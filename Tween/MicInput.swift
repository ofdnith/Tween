import AVFoundation
import CoreAudio

/// What the broadcaster needs of a microphone. `MicInput` is the real one; the checks use a stand-in.
protocol MicSource: AnyObject {
    /// 48 kHz stereo interleaved floats and the host time (seconds) of the first frame. Any thread.
    var onSamples: (([Float], Double) -> Void)? { get set }
    var onState: ((MicInput.State) -> Void)? { get set }
    /// nil = the system's default input.
    func start(deviceID: String?, removeGameSound: Bool)
    func stop()
}

/// The microphone while live: nothing here plays what it hears. Two paths: its own capture session
/// (headphones), or a voice-processing input that cancels the game's sound coming out of the speakers.
final class MicInput: NSObject, MicSource {
    enum State: Equatable {
        case off, needsPermission, denied
        case running(String)
        /// Voice processing wouldn't start; the plain path runs instead.
        case plainFallback(String)
        case unavailable(String)
    }

    /// Read from the tap and capture threads while the main thread sets them: all behind `lock`, and
    /// called only after a snapshot is taken, so nothing runs under it.
    var onSamples: (([Float], Double) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return samplesHandler }
        set { lock.lock(); samplesHandler = newValue; lock.unlock() }
    }
    var onState: ((State) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return stateHandler }
        set { lock.lock(); stateHandler = newValue; lock.unlock() }
    }

    private let lock = NSLock()
    private var samplesHandler: (([Float], Double) -> Void)?
    private var stateHandler: ((State) -> Void)?
    /// What the callback threads use of the running session. A new session gets new ones, so a late
    /// callback of the old session never touches the new one's converter.
    private var normalizer = PCMNormalizer()
    private var clock: CMClock?

    private let queue = DispatchQueue(label: "tween.mic", qos: .userInitiated)
    private let dataQueue = DispatchQueue(label: "tween.mic.data", qos: .userInitiated)

    // queue only
    private var generation = 0
    private var session: AVCaptureSession?
    private var engine: AVAudioEngine?
    private var observers: [NSObjectProtocol] = []

    func start(deviceID: String?, removeGameSound: Bool) {
        queue.async {
            self.teardown()
            self.generation += 1
            self.begin(deviceID: deviceID, removeGameSound: removeGameSound, generation: self.generation)
        }
    }

    func stop() {
        queue.async {
            self.teardown()
            self.generation += 1
            self.onState?(.off)
        }
    }

    // MARK: - queue

    private func begin(deviceID: String?, removeGameSound: Bool, generation: Int) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            onState?(.needsPermission)
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard let self else { return }
                self.queue.async {
                    guard generation == self.generation else { return }
                    if granted {
                        self.begin(deviceID: deviceID, removeGameSound: removeGameSound, generation: generation)
                    } else {
                        self.onState?(.denied)
                    }
                }
            }
            return
        default:
            onState?(.denied)
            return
        }

        let device = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? (deviceID == nil ? AVCaptureDevice.default(for: .audio) : nil)
        guard let device else {
            onState?(.unavailable(deviceID == nil ? "No microphone" : "Microphone"))
            return
        }
        lock.lock()
        normalizer = PCMNormalizer()
        clock = nil
        lock.unlock()
        if removeGameSound {
            if startVoiceProcessing(device: device, generation: generation) { return }
            if startPlain(device: device, generation: generation) { onState?(.plainFallback(device.localizedName)) }
        } else if startPlain(device: device, generation: generation) {
            onState?(.running(device.localizedName))
        }
    }

    private func teardown() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if let session {
            session.stopRunning()
            for output in session.outputs { (output as? AVCaptureAudioDataOutput)?.setSampleBufferDelegate(nil, queue: nil) }
        }
        session = nil
        lock.lock()
        clock = nil
        lock.unlock()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    /// Reports `.unavailable` and lets go of the hardware.
    private func lost(_ device: AVCaptureDevice, generation: Int) {
        guard generation == self.generation else { return }
        teardown()
        onState?(.unavailable(device.localizedName))
    }

    // MARK: Plain path

    private func startPlain(device: AVCaptureDevice, generation: Int) -> Bool {
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input), session.canAddOutput(output) else { throw CocoaError(.featureUnsupported) }
            session.addInput(input)
            session.addOutput(output)
        } catch {
            onState?(.unavailable(device.localizedName))
            return false
        }
        output.setSampleBufferDelegate(self, queue: dataQueue)
        self.session = session
        lock.lock()
        clock = session.synchronizationClock
        lock.unlock()
        observers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [weak self] _ in
            self?.queue.async { self?.lost(device, generation: generation) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] _ in
            self?.queue.async { self?.lost(device, generation: generation) }
        })
        session.startRunning()
        return true
    }

    // MARK: Voice processing path

    private func startVoiceProcessing(device: AVCaptureDevice, generation: Int) -> Bool {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        do {
            try input.setVoiceProcessingEnabled(true)
            guard var unit = Self.audioDeviceID(forUID: device.uniqueID), let audioUnit = input.audioUnit,
                  AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &unit, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
            else { throw CocoaError(.featureUnsupported) }
            // Other sound (the game) is lowered as little as macOS allows.
            input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false, duckingLevel: .min)
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw CocoaError(.featureUnsupported) }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
                self?.deliver(buffer, at: when)
            }
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            engine.stop()
            return false
        }
        self.engine = engine
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.queue.async { self?.engineChanged(device, generation: generation) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [weak self] _ in
            self?.queue.async { self?.lost(device, generation: generation) }
        })
        onState?(.running(device.localizedName))
        return true
    }

    /// The route changed under the engine: it stopped itself. Start it again unless the device is gone.
    private func engineChanged(_ device: AVCaptureDevice, generation: Int) {
        guard generation == self.generation, let engine else { return }
        guard device.isConnected else { return lost(device, generation: generation) }
        guard !engine.isRunning else { return }
        // Starting with a tap of the old format can raise an exception, so it is put in again first.
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return lost(device, generation: generation) }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
            self?.deliver(buffer, at: when)
        }
        if (try? engine.start()) == nil { lost(device, generation: generation) }
    }

    /// Tap thread. Voice processing can report several channels with the voice in the first only, so that
    /// one is taken and the normalizer sends it to both sides.
    private func deliver(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime) {
        lock.lock()
        let onSamples = samplesHandler, normalizer = normalizer
        lock.unlock()
        guard let onSamples, let first = Self.firstChannel(of: buffer),
              let samples = normalizer.samples(from: first), !samples.isEmpty else { return }
        let time = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : CACurrentMediaTime()
        onSamples(samples, time)
    }

    /// Channel 0 of a Float buffer as a mono buffer.
    static func firstChannel(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        guard buffer.format.commonFormat == .pcmFormatFloat32, frames > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                                         channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let dst = out.floatChannelData?[0] else { return nil }
        out.frameLength = buffer.frameLength
        if buffer.format.isInterleaved {
            guard let src = buffer.audioBufferList.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self) else { return nil }
            let stride = Int(buffer.format.channelCount)
            for i in 0..<frames { dst[i] = src[i * stride] }
        } else {
            guard let src = buffer.floatChannelData?[0] else { return nil }
            dst.update(from: src, count: frames)
        }
        return out
    }

    private static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), uidPointer, &size, &deviceID)
        }
        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
    }
}

extension MicInput: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock()
        let onSamples = samplesHandler, normalizer = normalizer, clock = clock
        lock.unlock()
        guard let onSamples, let samples = normalizer.samples(from: sampleBuffer), !samples.isEmpty else { return }
        let hostClock = CMClockGetHostTimeClock()
        let time = CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                                     from: clock ?? hostClock, to: hostClock)
        onSamples(samples, time.seconds)
    }
}
