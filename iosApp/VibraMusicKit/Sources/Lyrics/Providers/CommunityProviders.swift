import VibraMusicCore
import Foundation

// MARK: - SimpMusic

/// Lyrics from SimpMusic's community database, keyed on the YouTube video id.
///
/// That key is what makes it worth having: every other provider matches on title and artist
/// and can hand back a different edit of the same song, which drifts out of sync a verse
/// in. This one is looking up the exact track that is playing.
///
/// Two caveats, both seen in the wild:
///  - the host blocks some regions and networks outright, answering 403 with a Cloudflare
///    page rather than a network error, so a miss here can be permanent for a given user
///    and the chain must carry on past it;
///  - the rich sync is served HTML-escaped — see `EnhancedLRC.decodeEntities`.
public struct SimpMusicProvider: LyricsProvider {
    private static let base = "https://api-lyrics.simpmusic.org/v1/"
    /// Duration slack when the database holds several cuts of one video.
    private static let durationToleranceSeconds = 10

    private let http: LyricsHTTP

    public init(session: URLSession = VibraMusicHTTP.session) {
        http = LyricsHTTP(session: session)
    }

    public func lyrics(for request: LyricsProviderRequest) async throws -> LyricsProviderAnswer? {
        await lyrics(videoId: request.videoId, durationMs: request.durationMs)?.answer
    }

    public func lyrics(videoId: String, durationMs: Int) async -> [LyricLine]? {
        guard !videoId.kIsBlank, let body = await http.get(URL(string: Self.base + videoId)) else { return nil }
        return Self.parse(body, durationMs: durationMs)
    }

    static func parse(_ body: String, durationMs: Int) -> [LyricLine]? {
        guard let root = LyricsJSON.parse(body)?.object, succeeded(root) else { return nil }
        let seconds = durationMs / 1000
        let tracks = (root["data"]?.array ?? []).compactMap(\.object)
        let candidates = tracks.filter { seconds <= 0 || abs(duration(of: $0) - seconds) <= durationToleranceSeconds }
        guard let track = candidates.kMinBy({ abs(duration(of: $0) - seconds) }) else { return nil }

        // Word timing first; a line-synced answer from here is no better than LRCLIB's, but
        // it is still better than nothing.
        if let rich = track["richSyncLyrics"]?.content, !rich.kIsBlank, let lines = EnhancedLRC.parse(rich).nonEmpty {
            return lines
        }
        if let synced = track["syncedLyrics"]?.content, !synced.kIsBlank {
            return LRCFormat.parse(synced).nonEmpty
        }
        return nil
    }

    /// Whether the envelope says the lookup worked.
    ///
    /// iOS difference: Android reads only `success: true`, which is what the server's
    /// published OpenAPI document declares (`DocsLyricsListResponseSuccess`). Other clients
    /// of the same host read `type: "success"` instead (Echo Music's `SimpMusicApiResponse`),
    /// so both are accepted: this host cannot be reached from every network to check which
    /// one it sends on a given day, and turning a real answer away over the envelope's
    /// spelling would be a silent miss.
    private static func succeeded(_ root: LyricsJSONObject) -> Bool {
        root["success"] == .bool(true) || root["type"]?.content == "success"
    }

    /// The entry's length in seconds, 0 when unstated.
    ///
    /// iOS difference: Android reads only `duration`. The server's own schema
    /// (`LyricResponseDTO` in the OpenAPI document shipped with the official frontend,
    /// github.com/maxrave-dev/lyrics-frontend `src/data/openapi.json`) names the field
    /// `durationSeconds`, and read as `duration` it is always absent — which, for any track
    /// with a known length, filters every entry out. Both names are accepted here.
    private static func duration(of entry: LyricsJSONObject) -> Int {
        entry["duration"]?.long ?? entry["durationSeconds"]?.long ?? 0
    }
}

// MARK: - Unison

/// A community-submitted lyrics database, and the only source here whose contents are
/// contributed rather than licensed.
///
/// Every other source is a window onto somebody's catalogue; this one carries what people
/// have uploaded, which means it occasionally has a track none of the others do, and its
/// coverage is thin and uneven everywhere else. It sits low in the default order for
/// exactly that reason.
///
/// Each entry is voted on (`score`, `voteCount`, `confidence`). None of it is acted on: a
/// fresh submission is `confidence: "low"` with no votes, so refusing those would refuse
/// nearly the whole database. Three shapes come back, and it says which: Apple-style TTML,
/// ordinary line-stamped LRC, or plain text.
public struct UnisonProvider: LyricsProvider {
    private static let base = "https://unison.boidu.dev/lyrics"
    private let http: LyricsHTTP

    public init(session: URLSession = VibraMusicHTTP.session) {
        http = LyricsHTTP(session: session)
    }

    public func lyrics(for request: LyricsProviderRequest) async throws -> LyricsProviderAnswer? {
        await lyrics(title: request.title, artist: request.artist, durationMs: request.durationMs, album: request.album)?.answer
    }

