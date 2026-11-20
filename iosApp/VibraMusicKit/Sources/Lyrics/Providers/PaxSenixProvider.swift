import VibraMusicCore
import Foundation
import os

/// Public Apple lyrics plus optional authenticated Spotify and Musixmatch routes.
///
/// The keyless route finds the track in Apple Music's own catalogue — with the web
/// player's public token, scraped from its JavaScript — and asks lyrics.paxsenix.org for
/// that id's TTML. The two authenticated routes go to api.paxsenix.org with a user-issued
/// key (Settings → PaxSenix API key) and fall back to its general LRC search.
public final class PaxSenixProvider: Sendable {
    private static let api = "https://api.paxsenix.org"
    private static let publicProxy = "https://lyrics.paxsenix.org"
    private static let appleSearch = "https://amp-api.music.apple.com/v1/catalog/us/search"
    private static let minimumMatchScore = 10

    private let http: LyricsHTTP
    private let appleToken = AppleToken()
    private let apiKey = OSAllocatedUnfairLock(initialState: "")

    public init(session: URLSession = VibraMusicHTTP.session) {
        http = LyricsHTTP(session: session)
    }

    /// The api.paxsenix.org credential; a "Bearer " prefix is accepted and dropped.
    public func setAPIKey(_ value: String) {
        let normalized = Self.normalizeAPIKey(value)
        apiKey.withLock { $0 = normalized }
    }

    static func normalizeAPIKey(_ value: String) -> String {
        let trimmed = value.kTrimmed
        if trimmed.lowercased().hasPrefix("bearer ") {
            return trimmed.kSubstringAfter(" ").kTrimmed
        }
        return trimmed
    }

    // MARK: Routes

    /// The original keyless Apple Music provider.
    public func lyrics(title: String, artist: String, durationMs: Int, album: String? = nil) async -> [LyricLine]? {
        guard let id = await searchPublicAppleTrackID(title: title, artist: artist, durationMs: durationMs) else { return nil }
        let url = LyricsURL.make(Self.publicProxy + "/apple-music/lyrics", [("id", id), ("ttml", "true")])
        return await http.get(url).flatMap(Self.parseResponse)
    }

    public func spotifyLyrics(title: String, artist: String, durationMs: Int) async -> [LyricLine]? {
        if let id = await searchTrackID(path: "spotify/search", title: title, artist: artist, durationMs: durationMs),
           let lines = await apiBody(LyricsURL.make(Self.api + "/lyrics/spotify", [("id", id)])).flatMap(Self.parseResponse) {
            return lines
        }
        return await genericAuthenticatedLyrics(title: title, artist: artist, durationMs: durationMs)
    }

    public func musixmatchLyrics(title: String, artist: String, durationMs: Int) async -> [LyricLine]? {
        let url = LyricsURL.make(Self.api + "/lyrics/musixmatch", [
            ("t", title), ("a", artist), ("d", String(durationMs / 1000)),
        ])
        if let lines = await apiBody(url).flatMap(Self.parseResponse) { return lines }
        return await genericAuthenticatedLyrics(title: title, artist: artist, durationMs: durationMs)
    }

    private func searchPublicAppleTrackID(title: String, artist: String, durationMs: Int) async -> String? {
        guard let token = await appleToken.value(fetch: { await self.scrapeAppleToken() }) else { return nil }
        let url = LyricsURL.make(Self.appleSearch, [
            ("term", title + " " + artist), ("types", "songs"), ("limit", "10"), ("l", "en-US"),
        ])
        guard let root = await http.getAuthorized(url, bearer: token).flatMap(LyricsJSON.parse) else { return nil }
        return Self.bestCandidate(root, title: title, artist: artist, durationMs: durationMs)?.id
    }

    private func scrapeAppleToken() async -> String? {
        guard let page = await http.get(URL(string: "https://music.apple.com/us/new")),
              let scriptPath = Self.appleIndexScript.firstMatch(in: page)?.value,
              let script = await http.get(URL(string: "https://music.apple.com" + scriptPath))
        else { return nil }
        return Self.appleTokenPattern.firstMatch(in: script)?.value
    }

