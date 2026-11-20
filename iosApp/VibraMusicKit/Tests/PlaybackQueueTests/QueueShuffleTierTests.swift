import XCTest
import VibraMusicCore
@testable import PlaybackQueue

/// Ports QueueShuffleTierTest: shuffle respects the queue's tiers, and entry ids keep duplicates apart.
final class QueueShuffleTierTests: XCTestCase {

    func testStartingOrderKeepsUserQueueAtTheFrontAndShufflesContext() {
        let input = [
            testSong("selected", entryId: "entry-selected"),
            testSong("u1", tier: .userQueue, entryId: "entry-u1"),
            testSong("u2", tier: .userQueue, entryId: "entry-u2"),
            testSong("c1", entryId: "entry-c1"),
            testSong("c2", entryId: "entry-c2"),
            testSong("c3", entryId: "entry-c3"),
            testSong("a1", tier: .autoplay, entryId: "entry-a1"),
        ]
        let (result, original) = QueueShuffle.startingOrder(input, startIndex: 0)
        XCTAssertEqual(result[0].videoId, "selected")
        XCTAssertEqual(result[1].videoId, "u1")
        XCTAssertEqual(result[2].videoId, "u2")
        XCTAssertEqual(Set(result[3..<6].map(\.videoId)), ["c1", "c2", "c3"])
        XCTAssertEqual(result[6].videoId, "a1")
        XCTAssertEqual(original, input.map { $0.queueEntryId! }, "the arrival order is remembered")
    }

    func testStartingOrderLeadsWithTheTappedTrackFromTheMiddle() {
        let input = (0..<5).map { testSong("t\($0)", entryId: "e\($0)") }
        let (result, _) = QueueShuffle.startingOrder(input, startIndex: 3, shuffler: { $0 })
        XCTAssertEqual(result.map(\.videoId), ["t3", "t0", "t1", "t2", "t4"])
    }

    func testRestoreOrderRestoresDuplicateSongsByTheirEntryIds() {
        let original = ["uuid-1", "uuid-2"]
        let shuffled = ["uuid-2", "uuid-1"]
        let restored = QueueShuffle.restoreOrder(upcoming: shuffled, original: original).map { shuffled[$0] }
        XCTAssertEqual(restored, original)
    }

    func testRestoringKeepsSectionsInOrderEvenIfTheOldOrderInterleavedThem() {
        let upcoming = [testSong("a1", tier: .autoplay, entryId: "a1"), testSong("u1", tier: .userQueue, entryId: "u1"), testSong("c1", entryId: "c1")]
        let restored = QueueShuffle.restoreOrder(upcoming: upcoming.map { $0.queueEntryId! }, original: ["a1", "c1", "u1"])
        XCTAssertEqual(QueueShuffle.sectioned(restored, upcoming: upcoming).map { upcoming[$0].videoId }, ["u1", "c1", "a1"])
    }

    /// Kotlin's "reproduce album alternating skip and shuffle toggle": skip and toggle shuffle over
    /// and over while AutoPlay appends near the end of the album; entry ids must stay unique.
    @MainActor
    func testAlternatingSkipsAndShuffleTogglesKeepEntryIdsUnique() {
        let controller = PlaybackQueueController(settings: makeSettings())
        controller.setItems((1...10).map { testSong("track-\($0)", entryId: "entry-\($0)") }, startIndex: 0)
        XCTAssertFalse(controller.state.shuffleEnabled)

        for step in 0..<20 {
            controller.skipToNext()
            if controller.state.currentIndex >= 8, controller.state.songs.count == 10 {
                controller.appendItems((1...5).map { testSong("autoplay-\($0)", tier: .autoplay, entryId: "entry-auto-\($0)") })
            }
            controller.toggleShuffle()
            let ids = controller.state.songs.map { $0.queueEntryId ?? $0.videoId }
            XCTAssertEqual(Set(ids).count, ids.count, "entry ids must stay unique at step \(step)")
            XCTAssertEqual(controller.state.songs.count, Set(controller.state.songs.map(\.videoId)).count)
        }
    }
}
