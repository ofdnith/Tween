import Combine
import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore

enum StreamSite: String, CaseIterable, Identifiable {
    case twitch, youtube

    var id: String { rawValue }

    var label: String {
        switch self {
        case .twitch: return "Twitch"
        case .youtube: return "YouTube"
        }
    }

    var defaultServer: String {
        switch self {
        case .twitch: return "rtmps://live.twitch.tv/app"
        case .youtube: return "rtmps://a.rtmps.youtube.com/live2"
        }
    }

    /// Bits per second.
    func defaultBitrate(_ quality: StreamQuality) -> Int {
        switch (self, quality) {
        case (.twitch, _): return 6_000_000
        case (.youtube, .p1080): return 9_000_000
        case (.youtube, .p1440): return 18_000_000
        case (.youtube, .p2160): return 35_000_000
        }
    }
}

struct StreamSiteConfig {
    let site: StreamSite
    let server: String
    let key: String
    /// The canvas asked for; a smaller one is used when the picture or the hardware can't fill it.
    let quality: StreamQuality
    /// Bits per second; 0 = the site's default for the canvas in use.
    let bitrate: Int
    /// A key is saved but its file couldn't be read; `key` is then empty.
    var keyUnreadable = false
}

struct StreamConfig {
    var sites: [StreamSiteConfig]
    var gameVolume: Float
    var camera: (deviceID: String?, layout: CameraLayout)?
    var mic: (deviceID: String?, volume: Float, removeGameSound: Bool)?
}

/// Sends the finished picture and the game's sound to the streaming sites. Like `Recorder`: control
/// on the main thread, work on its own queue. A 60 Hz timer there takes the newest frame (or the
/// last one again), composes it per canvas, encodes it once per canvas and bitrate and sends it
/// with the mixed sound to every site. A site that loses its connection reconnects on its own.
final class Broadcaster: ObservableObject {
    enum SiteState: Equatable { case off, connecting, live, reconnecting(Int), failed(String) }

    static let pictureTimeout = 5.0
    /// A site's info line while its connection is throwing video away.
    static let slowConnectionText = "Connection too slow"

    @Published private(set) var states: [StreamSite: SiteState] = Dictionary(uniqueKeysWithValues: StreamSite.allCases.map { ($0, .off) })
    @Published private(set) var startedAt: Date?
    @Published private(set) var notice: String? {
        didSet { noticeChanged() }
    }
    /// How long a notice stays up. Checks only: shortened.
    var noticeDuration = 6.0
    private var noticeSerial = 0
    /// Bitrate sent and canvas per site, shown next to its state.
    @Published private(set) var info: [StreamSite: String] = [:]
    @Published private(set) var micMuted = false
    @Published private(set) var micState: MicInput.State = .off
    /// Checks only: stands in for the microphone. Set before `goLive`.
    var micSource: MicSource = MicInput()
    /// Checks only: scales reconnect pauses and timeouts. Set before `goLive`.
    var timeScale = 1.0

    var isLive: Bool {
        states.values.contains { state in
            switch state {
            case .connecting, .live, .reconnecting: return true
            case .off, .failed: return false
            }
        }
    }

    /// Main thread: turn the renderer's frame hand-over on or off.
    var onWantsFrames: ((Bool) -> Void)?
    /// Main thread: ask the source for its sound while live.
    var onWantsAudio: ((Bool) -> Void)?
    /// The webcam, shared with the preview in Settings.
    let camera = CameraFeed()
    /// Checks only: stands in for the webcam. Set before `goLive`.
    var cameraSource: CameraSource
    /// Checks only: each composed canvas before it is encoded, on the queue. Set before `goLive`.
    var onCanvas: ((CVPixelBuffer) -> Void)?
    /// Checks only: each mixed sound block (interleaved stereo, host time of its start) before it is encoded, on the queue.
    /// Set before `goLive`.
    var onSoundBlock: (([Float], Double) -> Void)?
    /// Checks only: each video encoder as it is made, on the queue. Set before `goLive`.
    var onEncoder: ((StreamVideoEncoder) -> Void)?
    /// Checks only: the host time at which a lost microphone's sound is taken out of the mix, on the queue.
    var onMicRemoved: ((Double) -> Void)?

