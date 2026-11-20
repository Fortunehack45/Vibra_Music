import Foundation

/// One match, shaped like Kotlin's `MatchResult`: `groupValues[0]` is the whole match and a
/// group that did not take part is `""`. Ranges are UTF-16 offsets into the input.
struct LyricsMatch {
    let groupValues: [String]
    let range: NSRange

    var value: String { groupValues[0] }
    /// Kotlin's `range.first` / `range.last + 1`.
    var start: Int { range.location }
    var end: Int { range.location + range.length }
}

/// A compiled pattern with Kotlin `Regex` semantics on top of `NSRegularExpression`.
///
/// The patterns ported from the Android code avoid the two places ICU and Java disagree:
/// `\d` and `\s` are Unicode-aware in ICU and ASCII-only in Java, so the ports spell them
/// `[0-9]` and `[ \t\n\x0B\f\r]` where the difference could matter.
struct LyricsRegex: @unchecked Sendable {
    private let regex: NSRegularExpression
    /// `\A(?:pattern)\z`, for Kotlin's `matchEntire`/`matches`, which require the *whole*
    /// input to match — an anchored first match can stop short where a longer one exists.
    private let entire: NSRegularExpression

    init(_ pattern: String, caseInsensitive: Bool = false, dotMatchesLineSeparators: Bool = false) {
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        if dotMatchesLineSeparators { options.insert(.dotMatchesLineSeparators) }
        do {
            regex = try NSRegularExpression(pattern: pattern, options: options)
            entire = try NSRegularExpression(pattern: "\\A(?:" + pattern + ")\\z", options: options)
        } catch {
            // Every pattern here is a literal in this module; one that does not compile is a
            // programming error caught by the first test that touches it.
            preconditionFailure("Invalid lyrics pattern \(pattern): \(error)")
        }
    }

    private static func fullRange(_ string: String) -> NSRange {
        NSRange(location: 0, length: (string as NSString).length)
    }

    private static func match(_ result: NSTextCheckingResult, in string: String) -> LyricsMatch {
        let ns = string as NSString
        let groups = (0..<result.numberOfRanges).map { index -> String in
            let range = result.range(at: index)
            return range.location == NSNotFound ? "" : ns.substring(with: range)
        }
        return LyricsMatch(groupValues: groups, range: result.range)
    }

    /// Kotlin's `find`.
    func firstMatch(in string: String, from start: Int = 0) -> LyricsMatch? {
        let length = (string as NSString).length
        guard start <= length else { return nil }
        let range = NSRange(location: start, length: length - start)
        return regex.firstMatch(in: string, range: range).map { Self.match($0, in: string) }
    }

    /// Kotlin's `findAll`.
    func allMatches(in string: String) -> [LyricsMatch] {
        regex.matches(in: string, range: Self.fullRange(string)).map { Self.match($0, in: string) }
    }

    /// Kotlin's `matchEntire`.
    func matchEntire(_ string: String) -> LyricsMatch? {
        entire.firstMatch(in: string, range: Self.fullRange(string)).map { Self.match($0, in: string) }
    }

    /// Kotlin's `matches`.
    func matches(_ string: String) -> Bool { matchEntire(string) != nil }

    /// Kotlin's `containsMatchIn`.
    func containsMatch(in string: String) -> Bool {
        regex.firstMatch(in: string, range: Self.fullRange(string)) != nil
    }

    /// Kotlin's `replace(input, literal)`.
    func replacing(in string: String, with replacement: String) -> String {
        regex.stringByReplacingMatches(
            in: string,
            range: Self.fullRange(string),
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
        )
    }

    /// Kotlin's `replace(input) { transform }`.
    func replacing(in string: String, transform: (LyricsMatch) -> String) -> String {
        let ns = string as NSString
        var out = ""
        var cursor = 0
        for result in regex.matches(in: string, range: Self.fullRange(string)) {
            let match = Self.match(result, in: string)
            out += ns.substring(with: NSRange(location: cursor, length: match.start - cursor))
            out += transform(match)
            cursor = match.end
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// Kotlin's `split(input)`, which — unlike Java's — keeps trailing empty strings.
    func split(_ string: String) -> [String] {
        let ns = string as NSString
        var parts: [String] = []
        var cursor = 0
        for result in regex.matches(in: string, range: Self.fullRange(string)) {
            parts.append(ns.substring(with: NSRange(location: cursor, length: result.range.location - cursor)))
            cursor = result.range.location + result.range.length
        }
        parts.append(ns.substring(from: cursor))
        return parts
    }

    /// How many times the pattern occurs.
    func count(in string: String) -> Int {
        regex.numberOfMatches(in: string, range: Self.fullRange(string))
    }
}
