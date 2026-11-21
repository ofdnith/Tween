import Foundation

func rtmpChunkChecks() {
    func message(_ size: Int, type: UInt8 = 9, streamID: UInt32 = 1, timestamp: UInt32 = 0) -> RTMPMessage {
        RTMPMessage(type: type, streamID: streamID, timestamp: timestamp,
                    payload: Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }))
    }

    check("rtmp chunk single") {
        let m = message(10, type: 20, streamID: 0x0102_0304, timestamp: 0x0A0B0C)
        let bytes = [UInt8](RTMPChunkWriter().chunks(for: m, chunkStreamID: 3))
        let header: [UInt8] = [0x03, 0x0A, 0x0B, 0x0C, 0, 0, 10, 20, 0x04, 0x03, 0x02, 0x01]
        try expect(bytes == header + [UInt8](m.payload))
    }
    check("rtmp chunk split") {
        let m = message(300)
        let bytes = [UInt8](RTMPChunkWriter().chunks(for: m, chunkStreamID: 6))
        let p = [UInt8](m.payload)
        let header: [UInt8] = [0x06, 0, 0, 0, 0x00, 0x01, 0x2C, 9, 1, 0, 0, 0]
        var expected = header + p[0..<128]
        expected += [0xC6] + p[128..<256]
        expected += [0xC6] + p[256..<300]
        try expect(bytes == expected)
    }
    check("rtmp chunk extended timestamp") {
        let m = message(200, timestamp: 0x0100_0000)
        let bytes = [UInt8](RTMPChunkWriter().chunks(for: m, chunkStreamID: 4))
        let p = [UInt8](m.payload)
        let ext: [UInt8] = [0x01, 0, 0, 0]
        let header: [UInt8] = [0x04, 0xFF, 0xFF, 0xFF, 0, 0, 200, 9, 1, 0, 0, 0]
        var expected = header + ext + p[0..<128]
        expected += [0xC4] + ext + p[128..<200]
        try expect(bytes == expected)
    }
    check("rtmp chunk round trip") {
        for size in [0, 1, 128, 129, 5000] {
            for timestamp: UInt32 in [0, 1234, 0xFFFFFF, 0x0100_0000] {
                let m = message(size, type: 8, streamID: 7, timestamp: timestamp)
                let bytes = RTMPChunkWriter().chunks(for: m, chunkStreamID: 4)
                var whole = RTMPChunkReader()
                try expect(try whole.append(bytes) == [m], "size \(size) ts \(timestamp)")
                var single = RTMPChunkReader()
                var received: [RTMPMessage] = []
                for byte in bytes { received += try single.append(Data([byte])) }
                try expect(received == [m], "byte at a time, size \(size) ts \(timestamp)")
            }
        }
    }
    check("rtmp chunk round trip larger chunk size") {
        let m = message(5000)
        var writer = RTMPChunkWriter()
        writer.chunkSize = 4096
        var reader = RTMPChunkReader()
        let setSize = RTMPMessage(type: 1, streamID: 0, timestamp: 0, payload: Data([0, 0, 0x10, 0]))
        let bytes = RTMPChunkWriter().chunks(for: setSize, chunkStreamID: 2) + writer.chunks(for: m, chunkStreamID: 6)
        try expect(try reader.append(bytes) == [setSize, m])
    }
    check("rtmp chunk reader peer headers") {
        // Message 1: type 0, ts 1000, 3 bytes. Message 2: type 1, delta 20, 4 bytes, type 8.
        // Message 3: type 2, delta 5. Message 4: type 3, reuses delta 5 and length 4.
        var bytes: [UInt8] = [0x05, 0x00, 0x03, 0xE8, 0, 0, 3, 9, 1, 0, 0, 0, 0xAA, 0xBB, 0xCC]
        bytes += [0x45, 0, 0, 20, 0, 0, 4, 8, 1, 2, 3, 4]
        bytes += [0x85, 0, 0, 5, 5, 6, 7, 8]
        bytes += [0xC5, 9, 10, 11, 12]
        var reader = RTMPChunkReader()
        let received = try reader.append(Data(bytes))
        try expect(received == [
            RTMPMessage(type: 9, streamID: 1, timestamp: 1000, payload: Data([0xAA, 0xBB, 0xCC])),
            RTMPMessage(type: 8, streamID: 1, timestamp: 1020, payload: Data([1, 2, 3, 4])),
            RTMPMessage(type: 8, streamID: 1, timestamp: 1025, payload: Data([5, 6, 7, 8])),
            RTMPMessage(type: 8, streamID: 1, timestamp: 1030, payload: Data([9, 10, 11, 12])),
        ], "\(received)")
    }
    check("rtmp chunk reader set chunk size") {
        let setSize = RTMPMessage(type: 1, streamID: 0, timestamp: 0, payload: Data([0, 0, 0x10, 0]))
        let m = message(4096)
        // After Set Chunk Size the whole 4096-byte message arrives in one chunk, no type-3 headers.
        let header: [UInt8] = [0x06, 0, 0, 0, 0, 0x10, 0, 9, 1, 0, 0, 0]
        var reader = RTMPChunkReader()
        let bytes = RTMPChunkWriter().chunks(for: setSize, chunkStreamID: 2) + Data(header) + m.payload
        try expect(try reader.append(bytes) == [setSize, m])
    }
    check("rtmp chunk reader rejects bad chunk size") {
        for value: [UInt8] in [[0, 0, 0, 0], [0x01, 0, 0, 0], [0x7F, 0xFF, 0xFF, 0xFF]] {
            let setSize = RTMPMessage(type: 1, streamID: 0, timestamp: 0, payload: Data(value))
            var reader = RTMPChunkReader()
            var threw = false
            do { _ = try reader.append(RTMPChunkWriter().chunks(for: setSize, chunkStreamID: 2)) } catch { threw = true }
            try expect(threw, "\(value)")
        }
        let largest = RTMPMessage(type: 1, streamID: 0, timestamp: 0, payload: Data([0, 0xFF, 0xFF, 0xFF]))
        var reader = RTMPChunkReader()
        try expect(try reader.append(RTMPChunkWriter().chunks(for: largest, chunkStreamID: 2)) == [largest])
    }

    check("rtmp chunk reader rejects long message") {
        // 16,000,001 bytes announced; rejected from the header alone.
        let header: [UInt8] = [0x06, 0, 0, 0, 0xF4, 0x24, 0x01, 9, 1, 0, 0, 0]
        var reader = RTMPChunkReader()
        var threw = false
        do { _ = try reader.append(Data(header)) } catch { threw = true }
        try expect(threw)
        var atLimit = RTMPChunkReader()
        try expect(try atLimit.append(Data([0x06, 0, 0, 0, 0xF4, 0x24, 0x00, 9, 1, 0, 0, 0])).isEmpty)
    }
    check("rtmp chunk reader two-byte chunk stream id") {
        // Chunk stream 70: basic header 0x00, 70 - 64; continuation 0xC0, 6.
        var bytes: [UInt8] = [0x00, 6, 0, 0, 5, 0, 0, 130, 8, 1, 0, 0, 0] + [UInt8](repeating: 1, count: 128)
        bytes += [0xC0, 6, 2, 2]
        var reader = RTMPChunkReader()
        let expected = RTMPMessage(type: 8, streamID: 1, timestamp: 5,
                                   payload: Data([UInt8](repeating: 1, count: 128) + [2, 2]))
        try expect(try reader.append(Data(bytes)) == [expected])
    }

    func basicHeader(_ format: UInt8, _ csid: Int) -> [UInt8] {
        csid < 64 ? [format << 6 | UInt8(csid)] : [format << 6, UInt8(csid - 64)]
    }
    func type0(_ csid: Int, length: Int) -> [UInt8] {
        basicHeader(0, csid) + [0, 0, 0, UInt8(length >> 16), UInt8(truncatingIfNeeded: length >> 8),
                                UInt8(truncatingIfNeeded: length), 9, 1, 0, 0, 0]
    }
    func throwsError(_ body: () throws -> Void) -> Bool {
        do { try body() } catch { return true }
        return false
    }

    check("rtmp chunk reader caps open chunk streams") {
        var reader = RTMPChunkReader()
        for csid in 2..<(2 + RTMPChunkReader.maxChunkStreams) {
            try expect(try reader.append(Data(type0(csid, length: 1) + [7])).count == 1, "csid \(csid)")
        }
        let next = 2 + RTMPChunkReader.maxChunkStreams
        try expect(throwsError { _ = try reader.append(Data(type0(next, length: 1) + [7])) }, "csid \(next)")
    }
    check("rtmp chunk reader caps bytes held across chunk streams") {
        let setSize = RTMPMessage(type: 1, streamID: 0, timestamp: 0, payload: Data([0, 0x0F, 0x42, 0x40]))  // 1,000,000
        let piece = [UInt8](repeating: 1, count: 1_000_000)
        var reader = RTMPChunkReader()
        _ = try reader.append(RTMPChunkWriter().chunks(for: setSize, chunkStreamID: 2))
        // Three 15,000,000-byte messages, 11 MB of each sent: 33 MB held, over the 32 MB budget.
        var threw = false
        for csid in [4, 5, 6] where !threw {
            for index in 0..<11 where !threw {
                let header = index == 0 ? type0(csid, length: 15_000_000) : basicHeader(3, csid)
                threw = throwsError { _ = try reader.append(Data(header + piece)) }
                try expect(!threw || (csid == 6 && index == 10), "threw early at csid \(csid) piece \(index)")
            }
        }
        try expect(threw)
    }
    check("rtmp chunk reader accepts a maximum-size message") {
        let m = message(RTMPChunkReader.maxMessageLength)
        for size in [4096, 16_777_215] {
            var writer = RTMPChunkWriter()
            writer.chunkSize = size
            var reader = RTMPChunkReader()
            let setSize = RTMPMessage(type: 1, streamID: 0, timestamp: 0,
                                      payload: Data(withUnsafeBytes(of: UInt32(size).bigEndian, Array.init)))
            var received = try reader.append(RTMPChunkWriter().chunks(for: setSize, chunkStreamID: 2))
            // Fed in 64 KB reads, as a socket would deliver it.
            let bytes = writer.chunks(for: m, chunkStreamID: 6)
            var offset = bytes.startIndex
            while offset < bytes.endIndex {
                let end = min(offset + 65536, bytes.endIndex)
                received += try reader.append(bytes[offset..<end])
                offset = end
            }
            try expect(received == [setSize, m], "chunk size \(size)")
        }
    }
    check("rtmp chunk reader interleaved chunk streams") {
        let a = message(300, type: 8, timestamp: 10)
        let b = message(300, type: 9, timestamp: 20)
        let ca = [UInt8](RTMPChunkWriter().chunks(for: a, chunkStreamID: 4))
        let cb = [UInt8](RTMPChunkWriter().chunks(for: b, chunkStreamID: 6))
        // Chunk boundaries: 12 + 128, 1 + 128, 1 + 44.
        let cuts = [0, 140, 269, 314]
        var bytes: [UInt8] = []
        for i in 0..<3 { bytes += ca[cuts[i]..<cuts[i + 1]] + cb[cuts[i]..<cuts[i + 1]] }
        var reader = RTMPChunkReader()
        try expect(try reader.append(Data(bytes)) == [a, b])
        try expect(try reader.append(RTMPChunkWriter().chunks(for: message(5000), chunkStreamID: 6)) == [message(5000)])
    }

    typealias Item = RTMPSendQueue.Item
    func video(_ ts: UInt32, key: Bool = false) -> Item { Item(bytes: Data([1]), timestamp: ts, isVideo: true, isKeyframe: key) }
    func audio(_ ts: UInt32) -> Item { Item(bytes: Data([2]), timestamp: ts, isVideo: false, isKeyframe: false) }

    check("rtmp send queue passes items in order") {
        var queue = RTMPSendQueue()
        queue.enqueue(video(0, key: true))
        queue.enqueue(audio(10))
        queue.enqueue(video(33))
        try expect(queue.next()?.timestamp == 0)
        try expect(queue.next()?.timestamp == 10)
        try expect(queue.next()?.timestamp == 33)
        try expect(queue.next() == nil)
        try expect(!queue.isDropping && queue.droppedVideoFrames == 0)
    }
    check("rtmp send queue drops video when behind") {
        var queue = RTMPSendQueue()
        for ts in stride(from: UInt32(0), through: 3500, by: 500) {
            queue.enqueue(video(ts, key: ts == 0))
            // Audio stops at 2510 so the queue spans exactly 0...3500 once video 3500 is in.
            if ts < 3000 { queue.enqueue(audio(ts + 10)) }
        }
        try expect(!queue.isDropping)
        // 8 video frames and 6 audio queued; the next enqueue finds 3.5 s queued and removes the video.
        queue.enqueue(video(3600))
        try expect(queue.isDropping)
        try expect(queue.droppedVideoFrames == 9, "\(queue.droppedVideoFrames)")
        queue.enqueue(audio(3610))
        queue.enqueue(video(3700))
        try expect(queue.droppedVideoFrames == 10)
        var drained: [Item] = []
        while let item = queue.next() { drained.append(item) }
        try expect(drained.count == 7 && drained.allSatisfy { !$0.isVideo })
        queue.enqueue(video(3800, key: true))
        try expect(!queue.isDropping)
        queue.enqueue(video(3833))
        try expect(queue.next()?.timestamp == 3800)
        try expect(queue.next()?.timestamp == 3833)
        try expect(queue.droppedVideoFrames == 10)
    }
    check("rtmp send queue keeps dropping while audio is still behind") {
        var queue = RTMPSendQueue()
        for ts in stride(from: UInt32(0), through: 3500, by: 500) { queue.enqueue(audio(ts)) }
        queue.enqueue(video(3510, key: true))
        try expect(queue.isDropping && queue.droppedVideoFrames == 1)
        while queue.next() != nil {}
        queue.enqueue(video(3600, key: true))
        try expect(!queue.isDropping && queue.next()?.timestamp == 3600)
    }
    check("rtmp send queue sends control items ahead of queued media, in their own order") {
        func control(_ tag: UInt8) -> Item { Item(bytes: Data([tag]), timestamp: 900, isVideo: false, isKeyframe: false, isControl: true) }
        var queue = RTMPSendQueue()
        queue.enqueue(video(0, key: true))
        queue.enqueue(audio(10))
        // The first video item is already being written: it is no longer in the queue.
        try expect(queue.next()?.bytes == Data([1]))
        queue.enqueue(video(33))
        queue.enqueue(control(7))
        queue.enqueue(audio(43))
        queue.enqueue(control(8))
        var order: [UInt8] = []
        while let item = queue.next() { order.append(item.bytes.first ?? 0) }
        try expect(order == [7, 8, 2, 1, 2], "order \(order)")
    }
    check("rtmp send queue backlog ignores control items") {
        var queue = RTMPSendQueue()
        for ts in stride(from: UInt32(1000), through: 3200, by: 550) { queue.enqueue(video(ts, key: ts == 1000)) }
        // A control item carrying an older timestamp must not make the backlog look longer.
        queue.enqueue(Item(bytes: Data([9]), timestamp: 0, isVideo: false, isKeyframe: false, isControl: true))
        queue.enqueue(video(3500))
        try expect(!queue.isDropping && queue.droppedVideoFrames == 0, "dropping \(queue.droppedVideoFrames)")
    }
    check("rtmp send queue measures only items not yet taken") {
        var queue = RTMPSendQueue()
        for ts in stride(from: UInt32(0), through: 3500, by: 500) {
            queue.enqueue(video(ts))
            _ = queue.next()
        }
        queue.enqueue(video(3600))
        try expect(!queue.isDropping && queue.droppedVideoFrames == 0)
    }
}
