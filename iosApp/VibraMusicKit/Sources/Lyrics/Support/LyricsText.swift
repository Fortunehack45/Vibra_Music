import Foundation
import os

/// Logging for the whole module: subsystem `com.fortune.vibramusic.ios`, category `Lyrics`.
let lyricsLog = Logger(subsystem: "com.fortune.vibramusic.ios", category: "Lyrics")

// The Android code this module ports is Kotlin, and a good deal of its behaviour
// rests on what Kotlin's string functions do rather than on what Swift's
// equivalents happen to do. The helpers here pin those semantics down once so
// the parsers can be read side by side with their Kotlin originals.
//
// Offsets: Kotlin strings are UTF-16, and every character offset the lyric
// model exposes (`revealedChars`, `wordSpans`) is a UTF-16 offset for the same
// reason TextKit's are. `NSString` is used wherever an offset is involved.

/// What Kotlin's `Char.isWhitespace()` accepts: `Character.isWhitespace` or
/// `Character.isSpaceChar` — every Zs/Zl/Zp separator (non-breaking ones
/// included), the ASCII controls `\t \n \v \f \r` and the information separators
/// U+001C–U+001F. Deliberately not `CharacterSet.whitespacesAndNewlines`, which
/// adds U+0085 and misses the separators.
let kotlinWhitespace: CharacterSet = {
    var set = CharacterSet.whitespaces // Zs + tab
    set.insert(charactersIn: "\n\u{0B}\u{0C}\r\u{1C}\u{1D}\u{1E}\u{1F}\u{2028}\u{2029}")
    return set
}()

extension String {
    /// Kotlin's `trim()`.
    var kTrimmed: String { trimmingCharacters(in: kotlinWhitespace) }

    /// Kotlin's `trimStart()`.
    var kTrimmedStart: String {
        guard let index = unicodeScalars.firstIndex(where: { !kotlinWhitespace.contains($0) }) else { return "" }
        return String(unicodeScalars[index...])
    }

    /// Kotlin's `trimEnd()`.
    var kTrimmedEnd: String {
        guard let index = unicodeScalars.lastIndex(where: { !kotlinWhitespace.contains($0) }) else { return "" }
        return String(unicodeScalars[...index])
    }

    /// Kotlin's `isBlank()`: empty, or whitespace all the way through.
    var kIsBlank: Bool { unicodeScalars.allSatisfy { kotlinWhitespace.contains($0) } }

    /// Kotlin's `length`: UTF-16 code units.
    var kLength: Int { utf16.count }

    /// Kotlin's `lineSequence()` / `lines()`: split on `\r\n`, `\n` and `\r`, keeping
    /// empty lines (a trailing newline yields a trailing empty string).
    var kLines: [String] {
        replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    /// Kotlin's `indexOf(other, startIndex)` in UTF-16 offsets, or nil for -1. An empty
    /// needle is found at `startIndex` clamped to the length, as Java's `indexOf` answers.
    func kIndexOf(_ other: String, from start: Int) -> Int? {
        let ns = self as NSString
        let from = Swift.max(0, start)
        if other.isEmpty { return Swift.min(from, ns.length) }
        guard from < ns.length else { return nil }
        let found = ns.range(of: other, options: .literal, range: NSRange(location: from, length: ns.length - from))
        return found.location == NSNotFound ? nil : found.location
    }

    /// Kotlin's `substring(start, end)` in UTF-16 offsets.
    func kSubstring(_ start: Int, _ end: Int) -> String {
        (self as NSString).substring(with: NSRange(location: start, length: end - start))
    }

    /// Kotlin's `substring(start)` in UTF-16 offsets.
    func kSubstring(from start: Int) -> String {
        (self as NSString).substring(from: start)
    }

    /// Kotlin's `contains(other, ignoreCase)`. An empty needle is contained in everything,
    /// which `range(of:)` would otherwise answer the other way.
    func kContains(_ other: String, ignoreCase: Bool = false) -> Bool {
        if other.isEmpty { return true }
        return range(of: other, options: ignoreCase ? [.caseInsensitive, .literal] : .literal) != nil
    }

    /// Kotlin's `equals(other, ignoreCase = true)`.
    func kEqualsIgnoreCase(_ other: String) -> Bool {
        compare(other, options: [.caseInsensitive, .literal]) == .orderedSame
    }

    /// Kotlin's `substringBefore(delimiter)`: the whole string when the delimiter is absent.
    func kSubstringBefore(_ delimiter: String) -> String {
        guard let range = range(of: delimiter, options: .literal) else { return self }
        return String(self[..<range.lowerBound])
    }

    /// Kotlin's `substringAfter(delimiter, missing)`.
    func kSubstringAfter(_ delimiter: String, missing: String? = nil) -> String {
        guard let range = range(of: delimiter, options: .literal) else { return missing ?? self }
        return String(self[range.upperBound...])
    }

    /// Kotlin's `ifBlank { fallback }`.
    func kIfBlank(_ fallback: @autoclosure () -> String) -> String {
        kIsBlank ? fallback() : self
    }

    /// Kotlin's `removePrefix` / `removeSuffix`.
    func kRemovingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }

