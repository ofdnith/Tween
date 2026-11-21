import Foundation
import Combine

enum ScalingMode: String, CaseIterable, Identifiable {
    case fit, fill, stretch

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fit: return "Fit"
        case .fill: return "Fill"
        case .stretch: return "Stretch"
        }
    }

    var next: ScalingMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// How much of the stats panel sits over the video.
enum StatsMode: String, CaseIterable, Identifiable {
    case off, compact, full

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .compact: return "Compact"
        case .full: return "Full"
        }
    }

    var next: StatsMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

enum VideoSource: String, CaseIterable, Identifiable {
    case captureCard, window

    var id: String { rawValue }

    var label: String {
        switch self {
        case .captureCard: return "Capture card"
        case .window: return "Remote Play app"
        }
    }
}

/// User preferences, persisted to UserDefaults on every change. Main thread only.
final class AppSettings: ObservableObject {
    private enum Key {
        static let source = "source"
        static let windowApp = "window.app"
        static let windowTitle = "window.title"
        static let windowHideTitleBar = "window.hideTitleBar"
        static let windowSharpness = "window.sharpness"
        static let deviceID = "capture.deviceID"
        static let formatID = "capture.formatID"
        static let frameRate = "capture.frameRate"
        static let displayID = "output.displayID"
        static let scalingMode = "output.scalingMode"
        static let displaySync = "output.displaySync"
        static let showOverlay = "overlay.visible"
        static let statsMode = "overlay.mode"
        static let upscaling = "enhance.upscaling"
        static let upscaler = "enhance.upscaler"
        static let sharpening = "enhance.sharpening"
        static let sharpness = "enhance.sharpness"
        static let frameGeneration = "enhance.frameGeneration"
        static let frameGenerationFast = "enhance.frameGenerationFast"
        static let frameGenerationSteady = "enhance.frameGenerationSteady"
        static let recordStats = "recording.includeStats"
        static let audioEnabled = "audio.enabled"
        static let audioDeviceID = "audio.deviceID"
        static let audioVolume = "audio.volume"
        static func streamEnabled(_ site: StreamSite) -> String { "stream.\(site.rawValue).enabled" }
        static func streamServer(_ site: StreamSite) -> String { "stream.\(site.rawValue).server" }
        static func streamBitrate(_ site: StreamSite) -> String { "stream.\(site.rawValue).bitrate" }
        static let streamYouTubeQuality = "stream.youtube.quality"
        static let streamGameVolume = "stream.gameVolume"
        static let micEnabled = "stream.mic.enabled"
        static let micDeviceID = "stream.mic.deviceID"
        static let micVolume = "stream.mic.volume"
        static let micRemoveGameSound = "stream.mic.removeGameSound"
        static let cameraEnabled = "stream.camera.enabled"
        static let cameraDeviceID = "stream.camera.deviceID"
        static let cameraCorner = "stream.camera.corner"
        static let cameraSize = "stream.camera.size"
    }

    private let defaults: UserDefaults

    @Published var source: VideoSource { didSet { defaults.set(source.rawValue, forKey: Key.source) } }
    /// nil = automatic (first window of a known streaming app).
    @Published var windowApp: String? { didSet { defaults.set(windowApp, forKey: Key.windowApp) } }
    @Published var windowTitle: String? { didSet { defaults.set(windowTitle, forKey: Key.windowTitle) } }
    @Published var windowHideTitleBar: Bool { didSet { defaults.set(windowHideTitleBar, forKey: Key.windowHideTitleBar) } }
    /// Streams are compressed, so they get gentler sharpening than a capture card by default.
    @Published var windowSharpness: Double { didSet { defaults.set(windowSharpness, forKey: Key.windowSharpness) } }

