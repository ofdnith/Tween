import Metal
import QuartzCore
import CoreVideo

/// Mirrors `ColorParams` in Shaders.metal.
struct ColorParams {
    var uvRect: SIMD4<Float>
    var range: SIMD4<Float>
    var coefficients: SIMD4<Float>
}

/// Everything the user can change that affects drawing.
struct RenderConfig: Equatable {
    var scalingMode: ScalingMode = .fit
    var upscaling = true
    var upscaler: Upscaler.Kind = .metalFX
    var sharpening = true
    var sharpness: Float = 0.5
    var frameGeneration = false
    /// Make in-between frames at 720p: about half the processing time (≈10 vs ≈21 ms on an M3), so
    /// each real frame is held back that much less. Real frames are always shown at full resolution.
    var fastFrameGeneration = true
    /// Let one frame wait in the display queue, to cover frames the source delivers late. Measured
    /// on a real Remote Play stream: refreshes showing nothing new fell from about 2.8 a second to
    /// 0.9, and the typical delay stayed at 61 ms (77 ms in about one second in ten).
    var steadyFrameGeneration = true
    var latencyTest = false
}

struct RenderStats {
    var inputFPS: Double = 0
    var outputFPS: Double = 0
    var gpuMs: Double = 0
    var latencyMs: Double = 0
    var droppedFrames = 0
    /// Repeats skipped by frame generation (a 30 fps game on a 60 Hz signal sends each frame twice).
    var repeatedFrames = 0
    var pixelFormat: OSType = 0
    var sourceSize: CGSize = .zero
    /// The video area inside the drawable, in pixels.
    var videoSize: CGSize = .zero
    var drawableSize: CGSize = .zero
    var scaler = "—"
    /// nil when frame generation is off.
    var frameGeneration: String?
    var latencyFlashes = 0
    var secondsSinceLastFrame: Double = .infinity
}

/// Draws each captured frame the moment it arrives: CVPixelBuffer → CVMetalTextureCache →
/// YCbCr→RGB → optional upscale → optional sharpen → present. At most one frame is in flight.
/// With frame generation on, each new frame also produces an in-between frame that is shown first.
final class Renderer {
    enum RendererError: Error, LocalizedError {
        case setupFailed(String)
        var errorDescription: String? {
            switch self { case .setupFailed(let what): return "Metal setup failed: \(what)" }
        }
    }

    /// A frame on the direct path, waiting for presentQueue.
    private struct PendingFrame {
        let pixelBuffer: CVPixelBuffer
        let captureTime: CFTimeInterval
        let config: RenderConfig
        let marker: Bool?
        let layer: CAMetalLayer
    }

    /// One source frame's output under frame generation, waiting for presentQueue.
    private struct PendingPair {
        /// The in-between frame, if one was made.
        let middles: [CVPixelBuffer]
        /// The source frame itself, shown at full resolution.
        let real: CVPixelBuffer
        let captureTime: CFTimeInterval
        /// Shortest time each frame of the pair stays up before the next one.
        let halfPeriod: Double
        let config: RenderConfig
        let marker: Bool?
        let layer: CAMetalLayer
    }

    private struct FrameGenState {
        var previous: CVPixelBuffer?
        /// The previous real frame as it arrived (420v sources only), for the still-pixel lock.
        var previousSource: CVPixelBuffer?
        var previousTime: CFTimeInterval = 0
        var lastProbe: FrameProbe?
        /// The frame just before this one, new or not, and when it arrived.
        var previousProbe: FrameProbe?
        var previousFrameTime: CFTimeInterval = 0
        var lastDistinctTime: CFTimeInterval = 0
        /// Smoothed spacing of distinct frames, seconds. Paces the in-between frame.
        var period: Double = 0
        var detector = RepeatDetector()
        /// When the distinct frames of the last second arrived. Their count is the source's real
        /// rate; `period` isn't, because a stream that stutters delivers frames in 60 Hz bursts.
        var distinctTimes: [CFTimeInterval] = []
        var firstTime: CFTimeInterval = 0
        /// The source is already fast enough, so frames go straight to the screen.
        var idle = false
    }

    /// Receives each finished picture and the host time it reached the screen.
    typealias FrameSink = (CVPixelBuffer, CFTimeInterval) -> Void

    /// A finished picture on its way to the frame sink once it has been shown.
    private struct Tapped {
        let buffer: CVPixelBuffer
        let texture: CVMetalTexture
        let sink: FrameSink
    }

    /// Keeps frame generation's delay near its minimum. Generated and real frames are made at least
    /// as fast as the screen shows them, so a frame that ever gets queued stays queued: a source
    /// clock running a hair fast (or a 32 fps source on a 60 Hz screen) fills the whole queue and
    /// keeps it full (measured: 80–110 ms where ~50 is possible). Leaving out one generated frame
    /// empties one slot.
    ///
    /// It first finds the delay of an empty queue by leaving out a few generated frames in a row.
    /// After that it leaves out one whenever the delay is a full slot above that floor, and, while
    /// that keeps happening, a steady share of them (a source faster than half the refresh rate
    /// needs that all the time). Judging single skips by "did the delay fall" doesn't work: with a
    /// full queue the slot refills at once, which looks the same as "already at the minimum".
    struct LatencyGovernor {
        private enum Phase {
            /// Let frame generation settle before measuring anything.
            case warmUp(framesLeft: Int)
            /// Leaving out this many generated frames in a row to empty the queue.
            case draining(pairsLeft: Int)
            /// The queue is empty: the lowest delay seen now is the floor.
            case measuring(framesLeft: Int, lowest: Double)
            case holding
        }

        /// Generated frames left out in a row to empty the queue (4 slots = 67 ms at 60 Hz).
        private static let drainPairs = 4
        /// Real frames per decision: a skip only shows in the delay once the frames queued before it
        /// have been shown, so deciding faster than this reacts to stale numbers.
        private static let window = 20

        /// A skip takes a whole refresh off the delay, so it only helps once the delay is more than
        /// one refresh (plus measuring noise) above the floor; earlier, the screen would just repeat a frame.
        var refreshMs = 1000.0 / 60 { didSet { refreshMs = min(max(refreshMs, 2), 50) } }
        private var margin: Double { refreshMs + 3 }

        private var phase = Phase.warmUp(framesLeft: 30)
        private var floor = 0.0
        private var samples: [Double] = []
        /// Share of generated frames to leave out, and the running total that turns it into skips.
        private var skipShare = 0.0
        private var credit = 0.0
        private var windowsAbove = 0
        private var sinceProbe = 0

        /// The delay of the last few real frames, however they were shown.
        private var recent = 0.0

        /// True while the display queue is empty: there is room to let one frame wait in it. A stream
        /// delivers some frames a refresh early and others a refresh late; a frame that waits when
        /// one comes early is there to fill the refresh that would stay empty when the next comes late.
        var hasSlack: Bool {
            guard case .holding = phase else { return false }
            return recent < floor + 0.5 * refreshMs
        }

