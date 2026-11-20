import CommonCrypto
import Foundation
import VibraMusicCore

// Ports data/jiosaavn/JioSaavnService.kt.

/// One JioSaavn catalogue row (`search.getResults` / `song.getDetails`).
public struct JioSaavnSong: Decodable, Hashable, Sendable {
    public struct Artist: Hashable, Sendable {
        public var id: String
        public var name: String
    }

    public var id: String
    public var title: String
    public var image: String
    /// JioSaavn sends the string `"1"` or `"0"`.
    public var explicitContent: String
    public var album: String
    public var albumId: String
    public var encryptedMediaURL: String
    /// Seconds, as a string.
    public var duration: String
    /// Whether a 320 kbps rendition exists, as `"true"`/`"false"`. Stated per track and frequently
    /// false; asking the CDN for `_320` anyway does not produce one.
    public var has320: String
    public var primaryArtists: [Artist]

    public var isExplicit: Bool {
        explicitContent == "1" || explicitContent.lowercased() == "true"
    }

    public var supports320: Bool { has320.lowercased() == "true" }

    public init(id: String = "", title: String = "", explicitContent: String = "") {
        self.id = id
        self.title = title
        self.explicitContent = explicitContent
        image = ""
        album = ""
        albumId = ""
        encryptedMediaURL = ""
        duration = ""
        has320 = ""
        primaryArtists = []
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        id = c.lenientString("id") ?? ""
        // JioSaavn's API HTML-escapes text (`Tum Hi Ho (From &quot;Aashiqui 2&quot;)`). Android keeps
        // the entities; decoding them keeps `&amp;` from reaching the matcher as the word "amp".
        title = JioSaavnService.unescapeHTML(c.lenientString("title") ?? "")
        image = c.lenientString("image") ?? ""
        explicitContent = c.lenientString("explicit_content") ?? ""
        let more = (try? c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("more_info")))
        album = JioSaavnService.unescapeHTML(more?.lenientString("album") ?? "")
        albumId = more?.lenientString("album_id") ?? ""
        encryptedMediaURL = more?.lenientString("encrypted_media_url") ?? ""
        duration = more?.lenientString("duration") ?? ""
        has320 = more?.lenientString("320kbps") ?? ""
        var artists: [Artist] = []
        if let map = try? more?.nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey("artistMap")) {
            for entry in map.lenientArray("primary_artists", of: JSONValue.self) {
                guard let object = entry.objectValue else { continue }
                let name = JioSaavnService.unescapeHTML(object["name"]?.queryValue ?? "")
                artists.append(Artist(id: object["id"]?.queryValue ?? "", name: name))
            }
        }
        primaryArtists = artists
    }
}

/// A decoded CDN URL and the bitrate it will really deliver.
public struct JioSaavnStream: Hashable, Sendable {
    public var url: String
    public var kbps: Int?
}

/// JioSaavn's public web API: search and stream URLs, no account.
public struct JioSaavnService: Sendable {
    private let session: URLSession
    private let baseURL: URL

    /// `https://www.jiosaavn.com/api.php`, stored base64 as the Android build does.
    public static let defaultBaseURL = URL(
        string: String(decoding: Data(base64Encoded: "aHR0cHM6Ly93d3cuamlvc2Fhdm4uY29tL2FwaS5waHA=")!, as: UTF8.self)
    )!

    public init(session: URLSession = VibraMusicHTTP.session, baseURL: URL = JioSaavnService.defaultBaseURL) {
        self.session = session
        self.baseURL = baseURL
    }

    /// Up to ten songs for `query`; empty on any failure (logged), as on Android.
    public func searchSongs(_ query: String) async -> [JioSaavnSong] {
        do {
            let data = try await get([
                ("__call", "search.getResults"), ("q", query), ("p", "1"), ("n", "10"),
            ])
            return Self.parseSearch(data)
        } catch {
            if !(error is CancellationError) { SourcesLog.w("Saavn search error: \(error.localizedDescription)") }
            return []
        }
    }

    /// The best stream this track really has, or nil.
    public func streamURL(for songId: String) async -> JioSaavnStream? {
        do {
            let data = try await get([("__call", "song.getDetails"), ("pids", songId)])
            guard let song = Self.parseDetails(data) else {
                SourcesLog.w("Saavn getDetails held no song for \(songId)")
                return nil
            }
            return Self.bestStream(encryptedURL: song.encryptedMediaURL, supports320: song.supports320)
        } catch {
            if !(error is CancellationError) { SourcesLog.w("Saavn getDetails error: \(error.localizedDescription)") }
            return nil
        }
    }

    // MARK: Parsing (pure, for tests)

    static func parseSearch(_ data: Data) -> [JioSaavnSong] {
        struct Envelope: Decodable {
            var results: [JioSaavnSong]
            init(from decoder: Decoder) throws {
                results = try decoder.container(keyedBy: AnyCodingKey.self).lenientArray("results", of: JioSaavnSong.self)
            }
        }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.results ?? []
    }

