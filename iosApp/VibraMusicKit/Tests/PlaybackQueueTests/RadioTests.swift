import XCTest
import VibraMusicCore
@testable import PlaybackQueue

/// "Start radio" from a song's menu, and the station CarPlay starts from the playing track
/// (PORTING "Autoplay and radio": "Start radio" works from any song).
@MainActor
final class RadioTests: XCTestCase {

    private func makeController(radio: FakeRadioSource, store: LastPlayedStore? = nil) -> PlaybackQueueController {
        let controller = PlaybackQueueController(settings: makeSettings(autoplay: false), lastPlayed: store, radioSource: radio)
        controller.autoplayEmptyRefreshDelay = .milliseconds(10)
        return controller
    }

    func testRadioFromAnotherSongReplacesTheQueueAndNamesTheStation() async throws {
        let radio = FakeRadioSource()
        radio.setStation("seed", station("r", count: 30))
        let directory = try makeTemporaryDirectory()
        let controller = makeController(radio: radio, store: LastPlayedStore(store: .init(directory: directory)))
        let recorder = ItemChangeRecorder()
        recorder.attach(to: controller)
        controller.setItems([testSong("old-1"), testSong("old-2")], startIndex: 0)

        let result = await controller.startRadio(from: testSong("seed", title: "Kesariya"))
        XCTAssertEqual(result, .started(name: "Kesariya"))
        XCTAssertEqual(controller.state.songs.count, 25, "the seed and a full first page of 24")
        XCTAssertEqual(controller.state.currentSong?.videoId, "seed")
        XCTAssertEqual(controller.state.currentSong?.radioName, "Kesariya")
        XCTAssertEqual(controller.state.currentSong?.playbackSourceType, .sharedLink)
        XCTAssertTrue(controller.state.upcoming.allSatisfy { $0.radioName == "Kesariya" && $0.queueTier == .autoplay })
        XCTAssertEqual(PlaybackOrigin.of(controller.state.currentSong!, queueLabel: "Queue"), .radio("Kesariya"))
        XCTAssertEqual(recorder.last?.song?.videoId, "seed")
        XCTAssertEqual(recorder.last?.playback, .play)

        // Committed synchronously: a relaunch right now restores the station, not the old queue.
        XCTAssertEqual(LastPlayedStore(store: .init(directory: directory)).load()?.songs.first?.videoId, "seed")
    }

    func testRadioFromThePlayingSongKeepsItPlayingAndRelabelsIt() async {
        let radio = FakeRadioSource()
        radio.setStation("now", station("r", count: 5))
        let controller = makeController(radio: radio)
        let recorder = ItemChangeRecorder()
        recorder.attach(to: controller)
        controller.setItems([testSong("before"), testSong("now"), testSong("after")], startIndex: 1)
        let entry = controller.state.currentSong?.queueEntryId
        recorder.reset()

        let result = await controller.startRadio(from: controller.state.currentSong!)
        XCTAssertEqual(result, .started(name: "Title now"))
        XCTAssertEqual(controller.state.ids, ["now", "r1", "r2", "r3", "r4", "r5"])
        XCTAssertEqual(controller.state.currentSong?.queueEntryId, entry)
        XCTAssertEqual(controller.state.currentSong?.radioName, "Title now")
        XCTAssertTrue(recorder.changes.isEmpty, "the playing track is never restarted")
    }

    func testAFailedOrEmptyRadioLeavesTheQueueAlone() async {
        let radio = FakeRadioSource()
        radio.setFailure("broken")
        let controller = makeController(radio: radio)
        controller.setItems([testSong("a"), testSong("b")], startIndex: 0)
        let before = controller.state

        let failed = await controller.startRadio(from: testSong("broken"))
        XCTAssertEqual(failed, .failed)
        let empty = await controller.startRadio(from: testSong("nothing"))
        XCTAssertEqual(empty, .failed)
        XCTAssertEqual(controller.state, before)
    }

    func testAPlayRequestDuringTheLoadWins() async {
        let radio = FakeRadioSource()
        radio.setStation("seed", station("r", count: 5))
        let controller = makeController(radio: radio)
        controller.setItems([testSong("a")], startIndex: 0)

        radio.gate = RadioGate()
        let started = Task { await controller.startRadio(from: testSong("seed")) }
        await waitUntil { radio.requests.count == 1 }
        controller.playSong(testSong("tapped"), source: QueueSource(title: "Search", type: .search))
        radio.gate?.release()
        let result = await started.value
        XCTAssertEqual(result, .superseded)
        XCTAssertEqual(controller.state.currentSong?.videoId, "tapped")
        XCTAssertFalse(controller.state.ids.contains("r1"))
    }

    func testAQueueEditDuringTheLoadWinsButAutoplayGrowthDoesNot() async {
        let radio = FakeRadioSource()
        radio.setStation("seed", station("r", count: 5))
        let controller = makeController(radio: radio)
        controller.setItems([testSong("a")], startIndex: 0)

        radio.gate = RadioGate()
        let edited = Task { await controller.startRadio(from: testSong("seed")) }
        await waitUntil { radio.requests.count == 1 }
        controller.addToQueue(testSong("mine"))
        radio.gate?.release()
        let first = await edited.value
        XCTAssertEqual(first, .superseded)

        radio.gate = RadioGate()
        let grown = Task { await controller.startRadio(from: testSong("seed")) }
        await waitUntil { radio.requests.count == 2 }
        controller.appendItems([testSong("auto", tier: .autoplay)])
        radio.gate?.release()
        let second = await grown.value
        XCTAssertEqual(second, .started(name: "Title seed"))
    }

