import XCTest
import VibraMusicCore
@testable import PlaybackQueue

/// Ports QueueCoordinatorTest: how the two-tier queue is built, extended, jumped through and pruned.
/// The Kotlin tests that drove a fake Media3 player run here against the pure functions and against
/// ``PlaybackQueueController``, which applies them.
final class QueueCoordinatorTests: XCTestCase {

    private let abbeyRoad = QueueSource(title: "Abbey Road", type: .browse, id: "album-id")

    // MARK: asQueueEntry

    func testAsQueueEntryGeneratesAUniqueEntryIdWhenMissing() {
        let entry = testSong("song1").asQueueEntry(.userQueue)
        XCTAssertNotNil(entry.queueEntryId)
        XCTAssertEqual(entry.queueTier, .userQueue)
        XCTAssertNotEqual(testSong("song1").asQueueEntry(.userQueue).queueEntryId, entry.queueEntryId)
    }

    func testAsQueueEntryPreservesAnExistingEntryId() {
        let entry = testSong("song1", entryId: "entry-123").asQueueEntry(.context)
        XCTAssertEqual(entry.queueEntryId, "entry-123")
        XCTAssertEqual(entry.queueTier, .context)
    }

    // MARK: buildContextQueue

    func testContextQueueKeepsOrderPutsUserQueueBehindSelectedAndStartsAtIt() {
        let userQ1 = testSong("u1", tier: .userQueue, entryId: "entry-u1")
        let userQ2 = testSong("u2", tier: .userQueue, entryId: "entry-u2")
        let current = [testSong("now"), userQ1, userQ2, testSong("old-auto", tier: .autoplay)]

        let result = QueueCoordinator.buildContextQueue(
            currentTimeline: current,
            currentIndex: 0,
            newContextSongs: [testSong("album-1"), testSong("album-2"), testSong("album-3")],
            selectedIndex: 1,
            contextSource: abbeyRoad
        )

        XCTAssertEqual(result.startIndex, 1)
        XCTAssertEqual(result.timeline.map(\.videoId), ["album-1", "album-2", "u1", "u2", "album-3"])
        for index in [0, 1, 4] {
            XCTAssertEqual(result.timeline[index].queueTier, .context)
            XCTAssertEqual(result.timeline[index].playbackSource, "Abbey Road")
            XCTAssertEqual(result.timeline[index].playbackSourceType, .browse)
            XCTAssertEqual(result.timeline[index].playbackSourceId, "album-id")
            XCTAssertNotNil(result.timeline[index].queueEntryId)
        }
        XCTAssertEqual(result.timeline[2].queueEntryId, "entry-u1")
        XCTAssertEqual(result.timeline[2].queueTier, .userQueue)
        XCTAssertEqual(result.timeline[3].queueEntryId, "entry-u2")
        XCTAssertEqual(result.timeline[3].queueTier, .userQueue)
    }

    func testContextQueueFromTheFirstTrackHasNoPrecedingContext() {
        let result = QueueCoordinator.buildContextQueue(
            currentTimeline: [testSong("now"), testSong("u1", tier: .userQueue, entryId: "entry-u1")],
            currentIndex: 0,
            newContextSongs: [testSong("album-1"), testSong("album-2"), testSong("album-3")],
            selectedIndex: 0,
            contextSource: abbeyRoad
        )
        XCTAssertEqual(result.startIndex, 0)
        XCTAssertEqual(result.timeline.map(\.videoId), ["album-1", "u1", "album-2", "album-3"])
    }

    func testContextQueueFromTheLastTrackHasNoFollowingContext() {
        let result = QueueCoordinator.buildContextQueue(
            currentTimeline: [testSong("now"), testSong("u1", tier: .userQueue, entryId: "entry-u1")],
            currentIndex: 0,
            newContextSongs: [testSong("album-1"), testSong("album-2"), testSong("album-3")],
            selectedIndex: 2,
            contextSource: abbeyRoad
        )
        XCTAssertEqual(result.startIndex, 2)
        XCTAssertEqual(result.timeline.map(\.videoId), ["album-1", "album-2", "album-3", "u1"])
    }