    /// `song.getDetails` does not answer with the `{"songs":[…]}` envelope search uses: it answers
    /// with a map keyed by the id asked for, `{"5xceLLNe":{…}}`. Android once decoded it as the
    /// envelope and got nothing, silently. Both shapes are read.
    static func parseDetails(_ data: Data) -> JioSaavnSong? {
        guard let object = JSONValue.parse(data)?.objectValue else { return nil }
        let element: JSONValue?
        if let first = object["songs"]?.arrayValue?.first {
            element = first
        } else {
            element = SourceFormats.orderedKeys(data).lazy.compactMap { key -> JSONValue? in
                guard case .object = object[key] else { return nil }
                return object[key]
            }.first
        }
        guard let element, let encoded = try? JSONSerialization.data(withJSONObject: element.foundationValue) else { return nil }
        return try? JSONDecoder().decode(JioSaavnSong.self, from: encoded)
    }

    /// The best CDN URL a track really has. The rewrite to `_320` is conditional on the catalogue
    /// saying one exists: rewriting unconditionally fetched nothing better, and the old code then
    /// reported a flat 320 — a 96 kbps stream advertised as 320 cleared the upgrade bar against
    /// YouTube and swapped the listener *down*.
    static func bestStream(encryptedURL: String, supports320: Bool) -> JioSaavnStream? {
        selectBestStream(decryptedURL: decrypt(encryptedURL), supports320: supports320)
    }

    /// Selects the highest rendition without losing URL parameters. CDN URLs need not end at `.mp4`
    /// (cache-busting or access parameters may follow), and an unrecognised URL is never labelled
    /// 320 merely because the catalogue says that rendition exists.
    public static func selectBestStream(decryptedURL: String, supports320: Bool) -> JioSaavnStream? {
        guard decryptedURL.nonBlank != nil else { return nil }
        let pattern = Pattern(#"_(48|96|160|320)\.(mp4|aac|mp3)(?=[?#]|$)"#, caseInsensitive: true)
        guard let match = pattern.firstMatch(in: decryptedURL),
              let whole = Range(match.range, in: decryptedURL),
              let rateRange = Range(match.range(at: 1), in: decryptedURL),
              let extRange = Range(match.range(at: 2), in: decryptedURL),
              let offered = Int(decryptedURL[rateRange]) else {
            return JioSaavnStream(url: decryptedURL, kbps: nil)
        }
        guard supports320 else { return JioSaavnStream(url: decryptedURL, kbps: offered) }
        var upgraded = decryptedURL
        upgraded.replaceSubrange(whole, with: "_320.\(decryptedURL[extRange])")
        return JioSaavnStream(url: upgraded, kbps: 320)
    }

    /// `encrypted_media_url` is DES-ECB (PKCS#5) under the public key `38346591`, base64-encoded.
    static func decrypt(_ encrypted: String) -> String {
        guard encrypted.nonBlank != nil,
              let input = Data(base64Encoded: encrypted, options: .ignoreUnknownCharacters) else { return "" }
        let key = Array("38346591".utf8)
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeDES)
        var produced = 0
        let status = input.withUnsafeBytes { raw in
            CCCrypt(
                CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                key, kCCKeySizeDES, nil,
                raw.baseAddress, input.count,
                &output, output.count, &produced
            )
        }
        guard status == kCCSuccess else {
            SourcesLog.e("JioSaavn URL decryption failed (\(status))")
            return ""
        }
        return String(decoding: output.prefix(produced), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Put uncensored rows ahead of their clean duplicates, stably.
    public static func prioritizeExplicit(_ songs: [JioSaavnSong]) -> [JioSaavnSong] {
        songs.filter(\.isExplicit) + songs.filter { !$0.isExplicit }
    }

    static func unescapeHTML(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        for (entity, character) in [("&quot;", "\""), ("&#039;", "'"), ("&#39;", "'"), ("&apos;", "'"),
                                    ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result
    }

    // MARK: Transport

    private func get(_ call: [(String, String)]) async throws -> Data {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let common: [(String, String)] = [("_format", "json"), ("_marker", "0"), ("api_version", "4"), ("ctx", "android")]
        components.queryItems = (call.prefix(1) + common + call.dropFirst()).map { URLQueryItem(name: $0.0, value: $0.1) }
        // `+` must not reach the server as a space-meaning literal.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = Self.requestTimeout
        for (name, value) in Self.headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await withDeadline(Self.requestTimeout) { [session, request] in
            try await session.data(for: request)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard status == 200 else { throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"]) }
        return data
    }

    /// Android's ktor client: 6 s per request. JioSaavn answers in about 0.4 s when it answers.
    static let requestTimeout: TimeInterval = 6

    /// The headers Android sends. The Indian forwarded-for address keeps the catalogue answering
    /// with the Indian rights set; `explicit_content=1` returns uncensored rows.
    static let headers: [(String, String)] = [
        ("Accept", "application/json"),
        ("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36"),
        ("X-Forwarded-For", "49.36.0.1"),
        ("X-Real-IP", "49.36.0.1"),
        ("Accept-Language", "en-IN,en;q=0.9"),
        ("Cookie", "explicit_content=1"),
    ]
}

extension JSONValue {
    /// The value as Foundation objects, for re-encoding a sub-tree.
    var foundationValue: Any {
        switch self {
        case .string(let text): return text
        case .number(let number): return number
        case .bool(let flag): return flag
        case .array(let items): return items.map(\.foundationValue)
        case .object(let object): return object.mapValues(\.foundationValue)
        case .null: return NSNull()
        }
    }
}
