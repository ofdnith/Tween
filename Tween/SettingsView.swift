import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var recorder: Recorder
    let broadcaster: Broadcaster
    @ObservedObject var capture: CaptureManager
    @ObservedObject var windowCapture: WindowCaptureManager
    @ObservedObject var audio: AudioPassthrough
    @ObservedObject var displays: DisplayManager
    let supportsMetalFX: Bool
    let supportsFrameGeneration: Bool
    let onClose: () -> Void

    private var selectedFormat: CaptureFormatOption? {
        capture.formats.first { $0.id == settings.formatID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tween").font(.title2.weight(.semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close (Esc)")
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Form {
                Section {
                    Picker("Source", selection: $settings.source) {
                        ForEach(VideoSource.allCases) { source in
                            Text(source.label).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                pictureSection
                enhancementSection
                if settings.source == .captureCard {
                    audioSection
                }
                StreamSettingsSection(settings: settings, broadcaster: broadcaster, camera: broadcaster.camera)
                recordingSection
                overlaySection
                shortcutsSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()
            HStack {
                Text("Tab shows and hides this panel").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Quit Tween") { NSApp.terminate(nil) }
                    .help("Quit (⌘Q)")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Picture

    /// Where the picture comes from, then where and how it is shown.
    private var pictureSection: some View {
        Section("Picture") {
            if settings.source == .captureCard {
                captureRows
            } else {
                windowRows
            }

            Picker("Display", selection: $settings.displayID) {
                Text("Automatic").tag(UInt32(0))
                ForEach(displays.displays) { display in
                    Text(display.summary).tag(display.id)
                }
            }

            Picker("Scaling", selection: $settings.scalingMode) {
                ForEach(ScalingMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            noted("Off lowers the delay. On some Macs it can tear.") {
                Toggle("V-Sync", isOn: $settings.displaySyncEnabled)
            }
        }
    }

    @ViewBuilder private var captureRows: some View {
        if capture.state == .denied {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tween needs camera access to read your capture card.")
                Button("Open Privacy Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                }
            }
        }

        Picker("Device", selection: $settings.deviceID) {
            if settings.deviceID == nil || !capture.devices.contains(where: { $0.id == settings.deviceID }) {
                Text(settings.deviceID != nil ? "Saved device (unplugged)"
                     : capture.devices.isEmpty ? "None connected" : "Automatic")
                    .tag(settings.deviceID)
            }
            ForEach(capture.devices) { device in
                Text(device.name).tag(Optional(device.id))
            }
        }

        formatRow

        // One rate to choose from is no choice.
        if let rates = selectedFormat?.frameRates, rates.count > 1 {
            Picker("Frame rate", selection: $settings.frameRate) {
                Text("Highest").tag(0.0)
                ForEach(rates, id: \.self) { fps in
                    Text("\(formatFPS(fps)) fps").tag(fps)
                }
            }
        }

        if selectedFormat?.isCompressed == true {
            Label("MJPEG is decoded before display and adds delay. Use YUY2 or 420v if your card offers it.",
                  systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.yellow)
        }
    }

    /// The sizes a console is normally captured at, with everything else the card offers one level down.
    private var formatRow: some View {
        let common = capture.formats.filter(\.isCommon)
        let shown = common.isEmpty ? capture.formats : common
        let other = common.isEmpty ? [] : capture.formats.filter { !$0.isCommon }
        let recommended = CaptureManager.defaultFormat(in: capture.formats)?.id
        return LabeledContent("Format") {
            Menu {
                formatButtons(shown, recommended: recommended)
                if !other.isEmpty {
                    Menu("Other sizes") { formatButtons(other, recommended: recommended) }
                }
            } label: {
                Text(selectedFormat?.label ?? (capture.formats.isEmpty ? "None" : "Automatic"))
            }
            .fixedSize()
        }
    }

    private func formatButtons(_ formats: [CaptureFormatOption], recommended: String?) -> some View {
        ForEach(formats) { format in
            let title = format.label + (format.id == recommended ? " · recommended" : "")
            Button {
                settings.formatID = format.id
            } label: {
                if format.id == settings.formatID {
                    Label(title, systemImage: "checkmark")
                } else {
                    Text(title)
                }
            }
        }
    }

    /// "app\u{1}title"; nil = automatic.
    private var windowChoice: Binding<String?> {
        Binding(
            get: { settings.windowApp.map { "\($0)\u{1}\(settings.windowTitle ?? "")" } },
            set: { value in
                let parts = value?.components(separatedBy: "\u{1}")
                settings.windowTitle = parts?.dropFirst().first
                settings.windowApp = parts?.first
            }
        )
    }

    @ViewBuilder private var windowRows: some View {
        if windowCapture.state == .denied {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tween needs Screen Recording access to read another app's window. Turn it on, then relaunch Tween.")
                Button("Open Screen Recording Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
        }

        noted("Keep the streaming app open; it can sit behind Tween.") {
            HStack {
                Picker("Window", selection: windowChoice) {
                    Text("Automatic (find Remote Play)").tag(String?.none)
                    if let app = settings.windowApp,
                       !windowCapture.windows.contains(where: { $0.appName == app && $0.title == (settings.windowTitle ?? "") }) {
                        Text("\(app) (not open)").tag(windowChoice.wrappedValue)
                    }
                    ForEach(windowCapture.windows) { window in
                        Text(window.label).tag(Optional("\(window.appName)\u{1}\(window.title)"))
                    }
                }
                Button {
                    windowCapture.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh the window list")
            }
        }
        .onAppear { windowCapture.refresh() }

        Toggle("Hide the window's title bar", isOn: $settings.windowHideTitleBar)
    }

    // MARK: - Enhance

    private var enhancementSection: some View {
        Section("Enhance") {
            noted("Used when the screen is larger than the picture. Adds GPU time, not frames of delay.") {
                Toggle("Upscaling", isOn: $settings.upscalingEnabled)
            }
            if settings.upscalingEnabled {
                if supportsMetalFX {
                    Picker("Method", selection: $settings.upscaler) {
                        ForEach(Upscaler.Kind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                } else {
                    LabeledContent("Method", value: "Lanczos")
                }
            }

            Toggle("Sharpening", isOn: $settings.sharpeningEnabled)
            if settings.sharpeningEnabled {
                LabeledContent("Strength") {
                    HStack {
                        Slider(value: settings.source == .window ? $settings.windowSharpness : $settings.sharpness, in: 0...1)
                        Text(String(format: "%.0f%%", settings.effectiveSharpness * 100))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            if supportsFrameGeneration {
                noted("For 30 fps games. Adds about 30 ms of delay; turn it off for tight timing.") {
                    Toggle("Frame generation (30 → 60 fps)", isOn: $settings.frameGenerationEnabled)
                }
                if settings.frameGenerationEnabled {
                    noted("Fast is about 10 ms quicker. Whatever holds still, such as the HUD, stays sharp in both.") {
                        Picker("In-between frames", selection: $settings.frameGenerationFast) {
                            Text("Fast (720p)").tag(true)
                            Text("Full (1080p)").tag(false)
                        }
                        .pickerStyle(.segmented)
                    }
                    // A capture card delivers no late frames to cover for.
                    if settings.source == .window {
                        noted("Keeps one frame ready for when the stream delivers late: fewer small hitches, up to 17 ms more delay on a 60 Hz screen.") {
                            Toggle("Steadier motion", isOn: $settings.frameGenerationSteady)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Sound, recording, overlay

    private var audioSection: some View {
        Section("Sound") {
            Toggle("Play the capture card's sound", isOn: $settings.audioEnabled)
            if settings.audioEnabled {
                Picker("Input", selection: $settings.audioDeviceID) {
                    Text("Match capture device").tag(String?.none)
                    ForEach(audio.devices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
                LabeledContent("Volume") {
                    Slider(value: $settings.audioVolume, in: 0...1)
                }
                switch audio.state {
                case .noMatch:
                    Text("Couldn't find the capture card's audio automatically. Choose it above.")
                        .font(.callout).foregroundStyle(.yellow)
                case .denied:
                    Button("Open Microphone Privacy Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                case .failed(let reason):
                    Text(reason).font(.callout).foregroundStyle(.yellow)
                default:
                    EmptyView()
                }
            }
        }
    }

    private var recordingSection: some View {
        Section("Screenshots & recording") {
            noted("Saves the enhanced picture: screenshots to Pictures → Tween, recordings with sound to Movies → Tween.") {
                HStack {
                    Button("Take screenshot") { recorder.takeScreenshot() }
                    Button(recorder.isRecording ? "Stop recording" : "Start recording") { recorder.toggleRecording() }
                    Spacer()
                    Button {
                        if let folder = Recorder.folder(.moviesDirectory) { NSWorkspace.shared.open(folder) }
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Show recordings in Finder")
                }
            }
            Toggle("Include the stats", isOn: $settings.recordStats)
        }
    }

    private var overlaySection: some View {
        Section("Overlay & testing") {
            Picker("Stats", selection: $settings.statsMode) {
                ForEach(StatsMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            noted("A square in the video's corner turns white while the centre of the picture is bright. Film the screen in slow motion to time it. Turns itself off after \(Int(AppSettings.latencyTestDuration / 60)) minutes. Not available while live: the square would be in the stream.") {
                WhileLive(broadcaster: broadcaster) { live in
                    Toggle("Latency test", isOn: $settings.latencyTest)
                        .disabled(live)
                }
            }
        }
    }

    private var shortcutsSection: some View {
        Section {
            DisclosureGroup("Shortcuts") {
                shortcut("Tab  or  ⌘,", "Show / hide settings")
                shortcut("O", "Stats: off / compact / full")
                shortcut("M", "Cycle Fit / Fill / Stretch")
                shortcut("V", "V-Sync on / off")
                shortcut("U", "Upscaling on / off")
                shortcut("S", "Sharpening on / off")
                if supportsFrameGeneration {
                    shortcut("F", "Frame generation on / off")
                }
                shortcut("A", "Sound on / off")
                shortcut("P", "Take a screenshot")
                shortcut("R", "Start / stop recording")
                shortcut("L", "Latency test on / off")
                shortcut("N", "Microphone on / off while live")
                shortcut("⌘Q", "Quit")
            }
        }
    }

    private func shortcut(_ keys: String, _ action: String) -> some View {
        HStack {
            Text(keys).font(.system(.body, design: .monospaced))
            Spacer()
            Text(action).foregroundStyle(.secondary)
        }
    }

    /// A control with one line of explanation under it, kept together as a single row.
    private func noted<Content: View>(_ note: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content()
            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Content that depends on whether a stream is live. Observes the broadcaster itself, so its
/// frequent updates redraw only this, not the whole panel.
private struct WhileLive<Content: View>: View {
    @ObservedObject var broadcaster: Broadcaster
    @ViewBuilder let content: (Bool) -> Content

    var body: some View { content(broadcaster.isLive) }
}