    func testContextQueueWithNoUserQueueKeepsTheExactContextOrder() {
        let result = QueueCoordinator.buildContextQueue(
            currentTimeline: [testSong("now")],
            currentIndex: 0,
            newContextSongs: [testSong("album-1"), testSong("album-2"), testSong("album-3")],
            selectedIndex: 1,
            contextSource: abbeyRoad
        )
        XCTAssertEqual(result.startIndex, 1)
        XCTAssertEqual(result.timeline.map(\.videoId), ["album-1", "album-2", "album-3"])
    }

    func testContextQueueHandlesAnEmptyContextAndOutOfRangeSelections() {
        let empty = QueueCoordinator.buildContextQueue(
            currentTimeline: [], currentIndex: -1, newContextSongs: [], selectedIndex: 0,
            contextSource: QueueSource(title: "Empty", type: .browse)
        )
        XCTAssertEqual(empty.startIndex, 0)
        XCTAssertEqual(empty.timeline, [])

        let album = [testSong("album-1"), testSong("album-2")]
        let underflow = QueueCoordinator.buildContextQueue(
            currentTimeline: [], currentIndex: -1, newContextSongs: album, selectedIndex: -10,
            contextSource: QueueSource(title: "Test", type: .browse)
        )
        XCTAssertEqual(underflow.startIndex, 0)
        XCTAssertEqual(underflow.timeline[0].videoId, "album-1")

        let overflow = QueueCoordinator.buildContextQueue(
            currentTimeline: [], currentIndex: -1, newContextSongs: album, selectedIndex: 50,
            contextSource: QueueSource(title: "Test", type: .browse)
        )
        XCTAssertEqual(overflow.startIndex, 1)
        XCTAssertEqual(overflow.timeline[1].videoId, "album-2")
    }

    func testContextQueueDropsUserQueueAlreadyBehindThePlayhead() {
        // Only what is still to come is preserved; a user-queued track already played is history.
        let result = QueueCoordinator.buildContextQueue(
            currentTimeline: [testSong("u0", tier: .userQueue), testSong("now"), testSong("u1", tier: .userQueue)],
            currentIndex: 1,
            newContextSongs: [testSong("album-1")],
            selectedIndex: 0,
            contextSource: abbeyRoad
        )
        XCTAssertEqual(result.timeline.map(\.videoId), ["album-1", "u1"])
    }

    // MARK: buildOneOffQueue

    func testOneOffQueueKeepsUpcomingUserQueueBehindTheTappedSong() {
        let result = QueueCoordinator.buildOneOffQueue(
            currentTimeline: [testSong("now"), testSong("u1", tier: .userQueue, entryId: "entry-u1"), testSong("old-auto", tier: .autoplay)],
            currentIndex: 0,
            tappedSong: testSong("search-song"),
            source: QueueSource(title: "Search", type: .search)
        )
        XCTAssertEqual(result.map(\.videoId), ["search-song", "u1"])
        XCTAssertEqual(result[0].queueTier, .context)
        XCTAssertEqual(result[0].playbackSource, "Search")
        XCTAssertEqual(result[0].playbackSourceType, .search)
        XCTAssertEqual(result[1].queueEntryId, "entry-u1")
        XCTAssertEqual(result[1].queueTier, .userQueue)
    }

    // MARK: findUserQueueInsertionIndex

    func testPlayNextInsertsRightAfterTheCurrentEntry() {
        let timeline = [testSong("song0"), testSong("u1", tier: .userQueue), testSong("c1")]
        XCTAssertEqual(QueueCoordinator.findUserQueueInsertionIndex(timeline: timeline, currentIndex: 0, isNext: true), 1)
    }

    func testAddToQueueInsertsAfterTheLastUserQueueEntry() {
        let timeline = [
            testSong("song0"), testSong("u1", tier: .userQueue), testSong("u2", tier: .userQueue),
            testSong("c1"), testSong("a1", tier: .autoplay),
        ]
        XCTAssertEqual(QueueCoordinator.findUserQueueInsertionIndex(timeline: timeline, currentIndex: 0, isNext: false), 3)
    }

    func testAddToQueueWithNoUserQueueInsertsAheadOfContext() {
        let timeline = [testSong("song0"), testSong("c1"), testSong("c2")]
        XCTAssertEqual(QueueCoordinator.findUserQueueInsertionIndex(timeline: timeline, currentIndex: 0, isNext: false), 1)
    }

