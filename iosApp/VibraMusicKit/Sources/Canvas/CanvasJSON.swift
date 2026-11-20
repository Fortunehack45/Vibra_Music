import Foundation

/// Minimal JSON value for the canvas providers. `Codable` models would need one struct per
/// endpoint shape across four vendors; these providers only pluck a handful of fields out of
/// each response, so a small dynamic value keeps the parsing next to the call site the way
/// Android's `kotlinx.serialization` `JsonObject` reads do.
enum CanvasJSON {
    case object([String: CanvasJSON])
    case array([CanvasJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    static func parse(_ text: String) -> CanvasJSON? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [.allowFragments]))
            .map(CanvasJSON.wrap)
    }

    private static func wrap(_ value: Any) -> CanvasJSON {
        switch value {
        case let dict as [String: Any]:
            return .object(dict.mapValues(wrap))
        case let array as [Any]:
            return .array(array.map(wrap))
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            // JSONSerialization booleans are NSNumber too; tell them apart by CoreFoundation type.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        default:
            return .null
        }
    }

    var object: [String: CanvasJSON]? {
        if case .object(let dict) = self { return dict }
        return nil
    }

    var array: [CanvasJSON]? {
        if case .array(let items) = self { return items }
        return nil
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var double: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// The `contentOrNull` read: strings only, since these providers never want a number where
    /// a name should be.
    var content: String? { string }
}
