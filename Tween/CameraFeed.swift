import AVFoundation
import Combine
import CoreVideo

/// Who wants the camera running. The Settings preview and the live stream share one session and
/// neither may stop it while the other still needs it.
enum CameraUser: Hashable { case preview, stream }

/// What the broadcaster needs of a camera. `CameraFeed` is the real one; the checks use a stand-in.
protocol CameraSource: AnyObject {
    /// BGRA, the newest picture or nil. Any thread.
    func newestFrame() -> CVPixelBuffer?
    /// Called on the main thread.
    var onState: ((CameraFeed.State) -> Void)? { get set }
    /// nil = the first built-in or Continuity camera.
    func start(deviceID: String?, for user: CameraUser)
    func stop(for user: CameraUser)
}

/// The users holding the camera. `add` and `remove` say when the camera has to start or stop.
struct CameraHolds {
    private var users: Set<CameraUser> = []

    /// True when this is the first user.
    mutating func add(_ user: CameraUser) -> Bool {
        let wasEmpty = users.isEmpty
        users.insert(user)
        return wasEmpty
    }

    /// True when this was the last user.
    mutating func remove(_ user: CameraUser) -> Bool {
        users.remove(user) != nil && users.isEmpty
    }

    mutating func removeAll() { users = [] }
}

/// The webcam, for the stream's corner picture and the preview in Settings. Its own capture session,
/// apart from the capture card's and the microphone's, so a camera problem never reaches the game.
/// Nothing here draws on the owner's screen except the preview layer Settings hosts.
final class CameraFeed: NSObject, ObservableObject, CameraSource {
    enum State: Equatable {
        case off, needsPermission, denied
        case running(String)
        case unavailable(String)
    }

    @Published private(set) var devices: [CaptureDeviceInfo] = []
    @Published private(set) var state: State = .off
    let previewLayer: AVCaptureVideoPreviewLayer

    /// The capture card in use: never offered, never picked as the default.
    var excludedDeviceID: String? {
        get { lock.lock(); defer { lock.unlock() }; return excluded }
        set {
            lock.lock()
            excluded = newValue
            lock.unlock()
            refreshDevices()
        }
    }

    /// Main thread.
    var onState: ((State) -> Void)?

    /// Written by the capture thread, read by the broadcaster's queue and set by the session queue:
    /// all behind `lock`, and nothing is called while it is held.
    private let lock = NSLock()
    private var excluded: String?
    private var newest: CVPixelBuffer?
    /// The output whose frames count. A late frame of a torn-down session is ignored.
    private var activeOutput: AVCaptureVideoDataOutput?

    private var observers: [NSObjectProtocol] = []
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "tween.camera", qos: .userInitiated)
    private let dataQueue = DispatchQueue(label: "tween.camera.data", qos: .userInitiated)

    // queue only
    private var holds = CameraHolds()
    private var generation = 0
    /// The session is running or waiting for permission for this device (nil inside = the default).
    private var engagedWith: Request?
    /// This session's device-lost observers; `observers` is the device list's, set once in init.
    private var sessionObservers: [NSObjectProtocol] = []
    private var lastState: State = .off

    private struct Request: Equatable { let deviceID: String? }

    private static let deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera]

    /// Checks only: stands in for the capture session, so the holds logic runs without a camera.
    private let engine: (begin: (String?) -> Void, end: () -> Void)?

    convenience override init() { self.init(engine: nil) }

    init(engine: (begin: (String?) -> Void, end: () -> Void)?) {
        self.engine = engine
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        super.init()
        refreshDevices()
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.refreshDevices()
            })
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Looks for cameras again: when Settings opens, a camera is plugged in or the capture card changes.
    func refreshDevices() {
        let list = availableDevices().map { CaptureDeviceInfo(id: $0.uniqueID, name: $0.localizedName, modelID: $0.modelID) }
        DispatchQueue.main.async { if self.devices != list { self.devices = list } }
    }

    private func availableDevices() -> [AVCaptureDevice] {
        let excluded = excludedDeviceID
        return AVCaptureDevice.DiscoverySession(deviceTypes: Self.deviceTypes, mediaType: .video, position: .unspecified).devices
            .filter { $0.uniqueID != excluded }
    }

    /// Checks only: returns once everything asked of the queue so far has run.
    func waitUntilIdle() { queue.sync {} }

    // MARK: - CameraSource

    func newestFrame() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return newest
    }

    func start(deviceID: String?, for user: CameraUser) {
        queue.async {
            _ = self.holds.add(user)
            let request = Request(deviceID: deviceID)
            if self.engagedWith == request {
                // Already running for the other user: only say how it is going.
                self.report(self.lastState)
                return
            }
            self.teardown()
            self.generation += 1
            self.begin(request, generation: self.generation)
        }
    }

    func stop(for user: CameraUser) {
        queue.async {
            if self.holds.remove(user) { self.shutDown() }
        }
    }

    // MARK: - queue

    private func shutDown() {
        teardown()
        generation += 1
        report(.off)
    }

    private func report(_ state: State) {
        lastState = state
        DispatchQueue.main.async {
            self.state = state
            self.onState?(state)
        }
    }

    private func begin(_ request: Request, generation: Int) {
        if let engine {
            engagedWith = request
            engine.begin(request.deviceID)
            report(.running("Stand-in"))
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            engagedWith = request
            report(.needsPermission)
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                self.queue.async {
                    guard generation == self.generation else { return }
                    if granted {
                        self.begin(request, generation: generation)
                    } else {
                        self.engagedWith = nil
                        self.report(.denied)
                    }
                }
            }
            return
        default:
            report(.denied)
            return
        }

        let candidates = availableDevices()
        let device: AVCaptureDevice?
        if let id = request.deviceID {
            device = candidates.first { $0.uniqueID == id }
        } else {
            // Automatic never takes an external device: it could be a capture card the exclusion doesn't know.
            // External webcams are chosen by name.
            device = candidates.first { $0.deviceType != .external }
        }
        guard let device else {
            report(.unavailable(request.deviceID == nil ? "No camera" : "Camera"))
            return
        }

        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch {
            report(.unavailable(device.localizedName))
            return
        }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                kCVPixelBufferMetalCompatibilityKey as String: true]
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            report(.unavailable(device.localizedName))
            return
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        lock.lock()
        activeOutput = output
        lock.unlock()
        output.setSampleBufferDelegate(self, queue: dataQueue)

        engagedWith = request
        sessionObservers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [weak self] _ in
            self?.queue.async { self?.lost(device, generation: generation) }
        })
        sessionObservers.append(NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] _ in
            self?.queue.async { self?.lost(device, generation: generation) }
        })
        session.startRunning()
        report(.running(device.localizedName))
    }

    private func teardown() {
        if let engine {
            if engagedWith != nil { engine.end() }
            engagedWith = nil
            return
        }
        for observer in sessionObservers { NotificationCenter.default.removeObserver(observer) }
        sessionObservers = []
        lock.lock()
        activeOutput = nil
        newest = nil
        lock.unlock()
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs {
            (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
            session.removeOutput(output)
        }
        session.commitConfiguration()
        engagedWith = nil
    }

    /// Reports `.unavailable` and lets go of the hardware. The holds stay, so the next start works.
    private func lost(_ device: AVCaptureDevice, generation: Int) {
        guard generation == self.generation else { return }
        teardown()
        report(.unavailable(device.localizedName))
    }
}

extension CameraFeed: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        if output === activeOutput { newest = buffer }
        lock.unlock()
    }
}
