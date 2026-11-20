import Observation
import XCTest
import VibraMusicCore
@testable import PlaybackQueue

/// The queue operations MainActivity and PlayerConnection perform, through the controller: play,
/// play next, add to queue, jump, drag, remove, clear, skip, repeat, and the party and lock rules.
@MainActor
final class PlaybackQueueControllerTests: XCTestCase {

    private var settings: AppSettings!
    private var controller: PlaybackQueueController!
    private var recorder: ItemChangeRecorder!
    private var intents = 0

    override func setUp() async throws {
        await MainActor.run {
            settings = makeSettings()
            controller = PlaybackQueueController(settings: settings)
            recorder = ItemChangeRecorder()
            recorder.attach(to: controller)
            intents = 0
            controller.onLocalIntent = { [unowned self] in self.intents += 1 }
        }
    }

    private let album = QueueSource(title: "Abbey Road", type: .browse, id: "MPREb_abbey")

    // MARK: Starting queues

    func testPlayingFromAnAlbumStartsAtTheTappedTrackAndStampsTheSource() {
        controller.playFrom((1...5).map { testSong("t\($0)") }, index: 2, source: album)
        XCTAssertEqual(controller.state.ids, ["t1", "t2", "t3", "t4", "t5"])
        XCTAssertEqual(controller.state.currentIndex, 2)
        XCTAssertTrue(controller.state.songs.allSatisfy { $0.playbackSource == "Abbey Road" && $0.queueTier == .context })
        XCTAssertEqual(Set(controller.state.songs.compactMap(\.queueEntryId)).count, 5)
        XCTAssertEqual(recorder.changes, [QueueItemChange(song: controller.state.currentSong, index: 2, startPositionMs: 0, reason: .newQueue, playback: .play)])
        XCTAssertEqual(controller.playingFrom, album)
        XCTAssertEqual(intents, 1)
    }

    func testANewAlbumKeepsTheUpcomingUserQueueRightAfterTheTappedTrack() {
        controller.playFrom([testSong("x1"), testSong("x2")], index: 0, source: album)
        controller.addToQueue(testSong("mine"))
        controller.playFrom([testSong("y1"), testSong("y2"), testSong("y3")], index: 1, source: album)
        XCTAssertEqual(controller.state.ids, ["y1", "y2", "mine", "y3"])
        XCTAssertEqual(controller.state.currentSong?.videoId, "y2")
    }

    func testASongPickedOnItsOwnPlaysAsAOneOffWithTheUserQueueAfterIt() {
        controller.playFrom([testSong("x1"), testSong("x2")], index: 0, source: album)
        controller.playNext(testSong("mine"))
        controller.playSong(testSong("hit"), source: QueueSource(title: "Search", type: .search))
        XCTAssertEqual(controller.state.ids, ["hit", "mine"])
        XCTAssertEqual(controller.state.currentSong?.playbackSourceType, .search)
    }

    func testPlayWithoutASourceInfersItFromTheTappedRow() {
        var tapped = testSong("t2", album: "Revolver")
        tapped.playbackSource = nil
        controller.play([testSong("t1"), tapped], index: 1)
        XCTAssertEqual(controller.state.currentSong?.playbackSource, "Revolver")
        XCTAssertEqual(controller.state.currentSong?.playbackSourceType, .queue)

        controller.play([testSong("u")], index: 0)
        XCTAssertEqual(controller.state.currentSong?.playbackSource, "Queue")
    }

