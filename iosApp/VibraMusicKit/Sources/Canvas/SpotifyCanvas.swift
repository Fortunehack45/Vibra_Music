import VibraMusicCore
import Foundation

/// Spotify's own Canvas — the feature the other providers are named after (Android:
/// `SpotifyCanvas` in `data/canvas/SpotifyCanvas.kt`).
///
/// There is no public API for it. The web player fetches it from an internal endpoint
/// (`canvaz-cache`) using protobuf over HTTP, authenticated with a bearer token minted from
/// the listener's own session — see `CanvasSpotifyTokenStore`. That means this source is the
/// one of the four that needs the listener to hand something over first (Settings > their
/// `sp_dc` session cookie); with no cookie set the token store returns nil before any request
/// is made, so this is a free no-op until then.
///
/// The wire format is hand-rolled rather than generated: the message shapes are tiny — one
/// string in, a handful of strings out — and pulling in a protobuf dependency for two fields
/// is not worth it. Field numbers below are Spotify's own, not chosen here; get them wrong
/// and the response silently parses to nothing rather than failing loudly.
public struct SpotifyCanvas: Sendable {
    static let searchEndpoint = "https://api.spotify.com/v1/search"
    static let albumTracksEndpoint = "https://api.spotify.com/v1/albums"
    static let canvasEndpoint = URL(string: "https://spclient.wg.spotify.com/canvaz-cache/v0/canvases")!
    static let pathfinderEndpoint = "https://api-partner.spotify.com/pathfinder/v1/query"

    /// The persisted query id for the web player's own track search.
    static let pathfinderSearchHash =
        "bc1ca2fcd0ba1013a0fc88e6cc4f190af501851e3dafd3e1ef85840297694428"

    /// spclient gates this path to Spotify's own apps by user agent; the web player's own UA
    /// is turned away, so this wears a mobile client's instead.
    static let appUserAgent = "Spotify/9.0.34.593 iOS/18.4 (iPhone15,3)"

    struct TrackHit: Sendable {
        var uri: String
        var title: String
        var artist: String
        var album: String?
    }

    private let http: CanvasHTTP
    private let tokens: CanvasSpotifyTokenStore
    /// The live `canvas` query hash, read off the web player's own scripts.
    private let queryHashes: CanvasQueryHashes

    public init(session: URLSession = VibraMusicHTTP.session, tokens: CanvasSpotifyTokenStore) {
        let http = CanvasHTTP(session: session)
        self.http = http
        self.tokens = tokens
        queryHashes = CanvasQueryHashes { url in
            await http.get(URL(string: url), headers: ["User-Agent": CanvasHTTP.userAgent])
        }
    }

    /// A canvas source with no token store (no `sp_dc` cookie): every lookup misses without
    /// touching the network.
    public init(session: URLSession = VibraMusicHTTP.session) {
        self.init(session: session, tokens: CanvasSpotifyTokenStore(session: session))
    }

    public func search(title: String, artist: String, album: String?) async -> CanvasArtwork? {
        guard let token = await tokens.accessToken() else {
            canvasLogDebug("SpotifyCanvas: no access token (cookie unset or mint failed); skipping")
            return nil
        }

        // Pathfinder first: it's the search the web player's own search box calls, and in
        // practice the one this kind of token is reliably let near — the plain REST endpoint
        // below answers some requests and 429s others in a pattern that hasn't been possible
        // to pin down from outside Spotify. Kept as the fallback rather than dropped, since a
        // client token failing to mint takes Pathfinder down with it but leaves REST still
        // reachable.
        let hit: TrackHit?
        if let pathfinderHit = await searchViaPathfinder(title: title, artist: artist, album: album, token: token) {
            hit = pathfinderHit
        } else {
            hit = await searchViaRest(title: title, artist: artist, album: album, token: token)
        }
        guard let hit else {
            canvasLogDebug("SpotifyCanvas: no canvas for '\(title)' by '\(artist)' (no matching track found)")
            return nil
        }

        guard let canvasURL = await fetchCanvasURL(trackURI: hit.uri, token: token) else {
            canvasLogDebug("SpotifyCanvas: no canvas for '\(title)' by '\(artist)' (matched '\(hit.title)', no clip)")
            return nil
        }
        canvasLogDebug("SpotifyCanvas: canvas for '\(hit.title)' by '\(hit.artist)'")
        return CanvasArtwork(
            url: canvasURL, title: hit.title, artist: hit.artist, album: hit.album,
            source: .spotify)
    }

