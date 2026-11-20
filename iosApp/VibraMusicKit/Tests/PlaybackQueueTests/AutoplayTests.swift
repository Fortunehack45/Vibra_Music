import XCTest
import VibraMusicCore
@testable import PlaybackQueue

/// AutoPlay and radio loading (Autoplay.kt's loadAutoplayTracks) on its own.
final class AutoplayLoaderTests: XCTestCase {

    func testABatchIsDedupedCappedAndTaggedWithTheSeedsStation() async throws {
        let radio = FakeRadioSource()
        var video = Song(videoId: "v-dup", title: "Kesariya (Official Video)", artist: "Arijit Singh")
        video.isVideo = true
        radio.setStation("seed", [
            Song(videoId: "seed", title: "Kesariya", artist: "Arijit Singh"),
            Song(videoId: "dup", title: "Kesariya | Lyric Video", artist: "Arijit Singh, Pritam"),
            video,
        ] + station("r", count: 15))
        var seed = Song(videoId: "seed", title: "Kesariya", artist: "Arijit Singh")
        seed.radioName = "Kesariya"
        seed.playbackSource = "Kesariya"
        seed.playbackSourceType = .sharedLink
        seed.playbackSourceId = "seed"

        let tracks = try await AutoplayLoader(source: radio).loadTracks(existing: [seed], seedSong: seed)
        XCTAssertEqual(tracks.map(\.videoId), (1...10).map { "r\($0)" })
        XCTAssertTrue(tracks.allSatisfy {
            $0.queueTier == .autoplay && $0.radioName == "Kesariya" && $0.playbackSource == "Kesariya"
                && $0.playbackSourceType == .sharedLink && $0.playbackSourceId == "seed" && $0.queueEntryId != nil
        })
        XCTAssertEqual(radio.requests, ["seed"])
    }

    func testATrackWithoutAYouTubeSeedHasNoStation() async throws {
        let radio = FakeRadioSource()
        radio.setSeed(for: "source:abc", nil)
        let tracks = try await AutoplayLoader(source: radio).loadTracks(existing: [], seedSong: testSong("source:abc"))
        XCTAssertEqual(tracks, [])
        XCTAssertTrue(radio.requests.isEmpty)
    }

    func testASourceBackedTrackIsSeededByItsYouTubeMatch() async throws {
        let radio = FakeRadioSource()
        radio.setSeed(for: "source:abc", "yt-match")
        radio.setStation("yt-match", station("m", count: 2))
        let tracks = try await AutoplayLoader(source: radio).loadTracks(existing: [], seedSong: testSong("source:abc"))
        XCTAssertEqual(tracks.map(\.videoId), ["m1", "m2"])
    }

    /// The protocol's default seed: a catalogue row seeds its own station, a file on this device has
    /// none (no radio request is made for it at all).
    func testTheDefaultSeedIsTheVideoIdAndNothingForADeviceFile() async throws {
        final class CountingRadio: AutoplayRadioSource, @unchecked Sendable {
            private let lock = NSLock()
            private var seeds: [String] = []
            var requested: [String] { lock.withLock { seeds } }
            func radio(seedVideoId: String) async throws -> [Song] {
                lock.withLock { seeds.append(seedVideoId) }
                return station("r", count: 2)
            }
        }
        let radio = CountingRadio()
        let seed = await radio.youtubeSeed(for: testSong("dQw4w9WgXcQ"))
        XCTAssertEqual(seed, "dQw4w9WgXcQ")
        for local in ["file:///var/mobile/a.m4a", "ipod-library://item/item.m4a?id=42", "content://media/external/audio/7"] {
            let seed = await radio.youtubeSeed(for: testSong(local))
            XCTAssertNil(seed, local)
            let tracks = try await AutoplayLoader(source: radio).loadTracks(existing: [], seedSong: testSong(local))
            XCTAssertEqual(tracks, [])
        }
        XCTAssertTrue(radio.requested.isEmpty)
    }

    func testAFailedRadioThrows() async {
        let radio = FakeRadioSource()
        radio.setFailure("seed")
        do {
            _ = try await AutoplayLoader(source: radio).loadTracks(existing: [], seedSong: testSong("seed"))
            XCTFail("expected a failure")
        } catch {}
    }
}