        /// Feed the capture → screen delay (ms) of every real frame.
        mutating func note(_ ms: Double) {
            recent = recent == 0 ? ms : recent + 0.5 * (ms - recent)
        }

        /// Feed the capture → screen delay (ms) of each real frame shown after a generated one.
        mutating func add(_ ms: Double) {
            switch phase {
            case .warmUp(let framesLeft):
                phase = framesLeft > 1 ? .warmUp(framesLeft: framesLeft - 1) : .draining(pairsLeft: Self.drainPairs)
            case .draining:
                break // frames from before the drain are still arriving
            case .measuring(let framesLeft, let lowest):
                let lowest = min(lowest, ms)
                if framesLeft > 1 {
                    phase = .measuring(framesLeft: framesLeft - 1, lowest: lowest)
                } else {
                    floor = lowest
                    samples.removeAll(keepingCapacity: true)
                    (skipShare, credit, windowsAbove, sinceProbe) = (0, 0, 0, 0)
                    phase = .holding
                }
            case .holding:
                samples.append(ms)
                sinceProbe += 1
                guard samples.count >= Self.window else { return }
                // A low percentile, not the average: a stream delivers some frames early or late, and
                // each early one queues its neighbours for a moment. Only a delay that nearly every
                // frame has is a standing queue. (Averaging skipped 6–18 frames a second on a real
                // Remote Play stream whose queue kept emptying by itself.)
                let average = samples.sorted()[samples.count / 5]
                samples.removeAll(keepingCapacity: true)
                floor = min(floor, average)
                if average > floor + margin {
                    // Skip one now, and more often from here on while this keeps happening.
                    credit = max(credit, 1)
                    skipShare = min(0.5, max(skipShare * 1.5, 1.0 / 40))
                    windowsAbove += 1
                    if windowsAbove >= 6 {
                        // Four seconds of skipping hasn't brought it down, so the floor is out of date
                        // (heavier settings, or a capture card's clock has drifted against the
                        // display's). Measure again, but not more than every 30 s.
                        (skipShare, credit, windowsAbove) = (0, 0, 0)
                        if sinceProbe >= 900 {
                            phase = .draining(pairsLeft: Self.drainPairs)
                        } else {
                            floor = average
                        }
                    }
                } else {
                    windowsAbove = 0
                    // Always ease off, only more slowly while the delay is still raised. Holding the
                    // share there got stuck: a capture card's delay sits anywhere in a refresh above
                    // the floor, depending on how its clock lines up with the display's, and half the
                    // generated frames were then left out for as long as it stayed in that band
                    // (recording: 46 fps shown for 40 s at an unchanged 80 ms).
                    skipShare *= average < floor + 0.6 * margin ? 0.7 : 0.85
                    if skipShare < 1.0 / 600 { skipShare = 0 }
                }
            }
        }

        /// Asked once per pair of frames: true = leave out this generated frame.
        mutating func takeSkip() -> Bool {
            switch phase {
            case .draining(let pairsLeft):
                phase = pairsLeft > 1 ? .draining(pairsLeft: pairsLeft - 1) : .measuring(framesLeft: 6, lowest: .infinity)
                return true
            case .holding:
                credit += skipShare
                guard credit >= 1 else { return false }
                credit -= 1
                return true
            default:
                return false
            }
        }
    }

    let device: MTLDevice
    let upscaler: Upscaler
    let supportsFrameGeneration: Bool

    private let commandQueue: MTLCommandQueue
    private let biplanarPipeline: MTLRenderPipelineState
    private let packedPipeline: MTLRenderPipelineState
    private let copyPipeline: MTLRenderPipelineState
    private let sharpenPipeline: MTLRenderPipelineState
    private let solidPipeline: MTLRenderPipelineState
    private let lumaPipeline: MTLRenderPipelineState
    private let chromaPipeline: MTLRenderPipelineState
    private let resampleLumaPipeline: MTLRenderPipelineState
    private let resampleChromaPipeline: MTLRenderPipelineState
    private let stillnessPipeline: MTLRenderPipelineState
    private let lockLumaPipeline: MTLRenderPipelineState
    private let lockChromaPipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache
    private let inFlight = DispatchSemaphore(value: 1)
    /// Frame generation presents from here, so the capture thread never waits on the screen.
    /// (A CAMetalDisplayLink was tried: it picks frames three refreshes ahead, adding ~30–45 ms, and
    /// makes any other nextDrawable call throw.)
    private let presentQueue = DispatchQueue(label: "tween.present", qos: .userInteractive)
    /// `FrameInterpolator` on macOS 26+, else nil (stored untyped for availability).
    private let interpolatorBox: AnyObject?

    // presentQueue only: see presentPendingFrame.
    private var waitingFrames = 0
    private var freeFrames = 0
    private var nextDrain: CFTimeInterval = 0
    private var drainInterval: CFTimeInterval = 2

    // Capture queue only.
    private var videoTexture: MTLTexture?
    private var frameGen = FrameGenState()
    private var lastMarker = false
    private var drawableCount = 2
    /// Still-pixel lock: two textures that take turns holding how long each pixel has been still.
    private var stillHistory: [MTLTexture] = []
    private var stillNewest = 0
    private var lockPool: CVPixelBufferPool?

    private let lock = NSLock()
    // Guarded by `lock`.
    private weak var layer: CAMetalLayer?
    private var config = RenderConfig()
    private var inputFrames = 0
    private var presentedFrames = 0
    private var droppedFrames = 0
    private var repeatedFrames = 0
    private var latencyFlashes = 0
    private var gpuMs = 0.0
    private var pendingGPUMs = 0.0
    private var latencyMs = 0.0
    private var lastFrameTime: CFTimeInterval = 0
    private var lastPixelFormat: OSType = 0
    private var lastSourceSize = CGSize.zero
    private var lastVideoSize = CGSize.zero
    private var lastDrawableSize = CGSize.zero
    private var lastScaler = "—"
    private var frameGenStatus: String?
    private var pendingPair: PendingPair?
    private var pendingFrame: PendingFrame?
    private var governor = LatencyGovernor()
    private var frameSink: FrameSink?
    private var sinkPool: CVPixelBufferPool?
    private var sinkPoolSize = (width: 0, height: 0)
    private var windowStart = CACurrentMediaTime()

