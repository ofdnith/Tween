import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// Hardware H.264 encoder for the stream. Takes BGRA buffers, emits AVCC frames (4-byte length
/// prefixed NAL units) with the parameter sets on keyframes. Never falls back to software.
final class StreamVideoEncoder {
    struct Frame {
        let avcc: Data
        let keyframe: Bool
        let time: CMTime
        let sps: Data?
        let pps: Data?
    }

    private static let cacheLock = NSLock()
    private static var availability: [String: Bool] = [:]

    /// Tries to create a hardware-only session at this size. The answer is cached per size.
    static func hardwareAvailable(width: Int, height: Int) -> Bool {
        let key = "\(width)x\(height)"
        cacheLock.lock()
        if let known = availability[key] { cacheLock.unlock(); return known }
        cacheLock.unlock()
        let session = makeSession(width: width, height: height)
        if let session { VTCompressionSessionInvalidate(session) }
        let available = session != nil
        cacheLock.lock()
        availability[key] = available
        cacheLock.unlock()
        return available
    }

    private static func makeSession(width: Int, height: Int) -> VTCompressionSession? {
        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        return status == noErr ? session : nil
    }

    /// Holds the stream to the target byte rate, which the hardware encoder does not (measured:
    /// it overshoots its average bitrate and data rate limit by 50% and more on busy pictures and
    /// ignores CBR, QP limits and quality). It drops input frames rather than letting a burst out.
    ///
    /// Invariant: a frame is admitted only if the bytes output in the last second of presentation
    /// time, plus every frame in flight costed at the larger of its reservation and the current
    /// estimate for its kind, plus the frame itself (a keyframe with a quarter more), fit the
    /// target. Estimates are the largest of the last 8 deltas in the last second (a keyframe:
    /// the last keyframe, never less than a delta), falling back to the largest frame there is.
    /// So a second goes over only by what frames outgrow their estimates. A lone frame (nothing
    /// in the window or in flight) is always admitted: a frame bigger than the budget would
    /// otherwise stop the stream.
    ///
    /// The window alone lets a burst through at the start of each second and refuses the rest,
    /// so delta frames are also paced by a credit charged with their actual size. It refills at
    /// the target less a keyframe (one comes every 2 s, so every second is within a second of
    /// one), and just before a keyframe is due deltas leave it its room. The pace yields after
    /// three drops in a row, so viewers see a lower frame rate rather than a frozen picture; the
    /// window never yields, since holding the rate comes first.
    /// Possible later improvement: lower the session's average bitrate while shedding, so the
    /// encoder stops spending the dropped frames' budget on the frames it gets.
    private struct RateGuard {
        let target: Double
        /// Seconds after a keyframe when the guard forces the next one, a little before the
        /// encoder's own 2 s limit would, so the kind of every frame is known when it is costed.
        let keyframeInterval: Double
        /// How long before a keyframe is due deltas start leaving room for it.
        let lead: Double
        let frameDuration: Double
        private var window: [(time: Double, bytes: Int, keyframe: Bool)] = []
        private var windowBytes = 0
        private var inFlight: [(keyframe: Bool, reserved: Int, charged: Double, epoch: Int)] = []
        /// Counts input time restarts; frames sent before the last one land outside the window.
        private var epoch = 0
        private var largestSeen: Int?
        private var lastDeltaBytes = 0
        private var lastKeyframeBytes: Int?
        /// Time of the last keyframe output in this epoch. Only output counts, so a keyframe
        /// the encoder loses is asked for again.
        private var lastKeyframeTime: Double?
        private var lastTime: Double?
        /// Bytes delta frames may still take ahead of the pace.
        private var credit = 0.0
        private var creditStarted = false
        /// When the credit started (stream start or time restart).
        private var creditStart = 0.0
        private var dropsInRow = 0
        /// Set while a keyframe is wanted and not yet handed to the encoder.
        private var keyframePending = false

        init(target: Double, frameRate: Int) {
            self.target = target
            frameDuration = 1 / Double(max(frameRate, 1))
            keyframeInterval = 2 - 1.5 * frameDuration
            lead = 3 * frameDuration
        }

        private func cost(keyframe: Bool) -> Int? {
            // Recent deltas only: the first ones after a keyframe run large while the encoder
            // settles, and costing every delta at those for a whole second stalls the stream.
            let deltas = window.lazy.filter { !$0.keyframe }.suffix(8).map(\.bytes).max()
            let delta = deltas ?? window.lazy.map(\.bytes).max() ?? largestSeen
            guard keyframe else { return delta }
            guard let last = lastKeyframeBytes ?? largestSeen else { return delta }
            return max(last, delta ?? 0)
        }