/// AutoPlay as the service ran it: topping the queue up to ten suggestions on every track change,
/// switching off, repeat-all, and the empty-queue fallbacks (PORTING "Autoplay and radio").
@MainActor
final class AutoplayQueueTests: XCTestCase {

    private func makeController(autoplay: Bool = true, radio: FakeRadioSource) -> (PlaybackQueueController, AppSettings) {
        let settings = makeSettings(autoplay: autoplay)
        let controller = PlaybackQueueController(settings: settings, radioSource: radio)
        controller.autoplayEmptyRefreshDelay = .milliseconds(10)
        return (controller, settings)
    }

    func testTheLastSongOfAPlaylistIsFollowedByRelatedSongs() async {
        let radio = FakeRadioSource()
        radio.setStation("t3", station("r", count: 12))
        let (controller, _) = makeController(radio: radio)
        let recorder = ItemChangeRecorder()
        recorder.attach(to: controller)
        controller.playFrom([testSong("t1"), testSong("t2"), testSong("t3")], index: 2, source: QueueSource(title: "Playlist", type: .browse))
        await controller.waitForAutoplay()

        XCTAssertEqual(controller.state.upcomingIds, (1...10).map { "r\($0)" }, "ten suggestions queued ahead")
        XCTAssertEqual(controller.state.sections.autoplay.count, 10)
        XCTAssertEqual(controller.state.autoplaySectionStart, 3)

        // The playlist's last song ends and a related one starts on its own.
        XCTAssertEqual(controller.trackDidFinish(), .advanced(index: 3))
        XCTAssertEqual(recorder.last?.song?.videoId, "r1")
        XCTAssertEqual(recorder.last?.reason, .autoAdvance)
    }

    func testEachTransitionTopsTheQueueBackUpToTen() async {
        let radio = FakeRadioSource()
        radio.setStation("now", station("r", count: 10))
        radio.setStation("r1", station("s", count: 10))
        let (controller, _) = makeController(radio: radio)
        controller.setItems([testSong("now")], startIndex: 0)
        await controller.waitForAutoplay()
        XCTAssertEqual(controller.state.upcoming.count, 10)

        controller.trackDidFinish()
        await controller.waitForAutoplay()
        XCTAssertEqual(controller.state.upcoming.filter(\.fromAutoplay).count, 10)
        XCTAssertEqual(controller.state.upcomingIds.last, "s1", "one new suggestion appended after those waiting")
        XCTAssertEqual(radio.requests, ["now", "r1"])
    }

    func testNothingIsLoadedWhileTenAreAlreadyQueued() async {
        let radio = FakeRadioSource()
        let (controller, _) = makeController(radio: radio)
        controller.setItems([testSong("now")] + (1...10).map { testSong("a\($0)", tier: .autoplay) }, startIndex: 0)
        await controller.waitForAutoplay()
        XCTAssertTrue(radio.requests.isEmpty)
    }

    func testSuggestionsSkipWhatIsAlreadyQueued() async {
        let radio = FakeRadioSource()
        radio.setStation("now", [testSong("queued-1"), testSong("fresh-1"), testSong("now"), testSong("fresh-2")])
        let (controller, _) = makeController(radio: radio)
        controller.setItems([testSong("now"), testSong("queued-1", tier: .userQueue)], startIndex: 0)
        await controller.waitForAutoplay()
        XCTAssertEqual(controller.state.ids, ["now", "queued-1", "fresh-1", "fresh-2"])
    }

    func testDontRepeatSuggestionsRemembersTheSessionsSuggestions() async {
        let radio = FakeRadioSource()
        radio.setStation("now", [testSong("s1"), testSong("s2")])
        radio.setStation("other", [testSong("s1"), testSong("s2"), testSong("s3")])
        let (controller, settings) = makeController(radio: radio)
        settings.dontRepeatSuggestions = true
        controller.setItems([testSong("now")], startIndex: 0)
        await controller.waitForAutoplay()
        XCTAssertEqual(controller.state.upcomingIds, ["s1", "s2"])

        // A new queue: s1 and s2 were already offered this session.
        controller.setItems([testSong("other")], startIndex: 0)
        await controller.waitForAutoplay()
        XCTAssertEqual(controller.state.upcomingIds, ["s3"])
    }