    private let queue = DispatchQueue(label: "tween.broadcaster", qos: .userInitiated)
    private let compositor: StreamCompositor?

    // main thread only
    private var ending = false
    /// Tells a microphone's reports from this stream apart from those of an earlier one.
    private var micSession = 0
    /// Tells a camera's reports from this stream apart from those of an earlier one.
    private var cameraSession = 0
    private var cameraStarted = false
    /// The camera ran during this stream, so a later loss is a disconnect rather than none found.
    private var cameraSeen = false
    /// The same for the microphone.
    private var micSeen = false
    /// Completions of `end` calls made while an end was already running.
    private var endCompletions: [() -> Void] = []

    // lock
    private let lock = NSLock()
    private var accepting = false
    private var newest: CVPixelBuffer?

    // queue only
    private var running = false
    private var session = 0
    private var config: StreamConfig?
    /// nil = no corner picture: the camera is off for this stream, or was lost.
    private var cameraLayout: CameraLayout?
    private var timer: DispatchSourceTimer?
    private var pictureDeadline = 0.0
    private var lastFrame: CVPixelBuffer?
    private var sitesStarted = false
    private var sites: [StreamSite: BroadcastSite] = [:]
    private var encoders: [EncoderKey: SharedEncoder] = [:]
    /// Each site's canvas note ("the picture is smaller than …"), for its info line.
    private var notes: [StreamSite: String] = [:]
    private var nextInfo = 0.0
    private var timeScaleInUse = 1.0
    private var composing: Set<StreamQuality> = []
    private var mixer: StreamMixer?
    private let gameNormalizer = PCMNormalizer()
    private var audioEncoder: StreamAudioEncoder?

    init(device: MTLDevice, library: MTLLibrary) {
        cameraSource = camera
        compositor = try? StreamCompositor(device: device, library: library)
    }

    // MARK: - Main thread

    func goLive(_ config: StreamConfig) {
        guard !isLive, !ending else { return }
        guard !config.sites.isEmpty else { return show("Turn on Twitch or YouTube in Settings") }
        if let unreadable = config.sites.first(where: \.keyUnreadable) {
            return show("Tween couldn't read the saved \(unreadable.site.label) key")
        }
        if let missing = config.sites.first(where: { $0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return show("Add a \(missing.site.label) stream key in Settings")
        }
        guard compositor != nil else { return show("Streaming isn't available on this Mac") }
        notice = nil
        info = [:]
        startedAt = nil
        // A failure line left from an earlier stream on a site that is now off must go too.
        for site in StreamSite.allCases where states[site] != .off { states[site] = .off }
        for site in config.sites { states[site.site] = .connecting }
        onWantsFrames?(true)
        onWantsAudio?(true)
        lock.lock()
        accepting = true
        newest = nil
        lock.unlock()
        let timeScale = self.timeScale
        queue.async { self.start(config, timeScale: timeScale) }
        startMic(config.mic)
        startCamera(config.camera)
    }

    /// Corner and size apply on the next frame, also while live.
    func setCameraLayout(_ layout: CameraLayout) {
        queue.async {
            // Only while the stream has a camera that hasn't been lost.
            guard self.cameraLayout != nil else { return }
            self.cameraLayout = layout
        }
    }

    /// Muting is for a live stream: it starts unmuted and does nothing otherwise.
    func toggleMicMute() {
        switch micState {
        case .running, .plainFallback, .needsPermission: break
        case .off, .denied, .unavailable: return
        }
        guard isLive else { return }
        micMuted.toggle()
        let muted = micMuted
        queue.async { self.mixer?.micMuted = muted }
    }

    /// Ends every site cleanly. `completion` runs on the main thread once all are closed.
    func end(completion: (() -> Void)? = nil) {
        if ending {
            // Quitting during an end must still wait for the sites to close.
            if let completion { endCompletions.append(completion) }
            return
        }
        guard isLive else {
            if let completion { DispatchQueue.main.async(execute: completion) }
            return
        }
        ending = true
        stopTakingInput()
        queue.async {
            let open = self.stopSession()
            let group = DispatchGroup()
            for site in open {
                group.enter()
                site.close { group.leave() }
            }
            group.notify(queue: .main) {
                self.ending = false
                for site in StreamSite.allCases where self.states[site] != .off { self.states[site] = .off }
                self.startedAt = nil
                let waiting = self.endCompletions
                self.endCompletions = []
                completion?()
                waiting.forEach { $0() }
            }
        }
    }

    // MARK: - Any thread

    /// The finished picture from the renderer. Only stored: the timer takes it.
    func handle(frame: CVPixelBuffer, at hostTime: CFTimeInterval) {
        lock.lock()
        if accepting { newest = frame }
        lock.unlock()
    }

    /// Game sound. `hostTime` is given when the buffer's own timestamp is on another clock.
    func handle(gameAudio sampleBuffer: CMSampleBuffer, at hostTime: CMTime? = nil) {
        guard isAccepting else { return }
        queue.async {
            guard self.running, self.mixer != nil,
                  let samples = self.gameNormalizer.samples(from: sampleBuffer), !samples.isEmpty else { return }
            let time = (hostTime ?? CMSampleBufferGetPresentationTimeStamp(sampleBuffer)).seconds
            self.mixer?.push(.game, samples: samples, hostTime: time)
        }
    }

    /// Microphone sound, already 48 kHz interleaved stereo, starting at `hostTime` on the host clock.
    func handle(micSamples: [Float], hostTime: Double) {
        guard isAccepting else { return }
        queue.async {
            guard self.running else { return }
            self.mixer?.push(.mic, samples: micSamples, hostTime: hostTime)
        }
    }

    private var isAccepting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return accepting
    }

