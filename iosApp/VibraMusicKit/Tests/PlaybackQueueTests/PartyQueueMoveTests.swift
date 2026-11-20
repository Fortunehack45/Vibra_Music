import XCTest
import VibraMusicCore
@testable import PlaybackQueue

/// Ports the queue-logic half of PartyQueueMoveTest: recognising a drag as a single move so a
/// party publishes one move rather than a whole new queue, and the tier a party track maps to.
/// The wire-format tests (PartyTrack / PartyPlayback serialization, sequence numbers) belong to
/// ListenTogether, which owns those types.
final class PartyQueueMoveTests: XCTestCase {

    func testDetectsASingleMoveForward() throws {
        let delta = try XCTUnwrap(QueueCoordinator.detectSingleMove(oldList: ["A", "B", "C", "D"], newList: ["A", "C", "D", "B"]))
        XCTAssertEqual(delta, .init(fromIndex: 1, toIndex: 3, videoId: "B"))
    }

    func testDetectsASingleMoveBackward() throws {
        let delta = try XCTUnwrap(QueueCoordinator.detectSingleMove(oldList: ["A", "C", "D", "B"], newList: ["A", "B", "C", "D"]))
        XCTAssertEqual(delta, .init(fromIndex: 3, toIndex: 1, videoId: "B"))
    }

    func testDetectsASingleMoveWithABaseOffset() throws {
        let delta = try XCTUnwrap(QueueCoordinator.detectSingleMove(oldList: ["B", "C", "D"], newList: ["D", "B", "C"], baseOffset: 5))
        XCTAssertEqual(delta, .init(fromIndex: 7, toIndex: 5, videoId: "D"))
    }

    func testIdenticalListsAreNotAMove() {
        XCTAssertNil(QueueCoordinator.detectSingleMove(oldList: ["A", "B", "C"], newList: ["A", "B", "C"]))
    }

    func testDifferentSizesAreNotAMove() {
        XCTAssertNil(QueueCoordinator.detectSingleMove(oldList: ["A", "B"], newList: ["A", "B", "C"]))
    }

    func testTwoIndependentSwapsAreNotASingleMove() {
        XCTAssertNil(QueueCoordinator.detectSingleMove(oldList: ["A", "B", "C", "D"], newList: ["B", "A", "D", "C"]))
    }

    func testDifferentContentIsNotAMove() {
        XCTAssertNil(QueueCoordinator.detectSingleMove(oldList: ["A", "B", "C"], newList: ["A", "C", "X"]))
        XCTAssertNil(QueueCoordinator.detectSingleMove(oldList: [], newList: []))
    }

    func testDuplicatesInTheListStillYieldAMoveThatReproducesTheNewList() throws {
        let old = ["A", "B", "A", "C"]
        let new = ["A", "A", "B", "C"]
        let delta = try XCTUnwrap(QueueCoordinator.detectSingleMove(oldList: old, newList: new))
        var reconstructed = old
        let item = reconstructed.remove(at: delta.fromIndex)
        reconstructed.insert(item, at: delta.toIndex)
        XCTAssertEqual(reconstructed, new)
    }

    /// A drag in the queue panel, as the controller applies it, is what a party sees as one move.
    @MainActor
    func testADragInTheQueueIsDetectedAsOneMove() throws {
        let controller = PlaybackQueueController(settings: makeSettings())
        controller.setItems(["now", "A", "B", "C", "D"].map { testSong($0) }, startIndex: 0)
        let before = controller.state.upcomingIds
        controller.moveInQueue(from: 1, to: 2)
        controller.moveInQueue(from: 2, to: 3)
        let delta = try XCTUnwrap(QueueCoordinator.detectSingleMove(oldList: before, newList: controller.state.upcomingIds, baseOffset: 1))
        XCTAssertEqual(delta, .init(fromIndex: 1, toIndex: 3, videoId: "A"))
    }

    /// PartyTrack.toSong maps a manual track to USER_QUEUE and AutoPlay's to AUTOPLAY; a party
    /// playback queue keeps only the manual ones (via ``PartyQueueEntry``).
    func testPartyEntriesKeepOnlyManualTracksAsUserQueue() {
        let manual = testSong("manual", tier: .userQueue)
        let auto = testSong("auto", tier: .autoplay)
        XCTAssertFalse(manual.fromAutoplay)
        XCTAssertTrue(auto.fromAutoplay)
        let timeline = QueueCoordinator.buildPartyPlaybackQueue(
            tappedSong: testSong("tapped"),
            source: QueueSource(title: "Search", type: .search),
            upcomingPartyTracks: [manual, auto]
        )
        XCTAssertEqual(timeline.map(\.videoId), ["tapped", "manual"])
        XCTAssertEqual(timeline.map(\.queueTier), [.context, .userQueue])
    }

    /// The app makes ListenTogether's PartyTrack conform; any conforming type works.
    func testAnyPartyQueueEntryCanFeedAPartyQueue() {
        struct WireTrack: PartyQueueEntry {
            var videoId: String
            var fromAutoplay: Bool
            func asQueueSong() -> Song {
                Song(videoId: videoId, title: videoId, artist: "", queueTier: fromAutoplay ? .autoplay : .userQueue)
            }
        }
        let timeline = QueueCoordinator.buildPartyPlaybackQueue(
            tappedSong: testSong("tapped"),
            source: QueueSource(title: "Search", type: .search),
            upcomingPartyTracks: [WireTrack(videoId: "m", fromAutoplay: false), WireTrack(videoId: "a", fromAutoplay: true)]
        )
        XCTAssertEqual(timeline.map(\.videoId), ["tapped", "m"])
        XCTAssertNotNil(timeline[1].queueEntryId)
    }
}