    func testSwitchingAutoplayOffTakesBackItsUnplayedTracks() async {
        let radio = FakeRadioSource()
        radio.setStation("now", station("r", count: 3))
        let (controller, settings) = makeController(radio: radio)
        controller.setItems([testSong("now"), testSong("mine", tier: .userQueue)], startIndex: 0)
        await controller.waitForAutoplay()
        XCTAssertEqual(controller.state.ids, ["now", "mine", "r1", "r2", "r3"])

        controller.toggleAutoplay()
        XCTAssertFalse(settings.autoplay)
        XCTAssertFalse(controller.isAutoplayEnabled)
        XCTAssertEqual(controller.state.ids, ["now", "mine"])

        controller.toggleAutoplay()
        await controller.waitForAutoplay()
        XCTAssertTrue(settings.autoplay)
        XCTAssertEqual(controller.state.ids, ["now", "mine", "r1", "r2", "r3"])
    }

    func testRepeatAllSetsAutoplayAsideAndPutsTheSameTracksBack() async {
        let radio = FakeRadioSource()
        radio.setStation("now", station("r", count: 3))
        let (controller, _) = makeController(radio: radio)
        controller.setItems([testSong("now")], startIndex: 0)
        await controller.waitForAutoplay()
        let mix = controller.state.songs

        controller.setRepeatMode(.all)
        XCTAssertEqual(controller.state.ids, ["now"], "repeat-all loops the queue as it stands")
        // Cycling on through repeat-one must not overwrite the stash with the empty tail, and
        // leaving repeat-all puts back the very same entries rather than a fresh mix.
        controller.setRepeatMode(.one)
        await controller.waitForAutoplay()
        XCTAssertEqual(Array(controller.state.songs.prefix(mix.count)), mix)
    }

    func testAStashIsRefusedOnceTheLoopHasMovedOn() async {
        let radio = FakeRadioSource()
        radio.setStation("a", station("r", count: 2))
        radio.setStation("b", station("s", count: 2))
        let (controller, _) = makeController(radio: radio)
        controller.setItems([testSong("a"), testSong("b")], startIndex: 0)
        await controller.waitForAutoplay()
        controller.setRepeatMode(.all)
        XCTAssertEqual(controller.state.ids, ["a", "b"])
        controller.trackDidFinish()
        controller.setRepeatMode(.off)
        await controller.waitForAutoplay()
        XCTAssertEqual(controller.state.upcomingIds, ["s1", "s2"], "loaded for the track now playing instead")
    }

    func testATrackQueuedByHandDuringTheLoopIsNotQueuedTwice() async {
        let radio = FakeRadioSource()
        radio.setStation("now", station("r", count: 3))
        let (controller, _) = makeController(radio: radio)
        controller.setItems([testSong("now")], startIndex: 0)
        await controller.waitForAutoplay()
        controller.setRepeatMode(.all)
        controller.addToQueue(Song(videoId: "r2", title: "r song 2", artist: "r artist 2"))
        controller.setRepeatMode(.off)
        await controller.waitForAutoplay()
        XCTAssertEqual(controller.state.ids, ["now", "r2", "r1", "r3"])
    }

    func testAnEmptyStationIsRetriedOnceWhileTheQueueEndsThere() async {
        let radio = FakeRadioSource()
        let (controller, _) = makeController(radio: radio)
        controller.setItems([testSong("now")], startIndex: 0)
        await controller.waitForAutoplay()
        XCTAssertEqual(radio.requests, ["now", "now"], "one bounded retry, not polling")
        XCTAssertEqual(controller.state.ids, ["now"])
    }

    func testAFailedLoadAtTheEndOfTheQueueIsRetriedOnce() async {
        let radio = FakeRadioSource()
        radio.setStation("now", station("r", count: 2))
        radio.setFailure("now", times: 1)
        let (controller, _) = makeController(radio: radio)
        controller.setItems([testSong("now")], startIndex: 0)
        await controller.waitForAutoplay()
        XCTAssertEqual(radio.requests, ["now", "now"])
        XCTAssertEqual(controller.state.ids, ["now", "r1", "r2"])
    }

    func testAFailedLoadMidQueueIsNotRetried() async {
        let radio = FakeRadioSource()
        radio.setFailure("a")
        let (controller, _) = makeController(radio: radio)
        controller.setItems([testSong("a"), testSong("b")], startIndex: 0)
        await controller.waitForAutoplay()
        XCTAssertEqual(radio.requests, ["a"])
        XCTAssertEqual(controller.state.ids, ["a", "b"])
    }