    func kRemovingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }

    /// Kotlin's `trimEnd(vararg chars)`.
    func kTrimmingEnd(_ characters: Set<Character>) -> String {
        var result = Substring(self)
        while let last = result.last, characters.contains(last) { result = result.dropLast() }
        return String(result)
    }
}

extension Unicode.Scalar {
    /// Kotlin's `Char.isWhitespace()`.
    var kIsWhitespace: Bool { kotlinWhitespace.contains(self) }

    /// Java's `Character.isLetter`: any `L*` general category.
    var kIsLetter: Bool {
        switch properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
    }

    /// Java's `Character.isLetterOrDigit`: a letter or an `Nd` decimal digit.
    var kIsLetterOrDigit: Bool { kIsLetter || properties.generalCategory == .decimalNumber }
}

extension Array {
    /// Kotlin's `getOrNull(index)`.
    func kGet(_ index: Int) -> Element? { indices.contains(index) ? self[index] : nil }

    /// Kotlin's `sortedBy`, which is stable: equal keys keep their input order.
    func kSortedBy<Key: Comparable>(_ key: (Element) -> Key) -> [Element] {
        enumerated()
            .sorted { lhs, rhs in
                let (left, right) = (key(lhs.element), key(rhs.element))
                return left != right ? left < right : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Kotlin's `maxByOrNull`: the first element with the largest key.
    func kMaxBy<Key: Comparable>(_ key: (Element) -> Key) -> Element? {
        var best: (Element, Key)?
        for element in self {
            let value = key(element)
            if let current = best, !(value > current.1) { continue }
            best = (element, value)
        }
        return best?.0
    }

    /// Kotlin's `minByOrNull`: the first element with the smallest key.
    func kMinBy<Key: Comparable>(_ key: (Element) -> Key) -> Element? {
        var best: (Element, Key)?
        for element in self {
            let value = key(element)
            if let current = best, !(value < current.1) { continue }
            best = (element, value)
        }
        return best?.0
    }
}

/// Kotlin's `coerceIn` for floating point.
@inline(__always)
func kClamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
    Swift.min(Swift.max(value, lower), upper)
}

/// Kotlin's `String.toDoubleOrNull()` for the plain decimal forms the lyric formats use.
func kDouble(_ text: String) -> Double? {
    let trimmed = text
    guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite else { return nil }
    return value
}

/// Kotlin's `Double.toLong()`: truncation toward zero, saturating at the bounds.
@inline(__always)
func kLong(_ value: Double) -> Int {
    if value.isNaN { return 0 }
    if value >= Double(Int.max) { return Int.max }
    if value <= Double(Int.min) { return Int.min }
    return Int(value)
}
