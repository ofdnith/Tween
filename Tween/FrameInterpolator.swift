import CoreMedia
import CoreVideo
import Metal
import VideoToolbox

/// A sparse read of a frame's luma (64×36 points, ~2.3k bytes straight from the IOSurface; no copy of
/// the frame). Used to spot repeated frames and, in latency-test mode, a bright flash in the centre.
struct FrameProbe {
    private static let columns = 64
    private static let rows = 36

    let samples: [UInt8]
    /// Average centre luma, 0…1 (video range).
    let centerLuma: Float

    init?(_ pixelBuffer: CVPixelBuffer) {
        let step: Int, offset: Int
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            (step, offset) = (1, 0)
        case kCVPixelFormatType_422YpCbCr8_yuvs: // Y0 Cb Y1 Cr
            (step, offset) = (2, 0)
        case kCVPixelFormatType_422YpCbCr8:      // Cb Y0 Cr Y1
            (step, offset) = (2, 1)
        default:
            return nil
        }

        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let planar = CVPixelBufferIsPlanar(pixelBuffer)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) : CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) : CVPixelBufferGetBytesPerRow(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        var samples = [UInt8]()
        samples.reserveCapacity(Self.columns * Self.rows)
        var centerSum = 0, centerCount = 0
        for gy in 0..<Self.rows {
            let y = (2 * gy + 1) * height / (2 * Self.rows)
            for gx in 0..<Self.columns {
                let x = (2 * gx + 1) * width / (2 * Self.columns)
                let value = bytes[y * bytesPerRow + x * step + offset]
                samples.append(value)
                if (24..<40).contains(gx), (12..<24).contains(gy) {
                    centerSum += Int(value)
                    centerCount += 1
                }
            }
        }
        self.samples = samples
        centerLuma = max(0, (Float(centerSum) / Float(max(centerCount, 1)) - 16) / 219)
    }

    /// Mean and largest per-sample luma difference.
    func difference(from other: FrameProbe) -> (mean: Double, max: Int) {
        guard samples.count == other.samples.count, !samples.isEmpty else { return (255, 255) }
        var total = 0, largest = 0
        for (a, b) in zip(samples, other.samples) {
            let d = abs(Int(a) - Int(b))
            total += d
            largest = max(largest, d)
        }
        return (Double(total) / Double(samples.count), largest)
    }

    /// Repeated frames from a digital source are bit-identical; allow ±2 for MJPEG.
    func isRepeat(of other: FrameProbe) -> Bool {
        guard samples.count == other.samples.count else { return false }
        for (a, b) in zip(samples, other.samples) where abs(Int(a) - Int(b)) > 2 {
            return false
        }
        return true
    }
}

/// Spots repeats that aren't bit-identical. A 30 fps game streamed as 60 fps video repeats every
/// frame, but the encoder touches the repeat up, so it changes a little. (PS Remote Play: real
/// frames changed by 0.20–0.36 on the probe's scale, their repeats by 0–0.13.)
struct RepeatDetector {
    // Cadence: when frames alternate big change / small change, learn both levels and split between them.
    private static let memory = 7
    /// Changes of the frames on even and odd refresh slots, newest last.
    private var slotChanges: [[Double]] = [[], []]
    private var slot = 0
    private var interval = 1.0 / 60
    private var mismatches = 0

    // Fallback, when there is no alternation to learn from: compare with recent new frames.
    private static let history = 8
    private var recent: [Double] = []
    private var lastWasRepeat = false

    /// - Parameters:
    ///   - change: mean luma difference from the frame just before this one.
    ///   - sinceNew: mean luma difference from the last frame taken as new.
    ///   - gap: seconds since the frame just before this one.
    mutating func isRepeat(change: Double, sinceNew: Double, gap: Double) -> Bool {
        // Frames arrive on the source's refresh grid; a missing one moves two slots on.
        if gap > 0.004, gap < interval * 1.5 { interval += 0.1 * (gap - interval) }
        slot += max(1, Int((gap / interval).rounded()))
        let levels = cadence()
        slotChanges[slot & 1].append(change)
        if slotChanges[slot & 1].count > Self.memory { slotChanges[slot & 1].removeFirst() }

        if let levels {
            let isLow = change < levels.threshold
            // A hiccup can shift the pattern by one slot: after two frames on the "wrong" slot, follow it.
            let expectedLow = (slot & 1) == levels.lowSlot
            mismatches = isLow == expectedLow ? 0 : mismatches + 1
            if mismatches >= 2 {
                slotChanges.swapAt(0, 1)
                mismatches = 0
            }
            lastWasRepeat = isLow
            return isLow
        }

        // Never two in a row here, so a scene that slows down drops to half rate at worst while
        // `recent` catches up. Third-highest of the last 8: ignores a scene cut or two.
        if !lastWasRepeat, recent.count == Self.history, sinceNew < 0.3 * recent.sorted()[Self.history - 3] {
            lastWasRepeat = true
            return true
        }
        lastWasRepeat = false
        recent.append(sinceNew)
        if recent.count > Self.history { recent.removeFirst() }
        return false
    }

