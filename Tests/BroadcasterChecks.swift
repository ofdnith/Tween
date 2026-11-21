import AVFoundation
import Combine
import CoreMedia
import CoreVideo
import Foundation
import Metal

/// Runs the main run loop, where the broadcaster publishes its state, until `condition` holds.
@discardableResult
private func spin(timeout: TimeInterval, until condition: () -> Bool = { false }) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < end else { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    return true
}

/// A grey picture with a white square whose place depends on `index`: calm enough that the rate guard keeps every frame.
private func squareFrame(width: Int, height: Int, index: Int) -> CVPixelBuffer? {
    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
                                       kCVPixelBufferMetalCompatibilityKey: true]
    var buffer: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
          let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let side = height / 8, left = (index * width / 10) % (width - side), top = height / 3
    for y in 0..<height {
        let row = base + y * stride
        memset(row, 90, width * 4)
        if y >= top && y < top + side { memset(row + left * 4, 255, side * 4) }
    }
    return buffer
}

/// 10 ms of a 440 Hz tone, 48 kHz stereo Float, starting at sample `start`.
private func toneBuffer(start: Int, frames: Int = 480) -> CMSampleBuffer? {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
        mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                         magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr,
          let format else { return nil }
    var pcm = [Float](repeating: 0, count: frames * 2)
    for i in 0..<frames {
        let value = Float(0.3 * sin(2 * Double.pi * 440 * Double(start + i) / 48_000))
        pcm[i * 2] = value
        pcm[i * 2 + 1] = value
    }
    let bytes = pcm.count * 4
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                             customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                                             blockBufferOut: &block) == noErr, let block,
          pcm.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                              offsetIntoDestination: 0, dataLength: bytes) }) == noErr
    else { return nil }
    var sample: CMSampleBuffer?
    guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
        presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample) == noErr else { return nil }
    return sample
}

/// Feeds a broadcaster frames at 60 Hz and sound in 10 ms buffers, both at real time, on its own queue.
private final class Feeder {
    private let queue = DispatchQueue(label: "BroadcasterChecks.feeder", qos: .userInitiated)
    private let broadcaster: Broadcaster
    private let small: [CVPixelBuffer]
    private let large: [CVPixelBuffer]
    private var timer: DispatchSourceTimer?
    private var frameIndex = 0
    private var soundStart = 0.0
    private var soundBuffers = 0
    /// queue only
    private var useLarge = false

    init?(broadcaster: Broadcaster) {
        self.broadcaster = broadcaster
        let small = (0..<10).compactMap { squareFrame(width: 1280, height: 720, index: $0) }
        let large = (0..<10).compactMap { squareFrame(width: 2560, height: 1440, index: $0) }
        guard small.count == 10, large.count == 10 else { return nil }
        self.small = small
        self.large = large
    }

