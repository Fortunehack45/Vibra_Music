import VibraMusicCore
import Foundation

/// Line-synced lyrics from KuGou's public mobile/lyrics endpoints — a Chinese catalogue,
/// but one that also carries a great many English and Hindi tracks the others don't have.
///
/// Three unauthenticated calls, chained: search the song to get its audio fingerprint
/// (`hash`), search lyrics candidates against that hash, then download the winning
/// candidate. A search by keyword alone (skipping the hash) is kept as the fallback that
/// catches everything the first two miss.
public struct KuGouProvider: LyricsProvider {
    private static let durationToleranceSeconds = 8
    private let http: LyricsHTTP

    public init(session: URLSession = VibraMusicHTTP.session) {
        http = LyricsHTTP(session: session)
    }

    public func lyrics(for request: LyricsProviderRequest) async throws -> LyricsProviderAnswer? {
        try await lyrics(title: request.title, artist: request.artist, durationMs: request.durationMs, album: request.album)?.answer
    }

    public func lyrics(title: String, artist: String, durationMs: Int, album: String? = nil) async throws -> [LyricLine]? {
        let keyword = Self.keyword(title: title, artist: artist, album: album)
        let seconds = durationMs / 1000

        var candidate: Candidate?
        if let hashes = await searchSongs(keyword, seconds: seconds) {
            for hash in hashes {
                if let first = await searchLyrics(hash: hash)?.first {
                    candidate = first
                    break
                }
            }
        }
        if candidate == nil {
            candidate = await searchLyrics(keyword: keyword, seconds: seconds)?.first
        }
        guard let candidate, let lrc = await download(id: candidate.id, accessKey: candidate.accessKey) else { return nil }
        return LRCFormat.parse(lrc).nonEmpty
    }

    struct Candidate: Equatable {
        let id: String
        let accessKey: String
    }

    /// Song hashes worth trying, restricted to cuts within `durationToleranceSeconds` of the
    /// track being played — otherwise the first result for a common title is as likely to be
    /// a cover or a remix as the right recording — and ordered closest match first.
    private func searchSongs(_ keyword: String, seconds: Int) async -> [String]? {
        let url = LyricsURL.make("https://mobileservice.kugou.com/api/v3/search/song", [
            ("version", "9108"), ("plat", "0"), ("pagesize", "8"), ("showtype", "0"), ("keyword", keyword),
        ])
        guard let body = await http.get(url) else { return nil }
        return Self.songHashes(body, seconds: seconds)
    }

    static func songHashes(_ body: String, seconds: Int) -> [String] {
        // Decoded as a whole: one entry missing its hash fails the response, as it does on Android.
        guard let root = LyricsJSON.parse(body)?.object else { return [] }
        let info = root["data"]?["info"]?.array ?? []
        var entries = [(hash: String, duration: Int)]()
        for item in info {
            guard let hash = item["hash"]?.content else { return [] }
            entries.append((hash, item["duration"]?.long ?? -1))
        }
        return entries
            .filter { seconds <= 0 || abs($0.duration - seconds) <= durationToleranceSeconds }
            .kSortedBy { abs($0.duration - seconds) }
            .map(\.hash)
    }

    private func searchLyrics(hash: String? = nil, keyword: String? = nil, seconds: Int = -1) async -> [Candidate]? {
        var query: [(String, String)] = [("ver", "1"), ("man", "yes"), ("client", "pc")]
        if let hash {
            query.append(("hash", hash))
        } else if let keyword {
            query.append(("keyword", keyword))
            if seconds > 0 { query.append(("duration", String(seconds * 1000))) }
        } else {
            return nil
        }
        guard let body = await http.get(LyricsURL.make("https://lyrics.kugou.com/search", query)) else { return nil }
        return Self.candidates(body)
    }

    static func candidates(_ body: String) -> [Candidate]? {
        guard let root = LyricsJSON.parse(body)?.object else { return nil }
        guard let list = root["candidates"]?.array else { return [] }
        var out = [Candidate]()
        for entry in list {
            guard let id = entry["id"]?.content, let key = entry["accesskey"]?.content else { return nil }
            out.append(Candidate(id: id, accessKey: key))
        }
        return out
    }

    private func download(id: String, accessKey: String) async -> String? {
        let url = LyricsURL.make("https://lyrics.kugou.com/download", [
            ("fmt", "lrc"), ("charset", "utf8"), ("client", "pc"), ("ver", "1"), ("id", id), ("accesskey", accessKey),
        ])
        guard let body = await http.get(url) else { return nil }
        return Self.decodeDownload(body)
    }

    static func decodeDownload(_ body: String) -> String? {
        guard let root = LyricsJSON.parse(body)?.object else { return nil }
        let content = root["content"]?.content ?? ""
        guard let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else { return nil }
        return stripCredits(String(decoding: data, as: UTF8.self))
    }

    static func keyword(title: String, artist: String, album: String?) -> String {
        var out = stripParenthetical(title) + " - " + stripParenthetical(artist)
        if let album, !album.kIsBlank { out += " " + album }
        return out
    }

    private static func stripParenthetical(_ value: String) -> String {
        let stripped = parenthetical.replacing(in: value, with: "").kTrimmed
        return stripped.kIsBlank ? value : stripped
    }

    /// KuGou's lyric files open and close with uncredited lines — songwriter, composer,
    /// arranger — that carry a real timestamp and would otherwise be sung as the first and
    /// last lines of the song. Cut the same way the source client does: from either end, up
    /// to the first/last line matching "label: value", and only within the first and last 30
    /// lines so a legit lyric that happens to contain a colon deep in the song is left alone.
    static func stripCredits(_ text: String) -> String {
        let lines = text.kLines.filter { stamped.matches($0) }
        if lines.isEmpty { return "" }
        let headLimit = min(30, lines.count - 1)
        let headCut = (stride(from: headLimit, through: 0, by: -1).first { credit.matches(lines[$0]) }).map { $0 + 1 } ?? 0
        let body = Array(lines.dropFirst(headCut))
        let tailLimit = min(30, body.count - 1)
        let tailCut = tailLimit < 0 ? 0 : ((0...tailLimit).first { credit.matches(body[body.count - 1 - $0]) }).map { $0 + 1 } ?? 0
        return body.dropLast(tailCut).joined(separator: "\n")
    }

    private static let parenthetical = LyricsRegex(#"[(（].*?[)）]"#)
    private static let stamped = LyricsRegex(#"\[[0-9]{2}:[0-9]{2}\.[0-9]{2,3}\].*"#)
    private static let credit = LyricsRegex(#".+\][^\[]+[:：].+"#)
}
