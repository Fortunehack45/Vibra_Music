import XCTest
import VibraMusicCore
@testable import PlaybackQueue

/// Ports DislikeSkipPolicyTest: disliking the song that's playing skips it, and nothing else does.
final class DislikeSkipPolicyTests: XCTestCase {

    func testIndifferentCurrentTrackSkips() {
        XCTAssertTrue(DislikeSkipPolicy.shouldSkip(previousStatus: .indifferent, targetVideoId: "target", currentVideoId: "target"))
    }

    func testLikedCurrentTrackSkips() {
        XCTAssertTrue(DislikeSkipPolicy.shouldSkip(previousStatus: .like, targetVideoId: "target", currentVideoId: "target"))
    }

    func testUndoingDislikeOnCurrentTrackDoesNotSkip() {
        XCTAssertFalse(DislikeSkipPolicy.shouldSkip(previousStatus: .dislike, targetVideoId: "target", currentVideoId: "target"))
    }

    func testIndifferentNonCurrentTrackDoesNotSkip() {
        XCTAssertFalse(DislikeSkipPolicy.shouldSkip(previousStatus: .indifferent, targetVideoId: "target", currentVideoId: "current"))
    }

    func testLikedNonCurrentTrackDoesNotSkip() {
        XCTAssertFalse(DislikeSkipPolicy.shouldSkip(previousStatus: .like, targetVideoId: "target", currentVideoId: "current"))
    }

    func testMissingCurrentTrackDoesNotSkip() {
        XCTAssertFalse(DislikeSkipPolicy.shouldSkip(previousStatus: .indifferent, targetVideoId: "target", currentVideoId: nil))
    }

    @MainActor
    func testDislikingThePlayingSongMovesTheQueueOn() {
        let controller = PlaybackQueueController(settings: makeSettings())
        let recorder = ItemChangeRecorder()
        recorder.attach(to: controller)
        controller.setItems([testSong("a"), testSong("b"), testSong("c")], startIndex: 0)

        XCTAssertFalse(controller.dislikeToggled(previousStatus: .indifferent, videoId: "c"), "not the playing song")
        XCTAssertEqual(controller.state.currentSong?.videoId, "a")
        XCTAssertFalse(controller.dislikeToggled(previousStatus: .dislike, videoId: "a"), "undoing a dislike")
        XCTAssertEqual(controller.state.currentSong?.videoId, "a")

        XCTAssertTrue(controller.dislikeToggled(previousStatus: .like, videoId: "a"))
        XCTAssertEqual(controller.state.currentSong?.videoId, "b")
        XCTAssertEqual(recorder.last?.reason, .skipNext)
        XCTAssertEqual(recorder.last?.playback, .keep)
    }
}
