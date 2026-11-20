import VibraMusicCore
import Foundation

/// Web scraper for Genius.com lyrics.
///
/// Used strictly as a last-resort fallback when none of the time-synced providers have
/// lyrics for a track — `LyricsRepository` starts it lazily and only if every higher
/// priority source missed. Genius has no timestamps, but carries an immense catalogue:
///  1. Search Genius's open multi-search endpoint (no API key required).
///  2. Match the best candidate song and take its page URL.
///  3. Fetch the page HTML and pull the lyrics out of `data-lyrics-container` elements.
///  4. Clean out Genius's furniture (headers, translation links, "You might also like", "Embed").
///  5. Keep section headers ("[Verse 1]", "[Chorus]") for formatted display.
public struct GeniusProvider: LyricsProvider {
    /// What this says it is, which is deliberately not a browser.
    ///
    /// Genius sits behind Cloudflare, and Cloudflare challenges a browser-claiming
    /// User-Agent whose TLS fingerprint and `sec-ch-ua` headers do not back the claim:
    /// measured in September 2026, a Chrome UA is answered `403` with a bot-challenge page
    /// and a plain one `200`. And the cost of a 403 is invisible — it reads as "no lyrics".
    private static let userAgent = "Vibra Music"
    private static let deadline: TimeInterval = 8

    private let http: LyricsHTTP

    public init(session: URLSession = VibraMusicHTTP.session) {
        http = LyricsHTTP(session: session)
    }

    public func lyrics(for request: LyricsProviderRequest) async throws -> LyricsProviderAnswer? {
        await lyrics(title: request.title, artist: request.artist)?.answer
    }

    public func lyrics(title: String, artist: String) async -> [LyricLine]? {
        let songURL = await firstSongURL(for: Self.searchAttempts(title: title, artist: artist))
        guard let songURL, let html = await httpGet(songURL), !html.kIsBlank else { return nil }
        return Self.parseHTML(html)?.nonEmpty
    }

    private func firstSongURL(for attempts: [SearchAttempt]) async -> String? {
        for attempt in attempts {
            if let url = await searchSongURL(query: attempt.query, targetTitle: attempt.title, targetArtist: attempt.artist) {
                return url
            }
        }
        return nil
    }

    struct SearchAttempt: Equatable {
        let query: String
        let title: String
        let artist: String
    }

    /// The searches worth trying, most specific first, de-duplicated by query.
    static func searchAttempts(title: String, artist: String) -> [SearchAttempt] {
        let cleanTitle = cleanQuery(title)
        let cleanArtist = cleanQuery(artist)

        // If the title is in "Artist - Title" format, extract both parts.
        let titleParts: [String]? = titleSeparator.containsMatch(in: cleanTitle) ? splitOnce(cleanTitle) : nil

        let extractedTitle: String
        let extractedArtist: String
        if let parts = titleParts, parts[0].kTrimmed.kEqualsIgnoreCase(cleanArtist) {
            extractedTitle = parts[1].kTrimmed
        } else if let parts = titleParts, parts[1].kTrimmed.kEqualsIgnoreCase(cleanArtist) {
            extractedTitle = parts[0].kTrimmed
        } else if let parts = titleParts, !parts[0].kIsBlank, !parts[1].kIsBlank {
            extractedTitle = parts[1].kTrimmed
        } else {
            extractedTitle = cleanTitle
        }
        if let parts = titleParts,
           parts[0].kTrimmed.kEqualsIgnoreCase(cleanArtist) || parts[1].kTrimmed.kEqualsIgnoreCase(cleanArtist) {
            extractedArtist = cleanArtist
        } else if let parts = titleParts, cleanArtist.kIsBlank {
            extractedArtist = parts[0].kTrimmed
        } else {
            extractedArtist = cleanArtist
        }

        let titleWithoutBrackets = LyricsRegex(#"[ \t\n\x0B\f\r]+"#).replacing(
            in: nonAlphanumeric.replacing(in: bracketedContent.replacing(in: extractedTitle, with: " "), with: " "),
            with: " "
        ).kTrimmed

        var attempts = [SearchAttempt]()
        // 1. Extracted artist + extracted title.
        if !extractedArtist.kIsBlank && !extractedTitle.kIsBlank {
            attempts.append(SearchAttempt(query: (extractedArtist + " " + extractedTitle).kTrimmed, title: extractedTitle, artist: extractedArtist))
        }
        // 2. Extracted artist + title without brackets.
        if !extractedArtist.kIsBlank && !titleWithoutBrackets.kIsBlank && titleWithoutBrackets != extractedTitle {
            attempts.append(SearchAttempt(query: (extractedArtist + " " + titleWithoutBrackets).kTrimmed, title: titleWithoutBrackets, artist: extractedArtist))
        }
        // 3. Clean artist + clean title (in case the separator wasn't Artist - Title).
        if cleanTitle != extractedTitle {
            attempts.append(SearchAttempt(query: (cleanArtist + " " + cleanTitle).kTrimmed, title: cleanTitle, artist: cleanArtist))
            attempts.append(SearchAttempt(query: cleanTitle, title: extractedTitle, artist: extractedArtist))
        }
        // 4. Standalone extracted title without artist prefix.
        if !titleWithoutBrackets.kIsBlank {
            attempts.append(SearchAttempt(query: titleWithoutBrackets, title: titleWithoutBrackets, artist: extractedArtist))
        } else if !extractedTitle.kIsBlank {
            attempts.append(SearchAttempt(query: extractedTitle, title: extractedTitle, artist: extractedArtist))
        }

        var seen = Set<String>()
        return attempts.filter { seen.insert($0.query).inserted }
    }

