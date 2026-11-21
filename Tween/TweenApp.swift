import SwiftUI
import AppKit
import Combine
import Metal

@main
struct TweenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The video window is AppKit-managed (borderless, per-display); settings live inside it.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { appDelegate.toggleSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}

/// The source currently allowed to draw. Read from capture queues, so it's lock-protected.
final class SourceGate {
    private let lock = NSLock()
    private var value: VideoSource = .captureCard

    var current: VideoSource {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

final class UIState: ObservableObject {
    @Published var showSettings = false
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    let ui = UIState()
    let displays = DisplayManager()
    let capture = CaptureManager()
    let windowCapture = WindowCaptureManager()
    let audio = AudioPassthrough()
    let recorder = Recorder()
    let stats = StatsModel()

    private var renderer: Renderer?
    // The frame sink and the captured sound are on only while the recorder wants them.
    private var recorderWantsFrames = false
    private var recorderWantsAudio = false
    private let sourceGate = SourceGate()
    private var windowController: VideoWindowController?
    private var activeDisplay: DisplayInfo?
    private var statsTimer: Timer?
    private var keyMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Use the GPU that drives the output display (matters on dual-GPU Intel Macs).
        let screen = displays.targetScreen(preferred: settings.displayID)
        guard let device = screen.flatMap({ CGDirectDisplayCopyCurrentMetalDevice($0.displayID) }) ?? MTLCreateSystemDefaultDevice() else {
            fail("This Mac has no Metal-capable GPU.")
            return
        }
        let renderer: Renderer
        do {
            renderer = try Renderer(device: device)
        } catch {
            fail(error.localizedDescription)
            return
        }
        self.renderer = renderer
        let overlay = VideoOverlayRoot(settings: settings, ui: ui, stats: stats, recorder: recorder,
                                       capture: capture,
                                       windowCapture: windowCapture, audio: audio,
                                       displays: displays, supportsMetalFX: renderer.upscaler.supportsMetalFX,
                                       supportsFrameGeneration: renderer.supportsFrameGeneration)
        let windowController = VideoWindowController(device: device, overlay: overlay)
        self.windowController = windowController
        renderer.attach(layer: windowController.videoView.metalLayer)

        // Only the selected source may draw: while switching, the other one can still deliver a frame
        // or two, and two threads feeding the renderer at once would flicker (or worse).
        let gate = sourceGate
        capture.onFrame = { pixelBuffer, captureTime in
            guard gate.current == .captureCard else { return }
            renderer.render(pixelBuffer: pixelBuffer, captureTime: captureTime)
        }
        capture.onDrop = { renderer.noteDroppedFrame() }
        capture.onStopped = { renderer.clear() }
        windowCapture.onFrame = { pixelBuffer, captureTime in
            guard gate.current == .window else { return }
            renderer.render(pixelBuffer: pixelBuffer, captureTime: captureTime)
        }
        windowCapture.onStopped = { renderer.clear() }

        // Screenshots and recordings take the finished picture from the renderer, and the
        // sound from whichever source is running.
        let recorder = recorder
        recorder.onWantsFrames = { [weak self] wanted in
            self?.recorderWantsFrames = wanted
            self?.updateFrameSink()
        }
        recorder.onWantsAudio = { [weak self] wanted in
            self?.recorderWantsAudio = wanted
            self?.updateCapturedAudio()
        }
        windowCapture.onAudio = { recorder.handle(audio: $0) }
        audio.onSamples = { recorder.handle(audio: $0, at: $1) }
        capture.onResolved = { [weak self] deviceID, formatID in
            guard let self else { return }
            // Only a device the user picked is remembered (and follows the card to a new USB port);
            // "Automatic" stays automatic, so a card plugged in later is still found.
            if self.settings.deviceID != nil, self.settings.deviceID != deviceID { self.settings.deviceID = deviceID }
            if self.settings.formatID != formatID { self.settings.formatID = formatID }
        }

        bindSettings(renderer: renderer, windowController: windowController)
        installKeyMonitor()
        placeWindow()

        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshStats()
        }
        refreshStats()
        applySource()
    }

    /// Runs exactly one source: the capture card or a captured window.
    private func applySource() {
        sourceGate.current = settings.source
        switch settings.source {
        case .captureCard:
            windowCapture.stop()
            capture.start(captureRequest)
        case .window:
            capture.stop()
            windowCapture.start(settings.windowSelection)
        }
        audio.apply(audioRequest)
    }

    /// The sink is set only while the recorder wants frames (latency rule).
    private func updateFrameSink() {
        guard let renderer else { return }
        let recorder = recorder
        if recorderWantsFrames {
            renderer.setFrameSink { frame, time in recorder.handle(frame: frame, at: time) }
        } else {
            renderer.setFrameSink(nil)
        }
    }

