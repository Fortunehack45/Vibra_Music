import CryptoKit
import VibraMusicCore
import Foundation

/// Rich word timing, with line-synced fallback, from Musixmatch's web API.
///
/// Every call is signed: HMAC-SHA256 over the URL and today's UTC date, with a key the
/// current web client carries (base64, reversed) in one of its JavaScript chunks. The key
/// and the user token both rotate, so both are cached and refreshed once on an auth failure.
public final class MusixmatchProvider: LyricsProvider, Sendable {
    private static let base = "https://apic.musixmatch.com/ws/1.1"
    private static let appID = "mobile-app-v1.0"
    private static let searchPage = "https://www.musixmatch.com/search"
    private static let browserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    /// Used only if the public page serving the rotating key is briefly unavailable.
    static let fallbackSigningSecret = "f09016176ba43a1cfd1031fbd6b3d26c"
    private static let deadline: TimeInterval = 8

    private let http: LyricsHTTP
    private let credentials = Credentials()
    private let guid = UUID().uuidString.lowercased()
    private let now: @Sendable () -> Date

    public init(session: URLSession = VibraMusicHTTP.session) {
        http = LyricsHTTP(session: session)
        now = { Date() }
    }

    init(session: URLSession, now: @escaping @Sendable () -> Date) {
        http = LyricsHTTP(session: session)
        self.now = now
    }

    public func lyrics(for request: LyricsProviderRequest) async throws -> LyricsProviderAnswer? {
        try await lyrics(title: request.title, artist: request.artist, durationMs: request.durationMs)?.answer
    }

    public func lyrics(title: String, artist: String, durationMs: Int) async throws -> [LyricLine]? {
        let seconds = durationMs / 1000
        guard let track = await bestTrack(title: title, artist: artist, seconds: seconds) else { return nil }

        // The subtitle endpoint is line-timed by design. Prefer the separate rich-sync tier
        // so tracks that have syllable data do not get flattened on ingestion.
        if track.hasRichSync != 0, let body = await fetchRichSync(track.trackID) {
            let rich = Self.parseRichSyncBody(body)
            if rich.contains(where: \.isWordSynced) { return rich }
        }

        guard track.hasSubtitles != 0, let subtitle = await fetchSubtitle(track.trackID) else { return nil }
        let lrc = Self.subtitleToLRC(subtitle)
        guard !lrc.kIsBlank else { return nil }
        return LRCFormat.parse(lrc).nonEmpty
    }

    // MARK: Search

    struct Track: Equatable {
        let trackID: Int
        let trackName: String
        let artistName: String
        let trackLength: Int?
        let hasSubtitles: Int?
        let hasRichSync: Int?
    }

    private func bestTrack(title: String, artist: String, seconds: Int) async -> Track? {
        guard let tracks = await searchTrack(title: title, artist: artist) else { return nil }
        return tracks.kMaxBy { Self.score($0, title: title, artist: artist, seconds: seconds) }
    }

    static func score(_ track: Track, title: String, artist: String, seconds: Int) -> Double {
        var score = 0.0
        let name = track.trackName.kTrimmed.lowercased()
        let target = title.kTrimmed.lowercased()
        if name == target {
            score += 80
        } else if name.kContains(target) || target.kContains(name) {
            score += 40
        }
        if track.artistName.kTrimmed.lowercased().kContains(artist.kTrimmed.lowercased()) { score += 40 }
        if let length = track.trackLength {
            let diff = abs(length - seconds)
            score += diff <= 2 ? 30 : diff <= 5 ? 15 : diff <= 10 ? 5 : -20
        }
        return score
    }

    private func searchTrack(title: String, artist: String) async -> [Track]? {
        let response = await signedGet { token in
            LyricsURL.string(Self.base + "/track.search", [
                ("app_id", Self.appID), ("format", "json"), ("q_track", title), ("q_artist", artist),
                ("f_has_lyrics", "1"), ("s_track_rating", "desc"), ("quorum_factor", "1"),
                ("page_size", "10"), ("page", "1"), ("usertoken", token),
            ])
        }
        return response.flatMap(Self.tracks(inSearch:))
    }

    static func tracks(inSearch body: String) -> [Track]? {
        guard let message = LyricsJSON.parse(body)?["message"], message["header"] != nil else { return nil }
        guard let list = message["body"]?["track_list"]?.array else { return nil }
        var tracks = [Track]()
        for wrapper in list {
            guard let track = wrapper["track"],
                  let id = track["track_id"]?.long,
                  let name = track["track_name"]?.content
            else { return nil }
            tracks.append(Track(
                trackID: id,
                trackName: name,
                artistName: track["artist_name"]?.content ?? "",
                trackLength: track["track_length"]?.long,
                hasSubtitles: track["has_subtitles"]?.long,
                hasRichSync: track["has_richsync"]?.long
            ))
        }
        return tracks
    }

