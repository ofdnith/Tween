import Foundation

/// Runs one connection on a private queue against a test server and records every state it reports.
private final class ConnectionProbe {
    let connection: RTMPConnection
    private let lock = NSLock()
    private var states: [RTMPConnection.State] = []
    private let changed = DispatchSemaphore(value: 0)

    convenience init(server: RTMPTestServer, key: String, connectTimeout: TimeInterval? = nil,
                     stallTimeout: TimeInterval? = nil) throws {
        try self.init(port: server.port, key: key, connectTimeout: connectTimeout, stallTimeout: stallTimeout)
    }

    init(port: UInt16, key: String, connectTimeout: TimeInterval? = nil, stallTimeout: TimeInterval? = nil) throws {
        guard let target = RTMPConnection.Target(server: "rtmp://127.0.0.1:\(port)/live", key: key) else {
            throw CheckFailure(description: "no target for the test server")
        }
        connection = RTMPConnection(target: target, queue: DispatchQueue(label: "RTMPConnectionChecks"))
        if let connectTimeout { connection.connectTimeout = connectTimeout }
        if let stallTimeout { connection.stallTimeout = stallTimeout }
        connection.onState = { [weak self] state in
            guard let self else { return }
            self.lock.lock()
            self.states.append(state)
            self.lock.unlock()
            self.changed.signal()
        }
        connection.start()
    }

    var history: [RTMPConnection.State] {
        lock.lock()
        defer { lock.unlock() }
        return states
    }

    /// Waits up to 5 s for a reported state that matches.
    func wait(for what: String, _ matches: (RTMPConnection.State) -> Bool) throws {
        let deadline = DispatchTime.now() + 5
        while !history.contains(where: matches) {
            guard changed.wait(timeout: deadline) == .success else {
                throw CheckFailure(description: "timed out waiting for \(what); states: \(history)")
            }
        }
    }

    func close() throws {
        let done = DispatchSemaphore(value: 0)
        connection.close { done.signal() }
        guard done.wait(timeout: .now() + 5) == .success else { throw CheckFailure(description: "close didn't complete") }
    }
}

private func isFailed(_ state: RTMPConnection.State) -> Bool {
    if case .failed = state { return true }
    return false
}

private func failureText(_ probe: ConnectionProbe) -> String? {
    for state in probe.history { if case .failed(let text) = state { return text } }
    return nil
}

/// Polls for up to 5 s.
private func eventually(_ what: String, _ condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition() {
        guard Date() < deadline else { throw CheckFailure(description: "timed out waiting for \(what)") }
        Thread.sleep(forTimeInterval: 0.01)
    }
}

private func commandNames(_ messages: [RTMPMessage]) -> [String] {
    messages.compactMap { message in
        guard message.type == RTMPMessage.Kind.command.rawValue,
              case .string(let name)? = try? AMF0.decode(message.payload).first else { return nil }
        return name
    }
}

