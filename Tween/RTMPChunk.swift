import Foundation

struct RTMPMessage: Equatable {
    enum Kind: UInt8 {
        case setChunkSize = 1, acknowledgement = 3, userControl = 4, windowAckSize = 5,
             setPeerBandwidth = 6, audio = 8, video = 9, data = 18, command = 20
    }
    var type: UInt8
    var streamID: UInt32
    var timestamp: UInt32
    var payload: Data
}

/// Timestamps at or above this don't fit the 3-byte field and go in a 4-byte extended timestamp.
private let extendedTimestampMarker: UInt32 = 0xFFFFFF

/// Splits messages into chunks. Every message starts with a full type-0 header, so no
/// per-chunk-stream state has to be kept in step with the peer.
struct RTMPChunkWriter {
    var chunkSize = 128

    /// `chunkStreamID` is 2...63, which keeps the basic header to one byte.
    func chunks(for message: RTMPMessage, chunkStreamID: UInt8) -> Data {
        let extended = message.timestamp >= extendedTimestampMarker
        var data = Data(capacity: message.payload.count + 16 + message.payload.count / chunkSize * 5)
        data.append(chunkStreamID & 0x3F)
        appendBigEndian(extended ? extendedTimestampMarker : message.timestamp, bytes: 3, to: &data)
        appendBigEndian(UInt32(message.payload.count), bytes: 3, to: &data)
        data.append(message.type)
        data.append(contentsOf: withUnsafeBytes(of: message.streamID.littleEndian, Array.init))
        if extended { appendBigEndian(message.timestamp, bytes: 4, to: &data) }

        var offset = message.payload.startIndex
        while true {
            let end = min(offset + chunkSize, message.payload.endIndex)
            data.append(message.payload[offset..<end])
            offset = end
            if offset == message.payload.endIndex { break }
            data.append(0xC0 | (chunkStreamID & 0x3F))
            if extended { appendBigEndian(message.timestamp, bytes: 4, to: &data) }
        }
        return data
    }

    private func appendBigEndian(_ value: UInt32, bytes: Int, to data: inout Data) {
        for shift in stride(from: (bytes - 1) * 8, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }
}

/// Reassembles messages from a peer's chunks. Bytes come from a remote server, so message
/// length and chunk size are bounded to keep a hostile one from making it allocate without limit.
struct RTMPChunkReader {
    enum ReadError: Error {
        case messageTooLong(Int), badChunkSize(UInt32), tooManyChunkStreams, tooManyBytesHeld, malformed
    }

    /// 16 MB. A 16 MiB cap could never trip, since the 3-byte length field tops out at 16,777,215.
    static let maxMessageLength = 16_000_000
    static let chunkSizeRange: ClosedRange<UInt32> = 1...16_777_215
    /// Servers use a handful; the cap and the byte budget stop a peer from holding partial
    /// messages open on many chunk streams at once.
    static let maxChunkStreams = 64
    /// Partial payloads plus unparsed bytes. One maximum-size message stays under it: its partial
    /// payload and the rest of it waiting in the buffer never exceed its own length.
    static let maxBytesHeld = 2 * maxMessageLength

    /// What the last header on a chunk stream said; later headers leave out what is unchanged.
    private struct StreamState {
        var timestamp: UInt32 = 0
        var delta: UInt32 = 0
        var length = 0
        var type: UInt8 = 0
        var streamID: UInt32 = 0
        var extended = false
        var payload = Data()
    }

    private var chunkSize = 128
    private var buffer: [UInt8] = []
    private var streams: [UInt32: StreamState] = [:]
    private var partialBytes = 0

    mutating func append(_ bytes: Data) throws -> [RTMPMessage] {
        buffer.append(contentsOf: bytes)
        var messages: [RTMPMessage] = []
        var position = 0
        while let (consumed, message) = try readChunk(at: position) {
            position += consumed
            guard let message else { continue }
            messages.append(message)
            // Applies to the chunks after this message, which haven't been parsed yet.
            if message.type == RTMPMessage.Kind.setChunkSize.rawValue {
                guard message.payload.count >= 4 else { throw ReadError.malformed }
                let size = message.payload.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                guard Self.chunkSizeRange.contains(size) else { throw ReadError.badChunkSize(size) }
                chunkSize = Int(size)
            }
        }
        buffer.removeFirst(position)
        guard partialBytes + buffer.count <= Self.maxBytesHeld else { throw ReadError.tooManyBytesHeld }
        return messages
    }