    /// Re-checks the hit the way `searchViaRest` does, as far as the response lets it. The
    /// GraphQL track carries `name` and `artists.items[].profile.name`; when they are there they
    /// must agree with the query, and a first result that doesn't is dropped so the REST search
    /// gets a turn. A response without them (the shape isn't published) is still trusted on
    /// Spotify's own ranking, as `firstTrackURI` trusts an album's track listing.
    func searchViaPathfinder(title: String, artist: String, album: String?, token: String) async -> TrackHit? {
        guard let clientToken = await tokens.clientToken() else {
            canvasLogDebug("SpotifyCanvas: no client token; skipping pathfinder search")
            return nil
        }
        let searchTerm = [title, artist, album].compactMap { $0 }.joined(separator: " ")
        let variables = """
        {"searchTerm":"\(Self.jsonEscaped(searchTerm))","offset":0,"limit":10,\
        "numberOfTopResults":5,"includeAudiobooks":false,"includePreReleases":false}
        """
        let extensions = """
        {"persistedQuery":{"version":1,"sha256Hash":"\(Self.pathfinderSearchHash)"}}
        """
        guard let url = CanvasURL.make(Self.pathfinderEndpoint, [
            ("operationName", "searchTracks"), ("variables", variables), ("extensions", extensions),
        ]) else { return nil }

        let headers = [
            "Authorization": "Bearer \(token)",
            "Client-Token": clientToken,
            "App-platform": "WebPlayer",
            "Accept": "application/json",
            "User-Agent": CanvasHTTP.userAgent,
        ]
        let (code, body) = await http.getWithStatus(url, headers: headers)
        guard let body else {
            canvasLogWarning("SpotifyCanvas: pathfinder search failed, http \(code)")
            return nil
        }
        guard let parsed = CanvasJSON.parse(body)?.object,
              let firstItem = parsed["data"]?.object?["searchV2"]?.object?["tracksV2"]?.object?["items"]?.array?.first?.object?["item"]?.object?["data"]?.object
        else {
            canvasLogWarning("SpotifyCanvas: pathfinder response had no hit (http \(code)): \(body.prefix(200))")
            return nil
        }
        let uri = firstItem["uri"]?.string
            ?? firstItem["id"]?.string.map { "spotify:track:\($0)" }
        guard let uri else {
            canvasLogWarning("SpotifyCanvas: pathfinder hit had neither uri nor id")
            return nil
        }
        var hitTitle = title
        var hitArtist = artist
        if let name = firstItem["name"]?.string {
            let credited = firstItem["artists"]?.object?["items"]?.array?
                .compactMap { $0.object?["profile"]?.object?["name"]?.string } ?? []
            // No credited artists in the response: check the name alone.
            let matches = credited.isEmpty
                ? name.normalizedForCanvasMatch == title.normalizedForCanvasMatch
                : Self.isMatch(gotName: name, gotArtists: credited, wantName: title, wantArtist: artist)
            if !matches {
                canvasLogDebug("SpotifyCanvas: pathfinder's top hit '\(name)' isn't '\(title)'; trying REST")
                return nil
            }
            hitTitle = name
            if !credited.isEmpty { hitArtist = credited.joined(separator: ", ") }
        }
        return TrackHit(uri: uri, title: hitTitle, artist: hitArtist, album: album)
    }

    func searchViaRest(title: String, artist: String, album: String?, token: String) async -> TrackHit? {
        let query = [title, artist, album].compactMap { $0 }.joined(separator: " ")
        guard let url = CanvasURL.make(Self.searchEndpoint, [
            ("q", query), ("type", "track"), ("limit", "10"),
        ]) else { return nil }

        let (code, body) = await http.getWithStatus(url, headers: authHeaders(token: token))
        guard let body else {
            canvasLogWarning("SpotifyCanvas: search request failed, http \(code)")
            return nil
        }
        guard let root = CanvasJSON.parse(body)?.object else {
            canvasLogWarning("SpotifyCanvas: search response wasn't JSON (http \(code))")
            return nil
        }
        guard let items = root["tracks"]?.object?["items"]?.array else {
            canvasLogWarning("SpotifyCanvas: search response had no tracks.items (http \(code)): \(body.prefix(200))")
            return nil
        }

        for item in items {
            guard let track = item.object else { continue }
            guard let trackTitle = track["name"]?.string else { continue }
            let artists = track["artists"]?.array?.compactMap { $0.object?["name"]?.string } ?? []
            if !Self.isMatch(gotName: trackTitle, gotArtists: artists, wantName: title, wantArtist: artist) {
                continue
            }
            guard let uri = track["uri"]?.string else { continue }
            let albumName = track["album"]?.object?["name"]?.string
            return TrackHit(
                uri: uri, title: trackTitle,
                artist: artists.joined(separator: ", ").nilIfBlankForCanvas ?? artist,
                album: albumName)
        }
        return nil
    }

