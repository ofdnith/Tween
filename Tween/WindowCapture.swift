import AppKit
import Combine
import CoreMedia
import ScreenCaptureKit

struct CaptureWindowInfo: Identifiable, Hashable {
    let id: CGWindowID
    let appName: String
    let title: String

    var label: String { title.isEmpty || title == appName ? appName : "\(appName) — \(title)" }
}

struct WindowSelection: Equatable {
    /// nil = automatic: the first window of a known streaming app.
    var appName: String?
    var title: String?
    var hideTitleBar: Bool
}

/// Captures another app's window (PS Remote Play, Steam Link, …) with ScreenCaptureKit and hands
/// its frames to the renderer exactly like capture-card frames: 420v IOSurface buffers, no copies.
/// Control methods run on the main thread; frames arrive on a high-priority queue.
final class WindowCaptureManager: NSObject, ObservableObject {
    static let streamingApps = ["Remote Play", "Steam Link", "Chiaki", "Moonlight", "Xbox", "GeForce NOW", "Parsec"]

    @Published private(set) var windows: [CaptureWindowInfo] = []
    @Published private(set) var state: CaptureState = .starting
    @Published private(set) var activeSummary = ""

    /// Called on the video queue with the frame's display time in host seconds. Set before `start`.
    var onFrame: ((CVPixelBuffer, CFTimeInterval) -> Void)?
    /// The captured app's sound, on the audio queue. Only delivered while `setCapturesAudio(true)`.
    var onAudio: ((CMSampleBuffer) -> Void)?
    /// Main thread.
    var onStopped: (() -> Void)?

    private let videoQueue = DispatchQueue(label: "tween.window.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "tween.window.audio", qos: .userInitiated)
    private var capturesAudio = false
    private var activeConfig: SCStreamConfiguration?
    private var selection: WindowSelection?
    private var stream: SCStream?
    private var activeWindowID: CGWindowID?
    private var retryTimer: Timer?
    /// Watches the captured window's size; the stream is rebuilt when it changes.
    private var resizeTimer: Timer?
    private var activeWindowSize = CGSize.zero

    func start(_ selection: WindowSelection) {
        let changed = selection != self.selection
        self.selection = selection
        if changed { stopStream() }
        guard CGPreflightScreenCaptureAccess() else {
            // Shows the system prompt once; macOS applies the grant after a relaunch.
            CGRequestScreenCaptureAccess()
            state = .denied
            return
        }
        refresh()
    }

    func stop() {
        selection = nil
        retryTimer?.invalidate()
        retryTimer = nil
        stopStream()
    }

    /// Taps the streaming app's sound for a recording. It keeps playing from the app as usual.
    func setCapturesAudio(_ on: Bool) {
        guard on != capturesAudio else { return }
        capturesAudio = on
        guard let stream, let activeConfig else { return }
        activeConfig.capturesAudio = on
        stream.updateConfiguration(activeConfig) { _ in }
    }

    /// Re-lists windows (for the picker) and (re)connects to the selected one if needed.
    func refresh() {
        guard CGPreflightScreenCaptureAccess() else { return }
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { [weak self] content, error in
            DispatchQueue.main.async {
                if let content {
                    self?.handle(content)
                } else if (error as NSError?)?.domain == SCStreamErrorDomain,
                          (error as NSError?)?.code == SCStreamError.Code.userDeclined.rawValue {
                    // macOS can say "allowed" up front and still refuse here: after an update of the app,
                    // or when its periodic "keep allowing?" prompt was dismissed. Same fix as never allowed.
                    self?.stopStream()
                    self?.state = .denied
                    self?.scheduleRetry()
                } else {
                    self?.state = .failed("Can't list windows: \(error?.localizedDescription ?? "unknown error")")
                }
            }
        }
    }

    // MARK: - Main thread

    private func handle(_ content: SCShareableContent) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let candidates = content.windows.filter { window in
            guard let app = window.owningApplication, app.processID != ownPID else { return false }
            return window.windowLayer == 0 && window.frame.width >= 320 && window.frame.height >= 180
        }
        let list = candidates.map {
            CaptureWindowInfo(id: $0.windowID, appName: $0.owningApplication?.applicationName ?? "?", title: $0.title ?? "")
        }
        if list != windows { windows = list }

        guard let selection else { return }
        guard let window = pick(from: candidates, selection) else {
            stopStream()
            state = selection.appName == nil ? .noDevice : .waitingForDevice
            scheduleRetry()
            return
        }
        if window.windowID == activeWindowID, stream != nil { return }
        startStream(window, hideTitleBar: selection.hideTitleBar)
    }

    private func pick(from candidates: [SCWindow], _ selection: WindowSelection) -> SCWindow? {
        func app(_ window: SCWindow) -> String { window.owningApplication?.applicationName ?? "" }
        let windows = candidates.sorted {
            Self.prefers(onScreen: $0.isOnScreen, area: $0.frame.width * $0.frame.height,
                         over: $1.isOnScreen, area: $1.frame.width * $1.frame.height)
        }
        if let appName = selection.appName {
            return windows.first { app($0) == appName && ($0.title ?? "") == (selection.title ?? "") }
                ?? windows.first { app($0) == appName }
        }
        return windows.first { Self.isStreamingApp(name: app($0), bundleID: $0.owningApplication?.bundleIdentifier ?? "") }
    }