    // MARK: - Main thread helpers

    /// A short note under the go-live button and over the video, cleared after `noticeDuration`.
    func show(_ text: String) {
        notice = text
    }

    /// A notice clears itself, so the overlay is not kept on screen by a message nobody needs any more.
    /// A newer notice restarts the time; the serial stops an older timer clearing it.
    private func noticeChanged() {
        noticeSerial += 1
        guard notice != nil else { return }
        let serial = noticeSerial
        DispatchQueue.main.asyncAfter(deadline: .now() + noticeDuration) { [weak self] in
            guard let self, self.noticeSerial == serial else { return }
            self.notice = nil
        }
    }

    /// Releases the frame sink and the sound at once; the stream itself closes after.
    private func stopTakingInput() {
        lock.lock()
        accepting = false
        newest = nil
        lock.unlock()
        onWantsFrames?(false)
        onWantsAudio?(false)
        stopMic()
        stopCamera()
    }

    private func startMic(_ mic: (deviceID: String?, volume: Float, removeGameSound: Bool)?) {
        micSession += 1
        micMuted = false
        micSeen = false
        guard let mic else { return micState = .off }
        let session = micSession
        micSource.onSamples = { [weak self] samples, hostTime in self?.handle(micSamples: samples, hostTime: hostTime) }
        micSource.onState = { [weak self] state in
            DispatchQueue.main.async { self?.micChanged(state, session: session) }
        }
        micSource.start(deviceID: mic.deviceID, removeGameSound: mic.removeGameSound)
    }

    private func stopMic() {
        micSession += 1
        micSource.onSamples = nil
        micSource.onState = nil
        micSource.stop()
        micState = .off
        micMuted = false
    }

    /// The stream goes on without the microphone when it goes away or isn't allowed.
    private func micChanged(_ state: MicInput.State, session: Int) {
        guard session == micSession else { return }
        micState = state
        switch state {
        case .running, .plainFallback:
            micSeen = true
            return
        case .unavailable:
            notice = micSeen ? "Microphone disconnected" : "No microphone found"
        case .denied:
            notice = "Tween isn't allowed to use the microphone"
        default:
            return
        }
        micMuted = false
        // Sound still arriving from it would start the mic's track again.
        micSource.onSamples = nil
        queue.async {
            self.mixer?.remove(.mic)
            self.onMicRemoved?(CACurrentMediaTime())
        }
    }

    private func startCamera(_ camera: (deviceID: String?, layout: CameraLayout)?) {
        cameraSession += 1
        cameraSeen = false
        guard let camera else { return }
        cameraStarted = true
        let session = cameraSession
        cameraSource.onState = { [weak self] state in
            DispatchQueue.main.async { self?.cameraChanged(state, session: session) }
        }
        cameraSource.start(deviceID: camera.deviceID, for: .stream)
    }