    private func fetchSubtitle(_ trackID: Int) async -> String? {
        let response = await signedGet { token in
            LyricsURL.string(Self.base + "/track.subtitle.get", [
                ("app_id", Self.appID), ("format", "json"), ("track_id", String(trackID)),
                ("subtitle_format", "mxm"), ("usertoken", token),
            ])
        }
        return response.flatMap { LyricsJSON.parse($0)?["message"]?["body"]?["subtitle"]?["subtitle_body"]?.content }
    }

    private func fetchRichSync(_ trackID: Int) async -> String? {
        let response = await signedGet { token in
            LyricsURL.string(Self.base + "/track.richsync.get", [
                ("app_id", Self.appID), ("format", "json"), ("track_id", String(trackID)), ("usertoken", token),
            ])
        }
        return response.flatMap { LyricsJSON.parse($0)?["message"]?["body"]?["richsync"]?["richsync_body"]?.content }
    }

    // MARK: Parsing

    /// Decodes rich-sync offsets without flattening them through line LRC. Source order is
    /// retained because punctuation and syllable fragments may share a stamp.
    static func parseRichSyncBody(_ body: String) -> [LyricLine] {
        guard let entries = LyricsJSON.parse(body)?.array else { return [] }
        var parsed = [LyricLine]()
        for entry in entries {
            guard let startSeconds = entry["ts"]?.double, let endSeconds = entry["te"]?.double else { return [] }
            var fragments = [(text: String, offset: Double)]()
            for fragment in entry["l"]?.array ?? [] {
                guard let text = fragment["c"]?.content, let offset = fragment["o"]?.double else { return [] }
                fragments.append((text, offset))
            }
            let lineStart = milliseconds(startSeconds)
            let lineEnd = max(lineStart, milliseconds(endSeconds))
            var words = [LyricWord]()
            var current = ""
            var currentStart = lineStart
            var currentEnd = lineStart
            var previousStart = lineStart

            func flush() {
                let text = current.kTrimmed
                current = ""
                if !text.isEmpty { words.append(LyricWord(startMs: currentStart, endMs: max(currentStart, currentEnd), text: text)) }
            }

            for (index, fragment) in fragments.enumerated() {
                let raw = fragment.text
                if raw.isEmpty { continue }
                let start = max(lineStart, previousStart, milliseconds(startSeconds + fragment.offset))
                let next = fragments.kGet(index + 1).map { milliseconds(startSeconds + $0.offset) } ?? lineEnd
                let end = max(start, min(lineEnd, next))
                previousStart = start

                if raw.unicodeScalars.first?.kIsWhitespace == true { flush() }
                let content = raw.kTrimmed
                if !content.isEmpty {
                    if current.isEmpty { currentStart = start }
                    current += content
                    currentEnd = end
                }
                if raw.unicodeScalars.last?.kIsWhitespace == true { flush() }
            }
            flush()

            let stated = (entry["x"]?.content ?? "").kTrimmed
            let text = stated.isEmpty ? words.map(\.text).joined(separator: " ") : stated
            if text.isEmpty { continue }
            parsed.append(LyricLine(
                timeMs: min(lineStart, words.first?.startMs ?? lineStart),
                text: text,
                words: words,
                sungUntilMs: lineEnd > lineStart ? lineEnd : nil
            ))
        }
        return parsed.kSortedBy(\.timeMs).withInstrumentalGaps()
    }

    /// Musixmatch's `mxm` subtitle JSON, converted only for the line-sync fallback.
    static func subtitleToLRC(_ subtitleBody: String) -> String {
        guard let lines = LyricsJSON.parse(subtitleBody)?.array else { return "" }
        var rows = [String]()
        for line in lines {
            guard let text = line["text"]?.content, let total = line["time"]?["total"]?.double else { return "" }
            if text.kIsBlank { continue }
            let totalMs = milliseconds(total)
            let minutes = totalMs / 1000 / 60
            let seconds = (totalMs / 1000) % 60
            let millis = totalMs % 1000
            rows.append("[" + pad(minutes, 2) + ":" + pad(seconds, 2) + "." + pad(millis, 3) + "]" + text)
        }
        return rows.joined(separator: "\n").kTrimmed
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return digits.count < width ? String(repeating: "0", count: width - digits.count) + digits : digits
    }

    private static func milliseconds(_ seconds: Double) -> Int { kLong(seconds * 1_000.0) }

    // MARK: Signing