    private func updateCapturedAudio() {
        windowCapture.setCapturesAudio(recorderWantsAudio)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// A recording in progress has to be finished, or the file can't be played.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard recorder.isRecording else { return .terminateNow }
        recorder.stop { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func toggleSettings() {
        ui.showSettings.toggle()
        if !ui.showSettings { NSCursor.setHiddenUntilMouseMoves(true) }
    }

    private var audioRequest: AudioPassthrough.Request {
        // A streaming app plays its own sound.
        AudioPassthrough.Request(enabled: settings.audioEnabled && settings.source == .captureCard,
                                 deviceID: settings.audioDeviceID,
                                 volume: Float(settings.audioVolume), videoDevice: capture.activeDevice)
    }

    private var captureRequest: CaptureRequest {
        CaptureRequest(deviceID: settings.deviceID, formatID: settings.formatID, frameRate: settings.frameRate)
    }

    private func bindSettings(renderer: Renderer, windowController: VideoWindowController) {
        Publishers.CombineLatest3(settings.$deviceID, settings.$formatID, settings.$frameRate)
            .map { CaptureRequest(deviceID: $0, formatID: $1, frameRate: $2) }
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] request in
                guard let self, self.settings.source == .captureCard else { return }
                self.capture.start(request)
            }
            .store(in: &cancellables)

        settings.$source.removeDuplicates().map { _ in () }
            .merge(with: Publishers.CombineLatest3(settings.$windowApp, settings.$windowTitle, settings.$windowHideTitleBar)
                .map { _ in () })
            .dropFirst(2)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applySource() }
            .store(in: &cancellables)

        // objectWillChange fires before the change lands; receive(on:) reads it after.
        renderer.setConfig(settings.renderConfig)
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                renderer.setConfig(self.settings.renderConfig)
                self.audio.apply(self.audioRequest)
                self.updateRecordedStats()
            }
            .store(in: &cancellables)
        capture.$activeDevice
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.audio.apply(self.audioRequest)
            }
            .store(in: &cancellables)

        settings.$displaySyncEnabled
            .sink { windowController.videoView.metalLayer.displaySyncEnabled = $0 }
            .store(in: &cancellables)


        // Re-place the window when the choice changes or displays are added, removed or reconfigured.
        settings.$displayID.removeDuplicates().map { _ in () }
            .merge(with: displays.$displays.map { _ in () })
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.placeWindow() }
            .store(in: &cancellables)

        // `receive(on:)` defers until the @Published value has actually changed.
        settings.$statsMode.map { _ in () }
            .merge(with: ui.$showSettings.map { _ in () }, stats.$statusMessage.map { _ in () },
                   settings.$latencyTest.map { _ in () },
                   recorder.$startedAt.map { _ in () }, recorder.$notice.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateOverlayVisibility() }
            .store(in: &cancellables)
    }

    private func placeWindow() {
        guard let windowController, let screen = displays.targetScreen(preferred: settings.displayID) else { return }
        windowController.show(on: screen)
        activeDisplay = DisplayManager.info(for: screen)
        if let rate = activeDisplay?.refreshRate { renderer?.setRefreshRate(rate) }
        if capture.state != .running { renderer?.clear() }
    }

    private func refreshStats() {
        guard let renderer else { return }
        let window = settings.source == .window
        stats.update(render: renderer.snapshot(),
                     state: window ? windowCapture.state : capture.state,
                     captureSummary: window ? windowCapture.activeSummary : capture.activeSummary,
                     display: activeDisplay, settings: settings, audio: audio.state)
        updateRecordedStats()
    }

    private func updateRecordedStats() {
        recorder.setStats(settings.recordStats
                          ? stats.lines.map { Recorder.StatLine(label: $0.label, value: $0.value) } : nil)
    }

    private func updateOverlayVisibility() {
        windowController?.overlayVisible = settings.statsMode != .off || ui.showSettings || stats.statusMessage != nil
            || recorder.isRecording || recorder.notice != nil || settings.latencyTest
    }

    // MARK: - Hotkeys

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handleKey(event) else { return event }
            return nil
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        // Typing into a text field is not a shortcut.
        if (event.window ?? NSApp.keyWindow)?.firstResponder is NSText { return false }
        switch event.keyCode {
        case 53: // Esc
            guard ui.showSettings else { return false }
            toggleSettings()
            return true
        case 48: // Tab
            toggleSettings()
            return true
        default:
            break
        }
        // A held key repeats: without this, holding P saved a burst of screenshots and holding R
        // could start and stop a recording.
        let key = event.charactersIgnoringModifiers?.lowercased()
        if event.isARepeat { return key.map { "omusfalprv".contains($0) } ?? false }
        switch key {
        case "o": settings.statsMode = settings.statsMode.next
        case "m": settings.scalingMode = settings.scalingMode.next
        case "u": settings.upscalingEnabled.toggle()
        case "s": settings.sharpeningEnabled.toggle()
        case "f" where renderer?.supportsFrameGeneration == true: settings.frameGenerationEnabled.toggle()
        case "a": settings.audioEnabled.toggle()
        case "l": settings.latencyTest.toggle()
        case "p": recorder.takeScreenshot()
        case "r": recorder.toggleRecording()
        case "v": settings.displaySyncEnabled.toggle()
        default: return false
        }
        return true
    }

    private func fail(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Tween can't start"
        alert.informativeText = message
        alert.runModal()
        NSApp.terminate(nil)
    }
}
