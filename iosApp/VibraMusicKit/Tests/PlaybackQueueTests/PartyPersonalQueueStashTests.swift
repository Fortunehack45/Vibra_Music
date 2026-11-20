import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import PlaybackQueue

/// Ports PartyPersonalQueueStashTest: the personal queue put aside for a party and given back after.
final class PartyPersonalQueueStashTests: XCTestCase {

    private var stash: PartyPersonalQueueStash!
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try makeTemporaryDirectory()
        stash = PartyPersonalQueueStash(store: JSONFileStore(directory: directory))
    }

    func testStashAndLoad() throws {
        XCTAssertFalse(stash.hasStash())
        XCTAssertNil(stash.load())

        let songs = [
            Song(videoId: "vid1", title: "Song 1", artist: "Artist 1", thumbnailUrl: "url1"),
            Song(videoId: "vid2", title: "Song 2", artist: "Artist 2", thumbnailUrl: "url2"),
            Song(videoId: "vid3", title: "Song 3", artist: "Artist 3", thumbnailUrl: "url3"),
        ]
        stash.stash(songs: songs, index: 1, positionMs: 45_000, wasPlaying: true)

        XCTAssertTrue(stash.hasStash())
        let snapshot = try XCTUnwrap(stash.load())
        XCTAssertEqual(snapshot.songs, songs)
        XCTAssertEqual(snapshot.index, 1)
        XCTAssertEqual(snapshot.positionMs, 45_000)
        XCTAssertTrue(snapshot.wasPlaying)
    }

    func testClearRemovesTheStash() {
        stash.stash(songs: [Song(videoId: "vid1", title: "Song 1", artist: "Artist 1")], index: 0, positionMs: 1_200, wasPlaying: false)
        XCTAssertTrue(stash.hasStash())
        stash.clear()
        XCTAssertFalse(stash.hasStash())
        XCTAssertNil(stash.load())
    }

    func testEmptySongsDoNotStash() {
        stash.stash(songs: [], index: 0, positionMs: 0, wasPlaying: false)
        XCTAssertFalse(stash.hasStash())
        XCTAssertNil(stash.load())
    }

    func testIndexClamping() throws {
        let songs = [Song(videoId: "vid1", title: "Song 1", artist: "A"), Song(videoId: "vid2", title: "Song 2", artist: "A")]
        stash.stash(songs: songs, index: 99, positionMs: -5, wasPlaying: false)
        let snapshot = try XCTUnwrap(stash.load())
        XCTAssertEqual(snapshot.index, 1)
        XCTAssertEqual(snapshot.positionMs, 0)
    }

    func testMidAlbumPartyEntryStashesTheFullContextAndRestoresItOnExit() throws {
        let album = (0..<15).map { Song(videoId: "track-\($0)", title: "Song \($0)", artist: "Artist", albumName: "Album 1") }
        stash.stash(songs: album, index: 4, positionMs: 30_000, wasPlaying: true)
        let restored = try XCTUnwrap(stash.load())
        XCTAssertEqual(restored.songs.count, 15)
        XCTAssertEqual(restored.index, 4)
        XCTAssertEqual(restored.songs[restored.index].videoId, "track-4")
        XCTAssertEqual(restored.positionMs, 30_000)
        XCTAssertTrue(restored.wasPlaying)
        stash.clear()
        XCTAssertFalse(stash.hasStash())
    }

    func testAJoinersPersonalQueueIsStashedAndRestoredOnExit() throws {
        let personal = [Song(videoId: "personal-1", title: "P1", artist: "Artist"), Song(videoId: "personal-2", title: "P2", artist: "Artist")]
        stash.stash(songs: personal, index: 0, positionMs: 15_000, wasPlaying: false)
        let restored = try XCTUnwrap(stash.load())
        XCTAssertEqual(restored.songs.map(\.videoId), ["personal-1", "personal-2"])
        XCTAssertEqual(restored.positionMs, 15_000)
        XCTAssertFalse(restored.wasPlaying)
    }

    // MARK: Stashing the live queue (Android's stashFromPlayer)

    func testDeviceFilesAreLeftOutAndTheIndexStillPointsAtThePlayingTrack() throws {
        let queue = [
            Song(videoId: "file:///var/mobile/a.m4a", title: "Local A", artist: "Me"),
            Song(videoId: "ipod-library://item/item.m4a?id=1", title: "Library", artist: "Me"),
            Song(videoId: "yt1", title: "One", artist: "X"),
            Song(videoId: "yt2", title: "Two", artist: "X"),
        ]
        XCTAssertTrue(stash.stash(queue: queue, currentIndex: 3, positionMs: 9_000, wasPlaying: true, lastPlayed: nil))
        let snapshot = try XCTUnwrap(stash.load())
        XCTAssertEqual(snapshot.songs.map(\.videoId), ["yt1", "yt2"])
        XCTAssertEqual(snapshot.songs[snapshot.index].videoId, "yt2")
        XCTAssertTrue(snapshot.wasPlaying)
    }

    func testAQueueOfNothingButDeviceFilesStashesNothing() {
        let queue = [Song(videoId: "content://media/1", title: "L", artist: "Me")]
        XCTAssertFalse(stash.stash(queue: queue, currentIndex: 0, positionMs: 0, wasPlaying: true, lastPlayed: nil))
        XCTAssertFalse(stash.hasStash())
    }

    func testAnEmptyPlayerFallsBackToTheRestartSnapshotStashedAsPaused() throws {
        let lastPlayed = LastPlayedStore(store: JSONFileStore(directory: try makeTemporaryDirectory()))
        lastPlayed.saveQueueImmediately([testSong("a"), testSong("b")], index: 1, positionMs: 7_000)
        XCTAssertTrue(stash.stash(queue: [], currentIndex: 0, positionMs: 0, wasPlaying: true, lastPlayed: lastPlayed))
        let snapshot = try XCTUnwrap(stash.load())
        XCTAssertEqual(snapshot.songs.map(\.videoId), ["a", "b"])
        XCTAssertEqual(snapshot.index, 1)
        XCTAssertEqual(snapshot.positionMs, 7_000)
        XCTAssertFalse(snapshot.wasPlaying)

        XCTAssertFalse(PartyPersonalQueueStash(store: JSONFileStore(directory: try makeTemporaryDirectory()))
            .stash(queue: [], currentIndex: 0, positionMs: 0, wasPlaying: false, lastPlayed: nil))
    }

    func testTheRestartSnapshotFallbackLeavesDeviceFilesOutToo() throws {
        let lastPlayed = LastPlayedStore(store: JSONFileStore(directory: try makeTemporaryDirectory()))
        lastPlayed.saveQueueImmediately(
            [testSong("file:///a.flac"), testSong("ipod-library://item/1"), testSong("b"), testSong("c")],
            index: 3,
            positionMs: 2_000
        )
        XCTAssertTrue(stash.stash(queue: [], currentIndex: 0, positionMs: 0, wasPlaying: true, lastPlayed: lastPlayed))
        let snapshot = try XCTUnwrap(stash.load())
        XCTAssertEqual(snapshot.songs.map(\.videoId), ["b", "c"])
        XCTAssertEqual(snapshot.songs[snapshot.index].videoId, "c")
    }

    func testACorruptStashLoadsAsNothing() throws {
        try Data("{not json".utf8).write(to: directory.appending(path: PartyPersonalQueueStash.fileName))
        XCTAssertTrue(stash.hasStash())
        XCTAssertNil(stash.load())
    }

    // MARK: Through the controller

    @MainActor
    func testJoiningStashesAndLeavingGivesThePersonalQueueBack() throws {
        let controller = PlaybackQueueController(settings: makeSettings(), partyStash: stash)
        let recorder = ItemChangeRecorder()
        recorder.attach(to: controller)
        controller.setItems((0..<5).map { testSong("p\($0)") }, startIndex: 2)
        controller.recordPlayhead(positionMs: 42_000, isPlaying: true)
        let personal = controller.state.songs

        XCTAssertTrue(controller.stashPersonalQueueForParty())
        controller.party = AutoplayPartyContext(code: "ABC123", yourMemberId: "me", members: [.init(memberId: "me", isHost: true)])
        controller.setItems([testSong("party-1"), testSong("party-2")], startIndex: 0, playback: .play)
        XCTAssertEqual(controller.state.ids, ["party-1", "party-2"])

        controller.party = .solo
        XCTAssertTrue(controller.restorePersonalQueueAfterParty())
        XCTAssertEqual(controller.state.songs, personal)
        XCTAssertEqual(controller.state.currentIndex, 2)
        XCTAssertEqual(recorder.last?.startPositionMs, 42_000)
        XCTAssertEqual(recorder.last?.playback, .play)
        XCTAssertFalse(stash.hasStash())
        XCTAssertFalse(controller.restorePersonalQueueAfterParty())
    }

    /// The engine hands over its playhead at the moment of joining, which a slow progress loop may
    /// not have reported yet.
    @MainActor
    func testTheStashTakesThePlayheadHandedToIt() throws {
        let controller = PlaybackQueueController(settings: makeSettings(), partyStash: stash)
        controller.setItems((0..<3).map { testSong("p\($0)") }, startIndex: 1)
        controller.recordPlayhead(positionMs: 5_000, isPlaying: true)
        XCTAssertTrue(controller.stashPersonalQueueForParty(positionMs: 71_500, isPlaying: false))
        let stashed = try XCTUnwrap(stash.load())
        XCTAssertEqual(stashed.index, 1)
        XCTAssertEqual(stashed.positionMs, 71_500)
        XCTAssertFalse(stashed.wasPlaying)
    }

    @MainActor
    func testAStashLeftByAKilledPartySessionWinsOverTheRestartSnapshot() throws {
        let lastPlayed = LastPlayedStore(store: JSONFileStore(directory: try makeTemporaryDirectory()))
        lastPlayed.saveQueueImmediately([testSong("old")], index: 0, positionMs: 0)
        stash.stash(songs: [testSong("mine-1"), testSong("mine-2")], index: 1, positionMs: 5_000, wasPlaying: true)

        let controller = PlaybackQueueController(settings: makeSettings(), lastPlayed: lastPlayed, partyStash: stash)
        let recorder = ItemChangeRecorder()
        recorder.attach(to: controller)
        XCTAssertTrue(controller.restore())
        XCTAssertEqual(controller.state.ids, ["mine-1", "mine-2"])
        XCTAssertEqual(controller.state.currentIndex, 1)
        XCTAssertEqual(recorder.last?.reason, .restored)
        XCTAssertEqual(recorder.last?.playback, .pause)
        XCTAssertEqual(recorder.last?.startPositionMs, 5_000)
        XCTAssertFalse(stash.hasStash(), "a stash is used once")
    }
}
