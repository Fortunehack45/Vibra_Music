import Foundation

// The JSON model Innertube responses are read through (Android: kotlinx.serialization's JsonElement).

/// A parsed JSON value that keeps object keys in document order.
///
/// Order is not cosmetic here. The parser finds renderers by walking the whole response depth-first
/// and takes "the first one" in several places — the page header before the recommendation shelves,
/// the row's own like button before a neighbour's — and kotlinx.serialization's objects iterate in
/// document order. `JSONSerialization` hands back dictionaries in hash order, which would make
/// "first" mean something different on every run. So responses are parsed with ``parse(_:)``.
///
/// Numbers keep their literal text: Kotlin's `JsonPrimitive.content` is the literal, and reading a
/// width, a millisecond offset or a `"true"` flag works the same whichever way YouTube typed it.
public indirect enum InnerTubeJSON: Hashable, Sendable {
    case null
    case bool(Bool)
    /// The number's literal text, exactly as it appeared.
    case number(String)
    case string(String)
    case array([InnerTubeJSON])
    case object(InnerTubeJSONObject)

    /// Parses UTF-8 JSON text.
    public static func parse(_ data: Data) throws -> InnerTubeJSON {
        try data.withUnsafeBytes { raw in
            var reader = JSONReader(bytes: raw.bindMemory(to: UInt8.self))
            return try reader.parseDocument()
        }
    }

    /// Parses JSON text.
    public static func parse(_ text: String) throws -> InnerTubeJSON {
        try parse(Data(text.utf8))
    }

    /// Compact JSON text for this value (request bodies).
    public func serialized() -> Data {
        var out = [UInt8]()
        out.reserveCapacity(256)
        write(into: &out)
        return Data(out)
    }

    // MARK: Accessors

    public var objectValue: InnerTubeJSONObject? {
        if case .object(let object) = self { return object }
        return nil
    }

    public var arrayValue: [InnerTubeJSON]? {
        if case .array(let array) = self { return array }
        return nil
    }

    /// Kotlin's `JsonPrimitive.contentOrNull`: a string's text, a number's literal, `"true"`/`"false"`
    /// for a boolean, nil for null and for arrays and objects.
    public var primitiveContent: String? {
        switch self {
        case .string(let text): return text
        case .number(let literal): return literal
        case .bool(let value): return value ? "true" : "false"
        case .null, .array, .object: return nil
        }
    }

    /// The value under `key`, when this is an object.
    public subscript(key: String) -> InnerTubeJSON? {
        objectValue?[key]
    }
}

/// A JSON object with its keys in document order. A repeated key keeps its first position and its
/// last value, as kotlinx.serialization does.
public struct InnerTubeJSONObject: Hashable, Sendable {
    public private(set) var keys: [String] = []
    public private(set) var values: [InnerTubeJSON] = []
    private var index: [String: Int] = [:]

    public init() {}

    public init(_ pairs: KeyValuePairs<String, InnerTubeJSON>) {
        for (key, value) in pairs { self[key] = value }
    }

    public subscript(key: String) -> InnerTubeJSON? {
        get { index[key].map { values[$0] } }
        set {
            if let position = index[key] {
                if let newValue {
                    values[position] = newValue
                } else {
                    keys.remove(at: position)
                    values.remove(at: position)
                    index = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })
                }
            } else if let newValue {
                index[key] = keys.count
                keys.append(key)
                values.append(newValue)
            }
        }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    /// Key/value pairs in document order.
    public var entries: Zip2Sequence<[String], [InnerTubeJSON]> { zip(keys, values) }

    public static func == (lhs: InnerTubeJSONObject, rhs: InnerTubeJSONObject) -> Bool {
        lhs.keys == rhs.keys && lhs.values == rhs.values
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(keys)
        hasher.combine(values)
    }
}

/// Malformed JSON, with the byte offset it was noticed at.
public struct InnerTubeJSONError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public let offset: Int
    public var description: String { "Invalid JSON at byte \(offset): \(message)" }
}

// MARK: - Literals (tests and request bodies)

