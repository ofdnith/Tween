import SwiftUI

struct OverlayLine: Identifiable, Equatable {
    let label: String
    let value: String
    var id: String { label }
}

/// Text the overlay shows, rebuilt from the renderer's counters a couple of times a second.
final class StatsModel: ObservableObject {
    @Published private(set) var lines: [OverlayLine] = []
    /// The few numbers worth watching while playing.
    @Published private(set) var compactLines: [OverlayLine] = []
    @Published private(set) var statusMessage: String?

    func update(render: RenderStats, state: CaptureState, captureSummary: String, display: DisplayInfo?,
                settings: AppSettings, audio: AudioPassthrough.State) {
        let window = settings.source == .window
        // A window only sends frames when its picture changes, so allow longer gaps.
        let receiving = render.secondsSinceLastFrame < (window ? 5 : 1.5)

        var lines: [OverlayLine] = []
        lines.append(OverlayLine(label: "SRC", value: captureSummary.isEmpty ? "—" : captureSummary))
        if receiving {
            lines.append(OverlayLine(label: "IN", value: String(format: "%5.1f fps · %d×%d %@", render.inputFPS,
                                                                Int(render.sourceSize.width), Int(render.sourceSize.height),
                                                                render.pixelFormat.formatName)))
            lines.append(OverlayLine(label: "OUT", value: String(format: "%5.1f fps · %d×%d (%@)", render.outputFPS,
                                                                 Int(render.videoSize.width), Int(render.videoSize.height),
                                                                 settings.scalingMode.label)))
            lines.append(OverlayLine(label: "GPU", value: String(format: "%.2f ms / frame", render.gpuMs)))
            lines.append(OverlayLine(label: "LAT", value: render.latencyMs > 0
                                     ? String(format: "%.1f ms capture → present", render.latencyMs) : "—"))
        } else {
            lines.append(OverlayLine(label: "IN", value: "no frames"))
        }
        lines.append(OverlayLine(label: "DROP", value: render.repeatedFrames > 0
                                 ? "\(render.droppedFrames) · \(render.repeatedFrames) repeats skipped" : "\(render.droppedFrames)"))
        lines.append(OverlayLine(label: "SCALE", value: receiving ? render.scaler : "—"))
        lines.append(OverlayLine(label: "SHARP", value: settings.sharpeningEnabled
                                 ? String(format: "CAS %.0f%%", settings.effectiveSharpness * 100) : "off"))
        let frameGeneration = render.frameGeneration ?? "On"
        if settings.frameGenerationEnabled {
            // Idle or unavailable, it adds nothing.
            lines.append(OverlayLine(label: "FGEN", value: frameGeneration.hasPrefix("On")
                                     ? frameGeneration + " · adds latency" : frameGeneration))
        }
        lines.append(OverlayLine(label: "AUDIO", value: window ? "from the streaming app" : Self.describe(audio)))
        lines.append(OverlayLine(label: "DISP", value: display?.summary ?? "—"))
        lines.append(OverlayLine(label: "SYNC", value: settings.displaySyncEnabled ? "V-Sync on" : "V-Sync off (lowest latency)"))
        if settings.latencyTest {
            lines.append(OverlayLine(label: "TEST", value: "Latency test · \(render.latencyFlashes) flashes"))
        }
        if self.lines != lines { self.lines = lines }

        var compact: [OverlayLine] = []
        if receiving {
            compact.append(OverlayLine(label: "IN", value: String(format: "%.0f fps", render.inputFPS)))
            compact.append(OverlayLine(label: "OUT", value: String(format: "%.0f fps", render.outputFPS)))
            compact.append(OverlayLine(label: "LAT", value: render.latencyMs > 0 ? String(format: "%.0f ms", render.latencyMs) : "—"))
        } else {
            compact.append(OverlayLine(label: "IN", value: "no frames"))
        }
        if settings.frameGenerationEnabled {
            compact.append(OverlayLine(label: "FGEN", value: frameGeneration))
        }
        if compactLines != compact { compactLines = compact }

        let message: String?
        if window {
            message = Self.windowMessage(state, receiving: receiving)
        } else {
            message = Self.captureMessage(state, receiving: receiving)
        }
        if statusMessage != message { statusMessage = message }
    }

    private static func windowMessage(_ state: CaptureState, receiving: Bool) -> String? {
        switch state {
        case .starting: return "Connecting to the Remote Play app…"
        case .needsPermission, .denied:
            return "Tween isn't allowed to see the Remote Play window.\nOpen System Settings → Privacy & Security → Screen & System Audio Recording.\nTurn Tween on (if it is already on, turn it off and on again), then quit and reopen Tween."
        case .noDevice: return "No streaming window found.\nOpen PS Remote Play (or Steam Link, Chiaki, Moonlight…) and start streaming,\nor pick a window in Settings (Tab)."
        case .waitingForDevice: return "The streaming window closed.\nWaiting for it to come back…"
        case .failed(let reason): return reason
        case .running:
            return receiving ? nil : "No new frames from the window.\nIf the stream froze, the app may pause while hidden: put it on another display."
        }
    }

