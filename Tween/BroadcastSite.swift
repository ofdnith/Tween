import Foundation

/// Pauses between reconnect attempts. Spent attempts come back once a connection has stayed up.
struct ReconnectPolicy {
    static let pauses: [Double] = [1, 2, 4, 8, 16]
    /// How long a connection must keep publishing before the attempts are reset.
    static let steadyTime: Double = 10

    private(set) var attempts = 0

    /// The pause before the next attempt; nil after five.
    mutating func nextPause() -> Double? {
        guard attempts < Self.pauses.count else { return nil }
        attempts += 1
        return Self.pauses[attempts - 1]
    }

    mutating func reset() {
        attempts = 0
    }
}

/// One site of a broadcast: its connection, replaced when it is lost, and its stream clock. Video
/// comes from an encoder that sites with the same canvas and bitrate share. Queue only: every
/// method runs on the broadcaster's queue, which the connections use too.
final class BroadcastSite {
    struct StartError: Error { let text: String }

    enum State: Equatable { case connecting, live, reconnecting(Int), failed(String), closed }

    let quality: StreamQuality
    let bitrate: Int
    /// Reports state changes, on the queue. `.failed` and `.closed` are final.
    var onState: ((State) -> Void)?
    /// Asks the shared encoder for a keyframe: each new connection must start with one.
    var onNeedsKeyframe: (() -> Void)?

    private let target: RTMPConnection.Target
    private let queue: DispatchQueue
    /// Shortens pauses and timeouts in the checks.
    private let timeScale: Double
    private var connection: RTMPConnection?
    private var policy = ReconnectPolicy()
    private var hasPublished = false
    private var publishing = false
    private var finished = false
    private var closing = false
    private var retry: DispatchWorkItem?
    private var steady: DispatchWorkItem?

    /// Host time of stream time zero: the first keyframe sent on this connection. Sound uses it too.
    private var zero: Double?
    private var sps: Data?
    private var pps: Data?
    private var lastVideo: UInt32 = 0
    private var lastAudio: UInt32 = 0

    /// (host time, bytes sent on this connection), for the rate actually sent.
    private var samples: [(time: Double, bytes: Int)] = []

    init(config: StreamSiteConfig, quality: StreamQuality, bitrate: Int, queue: DispatchQueue, timeScale: Double = 1) throws {
        guard let target = RTMPConnection.Target(server: config.server, key: config.key) else {
            throw StartError(text: "Check the server address in Settings")
        }
        self.quality = quality
        self.bitrate = bitrate
        self.queue = queue
        self.target = target
        self.timeScale = timeScale
    }

    /// True while frames for this site are wanted: its connection is publishing.
    var wantsFrames: Bool { publishing && !finished }

    /// True while the connection's send queue is throwing video away.
    var isTooSlow: Bool { publishing && connection?.isDropping == true }

    func start() {
        connect()
    }

    /// One encoded frame from the shared encoder. Late frames (after a close or a lost connection) are dropped.
    func encoded(_ frame: StreamVideoEncoder.Frame) {
        guard publishing, !finished, let connection else { return }
        let time = frame.time.seconds
        guard time.isFinite else { return }
        if zero == nil {
            // Each connection starts with metadata, both sequence headers, then a keyframe at 0.
            // Video before the first keyframe that actually arrives is left out.
            guard frame.keyframe, let sps = frame.sps, let pps = frame.pps else { return }
            let header = FLV.avcSequenceHeader(sps: sps, pps: pps)
            guard !header.isEmpty else { return fail("The video encoder's output can't be streamed") }
            let size = quality.size
            connection.send(metadata: FLV.metadata(width: size.width, height: size.height, frameRate: 60,
                                                   videoKbps: bitrate / 1000, audioKbps: 160))
            connection.send(video: header, timestamp: 0, keyframe: true)
            connection.send(audio: FLV.aacSequenceHeader(), timestamp: 0)
            self.sps = sps
            self.pps = pps
            zero = time
        } else if frame.keyframe, let sps = frame.sps, let pps = frame.pps, sps != self.sps || pps != self.pps {
            // The parameter sets changed: the decoder needs the new ones before this keyframe.
            let header = FLV.avcSequenceHeader(sps: sps, pps: pps)
            guard !header.isEmpty else { return fail("The video encoder's output can't be streamed") }
            self.sps = sps
            self.pps = pps
            connection.send(video: header, timestamp: timestamp(for: time), keyframe: true)
        }
        let stamp = timestamp(for: time)
        lastVideo = stamp
        connection.send(video: FLV.avcFrame(frame.avcc, keyframe: frame.keyframe), timestamp: stamp, keyframe: frame.keyframe)
    }

