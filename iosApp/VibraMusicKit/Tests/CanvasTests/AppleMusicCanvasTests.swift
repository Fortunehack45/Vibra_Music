import VibraMusicTestSupport
import XCTest
@testable import Canvas

/// Apple Music motion artwork against recorded catalog answers (ported from
/// `data/canvas/AppleMusicCanvas.kt`).
final class AppleMusicCanvasTests: XCTestCase {
    private func canvas(
        _ stub: URLProtocolStub, storefront: String = "us"
    ) async -> (AppleMusicCanvas, CanvasAppleTokenStore) {
        let tokens = CanvasAppleTokenStore(session: stub.makeSession())
        await tokens.seed(token: "test-bearer", expiresAt: .distantFuture)
        return (AppleMusicCanvas(session: stub.makeSession(), storefront: storefront, tokens: tokens), tokens)
    }

    func testInlineMotionArtworkPrefersTheSquareRendition() async throws {
        let stub = URLProtocolStub()
        try canvasRoute(stub, host: "amp-api.music.apple.com", path: "/v1/catalog/us/search",
                        fixture: "apple-search-inline.json")
        let (canvas, _) = await self.canvas(stub)

        let found = await canvas.search(title: "Blinding Lights", artist: "The Weeknd", album: "After Hours")
        let artwork = try XCTUnwrap(found)
        XCTAssertEqual(artwork.url, "https://example.com/apple/blinding-lights-square.m3u8")
        XCTAssertEqual(artwork.fallbackUrl, "https://example.com/apple/blinding-lights-tall.m3u8")
        XCTAssertEqual(artwork.tallUrl, "https://example.com/apple/blinding-lights-tall.m3u8")
        XCTAssertEqual(artwork.title, "Blinding Lights")
        XCTAssertEqual(artwork.artist, "The Weeknd")
        XCTAssertEqual(artwork.album, "After Hours")
        XCTAssertTrue(artwork.isHLS)
        // The tribute-cover hit lower in the results must not win.
        XCTAssertFalse(artwork.url.contains("wrong"))
    }

    func testMissingInlineVideoFallsThroughToTheAlbumLookup() async throws {
        let stub = URLProtocolStub()
        try canvasRoute(stub, host: "amp-api.music.apple.com", path: "/v1/catalog/us/search",
                        fixture: "apple-search-roundtrip.json")
        try canvasRoute(stub, host: "amp-api.music.apple.com", path: "/v1/catalog/us/albums/1499362749",
                        fixture: "apple-album.json")
        let (canvas, _) = await self.canvas(stub)

        let found = await canvas.search(title: "Blinding Lights", artist: "The Weeknd", album: "After Hours")
        let artwork = try XCTUnwrap(found)
        XCTAssertEqual(artwork.url, "https://example.com/apple/after-hours-square.m3u8")
        XCTAssertEqual(artwork.album, "After Hours")
        XCTAssertEqual(
            stub.requests.map { $0.url?.path ?? "" }.filter { $0.contains("albums") }.count, 1,
            "one album round trip for the one scored hit")
    }

    func testAWrongArtistHitIsRejectedEvenWhenItCarriesVideo() async throws {
        let stub = URLProtocolStub()
        try canvasRoute(stub, host: "amp-api.music.apple.com", path: "/v1/catalog/us/search",
                        fixture: "apple-search-wrong-artist.json")
        let (canvas, _) = await self.canvas(stub)

        let found = await canvas.search(title: "Blinding Lights", artist: "The Weeknd", album: nil)
        XCTAssertNil(found, "artist is a gate, not a score — a clip credited to someone else is never right")
    }