    /// Kotlin's `split(TITLE_SEPARATOR, limit = 2)`.
    private static func splitOnce(_ value: String) -> [String] {
        guard let match = titleSeparator.firstMatch(in: value) else { return [value] }
        return [value.kSubstring(0, match.start), value.kSubstring(from: match.end)]
    }

    /// Searches Genius for the track and returns the song's page URL.
    func searchSongURL(title: String, artist: String) async -> String? {
        await searchSongURL(query: (artist + " " + title).kTrimmed, targetTitle: title, targetArtist: artist)
    }

    private func searchSongURL(query: String, targetTitle: String, targetArtist: String) async -> String? {
        guard let body = await httpGet("https://genius.com/api/search/multi?q=" + LyricsURL.formComponent(query)) else { return nil }
        return Self.songURL(inSearch: body, targetTitle: targetTitle, targetArtist: targetArtist)
    }

    static func songURL(inSearch body: String, targetTitle: String, targetArtist: String) -> String? {
        guard let sections = LyricsJSON.parse(body)?["response"]?["sections"]?.array,
              let songs = sections.first(where: { $0["type"]?.content == "song" }),
              let hits = songs["hits"]?.array
        else { return nil }
        let candidates = hits.compactMap { $0["result"]?.object }
        return bestMatch(candidates, targetTitle: targetTitle, targetArtist: targetArtist)?["url"]?.content
    }

    private static func bestMatch(_ candidates: [LyricsJSONObject], targetTitle: String, targetArtist: String) -> LyricsJSONObject? {
        let wantedTitle = targetTitle.lowercased()
        let wantedArtist = targetArtist.lowercased()
        let scored = candidates.compactMap { item -> (LyricsJSONObject, Int)? in
            let title = item["title"]?.content?.lowercased() ?? ""
            let artist = item["artist_names"]?.content?.lowercased() ?? ""
            let titleMatches = !wantedTitle.kIsBlank
                && (title == wantedTitle || title.kContains(wantedTitle) || wantedTitle.kContains(title))
            let artistMatches = !wantedArtist.kIsBlank
                && (artist == wantedArtist || artist.kContains(wantedArtist) || wantedArtist.kContains(artist))
            if !titleMatches && !artistMatches { return nil }

            var score = 0
            if title == wantedTitle { score += 50 } else if titleMatches { score += 25 }
            if artistMatches { score += artist == wantedArtist ? 40 : 20 }

            // Penalise translations / instrumentals / reviews unless specifically requested.
            let path = item["path"]?.content ?? ""
            if path.kContains("translation", ignoreCase: true) && !wantedTitle.kContains("translation") { score -= 30 }
            if path.kContains("türkçe", ignoreCase: true) || path.kContains("polskie-tlumaczenie", ignoreCase: true) { score -= 40 }
            if path.kContains("tracklist", ignoreCase: true) || path.kContains("album-art", ignoreCase: true) { score -= 50 }
            return score > 0 ? (item, score) : nil
        }
        return scored.kMaxBy(\.1)?.0
    }

    /// Extracts the lyrics from a Genius song page, keeping stanzas and section headers.
    static func parseHTML(_ html: String) -> [LyricLine]? {
        let document = LyricsHTMLNode.parse(html)
        // Modern Genius uses data-lyrics-container="true", older pages use div.lyrics.
        var containers = document.select { $0.tagName == "div" && $0.attribute("data-lyrics-container", equals: "true") }
        if containers.isEmpty { containers = document.select { $0.tagName == "div" && $0.hasClass("lyrics") } }
        if containers.isEmpty { return nil }

        var fullText = ""
        for container in containers {
            // Remove headers, contributors, translation links, buttons, ads.
            container.select { element in
                element.attribute("data-exclude-from-selection", equals: "true")
                    || element.hasClass("LyricsHeader__Container")
                    || element.hasClass("SongBioPreview__Container")
                    || element.hasClass("InreadAd__Container")
                    || ["button", "script", "style"].contains(element.tagName ?? "")
            }.forEach { $0.remove() }

            // Turn <br> into explicit newlines before extracting text.
            container.select { $0.tagName == "br" }.forEach { $0.replace(with: LyricsHTMLNode(.text("\n"))) }
            container.select { $0.tagName == "p" }.forEach { $0.prepend(LyricsHTMLNode(.text("\n"))) }

            let text = container.wholeText
            if !text.kIsBlank { fullText += text + "\n" }
        }
        if fullText.kIsBlank { return nil }
        return textToLyricLines(stripArtifacts(fullText)).nonEmpty
    }

