import Foundation

func flvChecks() {
    check("flv avc sequence header") {
        let sps = Data([0x67, 0x64, 0x00, 0x1F, 0xAC])
        let pps = Data([0x68, 0xEE, 0x3C])
        let expected: [UInt8] = [0x17, 0, 0, 0, 0, 0x01, 0x64, 0x00, 0x1F, 0xFF, 0xE1, 0x00, 0x05]
            + [0x67, 0x64, 0x00, 0x1F, 0xAC] + [0x01, 0x00, 0x03] + [0x68, 0xEE, 0x3C]
        try expect([UInt8](FLV.avcSequenceHeader(sps: sps, pps: pps)) == expected)
    }
    check("flv avc sequence header rejects short sps") {
        try expect(FLV.avcSequenceHeader(sps: Data([0x67, 0x64, 0x00]), pps: Data([0x68])).isEmpty)
    }
    check("flv avc frame") {
        let body = Data([0, 0, 0, 2, 0x65, 0x88])
        try expect([UInt8](FLV.avcFrame(body, keyframe: true)) == [0x17, 0x01, 0, 0, 0] + [UInt8](body))
        try expect([UInt8](FLV.avcFrame(body, keyframe: false)) == [0x27, 0x01, 0, 0, 0] + [UInt8](body))
    }
    check("flv aac") {
        try expect([UInt8](FLV.aacSequenceHeader()) == [0xAF, 0x00, 0x11, 0x90])
        try expect([UInt8](FLV.aacFrame(Data([1, 2, 3]))) == [0xAF, 0x01, 1, 2, 3])
    }
    check("flv metadata") {
        let decoded = try AMF0.decode(FLV.metadata(width: 1920, height: 1080, frameRate: 60, videoKbps: 6000, audioKbps: 128))
        try expect(decoded.count == 3)
        try expect(decoded[0] == .string("@setDataFrame"))
        try expect(decoded[1] == .string("onMetaData"))
        guard case .ecmaArray = decoded[2] else { throw CheckFailure(description: "not an ecma array") }
        try expect(decoded[2]["width"] == .number(1920))
        try expect(decoded[2]["height"] == .number(1080))
        try expect(decoded[2]["framerate"] == .number(60))
        try expect(decoded[2]["videodatarate"] == .number(6000))
        try expect(decoded[2]["audiodatarate"] == .number(128))
        try expect(decoded[2]["videocodecid"] == .number(7))
        try expect(decoded[2]["audiocodecid"] == .number(10))
        try expect(decoded[2]["audiosamplerate"] == .number(48000))
        try expect(decoded[2]["stereo"] == .boolean(true))
    }
}