extension InnerTubeJSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(String(value)) }
    public init(arrayLiteral elements: InnerTubeJSON...) { self = .array(elements) }
    public init(nilLiteral: ()) { self = .null }
    public init(dictionaryLiteral elements: (String, InnerTubeJSON)...) {
        var object = InnerTubeJSONObject()
        for (key, value) in elements { object[key] = value }
        self = .object(object)
    }
}

// MARK: - Parser

private struct JSONReader {
    let bytes: UnsafeBufferPointer<UInt8>
    var position = 0

    init(bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
        // A UTF-8 byte order mark is tolerated, as kotlinx does.
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { position = 3 }
    }

    mutating func parseDocument() throws -> InnerTubeJSON {
        skipWhitespace()
        let value = try parseValue(depth: 0)
        skipWhitespace()
        guard position == bytes.count else { throw error("trailing characters") }
        return value
    }

    private func error(_ message: String) -> InnerTubeJSONError {
        InnerTubeJSONError(message: message, offset: position)
    }

    private mutating func skipWhitespace() {
        while position < bytes.count {
            switch bytes[position] {
            case 0x20, 0x0A, 0x0D, 0x09: position += 1
            default: return
            }
        }
    }

    private mutating func parseValue(depth: Int) throws -> InnerTubeJSON {
        // Real responses nest a few dozen levels; this only stops a hostile body from blowing the stack.
        guard depth < 512 else { throw error("nesting too deep") }
        guard position < bytes.count else { throw error("unexpected end of input") }
        switch bytes[position] {
        case UInt8(ascii: "{"): return try parseObject(depth: depth)
        case UInt8(ascii: "["): return try parseArray(depth: depth)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try parseNumber())
        default: throw error("unexpected character")
        }
    }

    private mutating func expect(_ word: StaticString) throws {
        let count = word.utf8CodeUnitCount
        guard position + count <= bytes.count else { throw error("unexpected end of input") }
        let expected = UnsafeBufferPointer(start: word.utf8Start, count: count)
        for offset in 0..<count where bytes[position + offset] != expected[offset] {
            throw error("invalid literal")
        }
        position += count
    }

    private mutating func parseObject(depth: Int) throws -> InnerTubeJSON {
        position += 1
        var object = InnerTubeJSONObject()
        skipWhitespace()
        if position < bytes.count, bytes[position] == UInt8(ascii: "}") {
            position += 1
            return .object(object)
        }
        while true {
            skipWhitespace()
            guard position < bytes.count, bytes[position] == UInt8(ascii: "\"") else { throw error("expected a key") }
            let key = try parseString()
            skipWhitespace()
            guard position < bytes.count, bytes[position] == UInt8(ascii: ":") else { throw error("expected ':'") }
            position += 1
            skipWhitespace()
            object[key] = try parseValue(depth: depth + 1)
            skipWhitespace()
            guard position < bytes.count else { throw error("unterminated object") }
            if bytes[position] == UInt8(ascii: ",") { position += 1; continue }
            if bytes[position] == UInt8(ascii: "}") { position += 1; return .object(object) }
            throw error("expected ',' or '}'")
        }
    }

    private mutating func parseArray(depth: Int) throws -> InnerTubeJSON {
        position += 1
        var array: [InnerTubeJSON] = []
        skipWhitespace()
        if position < bytes.count, bytes[position] == UInt8(ascii: "]") {
            position += 1
            return .array(array)
        }
        while true {
            skipWhitespace()
            array.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            guard position < bytes.count else { throw error("unterminated array") }
            if bytes[position] == UInt8(ascii: ",") { position += 1; continue }
            if bytes[position] == UInt8(ascii: "]") { position += 1; return .array(array) }
            throw error("expected ',' or ']'")
        }
    }

    private mutating func parseNumber() throws -> String {
        let start = position
        if bytes[position] == UInt8(ascii: "-") { position += 1 }
        var digits = 0
        while position < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[position]) {
            position += 1
            digits += 1
        }
        guard digits > 0 else { throw error("invalid number") }
        if position < bytes.count, bytes[position] == UInt8(ascii: ".") {
            position += 1
            var fraction = 0
            while position < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[position]) {
                position += 1
                fraction += 1
            }
            guard fraction > 0 else { throw error("invalid number") }
        }
        if position < bytes.count, bytes[position] == UInt8(ascii: "e") || bytes[position] == UInt8(ascii: "E") {
            position += 1
            if position < bytes.count, bytes[position] == UInt8(ascii: "+") || bytes[position] == UInt8(ascii: "-") {
                position += 1
            }
            var exponent = 0
            while position < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[position]) {
                position += 1
                exponent += 1
            }
            guard exponent > 0 else { throw error("invalid number") }
        }
        return String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<position]), as: UTF8.self)
    }

    private mutating func parseString() throws -> String {
        position += 1
        let start = position
        // Fast path: no escapes, so the bytes between the quotes are the string.
        while position < bytes.count {
            let byte = bytes[position]
            if byte == UInt8(ascii: "\"") {
                let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<position]), as: UTF8.self)
                position += 1
                return text
            }
            if byte == UInt8(ascii: "\\") { break }
            position += 1
        }
        var buffer = [UInt8](UnsafeBufferPointer(rebasing: bytes[start..<position]))
        while position < bytes.count {
            let byte = bytes[position]
            if byte == UInt8(ascii: "\"") {
                position += 1
                return String(decoding: buffer, as: UTF8.self)
            }
            guard byte == UInt8(ascii: "\\") else {
                buffer.append(byte)
                position += 1
                continue
            }
            position += 1
            guard position < bytes.count else { break }
            let escape = bytes[position]
            position += 1
            switch escape {
            case UInt8(ascii: "\""): buffer.append(UInt8(ascii: "\""))
            case UInt8(ascii: "\\"): buffer.append(UInt8(ascii: "\\"))
            case UInt8(ascii: "/"): buffer.append(UInt8(ascii: "/"))
            case UInt8(ascii: "b"): buffer.append(0x08)
            case UInt8(ascii: "f"): buffer.append(0x0C)
            case UInt8(ascii: "n"): buffer.append(0x0A)
            case UInt8(ascii: "r"): buffer.append(0x0D)
            case UInt8(ascii: "t"): buffer.append(0x09)
            case UInt8(ascii: "u"):
                var scalar = try readHex4()
                if (0xD800...0xDBFF).contains(scalar) {
                    // A surrogate pair spells one character across two escapes. A lone half is
                    // replaced rather than rejected, as lenient decoders do.
                    if position + 1 < bytes.count, bytes[position] == UInt8(ascii: "\\"), bytes[position + 1] == UInt8(ascii: "u") {
                        position += 2
                        let low = try readHex4()
                        if (0xDC00...0xDFFF).contains(low) {
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            appendScalar(0xFFFD, to: &buffer)
                            scalar = low
                        }
                    } else {
                        scalar = 0xFFFD
                    }
                } else if (0xDC00...0xDFFF).contains(scalar) {
                    scalar = 0xFFFD
                }
                appendScalar(scalar, to: &buffer)
            default:
                throw error("invalid escape")
            }
        }
        throw error("unterminated string")
    }

    private mutating func readHex4() throws -> UInt32 {
        guard position + 4 <= bytes.count else { throw error("truncated \\u escape") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[position]
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
            default: throw error("invalid \\u escape")
            }
            value = value << 4 | digit
            position += 1
        }
        return value
    }

    private func appendScalar(_ value: UInt32, to buffer: inout [UInt8]) {
        let scalar = Unicode.Scalar(value) ?? "\u{FFFD}"
        buffer.append(contentsOf: Array(String(Character(scalar)).utf8))
    }
}

