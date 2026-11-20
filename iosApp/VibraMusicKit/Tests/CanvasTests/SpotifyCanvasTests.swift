import VibraMusicTestSupport
import XCTest
@testable import Canvas

/// Spotify Canvas against recorded search answers, plus the hand-rolled protobuf codec and the
/// token-harvest parsing (ported from `data/canvas/SpotifyCanvas.kt` and `SpotifyToken.kt`).
final class SpotifyCanvasTests: XCTestCase {
    private func canvas(
        _ stub: URLProtocolStub, harvester: StubCanvasHarvester? = nil
    ) -> (SpotifyCanvas, CanvasSpotifyTokenStore) {
        let session = stub.makeSession()
        let tokens = CanvasSpotifyTokenStore(
            session: session, cookie: { "sp_dc=test-cookie" }, harvester: harvester)
        return (SpotifyCanvas(session: session, tokens: tokens), tokens)
    }

    private func harvester() -> StubCanvasHarvester {
        StubCanvasHarvester(harvested: CanvasHarvestedToken(
            token: "test-access-token", expiresAt: .distantFuture, clientId: "test-client-id"))
    }

    /// Encodes a canvaz-cache response the way Spotify sends it: field 1 = canvas messages,
    /// each with id = 1, canvas_url = 2, track_uri = 5.
    private func canvazResponse(url: String, trackURI: String) -> Data {
        var canvas = Data()
        canvas.append(SpotifyCanvas.protobufField(field: 1, wireType: 2))
        canvas.append(SpotifyCanvas.protobufString("canvas-id-1"))
        canvas.append(SpotifyCanvas.protobufField(field: 2, wireType: 2))
        canvas.append(SpotifyCanvas.protobufString(url))
        canvas.append(SpotifyCanvas.protobufField(field: 5, wireType: 2))
        canvas.append(SpotifyCanvas.protobufString(trackURI))
        var response = Data()
        response.append(SpotifyCanvas.protobufField(field: 1, wireType: 2))
        response.append(SpotifyCanvas.protobufBytes(canvas))
        return response
    }

    func testRestSearchSkipsTheWrongArtistThenFetchesTheCanvas() async throws {
        let stub = URLProtocolStub()
        try canvasRoute(stub, host: "api.spotify.com", path: "/v1/search",
                        fixture: "spotify-search-tracks.json")
        stub.register(host: "clienttoken.spotify.com", response: .status(400))
        let canvasURL = "https://example.com/spotify-canvas/abc.cnvs.mp4"
        stub.register(host: "spclient.wg.spotify.com", path: "/canvaz-cache/v0/canvases") { _ in
            .data(self.canvazResponse(url: canvasURL, trackURI: "spotify:track:0VjIjW4GlUZAMYd2vXMi3b"))
        }
        let (canvas, _) = self.canvas(stub, harvester: harvester())

        let found = await canvas.search(title: "Blinding Lights", artist: "The Weeknd", album: "After Hours")
        let artwork = try XCTUnwrap(found)
        XCTAssertEqual(artwork.url, canvasURL)
        XCTAssertEqual(artwork.title, "Blinding Lights")
        XCTAssertEqual(artwork.artist, "The Weeknd")
        XCTAssertEqual(artwork.source, .spotify)
    }

    func testPathfinderHitIsTrustedWithoutReChecking() async throws {
        let stub = URLProtocolStub()
        let config = Data("{\"clientVersion\":\"1.2.3\"}".utf8).base64EncodedString()
        stub.register(host: "open.spotify.com") { _ in
            .text("<html><script id=\"appServerConfig\" type=\"text/plain\">\(config)</script></html>")
        }
        stub.register(host: "api-partner.spotify.com") { _ in
            .text(try! CanvasFixture.text("spotify-pathfinder.json"))
        }
        stub.register(host: "clienttoken.spotify.com") { _ in
            .text("""
            {"response_type":"RESPONSE_GRANTED_TOKEN_RESPONSE",\
            "granted_token":{"token":"test-client-token","expires_after_seconds":3600}}
            """)
        }
        stub.register(host: "api.spotify.com") { _ in .status(429) }
        let canvasURL = "https://example.com/spotify-canvas/pathfinder.cnvs.mp4"
        stub.register(host: "spclient.wg.spotify.com", path: "/canvaz-cache/v0/canvases") { _ in
            .data(self.canvazResponse(url: canvasURL, trackURI: "spotify:track:0VjIjW4GlUZAMYd2vXMi3b"))
        }
        let (canvas, _) = self.canvas(stub, harvester: harvester())

        let found = await canvas.search(title: "Blinding Lights", artist: "The Weeknd", album: "After Hours")
        XCTAssertEqual((try XCTUnwrap(found)).url, canvasURL)
    }

