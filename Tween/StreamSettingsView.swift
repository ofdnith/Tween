import AVFoundation
import SwiftUI

/// The "Live stream" section of Settings: sites, keys, game volume, the go-live button and each site's state.
struct StreamSettingsSection: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var broadcaster: Broadcaster
    /// The broadcaster's own camera, observed here so the preview's state redraws.
    @ObservedObject var camera: CameraFeed

    /// The section's own state. A class rather than `@State`: `@State` is a macro in the newer SDKs,
    /// which the command-line type-check can't expand.
    final class Model: ObservableObject {
        /// What is typed into a key field, until it is saved. Cleared once it is saved.
        @Published var drafts: [StreamSite: String] = [:]
        @Published var savedKeys: [StreamSite: Bool] = [:]
        @Published var showAdvanced = false
        /// Set when a save or a removal failed. Never contains the key.
        @Published var keyError: String?
        @Published var micDevices: [CaptureDeviceInfo] = []
        /// The preview view is on screen in a window.
        var previewShown = false
    }

    @StateObject private var model = Model()
    @FocusState private var focusedKey: StreamSite?

    private static let available = StreamVideoEncoder.hardwareAvailable(width: 1920, height: 1080)

    var body: some View {
        Section("Live stream") {
            if Self.available {
                content
            } else {
                Text("Streaming isn't available on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            model.micDevices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio,
                                                                position: .unspecified).devices
                .map { CaptureDeviceInfo(id: $0.uniqueID, name: $0.localizedName, modelID: $0.modelID) }
            camera.refreshDevices()
            model.savedKeys = Dictionary(uniqueKeysWithValues: StreamSite.allCases.map { ($0, StreamKeyStore.hasKey(for: $0)) })
        }
        .onChange(of: settings.cameraDeviceID) { _, _ in
            if model.previewShown { camera.start(deviceID: settings.cameraDeviceID, for: .preview) }
        }
        .onChange(of: settings.cameraLayout) { _, layout in broadcaster.setCameraLayout(layout) }
        .onChange(of: focusedKey) { previous, _ in
            if let previous { saveKey(previous) }
        }
    }

    @ViewBuilder private var content: some View {
        ForEach(StreamSite.allCases) { site in
            Toggle(site.label, isOn: enabled(site))
            if settings.streamEnabled[site] == true {
                HStack {
                    SecureField("Stream key", text: draft(site),
                                prompt: Text(model.savedKeys[site] == true ? "Saved · paste to replace" : "Paste the stream key"))
                        .focused($focusedKey, equals: site)
                        .onSubmit { saveKey(site) }
                    if model.savedKeys[site] == true {
                        Button("Remove") {
                            model.keyError = StreamKeyStore.set(nil, for: site) ? nil : "Couldn't remove the \(site.label) key"
                            model.savedKeys[site] = StreamKeyStore.hasKey(for: site)
                        }
                        .disabled(broadcaster.isLive)
                    }
                }
                if site == .youtube {
                    Picker("Quality", selection: $settings.streamYouTubeQuality) {
                        ForEach(StreamQuality.allCases, id: \.self) { quality in
                            Text("\(quality.rawValue)p").tag(quality)
                        }
                    }
                }
            }
        }

        Toggle("Microphone", isOn: $settings.micEnabled)
            .disabled(broadcaster.isLive)
        if settings.micEnabled {
            Picker("Input", selection: $settings.micDeviceID) {
                Text("System default").tag(String?.none)
                ForEach(model.micDevices) { device in
                    Text(device.name).tag(Optional(device.id))
                }
            }
            .disabled(broadcaster.isLive)
            LabeledContent("Microphone volume") {
                HStack {
                    Slider(value: $settings.micVolume, in: 0...1)
                    Text(String(format: "%.0f%%", settings.micVolume * 100))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .disabled(broadcaster.isLive)
            Toggle("Remove game sound from the microphone", isOn: $settings.micRemoveGameSound)
                .disabled(broadcaster.isLive)
            Text("For when the game plays from speakers. macOS lowers other sound a little while this is on.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let line = micLine {
                Text(line).font(.callout).foregroundStyle(micNeedsAttention ? .yellow : .secondary)
            }
        }

        cameraControls

        LabeledContent("Game volume in stream") {
            HStack {
                Slider(value: $settings.streamGameVolume, in: 0...1)
                Text(String(format: "%.0f%%", settings.streamGameVolume * 100))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .disabled(broadcaster.isLive)

        HStack(alignment: .top) {
            Button(broadcaster.isLive ? "End stream" : "Go live") {
                if broadcaster.isLive {
                    broadcaster.end()
                } else {
                    if let site = focusedKey { saveKey(site) }
                    broadcaster.goLive(settings.makeStreamConfig())
                    // The test's square is drawn into the picture, so viewers would see it.
                    if broadcaster.isLive && settings.latencyTest {
                        settings.latencyTest = false
                        broadcaster.show("Latency test turned off while live")
                    }
                }
            }
            Spacer()
            // Redrawn every second for the time since going live.
            TimelineView(.periodic(from: broadcaster.startedAt ?? Date(), by: 1)) { context in
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(StreamSite.allCases) { site in
                        if let line = status(site, now: context.date) {
                            Text(line).font(.callout).foregroundStyle(needsAttention(site) ? .yellow : .secondary)
                        }
                    }
                }
            }
        }
        if let keyError = model.keyError {
            Text(keyError).font(.callout).foregroundStyle(.yellow)
        }
        if let notice = broadcaster.notice {
            Text(notice).font(.callout).foregroundStyle(.yellow)
        }
        Text("Your stream keys stay on this Mac. Set the title and who can watch on the site itself.")
            .font(.callout)
            .foregroundStyle(.secondary)

        DisclosureGroup("Advanced", isExpanded: $model.showAdvanced) {
            ForEach(StreamSite.allCases) { site in
                TextField("\(site.label) server", text: server(site), prompt: Text(site.defaultServer))
                if RTMPConnection.Target.sendsKeyInClear(server: settings.streamServer[site] ?? "") {
                    Text("rtmp:// sends your stream key unencrypted. Use rtmps:// if the site offers it.")
                        .font(.callout)
                        .foregroundStyle(.yellow)
                }
                TextField("\(site.label) bitrate (kbps)", value: bitrateKbps(site), format: .number,
                          prompt: Text("Default"))
            }
            Text("Leave empty for the defaults: Twitch 6,000 kbps; YouTube 9,000, 18,000 or 35,000 kbps for 1080p, 1440p or 2160p.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .disabled(broadcaster.isLive)
    }

    @ViewBuilder private var cameraControls: some View {
        Toggle("Camera", isOn: $settings.cameraEnabled)
            .disabled(broadcaster.isLive)
        if settings.cameraEnabled {
            Picker("Camera device", selection: $settings.cameraDeviceID) {
                Text("Automatic").tag(String?.none)
                if let saved = settings.cameraDeviceID, !camera.devices.contains(where: { $0.id == saved }) {
                    Text("Saved camera (unplugged)").tag(Optional(saved))
                }
                ForEach(camera.devices) { device in
                    Text(device.name).tag(Optional(device.id))
                }
            }
            .disabled(broadcaster.isLive)
            Picker("Corner", selection: $settings.cameraCorner) {
                Text("Top left").tag(StreamCorner.topLeft)
                Text("Top right").tag(StreamCorner.topRight)
                Text("Bottom left").tag(StreamCorner.bottomLeft)
                Text("Bottom right").tag(StreamCorner.bottomRight)
            }
            Picker("Camera size", selection: $settings.cameraSize) {
                Text("Small").tag(StreamCameraSize.small)
                Text("Medium").tag(StreamCameraSize.medium)
                Text("Large").tag(StreamCameraSize.large)
            }
            CameraPreview(camera: camera) { shown in
                model.previewShown = shown
                if shown { camera.start(deviceID: settings.cameraDeviceID, for: .preview) } else { camera.stop(for: .preview) }
            }
                .frame(width: 160, height: 90)
            if let line = cameraLine { Text(line).font(.callout).foregroundStyle(cameraNeedsAttention ? .yellow : .secondary) }
        }
    }

    private var cameraLine: String? {
        switch camera.state {
        case .off: return nil
        case .needsPermission: return "Camera: waiting for permission"
        case .denied: return "Camera: not allowed. Turn it on in System Settings > Privacy & Security > Camera."
        case .running(let name): return "Camera: \(name)"
        case .unavailable(let name): return "Camera: \(name) disconnected"
        }
    }

    private var cameraNeedsAttention: Bool {
        switch camera.state {
        case .denied, .unavailable: return true
        case .off, .needsPermission, .running: return false
        }
    }

    private var micLine: String? {
        guard broadcaster.isLive else { return nil }
        switch broadcaster.micState {
        case .off: return nil
        case .needsPermission: return "Microphone: waiting for permission"
        case .denied: return "Microphone: not allowed. Turn it on in System Settings > Privacy & Security > Microphone."
        case .running(let name): return "Microphone: \(name)" + (broadcaster.micMuted ? " (muted, N)" : " (N mutes)")
        case .plainFallback(let name): return "Microphone: \(name). Game sound isn't removed from it here." + (broadcaster.micMuted ? " Muted." : "")
        case .unavailable(let name): return "Microphone: \(name) disconnected"
        }
    }

    private var micNeedsAttention: Bool {
        switch broadcaster.micState {
        case .denied, .unavailable, .plainFallback: return true
        case .off, .needsPermission, .running: return false
        }
    }

    private func status(_ site: StreamSite, now: Date) -> String? {
        let info = broadcaster.info[site].map { " · \($0)" } ?? ""
        switch broadcaster.states[site] ?? .off {
        case .off: return nil
        case .connecting: return "\(site.label): Connecting…"
        case .live:
            let start = broadcaster.startedAt ?? Date()
            let seconds = max(0, Int(now.timeIntervalSince(start)))
            return String(format: "%@: Live %d:%02d:%02d", site.label, seconds / 3600, seconds / 60 % 60, seconds % 60) + info
        case .reconnecting(let attempt): return "\(site.label): Reconnecting (\(attempt))…"
        case .failed(let reason): return "\(site.label): \(reason)"
        }
    }

    /// A failed site, or a live one whose connection can't keep up.
    private func needsAttention(_ site: StreamSite) -> Bool {
        switch broadcaster.states[site] ?? .off {
        case .failed: return true
        case .live: return broadcaster.info[site] == Broadcaster.slowConnectionText
        case .off, .connecting, .reconnecting: return false
        }
    }

    private func saveKey(_ site: StreamSite) {
        guard let key = model.drafts[site]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
        // On failure the typed key stays in the field so it can be saved again.
        guard StreamKeyStore.set(key, for: site) else {
            model.keyError = "Couldn't save the \(site.label) key"
            return
        }
        model.keyError = nil
        model.drafts[site] = nil
        model.savedKeys[site] = StreamKeyStore.hasKey(for: site)
    }

    private func enabled(_ site: StreamSite) -> Binding<Bool> {
        Binding(get: { settings.streamEnabled[site] ?? false }, set: { settings.streamEnabled[site] = $0 })
    }

    private func draft(_ site: StreamSite) -> Binding<String> {
        Binding(get: { model.drafts[site] ?? "" }, set: { model.drafts[site] = $0 })
    }

    private func server(_ site: StreamSite) -> Binding<String> {
        Binding(get: { settings.streamServer[site] ?? "" }, set: { settings.streamServer[site] = $0 })
    }

    private func bitrateKbps(_ site: StreamSite) -> Binding<Int?> {
        Binding(get: { (settings.streamBitrate[site] ?? 0) > 0 ? settings.streamBitrate[site]! / 1000 : nil },
                set: { settings.streamBitrate[site] = max(0, ($0 ?? 0) * 1000) })
    }
}

/// The camera's own layer at 160×90. The only place the camera shows on this Mac's screen.
private struct CameraPreview: NSViewRepresentable {
    let camera: CameraFeed
    /// Called when the view enters or leaves a window. The camera runs for the preview only while it is
    /// on screen, so closing Settings stops it, and scrolling other rows never does. The stream holds it separately.
    let onVisible: (Bool) -> Void

    final class HostView: NSView {
        let preview: AVCaptureVideoPreviewLayer
        var onVisible: (Bool) -> Void = { _ in }
        private var shown = false
        init(_ layer: AVCaptureVideoPreviewLayer) {
            preview = layer
            super.init(frame: .zero)
            wantsLayer = true
            self.layer?.cornerRadius = 6
            self.layer?.masksToBounds = true
            self.layer?.backgroundColor = NSColor.black.cgColor
            self.layer?.addSublayer(layer)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            setShown(window != nil)
        }
        func setShown(_ nowShown: Bool) {
            guard nowShown != shown else { return }
            shown = nowShown
            onVisible(nowShown)
        }
        override func layout() {
            super.layout()
            preview.frame = bounds
        }
    }

    func makeNSView(context: Context) -> HostView {
        let view = HostView(camera.previewLayer)
        view.onVisible = onVisible
        return view
    }
    func updateNSView(_ view: HostView, context: Context) { view.onVisible = onVisible }
    static func dismantleNSView(_ view: HostView, coordinator: ()) { view.setShown(false) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HostView, context: Context) -> CGSize? { CGSize(width: 160, height: 90) }
}