    /// `nil` = pick the first external capture device.
    @Published var deviceID: String? { didSet { defaults.set(deviceID, forKey: Key.deviceID) } }
    /// `nil` = 1920×1080, YUY2 preferred.
    @Published var formatID: String? { didSet { defaults.set(formatID, forKey: Key.formatID) } }
    /// 0 = highest rate the format supports.
    @Published var frameRate: Double { didSet { defaults.set(frameRate, forKey: Key.frameRate) } }
    /// 0 = automatic (first external display, else the main display).
    @Published var displayID: UInt32 { didSet { defaults.set(Int(displayID), forKey: Key.displayID) } }
    @Published var scalingMode: ScalingMode { didSet { defaults.set(scalingMode.rawValue, forKey: Key.scalingMode) } }
    @Published var displaySyncEnabled: Bool { didSet { defaults.set(displaySyncEnabled, forKey: Key.displaySync) } }
    @Published var statsMode: StatsMode { didSet { defaults.set(statsMode.rawValue, forKey: Key.statsMode) } }
    @Published var upscalingEnabled: Bool { didSet { defaults.set(upscalingEnabled, forKey: Key.upscaling) } }
    /// Preferred method; MetalFX silently falls back to Lanczos where unsupported.
    @Published var upscaler: Upscaler.Kind { didSet { defaults.set(upscaler.rawValue, forKey: Key.upscaler) } }
    @Published var sharpeningEnabled: Bool { didSet { defaults.set(sharpeningEnabled, forKey: Key.sharpening) } }
    /// 0…1.
    @Published var sharpness: Double { didSet { defaults.set(sharpness, forKey: Key.sharpness) } }
    /// On by default in Tween: 30→60 is what the app is for. It adds latency.
    @Published var frameGenerationEnabled: Bool { didSet { defaults.set(frameGenerationEnabled, forKey: Key.frameGeneration) } }
    /// In-between frames at 720p (less delay) instead of 1080p.
    @Published var frameGenerationFast: Bool { didSet { defaults.set(frameGenerationFast, forKey: Key.frameGenerationFast) } }
    /// Trade up to a refresh of delay for steadier motion on a stream that delivers frames unevenly.
    @Published var frameGenerationSteady: Bool { didSet { defaults.set(frameGenerationSteady, forKey: Key.frameGenerationSteady) } }
    /// Draw the stats panel into screenshots and recordings.
    @Published var recordStats: Bool { didSet { defaults.set(recordStats, forKey: Key.recordStats) } }
    @Published var audioEnabled: Bool { didSet { defaults.set(audioEnabled, forKey: Key.audioEnabled) } }
    /// nil = the audio of the active capture device.
    @Published var audioDeviceID: String? { didSet { defaults.set(audioDeviceID, forKey: Key.audioDeviceID) } }
    /// 0…1.
    @Published var audioVolume: Double { didSet { defaults.set(audioVolume, forKey: Key.audioVolume) } }
    /// Stream keys are not settings: they live in files of their own (`StreamKeyStore`).
    @Published var streamEnabled: [StreamSite: Bool] {
        didSet { StreamSite.allCases.forEach { defaults.set(streamEnabled[$0] ?? false, forKey: Key.streamEnabled($0)) } }
    }
    /// Empty = the site's default server.
    @Published var streamServer: [StreamSite: String] {
        didSet { StreamSite.allCases.forEach { defaults.set(streamServer[$0] ?? "", forKey: Key.streamServer($0)) } }
    }
    /// Bits per second; 0 = the site's default for the canvas.
    @Published var streamBitrate: [StreamSite: Int] {
        didSet { StreamSite.allCases.forEach { defaults.set(streamBitrate[$0] ?? 0, forKey: Key.streamBitrate($0)) } }
    }
    @Published var streamYouTubeQuality: StreamQuality {
        didSet { defaults.set(streamYouTubeQuality.rawValue, forKey: Key.streamYouTubeQuality) }
    }
    /// 0…1.
    @Published var streamGameVolume: Double { didSet { defaults.set(streamGameVolume, forKey: Key.streamGameVolume) } }
    @Published var micEnabled: Bool { didSet { defaults.set(micEnabled, forKey: Key.micEnabled) } }
    /// nil = the system's default input.
    @Published var micDeviceID: String? { didSet { defaults.set(micDeviceID, forKey: Key.micDeviceID) } }
    /// 0…1.
    @Published var micVolume: Double { didSet { defaults.set(micVolume, forKey: Key.micVolume) } }
    /// Voice processing cancels the game's sound out of the microphone, for when it plays from speakers.
    @Published var micRemoveGameSound: Bool { didSet { defaults.set(micRemoveGameSound, forKey: Key.micRemoveGameSound) } }
    /// Off until the owner turns it on; going live never does.
    @Published var cameraEnabled: Bool { didSet { defaults.set(cameraEnabled, forKey: Key.cameraEnabled) } }
    /// nil = the first built-in or Continuity camera.
    @Published var cameraDeviceID: String? { didSet { defaults.set(cameraDeviceID, forKey: Key.cameraDeviceID) } }
    @Published var cameraCorner: StreamCorner { didSet { defaults.set(cameraCorner.rawValue, forKey: Key.cameraCorner) } }
    @Published var cameraSize: StreamCameraSize { didSet { defaults.set(cameraSize.rawValue, forKey: Key.cameraSize) } }
    var cameraLayout: CameraLayout { CameraLayout(corner: cameraCorner, size: cameraSize) }
    /// A measuring aid, so it always starts off, and turns itself off again: its square is part of
    /// the picture and ends up in recordings when forgotten.
    @Published var latencyTest = false {
        didSet {
            latencyTestTimer?.invalidate()
            guard latencyTest else { return }
            latencyTestTimer = Timer.scheduledTimer(withTimeInterval: Self.latencyTestDuration, repeats: false) { [weak self] _ in
                self?.latencyTest = false
            }
        }
    }
    static let latencyTestDuration: TimeInterval = 300
    private var latencyTestTimer: Timer?

