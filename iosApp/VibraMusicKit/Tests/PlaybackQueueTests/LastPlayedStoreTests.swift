import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import PlaybackQueue

/// The restart snapshot on its own: bounded, split into queue and scalar state, durable.
final class LastPlayedStoreTests: XCTestCase {

    private func makeStore() throws -> (LastPlayedStore, URL) {
        let directory = try makeTemporaryDirectory()
        return (LastPlayedStore(store: JSONFileStore(directory: directory)), directory)
    }

    func testNothingSavedLoadsNothing() throws {
        XCTAssertNil(try makeStore().0.load())
    }

    func testAQueueRoundTripsWithItsIndexAndPosition() throws {
        let (store, _) = try makeStore()
        let songs = (0..<5).map { testSong("s\($0)", entryId: "e\($0)") }
        store.saveQueue(songs, index: 3)
        store.savePlaybackState(index: 3, positionMs: 12_345)
        let snapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(snapshot.songs, songs)
        XCTAssertEqual(snapshot.index, 3)
        XCTAssertEqual(snapshot.positionMs, 12_345)
    }

    func testOnlyTheWindowAroundTheCurrentEntryIsKept() throws {
        let (store, _) = try makeStore()
        let songs = (0..<200).map { testSong("s\($0)") }
        store.saveQueue(songs, index: 100)
        let snapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(snapshot.songs.count, 76)
        XCTAssertEqual(snapshot.songs.first?.videoId, "s75")
        XCTAssertEqual(snapshot.songs.last?.videoId, "s150")
        XCTAssertEqual(snapshot.songs[snapshot.index].videoId, "s100")
    }

    func testPlaybackStateWritesNeverTouchTheSongList() throws {
        let (store, directory) = try makeStore()
        store.saveQueue([testSong("a"), testSong("b")], index: 0)
        store.flush()
        let queueFile = directory.appending(path: LastPlayedStore.queueFile)
        let before = try Data(contentsOf: queueFile)
        let modified = try FileManager.default.attributesOfItem(atPath: queueFile.path)[.modificationDate] as? Date
        for tick in 0..<20 { store.savePlaybackState(index: 1, positionMs: Int64(tick) * 500) }
        store.flush()
        XCTAssertEqual(try Data(contentsOf: queueFile), before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: queueFile.path)[.modificationDate] as? Date, modified)
        XCTAssertEqual(try XCTUnwrap(store.load()).positionMs, 9_500)
    }

    func testAQueueEditKeepsThePositionAlreadySaved() throws {
        let (store, _) = try makeStore()
        store.saveQueue([testSong("a"), testSong("b")], index: 0)
        store.savePlaybackState(index: 0, positionMs: 30_000)
        store.saveQueue([testSong("a"), testSong("x"), testSong("b")], index: 0)
        XCTAssertEqual(try XCTUnwrap(store.load()).positionMs, 30_000)
    }

    func testPlaybackStateIsIgnoredWhileNoQueueIsSaved() throws {
        let (store, directory) = try makeStore()
        store.savePlaybackState(index: 4, positionMs: 1_000)
        store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: LastPlayedStore.stateFile).path))
    }

    func testClearingAndSavingAnEmptyQueueRemoveTheSnapshot() throws {
        let (store, _) = try makeStore()
        store.saveQueue([testSong("a")], index: 0)
        store.clear()
        XCTAssertNil(store.load())
        store.saveQueueImmediately([testSong("a")], index: 0, positionMs: 5)
        store.saveQueue([], index: 0)
        XCTAssertNil(store.load())
        store.saveQueueImmediately([testSong("a")], index: 0, positionMs: 5)
        store.clearImmediately()
        XCTAssertNil(store.load())
    }

    func testAnImmediateSaveIsOnDiskWhenItReturns() throws {
        let (store, directory) = try makeStore()
        store.saveQueueImmediately([testSong("a"), testSong("b")], index: 1, positionMs: -20)
        // A second store over the same directory: nothing shared in memory.
        let snapshot = try XCTUnwrap(LastPlayedStore(store: JSONFileStore(directory: directory)).load())
        XCTAssertEqual(snapshot.index, 1)
        XCTAssertEqual(snapshot.positionMs, 0)
    }

    func testTheSnapshotIsCoreSongJSON() throws {
        let (store, directory) = try makeStore()
        let song = Song(videoId: "v", title: "T", artist: "A", queueTier: .autoplay, queueEntryId: "e", radioName: "R")
        store.saveQueueImmediately([song], index: 0, positionMs: 0)
        struct Envelope: Decodable { var tracks: [Song] }
        let data = try Data(contentsOf: directory.appending(path: LastPlayedStore.queueFile))
        XCTAssertEqual(try JSONDecoder().decode(Envelope.self, from: data).tracks, [song])
    }
}

