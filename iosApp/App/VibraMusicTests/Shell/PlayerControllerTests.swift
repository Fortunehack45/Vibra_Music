import AudioCache
import AudioDSP
import VibraMusicCore
import Playback
import PlaybackQueue
import XCTest
@testable import VibraMusic

/// PlayerController wired to a real engine playing local files through a fake resolver: the queue
/// drives the engine, the engine reports back, and the app's operations do what they say.
@MainActor
final class PlayerControllerWiringTests: XCTestCase {
    func testPlayingASongLoadsTheResolvedStreamIntoTheEngineAndItPlays() async throws {
        let harness = PlayerHarness(test: self)
        let first = try harness.song("aaaaaaaaaa1")
        let second = try harness.song("aaaaaaaaaa2")

        harness.player.play([first, second], startAt: 0, source: QueueSource(title: "Album", type: .browse, id: "MPREb1"))

        XCTAssertEqual(harness.player.currentSong?.videoId, first.videoId)
        XCTAssertEqual(harness.engine.currentItem?.song?.videoId, first.videoId, "the engine loads the queue's current entry")
        await waitUntil("the engine plays") { harness.engine.isPlaying }
        XCTAssertEqual(harness.resolver.requestedIds.first, first.videoId, "the stream is resolved through the app's resolver")
        let start = harness.player.position
        try await Task.sleep(for: .seconds(1))
        XCTAssertGreaterThan(harness.player.position, start + 0.5, "the position advances")
        XCTAssertEqual(harness.player.pipelineStatus, .playing)
        await waitUntil("the engine asks what follows") { harness.engine.upcomingItem?.song?.videoId == second.videoId }
    }

    /// A downloaded row still in the queue after its file was deleted streams instead of failing.
    func testADownloadWhoseFileIsGoneStreamsInstead() async throws {
        let harness = PlayerHarness(test: self)
        var song = try harness.song("goneFile001")
        let gone = harness.directory.appending(path: "deleted-download.m4a")
        song.localUri = gone.absoluteString
        song.localPath = gone.path(percentEncoded: false)

        harness.player.play([song], startAt: 0)

        await waitUntil("the stream plays") { harness.engine.isPlaying }
        XCTAssertEqual(harness.resolver.requestedIds.first, song.videoId)
    }

    /// "Copy log" on a played track says how long it took to resolve and to sound. The engine's
    /// lines used to be filed under its item id (queue slot plus video id), which the paste never
    /// looks up, so a slow start left no timing in the log at all.
    func testTheTrackLogTimesResolutionAndFirstAudio() async throws {
        let harness = PlayerHarness(test: self)
        let song = try harness.song("timedStart1")

        harness.player.play([song], startAt: 0)
        await waitUntil("the engine plays") { harness.engine.isPlaying }

        let pasted = TrackLog.shared.forTrack(song)
        XCTAssertTrue(pasted.contains("resolved '\(song.title)' in "), pasted)
        XCTAssertTrue(pasted.contains("first audio for "), pasted)
    }

    /// Offline, a track's retries run out and it is parked with nothing on the deck. Once the
    /// network is back, Play has to open it again: tapping an empty deck did nothing.
    func testPlayAfterAnOfflineFailurePlaysOnceTheNetworkIsBack() async throws {
        let harness = PlayerHarness(test: self)
        let tone = try TestAudio.tone(seconds: 8, in: harness.directory, name: "offlineSong1")
        let song = Song(videoId: "offlineSong1", title: "Offline", artist: "Artist", durationText: "0:08")

        // Nothing served yet: every resolve fails, as it does offline.
        harness.player.play([song], startAt: 0)
        // The give-up, not a retry in flight: only it reports a third attempt.
        await waitUntil("the retries run out") { harness.engine.lastError?.attempt == 3 }
        XCTAssertFalse(harness.engine.isPlaying)

        harness.resolver.serve(song.videoId, from: tone)
        harness.player.play()
        await waitUntil("it plays once the network is back") { harness.engine.isPlaying }
    }