    /// A queue the app starts directly (not through playFrom) still wins over a station loading,
    /// even when its manual tracks happen to match the old queue's.
    func testADirectlyStartedQueueDuringTheLoadWins() async {
        let radio = FakeRadioSource()
        radio.setStation("seed", station("r", count: 5))
        let controller = makeController(radio: radio)
        controller.setItems([testSong("a")], startIndex: 0)

        radio.gate = RadioGate()
        let started = Task { await controller.startRadio(from: testSong("seed")) }
        await waitUntil { radio.requests.count == 1 }
        controller.playSongs([testSong("a")], startIndex: 0)
        radio.gate?.release()
        let result = await started.value
        XCTAssertEqual(result, .superseded)
        XCTAssertEqual(controller.state.ids, ["a"])
    }

    /// In a party the snapshot on disk is the personal queue waiting for the party to end; a
    /// station started there must neither replace nor erase it.
    func testAStationStartedInAPartyLeavesThePersonalRestartSnapshotAlone() async throws {
        let radio = FakeRadioSource()
        radio.setStation("seed", station("r", count: 5))
        let store = LastPlayedStore(store: .init(directory: try makeTemporaryDirectory()))
        let controller = makeController(radio: radio, store: store)
        controller.playSongs([testSong("mine-1"), testSong("mine-2")], startIndex: 0)
        controller.party = AutoplayPartyContext(code: "ABC123", yourMemberId: "me", members: [.init(memberId: "me", isHost: true)])

        let result = await controller.startRadio(from: testSong("seed"))
        XCTAssertEqual(result, .started(name: "Title seed"))
        XCTAssertEqual(controller.state.currentSong?.videoId, "seed")
        store.flush()
        XCTAssertEqual(store.load()?.songs.map(\.videoId), ["mine-1", "mine-2"])
    }

    func testRadioIsUnavailableWithoutASourceOrForADeviceFile() async {
        let bare = PlaybackQueueController(settings: makeSettings())
        let noSource = await bare.startRadio(from: testSong("x"))
        XCTAssertEqual(noSource, .unavailable)
        let controller = makeController(radio: FakeRadioSource())
        let local = await controller.startRadio(from: testSong("file:///var/mobile/a.m4a"))
        XCTAssertEqual(local, .unavailable)
    }

    func testALockedListenerCantStartARadio() async {
        let radio = FakeRadioSource()
        radio.setStation("seed", station("r", count: 5))
        let controller = makeController(radio: radio)
        controller.party = AutoplayPartyContext(code: "ABC123", yourMemberId: "me", members: [.init(memberId: "host", isHost: true), .init(memberId: "me")], controlsLocked: true)
        let result = await controller.startRadio(from: testSong("seed"))
        XCTAssertEqual(result, .refusedByHost)
        XCTAssertTrue(radio.requests.isEmpty)
    }

    func testALockedListenerCantStartAStationFromThePlayingTrack() async {
        let radio = FakeRadioSource()
        radio.setStation("a", station("r", count: 5))
        let controller = makeController(radio: radio)
        controller.setItems([testSong("a"), testSong("b")], startIndex: 0)
        controller.party = AutoplayPartyContext(code: "ABC123", yourMemberId: "me", members: [.init(memberId: "host", isHost: true), .init(memberId: "me")], controlsLocked: true)
        let result = await controller.startStationFromCurrentTrack()
        XCTAssertEqual(result, .refusedByHost)
        XCTAssertTrue(radio.requests.isEmpty)
        XCTAssertEqual(controller.state.ids, ["a", "b"])
    }

    func testAStationFromThePlayingTrackKeepsItAndReplacesEverythingElse() async throws {
        let radio = FakeRadioSource()
        radio.setStation("now", station("r", count: 30))
        let store = LastPlayedStore(store: .init(directory: try makeTemporaryDirectory()))
        let controller = makeController(radio: radio, store: store)
        let recorder = ItemChangeRecorder()
        recorder.attach(to: controller)
        controller.setItems([testSong("h"), testSong("now"), testSong("u", tier: .userQueue)], startIndex: 1)
        recorder.reset()

        let result = await controller.startStationFromCurrentTrack()
        XCTAssertEqual(result, .started(name: "Title now"))
        XCTAssertEqual(controller.state.songs.count, 25)
        XCTAssertEqual(controller.state.currentIndex, 0)
        XCTAssertEqual(controller.state.currentSong?.radioName, "Title now")
        XCTAssertTrue(recorder.changes.isEmpty)
        XCTAssertEqual(store.load()?.songs.count, 25)
    }

    func testAStationIsAbandonedIfTheTrackChangedWhileItLoaded() async {
        let radio = FakeRadioSource()
        radio.setStation("a", station("r", count: 5))
        let controller = makeController(radio: radio)
        controller.setItems([testSong("a"), testSong("b")], startIndex: 0)
        radio.gate = RadioGate()
        let station = Task { await controller.startStationFromCurrentTrack() }
        await waitUntil { radio.requests.count == 1 }
        controller.skipToNext()
        radio.gate?.release()
        let result = await station.value
        XCTAssertEqual(result, .superseded)
        XCTAssertEqual(controller.state.ids, ["a", "b"])
    }
}
