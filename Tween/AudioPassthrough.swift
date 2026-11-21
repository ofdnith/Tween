import AVFoundation
import Combine

/// Plays the capture card's USB audio through the Mac's current output device. It runs in its own
/// AVCaptureSession so an audio problem never interrupts video. AVCaptureAudioPreviewOutput is
/// the system's own monitoring path: no extra buffering in the app.
final class AudioPassthrough: NSObject, ObservableObject {
    enum State: Equatable {
        case off
        case needsPermission
        case denied
        /// No input matched the video device; the user has to pick one.
        case noMatch
        case running(String)
        case failed(String)
    }

    struct Request: Equatable {
        var enabled: Bool
        /// nil = the audio half of the active capture device.
        var deviceID: String?
        var volume: Float
        var videoDevice: CaptureDeviceInfo?
    }

    @Published private(set) var devices: [CaptureDeviceInfo] = []
    @Published private(set) var state: State = .off

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioPreviewOutput()
    /// The same sound as sample buffers, for recordings.
    private let dataOutput = AVCaptureAudioDataOutput()
    private let dataQueue = DispatchQueue(label: "tween.audio.data", qos: .userInitiated)
    /// Each buffer with its timestamp converted to the host clock. Set once, before audio starts.
    var onSamples: ((CMSampleBuffer, CMTime) -> Void)?
    private let queue = DispatchQueue(label: "tween.audio", qos: .userInteractive)
    private let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                             mediaType: .audio, position: .unspecified)
    private var devicesObservation: NSKeyValueObservation?

    // queue only
    private var request = Request(enabled: false, deviceID: nil, volume: 1, videoDevice: nil)
    private var input: AVCaptureDeviceInput?

    override init() {
        super.init()
        output.outputDeviceUniqueID = nil // the system's default output
        dataOutput.setSampleBufferDelegate(self, queue: dataQueue)
        devicesObservation = discovery.observe(\.devices, options: [.initial, .new]) { [weak self] session, _ in
            let list = session.devices.map { CaptureDeviceInfo(id: $0.uniqueID, name: $0.localizedName, modelID: $0.modelID) }
            DispatchQueue.main.async { self?.devices = list }
            self?.queue.async { self?.reconcile() }
        }
    }

    func apply(_ request: Request) {
        queue.async {
            self.request = request
            self.reconcile()
        }
    }

    // MARK: - queue

    private func reconcile() {
        guard request.enabled else {
            stop()
            publish(.off)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            publish(.needsPermission)
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard let self else { return }
                self.queue.async { granted ? self.reconcile() : self.publish(.denied) }
            }
            return
        default:
            stop()
            publish(.denied)
            return
        }

        guard let device = resolveDevice() else {
            stop()
            publish(.noMatch)
            return
        }
        output.volume = request.volume

        if input?.device.uniqueID != device.uniqueID {
            session.beginConfiguration()
            if let input { session.removeInput(input) }
            input = nil
            do {
                let newInput = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(newInput) else { throw CocoaError(.featureUnsupported) }
                session.addInput(newInput)
                input = newInput
            } catch {
                session.commitConfiguration()
                publish(.failed("Can't open \(device.localizedName) audio: \(error.localizedDescription)"))
                return
            }
            if !session.outputs.contains(output), session.canAddOutput(output) {
                session.addOutput(output)
            }
            if !session.outputs.contains(dataOutput), session.canAddOutput(dataOutput) {
                session.addOutput(dataOutput)
            }
            session.commitConfiguration()
        }
        if !session.isRunning { session.startRunning() }
        publish(.running(device.localizedName))
    }

    /// The chosen input, or the audio interface that belongs to the video capture device. Never
    /// falls back to a microphone: that would feed the room (and the speakers) back into itself.
    private func resolveDevice() -> AVCaptureDevice? {
        let available = discovery.devices
        if let id = request.deviceID {
            return available.first { $0.uniqueID == id }
        }
        guard let video = request.videoDevice else { return nil }
        if let byName = available.first(where: { $0.localizedName == video.name }) { return byName }
        // UVC video and UAC audio of one USB device share vendor and product IDs.
        let ids = Self.usbIDs(in: video.modelID)
        guard !ids.isEmpty else { return nil }
        return available.first { device in
            let model = device.modelID.lowercased()
            return ids.allSatisfy { model.contains($0) }
        }
    }

    /// "UVC Camera VendorID_0x345F ProductID_0x2130" → ["345f", "2130"]. Newer macOS versions write
    /// the same IDs in decimal ("VendorID_13407 ProductID_8496"), while the audio half of the device
    /// keeps hex ("USB3 Digital Audio:345F:2130").
    static func usbIDs(in modelID: String) -> [String] {
        let pattern = #"(?:VendorID|ProductID)_(0x[0-9A-Fa-f]+|[0-9]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(modelID.startIndex..., in: modelID)
        return regex.matches(in: modelID, range: range).compactMap { match in
            guard let found = Range(match.range(at: 1), in: modelID) else { return nil }
            let text = modelID[found].lowercased()
            if text.hasPrefix("0x") { return String(text.dropFirst(2)) }
            return Int(text).map { String(format: "%04x", $0) }
        }
    }

    private func stop() {
        guard input != nil || session.isRunning else { return }
        session.beginConfiguration()
        if let input { session.removeInput(input) }
        input = nil
        session.commitConfiguration()
        session.stopRunning()
    }

    private func publish(_ newState: State) {
        DispatchQueue.main.async {
            if self.state != newState { self.state = newState }
        }
    }
}

extension AudioPassthrough: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let onSamples else { return }
        let hostClock = CMClockGetHostTimeClock()
        let time = CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                                     from: session.synchronizationClock ?? hostClock, to: hostClock)
        onSamples(sampleBuffer, time)
    }
}
