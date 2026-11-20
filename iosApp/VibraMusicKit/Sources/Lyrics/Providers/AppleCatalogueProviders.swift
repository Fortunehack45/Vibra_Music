import VibraMusicCore
import Foundation
import os

// MARK: - BetterLyrics

/// Word-timed lyrics from BetterLyrics — the backend behind the YouTube Music browser
/// extension of the same name.
///
/// One key-less call keyed on title, artist and duration, answering with Apple Music's own
/// TTML: no track-id lookup, no token to scrape, no login, and per-syllable timing.
///
/// This is the extension's original host. The project's newer Cloudflare API puts the same
/// endpoint behind a Turnstile challenge, which a native client has no way to answer.
public struct BetterLyricsProvider: LyricsProvider {
    public enum Endpoint: String, Sendable {
        /// Apple Music TTML.
        case apple = "https://lyrics-api.boidu.dev/getLyrics"
        /// QQ Music's karaoke timings through BetterLyrics' Portato endpoint.
        case portato = "https://lyrics-api.boidu.dev/qq/getLyrics"
    }

    private let http: LyricsHTTP
    private let endpoint: Endpoint

    public init(endpoint: Endpoint = .apple, session: URLSession = VibraMusicHTTP.session) {
        http = LyricsHTTP(session: session)
        self.endpoint = endpoint
    }

    public func lyrics(for request: LyricsProviderRequest) async throws -> LyricsProviderAnswer? {
        await lyrics(title: request.title, artist: request.artist, durationMs: request.durationMs, album: request.album)?.answer
    }

    public func lyrics(title: String, artist: String, durationMs: Int, album: String? = nil) async -> [LyricLine]? {
        var query = [("s", title), ("a", artist)]
        let seconds = durationMs / 1000
        if seconds > 0 { query.append(("d", String(seconds))) }
        if let album, !album.kIsBlank { query.append(("al", album)) }
        guard let body = await http.get(LyricsURL.make(endpoint.rawValue, query)) else { return nil }
        return ProviderLyrics.parse(body)
    }
}

// MARK: - BiniLyrics

/// Apple Music TTML again, from a third host — and the only one here that will answer to a
/// recording rather than to a name.
///
/// The catalogue is the same one BetterLyrics serves; what it adds is a different matcher
/// over it, which finds tracks BetterLyrics misses, particularly outside the
/// English-language releases, and an index by ISRC. A song can exist as a single at 205
/// seconds and an album cut at 206 with different words in places; an ISRC
/// names one recording, so a lookup that has one cannot come back with the wrong edit.
///
/// A search here also *reports* the ISRC of whatever it matched, which is where
/// `LyricsRepository` gets one to hand to the sources that can use it: this asks by name
/// once, and everything afterwards can ask by recording.
///
/// Two requests either way — the search returns a URL rather than the document, so the TTML
/// is a second fetch from the storage host. (The API host now redirects to lrc.red;
/// `URLSession` follows that the way OkHttp did.)
public final class BiniLyricsProvider: LyricsProvider, LyricsRecordingIdentifier, Sendable {
    private static let base = "https://lyrics-api.binimum.org/"

    /// One search hit.
    struct Hit: Hashable, Sendable {
        var trackName: String?
        var artistName: String?
        var albumName: String?
        var duration: Int?
        var isrc: String?
        /// `word` or `line`; the document itself is the authority.
        var timingType: String?
        var lyricsURL: String?
    }

    private let http: LyricsHTTP
    /// The last hits `identify` found, so the lyrics fetch that follows it in the same
    /// lookup does not search twice (Android handed the hit through the repository).
    private let recentHits = OSAllocatedUnfairLock(initialState: [LyricsProviderRequest: Hit]())

    public init(session: URLSession = VibraMusicHTTP.session) {
        http = LyricsHTTP(session: session)
    }

    /// Which recording this is, without fetching its words. The search is a couple of
    /// hundred bytes, and it is the only request any source makes whose answer is useful to
    /// the *other* sources.
    public func identify(_ request: LyricsProviderRequest) async throws -> String? {
        guard let hit = await search(request) else { return nil }
        recentHits.withLock { hits in
            if hits.count > 16 { hits.removeAll() }
            hits[request.withoutISRC] = hit
        }
        return hit.isrc.flatMap { $0.kIsBlank ? nil : $0 }
    }

    public func lyrics(for request: LyricsProviderRequest) async throws -> LyricsProviderAnswer? {
        let remembered = recentHits.withLock { $0[request.withoutISRC] }
        if let remembered, let found = await lyrics(for: remembered) { return found }
        guard let hit = await search(request) else { return nil }
        return await lyrics(for: hit)
    }