    func testAlbumSearchSkipsCompilationsForThePlainRelease() async throws {
        let stub = URLProtocolStub()
        try canvasRoute(stub, host: "amp-api.music.apple.com", path: "/v1/catalog/us/search",
                        fixture: "apple-search-albums.json")
        let (canvas, _) = await self.canvas(stub)

        let found = await canvas.searchAlbum(album: "After Hours", artist: "The Weeknd")
        let artwork = try XCTUnwrap(found)
        XCTAssertEqual(artwork.url, "https://example.com/apple/after-hours-square.m3u8")
        XCTAssertEqual(artwork.album, "After Hours")
    }

    func testNoTokenMeansNoRequests() async {
        let stub = URLProtocolStub()
        // No seed: the token store scrapes the web player, which is unstubbed and fails.
        let canvas = AppleMusicCanvas(
            session: stub.makeSession(), tokens: CanvasAppleTokenStore(session: stub.makeSession()))
        let found = await canvas.search(title: "Blinding Lights", artist: "The Weeknd", album: nil)
        XCTAssertNil(found)
        XCTAssertTrue(
            stub.requests.allSatisfy { $0.url?.host?.contains("apple.com") == true },
            "only token-scrape traffic")
        XCTAssertTrue(
            stub.requests.filter { $0.url?.host?.hasPrefix("amp-api") == true }.isEmpty,
            "never a catalog read")
    }

    func testARejectedTokenIsStruckOffAndTheNextLookupReScrapes() async throws {
        let stub = URLProtocolStub()
        stub.register(host: "amp-api.music.apple.com", path: "/v1/catalog/us/search",
                      response: .status(401))
        let (canvas, tokens) = await self.canvas(stub)

        let found = await canvas.search(title: "Blinding Lights", artist: "The Weeknd", album: nil)
        XCTAssertNil(found)
        let again = await tokens.token()
        XCTAssertNil(again, "the 401'd bearer is rejected, and the seeded cache is cleared with it")
    }

    // MARK: - Pure units

    func testScoreNeedsBothArtistAndTitle() {
        func song(name: String, artist: String, album: String? = nil) -> [String: CanvasJSON] {
            var attributes: [String: CanvasJSON] = [
                "name": .string(name), "artistName": .string(artist),
            ]
            if let album { attributes["albumName"] = .string(album) }
            return ["attributes": .object(attributes)]
        }

        XCTAssertNotNil(AppleMusicCanvas.score(
            song(name: "Blinding Lights", artist: "The Weeknd"),
            title: "Blinding Lights", artist: "The Weeknd", album: nil))
        XCTAssertNil(AppleMusicCanvas.score(
            song(name: "Blinding Lights", artist: "Tribute Act"),
            title: "Blinding Lights", artist: "The Weeknd", album: nil),
            "artist gate")
        XCTAssertNil(AppleMusicCanvas.score(
            song(name: "Today's Hits Mix", artist: "The Weeknd"),
            title: "Blinding Lights", artist: "The Weeknd", album: nil),
            "compilations are dropped outright")
        let exact = AppleMusicCanvas.score(
            song(name: "Blinding Lights", artist: "The Weeknd", album: "After Hours"),
            title: "Blinding Lights", artist: "The Weeknd", album: "After Hours")!
        let fuzzy = AppleMusicCanvas.score(
            song(name: "Blinding", artist: "The Weeknd"),
            title: "Blinding Lights", artist: "The Weeknd", album: nil)!
        XCTAssertGreaterThan(exact, fuzzy)
        XCTAssertGreaterThanOrEqual(exact, AppleMusicCanvas.minimumScore)
    }

