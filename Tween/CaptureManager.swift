import AVFoundation
import Combine
import QuartzCore

struct CaptureDeviceInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let modelID: String
}

/// One selectable resolution + pixel format of a device, with every frame rate it offers.
struct CaptureFormatOption: Identifiable, Hashable {
    let id: String
    let width: Int32
    let height: Int32
    let subtype: FourCharCode
    /// Descending.
    let frameRates: [Double]

    var isCompressed: Bool { !CaptureManager.uncompressedSubtypes.contains(subtype) }

    var label: String {
        let fps = frameRates.first.map { " · \(formatFPS($0)) fps" } ?? ""
        let format = subtype.formatName.split(separator: " ").first.map(String.init) ?? subtype.formatName
        return "\(width)×\(height) · \(format)\(fps)"
    }

    /// 16:9 at 720p or more, uncompressed: the sizes a console is normally captured at.
    var isCommon: Bool {
        !isCompressed && height >= 720 && width * 9 == height * 16
    }
}

struct CaptureRequest: Equatable {
    var deviceID: String?
    var formatID: String?
    var frameRate: Double
}

enum CaptureState: Equatable {
    case starting
    case needsPermission
    case denied
    case noDevice
    case waitingForDevice
    case running
    case failed(String)
}

func formatFPS(_ fps: Double) -> String {
    fps == fps.rounded() ? String(Int(fps)) : String(format: "%.2f", fps)
}

extension FourCharCode {
    var fourCCString: String {
        let bytes = [24, 16, 8, 0].map { UInt8((self >> $0) & 0xFF) }
        let printable = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
        return printable ? String(decoding: bytes, as: UTF8.self) : String(self)
    }

    var formatName: String {
        switch self {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: return "420v (NV12 4:2:0)"
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return "420f (NV12 4:2:0 full)"
        case kCVPixelFormatType_422YpCbCr8_yuvs: return "YUY2 (4:2:2)"
        case kCVPixelFormatType_422YpCbCr8: return "UYVY (4:2:2)"
        case kCMVideoCodecType_JPEG_OpenDML, kCMVideoCodecType_JPEG: return "MJPEG"
        default: return fourCCString
        }
    }
}

/// Owns the AVCaptureSession. Configuration runs on `sessionQueue`; frames arrive on
/// `videoQueue` and are handed straight to `onFrame` with no copies or hops.
final class CaptureManager: NSObject, ObservableObject {
    static let uncompressedSubtypes: Set<FourCharCode> = [
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_422YpCbCr8_yuvs,
        kCVPixelFormatType_422YpCbCr8,
    ]

    @Published private(set) var devices: [CaptureDeviceInfo] = []
    @Published private(set) var formats: [CaptureFormatOption] = []
    @Published private(set) var state: CaptureState = .starting
    @Published private(set) var activeSummary = ""
    @Published private(set) var activeDevice: CaptureDeviceInfo?

