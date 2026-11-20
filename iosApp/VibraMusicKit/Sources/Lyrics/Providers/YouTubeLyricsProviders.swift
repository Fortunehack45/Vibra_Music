import VibraMusicCore
import Foundation

/// The three InnerTube calls the YouTube lyric sources make, returning raw JSON bodies.
///
/// This module does not depend on the InnerTube module: `LyricsWebRemixClient` below makes
/// these requests itself, anonymously. The app can pass its own implementation instead
/// (backed by the InnerTube module's signed-in client) to `LyricsRepository`, which is what
/// lets the Lyrics tab of a signed-in session be read the same way the Android app reads it.
public protocol LyricsInnerTubeClient: Sendable {
    /// `next` for the video, as the player asks for it (the "RDAMVM" radio queue).
    func next(videoId: String) async throws -> Data
    /// `browse` for an id and optional params.
    func browse(browseId: String, params: String?) async throws -> Data
    /// `get_transcript` for the video.
    func transcript(videoId: String) async throws -> Data
}

/// A minimal anonymous YouTube Music (`WEB_REMIX`) client for the lyric sources.
///
/// Mirrors the request Android's `Innertube.postMusic` builds for a signed-out user: the
/// same endpoint, context, client name/version headers and origin, with the visitor id the
/// first response mints reused for the rest of the session.
public actor LyricsWebRemixClient: LyricsInnerTubeClient {
    private static let base = "https://music.youtube.com/youtubei/v1"
    private static let origin = "https://music.youtube.com"
    /// Android's fallback `WEB_REMIX` version; accepted as of September 2026.
    public static let defaultClientVersion = "1.20250101.01.00"

    private let http: LyricsHTTP
    private let clientVersion: String
    private let language: String
    private var visitorData: String?

    public init(session: URLSession = VibraMusicHTTP.session, clientVersion: String = defaultClientVersion, language: String = "en") {
        http = LyricsHTTP(session: session)
        self.clientVersion = clientVersion
        self.language = language
    }

    public func next(videoId: String) async throws -> Data {
        try await post("next", ["videoId": .string(videoId), "playlistId": .string("RDAMVM" + videoId), "isAudioOnly": .bool(true)])
    }

    public func browse(browseId: String, params: String?) async throws -> Data {
        var body: [String: LyricsJSON] = ["browseId": .string(browseId)]
        if let params { body["params"] = .string(params) }
        return try await post("browse", body)
    }

    public func transcript(videoId: String) async throws -> Data {
        try await post("get_transcript", ["params": .string(Self.transcriptParams(videoId))])
    }

    /// `get_transcript` expects a tiny protobuf: field 1, length, video id.
    static func transcriptParams(_ videoId: String) -> String {
        let id = Array(videoId.utf8)
        return Data([10, UInt8(truncatingIfNeeded: id.count)] + id).base64EncodedString()
    }

    private func post(_ endpoint: String, _ extras: [String: LyricsJSON]) async throws -> Data {
        var client = LyricsJSONObject()
        client["clientName"] = .string("WEB_REMIX")
        client["clientVersion"] = .string(clientVersion)
        client["hl"] = .string(language)
        client["gl"] = .string("US")
        if let visitorData { client["visitorData"] = .string(visitorData) }
        var user = LyricsJSONObject()
        user["lockedSafetyMode"] = .bool(false)
        var request = LyricsJSONObject()
        request["useSsl"] = .bool(true)
        var context = LyricsJSONObject()
        context["client"] = .object(client)
        context["user"] = .object(user)
        context["request"] = .object(request)
        var body = LyricsJSONObject()
        body["context"] = .object(context)
        for key in extras.keys.sorted() { body[key] = extras[key] }

        var headers = [
            "X-Origin": Self.origin,
            "Origin": Self.origin,
            "Referer": Self.origin + "/",
            "X-YouTube-Client-Name": "67",
            "X-YouTube-Client-Version": clientVersion,
            "Accept-Language": language == "en" ? "en-US,en;q=0.9" : "\(language),en-US;q=0.8,en;q=0.7",
        ]
        if let visitorData { headers["X-Goog-Visitor-Id"] = visitorData }
        let url = URL(string: Self.base + "/" + endpoint + "?prettyPrint=false&hl=" + LyricsURL.encodeQueryComponent(language))!
        let text = try await http.postJSON(url, body: Data(LyricsJSON.object(body).serialized.utf8), headers: headers, deadline: 15)
        if visitorData == nil, let minted = LyricsJSON.parse(text)?["responseContext"]?["visitorData"]?.content {
            visitorData = minted
        }
        return Data(text.utf8)
    }
}

// MARK: - YouTube Music's Lyrics tab

/// Lyrics exposed by YouTube Music's Lyrics tab for the exact playing video (plain text).
public struct YouTubeMusicLyricsProvider: LyricsProvider {
    private let client: any LyricsInnerTubeClient

    public init(client: any LyricsInnerTubeClient) {
        self.client = client
    }