// MARK: - Writer

extension InnerTubeJSON {
    fileprivate func write(into out: inout [UInt8]) {
        switch self {
        case .null: out.append(contentsOf: Array("null".utf8))
        case .bool(let value): out.append(contentsOf: Array((value ? "true" : "false").utf8))
        case .number(let literal): out.append(contentsOf: Array(literal.utf8))
        case .string(let text): Self.writeString(text, into: &out)
        case .array(let array):
            out.append(UInt8(ascii: "["))
            for (offset, element) in array.enumerated() {
                if offset > 0 { out.append(UInt8(ascii: ",")) }
                element.write(into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let object):
            out.append(UInt8(ascii: "{"))
            for (offset, (key, value)) in object.entries.enumerated() {
                if offset > 0 { out.append(UInt8(ascii: ",")) }
                Self.writeString(key, into: &out)
                out.append(UInt8(ascii: ":"))
                value.write(into: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    private static func writeString(_ text: String, into out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "\""): out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\"")])
            case UInt8(ascii: "\\"): out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\\")])
            case 0x0A: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "n")])
            case 0x0D: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "r")])
            case 0x09: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "t")])
            case 0x00..<0x20:
                out.append(contentsOf: Array(String(format: "\\u%04x", byte).utf8))
            default:
                out.append(byte)
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}