    func testNextPreviousAndSeekMoveTheQueueAndTheEngineTogether() async throws {
        let harness = PlayerHarness(test: self)
        let songs = try (1...3).map { try harness.song("bbbbbbbbbb\($0)") }
        harness.player.play(songs, startAt: 0)
        await waitUntil("playing") { harness.engine.isPlaying }

        XCTAssertTrue(harness.player.next())
        XCTAssertEqual(harness.player.currentIndex, 1)
        XCTAssertEqual(harness.engine.currentItem?.song?.videoId, songs[1].videoId)
        await waitUntil("the second track plays") { harness.engine.isPlaying && harness.engine.currentItem?.song?.videoId == songs[1].videoId }

        harness.player.seek(to: 3)
        await waitUntil("the seek lands") { harness.player.position >= 2.9 }

        // Past 10 s previous restarts; before it, it goes back a track.
        XCTAssertTrue(harness.player.previous())
        XCTAssertEqual(harness.player.currentIndex, 0)
        XCTAssertEqual(harness.engine.currentItem?.song?.videoId, songs[0].videoId)
    }

    /// Once the queue settles on a track, the partial add-on copies of the tracks it has moved past
    /// are dropped. The track before, this one and the ones read-ahead looks ahead for keep theirs
    /// (Android's `scheduleForeignCachePurge`).
    func testPartialAddonCopiesBehindTheQueueAreDroppedOnceItSettles() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let harness = PlayerHarness(test: self, cache: cache)
        harness.player.addonCachePurgeDelay = .milliseconds(100)
        let songs = try (0..<8).map { try harness.song("purgeAddon\($0)") }
        let keys = songs.map { AudioCacheKey.substitute(videoId: $0.videoId, atmosAllowed: true) }
        for key in keys {
            await cache.warmRange(key, source: InMemoryAudioSource(data: Data(count: 400_000), mimeType: "audio/mp4"), range: 0..<100_000)
        }

        harness.player.play(songs, startAt: 3)

