import Foundation

private func bytes(_ value: AMF0) -> [UInt8] {
    var data = Data()
    value.encode(into: &data)
    return [UInt8](data)
}

func amf0Checks() {
    check("amf0 string") {
        try expect(bytes(.string("connect")) == [0x02, 0x00, 0x07, 0x63, 0x6F, 0x6E, 0x6E, 0x65, 0x63, 0x74])
    }
    check("amf0 number, null, boolean") {
        try expect(bytes(.number(1)) == [0x00, 0x3F, 0xF0, 0, 0, 0, 0, 0, 0])
        try expect(bytes(.null) == [0x05])
        try expect(bytes(.boolean(true)) == [0x01, 0x01])
    }
    check("amf0 object") {
        let object = AMF0.object([.init(key: "app", value: .string("live2"))])
        try expect(bytes(object) == [0x03, 0x00, 0x03, 0x61, 0x70, 0x70, 0x02, 0x00, 0x05,
                                     0x6C, 0x69, 0x76, 0x65, 0x32, 0x00, 0x00, 0x09])
    }
    check("amf0 ecma array") {
        let array = AMF0.ecmaArray([.init(key: "a", value: .boolean(false))])
        try expect(bytes(array) == [0x08, 0, 0, 0, 1, 0x00, 0x01, 0x61, 0x01, 0x00, 0x00, 0x00, 0x09])
    }
    check("amf0 round trip") {
        let command: [AMF0] = [
            .string("connect"), .number(1),
            .object([.init(key: "app", value: .string("live2")),
                     .init(key: "fpad", value: .boolean(false)),
                     .init(key: "list", value: .ecmaArray([.init(key: "n", value: .number(2.5))]))]),
            .null, .string("end"),
        ]
        var data = Data()
        for value in command { value.encode(into: &data) }
        let decoded = try AMF0.decode(data)
        try expect(decoded == command)
        try expect(decoded[2]["app"] == .string("live2"))
        try expect(decoded[2]["list"]?["n"] == .number(2.5))
        try expect(decoded[0]["app"] == nil)
    }
    check("amf0 undefined decodes as null") {
        try expect(try AMF0.decode(Data([0x06])) == [.null])
    }
    check("amf0 truncated data throws") {
        var data = Data()
        AMF0.object([.init(key: "app", value: .string("live2"))]).encode(into: &data)
        for length in [1, 4, 9, data.count - 1] {
            var threw = false
            do { _ = try AMF0.decode(data.prefix(length)) } catch { threw = true }
            try expect(threw, "length \(length)")
        }
    }
    check("amf0 strict array and unknown marker throw") {
        for marker: UInt8 in [0x0A, 0x7F] {
            var threw = false
            do { _ = try AMF0.decode(Data([marker, 0, 0, 0, 0])) } catch { threw = true }
            try expect(threw, "marker \(marker)")
        }
    }
    check("amf0 nesting limit") {
        func nested(_ levels: Int) -> Data {
            var data = Data()
            for _ in 0 ..< levels { data.append(contentsOf: [0x03, 0x00, 0x01, 0x61]) }
            data.append(contentsOf: [0x05])
            for _ in 0 ..< levels { data.append(contentsOf: [0x00, 0x00, 0x09]) }
            return data
        }
        try expect(try AMF0.decode(nested(AMF0.maxDepth)).count == 1)
        var threw = false
        do { _ = try AMF0.decode(nested(AMF0.maxDepth + 1)) } catch { threw = true }
        try expect(threw, "one past the limit")
        var endless = Data()
        for _ in 0 ..< 100_000 { endless.append(contentsOf: [0x03, 0x00, 0x01, 0x61]) }
        threw = false
        do { _ = try AMF0.decode(endless) } catch { threw = true }
        try expect(threw, "100000 levels")
    }
}
