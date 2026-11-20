import VibraMusicTestSupport
import XCTest
@testable import Canvas

/// Tidal video covers against recorded search answers (ported from
/// `data/canvas/TidalCanvas.kt`).
final class TidalCanvasTests: XCTestCase {
    func testSkipsTheWrongArtistAndTheCoverlessHit() async throws {
        let stub = URLProtocolStub()
        try canvasRoute(stub, host: "api.tidal.com", path: "/v1/search", fixture: "tidal-tracks.json")
        let tidal = TidalCanvas(session: stub.makeSession())

        let found = await tidal.search(title: "Blinding Lights", artist: "The Weeknd", album: "After Hours")
        let artwork = try XCTUnwrap(found)
        XCTAssertEqual(
            artwork.url,
            "https://resources.tidal.com/videos/01234567/89ab/cdef/0123/456789abcdef/1280x1280.mp4")
        XCTAssertEqual(artwork.title, "Blinding Lights")
        XCTAssertEqual(artwork.artist, "The Weeknd")
        XCTAssertEqual(artwork.album, "After Hours")
        XCTAssertFalse(artwork.isHLS, "Tidal covers are square MP4")
    }

    func testAlbumSearchDoesNotSettleOnAnotherRecordByTheSameArtist() async throws {
        let stub = URLProtocolStub()
        try canvasRoute(stub, host: "api.tidal.com", path: "/v1/search", fixture: "tidal-albums.json")
        let tidal = TidalCanvas(session: stub.makeSession())

        // "Ctrl" also has a cover and is also by SZA — without the name check the search for
        // "SOS" would settle on it.
        let found = await tidal.searchAlbum(album: "SOS", artist: "SZA")
        let artwork = try XCTUnwrap(found)
        XCTAssertEqual(artwork.album, "SOS")
        XCTAssertTrue(artwork.url.contains("aaaa1111/bb22/cc33/dd44/ee5566778899"))
    }

    func testCoverIDShape() {
        XCTAssertEqual(
            TidalCanvas.coverURL("aa-bb-cc-dd-ee"),
            "https://resources.tidal.com/videos/aa/bb/cc/dd/ee/1280x1280.mp4")
        XCTAssertNil(TidalCanvas.coverURL("not-a-cover-id"), "unknown shapes are misses, not 404s")
        XCTAssertNil(TidalCanvas.coverURL("aa-bb-cc-dd"))
    }

    func testMatchNeedsTheNameAndEveryWantedArtist() {
        XCTAssertTrue(TidalCanvas.isMatch(
            gotName: "SOS", gotArtists: ["SZA"], wantName: "sos", wantArtist: "SZA"))
        XCTAssertFalse(TidalCanvas.isMatch(
            gotName: "Ctrl", gotArtists: ["SZA"], wantName: "SOS", wantArtist: "SZA"))
        XCTAssertFalse(TidalCanvas.isMatch(
            gotName: "SOS", gotArtists: ["SZA"], wantName: "SOS", wantArtist: "SZA, Kendrick Lamar"))
    }
}