    private func searchTrackID(path: String, title: String, artist: String, durationMs: Int) async -> String? {
        let url = LyricsURL.make(Self.api + "/" + path, [("q", title + " " + artist)])
        guard let root = await apiBody(url).flatMap(LyricsJSON.parse) else { return nil }
        return Self.bestCandidate(root, title: title, artist: artist, durationMs: durationMs)?.id
    }

    private func genericAuthenticatedLyrics(title: String, artist: String, durationMs: Int) async -> [LyricLine]? {
        let url = LyricsURL.make(Self.api + "/lyrics/lrcget", [("q", title + " " + artist)])
        return await apiBody(url).flatMap { Self.parseLrcGet($0, title: title, artist: artist, durationMs: durationMs) }
    }

    private func apiBody(_ url: URL?) async -> String? {
        let key = apiKey.withLock { $0 }
        guard !key.kIsBlank else { return nil }
        return await http.getBearer(url, bearer: key)
    }

    // MARK: Parsing

    /// The general endpoint returns search candidates, not lyric lines. Parsing its array as
    /// one document concatenates every candidate and makes each song's timestamps restart at
    /// zero, which appears as repeated lines that cannot stay in sync. Select one recording
    /// before parsing its lyrics.
    static func parseLrcGet(_ raw: String, title: String, artist: String, durationMs: Int) -> [LyricLine]? {
        guard let root = LyricsJSON.parse(raw) else { return nil }
        let documents = root.object?["lyrics"]?.array ?? []
        if documents.isEmpty { return parseResponse(raw) }

        struct Parsed {
            let lines: [LyricLine]
            let metadataScore: Int
            let durationDistanceMs: Int
        }
        let parsed = documents.compactMap { document -> Parsed? in
            guard let lines = parseResponse(document.serialized) else { return nil }
            let metadataScore = document.object.map { lyricCandidateScore($0, title: title, artist: artist, durationMs: durationMs) } ?? 0
            return Parsed(lines: lines, metadataScore: metadataScore, durationDistanceMs: durationDistance(lines, durationMs: durationMs))
        }
        // compareBy(metadataScore).thenBy(-distance).thenBy(timed count).thenBy(word-synced count); first max wins.
        func key(_ entry: Parsed) -> [Int] {
            [
                entry.metadataScore,
                -entry.durationDistanceMs,
                entry.lines.filter { $0.timeMs > 0 }.count,
                entry.lines.filter(\.isWordSynced).count,
            ]
        }
        var best: Parsed?
        for entry in parsed {
            guard let current = best else {
                best = entry
                continue
            }
            if key(current).lexicographicallyPrecedes(key(entry)) { best = entry }
        }
        return best?.lines
    }

    private static func durationDistance(_ lines: [LyricLine], durationMs: Int) -> Int {
        if durationMs <= 0 { return 0 }
        let last = lines.map { line in
            max(line.timeMs, line.sungUntilMs ?? 0, line.words.map(\.endMs).max() ?? 0)
        }.max()
        guard let last else { return Int.max }
        return abs(last - durationMs)
    }

    private static func lyricCandidateScore(_ object: LyricsJSONObject, title: String, artist: String, durationMs: Int) -> Int {
        let details = object["attributes"]?.object ?? object
        let candidate = Candidate(
            id: firstString(object, idKeys) ?? "",
            title: firstString(details, titleKeys) ?? "",
            artist: firstString(details, artistKeys) ?? artistNames(details) ?? "",
            durationMs: toDurationMs(firstLong(details, durationKeys))
        )
        return candidate.score(title: title, artist: artist, durationMs: durationMs)
    }

    struct Candidate: Equatable {
        let id: String
        let title: String
        let artist: String
        let durationMs: Int