    /// Answers the web-player page, the client token and Pathfinder with `body`; REST search 429s,
    /// so only Pathfinder can supply a hit.
    private func registerPathfinder(_ stub: URLProtocolStub, body: String) {
        let config = Data("{\"clientVersion\":\"1.2.3\"}".utf8).base64EncodedString()
        stub.register(host: "open.spotify.com") { _ in
            .text("<html><script id=\"appServerConfig\" type=\"text/plain\">\(config)</script></html>")
        }
        stub.register(host: "api-partner.spotify.com") { _ in .text(body) }
        stub.register(host: "clienttoken.spotify.com") { _ in
            .text("""
            {"response_type":"RESPONSE_GRANTED_TOKEN_RESPONSE",\
            "granted_token":{"token":"test-client-token","expires_after_seconds":3600}}
            """)
        }
        stub.register(host: "api.spotify.com") { _ in .status(429) }
        stub.register(host: "spclient.wg.spotify.com", path: "/canvaz-cache/v0/canvases") { _ in
            .data(self.canvazResponse(
                url: "https://example.com/spotify-canvas/pathfinder.cnvs.mp4",
                trackURI: "spotify:track:0VjIjW4GlUZAMYd2vXMi3b"))
        }
    }

    private func pathfinderBody(name: String, artist: String) -> String {
        """
        {"data":{"searchV2":{"tracksV2":{"items":[{"item":{"data":{"__typename":"Track",\
        "uri":"spotify:track:0VjIjW4GlUZAMYd2vXMi3b","name":"\(name)",\
        "artists":{"items":[{"profile":{"name":"\(artist)"}}]}}}}]}}}}
        """
    }

    func testPathfinderHitForADifferentTrackIsRejected() async {
        let stub = URLProtocolStub()
        registerPathfinder(stub, body: pathfinderBody(name: "Blinding Lights Karaoke", artist: "Cover Band"))
        let (canvas, _) = self.canvas(stub, harvester: harvester())

        let found = await canvas.search(title: "Blinding Lights", artist: "The Weeknd", album: "After Hours")
        XCTAssertNil(found, "Spotify's top result for the query isn't the playing track")
        XCTAssertTrue(stub.requests(toPath: "/canvaz-cache/v0/canvases").isEmpty)
    }

    func testPathfinderHitForTheRightTrackIsKept() async throws {
        let stub = URLProtocolStub()
        registerPathfinder(stub, body: pathfinderBody(name: "Blinding Lights", artist: "The Weeknd"))
        let (canvas, _) = self.canvas(stub, harvester: harvester())

        let found = await canvas.search(title: "Blinding Lights", artist: "The Weeknd", album: "After Hours")
        XCTAssertEqual(try XCTUnwrap(found).artist, "The Weeknd")
    }

    func testAClipBundledForAnotherTrackIsNotBorrowed() async throws {
        let stub = URLProtocolStub()
        try canvasRoute(stub, host: "api.spotify.com", path: "/v1/search",
                        fixture: "spotify-search-tracks.json")
        stub.register(host: "clienttoken.spotify.com", response: .status(400))
        stub.register(host: "spclient.wg.spotify.com", path: "/canvaz-cache/v0/canvases") { _ in
            .data(self.canvazResponse(
                url: "https://example.com/spotify-canvas/other.cnvs.mp4",
                trackURI: "spotify:track:someOtherTrack"))
        }
        let (canvas, _) = self.canvas(stub, harvester: harvester())

        let found = await canvas.search(title: "Blinding Lights", artist: "The Weeknd", album: "After Hours")
        XCTAssertNil(found)
    }