        /// Returns whether the frame should be a keyframe, or nil to drop it. An admitted frame
        /// must be followed by `sent` or `failed`.
        mutating func admit(at time: Double, forceKeyframe: Bool) -> Bool? {
            if let last = lastTime, time < last {
                // Input time went backwards: the old window says nothing about the new stretch,
                // and frames still in flight from before belong to neither.
                window.removeAll()
                windowBytes = 0
                lastKeyframeTime = nil
                creditStarted = false
                epoch += 1
            }
            let elapsed = lastTime.map { min(max(time - $0, 0), 1) } ?? 0
            lastTime = time
            while let first = window.first, first.time <= time - 1 {
                windowBytes -= first.bytes
                window.removeFirst()
            }
            let keyframeInFlight = inFlight.contains { $0.keyframe && $0.epoch == epoch }
            let sinceKeyframe = lastKeyframeTime.map { time - $0 } ?? .infinity
            if forceKeyframe || (!keyframeInFlight && sinceKeyframe >= keyframeInterval) {
                keyframePending = true
            }
            let keyframe = keyframePending
            // Shortly before one is due, deltas leave the keyframe its room, so it is not held
            // back for long once due (the 2 s spacing is what the ingest expects).
            let keyframeNear = !keyframeInFlight && sinceKeyframe >= keyframeInterval - lead
            // Every second is within a second of a keyframe, so deltas get what one leaves (with
            // the quarter it may grow by), so the window itself rarely has to refuse a frame:
            // that is what makes runs. A quarter second of credit absorbs uneven frame sizes, so
            // input already under the target is not thinned.
            let keyframeCost = Double(cost(keyframe: true) ?? 0)
            let pace = max(target - keyframeCost * 1.25, target / 4)
            // No credit to start with: in the first second nothing leaves the window, which then
            // has only a quarter keyframe to spare. The encoder's first deltas run large, though,
            // and dropping them can set it off on a path of larger frames (measured), so early in
            // that second the credit may be overdrawn by up to six frames, repaid by 0.9 s so the
            // yields after three drops still fit before the second ends.
            if !creditStarted { creditStart = time }
            credit = creditStarted ? min(credit + pace * elapsed, pace / 4) : 0
            creditStarted = true
            let overdraft = max(0, 0.9 - (time - creditStart)) / 0.9 * pace * 6 * frameDuration

            let lone = window.isEmpty && inFlight.isEmpty
            guard let candidate = cost(keyframe: keyframe) else {
                // Nothing has come out yet, so no size is known: one frame at a time.
                guard lone else { return drop() }
                inFlight.append((keyframe, 0, 0, epoch))
                dropsInRow = 0
                return keyframe
            }
            if !lone {
                if !keyframe && credit < -overdraft && dropsInRow < 3 { return drop() }
                let pending = inFlight.reduce(0) { $0 + max($1.reserved, cost(keyframe: $1.keyframe) ?? 0) }
                // A keyframe needs a quarter more room: fed sparsely, the encoder spends what drops
                // left unused on it (measured: 493 KB after a 368 KB one).
                let growth = keyframe ? Double(candidate) / 4 : 0
                let projected = Double(windowBytes + pending + candidate)
                if projected + growth > target {
                    // Credit saved while the window refuses would let a burst through after.
                    credit = min(credit, 0)
                    return drop()
                }
                // Only while shedding: input that fits has room for the keyframe anyway.
                if !keyframe && keyframeNear && credit < 0 && projected + keyframeCost > target { return drop() }
            }
            let charge = keyframe ? 0 : Double(lastDeltaBytes)
            inFlight.append((keyframe, candidate, charge, epoch))
            credit -= charge
            dropsInRow = 0
            return keyframe
        }

        private mutating func drop() -> Bool? {
            dropsInRow += 1
            return nil
        }

        /// The encoder took the frame admitted last.
        mutating func sent(keyframe: Bool) {
            if keyframe { keyframePending = false }
        }

        /// The encoder refused the frame admitted last; a keyframe request stays pending.
        mutating func failed() {
            guard let last = inFlight.popLast() else { return }
            credit += last.charged
        }

        /// The oldest frame in flight came out (no reordering, so output is in input order).
        mutating func landed(time: Double, bytes: Int, keyframe: Bool) {
            let entry = inFlight.isEmpty ? nil : inFlight.removeFirst()
            // Sent before input time restarted: its time is not on the new clock.
            if let entry, entry.epoch != epoch { return }
            window.append((time, bytes, keyframe))
            windowBytes += bytes
            largestSeen = max(largestSeen ?? 0, bytes)
            if keyframe {
                lastKeyframeBytes = bytes
                // The encoder may add one of its own; the schedule counts from it.
                lastKeyframeTime = time
            } else {
                // The credit was charged an estimate; settle it at the real size.
                credit += (entry?.charged ?? 0) - Double(bytes)
                lastDeltaBytes = bytes
            }
        }