        func score(title wantedTitle: String, artist wantedArtist: String, durationMs wantedDuration: Int) -> Int {
            var score = PaxSenixProvider.textScore(title, wantedTitle, exact: 20, partial: 10)
                + PaxSenixProvider.textScore(artist, wantedArtist, exact: 15, partial: 5)
            if wantedDuration > 0 && durationMs > 0 {
                let difference = abs(durationMs - wantedDuration)
                score += difference < 3_000 ? 10 : difference < 10_000 ? 5 : 0
            }
            return score
        }
    }

    static func bestCandidate(_ root: LyricsJSON, title: String, artist: String, durationMs: Int) -> Candidate? {
        var candidates = [Candidate]()
        collectCandidates(root, into: &candidates)
        let best = candidates.map { ($0, $0.score(title: title, artist: artist, durationMs: durationMs)) }.kMaxBy(\.1)
        guard let best, best.1 >= minimumMatchScore else { return nil }
        return best.0
    }

    private static func collectCandidates(_ element: LyricsJSON, into candidates: inout [Candidate]) {
        switch element {
        case .array(let values):
            values.forEach { collectCandidates($0, into: &candidates) }
        case .object(let object):
            if let candidate = toCandidate(object) { candidates.append(candidate) }
            object.values.forEach { collectCandidates($0, into: &candidates) }
        default:
            break
        }
    }

    private static func toCandidate(_ object: LyricsJSONObject) -> Candidate? {
        let details = object["attributes"]?.object ?? object
        guard let id = firstString(object, idKeys) ?? firstString(details, idKeys),
              let title = firstString(details, titleKeys)
        else { return nil }
        let artist = firstString(details, artistKeys) ?? artistNames(details) ?? ""
        return Candidate(id: id, title: title, artist: artist, durationMs: toDurationMs(firstLong(details, durationKeys)))
    }

    private static func artistNames(_ object: LyricsJSONObject) -> String? {
        guard let artists = object["artists"] ?? object["artist"] else { return nil }
        switch artists {
        case .object(let single):
            return firstString(single, ["name", "artistName", "title"])
        case .array(let values):
            let names = values.compactMap { value -> String? in
                switch value {
                case .object(let entry): firstString(entry, ["name", "artistName", "title"])
                case .array: nil
                default: value.content
                }
            }.joined(separator: ", ")
            return names.isEmpty ? nil : names
        default:
            return artists.content
        }
    }

    private static func firstString(_ object: LyricsJSONObject, _ keys: [String]) -> String? {
        for key in keys {
            if let value = object[key], value.isPrimitive, let text = value.content?.kTrimmed, !text.isEmpty { return text }
        }
        return nil
    }

    private static func firstLong(_ object: LyricsJSONObject, _ keys: [String]) -> Int? {
        for key in keys {
            if let value = object[key], value.isPrimitive, let long = value.long { return long }
        }
        return nil
    }

    /// Seconds (anything under 10 000) become milliseconds.
    private static func toDurationMs(_ value: Int?) -> Int {
        guard let value, value > 0 else { return 0 }
        return value < 10_000 ? value * 1000 : value
    }

    static func textScore(_ candidate: String, _ wanted: String, exact: Int, partial: Int) -> Int {
        if candidate.kIsBlank || wanted.kIsBlank { return 0 }
        if candidate.kEqualsIgnoreCase(wanted) { return exact }
        if candidate.kContains(wanted, ignoreCase: true) || wanted.kContains(candidate, ignoreCase: true) { return partial }
        return 0
    }

    static func parseResponse(_ raw: String) -> [LyricLine]? {
        parseTimedApple(raw) ?? ProviderLyrics.parse(raw)
    }