func rtmpConnectionChecks() {
    check("target parses rtmps with default port and trims the key") {
        let target = RTMPConnection.Target(server: "rtmps://live.twitch.tv/app", key: " abc\n")
        try expect(target?.host == "live.twitch.tv", "host")
        try expect(target?.port == 443, "port")
        try expect(target?.tls == true, "tls")
        try expect(target?.app == "app", "app")
        try expect(target?.key == "abc", "key")
    }

    check("target parses rtmp with an explicit port") {
        let target = RTMPConnection.Target(server: "rtmp://127.0.0.1:1935/live", key: "k")
        try expect(target?.port == 1935, "port")
        try expect(target?.tls == false, "tls")
    }

    check("target keeps a server's query on the app and the tcUrl") {
        let target = RTMPConnection.Target(server: "rtmps://b.rtmps.youtube.com/live2?backup=1", key: "made-up-key")
        try expect(target?.app == "live2?backup=1", "app \(target?.app ?? "nil")")
        try expect(target?.tcUrl == "rtmps://b.rtmps.youtube.com/live2?backup=1", "tcUrl \(target?.tcUrl ?? "nil")")
        try expect(target.map { !"\($0)".contains("made-up-key") } == true, "key in the description")
        try expect(RTMPConnection.Target(server: "rtmps://x/live2?", key: "k")?.app == "live2", "empty query kept")
    }

    check("plain rtmp:// to another machine is flagged as sending the key unencrypted") {
        try expect(RTMPConnection.Target.sendsKeyInClear(server: "rtmp://live.example.com/app"), "remote rtmp not flagged")
        try expect(RTMPConnection.Target.sendsKeyInClear(server: " RTMP://10.0.0.5:1935/live "), "LAN rtmp not flagged")
        for local in ["rtmp://localhost/live", "rtmp://127.0.0.1:1935/live", "rtmp://[::1]:1935/live",
                      "rtmps://live.example.com/app", "", "live.example.com/app"] {
            try expect(!RTMPConnection.Target.sendsKeyInClear(server: local), "\(local) flagged")
        }
    }

    check("target rejects other schemes and an empty key") {
        try expect(RTMPConnection.Target(server: "http://x/y", key: "k") == nil, "http accepted")
        try expect(RTMPConnection.Target(server: "rtmps://x/y", key: " \n") == nil, "empty key accepted")
    }

    check("publishes metadata, video and audio to an accepting server") {
        let server = try RTMPTestServer(behaviour: .accept)
        defer { server.stop() }
        let probe = try ConnectionProbe(server: server, key: "live_123")
        try probe.wait(for: "publishing") { $0 == .publishing }

        let metadata = FLV.metadata(width: 1920, height: 1080, frameRate: 60, videoKbps: 6000, audioKbps: 160)
        let video = FLV.avcFrame(Data([0, 0, 0, 2, 0x65, 0x88]), keyframe: true)
        let audio = FLV.aacFrame(Data([1, 2, 3]))
        probe.connection.send(metadata: metadata)
        probe.connection.send(video: video, timestamp: 40, keyframe: true)
        probe.connection.send(audio: audio, timestamp: 21)

        func message(_ type: UInt8) -> RTMPMessage? { server.received.first { $0.type == type } }
        try eventually("media at the server") { message(8) != nil && message(9) != nil && message(18) != nil }
        try expect(message(18)?.payload == metadata && message(18)?.timestamp == 0, "metadata")
        try expect(message(9)?.payload == video && message(9)?.timestamp == 40, "video")
        try expect(message(8)?.payload == audio && message(8)?.timestamp == 21, "audio")
        try expect(server.publishedKey == "live_123", "published key")
        try probe.close()
    }

    check("a rejected publish fails without the key in its text") {
        let server = try RTMPTestServer(behaviour: .rejectPublish(description: "bad key SECRET"))
        defer { server.stop() }
        let probe = try ConnectionProbe(server: server, key: "SECRET")
        try probe.wait(for: "failed", isFailed)
        guard case .failed(let text)? = probe.history.first(where: isFailed) else { return }
        try expect(!text.contains("SECRET"), "key in error text")
        try expect(!text.isEmpty, "empty error text")
    }

    check("a dropped connection after publishing fails") {
        let server = try RTMPTestServer(behaviour: .dropAfterPublish)
        defer { server.stop() }
        let probe = try ConnectionProbe(server: server, key: "k")
        try probe.wait(for: "failed", isFailed)
        let history = probe.history
        guard let publishing = history.firstIndex(of: .publishing) else { throw CheckFailure(description: "never published: \(history)") }
        try expect(history[publishing...].contains(where: isFailed), "failed before publishing: \(history)")
    }

    check("close after publishing unpublishes and ends closed") {
        let server = try RTMPTestServer(behaviour: .accept)
        defer { server.stop() }
        let probe = try ConnectionProbe(server: server, key: "k")
        try probe.wait(for: "publishing") { $0 == .publishing }
        try probe.close()
        try eventually("FCUnpublish and deleteStream") {
            let names = commandNames(server.received)
            return names.contains("FCUnpublish") && names.contains("deleteStream")
        }
        try expect(probe.history.last == .closed, "last state \(String(describing: probe.history.last))")
    }

    check("target descriptions hide the key") {
        guard let target = RTMPConnection.Target(server: "rtmps://live.twitch.tv/app", key: "live_SECRET_9") else {
            throw CheckFailure(description: "no target")
        }
        var dumped = ""
        dump(target, to: &dumped)
        for text in ["\(target)", String(describing: target), String(reflecting: target), dumped, "\([target])"] {
            try expect(!text.contains("SECRET"), "key in \(text)")
        }
        try expect("\(target)".contains("live.twitch.tv/app"), "address missing: \(target)")
    }

    check("an answer that doesn't decode fails the connection") {
        let server = try RTMPTestServer(behaviour: .garbleConnectAnswer)
        defer { server.stop() }
        let probe = try ConnectionProbe(server: server, key: "k")
        try probe.wait(for: "failed", isFailed)
        try expect(failureText(probe) == "The server sent an answer Tween can't read", "text \(failureText(probe) ?? "nil")")
        try expect(!probe.connection.refusedByServer, "counted as refused")
    }

    check("a server that never answers times out with a plain text") {
        let server = try RTMPTestServer(behaviour: .silent)
        defer { server.stop() }
        let probe = try ConnectionProbe(server: server, key: "k", connectTimeout: 0.5)
        try probe.wait(for: "failed", isFailed)
        try expect(failureText(probe) == "No answer from the server", "text \(failureText(probe) ?? "nil")")
    }

    check("a refused port times out with the network's reason") {
        // A port that was just listening and no longer is.
        let port: UInt16
        do {
            let server = try RTMPTestServer(behaviour: .accept)
            port = server.port
            server.stop()
        }
        Thread.sleep(forTimeInterval: 0.1)
        let probe = try ConnectionProbe(port: port, key: "k", connectTimeout: 1)
        try probe.wait(for: "failed", isFailed)
        let text = failureText(probe) ?? ""
        try expect(text.lowercased().contains("refused"), "text \(text)")
    }

    check("answers a ping and acknowledges received bytes") {
        let server = try RTMPTestServer(behaviour: .accept, ackWindow: 100, pingAfterPublish: true)
        defer { server.stop() }
        let probe = try ConnectionProbe(server: server, key: "k")
        try probe.wait(for: "publishing") { $0 == .publishing }
        try eventually("ping response") {
            server.received.contains { $0.type == RTMPMessage.Kind.userControl.rawValue && Array($0.payload) == [0, 7, 1, 2, 3, 4] }
        }
        let acks = server.received.filter { $0.type == RTMPMessage.Kind.acknowledgement.rawValue }
        try expect(!acks.isEmpty, "no acknowledgement")
        let sequence = acks.first.map { $0.payload.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } } ?? 0
        // The handshake alone is 3073 bytes from the server.
        try expect(acks.first?.payload.count == 4 && sequence >= 3073, "acknowledgement \(sequence)")
        try probe.close()
    }

    check("media sent before publishing is discarded") {
        let server = try RTMPTestServer(behaviour: .accept)
        defer { server.stop() }
        let probe = try ConnectionProbe(server: server, key: "k")
        probe.connection.send(video: FLV.avcFrame(Data([0, 0, 0, 1, 0x65]), keyframe: true), timestamp: 1, keyframe: true)
        probe.connection.send(audio: FLV.aacFrame(Data([1])), timestamp: 2)
        probe.connection.send(metadata: FLV.metadata(width: 1920, height: 1080, frameRate: 60, videoKbps: 6000, audioKbps: 160))
        try probe.wait(for: "publishing") { $0 == .publishing }
        probe.connection.send(audio: FLV.aacFrame(Data([9])), timestamp: 99)
        try eventually("the audio sent after publishing") { server.received.contains { $0.type == 8 } }
        let media = server.received.filter { [8, 9, 18].contains($0.type) }
        try expect(media.count == 1 && media.first?.timestamp == 99, "media at the server: \(media.map { ($0.type, $0.timestamp) })")
        try probe.close()
    }

    check("the send queue never drops the sequence header") {
        let header = FLV.avcSequenceHeader(sps: Data([0x67, 0x64, 0x00, 0x28, 0xAC]), pps: Data([0x68, 0xEE, 0x3C, 0x80]))
        let frame = FLV.avcFrame(Data([0, 0, 0, 1, 0x41]), keyframe: false)
        var queue = RTMPSendQueue()
        // Behind by more than the limit: the next video makes it drop.
        queue.enqueue(RTMPConnection.videoItem(frame, bytes: Data([1]), timestamp: 0, keyframe: false))
        queue.enqueue(RTMPConnection.videoItem(frame, bytes: Data([2]), timestamp: 3500, keyframe: false))
        queue.enqueue(RTMPConnection.videoItem(frame, bytes: Data([3]), timestamp: 3600, keyframe: false))
        try expect(queue.isDropping, "not dropping")
        queue.enqueue(RTMPConnection.videoItem(header, bytes: Data([4]), timestamp: 3600, keyframe: true))
        queue.enqueue(RTMPConnection.videoItem(frame, bytes: Data([5]), timestamp: 3610, keyframe: false))
        var left: [UInt8] = []
        while let item = queue.next() { left += item.bytes }
        try expect(left == [4], "queue gave \(left)")
    }

    check("a network that stops taking data counts as lost") {
        let server = try RTMPTestServer(behaviour: .stallAfterPublish)
        defer { server.stop() }
        let probe = try ConnectionProbe(server: server, key: "k", stallTimeout: 0.5)
        try probe.wait(for: "publishing") { $0 == .publishing }
        // More than the socket buffers hold, as keyframes 10 ms apart so the queue keeps them.
        let big = FLV.avcFrame(Data(repeating: 0x41, count: 200_000), keyframe: true)
        for i in 0..<100 { probe.connection.send(video: big, timestamp: UInt32(i * 10), keyframe: true) }
        try probe.wait(for: "failed", isFailed)
        try expect(failureText(probe) == "The network stopped taking data", "text \(failureText(probe) ?? "nil")")
    }

    check("a close before publishing never sends publish") {
        // The createStream answer comes after the close.
        let server = try RTMPTestServer(behaviour: .accept, createStreamDelay: 0.3)
        defer { server.stop() }
        let probe = try ConnectionProbe(server: server, key: "k")
        try eventually("createStream at the server") { commandNames(server.received).contains("createStream") }
        try probe.close()
        Thread.sleep(forTimeInterval: 0.5)
        try expect(!commandNames(server.received).contains("publish"), "publish sent after close: \(commandNames(server.received))")
        try expect(probe.history.last == .closed && !probe.history.contains(.publishing), "states \(probe.history)")
    }

    check("a refused publish counts as refused by the server") {
        let server = try RTMPTestServer(behaviour: .rejectPublish(description: "no"))
        defer { server.stop() }
        let probe = try ConnectionProbe(server: server, key: "k")
        try probe.wait(for: "failed", isFailed)
        try expect(probe.connection.refusedByServer, "not counted as refused")
    }
}
