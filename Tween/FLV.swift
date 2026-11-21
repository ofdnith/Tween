import Foundation

/// FLV tag bodies: the payloads of RTMP video (9), audio (8) and data (18) messages.
enum FLV {
    /// AVC decoder configuration record. SPS and PPS come without start codes or length prefixes.
    /// Returns empty data if the SPS is too short to hold profile, compatibility and level.
    static func avcSequenceHeader(sps: Data, pps: Data) -> Data {
        guard sps.count >= 4, sps.count <= 0xFFFF, pps.count <= 0xFFFF else { return Data() }
        let s = [UInt8](sps)
        var out = Data([0x17, 0x00, 0x00, 0x00, 0x00])
        out.append(contentsOf: [0x01, s[1], s[2], s[3], 0xFF, 0xE1])
        out.append(contentsOf: [UInt8(sps.count >> 8), UInt8(sps.count & 0xFF)])
        out.append(sps)
        out.append(0x01)
        out.append(contentsOf: [UInt8(pps.count >> 8), UInt8(pps.count & 0xFF)])
        out.append(pps)
        return out
    }

    /// One access unit in AVCC form (4-byte length prefixes), composition time 0.
    static func avcFrame(_ avcc: Data, keyframe: Bool) -> Data {
        var out = Data([keyframe ? 0x17 : 0x27, 0x01, 0x00, 0x00, 0x00])
        out.append(avcc)
        return out
    }

    /// AAC-LC, 48 kHz, stereo.
    static func aacSequenceHeader() -> Data {
        Data([0xAF, 0x00, 0x11, 0x90])
    }

    static func aacFrame(_ raw: Data) -> Data {
        var out = Data([0xAF, 0x01])
        out.append(raw)
        return out
    }

    static func metadata(width: Int, height: Int, frameRate: Int, videoKbps: Int, audioKbps: Int) -> Data {
        let properties: [AMF0.Property] = [
            .init(key: "width", value: .number(Double(width))),
            .init(key: "height", value: .number(Double(height))),
            .init(key: "framerate", value: .number(Double(frameRate))),
            .init(key: "videodatarate", value: .number(Double(videoKbps))),
            .init(key: "videocodecid", value: .number(7)),
            .init(key: "audiodatarate", value: .number(Double(audioKbps))),
            .init(key: "audiocodecid", value: .number(10)),
            .init(key: "audiosamplerate", value: .number(48000)),
            .init(key: "stereo", value: .boolean(true)),
        ]
        var out = Data()
        AMF0.string("@setDataFrame").encode(into: &out)
        AMF0.string("onMetaData").encode(into: &out)
        AMF0.ecmaArray(properties).encode(into: &out)
        return out
    }
}
