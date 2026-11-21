import Foundation

/// The AMF0 values RTMP commands are made of (connect, createStream, publish, onStatus...).
indirect enum AMF0: Equatable {
    struct Property: Equatable {
        let key: String
        let value: AMF0
    }

    case number(Double), boolean(Bool), string(String), null
    case object([Property]), ecmaArray([Property])

    enum DecodeError: Error { case truncated, unsupported(UInt8), tooDeep }

    /// Payloads come from a remote server, so nesting is capped to keep a hostile one from overflowing the stack.
    static let maxDepth = 32

    func encode(into data: inout Data) {
        switch self {
        case .number(let value):
            data.append(0x00)
            data.append(contentsOf: withUnsafeBytes(of: value.bitPattern.bigEndian, Array.init))
        case .boolean(let value):
            data.append(0x01)
            data.append(value ? 1 : 0)
        case .string(let value):
            data.append(0x02)
            AMF0.appendString(value, to: &data)
        case .object(let properties):
            data.append(0x03)
            AMF0.appendProperties(properties, to: &data)
        case .null:
            data.append(0x05)
        case .ecmaArray(let properties):
            data.append(0x08)
            data.append(contentsOf: withUnsafeBytes(of: UInt32(properties.count).bigEndian, Array.init))
            AMF0.appendProperties(properties, to: &data)
        }
    }

    /// Every value in the payload, in order.
    static func decode(_ data: Data) throws -> [AMF0] {
        var reader = Reader(bytes: Array(data))
        var values: [AMF0] = []
        while !reader.atEnd { values.append(try reader.value()) }
        return values
    }

    subscript(key: String) -> AMF0? {
        switch self {
        case .object(let properties), .ecmaArray(let properties):
            return properties.first { $0.key == key }?.value
        default:
            return nil
        }
    }

    private static func appendString(_ value: String, to data: inout Data) {
        let utf8 = Array(value.utf8.prefix(Int(UInt16.max)))
        data.append(contentsOf: withUnsafeBytes(of: UInt16(utf8.count).bigEndian, Array.init))
        data.append(contentsOf: utf8)
    }

    private static func appendProperties(_ properties: [Property], to data: inout Data) {
        for property in properties {
            appendString(property.key, to: &data)
            property.value.encode(into: &data)
        }
        data.append(contentsOf: [0x00, 0x00, 0x09])
    }

    private struct Reader {
        let bytes: [UInt8]
        var position = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { position >= bytes.count }

        mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count <= bytes.count - position else { throw DecodeError.truncated }
            defer { position += count }
            return bytes[position ..< position + count]
        }

        mutating func integer(_ count: Int) throws -> UInt64 {
            try take(count).reduce(0) { $0 << 8 | UInt64($1) }
        }

        mutating func string() throws -> String {
            let length = Int(try integer(2))
            return String(decoding: try take(length), as: UTF8.self)
        }

        mutating func properties(depth: Int) throws -> [Property] {
            var result: [Property] = []
            while true {
                let key = try string()
                if key.isEmpty {
                    guard try integer(1) == 0x09 else { throw DecodeError.unsupported(0x09) }
                    return result
                }
                result.append(Property(key: key, value: try value(depth: depth)))
            }
        }

        mutating func value(depth: Int = 0) throws -> AMF0 {
            let marker = UInt8(try integer(1))
            switch marker {
            case 0x00: return .number(Double(bitPattern: try integer(8)))
            case 0x01: return .boolean(try integer(1) != 0)
            case 0x02: return .string(try string())
            case 0x03:
                guard depth < AMF0.maxDepth else { throw DecodeError.tooDeep }
                return .object(try properties(depth: depth + 1))
            case 0x05, 0x06: return .null
            case 0x08:
                guard depth < AMF0.maxDepth else { throw DecodeError.tooDeep }
                _ = try integer(4)
                return .ecmaArray(try properties(depth: depth + 1))
            default: throw DecodeError.unsupported(marker)
            }
        }
    }
}