    public func lyrics(title: String, artist: String, durationMs: Int, album: String? = nil) async -> [LyricLine]? {
        var query = [("song", title), ("artist", artist)]
        if let album, !album.kIsBlank { query.append(("album", album)) }
        let seconds = durationMs / 1000
        if seconds > 0 { query.append(("duration", String(seconds))) }
        guard let body = await http.get(LyricsURL.make(Self.base, query)),
              let root = LyricsJSON.parse(body)?.object,
              root["success"] == .bool(true),
              let entry = Entry(root["data"])
        else { return nil }
        return Self.lines(of: entry)
    }

    struct Entry: Equatable {
        var lyrics: String?
        /// `ttml` or `lrc`.
        var format: String?
        /// `wordsync`, `linesync` or `plain`.
        var syncType: String?

        init(lyrics: String? = nil, format: String? = nil, syncType: String? = nil) {
            self.lyrics = lyrics
            self.format = format
            self.syncType = syncType
        }

        init?(_ json: LyricsJSON?) {
            guard let object = json?.object else { return nil }
            lyrics = object["lyrics"]?.content
            format = object["format"]?.content
            syncType = object["syncType"]?.content
        }
    }

    /// The three shapes, told apart by what the entry says it is.
    static func lines(of entry: Entry) -> [LyricLine]? {
        guard let text = entry.lyrics, !text.kIsBlank else { return nil }
        let lines: [LyricLine]
        if entry.format?.kEqualsIgnoreCase("ttml") == true {
            lines = TTMLLyrics.parse(text)
        } else if entry.syncType?.kEqualsIgnoreCase("plain") == true {
            // No timing: one line each, all stamped zero, which is how every unsynced source
            // here says the same thing.
            lines = text.kLines.map(\.kTrimmed).filter { !$0.isEmpty }.map { LyricLine(timeMs: 0, text: $0) }
        } else {
            // Word stamps first: the format field says only "lrc", and an enhanced file is
            // still one. EnhancedLRC comes back empty when there are no word stamps in it,
            // which is the signal to fall through rather than a failure.
            let enhanced = EnhancedLRC.parse(text)
            lines = enhanced.isEmpty ? LRCFormat.parse(text) : enhanced
        }
        return lines.nonEmpty
    }
}

// MARK: - Megalobiz

/// Line-synced community LRC scraped from Megalobiz.
///
/// iOS difference: Android searches `/searchall` and looks for `/lrc/maker/download/…`
/// links. That endpoint answers 404 (September 2026), and the site's own search form —
/// `/search/all?qry=` — links each result as `/lrc/maker/<name>.<id>`, whose page carries
/// the LRC in the `lrc_<id>_details` block the Android page parser reads. This port asks
/// the real search and accepts both link shapes, so the provider works whenever the site
/// does. (The site itself was timing out on 2026-09-26.)
public struct MegalobizProvider: LyricsProvider {
    private static let base = "https://www.megalobiz.com"
    private let http: LyricsHTTP

    public init(session: URLSession = VibraMusicHTTP.session) {
        http = LyricsHTTP(session: session)
    }

    public func lyrics(for request: LyricsProviderRequest) async throws -> LyricsProviderAnswer? {
        await lyrics(title: request.title, artist: request.artist)?.answer
    }

    public func lyrics(title: String, artist: String) async -> [LyricLine]? {
        let search = LyricsURL.make(Self.base + "/search/all", [("qry", (artist + " " + title).kTrimmed)])
        guard let results = await http.get(search, headers: ["User-Agent": LyricsHTTP.agent, "Accept": "text/html"]),
              let path = Self.pagePath(inSearch: results),
              let page = await http.get(URL(string: Self.base + path), headers: ["User-Agent": LyricsHTTP.agent, "Accept": "text/html"])
        else { return nil }
        return Self.parsePage(page)
    }

    /// The first result's page: an Android-style download link where one is present,
    /// otherwise the first `/lrc/maker/<name>.<id>` result.
    static func pagePath(inSearch html: String) -> String? {
        let path = lrcLink.firstMatch(in: html)?.groupValues[1] ?? resultLink.firstMatch(in: html)?.groupValues[1]
        return path?.replacingOccurrences(of: "&amp;", with: "&")
    }

    static func parsePage(_ page: String) -> [LyricLine]? {
        guard let raw = lrcBody.firstMatch(in: page)?.groupValues[1] else { return nil }
        let lrc = EnhancedLRC.decodeEntities(
            LyricsRegex("<[^>]+>").replacing(in: LyricsRegex(#"<br[ \t\n\x0B\f\r]*/?>"#, caseInsensitive: true).replacing(in: raw, with: "\n"), with: "")
        )
        let lines = LRCFormat.parse(lrc)
        return lines.contains(where: { !$0.text.kIsBlank }) ? lines : nil
    }

    private static let lrcLink = LyricsRegex(#"href=["'](/lrc/maker/download/[^"']+)["']"#, caseInsensitive: true)
    private static let resultLink = LyricsRegex(#"href=["'](/lrc/maker/[^"'/]+\.[0-9]+)["']"#, caseInsensitive: true)
    private static let lrcBody = LyricsRegex(
        #"id=["']lrc_[^"']*_details["'][^>]*>(.*?)</span>"#,
        caseInsensitive: true,
        dotMatchesLineSeparators: true
    )
}