    /// A release's canvas, read off its first track — Spotify hangs Canvas off individual
    /// tracks, not the release itself, so there is no album-level lookup to make directly.
    public func searchAlbum(album: String, artist: String) async -> CanvasArtwork? {
        guard let token = await tokens.accessToken() else { return nil }
        guard let url = CanvasURL.make(Self.searchEndpoint, [
            ("q", "\(album) \(artist)"), ("type", "album"), ("limit", "10"),
        ]) else { return nil }

        guard let body = await http.get(url, headers: authHeaders(token: token)) else { return nil }
        guard let items = CanvasJSON.parse(body)?.object?["albums"]?.object?["items"]?.array
        else { return nil }

        for item in items {
            guard let record = item.object else { continue }
            guard let recordTitle = record["name"]?.string else { continue }
            let artists = record["artists"]?.array?.compactMap { $0.object?["name"]?.string } ?? []
            if !Self.isMatch(gotName: recordTitle, gotArtists: artists, wantName: album, wantArtist: artist) {
                continue
            }
            guard let albumId = record["id"]?.string,
                  let trackURI = await firstTrackURI(albumId: albumId, token: token),
                  let canvasURL = await fetchCanvasURL(trackURI: trackURI, token: token)
            else { continue }

            canvasLogDebug("SpotifyCanvas: canvas for album '\(recordTitle)' by \(artists.joined(separator: ", "))")
            return CanvasArtwork(
                url: canvasURL, title: recordTitle,
                artist: artists.joined(separator: ", ").nilIfBlankForCanvas ?? artist,
                album: recordTitle, source: .spotify)
        }
        return nil
    }

    func firstTrackURI(albumId: String, token: String) async -> String? {
        guard let url = CanvasURL.make("\(Self.albumTracksEndpoint)/\(albumId)/tracks", [("limit", "1")])
        else { return nil }
        guard let body = await http.get(url, headers: authHeaders(token: token)) else { return nil }
        return CanvasJSON.parse(body)?.object?["items"]?.array?.first?.object?["uri"]?.string
    }

    /// `clientToken` on top of the bearer — api.spotify.com and spclient both turn away a
    /// request carrying only the bearer with a 429, which reads exactly like rate limiting on
    /// the very first request of a session until you notice that's what it always says. Sent
    /// whenever minting one succeeds; omitted otherwise rather than failing the call, since
    /// some of these endpoints still answer without it.
    func authHeaders(token: String) async -> [String: String] {
        var headers = ["Authorization": "Bearer \(token)", "User-Agent": CanvasHTTP.userAgent]
        if let clientToken = await tokens.clientToken() {
            headers["Client-Token"] = clientToken
        }
        return headers
    }

    static func isMatch(
        gotName: String, gotArtists: [String], wantName: String, wantArtist: String
    ) -> Bool {
        if gotName.normalizedForCanvasMatch != wantName.normalizedForCanvasMatch { return false }
        let wanted = canvasSplitArtists(wantArtist)
        let credited = gotArtists.map(\.normalizedForCanvasMatch).filter { !$0.isBlankForCanvas }
        if wanted.isEmpty || credited.isEmpty { return false }
        return wanted.allSatisfy { want in credited.contains(want) }
    }

    struct CanvasHit: Sendable {
        var id: String?
        var url: String
        var trackURI: String?
    }

    // MARK: - Pathfinder: the `canvas` GraphQL query

