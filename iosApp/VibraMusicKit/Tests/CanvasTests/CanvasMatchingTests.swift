import XCTest
@testable import Canvas

/// `CanvasArtwork.matches` and the text folding behind it (ported from
/// `data/canvas/CanvasArtwork.kt`): a near miss is a different song by the same artist, which
/// is the one failure mode users notice.
final class CanvasMatchingTests: XCTestCase {
    func testExactMetadataMatches() {
        let artwork = CanvasArtwork(
            url: "https://example.com/a.mp4",
            title: "Blinding Lights", artist: "The Weeknd", album: "After Hours")
        XCTAssertTrue(artwork.matches(title: "Blinding Lights", artist: "The Weeknd", album: "After Hours"))
    }

    func testAccentsCaseAndPunctuationAreFoldedAway() {
        let artwork = CanvasArtwork(
            url: "https://example.com/a.mp4",
            title: "Beyonce Crazy in Love feat Jay Z", artist: "Beyonce", album: nil)
        XCTAssertTrue(artwork.matches(
            title: "Beyoncé - CRAZY IN LOVE (feat. JAY-Z)", artist: "Beyoncé", album: nil))
    }

    func testADifferentSongByTheSameArtistDoesNotMatch() {
        let artwork = CanvasArtwork(
            url: "https://example.com/a.mp4",
            title: "Save Your Tears", artist: "The Weeknd", album: "After Hours")
        XCTAssertFalse(artwork.matches(
            title: "Blinding Lights", artist: "The Weeknd", album: "After Hours"))
    }

    func testAClipCreditedToSomeoneElseDoesNotMatch() {
        let artwork = CanvasArtwork(
            url: "https://example.com/a.mp4",
            title: "Blinding Lights", artist: "Tribute Act", album: nil)
        XCTAssertFalse(artwork.matches(title: "Blinding Lights", artist: "The Weeknd", album: nil))
    }

    func testEveryWantedArtistMustBeCredited() {
        let artwork = CanvasArtwork(
            url: "https://example.com/a.mp4",
            title: "Song", artist: "A, B", album: nil)
        // Only one of the two collaborators is credited — a different recording.
        XCTAssertFalse(artwork.matches(title: "Song", artist: "A, C", album: nil))
        XCTAssertTrue(artwork.matches(title: "Song", artist: "A", album: nil))
    }

    func testMissingMetadataNeverVetoes() {
        let artwork = CanvasArtwork(url: "https://example.com/a.mp4")
        XCTAssertTrue(artwork.matches(title: "Anything", artist: "Anyone", album: "Any Album"))
    }

    func testAlbumIsOnlyCheckedWhenBothSidesKnowIt() {
        let artwork = CanvasArtwork(
            url: "https://example.com/a.mp4",
            title: "Blinding Lights", artist: "The Weeknd", album: "After Hours")
        // The player resolves the album a beat after the track starts; a track queued from
        // search may never get one.
        XCTAssertTrue(artwork.matches(title: "Blinding Lights", artist: "The Weeknd", album: nil))
        XCTAssertFalse(artwork.matches(
            title: "Blinding Lights", artist: "The Weeknd", album: "Starboy"))
    }

    func testArtistSeparators() {
        XCTAssertEqual("A, B & C".canvasArtists, ["a", "b", "c"])
        XCTAssertEqual("A feat. B".canvasArtists, ["a", "b"])
        XCTAssertEqual("A ft B".canvasArtists, ["a", "b"])
        XCTAssertEqual("A x B".canvasArtists, ["a", "b"])
        XCTAssertEqual("A with B".canvasArtists, ["a", "b"])
        XCTAssertEqual("Beyoncé".canvasArtists, ["beyonce"])
    }

    func testYouTubePackagingIsCleanedBeforeSearching() {
        XCTAssertEqual(
            CanvasText.cleanedTrackText("Blinding Lights | Official Video"),
            "Blinding Lights")
        XCTAssertEqual(
            CanvasText.cleanedTrackText("Blinding Lights (Official Video) [HD]"),
            "Blinding Lights")
        XCTAssertEqual(
            CanvasText.cleanedTrackText("Raees (Lyrical) Full Song"),
            "Raees")
    }

    func testPlaybackURLsFallBackInOrder() {
        let artwork = CanvasArtwork(
            url: "https://example.com/primary.m3u8",
            fallbackUrl: "https://example.com/fallback.m3u8")
        XCTAssertTrue(artwork.isHLS)
        XCTAssertEqual(
            artwork.playbackURLs.map(\.absoluteString),
            ["https://example.com/primary.m3u8", "https://example.com/fallback.m3u8"])
        XCTAssertFalse(CanvasArtwork(url: "https://example.com/a.mp4").isHLS)
    }
}