    func testInsertionIntoAnEmptyOrFullyUserQueuedTimeline() {
        XCTAssertEqual(QueueCoordinator.findUserQueueInsertionIndex(timeline: [], currentIndex: 0, isNext: false), 0)
        let allUser = [testSong("now"), testSong("u1", tier: .userQueue)]
        XCTAssertEqual(QueueCoordinator.findUserQueueInsertionIndex(timeline: allUser, currentIndex: 0, isNext: false), 2)
    }

    // MARK: clearing and consuming the user queue

    @MainActor
    func testClearUserQueueRemovesOnlyUpcomingUserQueueEntries() {
        let songs = [
            testSong("playing"), testSong("u1", tier: .userQueue), testSong("u2", tier: .userQueue),
            testSong("c1"), testSong("a1", tier: .autoplay),
        ]
        XCTAssertEqual(QueueCoordinator.userQueueIndicesToClear(timeline: songs, currentIndex: 0), [1, 2])

        let controller = PlaybackQueueController(settings: makeSettings())
        controller.setItems(songs, startIndex: 0)
        XCTAssertEqual(controller.clearUserQueue(), .done)
        XCTAssertEqual(controller.state.ids, ["playing", "c1", "a1"])
    }

    @MainActor
    func testConsumePlayedUserQueuePrunesItOnEnteringContext() {
        let songs = [testSong("u1", tier: .userQueue), testSong("u2", tier: .userQueue), testSong("c1"), testSong("c2")]
        XCTAssertEqual(QueueCoordinator.playedUserQueueIndices(timeline: songs, currentIndex: 2), [0, 1])
        XCTAssertEqual(QueueCoordinator.playedUserQueueIndices(timeline: songs, currentIndex: 1), [], "still inside the user queue")
        XCTAssertEqual(QueueCoordinator.playedUserQueueIndices(timeline: songs, currentIndex: 0), [])

        // The controller applies it on every transition.
        let controller = PlaybackQueueController(settings: makeSettings())
        controller.setItems(songs, startIndex: 0)
        controller.trackDidFinish()
        XCTAssertEqual(controller.state.ids, ["u1", "u2", "c1", "c2"])
        controller.trackDidFinish()
        XCTAssertEqual(controller.state.ids, ["c1", "c2"])
        XCTAssertEqual(controller.state.currentSong?.videoId, "c1")
        XCTAssertEqual(controller.state.currentIndex, 0)
    }

    // MARK: buildJumpQueue

    func testJumpToAnAutoplayTrackKeepsTheUserQueueAndPromotesTheTargetToContext() throws {
        let timeline = [
            testSong("now"),
            testSong("u1", tier: .userQueue, entryId: "entry-u1"),
            testSong("u2", tier: .userQueue, entryId: "entry-u2"),
            testSong("c1"),
            testSong("a1", tier: .autoplay),
            testSong("a2", tier: .autoplay, entryId: "entry-a2", source: "Radio Seed"),
        ]
        let result = try XCTUnwrap(QueueCoordinator.buildJumpQueue(currentTimeline: timeline, currentIndex: 0, targetIndex: 5))
        XCTAssertEqual(result.map(\.videoId), ["a2", "u1", "u2"])
        XCTAssertEqual(result[0].queueTier, .context)
        XCTAssertEqual(result[0].playbackSourceType, .queue)
        XCTAssertEqual(result[0].playbackSource, "Radio Seed")
        XCTAssertEqual(result[0].queueEntryId, "entry-a2", "promotion keeps the entry's identity")
        XCTAssertEqual(result[1].queueEntryId, "entry-u1")
        XCTAssertEqual(result[2].queueEntryId, "entry-u2")
        XCTAssertEqual(result[1].queueTier, .userQueue)
    }

    func testAPromotedAutoplayTrackWithoutASourceIsNamedAfterItself() throws {
        let timeline = [testSong("now"), testSong("a1", tier: .autoplay, source: "  ")]
        let result = try XCTUnwrap(QueueCoordinator.buildJumpQueue(currentTimeline: timeline, currentIndex: 0, targetIndex: 1))
        XCTAssertEqual(result[0].playbackSource, "Title a1")
    }