        /// The oldest frame in flight failed in the encoder.
        mutating func lost() {
            guard !inFlight.isEmpty else { return }
            credit += inFlight.removeFirst().charged
        }

        /// The session was replaced: what was in flight in the old one never comes out, and the new
        /// one starts with a keyframe.
        mutating func restart() {
            for entry in inFlight { credit += entry.charged }
            inFlight.removeAll()
            keyframePending = true
        }
    }

    /// State the session's callback shares with the encoder. The callback holds this, never the
    /// encoder, so the last reference to the encoder can be dropped on any thread, including the
    /// VideoToolbox one.
    private final class Output {
        let lock = NSCondition()
        let onFrame: (Frame) -> Void
        var closed = false
        /// onFrame calls running now; invalidate waits for them.
        var delivering = 0
        /// Of those, the ones themselves waiting in another encoder's invalidate. Waiting for
        /// them could close a cycle (two encoders invalidating each other), so nobody does.
        var blocked = 0
        var dropped = 0
        var rate: RateGuard
        /// Counts session rebuilds; output from an older session is ignored.
        var generation = 0
        /// Frames handed to the current session that haven't come back.
        var pending = 0
        /// Since when a pending frame has been waiting for output (refreshed by each output).
        var waitingSince: Double?
        var failuresInRow = 0
        /// VideoToolbox said the session is gone (sleep/wake, its service crashed, a media reset).
        var sessionLost = false
        /// When the session first looked broken; cleared by the next frame that comes out.
        var brokenSince: Double?
        init(onFrame: @escaping (Frame) -> Void, rate: RateGuard) {
            self.onFrame = onFrame
            self.rate = rate
        }

        /// Per thread: the outputs whose onFrame that thread is inside.
        static let callbackKey = "StreamVideoEncoder.callbacks"
        static var activeOnThisThread: NSCountedSet? {
            Thread.current.threadDictionary[callbackKey] as? NSCountedSet
        }
    }

    private let lock = NSLock()
    private var session: VTCompressionSession?
    private let output: Output
    private let width: Int
    private let height: Int
    private let bitrate: Int
    private let frameRate: Int
    /// Lock: when the next rebuild may be tried, and whether recovery has given up.
    private var nextRebuild = 0.0
    private var gaveUp = false

    /// A broken session is rebuilt at most this often...
    static let rebuildInterval = 2.0
    /// ...and given up on when it hasn't produced a frame again for this long.
    static let recoveryLimit = 10.0
    /// Failed encodes in a row that count as a broken session.
    static let failureLimit = 30
    /// Checks only: scales the recovery's times.
    var recoveryTimeScale: Double {
        get { lock.lock(); defer { lock.unlock() }; return timeScale }
        set { lock.lock(); timeScale = newValue; lock.unlock() }
    }
    /// Checks only: sessions made for a rebuild fail.
    var refusesRebuildForChecks: Bool {
        get { lock.lock(); defer { lock.unlock() }; return refusesRebuild }
        set { lock.lock(); refusesRebuild = newValue; lock.unlock() }
    }
    // Lock: the two above.
    private var timeScale = 1.0
    private var refusesRebuild = false

