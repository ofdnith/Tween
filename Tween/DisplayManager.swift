import AppKit
import Combine
import QuartzCore
import SwiftUI

struct DisplayInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    let isBuiltIn: Bool

    var aspectLabel: String {
        guard pixelHeight > 0 else { return "?" }
        let ratio = Double(pixelWidth) / Double(pixelHeight)
        let known: [(String, Double)] = [("16:9", 16 / 9), ("16:10", 16 / 10), ("21:9", 64 / 27),
                                         ("32:9", 32 / 9), ("4:3", 4 / 3), ("3:2", 3 / 2)]
        if let match = known.first(where: { abs($0.1 - ratio) / $0.1 < 0.03 }) { return match.0 }
        return String(format: "%.2f:1", ratio)
    }

    var summary: String {
        "\(name) · \(pixelWidth)×\(pixelHeight) @ \(formatFPS(refreshRate.rounded())) Hz · \(aspectLabel)"
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// Tracks connected displays and their native pixel size and refresh rate; republishes on any
/// arrangement, resolution or hot-plug change.
final class DisplayManager: ObservableObject {
    @Published private(set) var displays: [DisplayInfo] = []

    init() {
        refresh()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        displays = NSScreen.screens.map(Self.info(for:))
    }

    /// The chosen display, or automatic: the first external display, else the main one.
    func targetScreen(preferred id: CGDirectDisplayID) -> NSScreen? {
        let screens = NSScreen.screens
        if id != 0, let screen = screens.first(where: { $0.displayID == id }) { return screen }
        return screens.first { CGDisplayIsBuiltin($0.displayID) == 0 } ?? NSScreen.main ?? screens.first
    }

    static func info(for screen: NSScreen) -> DisplayInfo {
        let id = screen.displayID
        let mode = CGDisplayCopyDisplayMode(id)
        let scale = screen.backingScaleFactor
        var refresh = mode?.refreshRate ?? 0
        if refresh <= 0 { refresh = Double(screen.maximumFramesPerSecond) }
        return DisplayInfo(id: id,
                           name: screen.localizedName,
                           pixelWidth: mode?.pixelWidth ?? Int(screen.frame.width * scale),
                           pixelHeight: mode?.pixelHeight ?? Int(screen.frame.height * scale),
                           refreshRate: refresh,
                           isBuiltIn: CGDisplayIsBuiltin(id) != 0)
    }
}

// MARK: - Video window

/// Layer-hosting view whose backing layer is the CAMetalLayer the renderer draws into.
final class VideoView: NSView {
    let metalLayer = CAMetalLayer()

    init(device: MTLDevice) {
        super.init(frame: .zero)
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 2
        metalLayer.displaySyncEnabled = true
        metalLayer.presentsWithTransaction = false
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        layer = metalLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    /// Drawable = the view's size in native pixels, so nothing is rescaled before the compositor.
    func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        metalLayer.contentsScale = scale
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        if size.width > 0, size.height > 0, metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
        }
    }
}

final class VideoWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Borderless window covering one whole display, with the SwiftUI overlay stacked above the video.
final class VideoWindowController {
    let window: VideoWindow
    let videoView: VideoView
    private let overlayView: NSView

    init<Overlay: View>(device: MTLDevice, overlay: Overlay) {
        videoView = VideoView(device: device)
        let hosting = NSHostingView(rootView: overlay)
        hosting.sizingOptions = []
        overlayView = hosting

        let initialFrame = NSRect(x: 0, y: 0, width: 1280, height: 720)
        let container = NSView(frame: initialFrame)
        for view in [videoView, overlayView] {
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }

        window = VideoWindow(contentRect: initialFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container
        window.title = "Tween"
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenNone]
        window.acceptsMouseMovedEvents = true
    }

    /// Hidden overlay = nothing composited on top of the video.
    var overlayVisible: Bool {
        get { !overlayView.isHidden }
        set { if overlayView.isHidden == newValue { overlayView.isHidden = !newValue } }
    }

    func show(on screen: NSScreen) {
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        if window.frame != screen.frame {
            window.setFrame(screen.frame, display: true)
        }
        videoView.updateDrawableSize()
        if !window.isVisible || !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
        NSCursor.setHiddenUntilMouseMoves(true)
    }
}