    /// Parses one whole chunk, or returns nil when the buffer doesn't hold one yet.
    private mutating func readChunk(at start: Int) throws -> (Int, RTMPMessage?)? {
        var p = start
        func take(_ count: Int) -> UInt32? {
            guard buffer.count - p >= count else { return nil }
            defer { p += count }
            return buffer[p..<p + count].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }

        guard let first = take(1) else { return nil }
        let format = first >> 6
        var csid = first & 0x3F
        if csid == 0 {
            guard let b = take(1) else { return nil }
            csid = 64 + b
        } else if csid == 1 {
            guard let b = take(2) else { return nil }
            csid = 64 + (b >> 8) + (b & 0xFF) * 256
        }

        var state = streams[csid] ?? StreamState()
        let continuing = !state.payload.isEmpty
        if continuing && format != 3 { throw ReadError.malformed }
        if streams[csid] == nil && format != 0 { throw ReadError.malformed }
        if streams[csid] == nil && streams.count >= Self.maxChunkStreams { throw ReadError.tooManyChunkStreams }

        var field: UInt32?
        switch format {
        case 0:
            guard let ts = take(3), let length = take(3), let type = take(1), let id = take(4) else { return nil }
            field = ts
            state.length = Int(length)
            state.type = UInt8(type)
            state.streamID = id.byteSwapped
        case 1:
            guard let delta = take(3), let length = take(3), let type = take(1) else { return nil }
            field = delta
            state.length = Int(length)
            state.type = UInt8(type)
        case 2:
            guard let delta = take(3) else { return nil }
            field = delta
        default:
            break
        }
        if let field { state.extended = field == extendedTimestampMarker }
        var value = field ?? (format == 3 && !continuing ? state.delta : 0)
        // Type-3 chunks repeat the extended timestamp of their message when it has one.
        if state.extended {
            guard let ext = take(4) else { return nil }
            value = ext
        }
        guard state.length <= Self.maxMessageLength else { throw ReadError.messageTooLong(state.length) }

        let count = min(chunkSize, state.length - state.payload.count)
        guard buffer.count - p >= count else { return nil }

        // Drop the dictionary's copy so the partial payload is appended to in place, not copied per chunk.
        streams[csid] = nil
        if !continuing {
            if format == 0 {
                state.timestamp = value
                state.delta = value
            } else {
                state.timestamp &+= value
                state.delta = value
            }
        }
        state.payload.append(contentsOf: buffer[p..<p + count])
        partialBytes += count
        p += count

        var message: RTMPMessage?
        if state.payload.count == state.length {
            message = RTMPMessage(type: state.type, streamID: state.streamID, timestamp: state.timestamp, payload: state.payload)
            partialBytes -= state.length
            state.payload = Data()
        }
        streams[csid] = state
        return (p - start, message)
    }
}

/// Media waiting for the socket. When the network falls behind, video is thrown away until the
/// next keyframe rather than let the delay grow; audio is small and always kept.
struct RTMPSendQueue {
    struct Item {
        let bytes: Data
        let timestamp: UInt32
        let isVideo: Bool
        let isKeyframe: Bool
        /// Goes ahead of every queued item that isn't control too.
        var isControl = false
    }

    static let limitMs: UInt32 = 3000

    private(set) var droppedVideoFrames = 0
    private(set) var isDropping = false
    private var items: [Item] = []

    mutating func enqueue(_ item: Item) {
        if !isDropping, queuedMs > Self.limitMs {
            isDropping = true
            let before = items.count
            items.removeAll { $0.isVideo }
            droppedVideoFrames += before - items.count
        }
        if item.isVideo && isDropping {
            guard item.isKeyframe, queuedMs <= Self.limitMs else {
                droppedVideoFrames += 1
                return
            }
            isDropping = false
        }
        guard item.isControl else { return items.append(item) }
        // Behind earlier control items, ahead of the rest. An item being written has already been
        // taken by `next`, so no message is ever split.
        items.insert(item, at: items.firstIndex { !$0.isControl } ?? items.count)
    }

    mutating func next() -> Item? {
        items.isEmpty ? nil : items.removeFirst()
    }

    /// Newest minus oldest queued timestamp, wrap-safe; negative (slightly out-of-order items) counts as zero.
    /// Control items are left out: they jump the queue carrying the newest timestamp.
    private var queuedMs: UInt32 {
        guard let first = items.first(where: { !$0.isControl }), let last = items.last(where: { !$0.isControl }) else { return 0 }
        return UInt32(max(0, Int32(bitPattern: last.timestamp &- first.timestamp)))
    }
}
