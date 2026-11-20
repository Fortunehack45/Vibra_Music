import Foundation

/// One stored preference with the type it must be restored as: the unit of a settings backup.
///
/// Encodes exactly like Android's `Backup.PrefValue` — `{"type":"bool","value":"true"}`,
/// `{"type":"stringSet","values":[…]}` — with numbers written as strings. JSON has one number type
/// and every parser picks its own back off it; on Android a `0.5` read back as a Double crashed a
/// Float preference weeks later. Carrying the type removes the ambiguity, and anything with an
/// unrecognised type decodes as ``unsupported`` and is skipped on import rather than guessed at.
public enum SettingValue: Hashable, Sendable {
    case bool(Bool)
    case int(Int)
    case long(Int64)
    case float(Float)
    case string(String)
    case stringSet(Set<String>)
    /// A type this build doesn't know (written by a newer one). Never applied.
    case unsupported(type: String)

    /// The Android `PrefValue.type` tag.
    public var typeTag: String {
        switch self {
        case .bool: return "bool"
        case .int: return "int"
        case .long: return "long"
        case .float: return "float"
        case .string: return "string"
        case .stringSet: return "stringSet"
        case .unsupported(let type): return type
        }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// Int, long and float values as an Int (floats truncated), for tolerant numeric reads.
    public var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .long(let value): return Int(exactly: value)
        case .float(let value): return value.isFinite ? Int(value) : nil
        default: return nil
        }
    }

    public var int64Value: Int64? {
        switch self {
        case .int(let value): return Int64(value)
        case .long(let value): return value
        case .float(let value): return value.isFinite ? Int64(value) : nil
        default: return nil
        }
    }

    public var floatValue: Float? {
        switch self {
        case .float(let value): return value
        case .int(let value): return Float(value)
        case .long(let value): return Float(value)
        default: return nil
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var stringSetValue: Set<String>? {
        if case .stringSet(let value) = self { return value }
        return nil
    }
}

extension SettingValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, value, values
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        let value = try c.decodeIfPresent(String.self, forKey: .value)
        switch type {
        case "bool":
            // Kotlin's toBooleanStrictOrNull: exactly "true" or "false".
            switch value {
            case "true": self = .bool(true)
            case "false": self = .bool(false)
            default: self = .unsupported(type: type)
            }
        case "int":
            self = value.flatMap(Int.init).map(SettingValue.int) ?? .unsupported(type: type)
        case "long":
            self = value.flatMap(Int64.init).map(SettingValue.long) ?? .unsupported(type: type)
        case "float":
            self = value.flatMap(Float.init).map(SettingValue.float) ?? .unsupported(type: type)
        case "string":
            self = value.map(SettingValue.string) ?? .unsupported(type: type)
        case "stringSet":
            self = .stringSet(Set(try c.decodeIfPresent([String].self, forKey: .values) ?? []))
        default:
            self = .unsupported(type: type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(typeTag, forKey: .type)
        switch self {
        case .bool(let value): try c.encode(value ? "true" : "false", forKey: .value)
        case .int(let value): try c.encode(String(value), forKey: .value)
        case .long(let value): try c.encode(String(value), forKey: .value)
        // Swift's description matches Kotlin's Float.toString() for ordinary values ("1.0", "0.5").
        case .float(let value): try c.encode(value.description, forKey: .value)
        case .string(let value): try c.encode(value, forKey: .value)
        case .stringSet(let values): try c.encode(values.sorted(), forKey: .values)
        case .unsupported: break
        }
    }
}