    func testMotionURLsPrefersSquareThenRawThenTall() throws {
        func video(_ keys: [String: String]) -> [String: CanvasJSON] {
            Dictionary(uniqueKeysWithValues: keys.map { ($0.key, CanvasJSON.object(["video": .string($0.value)])) })
        }
        let all = video([
            "motionDetailTall": "https://example.com/tall.m3u8",
            "motionDetailSquare": "https://example.com/square.m3u8",
            "motionDetailRaw": "https://example.com/raw.m3u8",
        ])
        let (primary, alternate, tall) = try XCTUnwrap(AppleMusicCanvas.motionURLs(all))
        XCTAssertEqual(primary, "https://example.com/square.m3u8")
        XCTAssertEqual(alternate, "https://example.com/raw.m3u8")
        XCTAssertEqual(tall, "https://example.com/tall.m3u8", "kept beside the square for the lock screen's 3x4 key")

        let tallOnly = video(["motionDetailTall": "https://example.com/tall.m3u8"])
        XCTAssertEqual(AppleMusicCanvas.motionURLs(tallOnly)?.primary, "https://example.com/tall.m3u8")
        XCTAssertNil(AppleMusicCanvas.motionURLs(tallOnly)?.tall, "the primary is not repeated as the tall link")
        XCTAssertNil(AppleMusicCanvas.motionURLs([:]))
    }

    func testAlbumIDComesFromRelationshipsOrTheWebURL() {
        let viaRelationship: [String: CanvasJSON] = [
            "relationships": .object(["albums": .object(["data": .array([
                .object(["id": .string("1499362749")]),
            ])])]),
        ]
        XCTAssertEqual(AppleMusicCanvas.albumID(viaRelationship), "1499362749")

        let playlistRelationship: [String: CanvasJSON] = [
            "relationships": .object(["albums": .object(["data": .array([
                .object(["id": .string("pl.12345")]),
            ])])]),
        ]
        XCTAssertNil(AppleMusicCanvas.albumID(playlistRelationship), "playlists are not albums")

        let viaURL: [String: CanvasJSON] = [
            "attributes": .object(["url": .string(
                "https://music.apple.com/us/album/blinding-lights/1499362749?i=1499362962")]),
        ]
        XCTAssertEqual(AppleMusicCanvas.albumID(viaURL), "1499362749")
    }

    func testTokenScrapeFindsBundlesAndPicksTheWebPlayerJWT() {
        let html = """
        <html><head>
        <script src="/assets/index-abcDEF123.js"></script>
        <script src="/assets/index-legacy~xyz789.js"></script>
        </head></html>
        """
        XCTAssertEqual(
            CanvasAppleTokenStore.scriptPaths(in: html),
            ["/assets/index-abcDEF123.js", "/assets/index-legacy~xyz789.js"])

        func jwt(issuer: String, payloadIssuer: String = "issuer", expiry: Int64) -> String {
            func b64(_ text: String) -> String {
                Data(text.utf8).base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
            }
            return "\(b64("{\"alg\":\"ES256\",\"kid\":\"\(issuer)\""))." +
                "\(b64("{\"iss\":\"\(payloadIssuer)\",\"exp\":\(expiry)}"))." +
                "\(b64("sig"))"
        }
        let future: Int64 = 4_000_000_000
        let webPlayer = jwt(issuer: "WebPlayKid123", expiry: future)
        // Recognised by the payload's `iss` alone, with a header that says nothing.
        let namedInPayload = jwt(issuer: "OtherKid", payloadIssuer: "AMPWebPlay", expiry: future)
        let other = jwt(issuer: "OtherKid", expiry: future)
        let expired = jwt(issuer: "WebPlayKid123", expiry: 1_000)

        XCTAssertTrue(CanvasAppleTokenStore.isWebPlayerToken(webPlayer))
        XCTAssertTrue(CanvasAppleTokenStore.isWebPlayerToken(namedInPayload))
        XCTAssertFalse(CanvasAppleTokenStore.isWebPlayerToken(other))
        XCTAssertEqual(CanvasAppleTokenStore.jwtExpiry(webPlayer), future * 1000)
        XCTAssertEqual(CanvasAppleTokenStore.jwtExpiry(expired), 1_000 * 1000)
        XCTAssertNil(CanvasAppleTokenStore.jwtExpiry("not-a-jwt"))

        let found = CanvasAppleTokenStore.candidateJWTs(in: "x \(other) y \(webPlayer) z")
        XCTAssertEqual(found.count, 2)
    }
}
