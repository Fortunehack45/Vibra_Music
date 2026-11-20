import VibraMusicCore
import Foundation

/// Lyrics from LRCLIB — a free, key-less, community lyrics database.
///
/// Two calls: an exact `get` keyed on artist + title + duration, and a fuzzy `search` when
/// that misses (YouTube Music titles carry "(From ...)" and "| Official Video" noise that
/// the exact endpoint won't match). Results are line-synced `[mm:ss.xx]` LRC — LRCLIB has no
/// word-level timing, so highlighting is per line.
public struct LrcLibProvider: LyricsProvider {
    private static let base = "https://lrclib.net/api"
    /// Android sends these through the shared stream client, not the short lyrics deadline.
    private static let deadline: TimeInterval = 20

    private let http: LyricsHTTP

    public init(session: URLSession = VibraMusicHTTP.session) {
        http = LyricsHTTP(session: session)
    }

    public func lyrics(for request: LyricsProviderRequest) async throws -> LyricsProviderAnswer? {
        try await lyrics(title: request.title, artist: request.artist, durationMs: request.durationMs)?.answer
    }

    /// Synced lyrics for a track, or nil when nothing usable is published.
    public func lyrics(title: String, artist: String, durationMs: Int) async throws -> [LyricLine]? {
        let cleanTitle = Self.clean(title)
        let cleanArtist = Self.clean(artist)
        let seconds = durationMs / 1000

        let synced: String?
        if let exact = await exactMatch(cleanTitle, cleanArtist, seconds) {
            synced = exact
        } else {
            synced = await bestSearchHit(cleanTitle, cleanArtist, seconds)
        }
        return synced.map(LRCFormat.parse)?.nonEmpty
    }

    private func exactMatch(_ title: String, _ artist: String, _ seconds: Int) async -> String? {
        let url = LyricsURL.make(Self.base + "/get", [
            ("track_name", title), ("artist_name", artist), ("duration", String(seconds)),
        ])
        guard let body = await get(url) else { return nil }
        return Self.syncedLyrics(inExactAnswer: body)
    }

    /// Fuzzy fallback. Prefers whichever hit is closest in length to what we're actually
    /// playing — same song, different edit, would drift otherwise.
    private func bestSearchHit(_ title: String, _ artist: String, _ seconds: Int) async -> String? {
        let url = LyricsURL.make(Self.base + "/search", [("track_name", title), ("artist_name", artist)])
        guard let body = await get(url) else { return nil }
        return Self.bestSyncedLyrics(inSearchAnswer: body, seconds: seconds)
    }

    private func get(_ url: URL?) async -> String? {
        await http.get(url, headers: ["User-Agent": LyricsHTTP.agent], deadline: Self.deadline)
    }

    static func syncedLyrics(inExactAnswer body: String) -> String? {
        guard let object = LyricsJSON.parse(body)?.object else { return nil }
        return object["syncedLyrics"]?.content
    }

    static func bestSyncedLyrics(inSearchAnswer body: String, seconds: Int) -> String? {
        guard let hits = LyricsJSON.parse(body)?.array else { return nil }
        let synced = hits.compactMap(\.object).filter { hit in
            guard let lyrics = hit["syncedLyrics"]?.content else { return false }
            return !lyrics.kIsBlank
        }
        return synced.kMinBy { abs(($0["duration"]?.double ?? 0) - Double(seconds)) }?["syncedLyrics"]?.content
    }

    /// YouTube Music titles are noisy — "(From "Raees")", "| Official Video", "(Lyrical)" —
    /// and LRCLIB matches on the plain song name.
    static func clean(_ value: String) -> String {
        let cleaned = LyricsRegex(#"[ \t\n\x0B\f\r]+"#).replacing(
            in: noise.replacing(in: value, with: " ").kSubstringBefore(" | "),
            with: " "
        ).kTrimmed
        return cleaned.kIsBlank ? value : cleaned
    }

    private static let noise = LyricsRegex(
        #"\((?:from|feat\.?|official|lyrical|video|audio|remix)[^)]*\)|\[[^\]]*\]|"#
            + #"\b(?:official (?:video|audio|music video)|lyrical|full song|4k video)\b"#,
        caseInsensitive: true
    )
}