    /// Cleans common scraper artifacts found on Genius: "You might also like" insertions,
    /// a trailing "Embed" or "123Embed", and non-breaking or zero-width spaces.
    static func stripArtifacts(_ raw: String) -> String {
        let spaced = raw
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: " ")
            .replacingOccurrences(of: "\u{FEFF}", with: " ")
        return trailingEmbed.replacing(in: youMightAlsoLike.replacing(in: spaced, with: "").kTrimmed, with: "").kTrimmed
    }

    /// Clean multi-line lyrics text as unsynced lines (all at 0), one gap between stanzas.
    static func textToLyricLines(_ text: String) -> [LyricLine] {
        var result = [LyricLine]()
        var lastWasGap = false
        for raw in text.kLines {
            let line = trailingEmbed.replacing(in: raw.kTrimmed, with: "").kTrimmed
            if line.isEmpty {
                if !lastWasGap && !result.isEmpty {
                    result.append(LyricLine(timeMs: 0, text: ""))
                    lastWasGap = true
                }
            } else {
                result.append(LyricLine(timeMs: 0, text: line))
                lastWasGap = false
            }
        }
        // Drop leading and trailing gaps.
        while result.first?.isGap == true { result.removeFirst() }
        while result.last?.isGap == true { result.removeLast() }
        return result
    }

    /// Whether a line is a section header like "[Verse 1]", "[Chorus]", "[Bridge]".
    public static func isSectionHeader(_ text: String) -> Bool {
        let trimmed = text.kTrimmed
        return trimmed.hasPrefix("[") && trimmed.hasSuffix("]") && (3...60).contains(trimmed.kLength)
    }

    static func cleanQuery(_ text: String) -> String {
        var cleaned = decorativeChars.replacing(in: text, with: " ")
        cleaned = noise.replacing(in: cleaned, with: " ")
        cleaned = producerTags.replacing(in: cleaned, with: " ")
        cleaned = LyricsRegex(#"[ \t\n\x0B\f\r]+"#).replacing(in: cleaned.kSubstringBefore(" | "), with: " ").kTrimmed
        return cleaned.kIsBlank ? text.kTrimmed : cleaned
    }

    private func httpGet(_ url: String) async -> String? {
        await http.get(
            URL(string: url),
            headers: [
                "User-Agent": Self.userAgent,
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,application/json,*/*;q=0.8",
                "Accept-Language": "en-US,en;q=0.9",
            ],
            deadline: Self.deadline
        )
    }

    private static let titleSeparator = LyricsRegex(javaSpace + "*[-–—:]" + javaSpace + "*")
    private static let decorativeChars = LyricsRegex(#"[♪♫★☆【】《》「」~_]"#)
    private static let producerTags = LyricsRegex(#"(?i)\b(?:prod(?:uced)?\.?(?:"# + javaSpace + #"+by)?)"# + javaSpace + "+.*$")
    private static let noise = LyricsRegex(
        javaSpace + #"*[(\[]"# + javaSpace
            + #"*(?:from|feat\.?|ft\.?|featuring|with|prod\.?|produced by|official|lyrical|video|audio|remix|music video|visualizer|mv|hd|4k|hq|full song)[^)\]]*[)\]]|"#
            + javaSpace + #"*\b(?:official"# + javaSpace + #"+(?:music"# + javaSpace + #"+)?(?:video|audio)|lyrical(?:"#
            + javaSpace + #"+video)?|full"# + javaSpace + #"+song|4k"# + javaSpace + #"+video|hd"# + javaSpace
            + #"+video|music"# + javaSpace + #"+video)\b"#,
        caseInsensitive: true
    )
    private static let bracketedContent = LyricsRegex(javaSpace + #"*[\(\[].*?[\)\]]"#)
    private static let nonAlphanumeric = LyricsRegex(#"[^\p{L}\p{N} \t\n\x0B\f\r]"#)
    private static let youMightAlsoLike = LyricsRegex(#"[0-9]*You might also like"#, caseInsensitive: true)
    private static let trailingEmbed = LyricsRegex(#"[0-9]*Embed[ \t\n\x0B\f\r]*$"#, caseInsensitive: true)
}