        let deadline = Date().addingTimeInterval(10)
        var held: [Bool] = []
        repeat {
            try await Task.sleep(for: .milliseconds(100))
            held = []
            for key in keys { held.append(!(await cache.cachedRanges(of: key)).isEmpty) }
        } while held.prefix(2).contains(true) && Date() < deadline
        XCTAssertEqual(held, [false, false, true, true, true, true, true, true],
                       "the two tracks behind the one before lose theirs; the rest of the window keeps them")
    }

    func testDislikingThePlayingSongSkipsIt() async throws {
        let harness = PlayerHarness(test: self)
        let songs = try (1...2).map { try harness.song("cccccccccc\($0)") }
        harness.player.play(songs, startAt: 0)
        await waitUntil("playing") { harness.engine.isPlaying }

        XCTAssertEqual(harness.player.toggleDislike(), .dislike)

        XCTAssertEqual(harness.player.currentSong?.videoId, songs[1].videoId)
        XCTAssertEqual(harness.engine.currentItem?.song?.videoId, songs[1].videoId)
        XCTAssertEqual(harness.player.likeStatus(of: songs[0]), .dislike)
    }

    func testTheQueueIsRestoredPausedAfterARelaunch() async throws {
        let store = JSONFileStore(directory: makeTemporaryDirectory(self))
        let songs: [Song]
        let expectedOrder: [String]
        let expectedCurrent: String?
        do {
            let first = PlayerHarness(test: self, lastPlayed: LastPlayedStore(store: store))
            songs = try (1...3).map { try first.song("dddddddddd\($0)") }
            first.player.play(songs, startAt: 0)
            // Reordered by hand, then moved on a track.
            XCTAssertEqual(first.player.move(from: 2, to: 1), .done)
            XCTAssertTrue(first.player.next())
            await waitUntil("playing") { first.engine.isPlaying }
            expectedOrder = first.player.songs.map(\.videoId)
            expectedCurrent = first.player.currentSong?.videoId
            first.player.flushPersistence()
            first.engine.shutdown()
        }
        XCTAssertEqual(expectedOrder, [songs[0], songs[2], songs[1]].map(\.videoId))

        let relaunched = PlayerHarness(test: self, lastPlayed: LastPlayedStore(store: store))
        for song in songs {
            relaunched.resolver.serve(song.videoId, from: try TestAudio.tone(seconds: 8, in: relaunched.directory, name: song.videoId))
        }
        XCTAssertTrue(relaunched.player.restore())

        XCTAssertEqual(relaunched.player.songs.map(\.videoId), expectedOrder, "the queue comes back in the order it was left")
        XCTAssertEqual(relaunched.player.currentSong?.videoId, expectedCurrent, "on the track that was playing")
        XCTAssertEqual(relaunched.engine.currentItem?.song?.videoId, expectedCurrent, "loaded into the engine")
        XCTAssertFalse(relaunched.engine.playWhenReady, "restored paused")
    }

    func testWhenTheLastSongEndsAutoplayFetchesRelatedSongsAndPlaysOn() async throws {
        let settings = makeTestSettings()
        settings.autoplay = true
        let harness0 = PlayerHarness(test: self, settings: settings, radio: nil)
        let related = try harness0.song("eeeeeeeeee2", seconds: 6)
        harness0.engine.shutdown()

        let radio = FakeRadioSource(related: [related])
        let harness = PlayerHarness(test: self, settings: settings, radio: radio)
        harness.resolver.serve(related.videoId, from: try TestAudio.tone(seconds: 6, in: harness.directory, name: related.videoId))
        let last = try harness.song("eeeeeeeeee1", seconds: 1.5)

        harness.player.play([last], startAt: 0, source: QueueSource(title: "Playlist", type: .browse, id: "VLPL1"))
        await waitUntil("the related song follows the last one", timeout: 20) {
            harness.player.currentSong?.videoId == related.videoId && harness.engine.isPlaying
        }
        XCTAssertEqual(radio.requestedSeeds.first, last.videoId, "AutoPlay seeds the station on the song that was playing")
        XCTAssertTrue(harness.player.currentSong?.fromAutoplay == true)
    }

    func testTheResolverIsAskedUnderThePerNetworkCeiling() async throws {
        let harness = PlayerHarness(test: self, request: { .playback(.low) })
        let song = try harness.song("ffffffffff1")
        harness.player.play([song], startAt: 0)
        await waitUntil("resolved") { !harness.resolver.requests.isEmpty }
        XCTAssertEqual(harness.resolver.requests.first?.request, .playback(.low))
        XCTAssertEqual(harness.resolver.requests.first?.request.maxKbps, 64)
    }

    func testAPartyHostsLockRefusesSkipsAndSaysSo() async throws {
        let harness = PlayerHarness(test: self)
        let songs = try (1...2).map { try harness.song("gggggggggg\($0)") }
        harness.player.play(songs, startAt: 0)
        harness.queue.party = AutoplayPartyContext(code: "ABC123", yourMemberId: "me", members: [], partyAutoplayEnabled: false,
                                                   hostOnlyControl: true, controlsLocked: true, upcomingTracks: [])

        XCTAssertFalse(harness.player.next())
        XCTAssertEqual(harness.player.currentIndex, 0)
        XCTAssertEqual(harness.player.notice?.message, L10n.listenTogetherHostOnlyNotice)
    }
}

/// Lossless and Atmos: what reaches the engine's processing tap (wave-b-plan "Lossless / Atmos").
@MainActor
final class SignalPathWiringTests: XCTestCase {
    func testADolbyAtmosItemPlaysWithoutTheDSPTap() async throws {
        let harness = PlayerHarness(test: self)
        harness.settings.equalizerEnabled = true
        let file = try TestAudio.tone(seconds: 6, format: .m4a, in: harness.directory, name: "atmos")
        let song = Song(videoId: "hhhhhhhhhh1", title: "Immersive", artist: "Mix", downloadFormat: "DOLBY")
        harness.factory.savedFile = { $0.videoId == song.videoId ? SavedAudioFile(url: file, isYouTubeOrigin: false) : nil }

        harness.player.play([song], startAt: 0)
        await waitUntil("the Atmos item opens") { harness.engine.signalPath != nil }

        XCTAssertEqual(harness.engine.signalPath, .spatialPassthrough, "no tap on an Atmos item, even with the EQ on")
        XCTAssertEqual(harness.player.signalPath, .spatialPassthrough)
    }