/// PORTING "Queue" done-criterion: the user adds songs, reorders them, the app is killed, and a
/// fresh launch shows the same queue at the same place.
@MainActor
final class QueueRestartTests: XCTestCase {

    func testAQueueBuiltAndReorderedSurvivesARestart() throws {
        let directory = try makeTemporaryDirectory()
        let settings = makeSettings()

        do {
            let controller = PlaybackQueueController(settings: settings, lastPlayed: LastPlayedStore(store: JSONFileStore(directory: directory)))
            controller.playFrom(
                (1...6).map { testSong("album-\($0)") },
                index: 1,
                source: QueueSource(title: "Revolver", type: .browse, id: "MPREb_revolver")
            )
            controller.addToQueue(testSong("mine-1"))
            controller.addToQueue(testSong("mine-2"))
            controller.addToQueue(testSong("mine-3"))
            // Drag mine-3 to the top of the user queue, then play on into it.
            controller.moveInQueue(from: 4, to: 3)
            controller.moveInQueue(from: 3, to: 2)
            XCTAssertEqual(controller.state.upcomingIds, ["mine-3", "mine-1", "mine-2", "album-3", "album-4", "album-5", "album-6"])
            controller.trackDidFinish()
            controller.recordPlayhead(positionMs: 64_000, isPlaying: true)
            XCTAssertEqual(controller.state.currentSong?.videoId, "mine-3")
        }

        // A fresh process: new store, new controller, same directory.
        let relaunched = PlaybackQueueController(settings: settings, lastPlayed: LastPlayedStore(store: JSONFileStore(directory: directory)))
        let recorder = ItemChangeRecorder()
        recorder.attach(to: relaunched)
        XCTAssertTrue(relaunched.restore())
        XCTAssertEqual(relaunched.state.ids, ["album-1", "album-2", "mine-3", "mine-1", "mine-2", "album-3", "album-4", "album-5", "album-6"])
        XCTAssertEqual(relaunched.state.currentSong?.videoId, "mine-3")
        XCTAssertEqual(relaunched.state.currentSong?.queueTier, .userQueue)
        XCTAssertEqual(relaunched.state.upcoming.first?.playbackSource, "Revolver", "queued under the album it was added from")
        XCTAssertEqual(relaunched.state.songs.first?.playbackSource, "Revolver")
        XCTAssertEqual(recorder.changes, [QueueItemChange(
            song: relaunched.state.currentSong,
            index: 2,
            startPositionMs: 64_000,
            reason: .restored,
            playback: .pause
        )])
    }

    func testEntryIdsSurviveARestartSoShuffleAndTheQueuePanelKeepTheirIdentity() throws {
        let directory = try makeTemporaryDirectory()
        let first = PlaybackQueueController(settings: makeSettings(), lastPlayed: LastPlayedStore(store: JSONFileStore(directory: directory)))
        first.playSongs([testSong("a"), testSong("a"), testSong("b")], startIndex: 0)
        let ids = first.state.songs.map(\.queueEntryId)
        XCTAssertEqual(Set(ids).count, 3)

        let second = PlaybackQueueController(settings: makeSettings(), lastPlayed: LastPlayedStore(store: JSONFileStore(directory: directory)))
        second.restore()
        XCTAssertEqual(second.state.songs.map(\.queueEntryId), ids)
    }

    func testARestartAfterALongSessionRestoresTheBoundedWindowAtTheRightTrack() throws {
        let directory = try makeTemporaryDirectory()
        let first = PlaybackQueueController(settings: makeSettings(), lastPlayed: LastPlayedStore(store: JSONFileStore(directory: directory)))
        first.playSongs((0..<300).map { testSong("s\($0)") }, startIndex: 0)
        for _ in 0..<120 { first.trackDidFinish() }
        first.recordPlayhead(positionMs: 1_000, isPlaying: false)
        XCTAssertEqual(first.state.currentSong?.videoId, "s120")

        let second = PlaybackQueueController(settings: makeSettings(), lastPlayed: LastPlayedStore(store: JSONFileStore(directory: directory)))
        second.restore()
        XCTAssertEqual(second.state.currentSong?.videoId, "s120")
        XCTAssertEqual(second.state.songs.first?.videoId, "s95")
        XCTAssertEqual(second.state.songs.last?.videoId, "s170")
    }

    func testAPartysQueueIsNeverWrittenAsTheRestartSnapshot() throws {
        let directory = try makeTemporaryDirectory()
        let store = LastPlayedStore(store: JSONFileStore(directory: directory))
        let controller = PlaybackQueueController(settings: makeSettings(), lastPlayed: store)
        controller.playSongs([testSong("mine")], startIndex: 0)
        controller.party = AutoplayPartyContext(code: "ABC123", yourMemberId: "me", members: [.init(memberId: "me", isHost: true)])
        controller.setItems([testSong("party")], startIndex: 0)
        store.flush()
        XCTAssertEqual(store.load()?.songs.map(\.videoId), ["mine"])
    }

