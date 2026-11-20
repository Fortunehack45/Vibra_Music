import Foundation

/// A parsed JSON document, modelled the way kotlinx.serialization's `JsonElement` is.
///
/// `JSONSerialization` would be less code, but two things it does not keep matter here:
/// object key *order* — several providers are read by walking a payload and taking the
/// first match (`PaxSenix` candidates, YouTube's tab renderers), and ties between
/// equally good candidates go to whichever came first — and the text a number was
/// written as, which is what `contentOrNull` returns for an id like `617154366`.
indirect enum LyricsJSON: Sendable, Equatable {
    case object(LyricsJSONObject)
    case array([LyricsJSON])
    case string(String)
    /// The literal exactly as written, e.g. `248.0`.
    case number(String)
    case bool(Bool)
    case null

    // MARK: Parsing

    /// The document in [text], or nil if it is not exactly one JSON value.
    static func parse(_ text: String) -> LyricsJSON? {
        var reader = Reader(bytes: Array(text.utf8))
        reader.skipWhitespace()
        guard let value = reader.value(depth: 0) else { return nil }
        reader.skipWhitespace()
        return reader.atEnd ? value : nil
    }

    // MARK: Access (the kotlinx accessors this code leans on)

    subscript(key: String) -> LyricsJSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var object: LyricsJSONObject? {
        if case .object(let object) = self { return object }
        return nil
    }

    var array: [LyricsJSON]? {
        if case .array(let array) = self { return array }
        return nil
    }

    var isNull: Bool { self == .null }

    var isPrimitive: Bool {
        switch self {
        case .object, .array: false
        default: true
        }
    }

    /// `JsonPrimitive.isString`.
    var isString: Bool {
        if case .string = self { return true }
        return false
    }

    /// `jsonPrimitive.contentOrNull`: a string's value, a number's literal, `true`/`false`;
    /// nil for `null` and for anything that is not a primitive.
    var content: String? {
        switch self {
        case .string(let value): value
        case .number(let literal): literal
        case .bool(let value): value ? "true" : "false"
        case .null, .object, .array: nil
        }
    }

    /// `longOrNull`: the content as a whole number, from a number *or* a numeric string.
    var long: Int? { content.flatMap { Int($0) } }

    /// `doubleOrNull`.
    var double: Double? { content.flatMap { Double($0) } }

    /// `JsonElement.toString()`: compact JSON, strings quoted.
    var serialized: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let literal): return literal
        case .string(let value): return Self.quote(value)
        case .array(let values): return "[" + values.map(\.serialized).joined(separator: ",") + "]"
        case .object(let object):
            return "{" + object.entries.map { Self.quote($0.key) + ":" + $0.value.serialized }
                .joined(separator: ",") + "}"
        }
    }

    private static func quote(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: Reader

    private struct Reader {
        let bytes: [UInt8]
        var index = 0

        var atEnd: Bool { index >= bytes.count }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value(depth: Int) -> LyricsJSON? {
            guard depth < 512, index < bytes.count else { return nil }
            switch bytes[index] {
            case UInt8(ascii: "{"): return object(depth: depth)
            case UInt8(ascii: "["): return array(depth: depth)
            case UInt8(ascii: "\""): return string().map(LyricsJSON.string)
            case UInt8(ascii: "t"): return literal("true", .bool(true))
            case UInt8(ascii: "f"): return literal("false", .bool(false))
            case UInt8(ascii: "n"): return literal("null", .null)
            default: return number()
            }
        }

        private mutating func literal(_ word: String, _ value: LyricsJSON) -> LyricsJSON? {
            let utf8 = Array(word.utf8)
            guard index + utf8.count <= bytes.count, Array(bytes[index..<index + utf8.count]) == utf8 else {
                return nil
            }
            index += utf8.count
            return value
        }

        private mutating func number() -> LyricsJSON? {
            let start = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            var digits = 0
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1; digits += 1 }
            guard digits > 0 else { return nil }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                var fraction = 0
                while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1; fraction += 1 }
                guard fraction > 0 else { return nil }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                    index += 1
                }
                var exponent = 0
                while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1; exponent += 1 }
                guard exponent > 0 else { return nil }
            }
            return .number(String(decoding: bytes[start..<index], as: UTF8.self))
        }

        private mutating func string() -> String? {
            guard bytes[index] == UInt8(ascii: "\"") else { return nil }
            index += 1
            var out = [UInt8]()
            var pendingHigh: UInt32?
            func flushHigh(_ out: inout [UInt8]) {
                if pendingHigh != nil {
                    out.append(contentsOf: Array("\u{FFFD}".utf8))
                    pendingHigh = nil
                }
            }
            while index < bytes.count {
                let byte = bytes[index]
                switch byte {
                case UInt8(ascii: "\""):
                    index += 1
                    flushHigh(&out)
                    return String(decoding: out, as: UTF8.self)
                case UInt8(ascii: "\\"):
                    index += 1
                    guard index < bytes.count else { return nil }
                    let escape = bytes[index]
                    index += 1
                    if escape == UInt8(ascii: "u") {
                        guard index + 4 <= bytes.count,
                              let code = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
                        else { return nil }
                        index += 4
                        if (0xD800...0xDBFF).contains(code) {
                            flushHigh(&out)
                            pendingHigh = code
                            continue
                        }
                        if (0xDC00...0xDFFF).contains(code), let high = pendingHigh {
                            pendingHigh = nil
                            let combined = 0x10000 + ((high - 0xD800) << 10) + (code - 0xDC00)
                            if let scalar = Unicode.Scalar(combined) { out.append(contentsOf: Array(String(scalar).utf8)) }
                            continue
                        }
                        flushHigh(&out)
                        let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
                        out.append(contentsOf: Array(String(scalar).utf8))
                        continue
                    }
                    flushHigh(&out)
                    switch escape {
                    case UInt8(ascii: "\""): out.append(UInt8(ascii: "\""))
                    case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\"))
                    case UInt8(ascii: "/"): out.append(UInt8(ascii: "/"))
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    default: return nil
                    }
                default:
                    flushHigh(&out)
                    out.append(byte)
                    index += 1
                }
            }
            return nil
        }

        private mutating func array(depth: Int) -> LyricsJSON? {
            index += 1
            var values = [LyricsJSON]()
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(values)
            }
            while true {
                skipWhitespace()
                guard let value = value(depth: depth + 1) else { return nil }
                values.append(value)
                skipWhitespace()
                guard index < bytes.count else { return nil }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(values) }
                return nil
            }
        }

        private mutating func object(depth: Int) -> LyricsJSON? {
            index += 1
            var object = LyricsJSONObject()
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(object)
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\""), let key = string() else { return nil }
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
                index += 1
                skipWhitespace()
                guard let value = value(depth: depth + 1) else { return nil }
                object[key] = value
                skipWhitespace()
                guard index < bytes.count else { return nil }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
                return nil
            }
        }
    }
}

/// A JSON object that remembers the order its keys were written in.
struct LyricsJSONObject: Sendable, Equatable {
    private(set) var keys: [String] = []
    private var storage: [String: LyricsJSON] = [:]

    subscript(key: String) -> LyricsJSON? {
        get { storage[key] }
        set {
            if storage[key] == nil, newValue != nil { keys.append(key) }
            if newValue == nil { keys.removeAll { $0 == key } }
            storage[key] = newValue
        }
    }

    /// Values in written order — kotlinx's `JsonObject.values`.
    var values: [LyricsJSON] { keys.compactMap { storage[$0] } }

    var entries: [(key: String, value: LyricsJSON)] { keys.compactMap { key in storage[key].map { (key, $0) } } }

    var isEmpty: Bool { keys.isEmpty }
}