    func testTheQueueRunningDryReArmsAutoplayAndPlaysOnWhenTracksArrive() async {
        let radio = FakeRadioSource()
        let (controller, _) = makeController(radio: radio)
        let recorder = ItemChangeRecorder()
        recorder.attach(to: controller)
        controller.setItems([testSong("a"), testSong("b")], startIndex: 0)
        await controller.waitForAutoplay()
        controller.trackDidFinish()
        await controller.waitForAutoplay()
        XCTAssertEqual(controller.state.currentSong?.videoId, "b")

        // The station for b was empty; by the time b ends it has songs.
        radio.setStation("b", station("late", count: 2))
        XCTAssertEqual(controller.trackDidFinish(), .ended)
        await controller.waitForAutoplay()
        XCTAssertEqual(controller.state.currentSong?.videoId, "late1", "the queue moved on by itself")
        XCTAssertEqual(recorder.changes.last(where: { $0.song?.videoId == "late1" })?.playback, .play)
    }

    /// "Previous" on a queue that ran out restarts its last track; the retry AutoPlay made when the
    /// queue ended must then queue up behind that track, not cut it off.
    func testAutoplayArrivingAfterTheLastTrackWasRestartedQueuesBehindIt() async {
        let radio = FakeRadioSource()
        let (controller, _) = makeController(radio: radio)
        let recorder = ItemChangeRecorder()
        recorder.attach(to: controller)
        controller.setItems([testSong("a"), testSong("b")], startIndex: 1)
        await controller.waitForAutoplay()
        controller.recordPlayhead(positionMs: 200_000, isPlaying: true)

        radio.gate = RadioGate()
        XCTAssertEqual(controller.trackDidFinish(), .ended)
        await waitUntil { radio.requests.count == 3 }
        controller.skipToPrevious(positionMs: 200_000)
        XCTAssertEqual(recorder.last?.reason, .restartCurrent)

        radio.setStation("b", station("late", count: 2))
        radio.gate?.release()
        await controller.waitForAutoplay()
        XCTAssertEqual(controller.state.currentSong?.videoId, "b", "still playing the restarted track")
        XCTAssertEqual(controller.state.upcomingIds, ["late1", "late2"])
        XCTAssertEqual(recorder.last?.reason, .restartCurrent, "nothing moved the queue on")
    }

    func testAnEditThatEmptiesTheTailReArmsAutoplay() async {
        let radio = FakeRadioSource()
        radio.setStation("now", station("r", count: 1))
        let (controller, _) = makeController(radio: radio)
        controller.setItems([testSong("now")], startIndex: 0)
        await controller.waitForAutoplay()
        XCTAssertEqual(controller.state.ids, ["now", "r1"])
        radio.setStation("now", station("q", count: 1))
        controller.removeFromQueue(at: 1)
        await controller.waitForAutoplay()
        XCTAssertEqual(controller.state.ids, ["now", "q1"])
    }

    func testAutoplayStaysQuietWhenOffOrUnderRepeatAll() async {
        let radio = FakeRadioSource()
        radio.setStation("now", station("r", count: 3))
        let (off, _) = makeController(autoplay: false, radio: radio)
        off.setItems([testSong("now")], startIndex: 0)
        await off.waitForAutoplay()
        XCTAssertEqual(off.state.ids, ["now"])

        let settings = makeSettings(autoplay: true)
        settings.repeatMode = .all
        let looping = PlaybackQueueController(settings: settings, radioSource: radio)
        looping.setItems([testSong("now")], startIndex: 0)
        await looping.waitForAutoplay()
        XCTAssertEqual(looping.state.ids, ["now"])
        XCTAssertTrue(radio.requests.isEmpty)
    }

    func testASkipCancelsTheLoadForTheTrackLeftBehind() async {
        let radio = FakeRadioSource()
        radio.setStation("a", station("ra", count: 2))
        radio.setStation("b", station("rb", count: 2))
        let (controller, _) = makeController(radio: radio)
        controller.setItems([testSong("a"), testSong("b")], startIndex: 0)
        controller.skipToNext()
        await controller.waitForAutoplay()
        XCTAssertFalse(controller.state.ids.contains("ra1"), "a's suggestions landed after the listener moved on")
        XCTAssertEqual(controller.state.upcomingIds, ["rb1", "rb2"])
    }
}