    func search(_ request: LyricsProviderRequest) async -> Hit? {
        var query = [(String, String)]()
        if let isrc = request.isrc, !isrc.kIsBlank {
            // Nothing else is worth sending: the recording is named, and a title alongside
            // it could only ever disagree with it.
            query.append(("isrc", isrc))
        } else {
            query.append(("track", request.title))
            query.append(("artist", request.artist))
            if let album = request.album, !album.kIsBlank { query.append(("album", album)) }
            if request.seconds > 0 { query.append(("duration", String(request.seconds))) }
        }
        // A miss is a 404 here rather than an empty result set, which `get` turns into nil.
        guard let body = await http.get(LyricsURL.make(Self.base, query)) else { return nil }
        return Self.firstHit(body)
    }

    /// The document a search already found, fetched and parsed.
    private func lyrics(for hit: Hit) async -> LyricsProviderAnswer? {
        guard let document = hit.lyricsURL, !document.kIsBlank,
              let ttml = await http.get(URL(string: document)),
              let lines = TTMLLyrics.parse(ttml).nonEmpty
        else { return nil }
        return LyricsProviderAnswer(lines: lines, isrc: hit.isrc.flatMap { $0.kIsBlank ? nil : $0 })
    }

    static func firstHit(_ body: String) -> Hit? {
        guard let root = LyricsJSON.parse(body)?.object, let first = root["results"]?.array?.first?.object else { return nil }
        return Hit(
            trackName: first["track_name"]?.content,
            artistName: first["artist_name"]?.content,
            albumName: first["album_name"]?.content,
            duration: first["duration"]?.long,
            isrc: first["isrc"]?.content,
            timingType: first["timing_type"]?.content,
            lyricsURL: first["lyricsUrl"]?.content
        )
    }
}

extension LyricsProviderRequest {
    /// The same search without the ISRC — what `identify` was asked before it knew one.
    fileprivate var withoutISRC: LyricsProviderRequest {
        var copy = self
        copy.isrc = nil
        copy.videoId = ""
        return copy
    }
}

// MARK: - LyricsPlus

/// Syllable-timed lyrics from LyricsPlus, the open backend behind the YouLy+ extension. It
/// aggregates Apple Music, QQ Music and Musixmatch, and its v2 response is the
/// finest-grained of the providers here — Apple's own syllable splits.
///
/// The catch is hosting: it runs on volunteer mirrors, and at any given moment most of them
/// are rate-limited, out of Vercel credit or simply gone. The extension's answer, copied
/// here, is to ask all of them at once and take the first real answer. The winner is
/// remembered so the next track goes straight to a host that was up a minute ago.
public final class LyricsPlusProvider: LyricsProvider, Sendable {
    static let mirrors = [
        "https://lyricsplus.prjktla.my.id",
        "https://lyricsplus.atomix.one",
        "https://lyricsplus.binimum.org",
        "https://lyricsplus.prjktla.workers.dev",
        "https://lyricsplus-seven.vercel.app",
        "https://lyrics-plus-backend.vercel.app",
    ]

    private let http: LyricsHTTP
    private let lastGood = OSAllocatedUnfairLock<String?>(initialState: nil)

    public init(session: URLSession = VibraMusicHTTP.session) {
        http = LyricsHTTP(session: session)
    }

    public func lyrics(for request: LyricsProviderRequest) async throws -> LyricsProviderAnswer? {
        await lyrics(title: request.title, artist: request.artist, durationMs: request.durationMs, album: request.album, isrc: request.isrc)?.answer
    }

    public func lyrics(title: String, artist: String, durationMs: Int, album: String? = nil, isrc: String? = nil) async -> [LyricLine]? {
        let hosts: [String]
        if let good = lastGood.withLock({ $0 }) {
            hosts = [good] + Self.mirrors.filter { $0 != good }
        } else {
            hosts = Self.mirrors
        }

        // Take the first mirror to answer with something usable rather than the first to
        // answer at all — a mirror that 404s this track shouldn't beat one that has it.
        return await withTaskGroup(of: (String, [LyricLine]?).self) { group in
            for host in hosts {
                group.addTask { (host, await self.fetch(host: host, title: title, artist: artist, durationMs: durationMs, album: album, isrc: isrc)) }
            }
            for await (host, lines) in group {
                if let lines, !lines.isEmpty {
                    lastGood.withLock { $0 = host }
                    group.cancelAll()
                    return lines
                }
            }
            return nil
        }
    }

    private func fetch(host: String, title: String, artist: String, durationMs: Int, album: String?, isrc: String?) async -> [LyricLine]? {
        var query = [("title", title), ("artist", artist)]
        let seconds = durationMs / 1000
        if seconds > 0 { query.append(("duration", String(seconds))) }
        if let album, !album.kIsBlank { query.append(("album", album)) }
        // Sent alongside the name rather than instead of it: unlike BiniLyrics this backend
        // aggregates several catalogues, and the ones with no ISRC index still need something
        // to match on.
        if let isrc, !isrc.kIsBlank { query.append(("isrc", isrc)) }
        guard let body = await http.get(LyricsURL.make(host + "/v2/lyrics/get", query)),
              let response = Response(json: body)
        else { return nil }
        return Self.parse(response).nonEmpty
    }