    /// Ignores spaces and case, and checks the bundle ID too: PS Remote Play reports its name as
    /// "RemotePlay" (only the localized name has the space).
    static func isStreamingApp(name: String, bundleID: String) -> Bool {
        func squash(_ text: String) -> String { text.lowercased().filter { !$0.isWhitespace } }
        let haystack = squash(name) + " " + squash(bundleID)
        return streamingApps.contains { haystack.contains(squash($0)) }
    }

    /// The centred 16:9 area below the title bar (where streaming apps draw the video), and the
    /// output size macOS scales it to. Always 1920×1080 or 1280×720: frame generation only works at
    /// a few sizes, and these are two of them.
    static func captureGeometry(windowSize: CGSize, titleBar: CGFloat, scale: CGFloat) -> (sourceRect: CGRect, pixelSize: CGSize) {
        let aspect: CGFloat = 16.0 / 9.0
        let content = CGRect(x: 0, y: titleBar, width: windowSize.width, height: max(windowSize.height - titleBar, 1))
        var rect = content
        if content.width / content.height > aspect {
            rect.size.width = content.height * aspect
            rect.origin.x = (content.width - rect.width) / 2
        } else {
            rect.size.height = content.width / aspect
            rect.origin.y = titleBar + (content.height - rect.height) / 2
        }
        let pixelSize = rect.width * scale > 1280 ? CGSize(width: 1920, height: 1080) : CGSize(width: 1280, height: 720)
        return (rect, pixelSize)
    }

    /// Streaming apps can own hidden helper windows; the visible, bigger one is the stream.
    static func prefers(onScreen: Bool, area: CGFloat, over otherOnScreen: Bool, area otherArea: CGFloat) -> Bool {
        onScreen != otherOnScreen ? onScreen : area > otherArea
    }

    private func startStream(_ window: SCWindow, hideTitleBar: Bool) {
        stopStream()
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)

        // A windowed app has a ~28 pt title bar above the video; a full-screen one doesn't.
        let isFullScreen = NSScreen.screens.contains { $0.frame.size == window.frame.size }
        let titleBar: CGFloat = hideTitleBar && !isFullScreen ? 28 : 0
        let (sourceRect, pixelSize) = Self.captureGeometry(windowSize: window.frame.size, titleBar: titleBar, scale: scale)

        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = Int(pixelSize.width)
        config.height = Int(pixelSize.height)
        config.scalesToFit = true
        config.backgroundColor = .black
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        // Frame generation keeps the source frame until its in-between frame has been shown.
        config.queueDepth = 5
        config.showsCursor = false
        config.capturesAudio = capturesAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        } catch {
            state = .failed("Can't capture that window: \(error.localizedDescription)")
            return
        }
        self.stream = stream
        activeConfig = config
        activeWindowID = window.windowID
        activeWindowSize = window.frame.size
        watchWindowSize()
        state = .starting

        let label = CaptureWindowInfo(id: window.windowID, appName: window.owningApplication?.applicationName ?? "?",
                                      title: window.title ?? "").label
        let summary = "Window · \(label) · \(Int(pixelSize.width))×\(Int(pixelSize.height))"
        stream.startCapture { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.stream === stream else { return }
                if let error {
                    self.stream = nil
                    self.activeWindowID = nil
                    self.state = .failed("Can't capture that window: \(error.localizedDescription)")
                    self.scheduleRetry()
                } else {
                    self.activeSummary = summary
                    self.state = .running
                }
            }
        }
    }

    private func stopStream() {
        guard let stream else { return }
        self.stream = nil
        activeConfig = nil
        activeWindowID = nil
        activeSummary = ""
        resizeTimer?.invalidate()
        resizeTimer = nil
        stream.stopCapture { _ in }
        onStopped?()
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            self?.retryTimer = nil
            self?.refresh()
        }
    }

    /// Rebuilds the stream when the window is resized, so the 16:9 crop follows it.
    private func watchWindowSize() {
        resizeTimer?.invalidate()
        resizeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let id = self.activeWindowID else { return }
            // The window can close without the stream reporting it; treat a missing window as gone
            // so the retry finds it (or its replacement) when the app reopens.
            guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
                  let boundsValue = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsValue as CFDictionary) else {
                self.stopStream()
                self.state = .waitingForDevice
                self.refresh()
                return
            }
            if abs(bounds.width - self.activeWindowSize.width) > 1 || abs(bounds.height - self.activeWindowSize.height) > 1 {
                self.stopStream()
                self.refresh()
            }
        }
    }

    private static func hostSeconds(machTime: UInt64) -> CFTimeInterval {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(machTime) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }
}

extension WindowCaptureManager: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            onAudio?(sampleBuffer)
            return
        }
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rawStatus = info[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete, // idle frames carry no new picture
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let captureTime = (info[.displayTime] as? UInt64).map(Self.hostSeconds(machTime:)) ?? CACurrentMediaTime()
        onFrame?(pixelBuffer, captureTime)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            guard self.stream === stream else { return }
            self.stream = nil
            self.activeWindowID = nil
            self.activeSummary = ""
            self.resizeTimer?.invalidate()
            self.resizeTimer = nil
            self.onStopped?()
            self.state = .waitingForDevice
            self.scheduleRetry()
        }
    }
}