// MARK: - Null-safe navigation (Android's o / a / s helpers)

// Innertube responses are deeply nested and every level can be missing, so reads are chains of
// lookups that simply yield nil (or "") when any step is absent — never a crash, never a throw.
// They are defined on both the value and its Optional so a chain reads like the Kotlin it ports:
// `renderer.o("title").o("runs")` rather than a ladder of `?.`.

extension InnerTubeJSON {
    /// The object under `key`.
    func o(_ key: String) -> InnerTubeJSON? {
        guard let value = self[key], case .object = value else { return nil }
        return value
    }

    /// The array under `key`.
    func a(_ key: String) -> [InnerTubeJSON]? {
        self[key]?.arrayValue
    }

    /// The primitive under `key`, as text (see ``primitiveContent``).
    func s(_ key: String) -> String? {
        self[key]?.primitiveContent
    }

    /// A `runs` text joined back together; "" when there are none.
    func runs() -> String {
        (a("runs") ?? []).map { $0.s("text") ?? "" }.joined()
    }

    /// The first run's text alone — for a field that is a count or a label, never a sentence.
    func firstRunText() -> String? {
        a("runs")?.first?.s("text")
    }

    /// The first string under `key` anywhere in the subtree, by name rather than by path — for a
    /// value whose position is not promised (see ``InnerTubeParser/parseAccountChannels(_:)``).
    func findString(_ key: String) -> String? {
        switch self {
        case .object(let object):
            if let direct = object[key]?.primitiveContent { return direct }
            for value in object.values {
                if let found = value.findString(key) { return found }
            }
            return nil
        case .array(let array):
            for value in array {
                if let found = value.findString(key) { return found }
            }
            return nil
        default:
            return nil
        }
    }
}

extension Optional where Wrapped == InnerTubeJSON {
    func o(_ key: String) -> InnerTubeJSON? { self?.o(key) }
    func a(_ key: String) -> [InnerTubeJSON]? { self?.a(key) }
    func s(_ key: String) -> String? { self?.s(key) }
    func runs() -> String { self?.runs() ?? "" }
    func firstRunText() -> String? { self?.firstRunText() }
    func findString(_ key: String) -> String? { self?.findString(key) }
}

extension Array where Element == InnerTubeJSON {
    /// Last thumbnail is the largest, taken exactly as offered.
    ///
    /// Android used to rewrite the size hint up to 544 px here; it no longer does, because a search
    /// row's cover at 120 px is 7.8 kB and the same cover at 544 px is 84 kB, to fill a square the
    /// size of a fingertip. The size is decided where the image is drawn (``Song/artworkAt(_:)``).
    func bestThumbnail() -> String? {
        last?.s("url")
    }

    /// Catalogue art is square; a music-video upload's thumbnail is widescreen. Missing dimensions
    /// count as square so a row is never dropped just because the field wasn't present.
    func isNotSquare() -> Bool {
        guard let last = last,
              let width = last.s("width").flatMap(Double.init),
              let height = last.s("height").flatMap(Double.init),
              width > 0, height > 0 else { return false }
        let ratio = width / height
        return !(0.85...1.15).contains(ratio)
    }
}

extension Optional where Wrapped == [InnerTubeJSON] {
    func bestThumbnail() -> String? { self?.bestThumbnail() }
    func isNotSquare() -> Bool { self?.isNotSquare() ?? false }
}