    /// Preserve word timestamps when PaxSenix returns its structured Apple payload.
    static func parseTimedApple(_ raw: String) -> [LyricLine]? {
        guard let root = LyricsJSON.parse(raw), let content = findTimedContent(root) else { return nil }
        let rows = content.compactMap(\.object)
        let lines = rows.enumerated().compactMap { index, row -> LyricLine? in
            guard let start = row["timestamp"]?.primitiveLong, let wordRows = row["text"]?.array else { return nil }
            let texts = wordRows.compactMap { $0.object?["text"]?.primitiveContent }
            if texts.isEmpty { return nil }
            let nextLine = rows.kGet(index + 1)?["timestamp"]?.primitiveLong
            let timed = wordRows.enumerated().compactMap { wordIndex, element -> LyricWord? in
                guard let word = element.object,
                      let text = word["text"]?.primitiveContent?.kTrimmed, !text.isEmpty,
                      let wordStart = word["timestamp"]?.primitiveLong
                else { return nil }
                let wordEnd = wordRows.kGet(wordIndex + 1)?.object?["timestamp"]?.primitiveLong ?? nextLine ?? wordStart + 800
                return LyricWord(startMs: wordStart, endMs: max(wordEnd, wordStart), text: text)
            }
            return LyricLine(
                timeMs: min(start, timed.first?.startMs ?? start),
                text: texts.map(\.kTrimmed).joined(separator: " "),
                words: timed.count == texts.count ? timed : [],
                sungUntilMs: nextLine
            )
        }
        let withGaps = lines.withInstrumentalGaps()
        return withGaps.contains(where: { !$0.text.kIsBlank }) ? withGaps : nil
    }

    private static func findTimedContent(_ element: LyricsJSON) -> [LyricsJSON]? {
        switch element {
        case .object(let object):
            if let content = object["content"]?.array, content.contains(where: { $0.object?["timestamp"] != nil }) {
                return content
            }
            for value in object.values {
                if let found = findTimedContent(value) { return found }
            }
            return nil
        case .array(let values):
            for value in values {
                if let found = findTimedContent(value) { return found }
            }
            return nil
        default:
            return nil
        }
    }

    private static let idKeys = ["id", "trackId", "track_id", "realId"]
    private static let titleKeys = ["name", "title", "trackName", "track_name"]
    private static let artistKeys = ["artistName", "artist_name"]
    private static let durationKeys = ["durationInMillis", "durationMs", "duration_ms", "duration"]

    private static let appleIndexScript = LyricsRegex(#"/assets/index~[^"]+\.js"#)
    private static let appleTokenPattern = LyricsRegex(#"eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#)

    /// Apple's public web-player token, fetched once and shared by concurrent lookups.
    private actor AppleToken {
        private var cached: String?
        private var pending: Task<String?, Never>?

        func value(fetch: @escaping @Sendable () async -> String?) async -> String? {
            if let cached { return cached }
            let task = pending ?? Task { await fetch() }
            pending = task
            let value = await task.value
            pending = nil
            if let value { cached = value }
            return value
        }
    }
}

extension LyricsJSON {
    /// `(this as? JsonPrimitive)?.longOrNull`.
    fileprivate var primitiveLong: Int? { isPrimitive ? long : nil }
    /// `(this as? JsonPrimitive)?.contentOrNull`.
    fileprivate var primitiveContent: String? { isPrimitive ? content : nil }
}

/// The keyless Apple route as a `LyricsProvider` (`LyricsSource.paxSenix`).
struct PaxSenixAppleRoute: LyricsProvider {
    let provider: PaxSenixProvider
    func lyrics(for request: LyricsProviderRequest) async throws -> LyricsProviderAnswer? {
        await provider.lyrics(title: request.title, artist: request.artist, durationMs: request.durationMs, album: request.album)?.answer
    }
}

/// `LyricsSource.paxSenixSpotify`.
struct PaxSenixSpotifyRoute: LyricsProvider {
    let provider: PaxSenixProvider
    func lyrics(for request: LyricsProviderRequest) async throws -> LyricsProviderAnswer? {
        await provider.spotifyLyrics(title: request.title, artist: request.artist, durationMs: request.durationMs)?.answer
    }
}

/// `LyricsSource.paxSenixMusixmatch`.
struct PaxSenixMusixmatchRoute: LyricsProvider {
    let provider: PaxSenixProvider
    func lyrics(for request: LyricsProviderRequest) async throws -> LyricsProviderAnswer? {
        await provider.musixmatchLyrics(title: request.title, artist: request.artist, durationMs: request.durationMs)?.answer
    }
}