    public func lyrics(for request: LyricsProviderRequest) async throws -> LyricsProviderAnswer? {
        await lyrics(videoId: request.videoId)?.answer
    }

    public func lyrics(videoId: String) async -> [LyricLine]? {
        guard youTubeID.matches(videoId),
              let next = try? await client.next(videoId: videoId),
              let endpoint = Self.lyricsBrowseEndpoint(inNext: LyricsYouTubeJSON.decode(next)),
              let page = try? await client.browse(browseId: endpoint.browseId, params: endpoint.params)
        else { return nil }
        return Self.lines(inBrowse: LyricsYouTubeJSON.decode(page))
    }

    /// The Lyrics tab's browse endpoint: the tab titled "Lyrics", or — when the interface
    /// language names it something else — the first endpoint after the first tab.
    static func lyricsBrowseEndpoint(inNext next: LyricsJSON?) -> (browseId: String, params: String?)? {
        guard let next else { return nil }
        let tabs = next.objects(named: "tabRenderer")
        let endpoint = tabs.first(where: { $0.youtubeStrings.contains { $0.kEqualsIgnoreCase("Lyrics") } })?
            .objects(named: "browseEndpoint").first
            ?? tabs.dropFirst().lazy.compactMap { $0.objects(named: "browseEndpoint").first }.first
        guard let endpoint, let browseId = endpoint["browseId"]?.primitiveContent else { return nil }
        return (browseId, endpoint["params"]?.primitiveContent)
    }

    static func lines(inBrowse page: LyricsJSON?) -> [LyricLine]? {
        guard let shelf = page?.objects(named: "musicDescriptionShelfRenderer").first else { return nil }
        let text = (shelf["description"]?.youtubeStrings.joined() ?? "").kTrimmed
        return text.kLines.map(\.kTrimmed).filter { !$0.isEmpty }.map { LyricLine(timeMs: 0, text: $0) }.nonEmpty
    }
}

// MARK: - Timed captions

/// Timed YouTube transcript/captions for the exact playing video.
///
/// As of September 2026 YouTube answers this request with `400 INVALID_ARGUMENT` for every
/// video tried (and the web client's own transcript params with `FAILED_PRECONDITION`), on
/// Android as much as here; the source stays so it works again the day that changes, and
/// misses cleanly until then.
public struct YouTubeTranscriptLyricsProvider: LyricsProvider {
    private let client: any LyricsInnerTubeClient

    public init(client: any LyricsInnerTubeClient) {
        self.client = client
    }

    public func lyrics(for request: LyricsProviderRequest) async throws -> LyricsProviderAnswer? {
        await lyrics(videoId: request.videoId)?.answer
    }

    public func lyrics(videoId: String) async -> [LyricLine]? {
        guard youTubeID.matches(videoId), let response = try? await client.transcript(videoId: videoId) else { return nil }
        return Self.lines(inTranscript: LyricsYouTubeJSON.decode(response))
    }

    static func lines(inTranscript response: LyricsJSON?) -> [LyricLine]? {
        guard let response else { return nil }
        let lines = response.objects(named: "transcriptCueRenderer").compactMap { cue -> LyricLine? in
            guard let start = cue["startOffsetMs"]?.primitiveLong else { return nil }
            let text = (cue["cue"]?.youtubeStrings.joined() ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " \n♪"))
            return text.isEmpty ? nil : LyricLine(timeMs: start, text: text)
        }
        return lines.kSortedBy(\.timeMs).nonEmpty
    }
}

private let youTubeID = LyricsRegex("[A-Za-z0-9_-]{11}")

enum LyricsYouTubeJSON {
    static func decode(_ data: Data) -> LyricsJSON? {
        LyricsJSON.parse(String(decoding: data, as: UTF8.self))
    }
}

extension LyricsJSON {
    /// Every object stored under `name`, at any depth, in document order.
    func objects(named name: String) -> [LyricsJSON] {
        var found = [LyricsJSON]()
        func walk(_ element: LyricsJSON) {
            switch element {
            case .object(let object):
                for (key, value) in object.entries {
                    if key == name, value.object != nil { found.append(value) }
                    walk(value)
                }
            case .array(let values):
                values.forEach(walk)
            default:
                break
            }
        }
        walk(self)
        return found
    }

    /// Every string in a YouTube text object, in order: `text`/`simpleText` where present,
    /// otherwise everything beneath (`runs[].text`).
    var youtubeStrings: [String] {
        switch self {
        case .array(let values):
            return values.flatMap(\.youtubeStrings)
        case .object(let object):
            if let direct = object["text"]?.primitiveContent ?? object["simpleText"]?.primitiveContent { return [direct] }
            return object.values.flatMap(\.youtubeStrings)
        default:
            return content.map { [$0] } ?? []
        }
    }

    fileprivate var primitiveContent: String? { isPrimitive ? content : nil }
    fileprivate var primitiveLong: Int? { isPrimitive ? long : nil }
}
