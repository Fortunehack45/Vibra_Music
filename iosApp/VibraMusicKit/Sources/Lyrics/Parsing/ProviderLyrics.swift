import Foundation

/// Turns the wire formats used by the smaller providers into lyric lines: Apple TTML,
/// QQ/NetEase karaoke, enhanced or plain LRC, or plain text — possibly wrapped in one or
/// two JSON envelopes (Android: `ProviderLyrics.kt`).
enum ProviderLyrics {

    static func parse(_ raw: String) -> [LyricLine]? {
        guard let unwrapped = unwrap(raw) else { return nil }
        let content = unescapeTTML(unwrapped)
        let lines: [LyricLine]
        if ttmlRoot.containsMatch(in: content) || content.kContains("http://www.w3.org/ns/ttml", ignoreCase: true) {
            lines = TTMLLyrics.parse(content)
        } else if KaraokeLRC.looksLike(content) {
            lines = KaraokeLRC.parse(content)
        } else if content.kTrimmedStart.hasPrefix("<") {
            lines = []
        } else {
            var parsed = EnhancedLRC.parse(content)
            if parsed.isEmpty { parsed = LRCFormat.parse(content) }
            if parsed.isEmpty { parsed = plain(content) }
            lines = parsed
        }
        return lines.contains(where: { !$0.text.kIsBlank }) ? lines : nil
    }

    private static func plain(_ content: String) -> [LyricLine] {
        if errorText.containsMatch(in: content) { return [] }
        return content.kLines.map(\.kTrimmed).filter { !$0.isEmpty }
            .filter { !metadataTag.matches($0) }
            .map { LyricLine(timeMs: 0, text: $0) }
    }

    /// Providers sometimes wrap the same lyric string in one or two JSON envelopes.
    static func unwrap(_ raw: String) -> String? {
        var value = raw.replacingOccurrences(of: "\u{FEFF}", with: "").kTrimmed
        if value.hasPrefix("```") {
            var rows = Array(value.kLines.dropFirst())
            if rows.last?.kTrimmed == "```" { rows.removeLast() }
            value = rows.joined(separator: "\n").kTrimmed
        }
        if value.kIsBlank { return nil }
        guard let json = LyricsJSON.parse(value) else { return value }
        guard let extracted = extract(json)?.kTrimmed, !extracted.isEmpty else { return nil }
        return extracted
    }

    private static func extract(_ element: LyricsJSON) -> String? {
        switch element {
        case .null:
            return nil
        case .string(let content):
            let text = content.kTrimmed
            if let nested = LyricsJSON.parse(text), !nested.isPrimitive { return extract(nested) }
            return text
        case .number, .bool:
            return nil
        case .array(let values):
            let joined = values.compactMap(extract).joined(separator: "\n")
            return joined.kIsBlank ? nil : joined
        case .object(let object):
            if object["isError"]?.serialized == "true" || object["ok"]?.serialized == "false" { return nil }
            if let error = object["error"], !error.isNull, !["false", "\"\""].contains(error.serialized) { return nil }
            for key in contentKeys {
                if let found = object[key].flatMap(extract) { return found }
            }
            if let metadata = object["metadata"], metadata.object != nil, let found = extract(metadata) { return found }
            return object["words"].flatMap(extract)
        }
    }

    private static func unescapeTTML(_ value: String) -> String {
        guard value.kContains("&lt;tt", ignoreCase: true) else { return value }
        return value
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static let contentKeys = [
        "ttml", "ttmlContent", "lyrics", "lrc", "content", "text",
        "plainLyrics", "syncedLyrics", "line", "lines", "lyric",
        "data", "result", "response",
    ]

    private static let ttmlRoot = LyricsRegex(#"<tt(?:[ \t\n\x0B\f\r]|>)"#, caseInsensitive: true)
    private static let errorText = LyricsRegex(#"\b(?:lyrics? (?:not found|unavailable)|error)\b"#, caseInsensitive: true)
    private static let metadataTag = LyricsRegex(#"\[[A-Za-z]+:.*\]"#)
}
