import Foundation
import Network
import Security

/// Publishes one stream to an RTMP(S) ingest server: handshake, connect, createStream, publish,
/// then media. Every method may be called from any thread; the work runs on `queue`, and
/// `sentBytes` should be read there.
final class RTMPConnection {
    struct Target: Equatable {
        let host: String
        let port: UInt16
        let tls: Bool
        let app: String
        let key: String

        /// `server` is "rtmps://host[:port]/app[?query]"; plain `rtmp://` exists for the local test server.
        /// A query stays on the app name, as librtmp keeps it (YouTube's backup ingest is `live2?backup=1`).
        init?(server: String, key: String) {
            let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty,
                  let url = URLComponents(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let scheme = url.scheme?.lowercased(), scheme == "rtmp" || scheme == "rtmps",
                  let host = url.host, !host.isEmpty else { return nil }
            var app = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !app.isEmpty else { return nil }
            if let query = url.percentEncodedQuery, !query.isEmpty { app += "?" + query }
            let tls = scheme == "rtmps"
            var port: UInt16 = tls ? 443 : 1935
            if let explicit = url.port {
                guard let value = UInt16(exactly: explicit), value > 0 else { return nil }
                port = value
            }
            self.host = host
            self.port = port
            self.tls = tls
            self.app = app
            self.key = key
        }

        /// Whether a server address sends the key unencrypted: plain `rtmp://` to anything but this Mac.
        static func sendsKeyInClear(server: String) -> Bool {
            guard let url = URLComponents(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
                  url.scheme?.lowercased() == "rtmp", let host = url.host?.lowercased(), !host.isEmpty else { return false }
            return !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        }

        /// The server's address as sent in `connect`. It never contains the key.
        var tcUrl: String {
            let scheme = tls ? "rtmps" : "rtmp"
            let host = self.host.contains(":") ? "[\(self.host)]" : self.host
            let port = self.port == (tls ? 443 : 1935) ? "" : ":\(self.port)"
            return "\(scheme)://\(host)\(port)/\(app)"
        }
    }

    enum State: Equatable { case connecting, publishing, failed(String), closed }

    static let connectTimeout: TimeInterval = 10
    /// A send the network hasn't taken for this long means the connection is dead, even if no error came.
    static let stallTimeout: TimeInterval = 10
    /// How long `close` waits for FCUnpublish and deleteStream to go out before cancelling anyway.
    static let closeTimeout: TimeInterval = 2

    private static let handshakeSize = 1536
    private static let outgoingChunkSize: UInt32 = 4096
    /// RTMP reads are capped at 64 KB so the chunk reader never sees more at once.
    private static let maxRead = 65536

    // Chunk stream IDs: protocol control, commands, audio, data, video.
    private static let controlChunkStream: UInt8 = 2
    private static let commandChunkStream: UInt8 = 3
    private static let audioChunkStream: UInt8 = 4
    private static let dataChunkStream: UInt8 = 5
    private static let videoChunkStream: UInt8 = 6

    // Transaction IDs of the publish sequence.
    private enum Step: Double { case connect = 1, createStream = 4, publish = 5 }
    private static let releaseStreamTransaction: Double = 2
    private static let fcPublishTransaction: Double = 3

    var onState: ((State) -> Void)?
    /// Set before `start`.
    var connectTimeout = RTMPConnection.connectTimeout
    /// Set before `start`.
    var stallTimeout = RTMPConnection.stallTimeout
    private(set) var sentBytes = 0
    /// True while the network is too slow and video is being thrown away.
    var isDropping: Bool { sendQueue.isDropping }
    /// The failure was the server saying no (`_error`, a refused publish) before publishing, not the network.
    /// An error status once publishing is a lost stream, which may come back.
    private(set) var refusedByServer = false

    private let target: Target
    private let queue: DispatchQueue
    private let connection: NWConnection
    private var state: State = .connecting
    private var started = false
    private var closing = false
    private var closeCompletions: [() -> Void] = []
    private var connectDeadline: DispatchWorkItem?
    /// Why the network is still trying, shown if the connect deadline passes.
    private var waitingError: String?
    private var sendStarted = 0.0

    private var handshake: [UInt8] = []
    private var sentC2 = false
    private var handshakeDone = false
    private var awaiting: Step?
    private var streamID: UInt32?

    private var reader = RTMPChunkReader()
    private var writer = RTMPChunkWriter()
    private var sendQueue = RTMPSendQueue()
    private var sending = false
    /// Control items carry the latest media timestamp so they don't skew the queue's backlog measure.
    private var lastMediaTimestamp: UInt32 = 0

    private var bytesReceived: UInt64 = 0
    private var acknowledgedBytes: UInt64 = 0
    private var peerWindow: UInt64 = 0

    init(target: Target, queue: DispatchQueue) {
        self.target = target
        self.queue = queue
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        // Default TLS options: the system validates the server's certificate.
        let parameters = NWParameters(tls: target.tls ? NWProtocolTLS.Options() : nil, tcp: tcp)
        connection = NWConnection(
            host: NWEndpoint.Host(target.host),
            port: NWEndpoint.Port(rawValue: target.port) ?? 1935,
            using: parameters)
    }

    deinit {
        connection.cancel()
    }

    static func redact(_ text: String, key: String) -> String {
        key.isEmpty ? text : text.replacingOccurrences(of: key, with: "•••")
    }

    func start() {
        queue.async { [self] in
            guard !started, !closing, !isFinished else { return }
            started = true
            setState(.connecting)
            connection.stateUpdateHandler = { [weak self] state in self?.connectionChanged(state) }
            connection.start(queue: queue)
            let deadline = DispatchWorkItem { [weak self] in
                guard let self, self.state == .connecting else { return }
                self.fail(self.waitingError ?? "No answer from the server")
            }
            connectDeadline = deadline
            queue.asyncAfter(deadline: .now() + connectTimeout, execute: deadline)
            watchSends()
        }
    }

    func send(metadata: Data) {
        queue.async { [self] in
            guard canSendMedia, let streamID else { return }
            let message = RTMPMessage(type: RTMPMessage.Kind.data.rawValue, streamID: streamID, timestamp: 0, payload: metadata)
            enqueue(message, chunkStream: Self.dataChunkStream)
        }
    }

    func send(video: Data, timestamp: UInt32, keyframe: Bool) {
        queue.async { [self] in
            guard canSendMedia, let streamID else { return }
            lastMediaTimestamp = timestamp
            let message = RTMPMessage(type: RTMPMessage.Kind.video.rawValue, streamID: streamID, timestamp: timestamp, payload: video)
            sendQueue.enqueue(Self.videoItem(video, bytes: writer.chunks(for: message, chunkStreamID: Self.videoChunkStream),
                                             timestamp: timestamp, keyframe: keyframe))
            pump()
        }
    }

    func send(audio: Data, timestamp: UInt32) {
        queue.async { [self] in
            guard canSendMedia, let streamID else { return }
            lastMediaTimestamp = timestamp
            let message = RTMPMessage(type: RTMPMessage.Kind.audio.rawValue, streamID: streamID, timestamp: timestamp, payload: audio)
            enqueue(message, chunkStream: Self.audioChunkStream)
        }
    }

    /// FCUnpublish, deleteStream, then cancel. `completion` runs on `queue` once the state is final.
    func close(completion: (() -> Void)? = nil) {
        queue.async { [self] in
            if isFinished {
                completion?()
                return
            }
            if let completion { closeCompletions.append(completion) }
            guard !closing else { return }
            closing = true
            connectDeadline?.cancel()
            guard started else {
                finishClose()
                return
            }
            if let streamID {
                sendCommand("FCUnpublish", 6, [.null, .string(target.key)])
                sendCommand("deleteStream", 7, [.null, .number(Double(streamID))])
            }
            // Holds self strongly on purpose, so a caller that lets go right after `close` still gets its completion.
            queue.asyncAfter(deadline: .now() + Self.closeTimeout) { self.finishClose() }
            pump()
        }
    }

    // MARK: - State

    private var isFinished: Bool {
        switch state {
        case .failed, .closed: return true
        case .connecting, .publishing: return false
        }
    }

    private var canSendMedia: Bool { state == .publishing && !closing }

    private func setState(_ new: State) {
        state = new
        onState?(new)
    }

    private func refuse(_ text: String) {
        guard !isFinished else { return }
        refusedByServer = state != .publishing
        fail(text)
    }

    private func fail(_ text: String) {
        guard !isFinished else { return }
        if closing {
            finishClose()
            return
        }
        connectDeadline?.cancel()
        connection.cancel()
        setState(.failed(text))
    }

    private func finishClose() {
        guard closing, !isFinished else { return }
        connection.cancel()
        setState(.closed)
        let completions = closeCompletions
        closeCompletions = []
        completions.forEach { $0() }
    }

    private func connectionChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard !handshakeDone, !sentC2 else { return }
            var c0c1 = Data([0x03])
            let time = UInt32(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 1_000_000)
            c0c1.append(contentsOf: withUnsafeBytes(of: time.bigEndian, Array.init))
            c0c1.append(contentsOf: [0, 0, 0, 0])
            var generator = SystemRandomNumberGenerator()
            c0c1.append(contentsOf: (0..<Self.handshakeSize - 8).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
            enqueueRaw(c0c1)
            receive()
        case .failed(let error):
            fail(redact(Self.describe(error)))
        case .waiting(let error):
            // Retries by itself; the connect deadline bounds it.
            waitingError = redact(Self.describe(error))
        default:
            break
        }
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            return String(cString: strerror(code.rawValue))
        case .dns:
            return "Couldn't find the server"
        case .tls(let status):
            return (SecCopyErrorMessageString(status, nil) as String?) ?? "Secure connection failed (\(status))"
        default:
            return "\(error)"
        }
    }

