import Foundation

// The Kotlin side decodes every wire shape in this module with
// `Json { isLenient = true; ignoreUnknownKeys = true; coerceInputValues = true }`: a field of the
// wrong type falls back to its default instead of failing the whole document. Swift's synthesized
// Codable is the opposite, so the models here decode field by field through these helpers.

/// Any JSON value, for the few fields whose type is specified as "string, number or boolean"
/// (addon setting defaults, `encrypted`) and for shape detection in `SourceFormats`.
enum JSONValue: Decodable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unreadable JSON value")
        }
    }

    /// Parses `data` as a JSON document, or nil when it is not one.
    static func parse(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// The literal text a scalar would carry in a query parameter (Kotlin `JsonPrimitive.content`):
    /// `320` stays `320`, never `320.0`. Null and composites have no single-parameter form.
    var queryValue: String? {
        switch self {
        case .string(let text): return text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : text
        case .number(let number): return Self.format(number)
        case .bool(let flag): return flag ? "true" : "false"
        case .array, .object, .null: return nil
        }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let array) = self { return array }
        return nil
    }

    var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    static func format(_ number: Double) -> String {
        if number.rounded() == number, abs(number) < 1e15 { return String(Int64(number)) }
        return String(number)
    }
}

/// Decoding keys by name, for models that read whatever keys they are given.
struct AnyCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int? = nil

    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

extension KeyedDecodingContainer where Key == AnyCodingKey {
    /// A string field, accepting a number or boolean in its place (lenient Kotlin decoding reads
    /// `"id": 42` as `"42"`). Nil when absent, null or composite.
    func lenientString(_ key: String) -> String? {
        guard let value = try? decodeIfPresent(JSONValue.self, forKey: AnyCodingKey(key)) else { return nil }
        switch value {
        case .string(let text): return text
        case .number(let number): return JSONValue.format(number)
        case .bool(let flag): return flag ? "true" : "false"
        default: return nil
        }
    }

    /// A number field, accepting a numeric string. Nil when absent or unreadable, and when not
    /// finite or past ±2^53: no real duration, rate or bitrate comes near, and every reader turns
    /// it into an Int, which traps on those.
    func lenientDouble(_ key: String) -> Double? {
        guard let value = try? decodeIfPresent(JSONValue.self, forKey: AnyCodingKey(key)) else { return nil }
        let parsed: Double?
        switch value {
        case .number(let number): parsed = number
        case .string(let text): parsed = Double(text.trimmingCharacters(in: .whitespaces))
        default: parsed = nil
        }
        guard let number = parsed, number.isFinite, abs(number) <= 9_007_199_254_740_992 else { return nil }
        return number
    }

    func lenientInt(_ key: String) -> Int? {
        lenientDouble(key).flatMap { $0.isFinite ? Int(exactly: $0.rounded(.towardZero)) : nil }
    }

    func lenientBool(_ key: String) -> Bool? {
        guard let value = try? decodeIfPresent(JSONValue.self, forKey: AnyCodingKey(key)) else { return nil }
        switch value {
        case .bool(let flag): return flag
        case .string(let text): return text.lowercased() == "true" ? true : (text.lowercased() == "false" ? false : nil)
        case .number(let number): return number != 0
        default: return nil
        }
    }

    /// A list of strings, skipping entries that aren't scalars. Empty when absent.
    func lenientStrings(_ key: String) -> [String] {
        guard case .array(let items)? = try? decodeIfPresent(JSONValue.self, forKey: AnyCodingKey(key)) else { return [] }
        return items.compactMap { item in
            switch item {
            case .string(let text): return text
            case .number(let number): return JSONValue.format(number)
            default: return nil
            }
        }
    }

    func json(_ key: String) -> JSONValue? {
        (try? decodeIfPresent(JSONValue.self, forKey: AnyCodingKey(key))) ?? nil
    }

    /// A list of decodable elements, dropping the ones that fail rather than the whole list.
    func lenientArray<Element: Decodable>(_ key: String, of type: Element.Type) -> [Element] {
        guard let wrapped = try? decodeIfPresent([LossyElement<Element>].self, forKey: AnyCodingKey(key)) else { return [] }
        return wrapped.compactMap(\.value)
    }

    func lenientObject<Value: Decodable>(_ key: String, as type: Value.Type) -> Value? {
        (try? decodeIfPresent(Value.self, forKey: AnyCodingKey(key))) ?? nil
    }
}

/// One element of a lossy array: nil when it failed to decode.
struct LossyElement<Element: Decodable>: Decodable {
    let value: Element?
    init(from decoder: Decoder) throws {
        value = try? Element(from: decoder)
    }
}

extension String {
    /// Kotlin's `ifBlank { null }`.
    var nonBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }

    /// Kotlin's `substringBefore`: everything before the first `delimiter`, or the whole string.
    func before(_ delimiter: String) -> String {
        guard let range = range(of: delimiter) else { return self }
        return String(self[..<range.lowerBound])
    }

    /// Kotlin's `substringAfterLast`: everything after the last `delimiter`, or `missing`.
    func afterLast(_ delimiter: String, missing: String? = nil) -> String {
        guard let range = range(of: delimiter, options: .backwards) else { return missing ?? self }
        return String(self[range.upperBound...])
    }

    /// Kotlin's `substringBeforeLast`: everything before the last `delimiter`, or the whole string.
    func beforeLast(_ delimiter: String) -> String {
        guard let range = range(of: delimiter, options: .backwards) else { return self }
        return String(self[..<range.lowerBound])
    }

    /// Kotlin's `trimEnd(char)`.
    func trimmingTrailing(_ character: Character) -> String {
        var text = Substring(self)
        while text.last == character { text = text.dropLast() }
        return String(text)
    }
}

/// A compiled regular expression with the few operations the Kotlin code uses.
struct Pattern: @unchecked Sendable {
    let regex: NSRegularExpression

    init(_ pattern: String, caseInsensitive: Bool = false) {
        // Every pattern here is a literal in this module; a typo is a programming error that the
        // tests catch on first run.
        regex = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    func firstMatch(in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    func contains(in text: String) -> Bool { firstMatch(in: text) != nil }

    /// Capture group `group` of the first match, or nil.
    func firstGroup(_ group: Int = 1, in text: String) -> String? {
        guard let match = firstMatch(in: text), let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }

    func replacing(in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// Kotlin's `split(regex)`: pieces between matches, empty ones included.
    func split(_ text: String) -> [String] {
        var pieces: [String] = []
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            if range.isEmpty { continue }
            pieces.append(String(text[cursor..<range.lowerBound]))
            cursor = range.upperBound
        }
        pieces.append(String(text[cursor...]))
        return pieces
    }
}