    /// The slot that carries the repeats and the change that separates them from new frames, or nil
    /// when the two slots don't clearly differ (a 60 fps game, a still picture).
    private func cadence() -> (lowSlot: Int, threshold: Double)? {
        guard slotChanges[0].count >= 5, slotChanges[1].count >= 5 else { return nil }
        // Medians: one scene cut must not move the levels.
        let sorted = slotChanges.map { $0.sorted() }
        let lowSlot = sorted[0][sorted[0].count / 2] < sorted[1][sorted[1].count / 2] ? 0 : 1
        let repeats = sorted[lowSlot]
        let low = repeats[repeats.count / 2], high = sorted[1 - lowSlot][sorted[1 - lowSlot].count / 2]
        guard high > 0.02, low < 0.6 * high else { return nil }
        // Normally halfway between the two levels on a ratio scale. But a stream's strongest repeats
        // reach half a new frame's change, so stay at least twice above the second-strongest recent
        // repeat, up to 0.6 × a typical new frame. (Replaying 4 minutes of a real Remote Play trace,
        // that cap gave the steadiest 30 a second; halfway alone let the strongest repeats through.)
        let halfway = (max(low, 0.1 * high) * high).squareRoot()
        return (lowSlot, min(0.6 * high, max(halfway, 2 * repeats[repeats.count - 2])))
    }
}

/// 2× low-latency frame interpolation (VideoToolbox, macOS 26+). Runs inside the renderer's own
/// Metal command buffer, so there's no CPU round-trip. Frames must be 420v.
@available(macOS 26.0, *)
final class FrameInterpolator {
    static var isSupported: Bool { VTLowLatencyFrameInterpolationConfiguration.isSupported }

    /// A new processor per session: one restarted after `endSession` crashes in `process` (seen on
    /// macOS 27 when the frame size changed or Fast/Full was switched).
    private var processor = VTFrameProcessor()
    private let commandQueue: MTLCommandQueue?
    private var pool: CVPixelBufferPool?
    private(set) var width = 0
    private(set) var height = 0
    /// Sizes that failed `producesOutput`, so the check doesn't rerun every frame.
    private var unsupportedSizes: Set<[Int]> = []

    init(device: MTLDevice) {
        commandQueue = device.makeCommandQueue()
    }

    /// (Re)starts the session when the frame size changes. False if this size isn't supported.
    func prepare(width: Int, height: Int) -> Bool {
        if pool != nil, width == self.width, height == self.height { return true }
        if unsupportedSizes.contains([width, height]) { return false }
        reset()
        processor = VTFrameProcessor()
        guard let configuration = VTLowLatencyFrameInterpolationConfiguration(
            frameWidth: width, frameHeight: height, numberOfInterpolatedFrames: 1) else { return false }
        do {
            try processor.startSession(configuration: configuration)
        } catch {
            return false
        }
        var attributes = configuration.destinationPixelBufferAttributes
        attributes[kCVPixelBufferMetalCompatibilityKey as String] = true
        var newPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary,
                                attributes as CFDictionary, &newPool)
        guard let newPool else {
            processor.endSession()
            return false
        }
        pool = newPool
        // The processor accepts any size but only writes output at some (1920×1080, 1280×720, …);
        // elsewhere it silently leaves the destination empty, which would show as green frames.
        guard producesOutput() else {
            processor.endSession()
            pool = nil
            unsupportedSizes.insert([width, height])
            return false
        }
        self.width = width
        self.height = height
        return true
    }

    /// Interpolates one test pair at the session's size and checks that pixels were written.
    private func producesOutput() -> Bool {
        guard let previous = makeBuffer(), let current = makeBuffer(), let output = makeBuffer(),
              let commandBuffer = commandQueue?.makeCommandBuffer() else { return false }
        Self.fill(previous, luma: 100)
        Self.fill(current, luma: 120)
        Self.fill(output, luma: 0)
        guard encodeMidpoint(previous: previous, previousTime: 0, current: current, currentTime: 1.0 / 30,
                             into: output, commandBuffer: commandBuffer) else { return false }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        guard CVPixelBufferLockBaseAddress(output, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        guard let luma = CVPixelBufferGetBaseAddressOfPlane(output, 0)?.assumingMemoryBound(to: UInt8.self) else { return false }
        let center = (CVPixelBufferGetHeightOfPlane(output, 0) / 2) * CVPixelBufferGetBytesPerRowOfPlane(output, 0)
            + CVPixelBufferGetWidthOfPlane(output, 0) / 2
        return luma[center] != 0
    }

    private static func fill(_ buffer: CVPixelBuffer, luma: Int32) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            memset(y, luma, CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * CVPixelBufferGetHeightOfPlane(buffer, 0))
        }
        if let c = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            memset(c, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
        }
    }

    /// A 420v buffer the interpolator accepts, for converted input or interpolated output.
    func makeBuffer() -> CVPixelBuffer? {
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    /// Encodes the frame halfway between `previous` and `current` into `destination`.
    func encodeMidpoint(previous: CVPixelBuffer, previousTime: CFTimeInterval,
                        current: CVPixelBuffer, currentTime: CFTimeInterval,
                        into destination: CVPixelBuffer, commandBuffer: MTLCommandBuffer) -> Bool {
        func time(_ seconds: CFTimeInterval) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 1_000_000) }
        guard let source = VTFrameProcessorFrame(buffer: current, presentationTimeStamp: time(currentTime)),
              let prior = VTFrameProcessorFrame(buffer: previous, presentationTimeStamp: time(previousTime)),
              let output = VTFrameProcessorFrame(buffer: destination,
                                                 presentationTimeStamp: time((previousTime + currentTime) / 2)),
              let parameters = VTLowLatencyFrameInterpolationParameters(
                sourceFrame: source, previousFrame: prior, interpolationPhase: [0.5], destinationFrames: [output])
        else { return false }
        processor.process(with: commandBuffer, parameters: parameters)
        return true
    }

    func reset() {
        if pool != nil { processor.endSession() }
        pool = nil
        width = 0
        height = 0
    }
}