    /// True once the session broke and rebuilding it hasn't brought frames back within
    /// `recoveryLimit`. The encoder then takes no more frames.
    var hasFailed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return gaveUp
    }

    /// Checks only: makes the last frame handed over look as if it has had no output for a long time.
    func stallForChecks() {
        output.lock.lock()
        output.pending = max(output.pending, 1)
        output.waitingSince = ProcessInfo.processInfo.systemUptime - 1000
        output.lock.unlock()
    }

    /// Checks only: tears the session down underneath the encoder, as a crashed encoder service would.
    func breakSessionForChecks() {
        lock.lock()
        defer { lock.unlock() }
        if let session { VTCompressionSessionInvalidate(session) }
    }

    /// Frames not encoded: refused by the session, failed or empty in the callback, or dropped
    /// by the rate guard.
    var droppedFrames: Int {
        output.lock.lock()
        defer { output.lock.unlock() }
        return output.dropped
    }

    init?(width: Int, height: Int, bitrate: Int, frameRate: Int, onFrame: @escaping (Frame) -> Void) {
        guard let session = Self.configuredSession(width: width, height: height, bitrate: bitrate, frameRate: frameRate) else {
            return nil
        }
        output = Output(onFrame: onFrame, rate: RateGuard(target: Double(bitrate) / 8, frameRate: frameRate))
        self.width = width
        self.height = height
        self.bitrate = bitrate
        self.frameRate = frameRate
        self.session = session
    }

    private static func configuredSession(width: Int, height: Int, bitrate: Int, frameRate: Int) -> VTCompressionSession? {
        guard let session = makeSession(width: width, height: height) else { return nil }
        func set(_ key: CFString, _ value: Any) -> Bool {
            VTSessionSetProperty(session, key: key, value: value as CFTypeRef) == noErr
        }
        // The hardware encoder treats the data rate limit as a hint and overshoots on busy
        // pictures (measured), so the guard in `encode` is what holds the rate. The limit and the
        // key frame duration are still set, but a Mac that rejects them is not refused.
        let required = set(kVTCompressionPropertyKey_RealTime, true)
            && set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
            && set(kVTCompressionPropertyKey_AllowFrameReordering, false)
            && set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 2 * frameRate)
            && set(kVTCompressionPropertyKey_AverageBitRate, bitrate)
            && set(kVTCompressionPropertyKey_ExpectedFrameRate, frameRate)
        _ = set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2)
        // Bytes per second: 1.2x the average, over a 1 s window.
        _ = set(kVTCompressionPropertyKey_DataRateLimits, [Double(bitrate) * 1.2 / 8, 1.0])
        // BT.709 for the conversion from BGRA and in the SPS, so the sites' transcoders don't guess.
        _ = set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        _ = set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        _ = set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        guard required, VTCompressionSessionPrepareToEncodeFrames(session) == noErr else {
            VTCompressionSessionInvalidate(session)
            return nil
        }
        return session
    }

    deinit {
        // Never block here: the owner may be any thread.
        lock.lock()
        let session = self.session
        self.session = nil
        lock.unlock()
        guard let session else { return }
        output.lock.lock()
        output.closed = true
        output.lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }

    /// Returns false when the frame was not accepted (counted in `droppedFrames`). If the rate
    /// guard drops a frame sent with `forceKeyframe`, the request is kept for the next one.
    @discardableResult
    func encode(_ buffer: CVPixelBuffer, at time: CMTime, forceKeyframe: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let output = self.output
        let now = ProcessInfo.processInfo.systemUptime
        recoverIfNeeded(now: now)
        guard let session else {
            output.lock.lock()
            if !output.closed { output.dropped += 1 }
            output.lock.unlock()
            return false
        }

        output.lock.lock()
        guard !output.closed, let keyframe = output.rate.admit(at: time.seconds, forceKeyframe: forceKeyframe) else {
            output.dropped += 1
            output.lock.unlock()
            return false
        }
        // Counted before the call: the handler may run before it returns.
        output.pending += 1
        if output.waitingSince == nil { output.waitingSince = now }
        let generation = output.generation
        output.lock.unlock()

        let properties: CFDictionary? = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        // The handler runs on VideoToolbox's thread.
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: buffer, presentationTimeStamp: time, duration: .invalid,
            frameProperties: properties, infoFlagsOut: nil
        ) { status, _, sample in
            Self.handle(status: status, sample: sample, output: output, generation: generation)
        }
        output.lock.lock()
        defer { output.lock.unlock() }
        // The handler is not called when the call itself fails.
        guard status == noErr else {
            output.rate.failed()
            output.dropped += 1
            output.pending -= 1
            if output.pending == 0 { output.waitingSince = nil }
            output.failuresInRow += 1
            if status == kVTInvalidSessionErr { output.sessionLost = true }
            return false
        }
        output.rate.sent(keyframe: keyframe)
        return true
    }

    /// Lock held. A session that VideoToolbox lost, that keeps failing, or that has held a frame
    /// for 2 s without output is replaced, at most every `rebuildInterval`. The new one starts
    /// with a keyframe, and sites resend the sequence header if its parameter sets differ.
    private func recoverIfNeeded(now: Double) {
        guard !gaveUp else { return }
        output.lock.lock()
        let stalled = output.waitingSince.map { now - $0 > Self.rebuildInterval * timeScale } ?? false
        // No session but not closed: a rebuild couldn't make one, so keep trying until the limit.
        let broken = !output.closed
            && (session == nil || output.sessionLost || output.failuresInRow >= Self.failureLimit || stalled)
        if broken && output.brokenSince == nil { output.brokenSince = now }
        let brokenSince = output.brokenSince
        output.lock.unlock()
        guard broken, let brokenSince else { return }

        if now - brokenSince >= Self.recoveryLimit * timeScale {
            gaveUp = true
            dropSession()
            return
        }
        guard now >= nextRebuild else { return }
        nextRebuild = now + Self.rebuildInterval * timeScale
        dropSession()
        let replacement = refusesRebuild ? nil
            : Self.configuredSession(width: width, height: height, bitrate: bitrate, frameRate: frameRate)
        output.lock.lock()
        output.generation += 1
        output.pending = 0
        output.waitingSince = nil
        output.rate.restart()
        if replacement != nil {
            output.sessionLost = false
            output.failuresInRow = 0
        }
        output.lock.unlock()
        session = replacement
    }

    /// Lock held. Lets go of a broken session without waiting on it: it may never answer.
    private func dropSession() {
        guard let old = session else { return }
        session = nil
        DispatchQueue.global(qos: .utility).async { VTCompressionSessionInvalidate(old) }
    }

    /// Completes pending frames, then tears the session down. No output follows its return.
    /// Called from an encoder's onFrame, it drops pending frames instead and finishes the
    /// teardown on another thread; an onFrame of this encoder that is itself inside an
    /// invalidate may then still be running.
    func invalidate() {
        let active = Output.activeOnThisThread
        if let active, active.count > 0 {
            // Neither the encoder's lock (a thread in `encode` may hold it while VideoToolbox
            // waits for this thread) nor the session may be waited on from here. Stop output now;
            // wait for onFrame calls on other threads unless this is one of ours.
            output.lock.lock()
            output.closed = true
            output.lock.unlock()
            if !active.contains(output) {
                let mine = active.allObjects.compactMap { $0 as? Output }
                for other in mine { other.lock.lock(); other.blocked += 1; other.lock.broadcast(); other.lock.unlock() }
                output.lock.lock()
                while output.delivering > output.blocked { output.lock.wait() }
                output.lock.unlock()
                for other in mine { other.lock.lock(); other.blocked -= 1; other.lock.unlock() }
            }
            DispatchQueue.global(qos: .utility).async { self.invalidate() }
            return
        }
        lock.lock()
        let session = self.session
        self.session = nil
        lock.unlock()
        if let session { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) }
        output.lock.lock()
        output.closed = true
        while output.delivering > 0 { output.lock.wait() }
        output.lock.unlock()
        if let session { VTCompressionSessionInvalidate(session) }
    }

    private static func handle(status: OSStatus, sample: CMSampleBuffer?, output: Output, generation: Int) {
        let frame = status == noErr ? sample.flatMap(makeFrame) : nil
        output.lock.lock()
        // From a session that has since been replaced: neither counted nor delivered.
        guard generation == output.generation else { output.lock.unlock(); return }
        output.pending = max(0, output.pending - 1)
        output.waitingSince = output.pending > 0 ? ProcessInfo.processInfo.systemUptime : nil
        guard let frame else {
            output.rate.lost()
            output.dropped += 1
            output.failuresInRow += 1
            if status == kVTInvalidSessionErr { output.sessionLost = true }
            output.lock.unlock()
            return
        }
        output.failuresInRow = 0
        output.brokenSince = nil
        output.rate.landed(time: frame.time.seconds, bytes: frame.avcc.count, keyframe: frame.keyframe)
        if output.closed { output.lock.unlock(); return }
        output.delivering += 1
        // Not held across onFrame: it may take a while or call back into the encoder.
        output.lock.unlock()

        let dictionary = Thread.current.threadDictionary
        let active = dictionary[Output.callbackKey] as? NSCountedSet ?? NSCountedSet()
        dictionary[Output.callbackKey] = active
        active.add(output)
        output.onFrame(frame)
        active.remove(output)

        output.lock.lock()
        output.delivering -= 1
        if output.delivering == 0 { output.lock.broadcast() }
        output.lock.unlock()
    }

    private static func makeFrame(_ sample: CMSampleBuffer) -> Frame? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        // Copied rather than read through the data pointer: the block need not be contiguous.
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return nil }
        var avcc = Data(count: length)
        let copied = avcc.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var keyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first, let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            keyframe = !notSync
        }

        var sps: Data?
        var pps: Data?
        if keyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            sps = Self.parameterSet(format, index: 0)
            pps = Self.parameterSet(format, index: 1)
        }
        return Frame(avcc: avcc, keyframe: keyframe, time: CMSampleBufferGetPresentationTimeStamp(sample), sps: sps, pps: pps)
    }

    private static func parameterSet(_ format: CMFormatDescription, index: Int) -> Data? {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
            parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return nil }
        return Data(bytes: pointer, count: size)
    }
}