    private func redact(_ text: String) -> String {
        Self.redact(text, key: target.key)
    }

    // MARK: - Receiving

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRead) { [weak self] data, _, isComplete, error in
            guard let self, !self.isFinished else { return }
            if let data, !data.isEmpty {
                self.handle(data)
                if self.isFinished { return }
            }
            if let error {
                self.fail(self.redact(Self.describe(error)))
            } else if isComplete {
                self.fail("The server closed the connection")
            } else {
                self.receive()
            }
        }
    }

    private func handle(_ data: Data) {
        bytesReceived += UInt64(data.count)
        var chunkBytes = data
        if !handshakeDone {
            handshake.append(contentsOf: data)
            let s0s1 = 1 + Self.handshakeSize
            if !sentC2, handshake.count >= s0s1 {
                guard handshake[0] == 0x03 else {
                    fail("The server doesn't speak RTMP")
                    return
                }
                enqueueRaw(Data(handshake[1..<s0s1]))
                sentC2 = true
            }
            let whole = s0s1 + Self.handshakeSize
            guard handshake.count >= whole else { return }
            chunkBytes = Data(handshake[whole...])
            handshake = []
            handshakeDone = true
            // A close during the handshake ends it: no connect after that.
            if closing { return }
            beginSession()
        }
        guard !chunkBytes.isEmpty else { return }

        let messages: [RTMPMessage]
        do {
            messages = try reader.append(chunkBytes)
        } catch {
            fail("The server sent data Tween can't read")
            return
        }
        for message in messages {
            handle(message)
            if isFinished { return }
        }
        acknowledgeIfNeeded()
    }

    private func handle(_ message: RTMPMessage) {
        let payload = [UInt8](message.payload)
        switch RTMPMessage.Kind(rawValue: message.type) {
        case .userControl:
            // Ping request (6) is answered with a ping response (7) carrying the same 4 bytes.
            guard payload.count >= 6, payload[0] == 0, payload[1] == 6 else { return }
            sendControl(.userControl, Data([0, 7] + payload[2..<6]))
        case .windowAckSize:
            guard payload.count >= 4 else { return }
            peerWindow = UInt64(payload[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        case .command:
            handleCommand(message.payload)
        default:
            break
        }
    }

    private func acknowledgeIfNeeded() {
        guard peerWindow > 0, bytesReceived - acknowledgedBytes >= peerWindow else { return }
        acknowledgedBytes = bytesReceived
        let sequence = UInt32(truncatingIfNeeded: bytesReceived)
        sendControl(.acknowledgement, Data(withUnsafeBytes(of: sequence.bigEndian, Array.init)))
    }

    private func handleCommand(_ payload: Data) {
        // Once closing, no further step: never publish into a close.
        if closing { return }
        let values: [AMF0]
        do {
            values = try AMF0.decode(payload)
        } catch {
            // Only matters when it is the answer a step is waiting for; anything else is ignored.
            guard let (name, transaction) = Self.commandHeader(payload), let awaiting else { return }
            let answersStep = (name == "_result" || name == "_error") && transaction == awaiting.rawValue
            if answersStep || (name == "onStatus" && awaiting == .publish) {
                fail("The server sent an answer Tween can't read")
            }
            return
        }
        guard case .string(let name)? = values.first else { return }
        var transaction: Double?
        if values.count > 1, case .number(let number) = values[1] { transaction = number }
        let info = values.dropFirst(2).first { if case .object = $0 { return true } else { return false } }

        switch name {
        case "_result":
            if transaction == Step.connect.rawValue, awaiting == .connect {
                awaiting = .createStream
                sendCommand("releaseStream", Self.releaseStreamTransaction, [.null, .string(target.key)])
                sendCommand("FCPublish", Self.fcPublishTransaction, [.null, .string(target.key)])
                sendCommand("createStream", Step.createStream.rawValue, [.null])
            } else if transaction == Step.createStream.rawValue, awaiting == .createStream {
                let number = values.dropFirst(2).lazy.compactMap { value -> Double? in
                    if case .number(let n) = value { return n } else { return nil }
                }.first
                guard let number, let id = UInt32(exactly: number) else {
                    fail("The server didn't open a stream")
                    return
                }
                streamID = id
                awaiting = .publish
                sendCommand("publish", Step.publish.rawValue, [.null, .string(target.key), .string("live")], streamID: id)
            }
        case "_error":
            // Errors for releaseStream and FCPublish are historical leftovers some servers send; ignore them.
            if transaction == Self.releaseStreamTransaction || transaction == Self.fcPublishTransaction { return }
            refuse(serverText(info, fallback: "The server refused the connection"))
        case "onStatus":
            if case .string("NetStream.Publish.Start")? = info?["code"], awaiting == .publish {
                awaiting = nil
                connectDeadline?.cancel()
                setState(.publishing)
            } else if case .string("error")? = info?["level"] {
                refuse(serverText(info, fallback: "The server refused the stream"))
            }
        default:
            break
        }
    }

    /// The server's description (or code) with the key removed; `fallback` when there is nothing left.
    private func serverText(_ info: AMF0?, fallback: String) -> String {
        var text = ""
        if case .string(let description)? = info?["description"] {
            text = description
        } else if case .string(let code)? = info?["code"] {
            text = code
        }
        let redacted = redact(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return redacted.isEmpty ? fallback : redacted
    }

    /// Name and transaction ID of a command whose full payload doesn't decode.
    private static func commandHeader(_ payload: Data) -> (String, Double?)? {
        let bytes = [UInt8](payload)
        guard bytes.count >= 3, bytes[0] == 0x02 else { return nil }
        let length = Int(bytes[1]) << 8 | Int(bytes[2])
        guard bytes.count >= 3 + length else { return nil }
        let name = String(decoding: bytes[3..<3 + length], as: UTF8.self)
        let rest = bytes.dropFirst(3 + length)
        guard rest.count >= 9, rest.first == 0x00 else { return (name, nil) }
        let bits = rest.dropFirst().prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return (name, Double(bitPattern: bits))
    }

    // MARK: - Sending

    private func beginSession() {
        let size = Self.outgoingChunkSize
        sendControl(.setChunkSize, Data(withUnsafeBytes(of: size.bigEndian, Array.init)))
        // Only chunks written after the Set Chunk Size message may use the new size.
        writer.chunkSize = Int(size)
        awaiting = .connect
        sendCommand("connect", Step.connect.rawValue, [.object([
            .init(key: "app", value: .string(target.app)),
            .init(key: "type", value: .string("nonprivate")),
            .init(key: "flashVer", value: .string("FMLE/3.0 (compatible; Tween)")),
            .init(key: "tcUrl", value: .string(target.tcUrl)),
        ])])
    }

    private func sendControl(_ kind: RTMPMessage.Kind, _ payload: Data) {
        let message = RTMPMessage(type: kind.rawValue, streamID: 0, timestamp: 0, payload: payload)
        enqueue(message, chunkStream: Self.controlChunkStream)
    }

    private func sendCommand(_ name: String, _ transaction: Double, _ arguments: [AMF0], streamID: UInt32 = 0) {
        var payload = Data()
        AMF0.string(name).encode(into: &payload)
        AMF0.number(transaction).encode(into: &payload)
        arguments.forEach { $0.encode(into: &payload) }
        let message = RTMPMessage(type: RTMPMessage.Kind.command.rawValue, streamID: streamID, timestamp: 0, payload: payload)
        enqueue(message, chunkStream: Self.commandChunkStream)
    }

    /// Anything but video, which `send(video:)` queues itself so the queue can drop it. Protocol
    /// control and commands (ping replies, acknowledgements, FCUnpublish) go ahead of queued media:
    /// they are on chunk streams of their own, so the order within each chunk stream is kept.
    private func enqueue(_ message: RTMPMessage, chunkStream: UInt8) {
        let bytes = writer.chunks(for: message, chunkStreamID: chunkStream)
        let isMedia = message.type == RTMPMessage.Kind.video.rawValue || message.type == RTMPMessage.Kind.audio.rawValue
        let timestamp = isMedia ? message.timestamp : lastMediaTimestamp
        let isControl = chunkStream == Self.controlChunkStream || chunkStream == Self.commandChunkStream
        sendQueue.enqueue(.init(bytes: bytes, timestamp: timestamp, isVideo: false, isKeyframe: false, isControl: isControl))
        pump()
    }

    /// The decoder can't start without the sequence header, so the queue must never drop it: it isn't queued as video.
    static func videoItem(_ video: Data, bytes: Data, timestamp: UInt32, keyframe: Bool) -> RTMPSendQueue.Item {
        let isSequenceHeader = video.count >= 2 && video[video.startIndex + 1] == 0
        return .init(bytes: bytes, timestamp: timestamp, isVideo: !isSequenceHeader, isKeyframe: keyframe)
    }

    /// The handshake: control, so the commands that follow it never overtake it.
    private func enqueueRaw(_ bytes: Data) {
        sendQueue.enqueue(.init(bytes: bytes, timestamp: lastMediaTimestamp, isVideo: false, isKeyframe: false, isControl: true))
        pump()
    }

    /// One `NWConnection.send` at a time, so the backlog stays in the queue where it can be trimmed.
    private func pump() {
        guard !sending, !isFinished else { return }
        guard let item = sendQueue.next() else {
            if closing { finishClose() }
            return
        }
        sending = true
        sendStarted = Self.seconds()
        connection.send(content: item.bytes, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.sending = false
            if let error {
                self.fail(self.redact(Self.describe(error)))
                return
            }
            self.sentBytes += item.bytes.count
            self.pump()
        })
    }

    private static func seconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    /// A dead network may never report an error: a send it hasn't taken for `stallTimeout` counts as lost.
    private func watchSends() {
        let interval = min(1, stallTimeout / 4)
        queue.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self, !self.isFinished else { return }
            if self.sending, Self.seconds() - self.sendStarted > self.stallTimeout {
                self.fail("The network stopped taking data")
                return
            }
            self.watchSends()
        }
    }
}

extension RTMPConnection.Target: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The address without the key, so printing a target never shows it (not even pasted into the address).
    var description: String { "\(RTMPConnection.redact(tcUrl, key: key)) (key hidden)" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["tcUrl": RTMPConnection.redact(tcUrl, key: key)], displayStyle: .struct)
    }
}
