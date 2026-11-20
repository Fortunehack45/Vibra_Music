import XCTest
import VibraMusicCore
@testable import PlaybackPolicy

/// The one-way escape from a higher-quality source that failed (ports PlaybackFallbackTest, plus the
/// "is there a YouTube upload behind this" rule and the item rebuild).
final class PlaybackFallbackTests: XCTestCase {
    func testFailedUpgradedYouTubeItemIsAnAlternative() {
        XCTAssertTrue(PlaybackFallback.isAlternative(
            "vibramusic://watch?v=5IX-nUxDtJI&n=Bin%20Tere&q=hifi",
            substitutedYouTube: false
        ))
    }

    func testLaterUpgradeGenerationsAreAlternativesToo() {
        XCTAssertTrue(PlaybackFallback.isAlternative(
            "vibramusic://watch?v=5IX-nUxDtJI&n=Bin%20Tere&q=hifi-2",
            substitutedYouTube: false
        ))
    }

    func testFailedSubstitutedBaseItemIsAnAlternative() {
        XCTAssertTrue(PlaybackFallback.isAlternative(
            "vibramusic://watch?v=5IX-nUxDtJI&n=Bin%20Tere",
            substitutedYouTube: true
        ))
    }

    func testDirectYouTubeFallbackNeverFallsBackRecursively() {
        XCTAssertFalse(PlaybackFallback.isAlternative(
            "vibramusic://watch?v=5IX-nUxDtJI&direct_youtube=1&q=original",
            substitutedYouTube: true
        ))
    }

    func testOrdinaryYouTubeAudioIsNotTreatedAsAFailedAlternative() {
        XCTAssertFalse(PlaybackFallback.isAlternative(
            "vibramusic://watch?v=5IX-nUxDtJI&n=Bin%20Tere",
            substitutedYouTube: false
        ))
    }

    func testSourceAlreadyForcedToYouTubeNeverFallsBackRecursively() {
        XCTAssertFalse(PlaybackFallback.isAlternative(
            "vibramusic://source?s=addon-1&t=3919244&n=Bin%20Tere&direct_youtube=1&q=original",
            substitutedYouTube: false
        ))
    }

    func testASourceItemIsAlwaysAnAlternative() {
        XCTAssertTrue(PlaybackFallback.isAlternative(
            "vibramusic://source?s=addon-1&t=3919244#frag",
            substitutedYouTube: false
        ))
    }

    func testSourceFallbackRemovesManifestAndUpgradeMarkersAndGetsItsOwnRendition() {
        let failed = "vibramusic://source?s=addon-1&t=3919244&n=Bin%20Tere&a=Vishal%20%26%20Shekhar"
            + "&manifest_reopen=dash&q=hifi#part"

        XCTAssertEqual(
            PlaybackFallback.directYouTubeSourceURI(failed),
            "vibramusic://source?s=addon-1&t=3919244&n=Bin%20Tere&a=Vishal%20%26%20Shekhar"
                + "&direct_youtube=1&q=original#part"
        )
    }

    /// Falling back twice must not stack markers.
    func testSourceFallbackIsIdempotent() {
        let once = PlaybackFallback.directYouTubeSourceURI("vibramusic://source?s=a&t=b")
        XCTAssertEqual(once, "vibramusic://source?s=a&t=b&direct_youtube=1&q=original")
        XCTAssertEqual(PlaybackFallback.directYouTubeSourceURI(once), once)
    }

    // MARK: Whether there is a YouTube upload to go back to

    func testAnOrdinaryCatalogueTrackHasAYouTubeOriginal() {
        XCTAssertTrue(PlaybackFallback.hasYouTubeOriginal(Song(videoId: "5IX-nUxDtJI", title: "Bin Tere", artist: "Vishal & Shekhar")))
    }

    /// The exclusions are all "there is no such upload", not "reverting would be unwise".
    func testSourceKeysFilesAndMusicVideosHaveNoYouTubeOriginal() {
        XCTAssertFalse(PlaybackFallback.hasYouTubeOriginal(Song(videoId: "src:addon-1::3919244", title: "t", artist: "a")))
        XCTAssertFalse(PlaybackFallback.hasYouTubeOriginal(Song(videoId: "file:///var/mobile/a.flac", title: "t", artist: "a")))
        XCTAssertFalse(PlaybackFallback.hasYouTubeOriginal(Song(videoId: "content://media/1", title: "t", artist: "a")))
        XCTAssertFalse(PlaybackFallback.hasYouTubeOriginal(Song(videoId: "ipod-library://item/42", title: "t", artist: "a")))
        XCTAssertFalse(PlaybackFallback.hasYouTubeOriginal(Song(videoId: "2kjolTLZ_Mg", title: "t", artist: "a", isVideo: true)))
        XCTAssertFalse(PlaybackFallback.hasYouTubeOriginal(Song(videoId: " ", title: "t", artist: "a")))
    }

    /// A key that only looks like a source key (nothing before the separator) is an ordinary id.
    func testAMalformedSourceKeyIsNotASourceTrack() {
        XCTAssertNil(SourceTrackKey.parse("src:::track"))
        XCTAssertNil(SourceTrackKey.parse("src:no-separator"))
        XCTAssertEqual(SourceTrackKey.parse("src:cfg::a::b")?.configId, "cfg")
        XCTAssertEqual(SourceTrackKey.parse("src:cfg::a::b")?.trackId, "a::b")
        XCTAssertEqual(SourceTrackKey.make(configId: "cfg", trackId: "t"), "src:cfg::t")
    }

    // MARK: Rebuilding the failed item

    func testAYouTubeEntryFallsBackToItsDirectUpload() {
        let song = Song(videoId: "5IX-nUxDtJI", title: "Bin Tere", artist: "Vishal & Shekhar", durationText: "4:01")
        XCTAssertEqual(
            PlaybackFallback.youTubeFallbackURI(for: song, currentURI: "vibramusic://watch?v=5IX-nUxDtJI&q=hifi"),
            "vibramusic://watch?v=5IX-nUxDtJI&n=Bin%20Tere&a=Vishal%20%26%20Shekhar&d=241&direct_youtube=1&q=original"
        )
    }

    func testASourceEntryKeepsItsMetadataToFindTheUpload() {
        let song = Song(videoId: "src:addon-1::3919244", title: "Bin Tere", artist: "Vishal & Shekhar")
        XCTAssertEqual(
            PlaybackFallback.youTubeFallbackURI(for: song, currentURI: "vibramusic://source?s=addon-1&t=3919244&n=Bin%20Tere&manifest_reopen=hls"),
            "vibramusic://source?s=addon-1&t=3919244&n=Bin%20Tere&direct_youtube=1&q=original"
        )
    }

    func testAFileHasNothingToFallBackTo() {
        let song = Song(videoId: "file:///a.flac", title: "t", artist: "a")
        XCTAssertNil(PlaybackFallback.youTubeFallbackURI(for: song, currentURI: "file:///a.flac"))
        let orphan = Song(videoId: "src:addon-1::1", title: "t", artist: "a")
        XCTAssertNil(PlaybackFallback.youTubeFallbackURI(for: orphan, currentURI: nil))
    }
}