    /// Lets go of the stream's hold only: the Settings preview may still be using the camera.
    private func stopCamera() {
        cameraSession += 1
        cameraSource.onState = nil
        guard cameraStarted else { return }
        cameraStarted = false
        cameraSource.stop(for: .stream)
    }

    /// The stream goes on without the corner picture when the camera goes away or isn't allowed.
    private func cameraChanged(_ state: CameraFeed.State, session: Int) {
        guard session == cameraSession else { return }
        switch state {
        case .unavailable:
            notice = cameraSeen ? "Camera disconnected" : "No camera found"
        case .denied:
            notice = "Tween isn't allowed to use the camera"
        case .running:
            cameraSeen = true
            return
        default:
            return
        }
        // A last picture from a device on its way out must not stay on screen.
        queue.async { self.cameraLayout = nil }
    }

    private func publish(_ state: SiteState, for site: StreamSite) {
        DispatchQueue.main.async {
            self.states[site] = state
            if state == .live, self.startedAt == nil { self.startedAt = Date() }
        }
    }

    // MARK: - Queue

    private func start(_ config: StreamConfig, timeScale: Double) {
        session += 1
        self.config = config
        cameraLayout = config.camera?.layout
        timeScaleInUse = timeScale
        running = true
        let now = CACurrentMediaTime()
        pictureDeadline = now + Self.pictureTimeout
        lastFrame = nil
        sitesStarted = false
        composing = []
        var mixer = StreamMixer(startHostTime: now)
        mixer.volume[.game] = config.gameVolume
        mixer.micMuted = false
        if let mic = config.mic { mixer.volume[.mic] = mic.volume }
        self.mixer = mixer
        audioEncoder = StreamAudioEncoder()
        guard audioEncoder != nil else { return giveUp("Couldn't start the sound encoder") }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// Stops the timer and forgets the session. Returns the sites still open, for the caller to close.
    private func stopSession() -> [BroadcastSite] {
        guard running else { return [] }
        running = false
        timer?.cancel()
        timer = nil
        // The sound still held back by the mixer's delay belongs to the pictures already sent.
        pullSound(now: CACurrentMediaTime() + StreamMixer.delay)
        // Frames finished by `invalidate` are queued behind this block, so they go out before the sites close.
        for shared in encoders.values { shared.encoder.invalidate() }
        encoders = [:]
        let open = Array(sites.values)
        sites = [:]
        notes = [:]
        config = nil
        cameraLayout = nil
        lastFrame = nil
        mixer = nil
        audioEncoder = nil
        composing = []
        return open
    }

    /// Ends the session from the queue, with `text` (if any) as the notice. Sites already failed keep their state.
    /// `failed` is set in the same main-thread update as the notice.
    private func giveUp(_ text: String?, failed: (site: StreamSite, text: String)? = nil) {
        for site in stopSession() { site.close {} }
        DispatchQueue.main.async {
            if !self.ending { self.stopTakingInput() }
            if let failed { self.states[failed.site] = .failed(failed.text) }
            if let text { self.notice = text }
            for (site, state) in self.states {
                switch state {
                case .connecting, .live, .reconnecting: self.states[site] = .off
                case .off, .failed: break
                }
            }
            if !self.isLive { self.startedAt = nil }
        }
    }

    private func tick() {
        guard running, let config else { return }
        let now = CACurrentMediaTime()
        lock.lock()
        if let frame = newest {
            lastFrame = frame
            newest = nil
        }
        lock.unlock()

        if !sitesStarted {
            guard let frame = lastFrame else {
                if now >= pictureDeadline { giveUp("No picture to stream") }
                return
            }
            startSites(config, frameHeight: CVPixelBufferGetHeight(frame))
            guard running else { return }
        }

        pullSound(now: now)
        if now >= nextInfo {
            nextInfo = now + 1
            updateInfo(now: now)
        }

        guard let frame = lastFrame, let compositor else { return }
        let session = self.session
        // Only canvases some publishing site is waiting for.
        let canvases = Set(encoders.filter { $0.value.wantsFrames }.map(\.key.quality))
        let camera = cameraLayout.flatMap { layout in cameraSource.newestFrame().map { ($0, layout) } }
        for quality in canvases where !composing.contains(quality) {
            composing.insert(quality)
            compositor.compose(game: frame, camera: camera?.0, layout: camera?.1, canvas: quality.size) { [weak self] canvas in
                guard let self else { return }
                self.queue.async { self.composed(canvas, quality: quality, at: now, session: session) }
            }
        }
    }

    private func composed(_ canvas: CVPixelBuffer?, quality: StreamQuality, at time: Double, session: Int) {
        guard running, session == self.session else { return }
        composing.remove(quality)
        guard let canvas else { return }
        onCanvas?(canvas)
        var failed: [SharedEncoder] = []
        for (key, shared) in encoders where key.quality == quality && shared.wantsFrames {
            // A forced keyframe the rate guard drops stays pending in the encoder.
            let force = shared.keyframeWanted
            shared.keyframeWanted = false
            shared.encoder.encode(canvas, at: CMTime(seconds: time, preferredTimescale: 1_000_000_000), forceKeyframe: force)
            // The encoder rebuilds a broken session itself; this is when that kept failing.
            if shared.encoder.hasFailed { failed.append(shared) }
        }
        // Its sites fail; sites on other encoders stream on.
        for shared in failed {
            for site in shared.receivers.sites { site.stop(because: "The video encoder stopped working") }
        }
    }

    private func updateInfo(now: Double) {
        var lines: [StreamSite: String] = [:]
        for (site, broadcastSite) in sites {
            let dropped = encoders[EncoderKey(broadcastSite)]?.encoder.droppedFrames ?? 0
            let rate = broadcastSite.sentBitrate(now: now) ?? Double(broadcastSite.bitrate)
            lines[site] = Self.infoLine(sentBitrate: rate, quality: broadcastSite.quality, note: notes[site],
                                        droppedFrames: dropped, tooSlow: broadcastSite.isTooSlow)
        }
        DispatchQueue.main.async { self.info = lines }
    }

    /// One site's info line: what is actually sent, or why it can't be.
    static func infoLine(sentBitrate: Double, quality: StreamQuality, note: String?, droppedFrames: Int, tooSlow: Bool) -> String {
        if tooSlow { return slowConnectionText }
        var text = String(format: "%.1f Mbps · %dp", sentBitrate / 1_000_000, quality.rawValue) + (note ?? "")
        if droppedFrames > 0 { text += " · \(droppedFrames) frame\(droppedFrames == 1 ? "" : "s") dropped" }
        return text
    }

    private func pullSound(now: Double) {
        guard let blocks = mixer?.pull(now: now), let audioEncoder else { return }
        for block in blocks {
            onSoundBlock?(block.samples, block.hostTime)
            // Encoded even before any site is live, so the encoder is primed by then.
            guard let aac = audioEncoder.encode(block.samples) else { continue }
            let body = FLV.aacFrame(aac)
            for site in sites.values { site.send(audio: body, hostTime: block.hostTime) }
        }
    }

    /// Picks each site's canvas for the first picture and starts its connection.
    private func startSites(_ config: StreamConfig, frameHeight: Int) {
        sitesStarted = true
        let session = self.session
        var anyEncodable = false
        /// The last site that couldn't start and why, for the notice when none could.
        var lastFailure: String?
        for siteConfig in config.sites {
            let site = siteConfig.site
            guard let quality = StreamQuality.choose(wanted: siteConfig.quality, frameHeight: frameHeight,
                                                     hardware: StreamVideoEncoder.hardwareAvailable) else {
                publish(.failed("This Mac can't encode the stream"), for: site)
                continue
            }
            anyEncodable = true
            let bitrate = siteConfig.bitrate > 0 ? siteConfig.bitrate : site.defaultBitrate(quality)
            let broadcastSite: BroadcastSite
            do {
                broadcastSite = try BroadcastSite(config: siteConfig, quality: quality, bitrate: bitrate, queue: queue,
                                                  timeScale: timeScaleInUse)
            } catch {
                let text = (error as? BroadcastSite.StartError)?.text ?? "Couldn't start"
                publish(.failed(text), for: site)
                lastFailure = "\(site.label): \(text)"
                continue
            }
            let key = EncoderKey(broadcastSite)
            if encoders[key] == nil {
                guard let shared = makeEncoder(key) else {
                    publish(.failed("Couldn't start the video encoder"), for: site)
                    lastFailure = "\(site.label): Couldn't start the video encoder"
                    continue
                }
                encoders[key] = shared
            }
            encoders[key]?.receivers.sites.append(broadcastSite)
            if quality.rawValue < siteConfig.quality.rawValue {
                let asked = siteConfig.quality
                notes[site] = StreamVideoEncoder.hardwareAvailable(width: asked.size.width, height: asked.size.height)
                    ? " (the picture is smaller than \(asked.rawValue)p)" : " (this Mac can't encode \(asked.rawValue)p)"
            }
            broadcastSite.onState = { [weak self] state in self?.siteChanged(site, state, session: session) }
            broadcastSite.onNeedsKeyframe = { [weak self] in self?.encoders[key]?.keyframeWanted = true }
            sites[site] = broadcastSite
        }
        updateInfo(now: CACurrentMediaTime())
        nextInfo = CACurrentMediaTime() + 1
        if !anyEncodable { return giveUp("Streaming isn't available on this Mac") }
        if sites.isEmpty { return giveUp(lastFailure.map { "The stream ended. \($0)" }) }
        // Started once all are set up, so a site that fails at once can't end the others' session early.
        for site in sites.values { site.start() }
    }

    /// One encoder for a canvas and bitrate. Its frames go, on the queue, to the sites it holds then:
    /// a site that ended or has no connection drops them, and frames finished after the session ended still flush.
    private func makeEncoder(_ key: EncoderKey) -> SharedEncoder? {
        let receivers = SiteList()
        let size = key.quality.size
        // The encoder calls back on a VideoToolbox thread; the sites belong to the queue.
        guard let encoder = StreamVideoEncoder(width: size.width, height: size.height, bitrate: key.bitrate, frameRate: 60,
                                               onFrame: { [queue] frame in
            queue.async { receivers.sites.forEach { $0.encoded(frame) } }
        }) else { return nil }
        onEncoder?(encoder)
        return SharedEncoder(encoder: encoder, receivers: receivers)
    }

    private func remove(_ site: StreamSite) {
        guard let broadcastSite = sites.removeValue(forKey: site) else { return }
        notes[site] = nil
        let key = EncoderKey(broadcastSite)
        guard let shared = encoders[key] else { return }
        shared.receivers.sites.removeAll { $0 === broadcastSite }
        if shared.receivers.sites.isEmpty {
            shared.encoder.invalidate()
            encoders[key] = nil
        }
    }

    private func siteChanged(_ site: StreamSite, _ state: BroadcastSite.State, session: Int) {
        guard running, session == self.session, sites[site] != nil else { return }
        switch state {
        case .connecting:
            break
        case .live:
            publish(.live, for: site)
        case .reconnecting(let attempt):
            publish(.reconnecting(attempt), for: site)
        case .failed(let text):
            remove(site)
            if sites.isEmpty {
                giveUp("The stream ended. \(site.label): \(text)", failed: (site, text))
            } else {
                publish(.failed(text), for: site)
            }
        case .closed:
            remove(site)
            publish(.off, for: site)
            if sites.isEmpty { giveUp(nil) }
        }
    }
}

private struct EncoderKey: Hashable {
    let quality: StreamQuality
    let bitrate: Int

    init(_ site: BroadcastSite) {
        quality = site.quality
        bitrate = site.bitrate
    }
}

/// The sites an encoder's frames go to. Its own object so the encoder's callback can hold it
/// without holding the encoder, and still deliver what `invalidate` flushes after the session ends.
private final class SiteList {
    var sites: [BroadcastSite] = []
}

/// One video encoder and the sites that share it. Queue only.
private final class SharedEncoder {
    let encoder: StreamVideoEncoder
    let receivers: SiteList
    /// A site's new connection needs a keyframe; the next frame is encoded as one.
    var keyframeWanted = false

    init(encoder: StreamVideoEncoder, receivers: SiteList) {
        self.encoder = encoder
        self.receivers = receivers
    }

    var wantsFrames: Bool { receivers.sites.contains { $0.wantsFrames } }
}
