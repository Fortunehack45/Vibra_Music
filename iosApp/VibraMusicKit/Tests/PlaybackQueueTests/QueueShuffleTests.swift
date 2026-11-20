import XCTest
import VibraMusicCore
@testable import PlaybackQueue

/// Ports QueueShuffleTest: getting the queue into the order it should play in, and back.
final class QueueShuffleTests: XCTestCase {

    /// The upcoming stretch of the queue as turning shuffle off leaves it.
    private func restored(_ upcoming: [String], original: [String]) -> [String] {
        QueueShuffle.restoreOrder(upcoming: upcoming, original: original).map { upcoming[$0] }
    }

    func testAShuffledQueueStartsAtTheTappedTrackMovedToItsHead() {
        XCTAssertEqual(QueueShuffle.queueStartIndex(requestedIndex: 3, itemCount: 5, shuffled: true), 0)
    }

    func testAnUnshuffledQueueStartsAtTheTappedTracksListPosition() {
        XCTAssertEqual(QueueShuffle.queueStartIndex(requestedIndex: 3, itemCount: 5, shuffled: false), 3)
        XCTAssertEqual(QueueShuffle.queueStartIndex(requestedIndex: 9, itemCount: 5, shuffled: false), 4)
    }

    func testARandomIdentityIsRotatedSoTheFirstShuffleAlwaysMovesATrack() {
        XCTAssertEqual(QueueShuffle.avoidIdentityShuffle(original: [0, 1, 2], shuffled: [0, 1, 2]), [1, 2, 0])
    }

    func testAGenuinelyShuffledOrderIsKept() {
        XCTAssertEqual(QueueShuffle.avoidIdentityShuffle(original: [0, 1, 2], shuffled: [2, 0, 1]), [2, 0, 1])
    }

    func testAOneTrackSectionRemainsUnchanged() {
        XCTAssertEqual(QueueShuffle.avoidIdentityShuffle(original: [0], shuffled: [0]), [0])
    }

    func testTheQueueGoesBackIntoTheOrderItWasQueuedIn() {
        XCTAssertEqual(restored(["d", "b", "c"], original: ["a", "b", "c", "d"]), ["b", "c", "d"])
    }

    func testAnOrderAlreadyInPlaceIsLeftAsItIs() {
        XCTAssertEqual(restored(["b", "c", "d"], original: ["a", "b", "c", "d"]), ["b", "c", "d"])
    }

    func testAQueueHoldingTheSameTrackTwiceKeepsBothCopies() {
        XCTAssertEqual(restored(["b", "c", "b"], original: ["a", "b", "b", "c"]), ["b", "b", "c"])
    }

    func testTracksTheOldOrderDoesNotNameTrailBehindTheOnesItDoes() {
        // "e" was queued after the shuffle, so it stays at the end rather than displacing anything.
        XCTAssertEqual(restored(["e", "d", "b", "c"], original: ["a", "b", "c", "d"]), ["b", "c", "d", "e"])
    }

    func testATrackThatHasSinceBeenRemovedIsSkipped() {
        XCTAssertEqual(restored(["d", "b"], original: ["a", "b", "c", "d"]), ["b", "d"])
    }

    func testShufflingThenRestoringReturnsTheOriginalRunningOrder() {
        let original = "abcdefghij".map(String.init)
        for _ in 0..<50 {
            let upcoming = Array(original.dropFirst()).shuffled()
            XCTAssertEqual(restored(upcoming, original: original), Array(original.dropFirst()))
        }
    }

    /// The queues this runs on are playlists, and a per-track linear search over one is quadratic —
    /// the shape that used to hang the app. Ten thousand tracks is a fraction of a second here and
    /// minutes if that ever comes back.
    func testAVeryLongQueueIsRestoredWithoutAPerTrackSearch() {
        let original = (0..<10_000).map(String.init)
        let upcoming = original.shuffled()
        let started = Date()
        XCTAssertEqual(restored(upcoming, original: original), original)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testTheShuffledOrderKeepsSectionsAndNeverReturnsAnUnchangedSection() {
        let upcoming = [
            testSong("c1"), testSong("u1", tier: .userQueue), testSong("c2"),
            testSong("a1", tier: .autoplay), testSong("u2", tier: .userQueue), testSong("a2", tier: .autoplay),
        ]
        let identity: QueueShuffle.Shuffler = { $0 }
        let order = QueueShuffle.shuffledOrder(upcoming: upcoming, shuffler: identity)
        // User queue in place first; an identity draw is rotated within each section.
        XCTAssertEqual(order.map { upcoming[$0].videoId }, ["u1", "u2", "c2", "c1", "a2", "a1"])
    }
}

/// Shuffle through the controller: the toggle as the player's button and the album page's
/// Shuffle use it (PORTING "Shuffle and repeat": on then off puts the queue back).
@MainActor
final class QueueShuffleToggleTests: XCTestCase {