    func testJumpToAContextTrackKeepsAutoplay() throws {
        let timeline = [testSong("now"), testSong("c1"), testSong("c2"), testSong("a1", tier: .autoplay), testSong("a2", tier: .autoplay)]
        let result = try XCTUnwrap(QueueCoordinator.buildJumpQueue(currentTimeline: timeline, currentIndex: 0, targetIndex: 1))
        XCTAssertEqual(result.map(\.videoId), ["c1", "c2", "a1", "a2"])
        XCTAssertEqual(result[2].queueTier, .autoplay)
        XCTAssertEqual(result[3].queueTier, .autoplay)
    }

    func testJumpToAMiddleAutoplayTrackKeepsTheAutoplayAfterIt() throws {
        let timeline = [
            testSong("now"), testSong("u1", tier: .userQueue), testSong("c1"),
            testSong("a1", tier: .autoplay), testSong("a2", tier: .autoplay), testSong("a3", tier: .autoplay),
        ]
        let result = try XCTUnwrap(QueueCoordinator.buildJumpQueue(currentTimeline: timeline, currentIndex: 0, targetIndex: 4))
        // a1 was skipped over and c1 was the old context; a3 is still to come.
        XCTAssertEqual(result.map(\.videoId), ["a2", "u1", "a3"])
        XCTAssertEqual(result[0].queueTier, .context)
        XCTAssertEqual(result[2].queueTier, .autoplay)
    }

    func testJumpToAContextTrackWithInterleavedUserQueueKeepsEveryUserQueueEntry() throws {
        let timeline = [
            testSong("now"), testSong("c1"), testSong("u1", tier: .userQueue, entryId: "entry-u1"),
            testSong("c2"), testSong("u2", tier: .userQueue, entryId: "entry-u2"), testSong("c3"),
        ]
        let result = try XCTUnwrap(QueueCoordinator.buildJumpQueue(currentTimeline: timeline, currentIndex: 0, targetIndex: 3))
        XCTAssertEqual(result.map(\.videoId), ["c2", "u1", "u2", "c3"])
        XCTAssertEqual(result.map(\.queueTier), [.context, .userQueue, .userQueue, .context])
    }

    func testJumpToAUserQueueTrackDropsSkippedUserQueueButKeepsTheRest() throws {
        let timeline = [
            testSong("now"), testSong("u1", tier: .userQueue), testSong("u2", tier: .userQueue),
            testSong("u3", tier: .userQueue), testSong("c1"), testSong("a1", tier: .autoplay),
        ]
        let result = try XCTUnwrap(QueueCoordinator.buildJumpQueue(currentTimeline: timeline, currentIndex: 0, targetIndex: 2))
        XCTAssertEqual(result.map(\.videoId), ["u2", "u3", "c1", "a1"])
        XCTAssertEqual(result.map(\.queueTier), [.userQueue, .userQueue, .context, .autoplay])
    }

    func testJumpQueueIsNilForBackwardSameOrOutOfRangeJumps() {
        let timeline = [testSong("s0"), testSong("s1"), testSong("s2")]
        XCTAssertNil(QueueCoordinator.buildJumpQueue(currentTimeline: timeline, currentIndex: 1, targetIndex: 1))
        XCTAssertNil(QueueCoordinator.buildJumpQueue(currentTimeline: timeline, currentIndex: 2, targetIndex: 1))
        XCTAssertNil(QueueCoordinator.buildJumpQueue(currentTimeline: timeline, currentIndex: 0, targetIndex: 10))
        XCTAssertNil(QueueCoordinator.buildJumpQueue(currentTimeline: timeline, currentIndex: -1, targetIndex: 1))
        XCTAssertNil(QueueCoordinator.buildJumpQueue(currentTimeline: timeline, currentIndex: 0, targetIndex: -1))
    }

    // MARK: jumpToQueueItem