    func testAQueueRowReusedAsAnInputGetsAFreshEntryId() {
        controller.playFrom([testSong("a"), testSong("b")], index: 0, source: album)
        let playing = controller.state.currentSong!
        controller.addToQueue(playing)
        controller.addToQueue(playing)
        let ids = controller.state.songs.map(\.queueEntryId)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    /// Rows ask whether they are the one playing, so the playing row is observed on its own:
    /// queue edits that leave it playing tell no one watching it, and a skip does.
    func testOnlyAChangeOfThePlayingRowNotifiesThoseWatchingIt() {
        final class Watch: @unchecked Sendable { var fired = false }
        controller.playFrom([testSong("a"), testSong("b")], index: 0, source: album)
        let watch = Watch()
        withObservationTracking { _ = controller.currentSong } onChange: { watch.fired = true }

        controller.addToQueue(testSong("mine"))
        controller.playNext(testSong("next"))
        controller.moveItem(from: 2, to: 3)
        XCTAssertFalse(watch.fired, "edits below the playing row")
        XCTAssertEqual(controller.currentSong?.videoId, "a")

        controller.skipToNext()
        XCTAssertTrue(watch.fired)
        XCTAssertEqual(controller.currentSong, controller.state.currentSong)
    }

    // MARK: Adding

    func testPlayNextAndAddToQueueLandAboveTheAlbumAndAutoplay() {
        controller.setItems([testSong("now"), testSong("c1"), testSong("a1", tier: .autoplay)], startIndex: 0)
        XCTAssertEqual(controller.addToQueue(testSong("added-1")), .added(count: 1))
        XCTAssertEqual(controller.addToQueue(testSong("added-2")), .added(count: 1))
        XCTAssertEqual(controller.playNext(testSong("next")), .added(count: 1))
        XCTAssertEqual(controller.state.ids, ["now", "next", "added-1", "added-2", "c1", "a1"])
        XCTAssertEqual(controller.state.songs[1].queueTier, .userQueue)
        XCTAssertEqual(controller.state.currentIndex, 0)
        XCTAssertEqual(recorder.changes.count, 1, "the playing track never changed")
        XCTAssertEqual(intents, 3)
    }

    func testQueuedTracksCarryThePlayingEntrysStationAndSource() {
        var now = testSong("now", source: "Kesariya")
        now.radioName = "Kesariya"
        now.playbackSourceType = .sharedLink
        now.playbackSourceId = "kesariya-id"
        controller.setItems([now], startIndex: 0)
        controller.addToQueue(testSong("added"))
        let added = controller.state.songs[1]
        XCTAssertEqual(added.radioName, "Kesariya")
        XCTAssertEqual(added.playbackSource, "Kesariya")
        XCTAssertEqual(added.playbackSourceType, .sharedLink)
        XCTAssertEqual(added.playbackSourceId, "kesariya-id")

        controller.setItems([testSong("plain")], startIndex: 0)
        controller.playNext(testSong("added"))
        XCTAssertEqual(controller.state.songs[1].playbackSource, "Queue")
        XCTAssertEqual(controller.state.songs[1].playbackSourceType, .queue)
    }

    func testAListGoesInWholeInItsOwnOrder() {
        controller.setItems([testSong("now"), testSong("c1")], startIndex: 0)
        controller.toggleShuffle()
        XCTAssertEqual(controller.queueSongs([testSong("l1"), testSong("l2"), testSong("l3")], next: false), .added(count: 3))
        XCTAssertEqual(controller.state.ids, ["now", "l1", "l2", "l3", "c1"])
        XCTAssertEqual(controller.queueSongs([testSong("n1"), testSong("n2")], next: true), .added(count: 2))
        XCTAssertEqual(controller.state.ids, ["now", "n1", "n2", "l1", "l2", "l3", "c1"])
    }

    func testQueueingAListOnAnEmptyQueueStartsIt() {
        XCTAssertEqual(controller.queueSongs([testSong("l1"), testSong("l2")], next: false), .done)
        XCTAssertEqual(controller.state.ids, ["l1", "l2"])
        XCTAssertEqual(recorder.last?.playback, .play)
    }

    func testASingleSongAddedToAnEmptyQueueBecomesCurrentWithoutPlaying() {
        controller.addToQueue(testSong("only"))
        XCTAssertEqual(controller.state.currentSong?.videoId, "only")
        XCTAssertEqual(recorder.last?.playback, .keep)
    }

    func testSwipeFollowsTheSetting() {
        controller.setItems([testSong("now"), testSong("u1", tier: .userQueue)], startIndex: 0)
        controller.queueFromSwipe(testSong("swiped-1"))
        XCTAssertEqual(controller.state.ids, ["now", "u1", "swiped-1"])
        settings.swipeToPlayNext = true
        controller.queueFromSwipe(testSong("swiped-2"))
        XCTAssertEqual(controller.state.ids, ["now", "swiped-2", "u1", "swiped-1"])
    }

    func testAPartyQueueHoldsAtMostTwentyFiveUpcomingTracks() {
        controller.setItems([testSong("now")] + (1...23).map { testSong("p\($0)") }, startIndex: 0)
        controller.party = AutoplayPartyContext(code: "ABC123", yourMemberId: "me", members: [.init(memberId: "me", isHost: true)], partyAutoplayEnabled: false)
        XCTAssertEqual(controller.queueSongs([testSong("l1"), testSong("l2"), testSong("l3")], next: false), .added(count: 2))
        XCTAssertEqual(controller.state.upcomingCount, 25)
        XCTAssertEqual(controller.addToQueue(testSong("more")), .partyQueueFull(limit: 25))
        XCTAssertEqual(controller.playNext(testSong("more")), .partyQueueFull(limit: 25))
        XCTAssertEqual(controller.state.upcomingCount, 25)
    }

    // MARK: Editing

    func testRemovingARowLeavesThePlayingTrackAlone() {
        controller.setItems([testSong("a"), testSong("b"), testSong("c"), testSong("d")], startIndex: 2)
        recorder.reset()
        controller.removeFromQueue(at: 0)
        XCTAssertEqual(controller.state.ids, ["b", "c", "d"])
        XCTAssertEqual(controller.state.currentSong?.videoId, "c")
        controller.removeFromQueue(at: 2)
        XCTAssertEqual(controller.state.ids, ["b", "c"])
        XCTAssertTrue(recorder.changes.isEmpty)
        XCTAssertEqual(controller.removeFromQueue(at: 9), .ignored)
    }

    func testRemovingThePlayingRowMovesOnToTheNextOne() {
        controller.setItems([testSong("a"), testSong("b"), testSong("c")], startIndex: 1)
        controller.removeFromQueue(at: 1)
        XCTAssertEqual(controller.state.currentSong?.videoId, "c")
        XCTAssertEqual(recorder.last?.reason, .queueEdit)
        XCTAssertEqual(recorder.last?.playback, .keep)

        // The last row: the queue stops at its top, or wraps under repeat-all.
        controller.removeFromQueue(at: 1)
        XCTAssertEqual(controller.state.currentSong?.videoId, "a")
        XCTAssertEqual(recorder.last?.playback, .pause)

        controller.setItems([testSong("a"), testSong("b")], startIndex: 1)
        controller.setRepeatMode(.all)
        controller.removeFromQueue(at: 1)
        XCTAssertEqual(controller.state.currentSong?.videoId, "a")
        XCTAssertEqual(recorder.last?.playback, .keep)

        controller.removeFromQueue(at: 0)
        XCTAssertTrue(controller.state.isEmpty)
        XCTAssertNil(recorder.last?.song)
        XCTAssertEqual(recorder.last?.playback, .pause)
    }

    func testDraggingMovesRowsWithinTheirOwnSectionOnly() {
        controller.setItems([
            testSong("now"), testSong("u1", tier: .userQueue), testSong("u2", tier: .userQueue),
            testSong("c1"), testSong("c2"), testSong("a1", tier: .autoplay),
        ], startIndex: 0)
        XCTAssertEqual(controller.moveInQueue(from: 2, to: 1), .done)
        XCTAssertEqual(controller.state.ids, ["now", "u2", "u1", "c1", "c2", "a1"])
        XCTAssertEqual(controller.moveInQueue(from: 4, to: 3), .done)
        XCTAssertEqual(controller.state.ids, ["now", "u2", "u1", "c2", "c1", "a1"])
        XCTAssertEqual(controller.moveInQueue(from: 3, to: 2), .ignored, "context into the user queue")
        XCTAssertEqual(controller.moveInQueue(from: 5, to: 4), .ignored, "AutoPlay into the context")
        XCTAssertEqual(controller.moveInQueue(from: 0, to: 1), .ignored, "the playing row")
        XCTAssertEqual(intents, 2)
    }

    func testProgrammaticMovesTrackThePlayingEntry() {
        controller.setItems([testSong("a"), testSong("b"), testSong("c"), testSong("d")], startIndex: 1)
        controller.moveItem(from: 1, to: 3)
        XCTAssertEqual(controller.state.currentIndex, 3)
        controller.moveItem(from: 0, to: 3)
        XCTAssertEqual(controller.state.currentSong?.videoId, "b")
        XCTAssertEqual(controller.state.currentIndex, 2)
        controller.moveItem(from: 3, to: 0)
        XCTAssertEqual(controller.state.currentIndex, 3)
        XCTAssertEqual(controller.state.currentSong?.videoId, "b")
        XCTAssertEqual(recorder.changes.count, 1)
        XCTAssertEqual(intents, 0, "programmatic edits aren't user intents")
    }

    func testReplacingItemsKeepsThePlayingEntryWhenItIsAmongThem() {
        controller.setItems([testSong("a", entryId: "ea"), testSong("b", entryId: "eb"), testSong("c", entryId: "ec")], startIndex: 1)
        recorder.reset()
        controller.replaceItems(in: 0..<3, with: [testSong("c", entryId: "ec"), testSong("b", entryId: "eb")])
        XCTAssertEqual(controller.state.ids, ["c", "b"])
        XCTAssertEqual(controller.state.currentIndex, 1)
        XCTAssertTrue(recorder.changes.isEmpty)

        controller.replaceItems(in: 1..<2, with: [testSong("z")])
        XCTAssertEqual(controller.state.currentSong?.videoId, "z")
        XCTAssertEqual(recorder.last?.reason, .queueEdit)
    }

    func testClearDropsOnlyTheUserQueue() {
        controller.setItems([testSong("now"), testSong("u1", tier: .userQueue), testSong("c1"), testSong("u2", tier: .userQueue), testSong("a1", tier: .autoplay)], startIndex: 0)
        XCTAssertTrue(controller.state.sections.canClearUserQueue)
        XCTAssertEqual(controller.clearUserQueue(), .done)
        XCTAssertEqual(controller.state.ids, ["now", "c1", "a1"])
        XCTAssertEqual(controller.clearUserQueue(), .ignored)
    }

    // MARK: Skipping and repeat

    func testNextAndPreviousRespectRepeatMode() {
        controller.setItems([testSong("a"), testSong("b"), testSong("c")], startIndex: 0)
        XCTAssertFalse(controller.state.hasPrevious)
        XCTAssertTrue(controller.state.hasNext)
        controller.skipToNext()
        controller.skipToNext()
        XCTAssertEqual(controller.state.currentSong?.videoId, "c")
        XCTAssertFalse(controller.state.hasNext)
        XCTAssertEqual(controller.skipToNext(), .ignored)

        controller.setRepeatMode(.all)
        XCTAssertTrue(controller.state.hasNext)
        controller.skipToNext()
        XCTAssertEqual(controller.state.currentSong?.videoId, "a", "repeat-all wraps")
        controller.skipToPrevious()
        XCTAssertEqual(controller.state.currentSong?.videoId, "c", "and wraps back")

        controller.setRepeatMode(.one)
        controller.skipToNext()
        XCTAssertEqual(controller.state.currentSong?.videoId, "c", "repeat-one doesn't wrap a skip")
        XCTAssertFalse(controller.state.hasNext)
    }

    func testPreviousRestartsTheTrackOnceItIsTenSecondsIn() {
        controller.setItems([testSong("a"), testSong("b")], startIndex: 1)
        controller.recordPlayhead(positionMs: 10_001, isPlaying: true)
        controller.skipToPrevious()
        XCTAssertEqual(controller.state.currentSong?.videoId, "b")
        XCTAssertEqual(recorder.last?.reason, .restartCurrent)
        XCTAssertEqual(recorder.last?.startPositionMs, 0)

        controller.recordPlayhead(positionMs: 10_000, isPlaying: true)
        controller.skipToPrevious()
        XCTAssertEqual(controller.state.currentSong?.videoId, "a")
        XCTAssertEqual(recorder.last?.reason, .skipPrevious)

        // Nothing before the first track: back restarts it.
        controller.skipToPrevious()
        XCTAssertEqual(recorder.last?.reason, .restartCurrent)
    }

    func testPreviousDecidesOnThePlayheadTheEngineHandsIt() {
        controller.setItems([testSong("a"), testSong("b")], startIndex: 1)
        // The progress loop last sampled 2 s in; the track has actually played 15 s by now.
        controller.recordPlayhead(positionMs: 2_000, isPlaying: true)
        controller.skipToPrevious(positionMs: 15_000)
        XCTAssertEqual(controller.state.currentSong?.videoId, "b")
        XCTAssertEqual(recorder.last?.reason, .restartCurrent)

        // And the other way round: a stale sample past 10 s, a real playhead of 3 s.
        controller.recordPlayhead(positionMs: 40_000, isPlaying: true)
        controller.skipToPrevious(positionMs: 3_000)
        XCTAssertEqual(controller.state.currentSong?.videoId, "a")
        XCTAssertEqual(recorder.last?.reason, .skipPrevious)
    }

    func testTheFinishTargetFollowsTheRepeatMode() {
        controller.setItems([testSong("a"), testSong("b")], startIndex: 0)
        XCTAssertEqual(controller.state.finishTargetIndex, 1)
        controller.skipToNext()
        XCTAssertNil(controller.state.finishTargetIndex, "the queue ends here")
        controller.setRepeatMode(.all)
        XCTAssertEqual(controller.state.finishTargetIndex, 0)
        controller.setRepeatMode(.one)
        XCTAssertEqual(controller.state.finishTargetIndex, 1)
        XCTAssertNil(PlaybackQueueState().finishTargetIndex)
    }

    func testAShuffledQueueOfRowsWithoutEntryIdsStillUnshuffles() {
        controller.shuffler = { Array($0.reversed()) }
        controller.enableShuffleForNextQueue()
        controller.playSongs([testSong("a"), testSong("b"), testSong("c"), testSong("d")], startIndex: 0)
        XCTAssertEqual(controller.state.ids, ["a", "d", "c", "b"])
        controller.toggleShuffle()
        XCTAssertFalse(controller.state.shuffleEnabled)
        XCTAssertEqual(controller.state.ids, ["a", "b", "c", "d"], "the order the rows arrived in")
    }

    func testRepeatCyclesOffAllOneAndPersists() {
        XCTAssertEqual(controller.state.repeatMode, .off)
        controller.cycleRepeatMode()
        XCTAssertEqual(controller.state.repeatMode, .all)
        XCTAssertEqual(settings.repeatMode, .all)
        controller.cycleRepeatMode()
        XCTAssertEqual(controller.state.repeatMode, .one)
        controller.cycleRepeatMode()
        XCTAssertEqual(controller.state.repeatMode, .off)
        XCTAssertEqual(settings.repeatMode, .off)
    }

    func testAFinishedTrackAdvancesRepeatsOrEndsPerTheRepeatMode() {
        controller.setItems([testSong("a"), testSong("b")], startIndex: 0)
        XCTAssertEqual(controller.trackDidFinish(), .advanced(index: 1))
        XCTAssertEqual(recorder.last?.reason, .autoAdvance)
        XCTAssertEqual(controller.trackDidFinish(), .ended)
        XCTAssertEqual(controller.state.currentSong?.videoId, "b")

        controller.setRepeatMode(.all)
        XCTAssertEqual(controller.trackDidFinish(), .advanced(index: 0))
        controller.setRepeatMode(.one)
        XCTAssertEqual(controller.trackDidFinish(), .repeated)
        XCTAssertEqual(controller.state.currentSong?.videoId, "a")
        XCTAssertEqual(recorder.last?.reason, .repeatCurrent)

        controller.setItems([testSong("solo")], startIndex: 0)
        controller.setRepeatMode(.all)
        XCTAssertEqual(controller.trackDidFinish(), .repeated, "repeat-all over one track replays it")
    }

    func testRepeatAllLoopsTheAlbumAfterConsumingTheUserQueue() {
        controller.setItems([testSong("c1"), testSong("u1", tier: .userQueue), testSong("c2")], startIndex: 0)
        controller.setRepeatMode(.all)
        controller.trackDidFinish()
        controller.trackDidFinish()
        XCTAssertEqual(controller.state.ids, ["c1", "c2"], "u1 played and was consumed")
        controller.trackDidFinish()
        XCTAssertEqual(controller.state.currentSong?.videoId, "c1")
    }

    func testASystemSeekFollowsTheSessionRule() {
        controller.setItems([testSong("now"), testSong("c1"), testSong("u1", tier: .userQueue), testSong("c2")], startIndex: 0)
        XCTAssertEqual(controller.seekToItemFromSystem(3), .done)
        XCTAssertEqual(controller.state.ids, ["now", "c2", "u1"])
        XCTAssertEqual(controller.state.currentSong?.videoId, "c2")
        XCTAssertEqual(recorder.last?.playback, .keep)
    }

    // MARK: Locked parties

    func testAListenerInALockedPartyCantEditTheQueue() {
        controller.setItems([testSong("a"), testSong("b"), testSong("c")], startIndex: 0)
        controller.party = AutoplayPartyContext(code: "ABC123", yourMemberId: "me", members: [.init(memberId: "host", isHost: true), .init(memberId: "me")], hostOnlyControl: true, controlsLocked: true)
        let before = controller.state
        XCTAssertEqual(controller.playFrom([testSong("x")], index: 0, source: album), .refusedByHost)
        XCTAssertEqual(controller.playSong(testSong("x"), source: album), .refusedByHost)
        XCTAssertEqual(controller.playNext(testSong("x")), .refusedByHost)
        XCTAssertEqual(controller.addToQueue(testSong("x")), .refusedByHost)
        XCTAssertEqual(controller.queueSongs([testSong("x")], next: true), .refusedByHost)
        XCTAssertEqual(controller.jump(to: 2), .refusedByHost)
        XCTAssertEqual(controller.removeFromQueue(at: 1), .refusedByHost)
        XCTAssertEqual(controller.moveInQueue(from: 1, to: 2), .refusedByHost)
        XCTAssertEqual(controller.clearUserQueue(), .refusedByHost)
        XCTAssertEqual(controller.skipToNext(), .refusedByHost)
        XCTAssertEqual(controller.skipToPrevious(), .refusedByHost)
        XCTAssertEqual(controller.state, before)
        XCTAssertEqual(intents, 0)

        // The party's own reconciliation still applies.
        controller.appendItems([testSong("from-host")])
        XCTAssertEqual(controller.state.ids.last, "from-host")
    }

    // MARK: Captions

    func testThePlaybackOriginCaption() {
        var song = testSong("s", source: "Liked Music", album: "Album")
        XCTAssertEqual(PlaybackOrigin.of(song, queueLabel: "Queue"), .playingFrom("Liked Music"))
        song.radioName = "Kesariya"
        XCTAssertEqual(PlaybackOrigin.of(song, queueLabel: "Queue"), .radio("Kesariya"))
        XCTAssertEqual(PlaybackOrigin.of(song, playedBy: "Sam", queueLabel: "Queue"), .playedBy("Sam"))
        XCTAssertEqual(PlaybackOrigin.of(testSong("t", album: "Album"), queueLabel: "Queue"), .playingFrom("Album"))
        XCTAssertEqual(PlaybackOrigin.of(testSong("t"), queueLabel: "Queue"), .playingFrom("Queue"))
        XCTAssertEqual(QueueSource.playingFrom(testSong("t"), queueLabel: "Queue"), QueueSource(title: "Queue", type: .queue))
    }
}