    /// Signs and issues the URL `build` makes for a token; an auth failure refreshes both
    /// moving credentials once.
    private func signedGet(_ build: (String) -> String) async -> String? {
        let secret = await secret()
        guard let token = await token(secret: secret) else { return nil }
        if let first = await apiGet(Self.sign(build(token), secret: secret, date: now())), !Self.looksUnauthorized(first) {
            return first
        }
        await credentials.reset()
        let freshSecret = await self.secret()
        guard let freshToken = await self.token(secret: freshSecret) else { return nil }
        return await apiGet(Self.sign(build(freshToken), secret: freshSecret, date: now()))
    }

    /// Musixmatch reports an expired token inside a successful HTTP response.
    static func looksUnauthorized(_ body: String) -> Bool {
        guard let code = LyricsJSON.parse(body)?["message"]?["header"]?["status_code"]?.long else { return false }
        return code == 401 || code == 402
    }

    private func token(secret: String) async -> String? {
        await credentials.token {
            let url = LyricsURL.string(Self.base + "/token.get", [
                ("app_id", Self.appID), ("guid", self.guid), ("format", "json"),
            ])
            guard let body = await self.apiGet(Self.sign(url, secret: secret, date: self.now())) else { return nil }
            return LyricsJSON.parse(body)?["message"]?["body"]?["user_token"]?.content
        }
    }

    /// Reads the rotating signing key from the JavaScript linked by the current web client.
    private func secret() async -> String {
        await credentials.secret {
            guard let page = await self.browserGet(Self.searchPage, accept: "text/html,application/xhtml+xml"),
                  let script = Self.appScript.firstMatch(in: page)?.groupValues[1],
                  let scriptURL = URL(string: script, relativeTo: URL(string: Self.searchPage))?.absoluteString,
                  let javascript = await self.browserGet(scriptURL, accept: "*/*"),
                  let encoded = Self.encodedSecret.firstMatch(in: javascript)?.groupValues[1],
                  let data = Data(base64Encoded: String(encoded.reversed())),
                  let key = String(data: data, encoding: .utf8), !key.kIsBlank
            else { return Self.fallbackSigningSecret }
            return key
        }
    }

    /// `<url><UTC yyyyMMdd>` signed with HMAC-SHA256, matching the current web client.
    static func sign(_ url: String, secret: String, date: Date) -> String {
        let normalized = url.replacingOccurrences(of: "%20", with: "+").replacingOccurrences(of: " ", with: "+")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%04d%02d%02d", locale: Locale(identifier: "en_US_POSIX"), parts.year!, parts.month!, parts.day!)
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data((normalized + day).utf8),
            using: SymmetricKey(data: Data(secret.utf8))
        )
        let signature = Data(mac).base64EncodedString()
        return normalized + "&signature=" + LyricsURL.formComponent(signature) + "&signature_protocol=sha256"
    }

    private func apiGet(_ url: String) async -> String? {
        await request(url, accept: "application/json, text/plain, */*", cookie: nil)
    }

    private func browserGet(_ url: String, accept: String) async -> String? {
        await request(url, accept: accept, cookie: "mxm_bab=AB")
    }

    private func request(_ url: String, accept: String, cookie: String?) async -> String? {
        var headers = [
            "User-Agent": Self.browserAgent,
            "Accept": accept,
            "Accept-Language": "en-US,en;q=0.9",
        ]
        if let cookie { headers["Cookie"] = cookie }
        return await http.get(URL(string: url), headers: headers, deadline: Self.deadline)
    }

    private static let appScript = LyricsRegex(
        #"src=["']([^"']*/_next/static/chunks/pages/_app-[^"']+\.js)["']"#,
        caseInsensitive: true
    )
    private static let encodedSecret = LyricsRegex(#"from\([ \t\n\x0B\f\r]*["']([^"']+)["'][ \t\n\x0B\f\r]*\.split"#)

    /// The signing key and user token, each fetched once and shared by concurrent lookups.
    private actor Credentials {
        private var cachedSecret: String?
        private var cachedToken: String?
        private var tokenTask: Task<String?, Never>?
        private var secretTask: Task<String, Never>?

        func secret(_ fetch: @escaping @Sendable () async -> String) async -> String {
            if let cachedSecret { return cachedSecret }
            let task = secretTask ?? Task { await fetch() }
            secretTask = task
            let value = await task.value
            cachedSecret = value
            secretTask = nil
            return value
        }

        func token(_ fetch: @escaping @Sendable () async -> String?) async -> String? {
            if let cachedToken { return cachedToken }
            let task = tokenTask ?? Task { await fetch() }
            tokenTask = task
            let value = await task.value
            if let value { cachedToken = value }
            tokenTask = nil
            return value
        }

        func reset() {
            cachedSecret = nil
            cachedToken = nil
        }
    }
}