    /// The track's canvas, asked for the way the current web player does; the older
    /// `canvaz-cache` endpoint when that query fails outright, or answers with no playable clip
    /// (a video canvas can come back there in a shape this can't play while canvaz-cache still
    /// hands out the plain `.cnvs.mp4`).
    func fetchCanvasURL(trackURI: String, token: String) async -> String? {
        switch await fetchCanvasViaPathfinder(trackURI: trackURI, token: token) {
        case .found(let url, let type):
            canvasLogDebug("SpotifyCanvas: pathfinder canvas (\(type ?? "no type")) for \(trackURI)")
            return url
        case .noCanvas(let detail):
            canvasLogDebug("SpotifyCanvas: pathfinder: no playable canvas for \(trackURI) (\(detail)); trying canvaz-cache")
            return await fetchCanvasViaCanvaz(trackURI: trackURI, token: token)
        case .failed(let reason, _):
            canvasLogWarning("SpotifyCanvas: pathfinder canvas query failed (\(reason)); trying canvaz-cache")
            return await fetchCanvasViaCanvaz(trackURI: trackURI, token: token)
        }
    }

    func fetchCanvasViaPathfinder(
        trackURI: String, token: String, isRetry: Bool = false
    ) async -> SpotifyCanvasQuery.Answer {
        let hash = await queryHashes.canvasHash(forceRefresh: isRetry)
        var headers = await authHeaders(token: token)
        headers["App-platform"] = "WebPlayer"
        headers["Accept"] = "application/json"
        headers["Accept-Language"] = "en"
        headers["Content-Type"] = "application/json"
        let (status, bytes) = await http.post(
            URL(string: SpotifyCanvasQuery.endpoint), headers: headers,
            body: SpotifyCanvasQuery.requestBody(trackURI: trackURI, hash: hash))
        guard let bytes else { return .failed(reason: "http \(status)") }

        let answer = SpotifyCanvasQuery.parse(CanvasHTTP.decode(bytes))
        // A rebuilt web player retires the old hash: look it up again once.
        if case .failed(_, true) = answer, !isRetry {
            return await fetchCanvasViaPathfinder(trackURI: trackURI, token: token, isRetry: true)
        }
        return answer
    }

    // MARK: - canvaz-cache: protobuf request/response (fallback)

    func fetchCanvasViaCanvaz(trackURI: String, token: String) async -> String? {
        let body = Self.encodeCanvasRequest(trackURI: trackURI)
        var headers = await authHeaders(token: token)
        headers["Accept"] = "application/protobuf"
        headers["Accept-Language"] = "en"
        headers["User-Agent"] = Self.appUserAgent
        headers["Content-Type"] = "application/protobuf"

        let (status, bytes) = await http.postBytes(Self.canvasEndpoint, headers: headers, body: body)
        guard let bytes else {
            canvasLogWarning("SpotifyCanvas: canvaz-cache http \(status) for \(trackURI)")
            return nil
        }

        // The structured parse first — it can tell this track's own clip apart from another one
        // Spotify bundled in the same response. The regex is the fallback: it only needs a
        // *.cnvs.mp4 URL to be sitting somewhere in the bytes as a plain string, so it still
        // finds a clip if a field number above turns out to be stale even though the search
        // above already picked the right track.
        let hits = Self.decodeCanvasResponse(bytes)
        if let own = hits.first(where: { $0.trackURI == trackURI }) { return own.url }
        // Clips Spotify bundled for other tracks, none of them this one's: that is a miss, not a
        // clip to borrow (the regex below would find the same wrong URL).
        if hits.contains(where: { $0.trackURI != nil }) {
            canvasLogDebug("SpotifyCanvas: canvaz-cache only had other tracks' clips for \(trackURI)")
            return nil
        }
        if let unattributed = hits.first?.url { return unattributed }

        let fallback = Self.canvasURL(in: bytes)
        if fallback == nil {
            canvasLogDebug("SpotifyCanvas: canvaz-cache had nothing for \(trackURI)")
        } else {
            canvasLogDebug("SpotifyCanvas: canvaz-cache url recovered by regex fallback for \(trackURI)")
        }
        return fallback
    }

    /// `CanvasRequest { repeated Track tracks = 1; Track { string track_uri = 1; } }`
    static func encodeCanvasRequest(trackURI: String) -> Data {
        var track = Data()
        track.append(Self.protobufField(field: 1, wireType: 2))
        track.append(Self.protobufString(trackURI))
        var request = Data()
        request.append(Self.protobufField(field: 1, wireType: 2))
        request.append(Self.protobufBytes(track))
        return request
    }

