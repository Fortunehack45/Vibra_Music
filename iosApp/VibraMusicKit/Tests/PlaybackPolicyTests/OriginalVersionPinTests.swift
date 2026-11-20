import XCTest
import Observation
import VibraMusicCore
import VibraMusicTestSupport
@testable import PlaybackPolicy

/// "Revert to original" plays YouTube's own upload, and stays that way after a relaunch
/// (PORTING.md, Quality upgrade and revert to original).
final class OriginalVersionPinTests: XCTestCase {
    private let song = Song(videoId: "5IX-nUxDtJI", title: "Bin Tere", artist: "Vishal & Shekhar", durationText: "4:01")

    func testARevertPinsTheTrackAndRebuildsItOnYouTubesOwnUpload() {
        let pins = OriginalVersion(defaults: makeEphemeralDefaults())

        let uri = pins.revert(song)

        XCTAssertEqual(uri, "vibramusic://watch?v=5IX-nUxDtJI&n=Bin%20Tere&a=Vishal%20%26%20Shekhar&d=241&direct_youtube=1&q=original")
        XCTAssertTrue(pins.isPinned(song.videoId))
        XCTAssertNil(pins.revert(song), "already there: nothing more to revert")
    }

    /// The pin is written down, so the next process builds the track straight onto YouTube's upload
    /// — from a list, from CarPlay, from the restored queue.
    func testAPinSurvivesARelaunch() {
        let defaults = makeEphemeralDefaults()
        OriginalVersion(defaults: defaults).revert(song)

        let relaunched = OriginalVersion(defaults: defaults)

        XCTAssertTrue(relaunched.isPinned(song.videoId))
        let rebuilt = PlaybackURI.forStreaming(song, pinnedToOriginal: relaunched.isPinned(song.videoId))
        XCTAssertEqual(PlaybackURI.queryValue(PlaybackURI.directYouTubeParameter, in: rebuilt), "1")
        XCTAssertEqual(QualityUpgrade.cacheTag(rebuilt), "original")
        XCTAssertFalse(
            PlaybackFallback.isAlternative(rebuilt, substitutedYouTube: false),
            "a pinned item never resolves to a substitute"
        )
    }

    /// "Upgrade quality" is the way back out, and it too survives a relaunch.
    func testUnpinningLetsTheTrackBeSubstitutedAgain() {
        let defaults = makeEphemeralDefaults()
        let pins = OriginalVersion(defaults: defaults)
        pins.pin(song.videoId)
        pins.unpin(song.videoId)

        XCTAssertFalse(pins.isPinned(song.videoId))
        XCTAssertFalse(OriginalVersion(defaults: defaults).isPinned(song.videoId))
        XCTAssertEqual(
            PlaybackURI.forStreaming(song, pinnedToOriginal: pins.isPinned(song.videoId)),
            "vibramusic://watch?v=5IX-nUxDtJI&n=Bin%20Tere&a=Vishal%20%26%20Shekhar&d=241"
        )
    }

    /// Only the listener's own revert pins, and only for a track with an upload behind it.
    func testTracksWithNothingToRevertToAreNotPinned() {
        let pins = OriginalVersion(defaults: nil)
        XCTAssertNil(pins.revert(Song(videoId: "src:addon-1::1", title: "t", artist: "a")))
        XCTAssertNil(pins.revert(Song(videoId: "x", title: "t", artist: "a", localUri: "file:///x.m4a")))
        XCTAssertNil(pins.revert(Song(videoId: "v", title: "t", artist: "a", isVideo: true)))
        XCTAssertTrue(pins.pinned.isEmpty)
        pins.pin("   ")
        XCTAssertTrue(pins.pinned.isEmpty, "a blank id is not a track")
    }

    /// Oldest first out: the newest entry is the one the listener just made.
    func testTheCapEvictsTheOldestPin() {
        let defaults = makeEphemeralDefaults()
        let pins = OriginalVersion(defaults: defaults)
        for index in 0...OriginalVersion.maxPinned {
            pins.pin("track-\(index)")
        }

        XCTAssertEqual(pins.pinned.count, OriginalVersion.maxPinned)
        XCTAssertFalse(pins.isPinned("track-0"))
        XCTAssertTrue(pins.isPinned("track-1"))
        XCTAssertTrue(pins.isPinned("track-\(OriginalVersion.maxPinned)"))
        XCTAssertEqual(OriginalVersion(defaults: defaults).pinnedInOrder.first, "track-1", "order survives the round trip")
    }

    func testReloadPicksUpAnotherWriter() {
        let defaults = makeEphemeralDefaults()
        let pins = OriginalVersion(defaults: defaults)
        OriginalVersion(defaults: defaults).pin("from-elsewhere")
        XCTAssertFalse(pins.isPinned("from-elsewhere"))
        pins.reload()
        XCTAssertTrue(pins.isPinned("from-elsewhere"))
    }

    /// The menu observes the pins to offer the right row.
    func testPinningIsObservable() {
        let pins = OriginalVersion(defaults: nil)
        let changed = expectation(description: "pinned changed")
        withObservationTracking {
            _ = pins.pinned
        } onChange: {
            changed.fulfill()
        }
        pins.pin(song.videoId)
        wait(for: [changed], timeout: 2)
    }
}