    var renderConfig: RenderConfig {
        RenderConfig(scalingMode: scalingMode, upscaling: upscalingEnabled, upscaler: upscaler,
                     sharpening: sharpeningEnabled, sharpness: Float(effectiveSharpness),
                     frameGeneration: frameGenerationEnabled, fastFrameGeneration: frameGenerationFast,
                     // A capture card delivers no late frames to cover for.
                     steadyFrameGeneration: frameGenerationSteady && source == .window,
                     latencyTest: latencyTest)
    }

    var effectiveSharpness: Double { source == .window ? windowSharpness : sharpness }

    var windowSelection: WindowSelection {
        WindowSelection(appName: windowApp, title: windowTitle, hideTitleBar: windowHideTitleBar)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Before settings version 2 the automatically chosen device was saved too (often the built-in
        // camera); forget it once so "Automatic" can find the capture card.
        if defaults.integer(forKey: "settingsVersion") < 2 {
            defaults.removeObject(forKey: Key.deviceID)
            defaults.set(2, forKey: "settingsVersion")
        }
        source = VideoSource(rawValue: defaults.string(forKey: Key.source) ?? "") ?? .captureCard
        windowApp = defaults.string(forKey: Key.windowApp)
        windowTitle = defaults.string(forKey: Key.windowTitle)
        windowHideTitleBar = defaults.object(forKey: Key.windowHideTitleBar) as? Bool ?? true
        windowSharpness = defaults.object(forKey: Key.windowSharpness) as? Double ?? 0.25
        deviceID = defaults.string(forKey: Key.deviceID)
        formatID = defaults.string(forKey: Key.formatID)
        frameRate = defaults.double(forKey: Key.frameRate)
        displayID = UInt32(clamping: defaults.integer(forKey: Key.displayID))
        scalingMode = ScalingMode(rawValue: defaults.string(forKey: Key.scalingMode) ?? "") ?? .fit
        displaySyncEnabled = defaults.object(forKey: Key.displaySync) as? Bool ?? true
        // Before the compact mode there was only on and off.
        statsMode = StatsMode(rawValue: defaults.string(forKey: Key.statsMode) ?? "")
            ?? (defaults.object(forKey: Key.showOverlay) as? Bool == false ? .off : .compact)
        upscalingEnabled = defaults.object(forKey: Key.upscaling) as? Bool ?? true
        upscaler = Upscaler.Kind(rawValue: defaults.string(forKey: Key.upscaler) ?? "") ?? .metalFX
        sharpeningEnabled = defaults.object(forKey: Key.sharpening) as? Bool ?? true
        sharpness = defaults.object(forKey: Key.sharpness) as? Double ?? 0.5
        frameGenerationEnabled = defaults.object(forKey: Key.frameGeneration) as? Bool ?? true
        frameGenerationFast = defaults.object(forKey: Key.frameGenerationFast) as? Bool ?? true
        frameGenerationSteady = defaults.object(forKey: Key.frameGenerationSteady) as? Bool ?? true
        recordStats = defaults.bool(forKey: Key.recordStats)
        audioEnabled = defaults.object(forKey: Key.audioEnabled) as? Bool ?? true
        audioDeviceID = defaults.string(forKey: Key.audioDeviceID)
        audioVolume = defaults.object(forKey: Key.audioVolume) as? Double ?? 1
        streamEnabled = Dictionary(uniqueKeysWithValues: StreamSite.allCases.map { ($0, defaults.bool(forKey: Key.streamEnabled($0))) })
        streamServer = Dictionary(uniqueKeysWithValues: StreamSite.allCases.map { ($0, defaults.string(forKey: Key.streamServer($0)) ?? "") })
        streamBitrate = Dictionary(uniqueKeysWithValues: StreamSite.allCases.map { ($0, max(0, defaults.integer(forKey: Key.streamBitrate($0)))) })
        streamYouTubeQuality = StreamQuality(rawValue: defaults.object(forKey: Key.streamYouTubeQuality) as? Int ?? 1440) ?? .p1440
        streamGameVolume = defaults.object(forKey: Key.streamGameVolume) as? Double ?? 1
        micEnabled = defaults.object(forKey: Key.micEnabled) as? Bool ?? true
        micDeviceID = defaults.string(forKey: Key.micDeviceID)
        micVolume = defaults.object(forKey: Key.micVolume) as? Double ?? 1
        micRemoveGameSound = defaults.object(forKey: Key.micRemoveGameSound) as? Bool ?? true
        cameraEnabled = defaults.bool(forKey: Key.cameraEnabled)
        cameraDeviceID = defaults.string(forKey: Key.cameraDeviceID)
        cameraCorner = defaults.string(forKey: Key.cameraCorner).flatMap(StreamCorner.init(rawValue:)) ?? .bottomRight
        cameraSize = defaults.string(forKey: Key.cameraSize).flatMap(StreamCameraSize.init(rawValue:)) ?? .medium
    }

    /// Reads the stream keys: call it only when going live.
    func makeStreamConfig() -> StreamConfig {
        let sites = StreamSite.allCases.filter { streamEnabled[$0] == true }.map { site -> StreamSiteConfig in
            let server = (streamServer[site] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let read = StreamKeyStore.read(for: site)
            return StreamSiteConfig(site: site, server: server.isEmpty ? site.defaultServer : server,
                                    key: read.key ?? "",
                                    quality: site == .youtube ? streamYouTubeQuality : .p1080,
                                    bitrate: streamBitrate[site] ?? 0,
                                    keyUnreadable: read.unreadable)
        }
        return StreamConfig(sites: sites, gameVolume: Float(streamGameVolume),
                            camera: cameraEnabled ? (cameraDeviceID, cameraLayout) : nil,
                            mic: micEnabled ? (micDeviceID, Float(micVolume), micRemoveGameSound) : nil)
    }
}