    /// `CanvasResponse { repeated Canvas canvases = 1; }`, `Canvas { id = 1; canvas_url = 2;
    /// ...; track_uri = 5; ... }` — only the fields this needs are read, everything else is
    /// skipped rather than modelled.
    static func decodeCanvasResponse(_ bytes: Data) -> [CanvasHit] {
        var hits: [CanvasHit] = []
        var reader = CanvasProtoReader(bytes)
        while !reader.isAtEnd {
            guard let (field, wireType) = reader.readTag() else { break }
            if field == 1, wireType == 2, let nested = reader.readBytes() {
                if let hit = decodeCanvas(nested) { hits.append(hit) }
            } else {
                reader.skipField(wireType: wireType)
            }
        }
        return hits
    }

    static func decodeCanvas(_ bytes: Data) -> CanvasHit? {
        var id: String?
        var url: String?
        var trackURI: String?
        var reader = CanvasProtoReader(bytes)
        while !reader.isAtEnd {
            guard let (field, wireType) = reader.readTag() else { break }
            switch (field, wireType) {
            case (1, 2): id = reader.readString()
            case (2, 2): url = reader.readString()
            case (5, 2): trackURI = reader.readString()
            default: reader.skipField(wireType: wireType)
            }
        }
        guard let url else { return nil }
        return CanvasHit(id: id, url: url, trackURI: trackURI)
    }

    /// Any `https://…​.cnvs.mp4` URL sitting in the response bytes as a plain string.
    static func canvasURL(in bytes: Data) -> String? {
        guard let text = String(data: bytes, encoding: .isoLatin1) else { return nil }
        guard let regex = try? NSRegularExpression(pattern: "https://[^\"'\\s\\x00-\\x1F]+\\.cnvs\\.mp4"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text)
        else { return nil }
        return String(text[range])
    }

    // MARK: - Minimal protobuf wire codec

    static func protobufField(field: Int, wireType: Int) -> Data {
        varint(UInt64(field << 3 | wireType))
    }

    static func protobufString(_ value: String) -> Data {
        protobufBytes(Data(value.utf8))
    }

    static func protobufBytes(_ value: Data) -> Data {
        varint(UInt64(value.count)) + value
    }

    static func varint(_ value: UInt64) -> Data {
        var value = value
        var out = Data()
        while value >= 0x80 {
            out.append(UInt8(value & 0x7F | 0x80))
            value >>= 7
        }
        out.append(UInt8(value))
        return out
    }

    private static func jsonEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

/// A minimal protobuf wire reader: tags, varints, length-delimited fields and skipping.
/// Only what the canvaz-cache response needs — no groups, no fixed64 beyond skipping.
struct CanvasProtoReader {
    private let bytes: Data
    private(set) var offset: Data.Index

    init(_ bytes: Data) {
        self.bytes = bytes
        offset = bytes.startIndex
    }

    var isAtEnd: Bool { offset >= bytes.endIndex }

    mutating func readTag() -> (field: Int, wireType: Int)? {
        guard let tag = readVarint(), tag != 0 else { return nil }
        return (Int(tag >> 3), Int(tag & 0x7))
    }

    mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift = 0
        while offset < bytes.endIndex {
            let byte = bytes[offset]
            offset = bytes.index(after: offset)
            if shift < 64 {
                result |= UInt64(byte & 0x7F) << shift
            }
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift >= 70 { return nil }
        }
        return nil
    }

    mutating func readBytes() -> Data? {
        guard let count = readVarint(), count <= UInt64(bytes.endIndex - offset) else { return nil }
        let end = bytes.index(offset, offsetBy: Int(count))
        let slice = bytes[offset..<end]
        offset = end
        return Data(slice)
    }

    mutating func readString() -> String? {
        readBytes().flatMap { String(data: $0, encoding: .utf8) }
    }

    mutating func skipField(wireType: Int) {
        switch wireType {
        case 0: _ = readVarint()
        case 1: advance(by: 8)
        case 2: _ = readBytes()
        case 5: advance(by: 4)
        default: offset = bytes.endIndex
        }
    }

    private mutating func advance(by count: Int) {
        offset = bytes.index(offset, offsetBy: count, limitedBy: bytes.endIndex) ?? bytes.endIndex
    }
}

private extension String {
    var nilIfBlankForCanvas: String? {
        isBlankForCanvas ? nil : self
    }
}