    @MainActor
    func testJumpingForwardKeepsHistoryAndInstallsTheNewUpcomingQueue() {
        let songs = [
            testSong("history0", entryId: "e0"),
            testSong("u1", tier: .userQueue, entryId: "entry-u1"),
            testSong("c1", entryId: "e2"),
            testSong("a1", tier: .autoplay, entryId: "e3"),
        ]
        let plan = QueueCoordinator.jumpPlan(timeline: songs, currentIndex: 0, targetIndex: 3)
        XCTAssertEqual(plan?.timeline.map(\.videoId), ["history0", "a1", "u1"])
        XCTAssertEqual(plan?.startIndex, 1)

        let controller = PlaybackQueueController(settings: makeSettings())
        let recorder = ItemChangeRecorder()
        recorder.attach(to: controller)
        controller.setItems(songs, startIndex: 0)
        XCTAssertEqual(controller.jump(to: 3), .done)
        XCTAssertEqual(controller.state.ids, ["history0", "a1", "u1"])
        XCTAssertEqual(controller.state.currentIndex, 1)
        XCTAssertEqual(controller.state.currentSong?.queueTier, .context, "the AutoPlay target was promoted")
        XCTAssertEqual(recorder.last?.reason, .jump)
        XCTAssertEqual(recorder.last?.playback, .play)
        XCTAssertEqual(recorder.last?.song?.videoId, "a1")
    }

    @MainActor
    func testJumpingBackwardSeeksWithoutChangingTheQueue() {
        let songs = [testSong("s0"), testSong("s1"), testSong("s2")]
        let controller = PlaybackQueueController(settings: makeSettings())
        let recorder = ItemChangeRecorder()
        recorder.attach(to: controller)
        controller.setItems(songs, startIndex: 2)
        controller.jump(to: 0)
        XCTAssertEqual(controller.state.ids, ["s0", "s1", "s2"])
        XCTAssertEqual(controller.state.currentIndex, 0)
        XCTAssertEqual(recorder.last?.playback, .play)

        // A tap on the playing row restarts it.
        recorder.reset()
        controller.jump(to: 0)
        XCTAssertEqual(recorder.changes.count, 1)
        XCTAssertEqual(recorder.last?.startPositionMs, 0)
        XCTAssertEqual(controller.jump(to: 7), .ignored)
    }

    // MARK: System seeks (the session's seekTo(index))

    func testASystemSeekToUserQueueConsumesOnlySkippedUserQueue() throws {
        let timeline = [
            testSong("now"), testSong("c1"), testSong("u1", tier: .userQueue),
            testSong("c2"), testSong("u2", tier: .userQueue),
        ]
        let plan = try XCTUnwrap(QueueCoordinator.systemSeekPlan(timeline: timeline, currentIndex: 0, targetIndex: 4))
        // u1 (skipped user queue) goes; c1 and c2 stay, and u2 moves up to play next.
        XCTAssertEqual(plan.timeline.map(\.videoId), ["now", "u2", "c1", "c2"])
        XCTAssertEqual(plan.startIndex, 1)
    }

    func testASystemSeekToContextNeverDeletesUserQueue() throws {
        let timeline = [
            testSong("now"), testSong("u1", tier: .userQueue), testSong("c1"),
            testSong("a1", tier: .autoplay), testSong("c2"),
        ]
        let plan = try XCTUnwrap(QueueCoordinator.systemSeekPlan(timeline: timeline, currentIndex: 0, targetIndex: 4))
        XCTAssertEqual(plan.timeline.map(\.videoId), ["now", "c2", "u1"])
        XCTAssertEqual(plan.startIndex, 1)
    }

    func testASystemSeekToTheNextRowOrBackwardIsAPlainSeek() throws {
        let timeline = [testSong("s0"), testSong("s1"), testSong("s2")]
        let next = try XCTUnwrap(QueueCoordinator.systemSeekPlan(timeline: timeline, currentIndex: 1, targetIndex: 2))
        XCTAssertEqual(next.timeline, timeline)
        XCTAssertEqual(next.startIndex, 2)
        let back = try XCTUnwrap(QueueCoordinator.systemSeekPlan(timeline: timeline, currentIndex: 2, targetIndex: 0))
        XCTAssertEqual(back.startIndex, 0)
        XCTAssertNil(QueueCoordinator.systemSeekPlan(timeline: timeline, currentIndex: 0, targetIndex: 3))
    }
}