    private func album(_ count: Int) -> [Song] {
        (1...count).map { testSong("track-\($0)", entryId: "entry-\($0)") }
    }

    func testTurningShuffleOnThenOffPutsTheQueueBackInItsOriginalOrder() {
        let settings = makeSettings()
        let controller = PlaybackQueueController(settings: settings)
        controller.setItems(album(12), startIndex: 2)
        let before = controller.state.songs

        controller.toggleShuffle()
        XCTAssertTrue(controller.state.shuffleEnabled)
        XCTAssertTrue(settings.shuffleEnabled, "persisted")
        XCTAssertEqual(Array(controller.state.songs[...2]), Array(before[...2]), "the playing track and what's above it stay")
        XCTAssertNotEqual(controller.state.songs, before, "the first tap always moves something")
        XCTAssertEqual(Set(controller.state.songs.map(\.queueEntryId)), Set(before.map(\.queueEntryId)))

        controller.toggleShuffle()
        XCTAssertFalse(controller.state.shuffleEnabled)
        XCTAssertFalse(settings.shuffleEnabled)
        XCTAssertEqual(controller.state.songs, before)
    }

    func testRestoringAfterSkipsAndAdditionsKeepsNewTracksAtTheEnd() {
        let controller = PlaybackQueueController(settings: makeSettings())
        controller.setItems(album(8), startIndex: 0)
        controller.toggleShuffle()
        controller.skipToNext()
        controller.skipToNext()
        let playing = controller.state.currentSong
        controller.appendItems([testSong("late", tier: .autoplay, entryId: "entry-late")])

        controller.toggleShuffle()
        XCTAssertEqual(controller.state.currentSong, playing, "the playing track never moves")
        let upcoming = controller.state.upcoming.map(\.videoId)
        XCTAssertEqual(upcoming.last, "late")
        let albumUpcoming = upcoming.dropLast()
        XCTAssertEqual(Array(albumUpcoming), albumUpcoming.sorted { Int($0.dropFirst(6))! < Int($1.dropFirst(6))! })
    }

    func testTheUserQueueStaysPinnedAtTheFrontWhileShuffled() {
        let controller = PlaybackQueueController(settings: makeSettings())
        controller.setItems(album(6), startIndex: 0)
        controller.addToQueue(testSong("mine-1"))
        controller.addToQueue(testSong("mine-2"))
        controller.toggleShuffle()
        XCTAssertEqual(Array(controller.state.upcomingIds.prefix(2)), ["mine-1", "mine-2"])
        controller.toggleShuffle()
        XCTAssertEqual(controller.state.upcomingIds, ["mine-1", "mine-2", "track-2", "track-3", "track-4", "track-5", "track-6"])
    }

    func testShufflingAnEmptyTailJustFlipsTheState() {
        let controller = PlaybackQueueController(settings: makeSettings())
        controller.setItems([testSong("only")], startIndex: 0)
        controller.toggleShuffle()
        XCTAssertTrue(controller.state.shuffleEnabled)
        XCTAssertEqual(controller.state.ids, ["only"])
        controller.toggleShuffle()
        XCTAssertFalse(controller.state.shuffleEnabled)
    }

    func testTheAlbumPagesShuffleBuildsTheNextQueueShuffledWithTheTappedTrackFirst() {
        let settings = makeSettings()
        let controller = PlaybackQueueController(settings: settings)
        controller.shuffler = { $0.reversed() }
        let recorder = ItemChangeRecorder()
        recorder.attach(to: controller)

        controller.enableShuffleForNextQueue()
        XCTAssertTrue(settings.shuffleEnabled)
        let songs = album(5)
        controller.playFrom(songs, index: 2, source: QueueSource(title: "Album", type: .browse, id: "MPRE1"))
        XCTAssertEqual(controller.state.ids, ["track-3", "track-5", "track-4", "track-2", "track-1"])
        XCTAssertEqual(controller.state.currentIndex, 0)
        XCTAssertEqual(recorder.last?.song?.videoId, "track-3")
        XCTAssertEqual(recorder.last?.playback, .play)

        // Off again: the album's own order comes back behind the playing track.
        controller.toggleShuffle()
        XCTAssertEqual(controller.state.ids, ["track-3", "track-1", "track-2", "track-4", "track-5"])
    }

    func testShuffleStateIsRestoredFromSettingsAtLaunch() {
        let settings = makeSettings()
        settings.shuffleEnabled = true
        settings.repeatMode = .one
        let controller = PlaybackQueueController(settings: settings)
        XCTAssertTrue(controller.state.shuffleEnabled)
        XCTAssertEqual(controller.state.repeatMode, .one)
    }
}