    func testAPartysPlayheadNeverMovesThePersonalRestartPosition() throws {
        let directory = try makeTemporaryDirectory()
        let store = LastPlayedStore(store: JSONFileStore(directory: directory))
        let controller = PlaybackQueueController(settings: makeSettings(), lastPlayed: store)
        controller.playSongs((1...4).map { testSong("mine-\($0)") }, startIndex: 2)
        controller.recordPlayhead(positionMs: 30_000, isPlaying: true)

        controller.party = AutoplayPartyContext(code: "ABC123", yourMemberId: "me", members: [.init(memberId: "me", isHost: true)])
        controller.setItems((1...8).map { testSong("party-\($0)") }, startIndex: 6)
        controller.recordPlayhead(positionMs: 5_000, isPlaying: true)
        controller.trackDidFinish()
        controller.recordPlayhead(positionMs: 1_000, isPlaying: true)

        store.flush()
        let snapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(snapshot.songs.map(\.videoId), ["mine-1", "mine-2", "mine-3", "mine-4"])
        XCTAssertEqual(snapshot.index, 2)
        XCTAssertEqual(snapshot.positionMs, 30_000)
    }

    func testTwoStoresOnOneDirectoryNeverReadPastEachOthersPendingWrites() throws {
        let directory = try makeTemporaryDirectory()
        let writer = LastPlayedStore(store: JSONFileStore(directory: directory))
        for round in 0..<50 {
            writer.saveQueue((0..<(round + 1)).map { testSong("s\($0)") }, index: round)
            // The index within the saved window, as the controller passes it.
            writer.savePlaybackState(index: min(round, QueueHistory.maxEntries), positionMs: Int64(round))
        }
        // No flush: the second store has to see every write the first one queued.
        let reader = LastPlayedStore(store: JSONFileStore(directory: directory))
        let snapshot = try XCTUnwrap(reader.load())
        XCTAssertEqual(snapshot.songs.map(\.videoId), (24..<50).map { "s\($0)" }, "25 behind the current entry, and the entry")
        XCTAssertEqual(snapshot.index, 25)
        XCTAssertEqual(snapshot.songs[snapshot.index].videoId, "s49")
        XCTAssertEqual(snapshot.positionMs, 49)
    }

    /// Leaving a party with no personal queue to give back (it was all device files, say) keeps the
    /// party's queue playing; the snapshot must follow it rather than have that queue's index and
    /// playhead written into the older personal queue still on disk.
    func testLeavingAPartyWithoutAStashMakesTheQueueHeldHereTheSnapshot() throws {
        let directory = try makeTemporaryDirectory()
        let store = LastPlayedStore(store: JSONFileStore(directory: directory))
        let controller = PlaybackQueueController(settings: makeSettings(), lastPlayed: store)
        controller.playSongs((1...3).map { testSong("mine-\($0)") }, startIndex: 0)
        controller.party = AutoplayPartyContext(code: "ABC123", yourMemberId: "me", members: [.init(memberId: "me", isHost: true)])
        controller.setItems((1...6).map { testSong("party-\($0)") }, startIndex: 4)

        controller.party = .solo
        controller.recordPlayhead(positionMs: 9_000, isPlaying: true)
        store.flush()
        let snapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(snapshot.songs.map(\.videoId), (1...6).map { "party-\($0)" })
        XCTAssertEqual(snapshot.songs[snapshot.index].videoId, "party-5")
        XCTAssertEqual(snapshot.positionMs, 9_000)
    }

    /// What the app does on going to the background: the playhead is on disk when this returns.
    func testFlushingPersistenceWritesThePlayheadBeforeReturning() throws {
        let directory = try makeTemporaryDirectory()
        let controller = PlaybackQueueController(settings: makeSettings(), lastPlayed: LastPlayedStore(store: JSONFileStore(directory: directory)))
        controller.playSongs((1...3).map { testSong("s\($0)") }, startIndex: 1)
        controller.flushPersistence(positionMs: 42_000, isPlaying: false)

        struct State: Decodable { var index: Int; var positionMs: Int64? }
        let raw = try Data(contentsOf: directory.appending(path: LastPlayedStore.stateFile))
        let state = try JSONDecoder().decode(State.self, from: raw)
        XCTAssertEqual(state.index, 1)
        XCTAssertEqual(state.positionMs, 42_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: LastPlayedStore.queueFile).path))
    }

    func testRestoringWithNothingSavedDoesNothing() throws {
        let controller = PlaybackQueueController(settings: makeSettings(), lastPlayed: LastPlayedStore(store: JSONFileStore(directory: try makeTemporaryDirectory())))
        let recorder = ItemChangeRecorder()
        recorder.attach(to: controller)
        XCTAssertFalse(controller.restore())
        XCTAssertTrue(controller.state.isEmpty)
        XCTAssertTrue(recorder.changes.isEmpty)
    }
}