    /// One AAC frame (FLV body) whose sound starts at `hostTime`.
    func send(audio: Data, hostTime: Double) {
        guard publishing, !finished, let zero, hostTime >= zero, let connection else { return }
        let timestamp = max(lastAudio, Self.milliseconds(hostTime - zero))
        lastAudio = timestamp
        connection.send(audio: audio, timestamp: timestamp)
    }

    /// Bits per second sent over the last `window` seconds of this connection; nil until there is a second to measure.
    func sentBitrate(now: Double, window: Double = 2) -> Double? {
        guard publishing, let connection else { return nil }
        samples.append((now, connection.sentBytes))
        samples.removeAll { now - $0.time > window + 0.01 }
        guard let first = samples.first, now - first.time >= 0.9 else { return nil }
        return Double(connection.sentBytes - first.bytes) * 8 / (now - first.time)
    }

    /// Ends this site with `text` as its failure, closing its connection. Reported through `onState`.
    func stop(because text: String) {
        fail(text)
    }

    /// Unpublishes and closes. `completion` runs on the queue. Frames the shared encoder still
    /// finishes must already be queued (invalidate the encoder first) to go out before the close.
    func close(completion: @escaping () -> Void) {
        retry?.cancel()
        steady?.cancel()
        guard !finished else { return queue.async(execute: completion) }
        closing = true
        queue.async {
            guard let connection = self.connection else {
                self.finish(.closed)
                return completion()
            }
            connection.close(completion: completion)
        }
    }

    // MARK: - Connections

    private func connect() {
        guard !finished, !closing else { return }
        let connection = RTMPConnection(target: target, queue: queue)
        // Shortened in the checks, but never so short that a real handshake can't finish.
        connection.connectTimeout = max(1, RTMPConnection.connectTimeout * timeScale)
        connection.onState = { [weak self, weak connection] state in
            guard let self, let connection, connection === self.connection else { return }
            self.connectionChanged(state)
        }
        self.connection = connection
        connection.start()
    }

    private func connectionChanged(_ state: RTMPConnection.State) {
        switch state {
        case .connecting:
            break
        case .publishing:
            publishing = true
            hasPublished = true
            zero = nil
            sps = nil
            pps = nil
            lastVideo = 0
            lastAudio = 0
            samples = []
            onNeedsKeyframe?()
            onState?(.live)
            let steady = DispatchWorkItem { [weak self] in self?.policy.reset() }
            self.steady = steady
            queue.asyncAfter(deadline: .now() + ReconnectPolicy.steadyTime * timeScale, execute: steady)
        case .closed:
            publishing = false
            finish(.closed)
        case .failed(let text):
            publishing = false
            steady?.cancel()
            let refused = connection?.refusedByServer == true
            connection = nil
            if closing { return finish(.closed) }
            // A site that never took the stream, or that said no, won't on a retry either.
            guard hasPublished, !refused else { return finish(.failed(text)) }
            guard let pause = policy.nextPause() else { return finish(.failed("Connection lost")) }
            onState?(.reconnecting(policy.attempts))
            let retry = DispatchWorkItem { [weak self] in self?.connect() }
            self.retry = retry
            queue.asyncAfter(deadline: .now() + pause * timeScale, execute: retry)
        }
    }

    private func finish(_ state: State) {
        guard !finished else { return }
        finished = true
        publishing = false
        retry?.cancel()
        steady?.cancel()
        onState?(state)
    }

    private func fail(_ text: String) {
        guard !finished else { return }
        connection?.close()
        connection = nil
        finish(.failed(text))
    }

    private func timestamp(for time: Double) -> UInt32 {
        guard let zero else { return 0 }
        return max(lastVideo, Self.milliseconds(time - zero))
    }

    private static func milliseconds(_ seconds: Double) -> UInt32 {
        UInt32(clamping: Int64((max(0, seconds) * 1000).rounded()))
    }
}