    /// Called on the high-priority video queue. The time is the frame's capture time in host seconds
    /// (same clock as `CACurrentMediaTime`). Set these before the first `start`.
    var onFrame: ((CVPixelBuffer, CFTimeInterval) -> Void)?
    var onDrop: (() -> Void)?
    /// Main thread. Capture stopped (device gone or failed).
    var onStopped: (() -> Void)?
    /// Main thread. The device and format actually in use after fallbacks.
    var onResolved: ((_ deviceID: String, _ formatID: String) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "tween.capture.session")
    private let videoQueue = DispatchQueue(label: "tween.capture.video", qos: .userInteractive)
    private let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.external, .builtInWideAngleCamera],
        mediaType: .video,
        position: .unspecified
    )
    private var devicesObservation: NSKeyValueObservation?

    // sessionQueue only
    private var request = CaptureRequest(deviceID: nil, formatID: nil, frameRate: 0)
    private var input: AVCaptureDeviceInput?
    private var applied: (deviceID: String, formatID: String, frameRate: Double)?
    /// False while another source (window capture) is in use; hot-plug events are ignored then.
    private var active = false

    private let clockLock = NSLock()
    private var syncClock: CMClock?

    override init() {
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)

        devicesObservation = discovery.observe(\.devices, options: [.initial, .new]) { [weak self] session, _ in
            let list = session.devices.map { CaptureDeviceInfo(id: $0.uniqueID, name: $0.localizedName, modelID: $0.modelID) }
            DispatchQueue.main.async { self?.devices = list }
        }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(deviceDisconnected(_:)),
                           name: AVCaptureDevice.wasDisconnectedNotification, object: nil)
        center.addObserver(self, selector: #selector(deviceConnected(_:)),
                           name: AVCaptureDevice.wasConnectedNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionRuntimeError(_:)),
                           name: .AVCaptureSessionRuntimeError, object: session)
    }

    /// Asks for camera permission if needed, then (re)configures. Repeating an applied request is a no-op.
    func start(_ request: CaptureRequest) {
        sessionQueue.async {
            self.active = true
            self.request = request
            self.authorizeThenConfigure()
        }
    }

    /// Releases the capture card, e.g. while showing a window instead.
    func stop() {
        sessionQueue.async {
            self.active = false
            self.teardown()
        }
    }

    // MARK: - Configuration (sessionQueue)

    private func authorizeThenConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            publish(.needsPermission)
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                self.sessionQueue.async {
                    // The user may have switched to window capture while the prompt was up.
                    guard self.active else { return }
                    if granted { self.configure() } else { self.publish(.denied) }
                }
            }
        default:
            publish(.denied)
        }
    }

    private func configure() {
        let available = discovery.devices
        let device: AVCaptureDevice?
        if let id = request.deviceID {
            // The same card in another USB port gets a new ID; fall back to one of the same model.
            device = available.first { $0.uniqueID == id } ?? AVCaptureDevice(uniqueID: id)
                ?? available.first { Self.isSameModel($0.uniqueID, id) }
        } else {
            // Automatic never picks the built-in camera: the user would see their own face.
            device = available.first { $0.deviceType == .external }
        }
        guard let device, device.isConnected else {
            teardown()
            // A saved device that's unplugged is waited for rather than swapped for the webcam.
            publish(request.deviceID == nil || available.isEmpty ? .noDevice : .waitingForDevice)
            return
        }

        let options = Self.formatOptions(for: device)
        DispatchQueue.main.async { self.formats = options }
        guard let option = options.first(where: { $0.id == request.formatID }) ?? Self.defaultFormat(in: options) else {
            teardown()
            publish(.failed("\(device.localizedName) offers no usable video formats."))
            return
        }
        let fps = Self.resolveFrameRate(request.frameRate, in: option)

        if let applied, applied == (device.uniqueID, option.id, fps), session.isRunning, input != nil {
            return
        }
        guard let (format, range) = Self.captureFormat(for: option, frameRate: fps, on: device) else {
            publish(.failed("Couldn't select \(option.label)."))
            return
        }

        session.beginConfiguration()
        if input?.device.uniqueID != device.uniqueID {
            if let input { session.removeInput(input) }
            input = nil
            do {
                let newInput = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(newInput) else { throw CocoaError(.featureUnsupported) }
                session.addInput(newInput)
                input = newInput
            } catch {
                session.commitConfiguration()
                teardown()
                publish(.failed("Can't open \(device.localizedName): \(error.localizedDescription)"))
                return
            }
        }
        if !session.outputs.contains(output), session.canAddOutput(output) {
            session.addOutput(output)
        }

        // Ask for the device's native layout so AVFoundation never converts on the CPU.
        // MJPEG is decoded by the system into 420v.
        var pixelFormat = Self.outputPixelFormat(for: option.subtype)
        if !output.availableVideoPixelFormatTypes.contains(pixelFormat) {
            pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]

        do {
            try device.lockForConfiguration()
        } catch {
            session.commitConfiguration()
            publish(.failed("Can't configure \(device.localizedName): \(error.localizedDescription)"))
            return
        }
        device.activeFormat = format
        device.activeVideoMinFrameDuration = range.minFrameDuration
        device.activeVideoMaxFrameDuration = range.minFrameDuration
        session.commitConfiguration()
        // Holding the lock across startRunning keeps the session from picking its own format.
        if !session.isRunning { session.startRunning() }
        device.unlockForConfiguration()

        clockLock.lock()
        syncClock = session.synchronizationClock
        clockLock.unlock()

        applied = (device.uniqueID, option.id, fps)
        let summary = "\(device.localizedName) · \(option.width)×\(option.height) \(option.subtype.formatName) @ \(formatFPS(fps))"
        let deviceID = device.uniqueID, formatID = option.id
        let info = CaptureDeviceInfo(id: device.uniqueID, name: device.localizedName, modelID: device.modelID)
        DispatchQueue.main.async {
            self.activeSummary = summary
            if self.activeDevice != info { self.activeDevice = info }
            self.state = .running
            self.onResolved?(deviceID, formatID)
        }
    }

    private func teardown() {
        let hadInput = input != nil
        session.beginConfiguration()
        if let input { session.removeInput(input) }
        input = nil
        session.commitConfiguration()
        if session.isRunning { session.stopRunning() }
        applied = nil
        if hadInput {
            DispatchQueue.main.async {
                self.activeSummary = ""
                self.onStopped?()
            }
        }
    }

    private func publish(_ newState: CaptureState) {
        DispatchQueue.main.async { self.state = newState }
    }

    // MARK: - Hot-plug

    @objc private func deviceDisconnected(_ note: Notification) {
        guard let device = note.object as? AVCaptureDevice else { return }
        sessionQueue.async {
            guard self.input?.device.uniqueID == device.uniqueID else { return }
            self.teardown()
            self.publish(.waitingForDevice)
        }
    }

    @objc private func deviceConnected(_ note: Notification) {
        sessionQueue.async {
            guard self.active, self.input == nil else { return }
            self.authorizeThenConfigure()
        }
    }

    /// USB video devices' unique IDs look like "0x14100000345f2130": the USB location followed by the
    /// vendor and product IDs. Same last eight hex digits = same model, possibly in another port.
    static func isSameModel(_ a: String, _ b: String) -> Bool {
        guard a.hasPrefix("0x"), b.hasPrefix("0x"), a.count >= 10, b.count >= 10 else { return false }
        return a.suffix(8).lowercased() == b.suffix(8).lowercased()
    }

    @objc private func sessionRuntimeError(_ note: Notification) {
        sessionQueue.asyncAfter(deadline: .now() + 1) {
            guard self.active else { return }
            self.applied = nil
            self.authorizeThenConfigure()
        }
    }

    // MARK: - Format selection

    private static func optionID(width: Int32, height: Int32, subtype: FourCharCode) -> String {
        "\(width)x\(height)-\(subtype.fourCCString)"
    }

    private static func roundedRate(_ rate: Float64) -> Double {
        (rate * 100).rounded() / 100
    }

    static func formatOptions(for device: AVCaptureDevice) -> [CaptureFormatOption] {
        var rates: [String: Set<Double>] = [:]
        var meta: [String: (Int32, Int32, FourCharCode)] = [:]
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            let id = optionID(width: dims.width, height: dims.height, subtype: subtype)
            meta[id] = (dims.width, dims.height, subtype)
            for range in format.videoSupportedFrameRateRanges {
                rates[id, default: []].insert(roundedRate(range.maxFrameRate))
            }
        }
        return meta.map { id, m in
            CaptureFormatOption(id: id, width: m.0, height: m.1, subtype: m.2,
                                frameRates: (rates[id] ?? []).sorted(by: >))
        }
        .sorted { a, b in
            if a.width * a.height != b.width * b.height { return a.width * a.height > b.width * b.height }
            if a.isCompressed != b.isCompressed { return !a.isCompressed }
            return subtypeRank(a.subtype) < subtypeRank(b.subtype)
        }
    }

    private static func subtypeRank(_ subtype: FourCharCode) -> Int {
        switch subtype {
        // 4:2:2 first: it is what capture cards send natively. An MS2130 delivered YUY2 about 6 ms
        // sooner than 420v, and frame generation dropped frames on its 420v.
        case kCVPixelFormatType_422YpCbCr8_yuvs: return 0
        case kCVPixelFormatType_422YpCbCr8: return 1
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: return 2
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return 3
        default: return 4
        }
    }

    /// 1920×1080 uncompressed (YUY2 first) at its highest rate; otherwise the largest uncompressed
    /// format. MJPEG only if the device has nothing else.
    static func defaultFormat(in options: [CaptureFormatOption]) -> CaptureFormatOption? {
        let uncompressed = options.filter { !$0.isCompressed }
        let byPreference: (CaptureFormatOption, CaptureFormatOption) -> Bool = { a, b in
            if subtypeRank(a.subtype) != subtypeRank(b.subtype) { return subtypeRank(a.subtype) < subtypeRank(b.subtype) }
            return (a.frameRates.first ?? 0) > (b.frameRates.first ?? 0)
        }
        if let hd = uncompressed.filter({ $0.width == 1920 && $0.height == 1080 }).sorted(by: byPreference).first {
            return hd
        }
        return uncompressed.first ?? options.first
    }

    static func resolveFrameRate(_ requested: Double, in option: CaptureFormatOption) -> Double {
        guard requested > 0 else { return option.frameRates.first ?? 30 }
        return option.frameRates.min { abs($0 - requested) < abs($1 - requested) } ?? requested
    }

    private static func captureFormat(for option: CaptureFormatOption, frameRate: Double,
                                      on device: AVCaptureDevice) -> (AVCaptureDevice.Format, AVFrameRateRange)? {
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            guard optionID(width: dims.width, height: dims.height, subtype: subtype) == option.id else { continue }
            if let range = format.videoSupportedFrameRateRanges.first(where: { abs(roundedRate($0.maxFrameRate) - frameRate) < 0.02 }) {
                return (format, range)
            }
        }
        return nil
    }

    static func outputPixelFormat(for subtype: FourCharCode) -> OSType {
        uncompressedSubtypes.contains(subtype) ? subtype : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    fileprivate func hostTime(of sampleBuffer: CMSampleBuffer) -> CFTimeInterval {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        clockLock.lock()
        let clock = syncClock
        clockLock.unlock()
        guard pts.isValid, let clock else { return CACurrentMediaTime() }
        let host = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
        return host.isValid ? host.seconds : CACurrentMediaTime()
    }
}

extension CaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer, hostTime(of: sampleBuffer))
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onDrop?()
    }
}
