import XCTest
@testable import PlaybackQueue

/// Ports QueueHistoryTest: how much of the played queue is kept, live and on disk.
final class QueueHistoryTests: XCTestCase {

    func testHistoryRetainsAtMostTwentyFiveSongs() {
        XCTAssertEqual(QueueHistory.trimCount(currentIndex: QueueHistory.maxEntries), 0)
        XCTAssertEqual(QueueHistory.trimCount(currentIndex: QueueHistory.maxEntries + 1), 1)
        XCTAssertEqual(QueueHistory.trimCount(currentIndex: 100), 75)
    }

    func testADirectForwardChoiceRemovesOnlyBypassedSongs() {
        XCTAssertEqual(QueueHistory.skippedByJump(currentIndex: 2, targetIndex: 7), 3..<7)
    }

    func testNextAndPreviousNavigationPreserveTheQueue() {
        XCTAssertNil(QueueHistory.skippedByJump(currentIndex: 2, targetIndex: 3))
        XCTAssertNil(QueueHistory.skippedByJump(currentIndex: 7, targetIndex: 2))
    }

    func testStartingInTheMiddleDoesNotTurnEarlierUnplayedRowsIntoHistory() {
        XCTAssertEqual(QueueHistory.startingAt(["a", "b", "c", "d"], 2), ["c", "d"])
        XCTAssertEqual(QueueHistory.startingAt(["a", "b"], 9), ["b"])
        XCTAssertEqual(QueueHistory.startingAt([String](), 0), [])
    }

    func testPersistedQueueWindowIsBoundedIndependentlyOfLiveQueueSize() {
        let window = LastPlayedStore.window(size: 10_000, index: 5_000)
        XCTAssertEqual(window.lowerBound, 4_975)
        XCTAssertEqual(window.count, 76)
    }

    func testPersistedQueueNeverRestoresMoreThanTwentyFiveHistoryRows() {
        let window = LastPlayedStore.window(size: 10_000, index: 9_999)
        XCTAssertEqual(window.lowerBound, 9_974)
        XCTAssertEqual(window.count, 26)
    }

    func testPersistedWindowClampsAndHandlesAnEmptyQueue() {
        XCTAssertEqual(LastPlayedStore.window(size: 0, index: 3), 0..<0)
        XCTAssertEqual(LastPlayedStore.window(size: 10, index: 99), 0..<10)
        XCTAssertEqual(LastPlayedStore.window(size: 100, index: -4), 0..<51)
    }

    /// The live queue itself keeps 25 played entries: older ones go on each transition, or rotate to
    /// the end under repeat-all so the loop goes on.
    @MainActor
    func testTheLiveQueueTrimsHistoryOrRotatesItUnderRepeatAll() {
        let songs = (0..<40).map { testSong("s\($0)") }
        let controller = PlaybackQueueController(settings: makeSettings())
        controller.setItems(songs, startIndex: 30)
        XCTAssertEqual(controller.state.songs.count, 35)
        XCTAssertEqual(controller.state.currentSong?.videoId, "s30")
        XCTAssertEqual(controller.state.currentIndex, 25)
        XCTAssertEqual(controller.state.songs.first?.videoId, "s5")

        controller.setRepeatMode(.all)
        controller.trackDidFinish()
        XCTAssertEqual(controller.state.currentSong?.videoId, "s31")
        XCTAssertEqual(controller.state.currentIndex, 25)
        XCTAssertEqual(controller.state.songs.count, 35, "rotated, not deleted")
        XCTAssertEqual(controller.state.songs.last?.videoId, "s5")
    }
}
