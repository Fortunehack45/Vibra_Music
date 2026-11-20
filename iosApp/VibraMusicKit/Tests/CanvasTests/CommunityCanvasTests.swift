import VibraMusicTestSupport
import XCTest
@testable import Canvas

/// The community index against a recorded manifest (ported from
/// `data/canvas/CommunityCanvas.kt`).
final class CommunityCanvasTests: XCTestCase {
    private func index(_ stub: URLProtocolStub) -> CommunityCanvas {
        CommunityCanvas(session: stub.makeSession())
    }

    func testManifestHit() async throws {
        let stub = URLProtocolStub()
        try canvasRoute(
            stub, host: "vivimusicanvas.mkmdevilmi.workers.dev", path: "/canvas.json",
            fixture: "community-manifest.json")
        let found = await index(stub).search(title: "Africa", artist: "Toto", album: "Toto IV")
        let artwork = try XCTUnwrap(found)
        XCTAssertEqual(artwork.url, "https://example.com/canvas/africa.mp4")
        XCTAssertEqual(artwork.title, "Africa")
        XCTAssertFalse(artwork.isHLS)
    }

    func testTitleMatchingIsContainmentBothWays() async throws {
        let stub = URLProtocolStub()
        try canvasRoute(
            stub, host: "vivimusicanvas.mkmdevilmi.workers.dev", path: "/canvas.json",
            fixture: "community-manifest.json")
        let canvas = index(stub)
        // The contributor wrote the plain title; YouTube Music carries the packaging.
        let found = await canvas.search(
            title: "Take On Me (Official Video)", artist: "a-ha", album: nil)
        XCTAssertEqual((try XCTUnwrap(found)).url, "https://example.com/canvas/take-on-me.mp4")
    }

    func testAlbumMismatchVetoesWhenAnAlbumIsKnown() async throws {
        let stub = URLProtocolStub()
        try canvasRoute(
            stub, host: "vivimusicanvas.mkmdevilmi.workers.dev", path: "/canvas.json",
            fixture: "community-manifest.json")
        let found = await index(stub).search(title: "Africa", artist: "Toto", album: "Fahrenheit")
        XCTAssertNil(found, "the album check is what keeps the loose matching honest")
    }

    func testAlbumLookupTakesTheFirstCoveredTrackOfTheRelease() async throws {
        let stub = URLProtocolStub()
        try canvasRoute(
            stub, host: "vivimusicanvas.mkmdevilmi.workers.dev", path: "/canvas.json",
            fixture: "community-manifest.json")
        let found = await index(stub).searchAlbum(album: "Toto IV", artist: "Toto")
        let artwork = try XCTUnwrap(found)
        XCTAssertEqual(artwork.album, "Toto IV")
        XCTAssertEqual(artwork.url, "https://example.com/canvas/africa.mp4")
    }

    func testManifestIsFetchedOnceThenHeld() async throws {
        let stub = URLProtocolStub()
        try canvasRoute(
            stub, host: "vivimusicanvas.mkmdevilmi.workers.dev", path: "/canvas.json",
            fixture: "community-manifest.json")
        let canvas = index(stub)
        _ = await canvas.search(title: "Africa", artist: "Toto", album: nil)
        _ = await canvas.search(title: "Africa", artist: "Toto", album: nil)
        XCTAssertEqual(stub.requests.count, 1, "one file for the whole index: one request, then local lookups")
    }

    func testManifestParsingSkipsIncompleteRows() throws {
        // The fixture carries an {"incomplete": true} row with no song/artist/url.
        let entries = CommunityCanvas.parse(try CanvasFixture.text("community-manifest.json"))
        XCTAssertEqual(entries.map(\.song), ["Africa", "Take On Me"])
        XCTAssertTrue(CommunityCanvas.parse("{\"items\": []}").isEmpty)
        XCTAssertTrue(CommunityCanvas.parse("not json").isEmpty)
    }
}
