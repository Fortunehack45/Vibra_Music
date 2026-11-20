import Foundation

/// Enhanced ("A2") LRC — a normal LRC line with a stamp in front of each word:
///
///     [00:27.39]<00:27.39>I <00:27.54>been <00:27.74>tryna <00:28.07>call
///
/// This is what Musixmatch's rich sync becomes, and it is what SimpMusic serves. Only
/// starts are written down, so each word runs until the next one begins, and the last word
/// of a line until the next line does.
enum EnhancedLRC {
    private static let line = LyricsRegex(#"^\[([0-9]{1,3}):([0-9]{2})[.:]([0-9]{2,3})\](.*)$"#)
    private static let word = LyricsRegex(#"<([0-9]{1,3}):([0-9]{2})[.:]([0-9]{2,3})>([^<]*)"#)
    private static let tailMs = 800

    private struct Row {
        let timeMs: Int
        let words: [LyricsMatch]
        let plain: String
    }

    /// Empty when `lrc` carries no word stamps — the caller can then fall back.
    static func parse(_ lrc: String) -> [LyricLine] {
        let rows = lrc.kLines.compactMap { raw -> Row? in
            guard let match = line.matchEntire(raw.kTrimmed) else { return nil }
            return Row(
                timeMs: LRCFormat.milliseconds(match.groupValues[1], match.groupValues[2], match.groupValues[3]),
                words: word.allMatches(in: match.groupValues[4]),
                plain: match.groupValues[4].kTrimmed
            )
        }.kSortedBy(\.timeMs)
        // Nothing word-stamped in here: this is an ordinary LRC file and the caller is better
        // served parsing it as one.
        if !rows.contains(where: { !$0.words.isEmpty }) { return [] }

        return rows.enumerated().compactMap { index, row -> LyricLine? in
            if row.words.isEmpty {
                let text = decodeEntities(row.plain)
                return text.isEmpty ? nil : LyricLine(timeMs: row.timeMs, text: text)
            }
            // A word runs until the next one starts; the last runs until the next line does.
            // Without a next line — the closing word of the song — give it a beat rather than
            // zero, or its sweep never runs.
            let lineEnd = rows.kGet(index + 1)?.timeMs ?? (stamp(row.words[row.words.count - 1]) + tailMs)

            let words = row.words.enumerated().compactMap { i, match -> LyricWord? in
                let text = decodeEntities(match.groupValues[4]).kTrimmed
                if text.isEmpty { return nil }
                let start = stamp(match)
                let end = row.words.kGet(i + 1).map(stamp) ?? lineEnd
                return LyricWord(startMs: start, endMs: max(end, start), text: text)
            }
            guard let first = words.first else { return nil }
            return LyricLine(
                timeMs: min(row.timeMs, first.startMs),
                text: words.map(\.text).joined(separator: " "),
                words: words
            )
        }.withInstrumentalGaps()
    }

    private static func stamp(_ match: LyricsMatch) -> Int {
        LRCFormat.milliseconds(match.groupValues[1], match.groupValues[2], match.groupValues[3])
    }

    /// SimpMusic serves its rich sync HTML-escaped, so an apostrophe arrives as `&#x27;` and
    /// would be sung literally. Metrolist shipped that bug; this is the fix.
    ///
    /// iOS difference: a numeric reference beyond the BMP decodes to its real character
    /// (Kotlin's `Int.toChar()` truncated it to 16 bits).
    static func decodeEntities(_ text: String) -> String {
        if !text.contains("&") { return text }
        var out = hexReference.replacing(in: text) { match in
            UInt32(match.groupValues[1], radix: 16).flatMap(Unicode.Scalar.init).map { String($0) } ?? match.value
        }
        out = decimalReference.replacing(in: out) { match in
            UInt32(match.groupValues[1]).flatMap(Unicode.Scalar.init).map { String($0) } ?? match.value
        }
        return out
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            // Last, so "&amp;#x27;" doesn't decode twice into an apostrophe.
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static let hexReference = LyricsRegex("&#x([0-9a-fA-F]+);")
    private static let decimalReference = LyricsRegex("&#([0-9]+);")
}

/// QQ/QRC and NetEase YRC: millisecond line and word ranges (Android: `KaraokeLrc`).
enum KaraokeLRC {
    private static let line = LyricsRegex(#"^\[([0-9]{1,8}),([0-9]{1,8})\](.*)$"#)
    private static let prefixWord = LyricsRegex(#"\(([0-9]{1,8}),([0-9]{1,8})(?:,[0-9]{1,8})?\)([^()]*)"#)
    private static let suffixWord = LyricsRegex(#"([^()]*)\(([0-9]{1,8}),([0-9]{1,8})(?:,[0-9]{1,8})?\)"#)
    private static let wordTime = LyricsRegex(#"\([0-9]{1,8},[0-9]{1,8}(?:,[0-9]{1,8})?\)"#)
    private static let content = LyricsRegex(#"LyricContent[ \t\n\x0B\f\r]*=[ \t\n\x0B\f\r]*"([^"]*)""#, caseInsensitive: true)

    static func looksLike(_ raw: String) -> Bool {
        lyricContent(raw).kLines.contains { source in
            guard let body = line.matchEntire(source.kTrimmed)?.groupValues[3] else { return false }
            return prefixWord.containsMatch(in: body) || suffixWord.containsMatch(in: body)
        }
    }

    static func parse(_ raw: String) -> [LyricLine] {
        let rows = lyricContent(raw).kLines.compactMap { source -> LyricLine? in
            guard let match = line.matchEntire(source.kTrimmed) else { return nil }
            let lineStart = Int(match.groupValues[1]) ?? 0
            let lineDuration = Int(match.groupValues[2]) ?? 0
            let body = match.groupValues[3]
            let prefixed = prefixWord.allMatches(in: body).compactMap {
                timedWord($0.groupValues[3], start: $0.groupValues[1], duration: $0.groupValues[2])
            }
            let suffixed = suffixWord.allMatches(in: body).compactMap {
                timedWord($0.groupValues[1], start: $0.groupValues[2], duration: $0.groupValues[3])
            }
            let prefixedLength = prefixed.reduce(0) { $0 + $1.text.kLength }
            let suffixedLength = suffixed.reduce(0) { $0 + $1.text.kLength }
            let words = prefixedLength >= suffixedLength ? prefixed : suffixed
            guard let first = words.first else { return nil }
            return LyricLine(
                timeMs: min(lineStart, first.startMs),
                text: EnhancedLRC.decodeEntities(wordTime.replacing(in: body, with: "")).kTrimmed,
                words: words,
                sungUntilMs: lineDuration > 0 ? lineStart + lineDuration : nil
            )
        }.filter { !$0.text.isEmpty }.kSortedBy(\.timeMs)
        return rows.withInstrumentalGaps()
    }

    private static func timedWord(_ text: String, start: String, duration: String) -> LyricWord? {
        let clean = EnhancedLRC.decodeEntities(text).kTrimmed
        if clean.isEmpty { return nil }
        let startMs = Int(start) ?? 0
        return LyricWord(startMs: startMs, endMs: startMs + (Int(duration) ?? 0), text: clean)
    }

    private static func lyricContent(_ raw: String) -> String {
        guard let found = content.firstMatch(in: raw)?.groupValues[1] else { return raw }
        return found
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