    func start(large: Bool = false) {
        queue.sync {
            useLarge = large
            soundStart = CACurrentMediaTime()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 60, leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func switchToLarge() { queue.sync { useLarge = true } }

    func stop() { queue.sync { timer?.cancel(); timer = nil } }

    private func tick() {
        let now = CACurrentMediaTime()
        let frames = useLarge ? large : small
        broadcaster.handle(frame: frames[frameIndex % frames.count], at: now)
        frameIndex += 1
        // Sound in 10 ms buffers stamped on one continuous timeline, as a capture device delivers it.
        while soundStart + Double(soundBuffers + 1) * 0.01 <= now {
            let time = soundStart + Double(soundBuffers) * 0.01
            if let sound = toneBuffer(start: soundBuffers * 480) {
                broadcaster.handle(gameAudio: sound, at: CMTime(seconds: time, preferredTimescale: 1_000_000_000))
            }
            soundBuffers += 1
        }
    }
}

private final class Locked<Value> {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func update(_ change: (inout Value) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}

private func oneSite(_ site: StreamSite = .twitch, quality: StreamQuality = .p1080, port: UInt16, key: String) -> StreamConfig {
    StreamConfig(sites: [StreamSiteConfig(site: site, server: "rtmp://127.0.0.1:\(port)/live", key: key,
                                          quality: quality, bitrate: 0)],
                 gameVolume: 1, camera: nil, mic: nil)
}

/// Stands in for `MicInput`: a 1 kHz tone in 10 ms pieces on the host clock, and states on demand.
private final class FakeMic: MicSource {
    var onSamples: (([Float], Double) -> Void)?
    var onState: ((MicInput.State) -> Void)?
    private let queue = DispatchQueue(label: "BroadcasterChecks.mic", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let started = Locked<[(deviceID: String?, removeGameSound: Bool)]>([])
    private let stops = Locked(0)
    /// What start reports.
    var startState = MicInput.State.running("Stand-in")
    var startCalls: [(deviceID: String?, removeGameSound: Bool)] { started.value }
    var stopCount: Int { stops.value }

    func start(deviceID: String?, removeGameSound: Bool) {
        started.update { $0.append((deviceID, removeGameSound)) }
        queue.sync {
            let origin = CACurrentMediaTime()
            var pieces = 0
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 0.005, leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in
                while origin + Double(pieces + 1) * 0.01 <= CACurrentMediaTime() {
                    var samples = [Float](repeating: 0, count: 960)
                    for i in 0..<480 {
                        let value = Float(0.3 * sin(2 * Double.pi * 1000 * Double(pieces * 480 + i) / 48_000))
                        samples[i * 2] = value
                        samples[i * 2 + 1] = value
                    }
                    self?.onSamples?(samples, origin + Double(pieces) * 0.01)
                    pieces += 1
                }
            }
            timer.resume()
            self.timer = timer
        }
        onState?(startState)
    }

    func stop() {
        stops.update { $0 += 1 }
        queue.sync { timer?.cancel(); timer = nil }
    }

    /// The microphone reports that it is gone.
    func disconnect() {
        // Keeps sending, as a device that is going away can for a moment: the broadcaster must drop it.
        onState?(.unavailable("Stand-in"))
    }
}

/// Stands in for `CameraFeed`: serves whatever frame it is given and records who started and stopped it.
private final class FakeCamera: CameraSource {
    let frame = Locked<CVPixelBuffer?>(nil)
    var onState: ((CameraFeed.State) -> Void)?
    /// What start reports.
    var startState = CameraFeed.State.running("Stand-in")
    private let started = Locked<[(deviceID: String?, user: CameraUser)]>([])
    private let stopped = Locked<[CameraUser]>([])
    var startCalls: [(deviceID: String?, user: CameraUser)] { started.value }
    var stopCalls: [CameraUser] { stopped.value }

    func newestFrame() -> CVPixelBuffer? { frame.value }

    func start(deviceID: String?, for user: CameraUser) {
        started.update { $0.append((deviceID, user)) }
        onState?(startState)
    }

    func stop(for user: CameraUser) { stopped.update { $0.append(user) } }

    /// The camera reports that it is gone, and has no picture any more.
    func disconnect() {
        frame.update { $0 = nil }
        onState?(.unavailable("Stand-in"))
    }
}

private func solidFrame(width: Int, height: Int, blue: UInt8, green: UInt8, red: UInt8) -> CVPixelBuffer? {
    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
                                       kCVPixelBufferMetalCompatibilityKey: true]
    var buffer: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
          let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height {
        for x in 0..<width {
            let p = base + y * stride + x * 4
            p[0] = blue; p[1] = green; p[2] = red; p[3] = 255
        }
    }
    return buffer
}

private struct Rgb { let blue: UInt8, green: UInt8, red: UInt8 }

private func rgb(_ buffer: CVPixelBuffer, at point: CGPoint) -> Rgb {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let p = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        + Int(point.y) * CVPixelBufferGetBytesPerRow(buffer) + Int(point.x) * 4
    return Rgb(blue: p[0], green: p[1], red: p[2])
}

private func isGreen(_ c: Rgb?) -> Bool { c.map { $0.green > 200 && $0.red < 40 && $0.blue < 40 } ?? false }
/// The game's grey (90) showing through.
private func isGameGrey(_ c: Rgb?) -> Bool { c.map { abs(Int($0.green) - 90) < 12 && abs(Int($0.red) - 90) < 12 && abs(Int($0.blue) - 90) < 12 } ?? false }

private let canvasSize = CGSize(width: 1920, height: 1080)

private func centre(of corner: StreamCorner, size: StreamCameraSize = .medium) -> CGPoint {
    let rect = StreamCompositor.cameraRect(canvas: canvasSize, aspect: 16.0 / 9.0, layout: CameraLayout(corner: corner, size: size))
    return CGPoint(x: rect.midX, y: rect.midY)
}

private func cameraConfig(port: UInt16, corner: StreamCorner = .bottomRight, size: StreamCameraSize = .medium) -> StreamConfig {
    var config = oneSite(port: port, key: "abc")
    config.camera = (deviceID: "usb-cam", layout: CameraLayout(corner: corner, size: size))
    return config
}

/// What the composed canvas shows at two corners' centres, as of its latest frame.
private final class CornerProbe {
    private let latest = Locked<(bottomRight: Rgb, topLeft: Rgb)?>(nil)
    init(_ broadcaster: Broadcaster) {
        let bottomRight = centre(of: .bottomRight), topLeft = centre(of: .topLeft)
        broadcaster.onCanvas = { [latest] canvas in
            latest.update { $0 = (rgb(canvas, at: bottomRight), rgb(canvas, at: topLeft)) }
        }
    }
    var bottomRight: Rgb? { latest.value?.bottomRight }
    var topLeft: Rgb? { latest.value?.topLeft }
}

/// How strongly a tone at `frequency` is in the left channel of interleaved 48 kHz stereo blocks, as an amplitude.
private func toneLevel(_ blocks: [[Float]], frequency: Double) -> Double {
    let left = blocks.flatMap { block in stride(from: 0, to: block.count, by: 2).map { Double(block[$0]) } }
    guard !left.isEmpty else { return 0 }
    var real = 0.0, imaginary = 0.0
    for (i, value) in left.enumerated() {
        let angle = 2 * Double.pi * frequency * Double(i) / 48_000
        real += value * cos(angle)
        imaginary += value * sin(angle)
    }
    return 2 * (real * real + imaginary * imaginary).squareRoot() / Double(left.count)
}

private func micConfig(port: UInt16, volume: Float = 1, removeGameSound: Bool = true) -> StreamConfig {
    var config = oneSite(port: port, key: "abc")
    config.mic = (deviceID: "usb-mic", volume: volume, removeGameSound: removeGameSound)
    return config
}

private func bytes(_ message: RTMPMessage, _ count: Int = 2) -> [UInt8] { Array(message.payload.prefix(count)) }

private func site(_ site: StreamSite, quality: StreamQuality = .p1080, bitrate: Int = 0, port: UInt16, key: String) -> StreamSiteConfig {
    StreamSiteConfig(site: site, server: "rtmp://127.0.0.1:\(port)/live", key: key, quality: quality, bitrate: bitrate)
}

private func bothSites(_ twitch: StreamSiteConfig, _ youtube: StreamSiteConfig) -> StreamConfig {
    StreamConfig(sites: [twitch, youtube], gameVolume: 1, camera: nil, mic: nil)
}

/// The SPS inside an FLV AVC sequence header (17 00 00 00 00, then the decoder configuration record).
private func sps(_ header: RTMPMessage) -> [UInt8]? {
    let bytes = [UInt8](header.payload)
    guard bytes.count > 13 else { return nil }
    let length = Int(bytes[11]) << 8 | Int(bytes[12])
    guard bytes.count >= 13 + length else { return nil }
    return Array(bytes[13..<13 + length])
}

/// Every state a site went through, as the main thread saw them.
private final class StateLog {
    private(set) var states: [Broadcaster.SiteState] = []
    private var subscription: AnyCancellable?
    init(_ broadcaster: Broadcaster, site: StreamSite) {
        subscription = broadcaster.$states.sink { [weak self] states in
            guard let self, let state = states[site], self.states.last != state else { return }
            self.states.append(state)
        }
    }
}

private func ends(_ broadcaster: Broadcaster) throws {
    var ended = false
    broadcaster.end { ended = true }
    try expect(spin(timeout: 5) { ended }, "end didn't complete")
}

func broadcasterChecks() {
    check("reconnect pauses are 1, 2, 4, 8, 16 s, then none; reset starts over") {
        var policy = ReconnectPolicy()
        var pauses: [Double?] = (0..<6).map { _ in policy.nextPause() }
        try expect(pauses == [1, 2, 4, 8, 16, nil], "pauses \(pauses)")
        try expect(policy.nextPause() == nil, "a pause after nil")
        policy.reset()
        pauses = [policy.nextPause(), policy.nextPause()]
        try expect(pauses == [1, 2], "after reset \(pauses)")
    }

    check("info line shows the sent rate, a smaller canvas, dropped frames and a slow connection") {
        let line = Broadcaster.infoLine(sentBitrate: 5_840_000, quality: .p1080, note: nil, droppedFrames: 0, tooSlow: false)
        try expect(line == "5.8 Mbps · 1080p", line)
        let noted = Broadcaster.infoLine(sentBitrate: 9_000_000, quality: .p1080, note: " (the picture is smaller than 1440p)",
                                         droppedFrames: 12, tooSlow: false)
        try expect(noted == "9.0 Mbps · 1080p (the picture is smaller than 1440p) · 12 frames dropped", noted)
        let one = Broadcaster.infoLine(sentBitrate: 6_000_000, quality: .p1440, note: nil, droppedFrames: 1, tooSlow: false)
        try expect(one == "6.0 Mbps · 1440p · 1 frame dropped", one)
        let slow = Broadcaster.infoLine(sentBitrate: 1_000_000, quality: .p1080, note: nil, droppedFrames: 3, tooSlow: true)
        try expect(slow == "Connection too slow", slow)
    }

    check("drawingTarget copies a shared frame, keeps an unshared one") {
        guard let frame = squareFrame(width: 640, height: 360, index: 3) else { throw CheckFailure(description: "no frame") }
        var pool: CVPixelBufferPool?
        let same = Recorder.drawingTarget(for: frame, shared: false, pool: &pool)
        try expect(same === frame, "shared: false gave another buffer")
        guard let copy = Recorder.drawingTarget(for: frame, shared: true, pool: &pool) else {
            throw CheckFailure(description: "no copy")
        }
        try expect(copy !== frame, "shared: true gave the same buffer")
        try expect(CVPixelBufferGetWidth(copy) == 640 && CVPixelBufferGetHeight(copy) == 360, "copy size")
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        CVPixelBufferLockBaseAddress(copy, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(copy, .readOnly)
            CVPixelBufferUnlockBaseAddress(frame, .readOnly)
        }
        let a = CVPixelBufferGetBaseAddress(frame)!, b = CVPixelBufferGetBaseAddress(copy)!
        let strideA = CVPixelBufferGetBytesPerRow(frame), strideB = CVPixelBufferGetBytesPerRow(copy)
        for y in 0..<360 {
            try expect(memcmp(a + y * strideA, b + y * strideB, 640 * 4) == 0, "row \(y) differs")
        }
    }

    check("stream keys are saved, read back and removed") {
        try expect(StreamKeyStore.folder.path.contains(".checks."), "harness folder \(StreamKeyStore.folder.path)")
        // The folder is this run's own (its name carries the process id); never leave it behind.
        defer { try? FileManager.default.removeItem(at: StreamKeyStore.folder) }
        try expect(StreamKeyStore.set(nil, for: .youtube), "removing nothing")
        try expect(StreamKeyStore.set("check-key-123", for: .youtube), "save")
        try expect(StreamKeyStore.key(for: .youtube) == "check-key-123", "read back")
        try expect(StreamKeyStore.hasKey(for: .youtube), "saved key not seen")
        try expect(!StreamKeyStore.hasKey(for: .twitch), "a key for the other site")
        let file = StreamKeyStore.folder.appendingPathComponent("youtube.key")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        try expect(mode == 0o600, "file mode \(String(mode ?? -1, radix: 8))")
        try expect(StreamKeyStore.set("replaced", for: .youtube), "replace")
        try expect(StreamKeyStore.key(for: .youtube) == "replaced", "read after replace")
        try expect(StreamKeyStore.set("", for: .youtube), "empty deletes")
        try expect(StreamKeyStore.key(for: .youtube) == nil, "read after delete")
        try expect(!StreamKeyStore.hasKey(for: .youtube), "deleted key still seen")
        try Data([0xff, 0xfe]).write(to: file)
        let bad = StreamKeyStore.read(for: .youtube)
        try expect(bad.key == nil && bad.unreadable, "a file that isn't text counts as unreadable")
        try expect(StreamKeyStore.set(nil, for: .youtube), "remove")
    }

    guard let device = MTLCreateSystemDefaultDevice() else {
        print("skip: broadcaster checks (no Metal device)")
        return
    }
    guard StreamVideoEncoder.hardwareAvailable(width: 1920, height: 1080) else {
        print("skip: broadcaster checks (no hardware H.264 encoder)")
        return
    }
    guard let source = try? String(contentsOfFile: repoRoot + "/Tween/Stream.metal", encoding: .utf8),
          let library = try? device.makeLibrary(source: source, options: nil) else {
        check("broadcaster setup") { throw CheckFailure(description: "could not build Stream.metal") }
        return
    }

    check("go live without a key or a site says what is missing") {
        let broadcaster = Broadcaster(device: device, library: library)
        broadcaster.goLive(oneSite(port: 1935, key: "  "))
        spin(timeout: 0.1)
        try expect(!broadcaster.isLive, "went live without a key")
        try expect(broadcaster.notice == "Add a Twitch stream key in Settings", "notice \(broadcaster.notice ?? "nil")")
        broadcaster.goLive(StreamConfig(sites: [], gameVolume: 1, camera: nil, mic: nil))
        spin(timeout: 0.1)
        try expect(!broadcaster.isLive, "went live with no site")
        try expect(broadcaster.notice == "Turn on Twitch or YouTube in Settings", "notice \(broadcaster.notice ?? "nil")")
    }

    check("streams picture and sound to one site") {
        let server = try RTMPTestServer(behaviour: .accept)
        defer { server.stop() }
        let broadcaster = Broadcaster(device: device, library: library)
        let wants = Locked<[Bool]>([])
        broadcaster.onWantsFrames = { wanted in wants.update { $0.append(wanted) } }
        let canvases = Locked<Set<String>>([])
        broadcaster.onCanvas = { buffer in
            canvases.update { $0.insert("\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer))") }
        }
        guard let feeder = Feeder(broadcaster: broadcaster) else { throw CheckFailure(description: "no frames") }
        feeder.start()
        defer { feeder.stop() }

        // YouTube asks for 1440p; a 720p picture gets 1080p, and a 1440p picture later must not change it.
        broadcaster.goLive(oneSite(.youtube, quality: .p1440, port: server.port, key: " abc \n"))
        try expect(spin(timeout: 5) { broadcaster.states[.youtube] == .live },
                   "not live: \(String(describing: broadcaster.states[.youtube])) \(broadcaster.notice ?? "")")
        try expect(broadcaster.info[.youtube]?.hasPrefix("9.0 Mbps · 1080p") == true, "info \(broadcaster.info[.youtube] ?? "nil")")
        spin(timeout: 1.5)
        feeder.switchToLarge()
        spin(timeout: 1.5)
        try expect(broadcaster.states[.youtube] == .live, "after the size change: \(String(describing: broadcaster.states[.youtube]))")
        var ended = false, endedAgain = false
        broadcaster.end { ended = true }
        // A second end (quitting while ending) waits for the same close.
        broadcaster.end { endedAgain = true }
        try expect(!endedAgain, "second end completed before the first")
        try expect(spin(timeout: 5) { ended && endedAgain }, "end didn't complete: \(ended) \(endedAgain)")
        try expect(!broadcaster.isLive && broadcaster.states[.youtube] == .off, "still live after end")
        try expect(wants.value.first == true && wants.value.last == false, "frame wants \(wants.value)")
        spin(timeout: 0.3)

        try expect(server.publishedKey == "abc", "published key \(server.publishedKey ?? "nil")")
        let media = server.received.filter { [8, 9, 18].contains($0.type) }
        try expect(media.count >= 4, "only \(media.count) media messages")
        try expect(media[0].type == 18, "first is not metadata: type \(media[0].type)")
        try expect(media[1].type == 9 && bytes(media[1]) == [0x17, 0x00], "second is not the AVC header: \(bytes(media[1]))")
        try expect(media[2].type == 8 && bytes(media[2]) == [0xAF, 0x00], "third is not the AAC header: \(bytes(media[2]))")
        try expect(media[3].type == 9 && bytes(media[3]) == [0x17, 0x01], "fourth is not a keyframe: \(bytes(media[3]))")

        let video = media.filter { $0.type == 9 }
        let audio = media.filter { $0.type == 8 }
        try expect((170...190).contains(video.count), "\(video.count) video messages")
        try expect((135...146).contains(audio.count), "\(audio.count) audio messages")
        try expect(video.first?.timestamp == 0, "first video timestamp \(video.first?.timestamp ?? 0)")
        try expect(zip(video, video.dropFirst()).allSatisfy { $0.timestamp <= $1.timestamp }, "video timestamps go backwards")
        try expect(zip(audio, audio.dropFirst()).allSatisfy { $0.timestamp <= $1.timestamp }, "audio timestamps go backwards")
        let lastVideo = Int(video.last?.timestamp ?? 0), lastAudio = Int(audio.last?.timestamp ?? 0)
        try expect(abs(lastVideo - lastAudio) < 200, "last video \(lastVideo) ms, last audio \(lastAudio) ms")

        try expect(canvases.value == ["1920x1080"], "canvases \(canvases.value)")
        try expect(media.filter { $0.type == 18 }.count == 1, "metadata sent again")
        try expect(video.filter { bytes($0) == [0x17, 0x00] }.count == 1, "sequence header sent again")
    }

    check("no picture for 5 s does not go live") {
        let server = try RTMPTestServer(behaviour: .accept)
        defer { server.stop() }
        let broadcaster = Broadcaster(device: device, library: library)
        let started = Date()
        broadcaster.goLive(oneSite(port: server.port, key: "abc"))
        try expect(broadcaster.isLive, "not starting")
        try expect(spin(timeout: 7) { broadcaster.notice != nil }, "no notice")
        try expect(Date().timeIntervalSince(started) > 4.8, "gave up after \(Date().timeIntervalSince(started)) s")
        try expect(broadcaster.notice == "No picture to stream", "notice \(broadcaster.notice ?? "nil")")
        try expect(!broadcaster.isLive, "live without a picture")
        try expect(server.publishedKey == nil, "published without a picture")
    }

    check("streams to both sites at two canvases") {
        guard StreamVideoEncoder.hardwareAvailable(width: 2560, height: 1440) else {
            print("skip: two canvases (no hardware 1440p encoder)")
            return
        }
        let a = try RTMPTestServer(behaviour: .accept), b = try RTMPTestServer(behaviour: .accept)
        defer { a.stop(); b.stop() }
        let broadcaster = Broadcaster(device: device, library: library)
        guard let feeder = Feeder(broadcaster: broadcaster) else { throw CheckFailure(description: "no frames") }
        feeder.start(large: true)
        defer { feeder.stop() }
        broadcaster.goLive(bothSites(site(.twitch, quality: .p1080, port: a.port, key: "ka"),
                                     site(.youtube, quality: .p1440, port: b.port, key: "kb")))
        try expect(spin(timeout: 5) { broadcaster.states[.twitch] == .live && broadcaster.states[.youtube] == .live },
                   "not live: \(broadcaster.states) \(broadcaster.notice ?? "")")
        spin(timeout: 1)
        try ends(broadcaster)
        spin(timeout: 0.3)
        let headers = [a, b].map { server in server.received.first { $0.type == 9 && bytes($0) == [0x17, 0x00] } }
        let videos = [a, b].map { server in server.received.filter { $0.type == 9 && (bytes($0) == [0x17, 0x01] || bytes($0) == [0x27, 0x01]) } }
        try expect(videos.allSatisfy { $0.count > 20 }, "video counts \(videos.map(\.count))")
        guard let first = headers[0].flatMap(sps), let second = headers[1].flatMap(sps) else {
            throw CheckFailure(description: "a sequence header is missing")
        }
        try expect(first != second, "both sites got the same SPS")
    }

    check("two sites on one canvas and bitrate get the same video") {
        let a = try RTMPTestServer(behaviour: .accept), b = try RTMPTestServer(behaviour: .accept)
        defer { a.stop(); b.stop() }
        let broadcaster = Broadcaster(device: device, library: library)
        guard let feeder = Feeder(broadcaster: broadcaster) else { throw CheckFailure(description: "no frames") }
        feeder.start()
        defer { feeder.stop() }
        broadcaster.goLive(bothSites(site(.twitch, bitrate: 6_000_000, port: a.port, key: "ka"),
                                     site(.youtube, bitrate: 6_000_000, port: b.port, key: "kb")))
        try expect(spin(timeout: 5) { broadcaster.states[.twitch] == .live && broadcaster.states[.youtube] == .live },
                   "not live: \(broadcaster.states) \(broadcaster.notice ?? "")")
        spin(timeout: 1.5)
        try ends(broadcaster)
        spin(timeout: 0.3)
        let videos = [a, b].map { server in server.received.filter { $0.type == 9 }.map(\.payload) }
        try expect(videos[0].first == videos[1].first, "sequence headers differ")
        // One site may have started a keyframe earlier; from the later start on, both carry the same bytes.
        let later = videos[0].count >= videos[1].count ? 1 : 0, earlier = 1 - later
        guard videos[later].count > 1, let start = videos[earlier].firstIndex(of: videos[later][1]) else {
            throw CheckFailure(description: "the later site's first frame isn't in the other stream")
        }
        let shared = Array(zip(videos[earlier][start...], videos[later].dropFirst()))
        try expect(shared.count > 60, "only \(shared.count) frames in common")
        try expect(shared.allSatisfy { $0 == $1 }, "payloads differ")
    }

    check("one site reconnecting leaves the other live") {
        let a = try RTMPTestServer(behaviour: .dropAfterPublish, stopsListeningOnDrop: true)
        let b = try RTMPTestServer(behaviour: .accept)
        defer { a.stop(); b.stop() }
        let broadcaster = Broadcaster(device: device, library: library)
        broadcaster.timeScale = 0.01
        guard let feeder = Feeder(broadcaster: broadcaster) else { throw CheckFailure(description: "no frames") }
        feeder.start()
        defer { feeder.stop() }
        broadcaster.goLive(bothSites(site(.twitch, port: a.port, key: "ka"), site(.youtube, port: b.port, key: "kb")))
        try expect(spin(timeout: 5) { broadcaster.states[.twitch] == .reconnecting(1) },
                   "twitch \(String(describing: broadcaster.states[.twitch]))")
        try expect(spin(timeout: 5) { broadcaster.states[.youtube] == .live }, "youtube \(String(describing: broadcaster.states[.youtube]))")
        let before = b.received.filter { $0.type == 9 }.count
        spin(timeout: 0.5)
        let after = b.received.filter { $0.type == 9 }.count
        try expect(after >= before + 20, "youtube video \(before) -> \(after)")
        try expect(broadcaster.states[.youtube] == .live, "youtube \(String(describing: broadcaster.states[.youtube]))")
        try ends(broadcaster)
    }

    check("a dropped connection comes back live and starts its stream again") {
        let server = try RTMPTestServer(behaviour: .dropOnceThenAccept)
        defer { server.stop() }
        let broadcaster = Broadcaster(device: device, library: library)
        broadcaster.timeScale = 0.01
        let log = StateLog(broadcaster, site: .twitch)
        guard let feeder = Feeder(broadcaster: broadcaster) else { throw CheckFailure(description: "no frames") }
        feeder.start()
        defer { feeder.stop() }
        broadcaster.goLive(oneSite(port: server.port, key: "abc"))
        try expect(spin(timeout: 5) { server.connectionCount == 2 && broadcaster.states[.twitch] == .live },
                   "states \(log.states) connections \(server.connectionCount)")
        spin(timeout: 1)
        try ends(broadcaster)
        spin(timeout: 0.3)
        try expect(log.states.contains(.reconnecting(1)), "states \(log.states)")
        let connections = server.receivedPerConnection
        guard connections.count == 2 else { throw CheckFailure(description: "\(connections.count) connections") }
        try expect(connections[1].contains { $0.type == 20 && (try? AMF0.decode($0.payload).first) == .string("publish") },
                   "no publish on the new connection")
        let media = connections[1].filter { [8, 9, 18].contains($0.type) }
        try expect(media.count > 10, "only \(media.count) media messages")
        try expect(media[0].type == 18, "first is not metadata: type \(media[0].type)")
        try expect(media[1].type == 9 && bytes(media[1]) == [0x17, 0x00], "second is not the AVC header: \(bytes(media[1]))")
        try expect(media[2].type == 8 && bytes(media[2]) == [0xAF, 0x00], "third is not the AAC header: \(bytes(media[2]))")
        try expect(media[3].type == 9 && bytes(media[3]) == [0x17, 0x01], "fourth is not a keyframe: \(bytes(media[3]))")
        try expect(media[0...3].allSatisfy { $0.timestamp == 0 }, "start timestamps \(media[0...3].map(\.timestamp))")
        let video = media.filter { $0.type == 9 }
        try expect(zip(video, video.dropFirst()).allSatisfy { $0.timestamp <= $1.timestamp }, "video timestamps go backwards")
        try expect((video.last?.timestamp ?? 0) < 3000, "new connection's clock didn't start at 0: \(video.last?.timestamp ?? 0)")
    }

    check("an error status while publishing reconnects instead of failing") {
        let server = try RTMPTestServer(behaviour: .errorAfterPublish)
        defer { server.stop() }
        let broadcaster = Broadcaster(device: device, library: library)
        broadcaster.timeScale = 0.01
        let log = StateLog(broadcaster, site: .twitch)
        guard let feeder = Feeder(broadcaster: broadcaster) else { throw CheckFailure(description: "no frames") }
        feeder.start()
        defer { feeder.stop() }
        broadcaster.goLive(oneSite(port: server.port, key: "abc"))
        let failed = { log.states.contains { if case .failed = $0 { return true } else { return false } } }
        try expect(spin(timeout: 5) { log.states.contains(.reconnecting(1)) || failed() }, "states \(log.states)")
        try expect(!failed() && log.states.contains(.reconnecting(1)), "states \(log.states)")
        try expect(spin(timeout: 5) { server.connectionCount >= 2 }, "no second connection")
        try ends(broadcaster)
    }

    check("a notice clears itself, and an older timer does not clear a newer notice") {
        let broadcaster = Broadcaster(device: device, library: library)
        broadcaster.noticeDuration = 0.4
        broadcaster.goLive(StreamConfig(sites: [], gameVolume: 1, camera: nil, mic: nil))
        try expect(broadcaster.notice != nil, "no notice")
        spin(timeout: 0.25)
        broadcaster.goLive(oneSite(port: 1935, key: " "))
        try expect(broadcaster.notice == "Add a Twitch stream key in Settings", "notice \(broadcaster.notice ?? "nil")")
        // The first notice's timer fires at 0.4 s, 0.15 s from here; the second one's at 0.65 s.
        spin(timeout: 0.3)
        try expect(broadcaster.notice == "Add a Twitch stream key in Settings", "older timer cleared it: \(broadcaster.notice ?? "nil")")
        try expect(spin(timeout: 1) { broadcaster.notice == nil }, "notice did not clear")
    }

    check("sites that can't start end the stream with a notice") {
        let broadcaster = Broadcaster(device: device, library: library)
        guard let feeder = Feeder(broadcaster: broadcaster) else { throw CheckFailure(description: "no frames") }
        feeder.start()
        defer { feeder.stop() }
        broadcaster.goLive(StreamConfig(sites: [StreamSiteConfig(site: .twitch, server: "http://127.0.0.1/live", key: "abc",
                                                                 quality: .p1080, bitrate: 0)],
                                        gameVolume: 1, camera: nil, mic: nil))
        try expect(spin(timeout: 5) { broadcaster.notice != nil }, "no notice; states \(broadcaster.states)")
        try expect(broadcaster.notice == "The stream ended. Twitch: Check the server address in Settings",
                   "notice \(broadcaster.notice ?? "nil")")
        try expect(!broadcaster.isLive, "still live")
    }

    check("a refused publish fails at once, without reconnecting") {
        let server = try RTMPTestServer(behaviour: .rejectPublish(description: "bad key"))
        defer { server.stop() }
        let broadcaster = Broadcaster(device: device, library: library)
        broadcaster.timeScale = 0.01
        let log = StateLog(broadcaster, site: .twitch)
        guard let feeder = Feeder(broadcaster: broadcaster) else { throw CheckFailure(description: "no frames") }
        feeder.start()
        defer { feeder.stop() }
        broadcaster.goLive(oneSite(port: server.port, key: "abc"))
        try expect(spin(timeout: 5) { if case .failed = broadcaster.states[.twitch] { return true } else { return false } },
                   "states \(log.states)")
        spin(timeout: 0.3)
        try expect(!log.states.contains { if case .reconnecting = $0 { return true } else { return false } }, "states \(log.states)")
        try expect(server.connectionCount == 1, "\(server.connectionCount) connections")
        try expect(!broadcaster.isLive, "still live")
        try expect(broadcaster.notice?.contains("bad key") == true, "notice \(broadcaster.notice ?? "nil")")
    }

    check("after five failed retries the site fails and the stream ends") {
        let server = try RTMPTestServer(behaviour: .dropAfterPublish, stopsListeningOnDrop: true)
        defer { server.stop() }
        let broadcaster = Broadcaster(device: device, library: library)
        broadcaster.timeScale = 0.01
        let log = StateLog(broadcaster, site: .twitch)
        guard let feeder = Feeder(broadcaster: broadcaster) else { throw CheckFailure(description: "no frames") }
        feeder.start()
        defer { feeder.stop() }
        broadcaster.goLive(oneSite(port: server.port, key: "abc"))
        try expect(spin(timeout: 15) { broadcaster.states[.twitch] == .failed("Connection lost") }, "states \(log.states)")
        try expect(log.states.contains(.reconnecting(5)) && !log.states.contains(.reconnecting(6)), "states \(log.states)")
        try expect(!broadcaster.isLive, "still live")
        try expect(broadcaster.notice?.contains("Connection lost") == true, "notice \(broadcaster.notice ?? "nil")")
    }

    check("the microphone is mixed with the game, muted with toggleMicMute, and unmuted again") {
        let server = try RTMPTestServer(behaviour: .accept)
        defer { server.stop() }
        let broadcaster = Broadcaster(device: device, library: library)
        let mic = FakeMic()
        broadcaster.micSource = mic
        let blocks = Locked<[[Float]]>([])
        broadcaster.onSoundBlock = { samples, _ in blocks.update { $0.append(samples) } }
        guard let feeder = Feeder(broadcaster: broadcaster) else { throw CheckFailure(description: "no frames") }
        feeder.start()
        defer { feeder.stop() }
        broadcaster.goLive(micConfig(port: server.port, removeGameSound: false))
        try expect(spin(timeout: 5) { broadcaster.states[.twitch] == .live }, "not live")
        try expect(mic.startCalls.count == 1 && mic.startCalls[0].deviceID == "usb-mic" && !mic.startCalls[0].removeGameSound,
                   "start calls \(mic.startCalls)")
        try expect(broadcaster.micState == .running("Stand-in"), "state \(broadcaster.micState)")
        spin(timeout: 1.5)
        let both = Array(blocks.value.suffix(20))
        try expect(both.count == 20, "\(both.count) blocks")
        try expect(toneLevel(both, frequency: 440) > 0.15, "game tone \(toneLevel(both, frequency: 440))")
        try expect(toneLevel(both, frequency: 1000) > 0.15, "mic tone \(toneLevel(both, frequency: 1000))")

        broadcaster.toggleMicMute()
        try expect(broadcaster.micMuted, "not muted")
        // Past what the mixer had already cut.
        spin(timeout: 0.8)
        let mark = blocks.value.count
        spin(timeout: 1.2)
        let muted = Array(blocks.value[mark...].suffix(20))
        try expect(muted.count == 20, "\(muted.count) muted blocks")
        try expect(toneLevel(muted, frequency: 440) > 0.15, "game tone while muted \(toneLevel(muted, frequency: 440))")
        try expect(toneLevel(muted, frequency: 1000) < 0.03, "mic tone while muted \(toneLevel(muted, frequency: 1000))")

        broadcaster.toggleMicMute()
        try expect(!broadcaster.micMuted, "still muted")
        spin(timeout: 0.8)
        let mark2 = blocks.value.count
        spin(timeout: 1.2)
        let back = Array(blocks.value[mark2...].suffix(20))
        try expect(toneLevel(back, frequency: 1000) > 0.15, "mic tone after unmute \(toneLevel(back, frequency: 1000))")

        try ends(broadcaster)
        try expect(mic.stopCount >= 1, "microphone not stopped")
        try expect(broadcaster.micState == .off, "state after end \(broadcaster.micState)")
        // Muting is for a live stream; it starts unmuted next time.
        broadcaster.toggleMicMute()
        try expect(!broadcaster.micMuted, "muted while not live")
    }

    check("a microphone that goes away leaves the stream live with a notice") {
        let server = try RTMPTestServer(behaviour: .accept)
        defer { server.stop() }
        let broadcaster = Broadcaster(device: device, library: library)
        let mic = FakeMic()
        broadcaster.micSource = mic
        let blocks = Locked<[[Float]]>([])
        let timed = Locked<[(samples: [Float], time: Double)]>([])
        broadcaster.onSoundBlock = { samples, time in blocks.update { $0.append(samples) }; timed.update { $0.append((samples, time)) } }
        guard let feeder = Feeder(broadcaster: broadcaster) else { throw CheckFailure(description: "no frames") }
        feeder.start()
        defer { feeder.stop() }
        let removedAt = Locked<Double?>(nil)
        broadcaster.onMicRemoved = { time in removedAt.update { $0 = time } }
        broadcaster.goLive(micConfig(port: server.port))
        try expect(spin(timeout: 5) { broadcaster.states[.twitch] == .live }, "not live")
        spin(timeout: 1)
        mic.disconnect()
        try expect(spin(timeout: 2) { broadcaster.notice == "Microphone disconnected" }, "notice \(broadcaster.notice ?? "nil")")
        // When the mixer let go of the microphone, as the broadcaster's queue saw it.
        try expect(spin(timeout: 2) { removedAt.value != nil }, "microphone never removed from the mix")
        let gone = removedAt.value ?? 0
        try expect(broadcaster.micState == .unavailable("Stand-in"), "state \(broadcaster.micState)")
        let before = server.received.filter { $0.type == 8 }.count
        spin(timeout: 1.5)
        let after = server.received.filter { $0.type == 8 }.count
        try expect(broadcaster.states[.twitch] == .live && broadcaster.isLive, "no longer live")
        try expect(after - before >= 30, "only \(after - before) audio messages in 1.5 s")
        // The mixer holds back 0.1 s: sound queued from the microphone before it went is still waiting,
        // and has to be cut. These blocks end shortly before the microphone went, so they would carry it.
        let queued = timed.value.filter { $0.time >= gone - 0.09 && $0.time <= gone - 0.055 }.map(\.samples)
        try expect(!queued.isEmpty, "no block in the window")
        try expect(toneLevel(queued, frequency: 440) > 0.15, "game tone \(toneLevel(queued, frequency: 440))")
        try expect(toneLevel(queued, frequency: 1000) < 0.03, "queued mic tone kept \(toneLevel(queued, frequency: 1000))")
        let tail = Array(blocks.value.suffix(15))
        try expect(toneLevel(tail, frequency: 440) > 0.15, "game tone later \(toneLevel(tail, frequency: 440))")
        try expect(toneLevel(tail, frequency: 1000) < 0.03, "mic tone later \(toneLevel(tail, frequency: 1000))")
        try ends(broadcaster)
    }

    check("the voice-processing tap's first channel goes to both sides") {
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3),
              let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                                                     interleaved: false, channelLayout: layout),
                                            frameCapacity: 960) else { throw CheckFailure(description: "no buffer") }
        buffer.frameLength = 960
        for i in 0..<960 {
            buffer.floatChannelData![0][i] = Float(0.3 * sin(2 * Double.pi * 1000 * Double(i) / 48_000))
            buffer.floatChannelData![1][i] = 0
            buffer.floatChannelData![2][i] = 0.2
        }
        guard let mono = MicInput.firstChannel(of: buffer),
              let samples = PCMNormalizer().samples(from: mono) else { throw CheckFailure(description: "no conversion") }
        try expect(samples.count == 1920, "\(samples.count) values")
        var differ = 0, loud: Float = 0
        for i in 0..<960 {
            if samples[i * 2] != samples[i * 2 + 1] { differ += 1 }
            loud = max(loud, abs(samples[i * 2]))
        }
        try expect(differ == 0, "\(differ) frames differ between left and right")
        try expect(loud > 0.25, "peak \(loud)")
    }

    check("a stream without a microphone setting never starts one") {
        let server = try RTMPTestServer(behaviour: .accept)
        defer { server.stop() }
        let broadcaster = Broadcaster(device: device, library: library)
        let mic = FakeMic()
        broadcaster.micSource = mic
        guard let feeder = Feeder(broadcaster: broadcaster) else { throw CheckFailure(description: "no frames") }
        feeder.start()
        defer { feeder.stop() }
        broadcaster.goLive(oneSite(port: server.port, key: "abc"))
        try expect(spin(timeout: 5) { broadcaster.states[.twitch] == .live }, "not live")
        try expect(mic.startCalls.isEmpty, "microphone started")
        try expect(broadcaster.micState == .off, "state \(broadcaster.micState)")
        try ends(broadcaster)
    }

    check("the camera shows in its corner, and only when the stream asks for it") {
        let server = try RTMPTestServer(behaviour: .accept)
        defer { server.stop() }
        let broadcaster = Broadcaster(device: device, library: library)
        let camera = FakeCamera()
        camera.frame.update { $0 = solidFrame(width: 1280, height: 720, blue: 0, green: 255, red: 0) }
        broadcaster.cameraSource = camera
        let probe = CornerProbe(broadcaster)
        guard let feeder = Feeder(broadcaster: broadcaster) else { throw CheckFailure(description: "no frames") }
        feeder.start()
        defer { feeder.stop() }
        broadcaster.goLive(cameraConfig(port: server.port))
        try expect(spin(timeout: 5) { isGreen(probe.bottomRight) }, "corner never green")
        try expect(isGameGrey(probe.topLeft), "the other corner changed")
        try expect(camera.startCalls.count == 1 && camera.startCalls[0].deviceID == "usb-cam" && camera.startCalls[0].user == .stream,
                   "start calls \(camera.startCalls)")
        try ends(broadcaster)
        try expect(camera.stopCalls == [.stream], "stop calls \(camera.stopCalls)")

        // Camera off: the source has a picture, but the stream never asks for it.
        let off = Broadcaster(device: device, library: library)
        let idle = FakeCamera()
        idle.frame.update { $0 = solidFrame(width: 1280, height: 720, blue: 0, green: 255, red: 0) }
        off.cameraSource = idle
        let offProbe = CornerProbe(off)
        guard let offFeeder = Feeder(broadcaster: off) else { throw CheckFailure(description: "no frames") }
        offFeeder.start()
        defer { offFeeder.stop() }
        off.goLive(oneSite(port: server.port, key: "abc"))
        try expect(spin(timeout: 5) { off.states[.twitch] == .live }, "not live")
        try expect(spin(timeout: 5) { offProbe.bottomRight != nil }, "no canvas")
        spin(timeout: 0.5)
        try expect(isGameGrey(offProbe.bottomRight), "camera shown with the camera off")
        try expect(idle.startCalls.isEmpty, "camera started by itself: \(idle.startCalls)")
        try ends(off)
        try expect(idle.stopCalls.isEmpty, "camera stopped though never started: \(idle.stopCalls)")
    }

    check("changing the corner mid-stream moves the camera on the next frame") {
        let server = try RTMPTestServer(behaviour: .accept)
        defer { server.stop() }
        let broadcaster = Broadcaster(device: device, library: library)
        let camera = FakeCamera()
        camera.frame.update { $0 = solidFrame(width: 1280, height: 720, blue: 0, green: 255, red: 0) }
        broadcaster.cameraSource = camera
        let probe = CornerProbe(broadcaster)
        guard let feeder = Feeder(broadcaster: broadcaster) else { throw CheckFailure(description: "no frames") }
        feeder.start()
        defer { feeder.stop() }
        broadcaster.goLive(cameraConfig(port: server.port))
        try expect(spin(timeout: 5) { isGreen(probe.bottomRight) }, "corner never green")
        broadcaster.setCameraLayout(CameraLayout(corner: .topLeft, size: .medium))
        try expect(spin(timeout: 2) { isGreen(probe.topLeft) && isGameGrey(probe.bottomRight) },
                   "top left \(String(describing: probe.topLeft)), bottom right \(String(describing: probe.bottomRight))")
        try expect(broadcaster.states[.twitch] == .live, "no longer live")
        try ends(broadcaster)
    }

    check("a camera that returns no picture leaves the stream live with the game in the corner") {
        let server = try RTMPTestServer(behaviour: .accept)
        defer { server.stop() }
        let broadcaster = Broadcaster(device: device, library: library)
        let camera = FakeCamera()
        camera.frame.update { $0 = solidFrame(width: 1280, height: 720, blue: 0, green: 255, red: 0) }
        broadcaster.cameraSource = camera
        let probe = CornerProbe(broadcaster)
        guard let feeder = Feeder(broadcaster: broadcaster) else { throw CheckFailure(description: "no frames") }
        feeder.start()
        defer { feeder.stop() }
        broadcaster.goLive(cameraConfig(port: server.port))
        try expect(spin(timeout: 5) { isGreen(probe.bottomRight) }, "corner never green")
        camera.frame.update { $0 = nil }
        try expect(spin(timeout: 2) { isGameGrey(probe.bottomRight) }, "corner \(String(describing: probe.bottomRight))")
        try expect(broadcaster.states[.twitch] == .live && broadcaster.isLive, "no longer live")
        try expect(broadcaster.notice == nil, "notice \(broadcaster.notice ?? "nil")")
        // It comes back by itself.
        camera.frame.update { $0 = solidFrame(width: 1280, height: 720, blue: 0, green: 255, red: 0) }
        try expect(spin(timeout: 2) { isGreen(probe.bottomRight) }, "corner didn't come back")
        try ends(broadcaster)
    }

    check("a camera that is lost or denied leaves the stream live with a notice") {
        for (state, text) in [(CameraFeed.State.unavailable("Stand-in"), "Camera disconnected"),
                              (CameraFeed.State.denied, "Tween isn't allowed to use the camera")] {
            let server = try RTMPTestServer(behaviour: .accept)
            defer { server.stop() }
            let broadcaster = Broadcaster(device: device, library: library)
            let camera = FakeCamera()
            camera.frame.update { $0 = solidFrame(width: 1280, height: 720, blue: 0, green: 255, red: 0) }
            broadcaster.cameraSource = camera
            let probe = CornerProbe(broadcaster)
            guard let feeder = Feeder(broadcaster: broadcaster) else { throw CheckFailure(description: "no frames") }
            feeder.start()
            defer { feeder.stop() }
            broadcaster.goLive(cameraConfig(port: server.port))
            try expect(spin(timeout: 5) { isGreen(probe.bottomRight) }, "corner never green")
            // A device on its way out can still hand over a last picture: the corner must go anyway.
            camera.onState?(state)
            try expect(spin(timeout: 2) { broadcaster.notice == text }, "notice \(broadcaster.notice ?? "nil") for \(state)")
            try expect(spin(timeout: 2) { isGameGrey(probe.bottomRight) }, "corner \(String(describing: probe.bottomRight)) for \(state)")
            try expect(broadcaster.states[.twitch] == .live && broadcaster.isLive, "no longer live for \(state)")
            try ends(broadcaster)
        }
    }

    check("the preview and the stream each keep the camera running until both let go") {
        let begun = Locked<[String?]>([])
        let ended = Locked(0)
        let feed = CameraFeed(engine: (begin: { id in begun.update { $0.append(id) } }, end: { ended.update { $0 += 1 } }))
        feed.start(deviceID: "cam", for: .preview)
        feed.start(deviceID: "cam", for: .stream)
        feed.waitUntilIdle()
        try expect(begun.value == ["cam"], "session started \(begun.value)")
        feed.stop(for: .preview)
        feed.waitUntilIdle()
        try expect(ended.value == 0, "the camera stopped under the stream")
        feed.stop(for: .stream)
        feed.waitUntilIdle()
        try expect(ended.value == 1, "the last user leaving should stop it, stops \(ended.value)")
        // The other way round, and a stream alone.
        feed.start(deviceID: "cam", for: .stream)
        feed.start(deviceID: "cam", for: .preview)
        feed.stop(for: .stream)
        feed.waitUntilIdle()
        try expect(begun.value.count == 2 && ended.value == 1, "ending the stream stopped the preview's camera")
        feed.stop(for: .preview)
        feed.stop(for: .preview)
        feed.waitUntilIdle()
        try expect(ended.value == 2, "stops \(ended.value)")
    }

    check("a saved microphone that isn't there at go-live says none was found") {
        let server = try RTMPTestServer(behaviour: .accept)
        defer { server.stop() }
        let broadcaster = Broadcaster(device: device, library: library)
        let mic = FakeMic()
        mic.startState = .unavailable("usb-mic")
        broadcaster.micSource = mic
        guard let feeder = Feeder(broadcaster: broadcaster) else { throw CheckFailure(description: "no frames") }
        feeder.start()
        defer { feeder.stop() }
        broadcaster.goLive(micConfig(port: server.port))
        try expect(spin(timeout: 3) { broadcaster.notice == "No microphone found" }, "notice \(broadcaster.notice ?? "nil")")
        try expect(broadcaster.isLive, "not live")
        try ends(broadcaster)
    }

    check("a saved key that can't be read is named as such") {
        let broadcaster = Broadcaster(device: device, library: library)
        broadcaster.goLive(StreamConfig(sites: [StreamSiteConfig(site: .youtube, server: "rtmp://127.0.0.1:1935/live", key: "",
                                                                 quality: .p1080, bitrate: 0, keyUnreadable: true)],
                                        gameVolume: 1, camera: nil, mic: nil))
        spin(timeout: 0.1)
        try expect(!broadcaster.isLive, "went live without a key")
        try expect(broadcaster.notice == "Tween couldn't read the saved YouTube key", "notice \(broadcaster.notice ?? "nil")")
    }

    check("going live clears a failure left from an earlier stream on a site now off") {
        let refusing = try RTMPTestServer(behaviour: .rejectPublish(description: "bad key"))
        let accepting = try RTMPTestServer(behaviour: .accept)
        defer { refusing.stop(); accepting.stop() }
        let broadcaster = Broadcaster(device: device, library: library)
        guard let feeder = Feeder(broadcaster: broadcaster) else { throw CheckFailure(description: "no frames") }
        feeder.start()
        defer { feeder.stop() }
        broadcaster.goLive(oneSite(.twitch, port: refusing.port, key: "made-up-a"))
        try expect(spin(timeout: 5) { if case .failed = broadcaster.states[.twitch] { return true } else { return false } },
                   "twitch \(String(describing: broadcaster.states[.twitch]))")
        try expect(spin(timeout: 2) { !broadcaster.isLive }, "still live")
        broadcaster.goLive(oneSite(.youtube, port: accepting.port, key: "made-up-b"))
        try expect(broadcaster.states[.twitch] == .off, "twitch still \(String(describing: broadcaster.states[.twitch]))")
        try expect(spin(timeout: 5) { broadcaster.states[.youtube] == .live }, "youtube not live")
        try ends(broadcaster)
    }

    check("an encoder that can't be brought back fails its site, and the other site streams on") {
        let a = try RTMPTestServer(behaviour: .accept), b = try RTMPTestServer(behaviour: .accept)
        defer { a.stop(); b.stop() }
        let broadcaster = Broadcaster(device: device, library: library)
        // Two bitrates, so two encoders; Twitch's is made first. Limit 0.5 s, rebuilds every 0.1 s.
        let made = Locked<[StreamVideoEncoder]>([])
        broadcaster.onEncoder = { encoder in
            if made.value.isEmpty {
                encoder.recoveryTimeScale = 0.05
                encoder.refusesRebuildForChecks = true
            }
            made.update { $0.append(encoder) }
        }
        guard let feeder = Feeder(broadcaster: broadcaster) else { throw CheckFailure(description: "no frames") }
        feeder.start()
        defer { feeder.stop() }
        broadcaster.goLive(bothSites(site(.twitch, bitrate: 6_000_000, port: a.port, key: "made-up-a"),
                                     site(.youtube, bitrate: 8_000_000, port: b.port, key: "made-up-b")))
        try expect(spin(timeout: 5) { broadcaster.states[.twitch] == .live && broadcaster.states[.youtube] == .live },
                   "not live: \(broadcaster.states) \(broadcaster.notice ?? "")")
        try expect(made.value.count == 2, "\(made.value.count) encoders")
        made.value.first?.breakSessionForChecks()
        try expect(spin(timeout: 3) { broadcaster.states[.twitch] == .failed("The video encoder stopped working") },
                   "twitch \(String(describing: broadcaster.states[.twitch]))")
        let before = b.received.filter { $0.type == 9 }.count
        spin(timeout: 0.5)
        let after = b.received.filter { $0.type == 9 }.count
        try expect(after >= before + 20, "youtube video \(before) -> \(after)")
        try expect(broadcaster.states[.youtube] == .live && broadcaster.isLive, "youtube \(String(describing: broadcaster.states[.youtube]))")
        try ends(broadcaster)
    }

    check("a stream that finds no camera says so, apart from a camera that was lost") {
        let server = try RTMPTestServer(behaviour: .accept)
        defer { server.stop() }
        let broadcaster = Broadcaster(device: device, library: library)
        let camera = FakeCamera()
        camera.startState = .unavailable("No camera")
        broadcaster.cameraSource = camera
        guard let feeder = Feeder(broadcaster: broadcaster) else { throw CheckFailure(description: "no frames") }
        feeder.start()
        defer { feeder.stop() }
        broadcaster.goLive(cameraConfig(port: server.port))
        try expect(spin(timeout: 3) { broadcaster.notice == "No camera found" }, "notice \(broadcaster.notice ?? "nil")")
        try expect(broadcaster.states[.twitch] != nil && broadcaster.isLive, "not live")
        try ends(broadcaster)
    }
}