    func testAlbumLookupReadsTheCanvasOffTheFirstTrack() async throws {
        let stub = URLProtocolStub()
        try canvasRoute(stub, host: "api.spotify.com", path: "/v1/search",
                        fixture: "spotify-search-albums.json")
        try canvasRoute(stub, host: "api.spotify.com", path: "/v1/albums/4yP0hdKOZPNshxUOjY0cZj/tracks",
                        fixture: "spotify-album-tracks.json")
        stub.register(host: "clienttoken.spotify.com", response: .status(400))
        let canvasURL = "https://example.com/spotify-canvas/album.cnvs.mp4"
        stub.register(host: "spclient.wg.spotify.com", path: "/canvaz-cache/v0/canvases") { _ in
            .data(self.canvazResponse(url: canvasURL, trackURI: "spotify:track:0VjIjW4GlUZAMYd2vXMi3b"))
        }
        let (canvas, _) = self.canvas(stub, harvester: harvester())

        let found = await canvas.searchAlbum(album: "After Hours", artist: "The Weeknd")
        let artwork = try XCTUnwrap(found)
        XCTAssertEqual(artwork.url, canvasURL)
        XCTAssertEqual(artwork.album, "After Hours")
        XCTAssertEqual(artwork.source, .spotify)
    }

    // MARK: - Pathfinder `canvas` query

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { value += 1; return value } }
    }

    private static let canvasPath = "/pathfinder/v2/query"
    private static let pathfinderClip = "https://example.com/spotify-canvas/pathfinder-v2.mp4"
    private static let canvazClip = "https://example.com/spotify-canvas/canvaz.cnvs.mp4"
    private static let newHash = String(repeating: "ab", count: 32)

    /// Search via Pathfinder v1, the client token, the web player page, and canvaz-cache; the
    /// `canvas` query itself (v2) answers through `canvasAnswer`.
    private func registerCanvasQuery(
        _ stub: URLProtocolStub, script: @escaping @Sendable () -> String = { "" },
        canvasAnswer: @escaping URLProtocolStub.Responder
    ) {
        let config = Data("{\"clientVersion\":\"1.2.3\"}".utf8).base64EncodedString()
        stub.register(host: "open.spotify.com") { _ in
            .text("""
            <html><script id=\"appServerConfig\" type=\"text/plain\">\(config)</script>\
            <script src=\"https://open.spotifycdn.com/cdn/build/web-player/web-player.abc123.js\"></script></html>
            """)
        }
        stub.register(host: "open.spotifycdn.com") { _ in .text(script()) }
        stub.register(host: "clienttoken.spotify.com") { _ in
            .text("""
            {"response_type":"RESPONSE_GRANTED_TOKEN_RESPONSE",\
            "granted_token":{"token":"test-client-token","expires_after_seconds":3600}}
            """)
        }
        stub.register(host: "api-partner.spotify.com", path: "/pathfinder/v1/query") { _ in
            .text(self.pathfinderBody(name: "Blinding Lights", artist: "The Weeknd"))
        }
        stub.register(host: "api-partner.spotify.com", path: Self.canvasPath, canvasAnswer)
        stub.register(host: "spclient.wg.spotify.com", path: "/canvaz-cache/v0/canvases") { _ in
            .data(self.canvazResponse(url: Self.canvazClip, trackURI: "spotify:track:0VjIjW4GlUZAMYd2vXMi3b"))
        }
    }

    private func canvasBody(url: String?) -> String {
        let urlField = url.map { "\"\($0)\"" } ?? "null"
        return "{\"data\":{\"trackUnion\":{\"canvas\":{\"type\":\"VIDEO\",\"fileId\":\"f1\",\"url\":\(urlField)}}}}"
    }

    private func sentHash(_ request: URLRequest) -> String? {
        guard let body = request.httpBody,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let persisted = (json["extensions"] as? [String: Any])?["persistedQuery"] as? [String: Any]
        else { return nil }
        return persisted["sha256Hash"] as? String
    }

    func testPathfinderCanvasIsUsedAndCanvazIsNotAsked() async throws {
        let stub = URLProtocolStub()
        registerCanvasQuery(stub) { _ in .text(self.canvasBody(url: Self.pathfinderClip)) }
        let (canvas, _) = self.canvas(stub, harvester: harvester())

        let found = await canvas.search(title: "Blinding Lights", artist: "The Weeknd", album: "After Hours")
        XCTAssertEqual(try XCTUnwrap(found).url, Self.pathfinderClip)
        XCTAssertTrue(stub.requests(toPath: "/canvaz-cache/v0/canvases").isEmpty)
        let sent = try XCTUnwrap(stub.requests(toPath: Self.canvasPath).first)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "App-platform"), "WebPlayer")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
    }

    func testNoPlayableCanvasFromPathfinderStillTriesCanvaz() async throws {
        let stub = URLProtocolStub()
        registerCanvasQuery(stub) { _ in .text(self.canvasBody(url: nil)) }
        let (canvas, _) = self.canvas(stub, harvester: harvester())

        let found = await canvas.search(title: "Blinding Lights", artist: "The Weeknd", album: "After Hours")
        XCTAssertEqual(try XCTUnwrap(found).url, Self.canvazClip)
        XCTAssertEqual(stub.requests(toPath: Self.canvasPath).count, 1)
    }

    func testFailedPathfinderCanvasFallsBackToCanvaz() async throws {
        let stub = URLProtocolStub()
        registerCanvasQuery(stub) { _ in .status(500) }
        let (canvas, _) = self.canvas(stub, harvester: harvester())

        let found = await canvas.search(title: "Blinding Lights", artist: "The Weeknd", album: "After Hours")
        XCTAssertEqual(try XCTUnwrap(found).url, Self.canvazClip)
    }

    func testAStaleHashIsLookedUpAgainOnce() async throws {
        let stub = URLProtocolStub()
        let scriptFetches = Counter()
        // The first read of the web player's script declares nothing (the known hash is sent and
        // refused as stale); the second finds the rebuilt player's hash.
        registerCanvasQuery(stub, script: {
            scriptFetches.next() == 1 ? "var a=1;" : "x(\"canvas\",\"query\",\"\(Self.newHash)\",null)"
        }, canvasAnswer: { request in
            self.sentHash(request) == Self.newHash
                ? .text(self.canvasBody(url: Self.pathfinderClip))
                : .text("{\"errors\":[{\"message\":\"PersistedQueryNotFound\"}]}")
        })
        let (canvas, _) = self.canvas(stub, harvester: harvester())

        let found = await canvas.search(title: "Blinding Lights", artist: "The Weeknd", album: "After Hours")
        XCTAssertEqual(try XCTUnwrap(found).url, Self.pathfinderClip)
        XCTAssertEqual(
            stub.requests(toPath: Self.canvasPath).map(sentHash),
            [SpotifyCanvasQuery.knownCanvasHash, Self.newHash])
        XCTAssertTrue(stub.requests(toPath: "/canvaz-cache/v0/canvases").isEmpty)
    }

    func testCanvasAnswerWithOnlyAFileIdIsNotPlayable() {
        let body = "{\"data\":{\"trackUnion\":{\"canvas\":{\"type\":\"VIDEO\",\"fileId\":\"f1\"}}}}"
        guard case .noCanvas(let detail) = SpotifyCanvasQuery.parse(body) else {
            return XCTFail("expected noCanvas")
        }
        XCTAssertTrue(detail.contains("fileId=f1"))
        XCTAssertEqual(
            SpotifyCanvasQuery.parse("{\"errors\":[{\"message\":\"PersistedQueryNotFound\"}]}"),
            .failed(reason: "PersistedQueryNotFound", staleHash: true))
    }

    func testNoCookieMeansNoRequests() async {
        let stub = URLProtocolStub()
        let harvester = harvester()
        let tokens = CanvasSpotifyTokenStore(
            session: stub.makeSession(), cookie: { "" }, harvester: harvester)
        let canvas = SpotifyCanvas(session: stub.makeSession(), tokens: tokens)
        let found = await canvas.search(title: "Blinding Lights", artist: "The Weeknd", album: nil)
        XCTAssertNil(found)
        XCTAssertTrue(stub.requests.isEmpty)
        XCTAssertEqual(harvester.calls, 0)
    }

    func testNoHarvesterMeansNoRequests() async {
        let stub = URLProtocolStub()
        let tokens = CanvasSpotifyTokenStore(
            session: stub.makeSession(), cookie: { "sp_dc=x" }, harvester: nil)
        let canvas = SpotifyCanvas(session: stub.makeSession(), tokens: tokens)
        let awaited1 = await canvas.search(title: "Blinding Lights", artist: "The Weeknd", album: nil)
        XCTAssertNil(awaited1)
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testLookupsDuringAHarvestShareIt() async {
        let slow = StubCanvasHarvester(
            harvested: CanvasHarvestedToken(token: "shared", expiresAt: .distantFuture), delay: .milliseconds(300))
        let tokens = CanvasSpotifyTokenStore(
            session: URLProtocolStub().makeSession(), cookie: { "sp_dc=x" }, harvester: slow)
        async let first = tokens.accessToken()
        async let second = tokens.accessToken()
        let found = await [first, second]
        XCTAssertEqual(found, ["shared", "shared"])
        XCTAssertEqual(slow.calls, 1, "one web-view load, not one per lookup")
    }

    func testANewCookieMintsANewToken() async {
        let harvester = harvester()
        let cookie = LockedCookie("sp_dc=first")
        let tokens = CanvasSpotifyTokenStore(
            session: URLProtocolStub().makeSession(), cookie: { cookie.value }, harvester: harvester)
        _ = await tokens.accessToken()
        _ = await tokens.accessToken()
        XCTAssertEqual(harvester.calls, 1, "the token is cached while the cookie stays")

        cookie.value = "sp_dc=second"
        _ = await tokens.accessToken()
        XCTAssertEqual(harvester.calls, 2, "another account's cookie is not served the old account's token")
    }

    func testACookieChangedMidHarvestGetsItsOwnToken() async throws {
        let cookie = LockedCookie("first")
        let tokens = CanvasSpotifyTokenStore(
            session: URLProtocolStub().makeSession(), cookie: { cookie.value }, harvester: EchoHarvester())
        async let first = tokens.accessToken()
        try await Task.sleep(for: .milliseconds(50))
        cookie.value = "second"
        let second = await tokens.accessToken()
        let firstToken = await first
        XCTAssertEqual(firstToken, "first")
        XCTAssertEqual(second, "second", "a new cookie never joins the old cookie's harvest")
        let later = await tokens.accessToken()
        XCTAssertEqual(later, "second")
    }

    // MARK: - Protobuf codec

    func testCanvasRequestEncodesOneTrackURI() {
        let bytes = SpotifyCanvas.encodeCanvasRequest(trackURI: "spotify:track:abc")
        // field 1 (LEN) outer, field 1 (LEN) inner, field 1 (string) "spotify:track:abc".
        XCTAssertEqual(Array(bytes.prefix(2)), [0x0A, 0x13])
        XCTAssertEqual(Array(bytes.dropFirst(2).prefix(2)), [0x0A, 0x11])
        XCTAssertEqual(String(data: bytes.dropFirst(4), encoding: .utf8), "spotify:track:abc")
    }

    func testCanvasResponseDecodesTheRightTrack() {
        let uri = "spotify:track:0VjIjW4GlUZAMYd2vXMi3b"
        let bytes = canvazResponse(url: "https://example.com/a.cnvs.mp4", trackURI: uri)
        let hits = SpotifyCanvas.decodeCanvasResponse(bytes)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].url, "https://example.com/a.cnvs.mp4")
        XCTAssertEqual(hits[0].trackURI, uri)
        XCTAssertEqual(hits[0].id, "canvas-id-1")
    }

    func testCanvasResponseSkipsUnknownFields() {
        var canvas = Data()
        canvas.append(SpotifyCanvas.protobufField(field: 9, wireType: 0))
        canvas.append(SpotifyCanvas.varint(12345))
        canvas.append(SpotifyCanvas.protobufField(field: 2, wireType: 2))
        canvas.append(SpotifyCanvas.protobufString("https://example.com/b.cnvs.mp4"))
        canvas.append(SpotifyCanvas.protobufField(field: 7, wireType: 2))
        canvas.append(SpotifyCanvas.protobufString("unknown"))
        var response = Data()
        response.append(SpotifyCanvas.protobufField(field: 1, wireType: 2))
        response.append(SpotifyCanvas.protobufBytes(canvas))
        let hits = SpotifyCanvas.decodeCanvasResponse(response)
        XCTAssertEqual(hits.first?.url, "https://example.com/b.cnvs.mp4")
        XCTAssertNil(hits.first?.trackURI)
    }

    func testCanvasURLRegexFallback() {
        let bytes = Data("....https://example.com/fallback.cnvs.mp4....".utf8)
        XCTAssertEqual(
            SpotifyCanvas.canvasURL(in: bytes), "https://example.com/fallback.cnvs.mp4")
        XCTAssertNil(SpotifyCanvas.canvasURL(in: Data("nothing here".utf8)))
    }

    func testVarintRoundTrip() {
        for value: UInt64 in [0, 1, 127, 128, 300, 1499362749, UInt64.max] {
            var reader = CanvasProtoReader(SpotifyCanvas.varint(value))
            XCTAssertEqual(reader.readVarint(), value, "varint \(value)")
        }
    }

    // MARK: - Token harvest parsing

    func testHarvestedTokenKeepsTheLoggedInToken() {
        let future = Int64(Date().timeIntervalSince1970 + 3600) * 1000
        let payload = """
        {"accessToken":"logged-in-token","isAnonymous":false,\
        "accessTokenExpirationTimestampMs":\(future),"clientId":"client-1"}
        """
        let harvested = CanvasSpotifyTokenStore.harvestedToken(in: payload)
        XCTAssertEqual(try XCTUnwrap(harvested).token, "logged-in-token")
        XCTAssertEqual(harvested?.clientId, "client-1")
    }

    func testHarvestedTokenSkipsTheAnonymousToken() {
        XCTAssertNil(CanvasSpotifyTokenStore.harvestedToken(in:
            "{\"accessToken\":\"anon\",\"isAnonymous\":true}"))
        XCTAssertNil(CanvasSpotifyTokenStore.harvestedToken(in: "{}"))
        XCTAssertNil(CanvasSpotifyTokenStore.harvestedToken(in: ""))
    }

    func testHarvestedTokenRejectsOneThatSaysItIsAlreadyExpired() {
        let past = Int64(Date().timeIntervalSince1970 - 60) * 1000
        XCTAssertNil(CanvasSpotifyTokenStore.harvestedToken(in:
            "{\"accessToken\":\"stale\",\"accessTokenExpirationTimestampMs\":\(past)}"))

        let undated = CanvasSpotifyTokenStore.harvestedToken(in: "{\"accessToken\":\"undated\"}")
        XCTAssertNotNil(undated, "no expiry in the response: the default lifetime applies")
    }

    func testHarvestHookScriptWatchesTheTokenEndpoint() {
        let script = CanvasSpotifyTokenStore.harvestHookScript(bridge: "TestBridge")
        XCTAssertTrue(script.contains("/api/token"))
        XCTAssertTrue(script.contains("TestBridge"))
        XCTAssertTrue(script.contains("__vibramusicTokenHook"))
    }
}

private final class LockedCookie: @unchecked Sendable {
    private let lock = NSLock()
    private var current: String
    init(_ value: String) { current = value }
    var value: String {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// Mints a token named after the cookie it was given, slowly enough for lookups to overlap.
private struct EchoHarvester: CanvasSpotifyTokenHarvester {
    func harvest(spDcCookie: String) async -> CanvasHarvestedToken? {
        try? await Task.sleep(for: .milliseconds(300))
        return CanvasHarvestedToken(token: spDcCookie, expiresAt: .distantFuture)
    }
}