    init(device: MTLDevice) throws {
        guard let queue = device.makeCommandQueue() else { throw RendererError.setupFailed("command queue") }
        guard let library = device.makeDefaultLibrary() else { throw RendererError.setupFailed("shader library") }

        func pipeline(_ fragment: String, _ format: MTLPixelFormat = .bgra8Unorm) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { throw RendererError.setupFailed("texture cache") }

        self.device = device
        commandQueue = queue
        biplanarPipeline = try pipeline("biplanarFragment")
        packedPipeline = try pipeline("packed422Fragment")
        copyPipeline = try pipeline("copyFragment")
        sharpenPipeline = try pipeline("casFragment")
        solidPipeline = try pipeline("solidFragment")
        lumaPipeline = try pipeline("packedToLuma", .r8Unorm)
        chromaPipeline = try pipeline("packedToChroma", .rg8Unorm)
        resampleLumaPipeline = try pipeline("resampleFragment", .r8Unorm)
        resampleChromaPipeline = try pipeline("resampleFragment", .rg8Unorm)
        stillnessPipeline = try pipeline("stillnessFragment", .r8Unorm)
        lockLumaPipeline = try pipeline("lockStillFragment", .r8Unorm)
        lockChromaPipeline = try pipeline("lockStillFragment", .rg8Unorm)
        textureCache = cache
        upscaler = try Upscaler(device: device, library: library)

        if #available(macOS 26.0, *), FrameInterpolator.isSupported {
            interpolatorBox = FrameInterpolator(device: device)
        } else {
            interpolatorBox = nil
        }
        supportsFrameGeneration = interpolatorBox != nil
    }

    func attach(layer: CAMetalLayer) {
        locked { self.layer = layer }
    }

    func setConfig(_ newConfig: RenderConfig) {
        locked { config = newConfig }
    }

    /// While set, every picture is also handed to `sink` (for screenshots and recording).
    func setFrameSink(_ sink: FrameSink?) {
        locked {
            frameSink = sink
            if sink == nil { sinkPool = nil }
        }
    }

    /// The output display's refresh rate, for the latency governor.
    func setRefreshRate(_ hertz: Double) {
        guard hertz > 0 else { return }
        locked { governor.refreshMs = 1000 / hertz }
    }

    func noteDroppedFrame() {
        locked { droppedFrames += 1 }
    }

    // MARK: - Frame path (capture queue)

    func render(pixelBuffer: CVPixelBuffer, captureTime: CFTimeInterval) {
        let (layer, config) = locked { () -> (CAMetalLayer?, RenderConfig) in
            inputFrames += 1
            lastFrameTime = CACurrentMediaTime()
            return (self.layer, self.config)
        }
        guard let layer else { return }

        let probe = config.frameGeneration || config.latencyTest ? FrameProbe(pixelBuffer) : nil
        var marker: Bool?
        if config.latencyTest {
            let bright = (probe?.centerLuma ?? 0) > 0.5
            if bright, !lastMarker { locked { latencyFlashes += 1 } }
            lastMarker = bright
            marker = bright
        }

        if config.frameGeneration, #available(macOS 26.0, *), let interpolator = interpolatorBox as? FrameInterpolator {
            if renderInterpolated(pixelBuffer, captureTime: captureTime, probe: probe, layer: layer,
                                  config: config, marker: marker, interpolator: interpolator) {
                setDrawableCount(3, on: layer)
                return
            }
            // Not interpolating this frame (source already fast, unsupported size…): direct path.
        } else if frameGen.lastProbe != nil {
            frameGen = FrameGenState()
            locked { frameGenStatus = nil }
        }
        setDrawableCount(2, on: layer)
        renderDirect(pixelBuffer, captureTime: captureTime, layer: layer, config: config, marker: marker)
    }

    /// Two drawables for the lowest latency; three only while actually generating frames (it presents
    /// twice per source frame and stalls with two). Following the F setting instead kept three on an
    /// already-60 fps stream, which then queued at the display: measured 61–78 ms instead of ~25.
    private func setDrawableCount(_ count: Int, on layer: CAMetalLayer) {
        guard count != drawableCount else { return }
        drawableCount = count
        DispatchQueue.main.async { layer.maximumDrawableCount = count }
    }

    /// Hands the frame to presentQueue, which draws the newest one each time the screen can take
    /// another. Drawing here instead means waiting for a drawable with the frame already chosen: a
    /// capture card runs on its own clock, a little faster or slower than the display, so that wait
    /// is nearly always a whole refresh and the frame ages through it (MS2130 card, 1080p60 on a
    /// 60 Hz screen: 81–89 ms that way).
    private func renderDirect(_ pixelBuffer: CVPixelBuffer, captureTime: CFTimeInterval, layer: CAMetalLayer,
                              config: RenderConfig, marker: Bool?) {
        let frame = PendingFrame(pixelBuffer: pixelBuffer, captureTime: captureTime, config: config,
                                 marker: marker, layer: layer)
        let replaced = locked { () -> Bool in
            let replaced = pendingFrame != nil
            pendingFrame = frame
            return replaced
        }
        if replaced {
            // The screen hasn't taken the last frame yet: this newer one goes in its place.
            noteDroppedFrame()
        } else {
            presentQueue.async { [weak self] in self?.presentPendingFrame() }
        }
    }

    /// Runs on presentQueue. Waits for the previous frame's GPU work and for a drawable first, and
    /// only then takes the frame, so what gets drawn is the newest one there is.
    private func presentPendingFrame() {
        guard let layer = locked({ pendingFrame?.layer }) else { return }
        guard inFlight.wait(timeout: .now() + .milliseconds(50)) == .success else {
            locked { pendingFrame = nil }
            noteDroppedFrame()
            return
        }
        let asked = CACurrentMediaTime()
        let drawable = layer.nextDrawable()
        let now = CACurrentMediaTime()
        // A source as fast as the display can settle into waiting for a drawable on every frame.
        // That state keeps itself going, and so does the other one, where a drawable is free the
        // moment a frame arrives: the free one is released just after the compositor's cut-off for
        // the next refresh, so a frame drawn then waits most of a refresh for the cut-off after it
        // (MS2130, 1080p60: 61–64 ms waiting, 49–55 not). Leaving one frame out moves it across.
        // At some phases between source and display it moves straight back, so retry ever less often.
        if now - asked > 0.001 {
            (waitingFrames, freeFrames) = (waitingFrames + 1, 0)
        } else {
            (waitingFrames, freeFrames) = (0, freeFrames + 1)
            if freeFrames == 300 { drainInterval = 2 }
        }
        if waitingFrames >= 30, now >= nextDrain {
            waitingFrames = 0
            nextDrain = now + drainInterval
            drainInterval = min(drainInterval * 2, 30)
            locked { pendingFrame = nil }
            inFlight.signal()
            noteDroppedFrame()
            return
        }
        guard let frame = locked({ () -> PendingFrame? in
            defer { pendingFrame = nil }
            return pendingFrame
        }) else {
            inFlight.signal()
            return
        }
        guard let drawable,
              let planes = makeTextures(frame.pixelBuffer),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              case (true, let tapped) = encodeFrame(planes, of: frame.pixelBuffer, into: drawable.texture,
                                                    config: frame.config, marker: frame.marker,
                                                    commandBuffer: commandBuffer) else {
            inFlight.signal()
            noteDroppedFrame()
            return
        }
        drawable.addPresentedHandler { [weak self] presented in
            self?.notePresented(at: presented.presentedTime, captureTime: frame.captureTime, tapped: tapped)
        }
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self] buffer in
            // The CVMetalTextures must outlive the GPU work that samples them.
            withExtendedLifetime((planes, frame.pixelBuffer)) {}
            guard let self else { return }
            let ms = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            self.locked { self.gpuMs = ms }
            self.inFlight.signal()
        }
        commandBuffer.commit()
    }

    /// Queues an in-between frame and this frame for presentQueue. Returns false when this frame
    /// can't be interpolated; the caller then queues it on its own.
    @available(macOS 26.0, *)
    private func renderInterpolated(_ pixelBuffer: CVPixelBuffer, captureTime: CFTimeInterval, probe: FrameProbe?,
                                    layer: CAMetalLayer, config: RenderConfig, marker: Bool?,
                                    interpolator: FrameInterpolator) -> Bool {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let accepted: Set<OSType> = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                     kCVPixelFormatType_422YpCbCr8_yuvs, kCVPixelFormatType_422YpCbCr8]
        guard accepted.contains(format), let probe else {
            frameGen = FrameGenState()
            locked { frameGenStatus = "Unavailable for \(format.formatName)" }
            return false
        }

        // The probe samples a coarse grid, so a small change (a menu cursor) can look like a repeat;
        // never hold the picture for more than 100 ms because of it.
        var isRepeat = false, touchedUp = false
        if let last = frameGen.lastProbe {
            let sinceNew = probe.difference(from: last).mean
            let change = frameGen.previousProbe.map { probe.difference(from: $0).mean } ?? sinceNew
            // Every frame goes through the detector, exact repeats too: it learns from their rhythm.
            let soft = frameGen.detector.isRepeat(change: change, sinceNew: sinceNew,
                                                  gap: captureTime - frameGen.previousFrameTime)
            if probe.isRepeat(of: last) {
                isRepeat = true
            } else if soft {
                (isRepeat, touchedUp) = (true, true)
            }
        }
        frameGen.previousProbe = probe
        frameGen.previousFrameTime = captureTime
        if isRepeat, captureTime - frameGen.lastDistinctTime < 0.1 {
            // While idle every frame that changed is shown; it just doesn't count towards the rate.
            if touchedUp, frameGen.idle { return false }
            locked { repeatedFrames += 1 }
            return true
        }
        frameGen.lastProbe = probe

        let gap = captureTime - frameGen.lastDistinctTime
        frameGen.lastDistinctTime = captureTime
        if gap > 0.005, gap < 0.1 {
            frameGen.period = frameGen.period == 0 ? gap : frameGen.period + 0.2 * (gap - frameGen.period)
        }
        if frameGen.firstTime == 0 { frameGen.firstTime = captureTime }
        frameGen.distinctTimes.append(captureTime)
        frameGen.distinctTimes.removeAll { captureTime - $0 >= 1 }
        // Two thresholds, so a rate hovering near one doesn't flip frame generation on and off.
        let rate = frameGen.distinctTimes.count
        frameGen.idle = rate >= (frameGen.idle ? 40 : 48)
        if frameGen.idle {
            frameGen.previous = nil
            frameGen.previousSource = nil
            locked { frameGenStatus = "Idle: source is already \(rate) fps" }
            return false
        }

        let (width, height) = Self.interpolationSize(width: CVPixelBufferGetWidth(pixelBuffer),
                                                     height: CVPixelBufferGetHeight(pixelBuffer),
                                                     fast: config.fastFrameGeneration)
        guard interpolator.prepare(width: width, height: height) else {
            frameGen.previous = nil
            locked { frameGenStatus = "Unsupported at \(width)×\(height)" }
            return false
        }
        if let previous = frameGen.previous,
           CVPixelBufferGetWidth(previous) != width || CVPixelBufferGetHeight(previous) != height {
            frameGen.previous = nil
        }

        // This thread only queues GPU work and returns; presentQueue presents. Blocking here on
        // drawables (which free up only after interpolation + a refresh) made capture drop every third
        // frame: measured 30 fps in → 20 real + 20 generated out.
        guard let work = commandQueue.makeCommandBuffer() else {
            noteDroppedFrame()
            return true
        }

        // The interpolator only reliably reads buffers from its own pool (others come out empty,
        // i.e. green, at most sizes), so every frame is copied, scaled or repacked into one on the GPU.
        guard let current = interpolator.makeBuffer(),
              let copyTextures = interpolatorInput(pixelBuffer, into: current, commandBuffer: work) else {
            noteDroppedFrame()
            return true
        }

        let previous = frameGen.previous, previousTime = frameGen.previousTime
        frameGen.previous = current
        frameGen.previousTime = captureTime
        let halfPeriod = frameGen.period / 2
        // A frame that arrives one refresh after the last (streams deliver some early, then catch up)
        // leaves no refresh to show an in-between frame in; making one anyway only queues delay.
        let refresh = locked { governor.refreshMs } / 1000
        // The exception: with the display queue empty, the extra frame may wait in it. That costs a
        // refresh of delay until a frame next arrives late, when it fills the refresh that would
        // otherwise show nothing new.
        // (Tried instead: two in-between frames, at ⅓ and ⅔, for a frame that arrives a refresh late.
        // A queue model said that removes every empty refresh; on screen it was worse, 54–58 fps at
        // ~85 ms with dropped frames against 56–60 at ~50, because three frames in a row need more
        // drawables than CAMetalLayer's three and the present thread blocks while new frames arrive.)
        let roomForMiddle = captureTime - previousTime > 1.5 * refresh
            || (config.steadyFrameGeneration && locked { governor.hasSlack })
        // How long the generated frame stays up before the real one: whole refreshes, less a quarter
        // refresh of slack. Not the smoothed half period itself: on an uneven stream that lands just
        // over one refresh (17–18 ms at 60 Hz), which holds every real frame a whole extra refresh.
        // Pairs then take three refreshes, not two, and the queue fills and stays full (on a real
        // Remote Play stream: 95–110 ms and 2–6 dropped frames a second, against 60 ms and none).
        let hold = max(1, (halfPeriod / refresh).rounded()) * refresh - 0.25 * refresh

        // The still-pixel lock compares real frames at full size when they are 420v already, else
        // the interpolator's (possibly smaller) copies.
        let fullSize = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let reference = fullSize ? pixelBuffer : current
        let previousReference = fullSize ? frameGen.previousSource : previous
        frameGen.previousSource = fullSize ? pixelBuffer : nil
        var lockTextures: [CVMetalTexture] = []
        let stillness = previousReference.flatMap {
            updateStillness(current: reference, previous: $0, commandBuffer: work, keep: &lockTextures)
        }

        var middles: [CVPixelBuffer] = []
        if let previous, roomForMiddle, captureTime - previousTime < 0.1, halfPeriod > 0,
           let buffer = interpolator.makeBuffer(),
           interpolator.encodeMidpoint(previous: previous, previousTime: previousTime, current: current,
                                       currentTime: captureTime, into: buffer, commandBuffer: work) {
            middles.append(stillness.flatMap {
                lockStill(generated: buffer, real: reference, stillness: $0, commandBuffer: work, keep: &lockTextures)
            } ?? buffer)
        }
        work.addCompletedHandler { [weak self] buffer in
            withExtendedLifetime((copyTextures, previous, lockTextures, previousReference)) {}
            let ms = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            self?.locked { self?.pendingGPUMs = ms }
        }
        work.commit()

        let pair = PendingPair(middles: middles, real: pixelBuffer, captureTime: captureTime, halfPeriod: hold,
                               config: config, marker: marker, layer: layer)
        let replaced = locked { () -> Bool in
            let replaced = pendingPair != nil
            pendingPair = pair
            return replaced
        }
        if replaced {
            // The screen is behind: show the newest pair rather than queueing delay.
            noteDroppedFrame()
        } else {
            presentQueue.async { [weak self] in self?.presentPendingPair() }
        }

        let interpolated = !middles.isEmpty
        // The count needs a second of frames; until then go by their spacing.
        let fps = captureTime - frameGen.firstTime >= 1 ? Double(frameGen.distinctTimes.count)
            : frameGen.period > 0 ? 1 / frameGen.period : 0
        locked {
            frameGenStatus = interpolated
                ? String(format: "On · %.0f → %.0f fps · %dp", fps, fps * 2, height)
                : "On · waiting for motion"
        }
        return true
    }

    /// Shows the in-between frame, then the real frame once the in-between one has been on screen
    /// for half a frame period. Runs on presentQueue; holds `inFlight` so it never overlaps the
    /// direct path's use of the shared upscale/sharpen textures.
    private func presentPendingPair() {
        guard let pair = locked({ () -> PendingPair? in
            defer { pendingPair = nil }
            return pendingPair
        }) else { return }
        guard inFlight.wait(timeout: .now() + .milliseconds(100)) == .success else {
            noteDroppedFrame()
            return
        }

        // Now and then the latency governor asks for one generated frame to be left out.
        var middles = pair.middles
        if !middles.isEmpty, locked({ governor.takeSkip() }) { middles.removeFirst() }
        var shownMiddles = 0
        for middle in middles {
            guard let planes = makeTextures(middle),
                  let drawable = pair.layer.nextDrawable(), let commandBuffer = commandQueue.makeCommandBuffer(),
                  case (true, let tapped) = encodeFrame(planes, of: middle, into: drawable.texture, config: pair.config,
                                                        marker: pair.marker, commandBuffer: commandBuffer) else { continue }
            drawable.addPresentedHandler { [weak self] presented in
                self?.notePresented(at: presented.presentedTime, captureTime: nil, tapped: tapped)
            }
            if shownMiddles == 0 {
                commandBuffer.present(drawable)
            } else {
                commandBuffer.present(drawable, afterMinimumDuration: pair.halfPeriod)
            }
            commandBuffer.addCompletedHandler { _ in withExtendedLifetime((planes, middle)) {} }
            commandBuffer.commit()
            shownMiddles += 1
        }

        guard let planes = makeTextures(pair.real),
              let drawable = pair.layer.nextDrawable(), let commandBuffer = commandQueue.makeCommandBuffer(),
              case (true, let tapped) = encodeFrame(planes, of: pair.real, into: drawable.texture, config: pair.config,
                                                    marker: pair.marker, commandBuffer: commandBuffer) else {
            inFlight.signal()
            noteDroppedFrame()
            return
        }
        let governed = shownMiddles > 0
        drawable.addPresentedHandler { [weak self] presented in
            self?.notePresented(at: presented.presentedTime, captureTime: pair.captureTime, tapped: tapped,
                                governed: governed)
        }
        if shownMiddles == 0 {
            commandBuffer.present(drawable)
        } else {
            commandBuffer.present(drawable, afterMinimumDuration: pair.halfPeriod)
        }
        commandBuffer.addCompletedHandler { [weak self] buffer in
            withExtendedLifetime((planes, pair.real)) {}
            guard let self else { return }
            let ms = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            self.locked {
                self.gpuMs = self.pendingGPUMs + ms
                self.pendingGPUMs = 0
            }
            self.inFlight.signal()
        }
        commandBuffer.commit()
    }

    /// Paints the screen black, e.g. after the capture device goes away.
    func clear() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, let layer = self.locked({ self.layer }) else { return }
            guard self.inFlight.wait(timeout: .now() + .milliseconds(100)) == .success else { return }
            guard let drawable = layer.nextDrawable(),
                  let commandBuffer = self.commandQueue.makeCommandBuffer() else {
                self.inFlight.signal()
                return
            }
            let pass = Self.renderPass(drawable.texture, clear: true)
            commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.addCompletedHandler { [weak self] _ in self?.inFlight.signal() }
            commandBuffer.commit()
        }
    }

    /// Returns rates since the previous call and resets the counters.
    func snapshot() -> RenderStats {
        locked {
            let now = CACurrentMediaTime()
            let elapsed = max(now - windowStart, 0.001)
            var stats = RenderStats()
            stats.inputFPS = Double(inputFrames) / elapsed
            stats.outputFPS = Double(presentedFrames) / elapsed
            stats.gpuMs = gpuMs
            stats.latencyMs = latencyMs
            stats.droppedFrames = droppedFrames
            stats.repeatedFrames = repeatedFrames
            stats.pixelFormat = lastPixelFormat
            stats.sourceSize = lastSourceSize
            stats.videoSize = lastVideoSize
            stats.drawableSize = lastDrawableSize
            stats.scaler = lastScaler
            stats.frameGeneration = frameGenStatus
            stats.latencyFlashes = latencyFlashes
            stats.secondsSinceLastFrame = lastFrameTime == 0 ? .infinity : now - lastFrameTime
            inputFrames = 0
            presentedFrames = 0
            windowStart = now
            return stats
        }
    }

    // MARK: - Encoding

    /// The full output chain for one frame into the drawable `target`. Returns false if nothing was encoded.
    /// Draws a frame into the drawable. While a screenshot or recording wants the picture, it is
    /// drawn into a buffer of its own (the video area only, no black bars) and copied to the screen:
    /// one extra pass, and only then.
    private func encodeFrame(_ planes: [CVMetalTexture], of pixelBuffer: CVPixelBuffer, into target: MTLTexture,
                             config: RenderConfig, marker: Bool?, commandBuffer: MTLCommandBuffer) -> (Bool, Tapped?) {
        let screenSize = CGSize(width: target.width, height: target.height)
        let sourceSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let viewport = Self.layout(source: sourceSize, drawable: screenSize, mode: config.scalingMode).0
        // Video encoders want even sizes.
        let width = Int(viewport.width) & ~1, height = Int(viewport.height) & ~1
        guard let sink = locked({ frameSink }),
              let buffer = sinkBuffer(width: width, height: height),
              let wrapped = texture(buffer, plane: 0, format: .bgra8Unorm, writable: true),
              let picture = CVMetalTextureGetTexture(wrapped) else {
            return (encodeOutput(planes, of: pixelBuffer, into: target, config: config, marker: marker,
                                 commandBuffer: commandBuffer), nil)
        }
        let area = MTLViewport(originX: viewport.originX, originY: viewport.originY,
                               width: Double(width), height: Double(height), znear: 0, zfar: 1)
        guard encodeOutput(planes, of: pixelBuffer, into: picture, config: config, marker: marker,
                           commandBuffer: commandBuffer, screenSize: screenSize),
              encodePresent(picture, into: target, viewport: area, sharpness: nil, marker: nil,
                            commandBuffer: commandBuffer) else { return (false, nil) }
        return (true, Tapped(buffer: buffer, texture: wrapped, sink: sink))
    }

    /// `screenSize` is the drawable's size when `target` is something else (for the stats).
    private func encodeOutput(_ planes: [CVMetalTexture], of pixelBuffer: CVPixelBuffer, into target: MTLTexture,
                              config: RenderConfig, marker: Bool?, commandBuffer: MTLCommandBuffer,
                              screenSize: CGSize? = nil) -> Bool {
        let drawableSize = CGSize(width: target.width, height: target.height)
        let sourceSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let (viewport, uvRect) = Self.layout(source: sourceSize, drawable: drawableSize, mode: config.scalingMode)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        var params = Self.colorParams(for: pixelBuffer, pixelFormat: pixelFormat, uvRect: uvRect)

        let cropWidth = Int((sourceSize.width * CGFloat(uvRect.z)).rounded())
        let cropHeight = Int((sourceSize.height * CGFloat(uvRect.w)).rounded())
        let outWidth = Int(viewport.width), outHeight = Int(viewport.height)
        let needsUpscale = outWidth > cropWidth || outHeight > cropHeight
        let sharpness: Float? = config.sharpening && config.sharpness > 0 ? config.sharpness : nil

        // Fastest path: one pass straight into the drawable. The others render into an output-sized
        // texture first so the final pass can sharpen with full-resolution neighbours.
        let scaler: String
        if config.upscaling, needsUpscale, let rgb = upscaler.inputTexture(width: cropWidth, height: cropHeight) {
            guard encodeConversion(planes, params: &params, into: rgb, viewport: Self.fullViewport(rgb), clear: false,
                                   marker: nil, commandBuffer: commandBuffer),
                  let (scaled, name) = upscaler.encode(source: rgb, outputWidth: outWidth, outputHeight: outHeight,
                                                       kind: config.upscaler, commandBuffer: commandBuffer),
                  encodePresent(scaled, into: target, viewport: viewport, sharpness: sharpness, marker: marker,
                                commandBuffer: commandBuffer) else { return false }
            scaler = name
        } else if let sharpness, let video = outputTexture(width: outWidth, height: outHeight) {
            guard encodeConversion(planes, params: &params, into: video, viewport: Self.fullViewport(video), clear: false,
                                   marker: nil, commandBuffer: commandBuffer),
                  encodePresent(video, into: target, viewport: viewport, sharpness: sharpness, marker: marker,
                                commandBuffer: commandBuffer) else { return false }
            scaler = needsUpscale ? "Bilinear (upscaling off)" : "Bilinear (no upscale needed)"
        } else {
            guard encodeConversion(planes, params: &params, into: target, viewport: viewport, clear: true,
                                   marker: marker, commandBuffer: commandBuffer) else { return false }
            scaler = needsUpscale ? "Bilinear (upscaling off)" : "Bilinear (no upscale needed)"
        }

        locked {
            lastPixelFormat = pixelFormat
            lastSourceSize = sourceSize
            lastVideoSize = CGSize(width: outWidth, height: outHeight)
            lastDrawableSize = screenSize ?? drawableSize
            lastScaler = scaler
        }
        return true
    }

    /// YCbCr → RGB (and bilinear scale/crop) into `target`.
    private func encodeConversion(_ planes: [CVMetalTexture], params: inout ColorParams, into target: MTLTexture,
                                  viewport: MTLViewport, clear: Bool, marker: Bool?,
                                  commandBuffer: MTLCommandBuffer) -> Bool {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: Self.renderPass(target, clear: clear)) else {
            return false
        }
        encoder.setViewport(viewport)
        encoder.setRenderPipelineState(planes.count == 2 ? biplanarPipeline : packedPipeline)
        for (index, plane) in planes.enumerated() {
            encoder.setFragmentTexture(CVMetalTextureGetTexture(plane), index: index)
        }
        encoder.setFragmentBytes(&params, length: MemoryLayout<ColorParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        drawMarker(marker, encoder: encoder, video: viewport)
        encoder.endEncoding()
        return true
    }

    /// Final pass: an output-sized texture 1:1 into the drawable's video area, sharpened or copied.
    private func encodePresent(_ texture: MTLTexture, into target: MTLTexture, viewport: MTLViewport,
                               sharpness: Float?, marker: Bool?, commandBuffer: MTLCommandBuffer) -> Bool {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: Self.renderPass(target, clear: true)) else {
            return false
        }
        encoder.setViewport(viewport)
        encoder.setFragmentTexture(texture, index: 0)
        if var sharpness {
            encoder.setRenderPipelineState(sharpenPipeline)
            encoder.setFragmentBytes(&sharpness, length: MemoryLayout<Float>.size, index: 0)
        } else {
            encoder.setRenderPipelineState(copyPipeline)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        drawMarker(marker, encoder: encoder, video: viewport)
        encoder.endEncoding()
        return true
    }

    /// Latency test: a square in the video's top-left corner, white while the captured picture's
    /// centre is bright and black otherwise.
    private func drawMarker(_ marker: Bool?, encoder: MTLRenderCommandEncoder, video: MTLViewport) {
        guard let marker else { return }
        let side = max(48, (video.height * 0.12).rounded())
        encoder.setViewport(MTLViewport(originX: video.originX + side / 4, originY: video.originY + side / 4,
                                        width: side, height: side, znear: 0, zfar: 1))
        encoder.setRenderPipelineState(solidPipeline)
        var color: SIMD4<Float> = marker ? SIMD4(1, 1, 1, 1) : SIMD4(0, 0, 0, 1)
        encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// The size in-between frames are made at. 16:9 sources are capped at 720p (fast) or 1080p, which
    /// the interpolator supports; other shapes stay at their own size so both kinds of frame line up.
    static func interpolationSize(width: Int, height: Int, fast: Bool) -> (width: Int, height: Int) {
        guard height > 0, abs(Double(width) / Double(height) - 16.0 / 9.0) < 0.02 else { return (width, height) }
        let maxHeight = fast ? 720 : 1080
        return height > maxHeight ? (maxHeight * 16 / 9, maxHeight) : (width, height)
    }

    /// Any supported source frame → an interpolator pool buffer (copy, scale or 4:2:2 repack).
    private func interpolatorInput(_ pixelBuffer: CVPixelBuffer, into destination: CVPixelBuffer,
                                   commandBuffer: MTLCommandBuffer) -> [CVMetalTexture]? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
            return repackTo420v(pixelBuffer, into: destination, commandBuffer: commandBuffer)
        }
        let sameSize = CVPixelBufferGetWidth(pixelBuffer) == CVPixelBufferGetWidth(destination)
            && CVPixelBufferGetHeight(pixelBuffer) == CVPixelBufferGetHeight(destination)
        return sameSize
            ? copy420v(pixelBuffer, into: destination, commandBuffer: commandBuffer)
            : resample420v(pixelBuffer, into: destination, commandBuffer: commandBuffer)
    }

    /// 420v frame → smaller 420v pool buffer: a bilinear pass per plane.
    private func resample420v(_ pixelBuffer: CVPixelBuffer, into destination: CVPixelBuffer,
                              commandBuffer: MTLCommandBuffer) -> [CVMetalTexture]? {
        guard let source = makeTextures(pixelBuffer), source.count == 2,
              let luma = texture(destination, plane: 0, format: .r8Unorm, writable: true),
              let chroma = texture(destination, plane: 1, format: .rg8Unorm, writable: true) else { return nil }
        for (input, output, pipeline) in [(source[0], luma, resampleLumaPipeline), (source[1], chroma, resampleChromaPipeline)] {
            guard let target = CVMetalTextureGetTexture(output),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: Self.renderPass(target, clear: false)) else {
                return nil
            }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(CVMetalTextureGetTexture(input), index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        return source + [luma, chroma]
    }

    /// 420v frame → 420v pool buffer for the interpolator: a plain GPU copy of both planes.
    private func copy420v(_ pixelBuffer: CVPixelBuffer, into destination: CVPixelBuffer,
                          commandBuffer: MTLCommandBuffer) -> [CVMetalTexture]? {
        guard let source = makeTextures(pixelBuffer), source.count == 2,
              let luma = texture(destination, plane: 0, format: .r8Unorm),
              let chroma = texture(destination, plane: 1, format: .rg8Unorm),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        for (from, to) in zip(source, [luma, chroma]) {
            guard let fromTexture = CVMetalTextureGetTexture(from), let toTexture = CVMetalTextureGetTexture(to) else {
                blit.endEncoding()
                return nil
            }
            blit.copy(from: fromTexture, to: toTexture)
        }
        blit.endEncoding()
        return source + [luma, chroma]
    }

    /// 4:2:2 capture → 420v pool buffer for the interpolator (luma pass + half-size chroma pass).
    private func repackTo420v(_ pixelBuffer: CVPixelBuffer, into destination: CVPixelBuffer,
                              commandBuffer: MTLCommandBuffer) -> [CVMetalTexture]? {
        guard let source = makeTextures(pixelBuffer)?.first,
              let luma = texture(destination, plane: 0, format: .r8Unorm, writable: true),
              let chroma = texture(destination, plane: 1, format: .rg8Unorm, writable: true) else { return nil }
        for (target, pipeline) in [(luma, lumaPipeline), (chroma, chromaPipeline)] {
            guard let output = CVMetalTextureGetTexture(target),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: Self.renderPass(output, clear: false)) else {
                return nil
            }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(CVMetalTextureGetTexture(source), index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        return [source, luma, chroma]
    }

    // MARK: - Still-pixel lock

    /// Real frames a pixel must hold still before it is locked (about 0.17 s at 30 fps). One or two
    /// frames isn't enough: moving texture often matches by chance, and locking it costs detail
    /// (measured on a panning game screenshot: 48.9 dB unlocked, 39.1 at 1 frame, 46.7 at 4).
    private static let stillFrames: Float = 5
    /// Luma change (of 255) that still counts as still: enough for a compressed stream's flutter.
    private static let stillTolerance: Float = 4

    /// Counts, per pixel, how long the picture has held still, from the two newest real frames.
    /// Returns the up-to-date map, or nil when it can't be made (then nothing is locked).
    func updateStillness(current: CVPixelBuffer, previous: CVPixelBuffer, commandBuffer: MTLCommandBuffer,
                         keep: inout [CVMetalTexture]) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(current), height = CVPixelBufferGetHeight(current)
        guard width == CVPixelBufferGetWidth(previous), height == CVPixelBufferGetHeight(previous) else {
            stillHistory = []
            return nil
        }
        if stillHistory.first?.width != width || stillHistory.first?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height,
                                                                      mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            stillHistory = (0..<2).compactMap { _ in device.makeTexture(descriptor: descriptor) }
            guard stillHistory.count == 2 else {
                stillHistory = []
                return nil
            }
            // New textures hold garbage; start every pixel at "just moved".
            for texture in stillHistory {
                commandBuffer.makeRenderCommandEncoder(descriptor: Self.renderPass(texture, clear: true))?.endEncoding()
            }
        }
        let history = stillHistory[stillNewest], target = stillHistory[1 - stillNewest]
        guard let currentLuma = texture(current, plane: 0, format: .r8Unorm),
              let previousLuma = texture(previous, plane: 0, format: .r8Unorm),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: Self.renderPass(target, clear: false)) else {
            return nil
        }
        var params = SIMD2<Float>(Self.stillTolerance / 255, 1 / Self.stillFrames)
        encoder.setRenderPipelineState(stillnessPipeline)
        encoder.setFragmentTexture(CVMetalTextureGetTexture(currentLuma), index: 0)
        encoder.setFragmentTexture(CVMetalTextureGetTexture(previousLuma), index: 1)
        encoder.setFragmentTexture(history, index: 2)
        encoder.setFragmentBytes(&params, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        stillNewest = 1 - stillNewest
        keep += [currentLuma, previousLuma]
        return target
    }

    /// The in-between frame with every still pixel (HUD, text, a fixed camera) taken from the real
    /// frame instead: the interpolator softens fine detail and smears it when the background moves
    /// behind it. The result has the real frame's size, so it also stays sharp in Fast (720p) mode.
    func lockStill(generated: CVPixelBuffer, real: CVPixelBuffer, stillness: MTLTexture, commandBuffer: MTLCommandBuffer,
                   keep: inout [CVMetalTexture]) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(real), height = CVPixelBufferGetHeight(real)
        guard stillness.width == width, stillness.height == height,
              let output = lockBuffer(width: width, height: height),
              let generatedPlanes = makeTextures(generated), generatedPlanes.count == 2,
              let realPlanes = makeTextures(real), realPlanes.count == 2,
              let luma = texture(output, plane: 0, format: .r8Unorm, writable: true),
              let chroma = texture(output, plane: 1, format: .rg8Unorm, writable: true) else { return nil }
        // Same colour tags as the real frame, so both kinds of frame convert identically.
        CVBufferPropagateAttachments(real, output)
        for (plane, target, pipeline) in [(0, luma, lockLumaPipeline), (1, chroma, lockChromaPipeline)] {
            guard let texture = CVMetalTextureGetTexture(target),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: Self.renderPass(texture, clear: false)) else {
                return nil
            }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(CVMetalTextureGetTexture(generatedPlanes[plane]), index: 0)
            encoder.setFragmentTexture(CVMetalTextureGetTexture(realPlanes[plane]), index: 1)
            encoder.setFragmentTexture(stillness, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        keep += generatedPlanes + realPlanes + [luma, chroma]
        return output
    }

    private func lockBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if let lockPool, let attributes = CVPixelBufferPoolGetPixelBufferAttributes(lockPool) as? [CFString: Any],
           attributes[kCVPixelBufferWidthKey] as? Int != width || attributes[kCVPixelBufferHeightKey] as? Int != height {
            self.lockPool = nil
        }
        if lockPool == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
                kCVPixelBufferMetalCompatibilityKey: true]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &lockPool)
        }
        guard let lockPool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, lockPool, &buffer)
        return buffer
    }

    // MARK: - Helpers

    private func notePresented(at presentedTime: CFTimeInterval, captureTime: CFTimeInterval?, tapped: Tapped?,
                               governed: Bool = false) {
        if let tapped, presentedTime > 0 { tapped.sink(tapped.buffer, presentedTime) }
        locked {
            // presentedTime is 0 when the compositor skipped the drawable.
            guard presentedTime > 0 else {
                droppedFrames += 1
                return
            }
            presentedFrames += 1
            guard let captureTime else { return }
            let ms = (presentedTime - captureTime) * 1000
            guard ms > 0, ms < 1000 else { return }
            governor.note(ms)
            if governed { governor.add(ms) }
            latencyMs = latencyMs == 0 ? ms : latencyMs + 0.1 * (ms - latencyMs)
        }
    }

    /// A BGRA buffer for a picture headed to the frame sink.
    private func sinkBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        guard width > 0, height > 0 else { return nil }
        let pool = locked { () -> CVPixelBufferPool? in
            if sinkPool == nil || sinkPoolSize != (width, height) {
                let attributes: [CFString: Any] = [
                    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                    kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
                    kCVPixelBufferMetalCompatibilityKey: true]
                sinkPool = nil
                CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &sinkPool)
                sinkPoolSize = (width, height)
            }
            return sinkPool
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    private func outputTexture(width: Int, height: Int) -> MTLTexture? {
        if let videoTexture, videoTexture.width == width, videoTexture.height == height { return videoTexture }
        guard width > 0, height > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        videoTexture = device.makeTexture(descriptor: descriptor)
        return videoTexture
    }

    private func texture(_ pixelBuffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat,
                         writable: Bool = false) -> CVMetalTexture? {
        let planar = CVPixelBufferIsPlanar(pixelBuffer)
        let width = planar ? CVPixelBufferGetWidthOfPlane(pixelBuffer, plane) : CVPixelBufferGetWidth(pixelBuffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(pixelBuffer, plane) : CVPixelBufferGetHeight(pixelBuffer)
        let usage: MTLTextureUsage = writable ? [.renderTarget, .shaderRead] : .shaderRead
        let attributes = [kCVMetalTextureUsage: usage.rawValue] as CFDictionary
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, attributes, format, width, height, plane, &texture)
        return status == kCVReturnSuccess ? texture : nil
    }

    /// One texture per plane, wrapping the buffer's IOSurface without copying.
    private func makeTextures(_ pixelBuffer: CVPixelBuffer) -> [CVMetalTexture]? {
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            guard let luma = texture(pixelBuffer, plane: 0, format: .r8Unorm),
                  let chroma = texture(pixelBuffer, plane: 1, format: .rg8Unorm) else { return nil }
            return [luma, chroma]
        case kCVPixelFormatType_422YpCbCr8_yuvs:
            return texture(pixelBuffer, plane: 0, format: .gbgr422).map { [$0] }
        case kCVPixelFormatType_422YpCbCr8:
            return texture(pixelBuffer, plane: 0, format: .bgrg422).map { [$0] }
        default:
            return nil
        }
    }

    private static func renderPass(_ target: MTLTexture, clear: Bool) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = clear ? .clear : .dontCare
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        return pass
    }

    private static func fullViewport(_ texture: MTLTexture) -> MTLViewport {
        MTLViewport(originX: 0, originY: 0, width: Double(texture.width), height: Double(texture.height), znear: 0, zfar: 1)
    }

    /// Fit: largest source-aspect rect that fits, centered with black bars. Fill: covers the drawable
    /// and crops the source. Stretch: covers the drawable, ignoring aspect.
    static func layout(source: CGSize, drawable: CGSize, mode: ScalingMode) -> (MTLViewport, SIMD4<Float>) {
        let full = MTLViewport(originX: 0, originY: 0, width: drawable.width, height: drawable.height, znear: 0, zfar: 1)
        let fullUV = SIMD4<Float>(0, 0, 1, 1)
        guard source.width > 0, source.height > 0, drawable.width > 0, drawable.height > 0 else { return (full, fullUV) }

        let sourceAspect = source.width / source.height
        let drawableAspect = drawable.width / drawable.height
        switch mode {
        case .stretch:
            return (full, fullUV)
        case .fill:
            if sourceAspect > drawableAspect {
                let w = Float(drawableAspect / sourceAspect)
                return (full, SIMD4((1 - w) / 2, 0, w, 1))
            } else {
                let h = Float(sourceAspect / drawableAspect)
                return (full, SIMD4(0, (1 - h) / 2, 1, h))
            }
        case .fit:
            var width = drawable.width, height = drawable.height
            if sourceAspect > drawableAspect {
                height = (drawable.width / sourceAspect).rounded()
            } else {
                width = (drawable.height * sourceAspect).rounded()
            }
            let viewport = MTLViewport(originX: ((drawable.width - width) / 2).rounded(),
                                       originY: ((drawable.height - height) / 2).rounded(),
                                       width: width, height: height, znear: 0, zfar: 1)
            return (viewport, fullUV)
        }
    }

    private static func colorParams(for pixelBuffer: CVPixelBuffer, pixelFormat: OSType, uvRect: SIMD4<Float>) -> ColorParams {
        let fullRange = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let range: SIMD4<Float> = fullRange ? SIMD4(0, 1, 1, 0) : SIMD4(16.0 / 255.0, 255.0 / 219.0, 255.0 / 224.0, 0)

        let bt601 = SIMD4<Float>(0.299, 0.114, 0, 0)
        let bt709 = SIMD4<Float>(0.2126, 0.0722, 0, 0)
        let bt2020 = SIMD4<Float>(0.2627, 0.0593, 0, 0)
        let matrix = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
        let coefficients: SIMD4<Float>
        if matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String {
            coefficients = bt601
        } else if matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String {
            coefficients = bt2020
        } else if matrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String {
            coefficients = bt709
        } else {
            // Untagged: HD and up is BT.709, SD is BT.601.
            coefficients = CVPixelBufferGetHeight(pixelBuffer) >= 720 ? bt709 : bt601
        }
        return ColorParams(uvRect: uvRect, range: range, coefficients: coefficients)
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

