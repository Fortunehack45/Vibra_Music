import Foundation

// Small text helpers the parser and client share. Kept internal: they mirror Kotlin stdlib calls
// (`isBlank`, `split`, `Regex.matches`) closely enough that the ported code reads the same.

/// A compiled pattern with Kotlin's two ways of asking: `matches` (the whole string) and
/// `containsMatchIn` (anywhere).
struct TextPattern: @unchecked Sendable {
    // NSRegularExpression is immutable and documented thread-safe; Swift's Regex is not Sendable.
    private let whole: NSRegularExpression
    private let anywhere: NSRegularExpression

    init(_ pattern: String, caseInsensitive: Bool = false) {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        // The patterns are literals in this module; a typo is a programming error caught by tests.
        whole = try! NSRegularExpression(pattern: "^(?:\(pattern))\\z", options: options)
        anywhere = try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// Kotlin's `String.matches(Regex)`: the entire string matches.
    func matches(_ text: String) -> Bool {
        whole.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Kotlin's `Regex.containsMatchIn`.
    func containsMatch(in text: String) -> Bool {
        anywhere.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The first capture group of the first match, like `find(text)?.groupValues?.get(1)`.
    func firstGroup(in text: String) -> String? {
        guard let match = anywhere.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// The first match's text.
    func firstMatch(in text: String) -> String? {
        guard let match = anywhere.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }
}

extension String {
    /// Kotlin's `isBlank()`: empty or whitespace only.
    var isBlankText: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Kotlin's `trim()`.
    var trimmedText: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Kotlin's `split(delimiter)` (empty pieces kept).
    func splitText(_ delimiter: String) -> [String] {
        components(separatedBy: delimiter)
    }

    /// Kotlin's `split(a, b, …)`: at each position the first delimiter (in argument order) that
    /// matches ends a piece.
    func splitText(anyOf delimiters: [String]) -> [String] {
        var pieces: [String] = []
        var current = ""
        var index = startIndex
        outer: while index < endIndex {
            for delimiter in delimiters where !delimiter.isEmpty && self[index...].hasPrefix(delimiter) {
                pieces.append(current)
                current = ""
                index = self.index(index, offsetBy: delimiter.count)
                continue outer
            }
            current.append(self[index])
            index = self.index(after: index)
        }
        pieces.append(current)
        return pieces
    }

    /// Kotlin's `substringAfter(delimiter, missing)`.
    func substring(after delimiter: String, missing: String) -> String {
        guard let range = range(of: delimiter) else { return missing }
        return String(self[range.upperBound...])
    }

    /// Kotlin's `substringBefore(delimiter)` (the whole string when absent).
    func substring(before delimiter: String) -> String {
        guard let range = range(of: delimiter) else { return self }
        return String(self[..<range.lowerBound])
    }

    /// Kotlin's `removePrefix`.
    func removingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}

extension Sequence {
    /// Kotlin's `distinctBy`: keeps the first element for each key, in order.
    func distinct<Key: Hashable>(by key: (Element) -> Key) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert(key($0)).inserted }
    }
}

extension Sequence where Element: Hashable {
    /// Kotlin's `distinct()`.
    func distinctElements() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