    private static func captureMessage(_ state: CaptureState, receiving: Bool) -> String? {
        let message: String?
        switch state {
        case .starting: message = "Starting capture…"
        case .needsPermission: message = "Waiting for camera permission…"
        case .denied: message = "Camera access is off.\nTurn on Tween in System Settings → Privacy & Security → Camera, then relaunch.\nUsing PS Remote Play instead? Press Tab and choose Remote Play app."
        case .noDevice: message = "No capture device found.\nPlug in your capture card, or for PS Remote Play press Tab and choose Remote Play app.\nTab opens settings · ⌘Q quits"
        case .waitingForDevice: message = "Capture device disconnected.\nWaiting for it to come back…"
        case .failed(let reason): message = reason
        case .running: message = receiving ? nil : "No signal.\nCheck that the console is on and HDMI is connected."
        }
        return message
    }

    private static func describe(_ state: AudioPassthrough.State) -> String {
        switch state {
        case .off: return "off"
        case .needsPermission: return "waiting for microphone permission"
        case .denied: return "microphone access is off (System Settings → Privacy)"
        case .noMatch: return "pick the capture card's audio in Settings"
        case .running(let name): return name
        case .failed(let reason): return reason
        }
    }
}

struct StatsOverlay: View {
    @ObservedObject var stats: StatsModel
    let compact: Bool

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            ForEach(compact ? stats.compactLines : stats.lines) { line in
                GridRow {
                    Text(line.label).foregroundStyle(.white.opacity(0.55))
                    Text(line.value).foregroundStyle(.white)
                }
            }
        }
        .font(.system(size: 13, weight: .medium, design: .monospaced))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct StatusBanner: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 20, weight: .semibold))
            .multilineTextAlignment(.center)
            // Long messages wrap instead of running under the settings panel.
            .frame(maxWidth: 760)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// "REC 1:23" while recording, and short notes such as "Screenshot saved". Drawn over the video
/// only, so it never ends up in the recording itself.
struct RecorderBadge: View {
    @ObservedObject var recorder: Recorder

    var body: some View {
        VStack(spacing: 8) {
            if let start = recorder.startedAt {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(start)))
                    HStack(spacing: 8) {
                        Circle().fill(.red).frame(width: 10, height: 10)
                        Text(String(format: "REC %d:%02d", seconds / 60, seconds % 60))
                    }
                }
                .modifier(BadgeStyle())
            }
            if let notice = recorder.notice {
                Text(notice).modifier(BadgeStyle())
            }
        }
    }
}

private struct BadgeStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.black.opacity(0.62), in: Capsule())
    }
}

/// "LIVE 1:23" while streaming, "MIC OFF" while the microphone is muted, and the stream's short
/// notes. Drawn over the video only, so it is never in the stream.
struct LiveBadge: View {
    @ObservedObject var broadcaster: Broadcaster

    var body: some View {
        VStack(spacing: 8) {
            if broadcaster.isLive {
                if let start = broadcaster.startedAt {
                    // The timeline exists only once a site is live, so nothing ticks otherwise.
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        let seconds = max(0, Int(context.date.timeIntervalSince(start)))
                        HStack(spacing: 8) {
                            Circle().fill(.red).frame(width: 10, height: 10)
                            Text(Self.elapsed(seconds))
                        }
                    }
                    .modifier(BadgeStyle())
                } else {
                    Text("CONNECTING").modifier(BadgeStyle())
                }
                if broadcaster.micMuted {
                    Text("MIC OFF").modifier(BadgeStyle())
                }
            }
            if let notice = broadcaster.notice {
                Text(notice).modifier(BadgeStyle())
            }
        }
    }

    private static func elapsed(_ seconds: Int) -> String {
        seconds >= 3600
            ? String(format: "LIVE %d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "LIVE %d:%02d", seconds / 60, seconds % 60)
    }
}

/// Everything drawn over the video: stats (top-left), badges (top), status (center), settings (right).
struct VideoOverlayRoot: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var ui: UIState
    @ObservedObject var stats: StatsModel
    @ObservedObject var recorder: Recorder
    let broadcaster: Broadcaster
    let capture: CaptureManager
    let windowCapture: WindowCaptureManager
    let audio: AudioPassthrough
    let displays: DisplayManager
    let supportsMetalFX: Bool
    let supportsFrameGeneration: Bool

    var body: some View {
        ZStack {
            if let message = stats.statusMessage {
                StatusBanner(message: message)
            }
            if settings.statsMode != .off {
                StatsOverlay(stats: stats, compact: settings.statsMode == .compact)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            // The live badge watches the broadcaster itself and is empty when not live, so this view's
            // body isn't redrawn for every broadcaster update.
            VStack(spacing: 8) {
                if settings.latencyTest {
                    // The test's square is part of the picture, so say that it is on.
                    Text("LATENCY TEST · L to stop").modifier(BadgeStyle())
                }
                if recorder.isRecording || recorder.notice != nil {
                    RecorderBadge(recorder: recorder)
                }
                LiveBadge(broadcaster: broadcaster)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if ui.showSettings {
                SettingsView(settings: settings, recorder: recorder, broadcaster: broadcaster, capture: capture, windowCapture: windowCapture, audio: audio, displays: displays,
                             supportsMetalFX: supportsMetalFX, supportsFrameGeneration: supportsFrameGeneration) {
                    ui.showSettings = false
                }
                .frame(width: 420)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