    func testALosslessItemIsBitTransparentUntilTheEqualizerGoesOn() async throws {
        let harness = PlayerHarness(test: self)
        harness.settings.loudnessNormalization = false
        let song = try harness.song("iiiiiiiiii1", format: .wav)

        harness.player.play([song], startAt: 0)
        await waitUntil("the lossless item opens") { harness.engine.signalPath != nil }
        XCTAssertEqual(harness.engine.signalPath, .bitTransparent)

        harness.settings.equalizerEnabled = true
        await waitUntil("the EQ puts the tap on") { harness.engine.signalPath == .processed }
    }

    func testALossyItemAlwaysGoesThroughTheTap() async throws {
        let harness = PlayerHarness(test: self)
        let song = try harness.song("jjjjjjjjjj1", format: .m4a)
        harness.player.play([song], startAt: 0)
        await waitUntil("the item opens") { harness.engine.signalPath != nil }
        XCTAssertEqual(harness.engine.signalPath, .processed)
    }

    func testTheProcessorOnlyAltersWhatItWouldChange() {
        var dsp = AudioDSPSettings()
        dsp.loudnessNormalization = true
        XCTAssertFalse(AudioDSPProcessor.alters(settings: dsp, automix: false, loudnessDb: nil), "no figure, no gain")
        XCTAssertFalse(AudioDSPProcessor.alters(settings: dsp, automix: false, loudnessDb: 0), "0 dB gain leaves samples alone")
        XCTAssertTrue(AudioDSPProcessor.alters(settings: dsp, automix: false, loudnessDb: 6))
        XCTAssertTrue(AudioDSPProcessor.alters(settings: AudioDSPSettings(spatialAudio: true, loudnessNormalization: false), automix: false, loudnessDb: nil))
        XCTAssertTrue(AudioDSPProcessor.alters(settings: AudioDSPSettings(loudnessNormalization: false), automix: true, loudnessDb: nil),
                      "Automix may ride the transition filter")
    }
}

/// Lock screen, Control Center, AirPods: the engine's remote commands reach the controller.
@MainActor
final class RemoteCommandWiringTests: XCTestCase {
    func testRemoteCommandsDriveTheQueueAndTheHeart() async throws {
        let harness = PlayerHarness(test: self)
        let songs = try (1...3).map { try harness.song("kkkkkkkkkk\($0)") }
        harness.player.play(songs, startAt: 0)
        await waitUntil("playing") { harness.engine.isPlaying }

        XCTAssertEqual(harness.remote.fire(.nextTrack), .success)
        XCTAssertEqual(harness.player.currentIndex, 1)

        XCTAssertEqual(harness.remote.fire(.previousTrack), .success)
        XCTAssertEqual(harness.player.currentIndex, 0)

        XCTAssertEqual(harness.remote.fire(.togglePlayPause), .success)
        XCTAssertFalse(harness.engine.playWhenReady)
        XCTAssertEqual(harness.remote.fire(.play), .success)
        XCTAssertTrue(harness.engine.playWhenReady)

        XCTAssertEqual(harness.remote.fire(.like(wasActive: false)), .success)
        XCTAssertEqual(harness.player.likeStatus(), .like)
        XCTAssertTrue(harness.remote.feedback.liked, "the lock screen's heart lights")

        await waitUntil("playing again") { harness.engine.isPlaying }
        XCTAssertEqual(harness.remote.fire(.changePlaybackPosition(2)), .success)
        await waitUntil("the lock-screen scrub lands") { harness.player.position >= 1.9 }
    }

    func testWithNothingLoadedCommandsSayThereIsNothingToControl() {
        let harness = PlayerHarness(test: self)
        XCTAssertEqual(harness.remote.fire(.nextTrack), .noActionableNowPlayingItem)
    }
}