    struct Response {
        var type: String?
        var lines: [Line]?
        /// Declared voices: id → (type, alias).
        var agents: [(id: String, type: String?, alias: String?)] = []

        /// The declared voices, keyed the way the lines refer to them — by alias where one is
        /// given, which is what a line's `singer` actually holds.
        var agentTypes: [String: String] {
            var types = [String: String]()
            for agent in agents {
                guard let type = agent.type else { continue }
                types[agent.alias ?? agent.id] = type
            }
            return types
        }

        init(type: String? = nil, lines: [Line]? = nil, agents: [(id: String, type: String?, alias: String?)] = []) {
            self.type = type
            self.lines = lines
            self.agents = agents
        }

        init?(json body: String) {
            guard let root = LyricsJSON.parse(body)?.object else { return nil }
            type = root["type"]?.content
            if let array = root["lyrics"]?.array {
                var lines = [Line]()
                for entry in array {
                    guard let line = entry.object else { return nil }
                    lines.append(Line(
                        time: line["time"]?.long,
                        duration: line["duration"]?.long,
                        text: line["text"]?.content,
                        syllabus: line["syllabus"]?.array?.compactMap { syllable in
                            syllable.object.map {
                                Syllable(time: $0["time"]?.long, duration: $0["duration"]?.long, text: $0["text"]?.content)
                            }
                        },
                        element: line["element"]
                    ))
                }
                self.lines = lines
            }
            if let agents = root["metadata"]?["agents"]?.object {
                self.agents = agents.entries.map { entry in
                    (entry.key, entry.value["type"]?.content, entry.value["alias"]?.content)
                }
            }
        }
    }

    struct Line {
        var time: Int?
        var duration: Int?
        var text: String?
        var syllabus: [Syllable]?
        /// Raw: an object carrying `singer` on the current API and a bare array of tags on the
        /// older one. Read as raw JSON so a payload using the other shape doesn't fail.
        var element: LyricsJSON?
    }

    struct Syllable {
        var time: Int?
        var duration: Int?
        var text: String?
    }

    static func parse(_ response: Response) -> [LyricLine] {
        let sung = (response.lines ?? []).compactMap { line -> (LyricLine, LyricsJSON?)? in
            guard let start = line.time else { return nil }
            let words = mergeSyllables(line.syllabus ?? [])
            if let first = words.first {
                return (LyricLine(timeMs: min(start, first.startMs), text: words.map(\.text).joined(separator: " "), words: words), line.element)
            }
            // Some sources are only line-synced; still worth showing. The line's duration is
            // the only end it gets, and without it an interlude can't be told from a slowly
            // sung line.
            if let text = line.text, !text.kIsBlank {
                let end = line.duration.flatMap { $0 > 0 ? start + $0 : nil }
                return (LyricLine(timeMs: start, text: text.kTrimmed, sungUntilMs: end), line.element)
            }
            return nil
        }.kSortedBy(\.0.timeMs)

        let sides = lineAlignments(singers: sung.map { singer(of: $0.1) }, types: response.agentTypes)
        return sung.enumerated().map { index, entry in
            var line = entry.0
            // A payload that names no voices at all can still mark a line as the answering
            // side, which is how the older shape of this API said the same thing.
            line.alignment = sides[index] == .end || saysOpposite(entry.1) ? .end : .start
            return line
        }.withInstrumentalGaps()
    }

    private static func singer(of element: LyricsJSON?) -> String? {
        guard let singer = element?.object?["singer"], singer.isPrimitive else { return nil }
        return singer.content
    }

    /// The older shape: `element` as a list of tags, one of which is the side.
    private static func saysOpposite(_ element: LyricsJSON?) -> Bool {
        guard let tags = element?.array else { return false }
        return tags.contains { tag in
            guard case .string(let value) = tag else { return false }
            return value == "opposite" || value == "right"
        }
    }

    /// Glues syllables back into words. The API's own spacing is the word boundary — it
    /// emits `"e"` then `"nough "`, and the trailing space is the only thing saying those
    /// are one word. Splitting on the syllable instead would render "e nough".
    private static func mergeSyllables(_ syllables: [Syllable]) -> [LyricWord] {
        var words = [LyricWord]()
        var current = ""
        var start = 0
        var end = 0
        for syllable in syllables {
            guard let text = syllable.text, !text.kIsBlank, let time = syllable.time else { continue }
            if current.isEmpty { start = time }
            current += text.kTrimmed
            end = time + (syllable.duration ?? 0)
            if text.unicodeScalars.last?.kIsWhitespace == true {
                words.append(LyricWord(startMs: start, endMs: end, text: current))
                current = ""
            }
        }
        if !current.isEmpty { words.append(LyricWord(startMs: start, endMs: end, text: current)) }
        return words
    }
}
