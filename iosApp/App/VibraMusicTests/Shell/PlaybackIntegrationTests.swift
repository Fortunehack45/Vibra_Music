import AVFoundation
import AudioCache
import Automix
import VibraMusicCore
import Foundation
import Observation
import ListenTogether
import Playback
import PlaybackPolicy
import PlaybackQueue
import Sources
import XCTest
@testable import VibraMusic

// The four integration gaps the shell left: Automix's planner and the cache's renditions, the song
// ↔ music video switch landing at the aligned position, the quality upgrade of a stream that came
// back below the request, and Listen Together's state reaching the queue.

// MARK: - Automix

/// Recorded analyses standing in for the analyzer.
@MainActor
final class RecordedAnalyses: AutomixAnalysisProviding {
    var analyses: [String: TrackAnalysis] = [:]
    private(set) var requested: [(trackId: String, uri: URL, duration: Double)] = []

    func analysis(for trackId: String) -> TrackAnalysis { analyses[trackId] ?? TrackAnalysis(trackId: trackId) }

    func state(of trackId: String) -> AutomixAnalysisState {
        analyses[trackId]?.isUsable == true ? .analysed : .waiting
    }

    func request(trackId: String, uri: URL, durationSeconds: Double) {
        requested.append((trackId, uri, durationSeconds))
    }

    /// A fixture recorded by Automix's live test (SoundHelix songs 1 and 2, both models), read
    /// through the analysis store's own file format.
    static func recorded(_ name: String, as trackId: String, test: XCTestCase) throws -> TrackAnalysis {
        let fixture = try XCTUnwrap(
            Bundle(for: PlaybackIntegrationFixtures.self).url(forResource: "\(name).analysis", withExtension: "json")
                ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/\(name).analysis.json"),
            "fixture \(name)"
        )
        let directory = makeTemporaryDirectory(test)
        try FileManager.default.copyItem(at: fixture, to: directory.appending(path: storeFileName(for: trackId)))
        return try XCTUnwrap(AutomixAnalysisStore(directory: directory).load(trackId))
    }

    /// The store's file name for a track id: Java's `String.hashCode` as unsigned, then the
    /// UTF-16 length (AutomixAnalysisStore keeps Android's scheme).
    static func storeFileName(for trackId: String) -> String {
        var hash: Int32 = 0
        for unit in trackId.utf16 { hash = hash &* 31 &+ Int32(unit) }
        return "\(UInt32(bitPattern: hash))_\(trackId.utf16.count).json"
    }
}

final class PlaybackIntegrationFixtures {}

@MainActor
final class AutomixPlannerWiringTests: XCTestCase {
    private func context(outgoing: Song, incoming: Song, position: TimeInterval, duration: TimeInterval, incomingDuration: TimeInterval?) -> TransitionContext {
        TransitionContext(
            outgoing: PlayableItem(song: outgoing, source: .file(URL(fileURLWithPath: "/dev/null"))),
            incoming: PlayableItem(song: incoming, source: .file(URL(fileURLWithPath: "/dev/null"))),
            position: position,
            duration: duration,
            incomingDuration: incomingDuration,
            fallbackOverlap: 6
        )
    }

    func testTwoRecordedAnalysesBecomeABeatMatchedBlendTheEngineExecutes() throws {
        let analyzer = RecordedAnalyses()
        let outgoing = try RecordedAnalyses.recorded("soundhelix-song-1", as: "shSong00001", test: self)
        let incoming = try RecordedAnalyses.recorded("soundhelix-song-2", as: "shSong00002", test: self)
        analyzer.analyses = ["shSong00001": outgoing, "shSong00002": incoming]
        let planner = AutomixTransitionPlanner { analyzer }
        let first = Song(videoId: "shSong00001", title: "Song 1", artist: "SoundHelix")
        let second = Song(videoId: "shSong00002", title: "Song 2", artist: "SoundHelix")

        let spec = try XCTUnwrap(planner.transitionSpec(for: context(
            outgoing: first, incoming: second, position: 30, duration: outgoing.duration, incomingDuration: incoming.duration
        )))

        // What the live run planned from the same numbers (Automix's RecordedAnalysisPlanningTests),
        // carried over into the engine's terms.
        XCTAssertEqual(spec.startTime, 361.810, accuracy: 0.01, "the blend starts at the analysed mix-out")
        XCTAssertEqual(spec.overlap, 5.329, accuracy: 0.01, "eight beats long")
        XCTAssertEqual(spec.incomingCueTime, 40.576, accuracy: 0.01, "the incoming track is cued into its intro, not 0:00")
        let expectedRate = (1 / (incoming.bpm / outgoing.bpm) * 10000).rounded() / 10000
        XCTAssertEqual(spec.incomingRate, expectedRate, accuracy: 1e-9, "stretched onto the outgoing tempo")
        guard case .ride(let ride) = spec.filters else { return XCTFail("a DJ blend rides the filters") }
        XCTAssertEqual(ride.style, .djBlend)
        XCTAssertTrue(ride.bassSwap, "the low end changes hands on the beat")
        XCTAssertTrue(spec.isRealMix)
        XCTAssertTrue(spec.markerVisible, "both sides measured: the window may be drawn")

        XCTAssertEqual(Set(analyzer.requested.map(\.trackId)), ["shSong00001", "shSong00002"], "both sides are asked for")
        XCTAssertEqual(analyzer.requested.first?.uri.absoluteString, "vibramusic://watch?v=shSong00001")
        XCTAssertEqual(planner.pairStatus?.style, .djBlend)
        XCTAssertEqual(planner.pairStatus?.current, .analysed)
    }

    func testWithoutAnalysisTheCrossfadeIsTheFallback() {
        let analyzer = RecordedAnalyses()
        let planner = AutomixTransitionPlanner { analyzer }
        let first = Song(videoId: "noAnalysis1", title: "One", artist: "A")
        let second = Song(videoId: "noAnalysis2", title: "Two", artist: "B")

        let spec = planner.transitionSpec(for: context(outgoing: first, incoming: second, position: 10, duration: 200, incomingDuration: 180))

        XCTAssertEqual(spec?.startTime ?? 0, 194, accuracy: 0.01, "the fallback fade ends with the track")
        XCTAssertEqual(spec?.overlap ?? 0, 6, accuracy: 0.01)
        XCTAssertEqual(spec?.incomingCueTime, 0)
        XCTAssertEqual(spec?.incomingRate, 1)
        XCTAssertEqual(spec?.isRealMix, false)
        XCTAssertEqual(spec?.markerVisible, false, "nothing measured: no window on the scrubber")
    }

    func testNothingIsMeasuredWhileStopped() {
        let analyzer = RecordedAnalyses()
        var stopped = true
        let planner = AutomixTransitionPlanner(isStopped: { stopped }) { analyzer }
        let first = Song(videoId: "stopped0001", title: "One", artist: "A")
        let second = Song(videoId: "stopped0002", title: "Two", artist: "B")
        _ = planner.transitionSpec(for: context(outgoing: first, incoming: second, position: 10, duration: 200, incomingDuration: 180))
        XCTAssertTrue(analyzer.requested.isEmpty, "a party (or Automix off) measures nothing")
        stopped = false
        _ = planner.transitionSpec(for: context(outgoing: first, incoming: second, position: 10, duration: 200, incomingDuration: 180))
        XCTAssertEqual(analyzer.requested.count, 2)
    }

    func testASourceBackedRowIsAnalysedThroughItsYouTubeMatch() {
        let song = Song(videoId: "src:jiosaavn::abc", title: "Kesariya", artist: "Arijit Singh", durationText: "4:28")
        let uri = AutomixTransitionPlanner.analysisURI(for: song)
        XCTAssertEqual(uri.host, "source", "the analyzer resolves source URIs to YouTube's copy")
        let items = URLComponents(url: uri, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "title" }?.value, "Kesariya")
        XCTAssertEqual(items.first { $0.name == "d" }?.value, "268")
    }

    func testThePlannerIsWiredIntoTheEngineAndCarriesTheCueAndRate() async throws {
        // End to end through the real engine: Automix on, the planner answers with a cued,
        // stretched blend, and the incoming track opens at its cue.
        let settings = makeTestSettings()
        let harness = PlayerHarness(test: self, settings: settings)
        let first = try harness.song("automixEnd1", seconds: 8)
        let second = try harness.song("automixEnd2", seconds: 12)
        let planner = FixedPlanner(spec: TransitionSpec(startTime: 3, overlap: 2, incomingCueTime: 4, incomingRate: 1.02,
                                                        filters: .ride(TransitionFilterRide(style: .djBlend, bassSwap: true)), markerVisible: true))
        harness.engine.transitionPlanner = planner
        settings.smartFadeEnabled = true
        await waitUntil("Automix on") { harness.engine.automixEnabled }

        harness.player.play([first, second], startAt: 0)
        await waitUntil("the blend hands over to the second track", timeout: 20) {
            harness.player.currentSong?.videoId == second.videoId && harness.engine.currentItem?.song?.videoId == second.videoId
        }
        XCTAssertGreaterThanOrEqual(harness.player.position, 4, "the incoming track entered at its cue, not 0:00")
        XCTAssertGreaterThan(planner.asked, 0)
    }
}

@MainActor
private final class FixedPlanner: TransitionPlanning {
    let spec: TransitionSpec
    private(set) var asked = 0
    init(spec: TransitionSpec) { self.spec = spec }
    func transitionSpec(for context: TransitionContext) -> TransitionSpec? {
        asked += 1
        return spec
    }
}

final class AudioCacheRenditionsTests: XCTestCase {
    func testACachedRenditionIsLinkedAsAnAudioFileTheAnalyzerCanDecode() async throws {
        let directory = makeTemporaryDirectory(self)
        let cache = try AudioStreamCache(configuration: .init(directory: directory.appending(path: "cache"), minimumFreeBytes: 0,
                                                              availableCapacity: { _ in nil }))
        let tone = try TestAudio.tone(seconds: 6, in: directory, name: "rendition")
        let key = AudioCacheKey.youtube(videoId: "renditionA1")
        let filled = await cache.cacheCompletely(key, source: InMemoryAudioSource(data: try Data(contentsOf: tone), mimeType: "audio/mp4"))
        XCTAssertTrue(filled)
        let provider = AudioCacheRenditions(cache: cache, linkDirectory: directory.appending(path: "links"))
        let uri = URL(string: "vibramusic://watch?v=renditionA1")!

        let renditions = await provider.refresh(trackID: "renditionA1")

        let rendition = try XCTUnwrap(renditions.first)
        XCTAssertEqual(rendition.key, "renditionA1", "YouTube's own copy: the key the analyzer treats as canonical")
        XCTAssertTrue(rendition.isComplete)
        XCTAssertEqual(rendition.fileURL.pathExtension, "m4a", "named so AVAssetReader picks the MP4 parser")
        let length = await AutomixAudioDecoder.containerDuration(of: rendition.fileURL)
        XCTAssertEqual(length ?? 0, 6, accuracy: 0.1, "the link decodes as the cached track")
        XCTAssertEqual(provider.renditions(of: uri).map(\.key), ["renditionA1"], "the synchronous answer is the snapshot")
        XCTAssertEqual(provider.cacheKey(of: uri), "renditionA1")

        // Evicted: the link goes with it, so the bytes aren't kept alive through it.
        await cache.discard(trackID: "renditionA1")
        let after = await provider.refresh(trackID: "renditionA1")
        XCTAssertTrue(after.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rendition.fileURL.path(percentEncoded: false)))
    }

    /// Refreshing one track touches only that track's links, not a directory listing: another
    /// track's dead link survives it. A track the cache evicted and nobody refreshes again still
    /// doesn't keep its bytes on disk through its link: the next refresh past the sweep interval
    /// sweeps it.
    func testADeadLinkNobodyRefreshesIsSweptOnceTheIntervalPasses() async throws {
        let directory = makeTemporaryDirectory(self)
        let cache = try AudioStreamCache(configuration: .init(directory: directory.appending(path: "cache"), minimumFreeBytes: 0,
                                                              availableCapacity: { _ in nil }))
        let data = Data(repeating: 0xAB, count: 2048)
        _ = await cache.cacheCompletely(AudioCacheKey.youtube(videoId: "sweepA1"), source: InMemoryAudioSource(data: data, mimeType: "audio/mp4"))
        _ = await cache.cacheCompletely(AudioCacheKey.youtube(videoId: "sweepB1"), source: InMemoryAudioSource(data: data, mimeType: "audio/mp4"))
        // A dead link only the provider's startup sweep removes: once it's gone that sweep is over,
        // so it can't race the assertions below.
        let links = directory.appending(path: "links")
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        let sentinel = links.appending(path: "sentinel.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: sentinel.path(percentEncoded: false), contents: Data([1])))
        let clock = SweepTestClock()
        let provider = AudioCacheRenditions(cache: cache, linkDirectory: links, now: { clock.date })
        await waitUntil("the startup sweep ran") { !FileManager.default.fileExists(atPath: sentinel.path(percentEncoded: false)) }

        _ = await provider.refresh(trackID: "sweepA1")
        let renditionsB = await provider.refresh(trackID: "sweepB1")
        let linkB = try XCTUnwrap(renditionsB.first?.fileURL)

        await cache.discard(trackID: "sweepB1")
        _ = await provider.refresh(trackID: "sweepA1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: linkB.path(percentEncoded: false)),
                      "refreshing one track must not list the directory and prune another track's links")

        clock.date += AudioCacheRenditions.sweepInterval + 1
        _ = await provider.refresh(trackID: "sweepA1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: linkB.path(percentEncoded: false)),
                       "the evicted track's link went, though that track was never refreshed again")
    }

    func testSnapshotsStayBoundedAfterManyTracks() async throws {
        let directory = makeTemporaryDirectory(self)
        let cache = try AudioStreamCache(configuration: .init(directory: directory.appending(path: "cache"), minimumFreeBytes: 0,
                                                              availableCapacity: { _ in nil }))
        let provider = AudioCacheRenditions(cache: cache, linkDirectory: directory.appending(path: "links"))

        let total = 80
        for i in 0..<total {
            let data = Data(repeating: UInt8(i % 251) + 1, count: 512)
            _ = await cache.cacheCompletely(AudioCacheKey.youtube(videoId: "bulk\(i)"), source: InMemoryAudioSource(data: data, mimeType: "audio/mp4"))
            _ = await provider.refresh(trackID: "bulk\(i)")
        }

        let recent = URL(string: "vibramusic://watch?v=bulk\(total - 1)")!
        XCTAssertFalse(provider.renditions(of: recent).isEmpty, "the most recent track's snapshot is still served")
        let oldest = URL(string: "vibramusic://watch?v=bulk0")!
        XCTAssertTrue(provider.renditions(of: oldest).isEmpty, "the oldest snapshots were evicted, so the map stays within its bound")
    }

    func testLinkExtensionsFollowTheCachedType() {
        XCTAssertEqual(AudioCacheRenditions.fileExtension(forMimeType: "audio/mp4"), "m4a")
        XCTAssertEqual(AudioCacheRenditions.fileExtension(forMimeType: "audio/flac"), "flac")
        XCTAssertEqual(AudioCacheRenditions.fileExtension(forMimeType: "audio/mpeg"), "mp3")
        XCTAssertEqual(AudioCacheRenditions.fileExtension(forMimeType: nil), "m4a")
    }
}

/// Bytes served from memory, as a network source would (a file source is never cached).
struct InMemoryAudioSource: AudioRangeDataSource {
    let data: Data
    let mimeType: String

    func contentInfo() async throws -> AudioContentInfo { AudioContentInfo(contentLength: Int64(data.count), mimeType: mimeType) }
    func read(_ range: Range<Int64>) async throws -> Data { data.subdata(in: Int(range.lowerBound)..<Int(min(range.upperBound, Int64(data.count)))) }
    func stream(_ range: Range<Int64>) -> AsyncThrowingStream<Data, Error> {
        let chunk = data.subdata(in: Int(range.lowerBound)..<Int(min(range.upperBound, Int64(data.count))))
        return AsyncThrowingStream { continuation in
            continuation.yield(chunk)
            continuation.finish()
        }
    }
    var maxRangeBytes: Int64 { Int64.max }
    var requiresYouTubeDurationFix: Bool { false }
    var isCacheable: Bool { true }
}

// MARK: - Song ↔ music video

@MainActor
final class VersionSwitchWiringTests: XCTestCase {
    func testSwitchingVersionsLandsAtTheAlignedPosition() async throws {
        let harness = PlayerHarness(test: self)
        harness.settings.smartVersionAlignment = true
        let song = try harness.song("versionSong", seconds: 20)
        let video = try harness.song("versionVid1", seconds: 26)
        harness.player.versionFinder = { _ in video }
        var asked: [(String, String)] = []
        harness.player.versionAligner = { source, target in
            asked.append((source.videoId, target.videoId))
            try? await Task.sleep(for: .milliseconds(300))
            return 4_000
        }
        harness.player.play([song], startAt: 0)
        await waitUntil("playing") { harness.engine.isPlaying }
        harness.player.seek(to: 3)
        await waitUntil("at 3 s") { harness.player.position >= 3 }

        await harness.player.switchVersion()

        XCTAssertEqual(asked.first?.0, song.videoId)
        XCTAssertEqual(asked.first?.1, video.videoId)
        XCTAssertEqual(harness.player.currentSong?.videoId, video.videoId, "the queue slot now holds the video")
        await waitUntil("the video plays") { harness.engine.currentItem?.song?.videoId == video.videoId && harness.engine.isPlaying }
        // 3 s in plus the 300 ms the measurement took, plus the 4 s offset.
        XCTAssertGreaterThanOrEqual(harness.player.position, 7.0, "the offset was applied to where the song had got to")
        XCTAssertLessThan(harness.player.position, 9.5)
        XCTAssertFalse(harness.engine.transitionsSuspended, "transitions are back once the swap has landed")
    }

    func testNoVersionSwitchInAListenTogetherParty() async throws {
        // Android refuses the swap in a party: every member plays the same cut.
        let harness = PlayerHarness(test: self)
        let song = try harness.song("partySong01", seconds: 10)
        let video = try harness.song("partyVideo1", seconds: 10)
        var looked = 0
        harness.player.versionFinder = { _ in
            looked += 1
            return video
        }
        harness.player.play([song], startAt: 0)
        await waitUntil("playing") { harness.engine.isPlaying }
        harness.player.isInParty = true

        await harness.player.switchVersion()

        XCTAssertEqual(looked, 0, "nothing is even looked up")
        XCTAssertEqual(harness.player.currentSong?.videoId, song.videoId)
        XCTAssertNil(harness.player.notice, "no \"couldn't find\" for a refusal")
    }

    func testNoCouldntFindWhenTheQueueMovedOnDuringTheLookup() async throws {
        // The lookup is a network round trip; a skip during it is not a failed lookup.
        let harness = PlayerHarness(test: self)
        let first = try harness.song("lookupSong1", seconds: 10)
        let second = try harness.song("lookupSong2", seconds: 10)
        harness.player.versionFinder = { [player = harness.player] _ in
            player.next()
            try? await Task.sleep(for: .milliseconds(200))
            return nil
        }
        harness.player.play([first, second], startAt: 0)
        await waitUntil("playing") { harness.engine.isPlaying }

        await harness.player.switchVersion()

        XCTAssertEqual(harness.player.currentSong?.videoId, second.videoId)
        XCTAssertNil(harness.player.notice, "no \"couldn't find\" about a track that is no longer playing")
    }

    func testTheMusicOnlyPreferenceConvertsAVideoThatStartsPlaying() async throws {
        // The setting is on, so a music video that starts playing becomes its catalogue audio
        // version (MainActivity's LaunchedEffect keyed on the song and the preference).
        let harness = PlayerHarness(test: self)
        var video = try harness.song("musicOnlyVid1", seconds: 20)
        video.isVideo = true
        let audio = try harness.song("musicOnlyAud1", seconds: 20)
        harness.player.versionFinder = { song in song.videoId == video.videoId ? audio : nil }
        harness.settings.preferMusicOnly = true

        harness.player.play([video], startAt: 0)

        await waitUntil("the audio version plays") {
            harness.player.currentSong?.videoId == audio.videoId && harness.engine.isPlaying
        }
        XCTAssertNil(harness.player.notice, "no \"couldn't find\" for an automatic conversion")
        XCTAssertEqual(harness.player.songs.count, 1, "the queue slot now holds the audio version")
    }

    func testAVideoKeepsPlayingWhileTheMusicOnlyPreferenceIsOff() async throws {
        let harness = PlayerHarness(test: self)
        var video = try harness.song("musicOffVideo", seconds: 12)
        video.isVideo = true
        let audio = try harness.song("musicOffAudio", seconds: 12)
        var looks = 0
        harness.player.versionFinder = { _ in
            looks += 1
            return audio
        }

        harness.player.play([video], startAt: 0)
        await waitUntil("the video plays") { harness.engine.isPlaying }
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(harness.player.currentSong?.videoId, video.videoId)
        XCTAssertEqual(looks, 0, "nothing is even looked up")
        XCTAssertNil(harness.player.notice)
    }

    func testTurningOnTheMusicOnlyPreferenceHoldsTheVideoUntilTheAudioVersionResolves() async throws {
        // Android pauses for the automatic lookup (pauseWhileResolving) and resumes whatever the
        // lookup leaves playing; turning the setting on mid-play must convert the video too.
        let harness = PlayerHarness(test: self)
        var video = try harness.song("musicHoldVideo", seconds: 20)
        video.isVideo = true
        let audio = try harness.song("musicHoldAudio", seconds: 20)
        var looking = false
        var released = false
        harness.player.versionFinder = { _ in
            looking = true
            var waited = 0
            while !released, waited < 400 {
                try? await Task.sleep(for: .milliseconds(20))
                waited += 1
            }
            return audio
        }
        harness.player.play([video], startAt: 0)
        await waitUntil("the video plays") { harness.engine.isPlaying }

        harness.settings.preferMusicOnly = true

        await waitUntil("the audio version is being looked up") { looking }
        XCTAssertFalse(harness.player.playWhenReady, "the video is held while the other cut resolves")
        released = true
        await waitUntil("the audio version plays") {
            harness.player.currentSong?.videoId == audio.videoId && harness.engine.isPlaying
        }
        XCTAssertNil(harness.player.notice, "no \"couldn't find\" for an automatic conversion")
    }

    /// The automatic lookup pauses the video; a skip during it is the listener moving on while
    /// playing, so the next track plays rather than loading into the lookup's pause.
    func testASkipDuringTheMusicOnlyLookupPlaysTheNextTrack() async throws {
        let harness = PlayerHarness(test: self)
        var video = try harness.song("skipHoldVideo", seconds: 20)
        video.isVideo = true
        let audio = try harness.song("skipHoldAudio", seconds: 20)
        let next = try harness.song("skipHoldNext1", seconds: 20)
        var looking = false
        var released = false
        harness.player.versionFinder = { song in
            guard song.videoId == video.videoId else { return nil }
            looking = true
            var waited = 0
            while !released, waited < 400 {
                try? await Task.sleep(for: .milliseconds(20))
                waited += 1
            }
            return audio
        }
        harness.settings.preferMusicOnly = true
        harness.player.play([video, next], startAt: 0)
        await waitUntil("the audio version is being looked up") { looking }
        XCTAssertFalse(harness.player.playWhenReady, "the video is held while the other cut resolves")

        harness.player.next()
        released = true

        await waitUntil("the next track plays") {
            harness.player.currentSong?.videoId == next.videoId && harness.engine.isPlaying
        }
    }

    /// A skip onto a second music video while the first one's lookup still runs: the second is
    /// converted once that lookup ends, rather than refused for good.
    func testASkipOntoAnotherVideoDuringTheMusicOnlyLookupConvertsItToo() async throws {
        let harness = PlayerHarness(test: self)
        var first = try harness.song("twoVideosVid1", seconds: 20)
        first.isVideo = true
        var second = try harness.song("twoVideosVid2", seconds: 20)
        second.isVideo = true
        let firstAudio = try harness.song("twoVideosAud1", seconds: 20)
        let secondAudio = try harness.song("twoVideosAud2", seconds: 20)
        var looking = false
        var released = false
        var reached = false
        harness.player.versionFinder = { song in
            if song.videoId == second.videoId {
                // Nothing ahead of time, so the skip lands on the video itself.
                return reached ? secondAudio : nil
            }
            guard song.videoId == first.videoId else { return nil }
            looking = true
            var waited = 0
            while !released, waited < 400 {
                try? await Task.sleep(for: .milliseconds(20))
                waited += 1
            }
            return firstAudio
        }
        harness.settings.preferMusicOnly = true
        harness.player.play([first, second], startAt: 0)
        await waitUntil("the first video's audio version is being looked up") { looking }

        reached = true
        harness.player.next()
        await waitUntil("on the second video") { harness.player.currentSong?.videoId == second.videoId }
        // Long enough for the second video's own conversion to be asked for, and refused.
        try await Task.sleep(for: .milliseconds(300))
        released = true

        await waitUntil("the second video's audio version plays") {
            harness.player.currentSong?.videoId == secondAudio.videoId && harness.engine.isPlaying
        }
    }

    /// A pause pressed during the automatic lookup is the listener's: the audio version replaces
    /// the video, paused, instead of resuming over them.
    func testAPauseDuringTheMusicOnlyLookupIsKept() async throws {
        let harness = PlayerHarness(test: self)
        var video = try harness.song("pauseHoldVid1", seconds: 20)
        video.isVideo = true
        let audio = try harness.song("pauseHoldAud1", seconds: 20)
        var looking = false
        var released = false
        harness.player.versionFinder = { song in
            guard song.videoId == video.videoId else { return nil }
            looking = true
            var waited = 0
            while !released, waited < 400 {
                try? await Task.sleep(for: .milliseconds(20))
                waited += 1
            }
            return audio
        }
        harness.settings.preferMusicOnly = true
        harness.player.play([video], startAt: 0)
        await waitUntil("the audio version is being looked up") { looking }

        harness.player.pause()
        released = true

        await waitUntil("the audio version replaces the video") { harness.player.currentSong?.videoId == audio.videoId }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(harness.player.playWhenReady, "the listener's pause is kept")
        XCTAssertFalse(harness.engine.isPlaying)
    }

    func testTurningOnTheMusicOnlyPreferenceWithNothingQueuedIsHarmless() async throws {
        let harness = PlayerHarness(test: self)
        XCTAssertTrue(harness.player.songs.isEmpty)

        harness.settings.preferMusicOnly = true
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertNil(harness.player.currentSong)
    }

    func testNoAudioMatchLeavesTheVideoPlayingWithoutANotice() async throws {
        let harness = PlayerHarness(test: self)
        var video = try harness.song("musicNoMatchVid", seconds: 15)
        video.isVideo = true
        var looks = 0
        harness.player.versionFinder = { _ in
            looks += 1
            return nil
        }
        harness.settings.preferMusicOnly = true

        harness.player.play([video], startAt: 0)

        await waitUntil("the automatic look happens") { looks >= 1 }
        await waitUntil("the video keeps playing") {
            harness.player.currentSong?.videoId == video.videoId && harness.engine.isPlaying
        }
        XCTAssertNil(harness.player.notice, "a missed match is silent on the automatic path")
    }

    func testAVideoTheListenerSwitchedBackToIsNotConvertedAgainUntilTheSongChanges() async throws {
        let harness = PlayerHarness(test: self)
        var first = try harness.song("keptFirstVideo", seconds: 15)
        first.isVideo = true
        let firstAudio = try harness.song("keptFirstAudio", seconds: 15)
        var second = try harness.song("keptSecondVide", seconds: 15)
        second.isVideo = true
        let secondAudio = try harness.song("keptSecondAud", seconds: 15)
        let cuts = [first.videoId: firstAudio, firstAudio.videoId: first,
                    second.videoId: secondAudio, secondAudio.videoId: second]
        harness.player.versionFinder = { song in cuts[song.videoId] }
        harness.settings.preferMusicOnly = true

        harness.player.play([first], startAt: 0)
        await waitUntil("the first video converts") {
            harness.player.currentSong?.videoId == firstAudio.videoId && harness.engine.isPlaying
        }

        // Back to the video by hand (the menu's "Convert to video").
        await harness.player.switchVersion()
        await waitUntil("the video is back") {
            harness.player.currentSong?.videoId == first.videoId && harness.engine.isPlaying
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(harness.player.currentSong?.videoId, first.videoId,
                       "a video the listener switched back to is not converted again")
        XCTAssertNil(harness.player.notice)

        // The song changes: the preference applies to the next video, and to the kept one once
        // it comes back.
        harness.player.play([second], startAt: 0)
        await waitUntil("the second video converts") {
            harness.player.currentSong?.videoId == secondAudio.videoId && harness.engine.isPlaying
        }
        harness.player.play([first], startAt: 0)
        await waitUntil("the first video converts again") {
            harness.player.currentSong?.videoId == firstAudio.videoId && harness.engine.isPlaying
        }
    }

    /// A playlist of music videos with music-only on: the first converts from its top with nothing
    /// measured, and the next ones are already songs by the time they play, so the engine preloads
    /// the songs themselves and each advance is as quick as any other track's.
    func testTheNextVideosAreConvertedWhileTheCurrentTrackPlays() async throws {
        let harness = PlayerHarness(test: self)
        var first = try harness.song("aheadFirstVid", seconds: 15)
        first.isVideo = true
        let firstAudio = try harness.song("aheadFirstAud", seconds: 15)
        var second = try harness.song("aheadSecndVid", seconds: 15)
        second.isVideo = true
        let secondAudio = try harness.song("aheadSecndAud", seconds: 15)
        let cuts = [first.videoId: firstAudio, second.videoId: secondAudio]
        harness.player.versionFinder = { song in cuts[song.videoId] }
        var measured = 0
        harness.player.versionAligner = { _, _ in
            measured += 1
            return 4_000
        }
        harness.settings.smartVersionAlignment = true
        harness.settings.preferMusicOnly = true

        harness.player.play([first, second], startAt: 0)
        await waitUntil("the first video converts") {
            harness.player.currentSong?.videoId == firstAudio.videoId && harness.engine.isPlaying
        }
        XCTAssertEqual(measured, 0, "converted at its start: the song plays from its top, nothing is measured")
        XCTAssertLessThan(harness.player.position, 3, "from the top, not 4 s in")
        await waitUntil("the next video is already its audio version") { harness.player.songs.last?.videoId == secondAudio.videoId }
        await waitUntil("the engine preloads the song itself") { harness.engine.upcomingItem?.song?.videoId == secondAudio.videoId }
    }

    /// A video that arrives by crossfade becomes the playing song at the hand-over, while the mix is
    /// still running and the swap is refused. It must be converted when the mix ends.
    func testAVideoThatArrivesByCrossfadeIsConvertedOnceTheMixIsOver() async throws {
        let harness = PlayerHarness(test: self)
        harness.settings.crossfadeSeconds = 2
        let first = try harness.song("mixFirstAudio", seconds: 8)
        var video = try harness.song("mixArrivesVid", seconds: 12)
        video.isVideo = true
        let audio = try harness.song("mixArrivesAud", seconds: 12)
        // The look-ahead found nothing in time (it answers only for the video once it is playing),
        // so the video really does reach the mix as a video.
        harness.player.versionFinder = { song in
            song.videoId == video.videoId && harness.player.currentSong?.videoId == video.videoId && !harness.engine.isTransitioning ? audio : nil
        }
        harness.settings.preferMusicOnly = true

        harness.player.play([first, video], startAt: 0)
        await waitUntil("the video arrives by crossfade", timeout: 20) { harness.player.currentSong?.videoId == video.videoId }

        await waitUntil("the mix ends and the audio version plays", timeout: 20) {
            harness.player.currentSong?.videoId == audio.videoId && harness.engine.isPlaying && !harness.engine.isTransitioning
        }
        XCTAssertNil(harness.player.notice)
    }

    func testADeadlineAnswersOnTimeEvenWhenTheWorkIgnoresCancellation() async {
        // The alignment's 30 s and the upgrade proof's 20 s are Kotlin's withTimeoutOrNull: they
        // must not wait for a decode or an AVFoundation load that doesn't check for cancellation.
        let started = ContinuousClock.now
        let late: Int? = await withDeadline(.milliseconds(200)) {
            blockThread(seconds: 2)
            return 1
        }
        XCTAssertNil(late)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
        let quick: Int? = await withDeadline(.seconds(5)) { 7 }
        XCTAssertEqual(quick, 7)
    }

    func testTheAlignedPositionIsClampedToTheOtherCut() {
        XCTAssertEqual(PlayerController.alignedPosition(sourceMs: 2_000, offsetMs: -6_500), 0, "never before the start")
        XCTAssertEqual(PlayerController.alignedPosition(sourceMs: 200_000, offsetMs: 30_000, targetDurationMs: 210_000), 209_000,
                       "never past the other cut's last second")
        XCTAssertEqual(PlayerController.alignedPosition(sourceMs: 60_000, offsetMs: 6_500, targetDurationMs: 210_000), 66_500)
    }

    func testTheRealAlignerMeasuresTheVideosIntroAndTheSwitchAppliesIt() async throws {
        // Two local cuts of the same "recording": the video carries 3 s of intro in front.
        let harness = PlayerHarness(test: self)
        harness.settings.smartVersionAlignment = true
        let songURL = try TestAudio.pattern(seconds: 50, in: harness.directory, name: "cutSong")
        let videoURL = try TestAudio.pattern(seconds: 50, leadingSilence: 3, in: harness.directory, name: "cutVideo")
        let song = Song(videoId: "alignSong01", title: "Cut", artist: "Band", durationText: "0:50", localUri: songURL.absoluteString)
        let video = Song(videoId: "alignVideo1", title: "Cut (Official Video)", artist: "Band", durationText: "0:53",
                         isVideo: true, localUri: videoURL.absoluteString)
        let service = VersionAlignmentService(
            aligner: VersionAudioAligner(),
            cache: nil,
            renditions: nil,
            headSource: { _ in nil },
            remoteStream: { _ in nil }
        )
        service.publishStatus(to: harness.player)
        harness.player.versionFinder = { _ in video }
        harness.player.versionAligner = { source, target in await service.offset(from: source, to: target) }
        harness.player.play([song], startAt: 0)
        await waitUntil("playing") { harness.engine.isPlaying }
        harness.player.seek(to: 5)
        await waitUntil("at 5 s") { harness.player.position >= 5 }
        // Paused, so the playhead stays put however long the measurement takes.
        harness.player.pause()
        await waitUntil("paused") { !harness.engine.isPlaying }
        let pausedAt = harness.player.position

        await harness.player.switchVersion()

        await waitUntil("the status reaches the player") { harness.player.versionAlignment?.phase == .aligned }
        let status = try XCTUnwrap(harness.player.versionAlignment)
        XCTAssertEqual(status.sourceId, song.videoId)
        XCTAssertEqual(status.targetId, video.videoId)
        XCTAssertEqual(Double(status.offsetMs ?? 0), 3_000, accuracy: 60, "the intro is measured, not assumed")
        XCTAssertTrue(status.concerns(video.videoId))
        await waitUntil("the video is loaded") { harness.engine.currentItem?.song?.videoId == video.videoId && !harness.engine.isBuffering }
        XCTAssertEqual(harness.player.position, pausedAt + 3, accuracy: 0.15, "5 s into the song is 8 s into the video")
        XCTAssertFalse(harness.engine.playWhenReady, "a paused switch stays paused")

        // Switching back recalls the reversed offset instead of measuring again.
        harness.player.versionFinder = { _ in song }
        await harness.player.switchVersion()
        await waitUntil("recalled") { harness.player.versionAlignment?.fromCache == true }
        XCTAssertEqual(Double(harness.player.versionAlignment?.offsetMs ?? 0), -3_000, accuracy: 60)
    }

    func testASecondSwitchToTheSameCounterpartDoesNotSilenceTheMeasurementsPhases() async throws {
        let harness = PlayerHarness(test: self)
        let songURL = try TestAudio.pattern(seconds: 50, in: harness.directory, name: "joinSong")
        let videoURL = try TestAudio.pattern(seconds: 50, leadingSilence: 3, in: harness.directory, name: "joinVideo")
        let song = Song(videoId: "joinSong001", title: "Join", artist: "Band", durationText: "0:50", localUri: songURL.absoluteString)
        let video = Song(videoId: "joinVideo01", title: "Join (Official Video)", artist: "Band", durationText: "0:53",
                         isVideo: true, localUri: videoURL.absoluteString)
        let aligner = VersionAudioAligner()
        let service = VersionAlignmentService(aligner: aligner, cache: nil, renditions: nil, headSource: { _ in nil }, remoteStream: { _ in nil })
        let updates = aligner.statusUpdates()
        let phases = Task { () -> [VersionAudioAligner.CutPhase] in
            var seen: [VersionAudioAligner.CutPhase] = []
            for await status in updates {
                guard let phase = status?.phase else { continue }
                seen.append(phase)
                if phase == .aligned || phase == .failed { break }
            }
            return seen
        }

        async let first = service.offset(from: song, to: video)
        async let second = service.offset(from: song, to: video)
        _ = await (first, second)

        let seen = await phases.value
        XCTAssertTrue(seen.contains(.measuring), "the joiner must not cut off the measurement's own phases: \(seen)")
    }
}

// MARK: - Quality upgrade

/// Sources' upgrade search, canned: a better copy per title, and a count of the looks.
final class FakeUpgradeSearch: QualityUpgradeSearching, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: ResolvedStream] = [:]
    private var log: [String] = []
    var delay: Duration = .zero
    private var holding = false

    /// Holds every answer until ``release()``, for a test that must act while the look is open.
    func hold() { lock.withLock { holding = true } }
    func release() { lock.withLock { holding = false } }

    func answer(_ title: String, with stream: ResolvedStream) { lock.withLock { answers[title] = stream } }
    func answer(for title: String) -> ResolvedStream? { lock.withLock { answers[title] } }
    var searchedTitles: [String] { lock.withLock { log } }
    /// Searches ("search") and drops of the completed answers ("clear"), in order.
    var trail: [String] { lock.withLock { steps } }
    private var steps: [String] = []

    var canSubstituteForYouTube: Bool { true }

    func clearCompletedAnswers() async {
        lock.withLock { steps.append("clear") }
    }

    func findUpgrade(for target: QualityUpgrade.Target, playing: StreamFormat?, excluding servedBy: String?,
                     isWorthSwapping: @escaping @Sendable (ResolvedStream) -> Bool) async throws -> ResolvedStream? {
        let found: ResolvedStream? = lock.withLock {
            log.append(target.title)
            steps.append("search")
            return answers[target.title]
        }
        try await Task.sleep(for: delay)
        while lock.withLock({ holding }) { try await Task.sleep(for: .milliseconds(20)) }
        return found.flatMap { isWorthSwapping($0) ? $0 : nil }
    }
}

/// Counts the tracks the player reports as started, repeats included.
@MainActor
final class StartCounter: PlaybackEventObserver {
    private(set) var videoIds: [String] = []
    var count: Int { videoIds.count }

    func playback(didStart song: Song, durationMs: Int64, isPlaying: Bool, previous: Song?, previousListened: Bool, previousPositionMs: Int64) {
        videoIds.append(song.videoId)
    }
}

/// How many times the source factory was asked what to request.
final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// A connection a test flips, readable inside an observation like the real monitor's status.
@MainActor @Observable
final class FlippableConnection {
    var unmetered = true
}

/// Keeps what the player said about the track a start replaced.
@MainActor
final class PreviousPositionRecorder: PlaybackEventObserver {
    private(set) var previousPositionsMs: [Int64] = []

    func playback(didStart song: Song, durationMs: Int64, isPlaying: Bool, previous: Song?, previousListened: Bool, previousPositionMs: Int64) {
        previousPositionsMs.append(previousPositionMs)
    }
}

/// What the silent proof saw of the upgrade rendition's cache entry, recorded the moment it ran —
/// the one point that is after the warm-ups and before the swap — and where the playhead was.
@MainActor
final class UpgradeWarmSnapshot {
    var ranges: [Range<Int64>] = []
    var requested: [Range<Int64>] = []
    var position: TimeInterval = -1
}

/// What a test says the engine's crossfade is doing, and when the silent proof finished. Time since
/// the last blend ended keeps counting, as the engine's does.
@MainActor
final class CrossfadeStandIn {
    var isRunning = false
    var provedAt: ContinuousClock.Instant?
    private var endedAt: ContinuousClock.Instant?

    func endedSecondsAgo(_ seconds: Double) { endedAt = .now - .seconds(seconds) }

    var reading: QualityUpgradeController.CrossfadeReading {
        .init(isRunning: isRunning, sinceEnded: endedAt.map { (ContinuousClock.now - $0) / .seconds(1) })
    }
}

/// Where a WAV's audio starts: just past its `data` chunk header. Apple's writer pads the header,
/// so it isn't the textbook 44 bytes.
func wavAudioStart(of file: URL) throws -> Int64 {
    let bytes = try Data(contentsOf: file)
    let chunk = try XCTUnwrap(bytes.range(of: Data("data".utf8)), "no data chunk in \(file.lastPathComponent)")
    return Int64(chunk.upperBound - bytes.startIndex) + 4
}

@MainActor
final class QualityUpgradeWiringTests: XCTestCase {
    /// - Parameters:
    ///   - minRemaining: how much track a swap needs left; none by default, as these tracks run seconds.
    ///   - ceiling: the ceiling followed, when a test lowers it; lossless throughout otherwise.
    private func controller(_ harness: PlayerHarness, search: FakeUpgradeSearch, pinned: @escaping (String) -> Bool = { _ in false },
                            minRemaining: TimeInterval = 0, ceiling: PlaybackQualityCeiling? = nil,
                            proofClock: QualityUpgradeController.ProofClock = QualityUpgradeController.standardProof,
                            prove: (@MainActor (Song, ResolvedStream, String) async -> TimeInterval?)? = nil,
                            crossfade: (@MainActor () -> QualityUpgradeController.CrossfadeReading)? = nil) -> QualityUpgradeController {
        let stats = NerdStats()
        let request: @Sendable () -> StreamRequest
        if let ceiling { request = { ceiling.currentRequest } } else { request = { .playback(.lossless) } }
        let upgrades = QualityUpgradeController(
            upgrade: QualityUpgrade(search: search, requestForNow: request, streamChoice: StreamChoice(), nerdStats: stats),
            nerdStats: stats,
            settings: harness.settings,
            isPinned: pinned,
            minRemaining: minRemaining,
            proofClock: proofClock,
            prove: prove,
            crossfade: crossfade
        )
        harness.player.qualityUpgrades = upgrades
        if let ceiling { upgrades.follow(ceiling) }
        return upgrades
    }

    /// Whether the swap has been asked of the engine: the playing row (the queue's own entry of the
    /// song, which carries its slot id) is reopened as the `hifi` copy.
    private func upgradeAsked(_ harness: PlayerHarness) -> Bool {
        harness.player.currentSong.map { harness.factory.renditionTag(for: $0) } == "hifi"
    }

    private func losslessCopy(_ harness: PlayerHarness, seconds: Double, name: String) throws -> ResolvedStream {
        let url = try TestAudio.tone(seconds: seconds, format: .wav, in: harness.directory, name: name)
        return ResolvedStream(url: url, origin: .addon, mimeType: "audio/wav", format: StreamFormat(codec: "flac", sampleRateHz: 44_100, bitDepth: 16),
                              durationSeconds: Int(seconds), sourceConfigId: "lossless-addon")
    }

    func testABelowRequestStreamIsSwappedForTheBetterCopyOnce() async throws {
        let harness = PlayerHarness(test: self)
        let search = FakeUpgradeSearch()
        _ = controller(harness, search: search)
        let song = try harness.song("upgradeSng1", seconds: 10)
        harness.resolver.markBelowRequest(song.videoId)
        search.answer(song.title, with: try losslessCopy(harness, seconds: 10, name: "upgradeFlac"))
        search.delay = .seconds(2.5)

        harness.player.play([song], startAt: 0)
        await waitUntil("the upgrade is swapped in", timeout: 20) {
            harness.engine.currentItem?.id.hasSuffix("#hifi") == true && harness.engine.isPlaying
        }
        XCTAssertEqual(harness.player.currentStream?.format.codec, "flac", "stats describe the copy now playing")
        guard case .upgraded(_, let to)? = harness.player.qualityUpgrade?.phase else { return XCTFail("the badge says upgraded") }
        XCTAssertEqual(to.codec, "flac")
        XCTAssertGreaterThan(harness.player.position, 1.0, "the swap carried on from where the track was, not from 0:00")

        // Once: the upgraded copy is not looked at again, and nothing else is swapped in.
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(search.searchedTitles, [song.title])
        XCTAssertTrue(harness.engine.currentItem?.id.hasSuffix("#hifi") == true)
        XCTAssertEqual(harness.player.currentSong?.videoId, song.videoId)
    }

    func testATrackPinnedToTheOriginalIsNeverUpgraded() async throws {
        let harness = PlayerHarness(test: self)
        let search = FakeUpgradeSearch()
        _ = controller(harness, search: search, pinned: { _ in true })
        let song = try harness.song("upgradePin1", seconds: 8)
        harness.resolver.markBelowRequest(song.videoId)
        search.answer(song.title, with: try losslessCopy(harness, seconds: 8, name: "pinnedFlac"))

        harness.player.play([song], startAt: 0)
        await waitUntil("playing") { harness.engine.isPlaying }
        try await Task.sleep(for: .seconds(1.5))

        XCTAssertTrue(search.searchedTitles.isEmpty, "a pinned track is not a candidate for anything")
        XCTAssertFalse(harness.engine.currentItem?.id.contains("#") ?? true)
        XCTAssertNil(harness.player.qualityUpgrade)
    }

    func testACopyOfAnotherLengthIsNotSwappedIn() async throws {
        let harness = PlayerHarness(test: self)
        harness.settings.upgradeLengthSlackSeconds = 1
        let search = FakeUpgradeSearch()
        _ = controller(harness, search: search)
        let song = try harness.song("upgradeLen1", seconds: 8)
        harness.resolver.markBelowRequest(song.videoId)
        // Claims the right length but decodes to 14 s: the silent proof catches it.
        var wrongCut = try losslessCopy(harness, seconds: 14, name: "longerCut")
        wrongCut.durationSeconds = 8
        search.answer(song.title, with: wrongCut)

        harness.player.play([song], startAt: 0)
        await waitUntil("the upgrade gives up", timeout: 20) { harness.player.qualityUpgrade?.phase == .unavailable }
        XCTAssertFalse(harness.engine.currentItem?.id.contains("#") ?? true, "the playing stream was never touched")
        XCTAssertEqual(search.searchedTitles.count, 1)
        // The proof is silent: stats still describe the copy that plays, not the one refused.
        XCTAssertNotEqual(harness.player.currentStream?.format.codec, "flac", "a refused copy never reaches stats for nerds")
        let playingID = try XCTUnwrap(harness.engine.currentItem?.id)
        XCTAssertNotEqual(harness.player.sources.facts.stream(for: playingID)?.format.codec, "flac")
    }

    func testTheLengthCheckReadsTheDecodersLengthNotTheCatalogues() async throws {
        // The catalogue says 0:30 but the stream playing decodes to 10 s, as does the better
        // copy: the same recording, so it swaps. Measured against the catalogue it would not.
        let harness = PlayerHarness(test: self)
        harness.settings.upgradeLengthSlackSeconds = 1
        let search = FakeUpgradeSearch()
        _ = controller(harness, search: search)
        var song = try harness.song("upgradeCat1", seconds: 10)
        song.durationText = "0:30"
        harness.resolver.markBelowRequest(song.videoId)
        search.answer(song.title, with: try losslessCopy(harness, seconds: 10, name: "catalogueFlac"))

        harness.player.play([song], startAt: 0)
        await waitUntil("the upgrade is swapped in", timeout: 20) {
            harness.engine.currentItem?.id.hasSuffix("#hifi") == true
        }
        guard case .upgraded? = harness.player.qualityUpgrade?.phase else {
            return XCTFail("upgraded, got \(String(describing: harness.player.qualityUpgrade?.phase))")
        }
    }

    func testUpgradeQualityWithoutASearchReopensTheTrackForReal() async throws {
        // No upgrade controller (or nothing outranks YouTube): the track is resolved again. The
        // reopen needs a new engine identity, or the engine would reuse the asset it already has.
        let harness = PlayerHarness(test: self)
        let song = try harness.song("reopenSong1", seconds: 8)
        harness.player.play([song], startAt: 0)
        await waitUntil("playing") { harness.engine.isPlaying }
        XCTAssertEqual(harness.resolver.requestedIds, [song.videoId])

        harness.player.upgradeQuality()

        await waitUntil("resolved again") { harness.resolver.requestedIds.count == 2 }
        // Playing, the reopened copy is crossed over to once it's buffered ahead of the playhead.
        await waitUntil("the reopened copy plays on") {
            harness.engine.currentItem?.id.hasSuffix("#reopen-1") == true && harness.engine.isPlaying
        }
        XCTAssertEqual(harness.player.currentSong?.videoId, song.videoId)
    }

    /// A press on a row playing `hifi-2` (left whole on disk by an earlier session) looks into
    /// `hifi`, not the slot it plays from, which would empty and warm the very entry being read.
    func testAnUpgradeTargetsTheSlotTheRowIsNotPlayingFrom() {
        XCTAssertEqual(QualityUpgradeController.generation(playing: nil), 1)
        XCTAssertEqual(QualityUpgradeController.generation(playing: "original"), 1)
        XCTAssertEqual(QualityUpgradeController.generation(playing: "hifi"), 2)
        XCTAssertEqual(QualityUpgradeController.generation(playing: "hifi-2"), 1)
    }

    func testAManualUpgradeIsThrottled() async throws {
        let harness = PlayerHarness(test: self)
        let search = FakeUpgradeSearch()
        let upgrades = controller(harness, search: search)
        let song = try harness.song("upgradeMan1", seconds: 8)
        harness.player.play([song], startAt: 0)
        await waitUntil("playing") { harness.engine.isPlaying }

        let playing = try XCTUnwrap(harness.player.currentSong)
        let first = upgrades.requestByHand(for: playing, playing: harness.player.currentStream)
        XCTAssertEqual(first, .searching)
        await waitUntil("the look finishes") { harness.player.qualityUpgrade?.phase == .unavailable }
        let second = upgrades.requestByHand(for: playing, playing: harness.player.currentStream)
        guard case .coolingDown(let remaining) = second else { return XCTFail("a second press inside 30 s is refused, got \(second)") }
        XCTAssertGreaterThan(remaining, 25_000)
    }

    /// A track reached by advancing through the queue still gets its automatic second look.
    ///
    /// The engine preloads the next item for gapless, so the second row's stream resolves while the
    /// first is still current. That answer used to be dropped (`currentSong` was the guard), and the
    /// automatic upgrade never ran for a track that was advanced to rather than started directly.
    func testATrackReachedByAdvancingStillGetsItsAutomaticUpgrade() async throws {
        let harness = PlayerHarness(test: self)
        let search = FakeUpgradeSearch()
        let upgrades = controller(harness, search: search)
        search.delay = .seconds(4)
        let first = try harness.song("advanceFirst", seconds: 8)
        let second = try harness.song("advanceSecnd", seconds: 8)
        harness.resolver.markBelowRequest(second.videoId)

        harness.player.play([first, second], startAt: 0)
        await waitUntil("the first track plays") { harness.engine.isPlaying && harness.player.currentSong?.videoId == first.videoId }
        await waitUntil("the next item is preloaded") { harness.engine.upcomingItem?.song?.videoId == second.videoId }
        // The queue assigns each row its own queue entry id, so the id the engine knows the row by
        // is the queued copy's, not the bare Song this test built.
        let queuedSecond = try XCTUnwrap(harness.player.songs.first { $0.videoId == second.videoId })
        let secondID = PlayerController.itemID(for: queuedSecond)
        await waitUntil("the preload resolved the next row's stream") { harness.player.sources.facts.stream(for: secondID) != nil }
        XCTAssertEqual(harness.player.currentSong?.videoId, first.videoId, "still on the first while the next is only preloaded")
        XCTAssertNotEqual(harness.player.currentStream?.url, harness.player.sources.facts.stream(for: secondID)?.url,
                          "the preload's stream does not describe the first track while it plays")

        XCTAssertTrue(harness.player.next())

        XCTAssertEqual(harness.player.currentSong?.videoId, second.videoId)
        await waitUntil("the second track plays") { harness.engine.currentItem?.song?.videoId == second.videoId }
        let preloaded = try XCTUnwrap(harness.player.sources.facts.stream(for: secondID))
        await waitUntil("the held stream describes the second track") { harness.player.currentStream == preloaded }
        await waitUntil("the automatic upgrade starts for the second track") { upgrades.status?.videoId == second.videoId }
        XCTAssertEqual(upgrades.status?.phase, .searching, "the below-request stream started the second look")
    }

    /// Skipped away before its second look answered, then straight back: the engine reuses the
    /// row's opened audio, so nothing resolves again, and the question left open is asked again.
    func testComingBackBeforeTheUpgradeLandedStillUpgradesTheTrack() async throws {
        let harness = PlayerHarness(test: self)
        let search = FakeUpgradeSearch()
        let upgrades = controller(harness, search: search)
        let first = try harness.song("returnFirst", seconds: 12)
        let second = try harness.song("returnSecnd", seconds: 12)
        harness.resolver.markBelowRequest(first.videoId)
        search.answer(first.title, with: try losslessCopy(harness, seconds: 12, name: "returnFlac"))
        search.delay = .seconds(30)

        harness.player.play([first, second], startAt: 0)
        await waitUntil("the first track's second look is searching") {
            upgrades.status?.videoId == first.videoId && upgrades.status?.isUpgrading == true
        }
        XCTAssertTrue(harness.player.next())
        await waitUntil("the second track plays") { harness.engine.currentItem?.song?.videoId == second.videoId && harness.engine.isPlaying }
        search.delay = .zero
        XCTAssertTrue(harness.player.previous())

        await waitUntil("the first track is upgraded on its return", timeout: 20) {
            harness.player.currentSong?.videoId == first.videoId && harness.engine.currentItem?.id.hasSuffix("#hifi") == true
        }
    }

    /// Upgraded, skipped away from, then come back to: the row plays its ordinary copy again, and
    /// the copy found last time is proved back in without searching again.
    func testComingBackToAnUpgradedTrackPutsTheBetterCopyBackWithoutSearching() async throws {
        let harness = PlayerHarness(test: self)
        let search = FakeUpgradeSearch()
        _ = controller(harness, search: search)
        let first = try harness.song("shelfFirst1", seconds: 12)
        let second = try harness.song("shelfSecnd1", seconds: 12)
        harness.resolver.markBelowRequest(first.videoId)
        search.answer(first.title, with: try losslessCopy(harness, seconds: 12, name: "shelfFlac"))

        harness.player.play([first, second], startAt: 0)
        await waitUntil("the first track is upgraded", timeout: 20) { harness.engine.currentItem?.id.hasSuffix("#hifi") == true }
        XCTAssertTrue(harness.player.next())
        await waitUntil("the second track plays") { harness.engine.currentItem?.song?.videoId == second.videoId && harness.engine.isPlaying }
        XCTAssertTrue(harness.player.previous())

        await waitUntil("the better copy is back on the return", timeout: 20) {
            harness.player.currentSong?.videoId == first.videoId && harness.engine.currentItem?.id.hasSuffix("#hifi") == true
        }
        XCTAssertEqual(search.searchedTitles, [first.title], "the return re-proved the shelved copy instead of searching again")
    }

    /// The same return with the copy going through the cache: the shelved copy is proved back into
    /// the slot its bytes already fill. Proved into "the slot the row isn't playing" instead (the
    /// row's key still named `#hifi`, the copy swapped in before the skip), it was fetched again,
    /// whole, into `hifi-2` and swapped in for itself.
    func testComingBackToAnUpgradedTrackReadsItsCopyFromTheSlotItFills() async throws {
        let (harness, first, _, search) = try await upgradedAndSkippedPast("slotReturn1")
        XCTAssertTrue(harness.player.previous())

        await waitUntil("the better copy is back on the return", timeout: 20) {
            harness.player.currentSong?.videoId == first.videoId && harness.engine.currentItem?.id.contains("#hifi") == true
        }
        XCTAssertEqual(harness.engine.currentItem?.id.hasSuffix("#hifi"), true, "back in its own slot, not hifi-2")
        let cache = try XCTUnwrap(harness.cache)
        let other = await cache.cachedRanges(of: AudioCacheKey(trackID: first.videoId, rendition: "hifi-2"))
        XCTAssertEqual(other, [], "nothing of the copy fetched again")
        XCTAssertEqual(search.searchedTitles, [first.title])
    }

    /// Back on an upgraded row whose copy is now whole on disk: the fresh open plays it straight off
    /// the disk (`cachedCopy` picks a whole `#hifi`), so the row already plays the upgrade. Taken for
    /// a row "returning" to its ordinary copy, the shelved copy was downloaded again into `hifi-2`
    /// and crossed over to: the same audio, a second time over the network.
    func testAnUpgradedRowOpenedWholeOffTheDiskIsNotUpgradedAgain() async throws {
        let (harness, first, _, search) = try await upgradedAndSkippedPast("slotFresh01")
        let cache = try XCTUnwrap(harness.cache)
        let found = try XCTUnwrap(search.answer(for: first.title))
        // As a segmented copy's proof leaves it, or its completion once played.
        let filled = await cache.cacheCompletely(AudioCacheKey(trackID: first.videoId, rendition: "hifi"),
                                                 source: HTTPAudioSource(stream: found, session: FileRangeProtocol.session()))
        XCTAssertTrue(filled)

        harness.player.play([first], startAt: 0)
        await waitUntil("the row says it plays its upgrade", timeout: 20) {
            guard case .upgraded? = harness.player.qualityUpgrade?.phase else { return false }
            return harness.player.currentSong?.videoId == first.videoId
        }
        // Long enough for a proof and a swap from disk, were one under way.
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(harness.engine.currentItem?.id.contains("#"), false, "still the copy it opened off the disk")
        let other = await cache.cachedRanges(of: AudioCacheKey(trackID: first.videoId, rendition: "hifi-2"))
        XCTAssertEqual(other, [], "nothing of the copy fetched again")
        XCTAssertEqual(search.searchedTitles, [first.title])
    }

    /// Two rows; the first played below the request and upgraded to a lossless copy served over
    /// HTTP, so its bytes land in the cache's `#hifi` slot; then the queue moves on to the second.
    private func upgradedAndSkippedPast(_ id: String) async throws -> (PlayerHarness, Song, Song, FakeUpgradeSearch) {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let harness = PlayerHarness(test: self, cache: cache, session: FileRangeProtocol.session())
        let search = FakeUpgradeSearch()
        _ = controller(harness, search: search)
        let first = try harness.song(id, seconds: 12)
        let second = try harness.song("\(id)b", seconds: 12)
        harness.resolver.markBelowRequest(first.videoId)
        let remote = URL(string: "http://upgrade.test/\(id).wav")!
        FileRangeProtocol.serve(remote, from: try TestAudio.tone(seconds: 12, format: .wav, in: harness.directory, name: "\(id)Flac"))
        search.answer(first.title, with: ResolvedStream(url: remote, origin: .addon, mimeType: "audio/wav",
                                                        format: StreamFormat(codec: "flac", sampleRateHz: 44_100, bitDepth: 16),
                                                        durationSeconds: 12, sourceConfigId: "lossless-addon"))

        harness.player.play([first, second], startAt: 0)
        await waitUntil("the first track is upgraded", timeout: 20) { harness.engine.currentItem?.id.hasSuffix("#hifi") == true }
        XCTAssertTrue(harness.player.next())
        await waitUntil("the second track plays") { harness.engine.currentItem?.song?.videoId == second.videoId && harness.engine.isPlaying }
        return (harness, first, second, search)
    }

    /// A gapless advance reaches the next row before its stream has resolved. The track before it
    /// must not keep describing the new one — the stats line and the quality badge read
    /// ``PlayerController/currentStream`` for the copy playing and it must be nil until it resolves.
    func testAdvancingNeverLeavesThePreviousTracksStreamShowing() async throws {
        let harness = PlayerHarness(test: self)
        let first = try harness.song("prevStreamA", seconds: 2)
        let second = try harness.song("prevStreamB", seconds: 8)
        // Longer than the first track: the advance happens well before the second row resolves, so
        // there is a real window in which nothing is known for it.
        harness.resolver.delay(second.videoId, by: .seconds(4))

        harness.player.play([first, second], startAt: 0)
        await waitUntil("the first track's stream is current") {
            harness.engine.isPlaying && harness.player.currentSong?.videoId == first.videoId && harness.player.currentStream != nil
        }
        let firstStream = try XCTUnwrap(harness.player.currentStream)
        await waitUntil("the next item is preloaded") { harness.engine.upcomingItem?.song?.videoId == second.videoId }

        // Let the first track run out: a gapless advance the queue follows, not a skip.
        harness.player.seek(to: 1.8)
        await waitUntil("the second track is current") { harness.engine.currentItem?.song?.videoId == second.videoId }

        XCTAssertNotEqual(harness.player.currentStream?.url, firstStream.url, "the previous track's stream never describes the new one")
        XCTAssertNil(harness.player.currentStream, "nothing has resolved for the second row yet")
        await waitUntil("the second row's stream arrives") { harness.player.currentStream != nil }
        let currentID = try XCTUnwrap(harness.engine.currentItem?.id)
        XCTAssertEqual(harness.player.currentStream?.url, harness.player.sources.facts.stream(for: currentID)?.url)
    }

    /// The engine moved on by itself onto an item the queue no longer names next (the queue changed
    /// under the preload). The queue's row is loaded and reported; the stale item must never be
    /// reported as started, or scrobbling and history would log a song that never played.
    func testAnAdvanceOntoAStalePreloadReportsOnlyTheQueuesRow() async throws {
        let harness = PlayerHarness(test: self)
        let starts = StartCounter()
        harness.player.addObserver(starts)
        let first = try harness.song("staleAdvA01", seconds: 10)
        let second = try harness.song("staleAdvB01", seconds: 10)
        let third = try harness.song("staleAdvC01", seconds: 10)
        harness.player.play([first, second, third], startAt: 0)
        await waitUntil("the first track plays") { harness.engine.isPlaying && starts.videoIds == [first.videoId] }
        let stale = harness.player.sources.item(for: harness.player.songs[2])

        // The engine reports it advanced onto the third row, while the queue's next is the second.
        harness.player.audioPlayerEngine(harness.engine, didChangeItemTo: stale, reason: .ended)

        XCTAssertEqual(harness.player.currentSong?.videoId, second.videoId)
        XCTAssertEqual(harness.engine.currentItem?.song?.videoId, second.videoId, "what the queue says wins")
        XCTAssertEqual(starts.videoIds, [first.videoId, second.videoId], "the stale item is never reported as started")
    }

    /// A track the engine had to open itself (nothing preloaded) has its position reset before the
    /// start is announced; scrobbling and history must still get where the track before it stopped.
    func testAStartWithNothingPreloadedReportsTheTrackBeforeItsRealPosition() async throws {
        let harness = PlayerHarness(test: self)
        let recorder = PreviousPositionRecorder()
        harness.player.addObserver(recorder)
        let first = try harness.song("prevPosA0001", seconds: 30)
        let second = try harness.song("prevPosB0001", seconds: 30)
        harness.player.play([first, second], startAt: 0)
        await waitUntil("the first track plays") { harness.engine.isPlaying && recorder.previousPositionsMs.count == 1 }
        let firstItem = try XCTUnwrap(harness.engine.currentItem)

        // The engine's own checkpoint, then a skip in the same turn so no tick lands in between.
        harness.player.audioPlayerEngine(harness.engine, checkpoint: PlaybackCheckpoint(itemID: firstItem.id, position: 7, isPlaying: true))
        XCTAssertTrue(harness.player.next())
        await waitUntil("the second track starts") { recorder.previousPositionsMs.count == 2 }

        XCTAssertEqual(recorder.previousPositionsMs.last, 7_000)
    }

    /// What read-ahead fetches depends on the connection and on Direct source stream; a change in
    /// either must plan it again, not wait for the queue or play/pause to move.
    func testReadAheadPlansAgainWhenTheConnectionOrDirectSourceChanges() async throws {
        let counter = RequestCounter()
        let connection = FlippableConnection()
        let directory = makeTemporaryDirectory(self)
        let harness = PlayerHarness(test: self, cache: try makeTestCache(in: directory), request: { counter.bump(); return .playback(.lossless) })
        harness.factory.isUnmetered = { connection.unmetered }
        let first = try harness.song("replanA00001", seconds: 30)
        let second = try harness.song("replanB00001", seconds: 30)
        harness.player.play([first, second], startAt: 0)
        await waitUntil("playing, with the plan made") { harness.engine.isPlaying && counter.value > 0 }
        try? await Task.sleep(for: .milliseconds(300))

        var seen = counter.value
        connection.unmetered = false
        await waitUntil("going onto cellular plans again") { counter.value > seen }

        try? await Task.sleep(for: .milliseconds(300))
        seen = counter.value
        harness.settings.directSourceStream = .queueOnly
        await waitUntil("changing Direct source stream plans again") { counter.value > seen }
    }

    /// Repeat one replays the same row in place, so nothing is held for it and starting it clears
    /// the stream. The engine callback must then put it back from the facts the first resolve
    /// recorded: the quality badge, Stats for Nerds and the upgrade controller all read
    /// ``PlayerController/currentStream`` for the copy playing.
    func testARepeatOnePlayKeepsItsResolvedStream() async throws {
        let harness = PlayerHarness(test: self)
        let starts = StartCounter()
        harness.player.addObserver(starts)
        let song = try harness.song("repeatOne01", seconds: 2)

        harness.player.play([song], startAt: 0)
        await waitUntil("the track plays with its stream") { harness.engine.isPlaying && harness.player.currentStream != nil }
        let resolved = try XCTUnwrap(harness.player.currentStream)
        harness.player.setRepeatMode(.one)
        await waitUntil("the same track is preloaded to repeat") { harness.engine.upcomingItem?.song?.videoId == song.videoId }

        let before = starts.count
        // Let the track run out: the engine loops it and the queue follows.
        harness.player.seek(to: 1.8)
        await waitUntil("the track starts again") { starts.count > before }

        XCTAssertEqual(harness.player.currentStream, resolved, "the repeated play lost its stream")
    }

    /// A late answer for the copy an upgrade replaced is still ignored, even though a stream for a
    /// not-yet-current row is now held rather than dropped.
    func testALateAnswerForAReplacedRenditionIsStillIgnored() async throws {
        let harness = PlayerHarness(test: self)
        let search = FakeUpgradeSearch()
        let upgrades = controller(harness, search: search)
        let song = try harness.song("staleRend01", seconds: 8)
        harness.player.play([song], startAt: 0)
        await waitUntil("playing") { harness.engine.isPlaying && harness.player.currentStream != nil }
        let playing = try XCTUnwrap(harness.player.currentStream)
        let queued = try XCTUnwrap(harness.player.songs.first { $0.videoId == song.videoId })
        let oldID = PlayerController.itemID(for: queued)

        // The row is reopened as an upgraded copy: its engine item id now carries a #hifi tag.
        harness.factory.setRendition("hifi", stream: nil, for: queued)
        // A late answer for the copy it replaced arrives under the old, untagged id.
        let late = try losslessCopy(harness, seconds: 8, name: "staleLate")
        harness.factory.noteResolved(itemID: oldID, videoId: song.videoId, stream: late)

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(harness.player.currentStream?.url, playing.url, "the replaced copy's late answer never describes the row")
        XCTAssertNil(upgrades.status, "and it never starts an upgrade for the replaced copy")
        XCTAssertTrue(search.searchedTitles.isEmpty)
    }

    // MARK: Cached-track adoption (Android `adoptCachedTrack` / `QualityUpgrade.adoptUnresolved`)

    /// A fully cached YouTube track — started directly — is served from disk without ever being
    /// resolved, so nothing marks it for a second look. It must be adopted once the decoder reports
    /// it, and the same second look must run.
    func testAFullyCachedTrackIsAdoptedAndLookedAtOnceTheDecoderReportsIt() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let harness = PlayerHarness(test: self, cache: cache)
        let search = FakeUpgradeSearch()
        let upgrades = controller(harness, search: search)
        let song = try harness.song("cachedTrk01", seconds: 8)
        let filled = await cache.fillFullyCachedYouTube(song.videoId, from: harness.directory.appending(path: "cachedTrk01.m4a"))
        XCTAssertTrue(filled)
        search.delay = .seconds(2)
        search.answer(song.title, with: try losslessCopy(harness, seconds: 8, name: "cachedFlac"))

        harness.player.play([song], startAt: 0)

        await waitUntil("the cached track is adopted and the second look starts") {
            upgrades.status?.videoId == song.videoId && upgrades.status?.phase == .searching
        }
        XCTAssertTrue(harness.resolver.requestedIds.isEmpty, "a fully cached track never resolves a stream")
        XCTAssertEqual(search.searchedTitles, [song.title], "the second look was asked for the cached track")
        // And the swap lands exactly as it does on the resolved path.
        await waitUntil("the upgrade swaps in", timeout: 20) {
            harness.engine.currentItem?.id.hasSuffix("#hifi") == true
        }
        await waitUntil("stats describe the swapped-in copy") { harness.player.currentStream?.format.codec == "flac" }
    }

    /// "Upgrade quality" on a row played whole off the disk: nothing resolved it, so there is no
    /// stream to take a floor from. The press measures one as the automatic look does, so a 320 kbps
    /// copy can swap in over YouTube's 128; asked against no floor, only lossless passed.
    func testAPressOnACachedRowWeighsALossyCopyAgainstItsMeasuredFloor() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let harness = PlayerHarness(test: self, cache: cache)
        let search = FakeUpgradeSearch()
        let upgrades = controller(harness, search: search)
        let song = try harness.song("pressCached", seconds: 10)
        let filled = await cache.fillFullyCachedYouTube(song.videoId, from: harness.directory.appending(path: "pressCached.m4a"))
        XCTAssertTrue(filled)

        harness.player.play([song], startAt: 0)
        await waitUntil("the automatic look finds nothing", timeout: 20) { upgrades.status?.phase == .unavailable }
        XCTAssertNil(harness.player.currentStream, "played off the disk: no stream to take a floor from")
        let lossy = ResolvedStream(url: try TestAudio.tone(seconds: 10, in: harness.directory, name: "press320"), origin: .addon,
                                   mimeType: "audio/mp4", format: StreamFormat(codec: "aac", kbps: 320), durationSeconds: 10,
                                   sourceConfigId: "lossy-addon")
        search.answer(song.title, with: lossy)

        let playing = try XCTUnwrap(harness.player.currentSong)
        XCTAssertEqual(upgrades.requestByHand(for: playing, playing: harness.player.currentStream), .searching)

        await waitUntil("the 320 kbps copy swaps in", timeout: 20) { self.upgradeAsked(harness) }
        XCTAssertEqual(search.searchedTitles, [song.title, song.title])
    }

    /// The same track reached by advancing the queue: a gapless advance does not go through the
    /// resolver either, and the adoption must happen from the progress sample or the track change.
    func testAFullyCachedTrackReachedByAdvancingIsAdopted() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let harness = PlayerHarness(test: self, cache: cache)
        let search = FakeUpgradeSearch()
        let upgrades = controller(harness, search: search)
        let first = try harness.song("advanceCach1", seconds: 8)
        let second = try harness.song("advanceCach2", seconds: 8)
        let filled = await cache.fillFullyCachedYouTube(second.videoId, from: harness.directory.appending(path: "advanceCach2.m4a"))
        XCTAssertTrue(filled)
        search.answer(second.title, with: try losslessCopy(harness, seconds: 8, name: "advanceFlac"))

        harness.player.play([first, second], startAt: 0)
        await waitUntil("the first track plays") {
            harness.engine.isPlaying && harness.player.currentSong?.videoId == first.videoId
        }
        XCTAssertTrue(harness.player.next())
        await waitUntil("the cached second row is adopted") { upgrades.status?.videoId == second.videoId }
        // The status can name the song before the search is recorded: wait for it too.
        await waitUntil("the search ran for the second row") { search.searchedTitles == [second.title] }
    }

    /// A cached entry already holding lossless bytes gets no second look — and says so, because the
    /// line is the only way a correct verdict can be told from one reached on the wrong track.
    func testAFullyCachedLosslessTrackGetsNoSecondLook() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let harness = PlayerHarness(test: self, cache: cache)
        let search = FakeUpgradeSearch()
        let upgrades = controller(harness, search: search)
        let song = try harness.song("cachedFlac1", seconds: 6)
        // A real raw-FLAC file (the PlaybackPolicy tests' fixture): the container AVFoundation
        // decodes as `flac` and reports as lossless. (FLAC/ALAC written into CAF are refused by the
        // simulator's AVFoundation through a resource-loaded asset.)
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "VibraMusicKit/Tests/PlaybackPolicyTests/Fixtures/audio/flac_24_96.flac")
        let filled = await cache.fillFullyCachedYouTube(song.videoId, from: fixture, mimeType: "audio/flac")
        XCTAssertTrue(filled)

        harness.player.play([song], startAt: 0)
        let queued = try XCTUnwrap(harness.player.songs.first { $0.videoId == song.videoId })
        await waitUntil("the decoder reports the cached lossless track", timeout: 20) {
            harness.engine.stats?.itemID == harness.player.sources.engineItemID(for: queued) && harness.engine.stats?.codec != nil
        }
        try await Task.sleep(for: .seconds(1.5))

        XCTAssertTrue(search.searchedTitles.isEmpty, "a track already playing lossless needs no second look")
        XCTAssertNil(upgrades.status, "and no \"Upgrading quality\" badge flashes")
        let lines = TrackLog.shared.heldLines.map(\.text)
        XCTAssertTrue(lines.contains { $0.contains("'\(song.title)'") && $0.contains("from cache; no second look needed") }, "\(lines)")
    }

    /// A downloaded track owns its bytes on this device; the cached-track path must not spend data
    /// replacing the file the listener saved. A control row proves the same harness upgrades a
    /// stream row, so the refusal is the download guard and not the path being asleep.
    func testADownloadedTrackGetsNoSecondLook() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let harness = PlayerHarness(test: self, cache: cache)
        let search = FakeUpgradeSearch()
        let upgrades = controller(harness, search: search)
        let downloaded = try harness.song("downloadRow", seconds: 8)
        let saved = harness.directory.appending(path: "downloaded.m4a")
        try FileManager.default.copyItem(at: harness.directory.appending(path: "downloadRow.m4a"), to: saved)
        harness.factory.savedFile = { $0.videoId == downloaded.videoId ? SavedAudioFile(url: saved, isYouTubeOrigin: false) : nil }

        harness.player.play([downloaded], startAt: 0)
        await waitUntil("the download plays") { harness.engine.isPlaying }
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(search.searchedTitles.isEmpty, "a download is never replaced")
        XCTAssertNil(upgrades.status)

        // Control: a fully cached stream row in the same harness is adopted and searched.
        let cached = try harness.song("downloadCtl", seconds: 8)
        let filled = await cache.fillFullyCachedYouTube(cached.videoId, from: harness.directory.appending(path: "downloadCtl.m4a"))
        XCTAssertTrue(filled)
        search.answer(cached.title, with: try losslessCopy(harness, seconds: 8, name: "ctlFlac"))
        harness.player.play([cached], startAt: 0)
        await waitUntil("the cached control is adopted") { upgrades.status?.videoId == cached.videoId }
        XCTAssertEqual(search.searchedTitles, [cached.title])
    }

    /// A track that went through the resolver and is already pending is not adopted a second time,
    /// and the progress samples that go by while its look is in flight start no second job.
    func testAResolvedPendingTrackIsNotAdoptedAgainByAProgressSample() async throws {
        let harness = PlayerHarness(test: self)
        let search = FakeUpgradeSearch()
        let upgrades = controller(harness, search: search)
        let song = try harness.song("pendingOnce", seconds: 10)
        harness.resolver.markBelowRequest(song.videoId)
        search.delay = .seconds(2.5)
        search.answer(song.title, with: try losslessCopy(harness, seconds: 10, name: "pendingFlac"))

        harness.player.play([song], startAt: 0)
        await waitUntil("the resolved stream starts the second look") {
            upgrades.status?.phase == .searching && !search.searchedTitles.isEmpty
        }
        // Several checkpoints (0.5 s each) go by while the look is in flight. Each one re-offers the
        // track; none may cancel the job and start a second look.
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(search.searchedTitles, [song.title], "one look, not one per progress sample")
        await waitUntil("the upgrade swaps in", timeout: 20) {
            harness.engine.currentItem?.id.hasSuffix("#hifi") == true
        }
        XCTAssertEqual(search.searchedTitles, [song.title])
    }

    /// The upgrade's header and the bytes at the swap point are on disk before the swap, and
    /// nothing else is. The copy replaces one already playing, so it is read from the playhead
    /// onward: after its header, the swap's first read lands at the byte the position maps to.
    /// Android warms a fixed megabyte from byte zero instead, which for a swap ten seconds into a
    /// lossless track holds nothing the cut reads. The proof runs after the warm-ups and before
    /// `reopenCurrent`, so what it sees is what the swap lands on.
    func testTheHeaderAndTheSwapPointAreWarmedBeforeTheSwap() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let harness = PlayerHarness(test: self, cache: cache, session: FileRangeProtocol.session())
        let search = FakeUpgradeSearch()
        // The second look answers after the playhead is parked at 10 s.
        search.delay = .seconds(3)
        let snapshot = UpgradeWarmSnapshot()
        _ = controller(harness, search: search, prove: { song, _, tag in
            snapshot.position = harness.engine.position
            snapshot.ranges = await cache.cachedRanges(of: AudioCacheKey(trackID: song.videoId, rendition: tag))
            return 20 // the copy's real length, so the lengths agree and the swap proceeds
        })
        let song = try harness.song("swapPoint1", seconds: 20, format: .wav)
        harness.resolver.markBelowRequest(song.videoId)
        // The better copy is remote: an upgrade is fetched over HTTP in production, and the swap
        // then reads the entry back through the same session.
        let body = try TestAudio.tone(seconds: 20, format: .wav, in: harness.directory, name: "swapPointBody")
        let remote = URL(string: "http://upgrade.test/swapPointBody.wav")!
        FileRangeProtocol.serve(remote, from: body)
        search.answer(song.title, with: ResolvedStream(url: remote, origin: .addon, mimeType: "audio/wav",
                                                       format: StreamFormat(codec: "flac", sampleRateHz: 44_100, bitDepth: 16),
                                                       durationSeconds: 20, sourceConfigId: "lossless-addon"))

        harness.player.play([song], startAt: 0)
        await waitUntil("playing") { harness.engine.isPlaying }
        harness.player.seek(to: 10)
        await waitUntil("at 10 s") { harness.player.position >= 10 }
        // Paused, so the playhead is where the swap lands however long the warm-ups take.
        harness.player.pause()
        await waitUntil("the upgrade is swapped in", timeout: 30) {
            harness.engine.currentItem?.id.hasSuffix("#hifi") == true
        }

        // 16-bit stereo PCM at 44.1 kHz: 176,400 bytes a second after the header.
        let audioStart = try wavAudioStart(of: body)
        let bytesPerSecond: Int64 = 176_400
        let swapByte = audioStart + Int64(snapshot.position * Double(bytesPerSecond))
        XCTAssertGreaterThanOrEqual(snapshot.position, 10)
        XCTAssertTrue(snapshot.ranges.contains { $0.lowerBound == 0 && $0.upperBound >= audioStart },
                      "the header was on disk before the swap: \(snapshot.ranges)")
        // Twelve seconds past the playhead, or to the end of the copy if that comes first.
        let audioEnd = audioStart + 20 * bytesPerSecond
        XCTAssertTrue(snapshot.ranges.contains { $0.contains(swapByte) && $0.upperBound >= min(swapByte + 12 * bytesPerSecond, audioEnd) },
                      "twelve seconds of audio at the swap point (byte \(swapByte)) were on disk before the swap: \(snapshot.ranges)")
        let held = snapshot.ranges.reduce(Int64(0)) { $0 + ($1.upperBound - $1.lowerBound) }
        XCTAssertLessThanOrEqual(held, 256 * 1_024 + 13 * bytesPerSecond, "the header and a window, nothing else: \(snapshot.ranges)")
    }

    /// The window is warmed around the playhead as it is once the header is in: four seconds on.
    /// A slow fetch or a long proof leaves the playhead past it, and the cut would then read its
    /// first seconds off the network. So the playhead is looked at again just before the swap and
    /// the window warmed from there. The request log is read at the last look at the pin before
    /// the swap, which is after the proof and the second warm.
    func testAPlayheadThatOutrunsTheSwapWindowIsWarmedAgainBeforeTheSwap() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let harness = PlayerHarness(test: self, cache: cache, session: FileRangeProtocol.session())
        let search = FakeUpgradeSearch()
        search.delay = .seconds(3)
        let song = try harness.song("driftWarm1", seconds: 30, format: .wav)
        harness.resolver.markBelowRequest(song.videoId)
        let body = try TestAudio.tone(seconds: 30, format: .wav, in: harness.directory, name: "driftWarmBody")
        let remote = URL(string: "http://upgrade.test/driftWarmBody.wav")!
        FileRangeProtocol.serve(remote, from: body)
        let snapshot = UpgradeWarmSnapshot()
        _ = controller(harness, search: search, pinned: { _ in
            MainActor.assumeIsolated {
                if harness.factory.renditionTag(for: song) == nil { snapshot.requested = FileRangeProtocol.requests(for: remote) }
            }
            return false
        }, prove: { _, _, _ in
            // The playhead has moved well past the four seconds the window held.
            harness.player.seek(to: 20)
            await self.waitUntil("at 20 s") { harness.player.position >= 20 }
            return 30
        })
        search.answer(song.title, with: ResolvedStream(url: remote, origin: .addon, mimeType: "audio/wav",
                                                       format: StreamFormat(codec: "flac", sampleRateHz: 44_100, bitDepth: 16),
                                                       durationSeconds: 30, sourceConfigId: "lossless-addon"))

        harness.player.play([song], startAt: 0)
        await waitUntil("playing") { harness.engine.isPlaying }
        harness.player.seek(to: 10)
        await waitUntil("at 10 s") { harness.player.position >= 10 }
        harness.player.pause()
        await waitUntil("the upgrade is swapped in", timeout: 30) {
            harness.engine.currentItem?.id.hasSuffix("#hifi") == true
        }

        // 16-bit stereo PCM at 44.1 kHz: 176,400 bytes a second after the header.
        let audioStart = try wavAudioStart(of: body)
        let bytesPerSecond: Int64 = 176_400
        // The window can arrive as several requests, so each second is looked for on its own.
        for second in 20...23 {
            let byte = audioStart + Int64(second) * bytesPerSecond
            XCTAssertTrue(snapshot.requested.contains { $0.contains(byte) },
                          "the audio \(second) s in was fetched before the swap: \(snapshot.requested)")
        }
    }

    /// The swap to a better copy carries on from the point the track had reached, to within a few
    /// tens of milliseconds: nothing heard twice, nothing skipped. The playing copy is lossy
    /// and runs through the DSP tap, the better one is lossless with none, so the two decks take
    /// different times to sound once told to play. A crossover timed off an assumed start latency
    /// put the copy off the playhead by the difference (behind it on a Bluetooth route,
    /// so a moment repeated).
    func testTheSwapToABetterCopyCarriesOnFromTheSamePoint() async throws {
        let harness = PlayerHarness(test: self)
        let search = FakeUpgradeSearch()
        search.delay = .seconds(1)
        _ = controller(harness, search: search)
        let song = try harness.song("seamSwap01", seconds: 20)
        harness.resolver.markBelowRequest(song.videoId)
        search.answer(song.title, with: try losslessCopy(harness, seconds: 20, name: "seamSwapFlac"))

        harness.player.play([song], startAt: 0)
        await waitUntil("playing") { harness.engine.isPlaying }
        // The playhead less the wall clock, at every position update, until a second past the swap:
        // constant while one copy plays, and it moves by however far the swap lands off the point.
        let start = ContinuousClock.now
        var before: [Double] = []
        var after: [Double] = []
        var last = -1.0
        var swappedAt: ContinuousClock.Instant?
        while ContinuousClock.now - start < .seconds(25) {
            let swapped = harness.engine.currentItem?.id.hasSuffix("#hifi") == true
            if swapped, swappedAt == nil { swappedAt = ContinuousClock.now }
            if let swappedAt, ContinuousClock.now - swappedAt > .seconds(1) { break }
            let position = harness.engine.position
            if position != last, harness.engine.isPlaying {
                last = position
                let offset = position - (ContinuousClock.now - start) / .seconds(1)
                if swapped { after.append(offset) } else { before.append(offset) }
            }
            try await Task.sleep(for: .milliseconds(5))
        }

        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        XCTAssertNotNil(swappedAt, "the better copy swapped in")
        XCTAssertGreaterThan(before.count, 5)
        XCTAssertGreaterThan(after.count, 5)
        guard before.count > 5, after.count > 5 else { return }
        let landed = median(Array(after.dropFirst())) - median(Array(before.suffix(10)))
        XCTAssertLessThan(abs(landed), 0.06, "the swap landed \(Int(landed * 1_000)) ms off the playhead (negative: a repeat)")
    }

    /// The swap to a better copy isn't heard as a gap. The copy's server answers every
    /// request half a second late and the proof takes five seconds, so by the swap the playhead is
    /// past the window warmed for it: cutting first would leave the reads at the playhead in
    /// silence. The copy has to be buffered ahead of the playhead while the old one plays on, and
    /// the engine never stops playing across the swap.
    func testTheSwapToABetterCopyLeavesNoGap() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let harness = PlayerHarness(test: self, cache: cache, session: FileRangeProtocol.session())
        let search = FakeUpgradeSearch()
        search.delay = .seconds(1)
        _ = controller(harness, search: search, prove: { _, _, _ in
            try? await Task.sleep(for: .seconds(5))
            return 30
        })
        let song = try harness.song("gaplessSwap1", seconds: 30, format: .wav)
        harness.resolver.markBelowRequest(song.videoId)
        let body = try TestAudio.tone(seconds: 30, format: .wav, in: harness.directory, name: "gaplessSwapBody")
        let remote = URL(string: "http://upgrade.test/gaplessSwapBody.wav")!
        FileRangeProtocol.serve(remote, from: body, after: 0.5)
        search.answer(song.title, with: ResolvedStream(url: remote, origin: .addon, mimeType: "audio/wav",
                                                       format: StreamFormat(codec: "flac", sampleRateHz: 44_100, bitDepth: 16),
                                                       durationSeconds: 30, sourceConfigId: "lossless-addon"))

        harness.player.play([song], startAt: 0)
        await waitUntil("playing") { harness.engine.isPlaying }
        // Sampled every 10 ms until the better copy is the one playing: the longest the engine wasn't.
        var longest: Duration = .zero
        var silentSince: ContinuousClock.Instant?
        let deadline = ContinuousClock.now + .seconds(25)
        while !(harness.engine.currentItem?.id.hasSuffix("#hifi") == true && harness.engine.isPlaying), ContinuousClock.now < deadline {
            if harness.engine.isPlaying {
                silentSince = nil
            } else {
                let since = silentSince ?? ContinuousClock.now
                silentSince = since
                longest = max(longest, ContinuousClock.now - since)
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(harness.engine.currentItem?.id.hasSuffix("#hifi"), true, "the better copy swapped in")
        XCTAssertLessThan(longest, .milliseconds(100), "the swap was heard as a gap")
    }

    /// A proved copy waits while a crossfade is in flight: the engine's swap falls back to a
    /// cut when a blend is running, and the cut bails the blend. The swap is asked for only once the
    /// blend is over.
    func testTheSwapWaitsOutACrossfadeInFlight() async throws {
        let harness = PlayerHarness(test: self)
        let search = FakeUpgradeSearch()
        let blend = CrossfadeStandIn()
        blend.isRunning = true
        _ = controller(harness, search: search, prove: { _, _, _ in
            blend.provedAt = .now
            return 30  // the copy's real length, so the lengths agree and the swap proceeds
        }, crossfade: { blend.reading })
        let song = try harness.song("blendHold01", seconds: 30)
        harness.resolver.markBelowRequest(song.videoId)
        search.answer(song.title, with: try losslessCopy(harness, seconds: 30, name: "blendHoldFlac"))

        harness.player.play([song], startAt: 0)
        await waitUntil("the copy is proved", timeout: 15) { blend.provedAt != nil }
        try await Task.sleep(for: .seconds(3))
        XCTAssertFalse(upgradeAsked(harness), "the swap was asked for in the middle of a crossfade")

        blend.isRunning = false
        await waitUntil("the swap is asked for once the blend is over", timeout: 15) { self.upgradeAsked(harness) }
    }

    /// A blend that has just ended is given a few seconds to settle before the swap cuts into the
    /// track it handed to: the mix lands and the music doesn't stop for the swap. The hold
    /// is what is left of the grace, so a blend that ended four seconds ago holds for one more.
    func testTheSwapWaitsOutTheSettlingAfterACrossfade() async throws {
        let harness = PlayerHarness(test: self)
        let search = FakeUpgradeSearch()
        let blend = CrossfadeStandIn()
        _ = controller(harness, search: search, prove: { _, _, _ in
            // A blend ended four seconds before the proof finishes.
            blend.endedSecondsAgo(QualityUpgradeController.afterCrossfade - 1)
            blend.provedAt = .now
            return 30  // the copy's real length, so the lengths agree and the swap proceeds
        }, crossfade: { blend.reading })
        let song = try harness.song("blendHold02", seconds: 30)
        harness.resolver.markBelowRequest(song.videoId)
        search.answer(song.title, with: try losslessCopy(harness, seconds: 30, name: "blendSettleFlac"))

        harness.player.play([song], startAt: 0)
        await waitUntil("the swap is asked for", timeout: 15) { self.upgradeAsked(harness) }
        let proved = try XCTUnwrap(blend.provedAt)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - proved, .milliseconds(900), "the swap did not wait for the blend to settle")
    }

    /// A blend that starts during the hold finds the swap not made: the proved copy is shelved
    /// for the next look, not cut into the blend.
    func testACrossfadeThatBeginsDuringTheHoldShelvesTheSwap() async throws {
        let harness = PlayerHarness(test: self)
        let search = FakeUpgradeSearch()
        let blend = CrossfadeStandIn()
        let upgrades = controller(harness, search: search, prove: { _, _, _ in
            blend.endedSecondsAgo(QualityUpgradeController.afterCrossfade - 2)
            blend.provedAt = .now
            return 30  // the copy's real length, so the lengths agree and the swap proceeds
        }, crossfade: { blend.reading })
        let song = try harness.song("blendHold03", seconds: 30)
        harness.resolver.markBelowRequest(song.videoId)
        search.answer(song.title, with: try losslessCopy(harness, seconds: 30, name: "blendShelveFlac"))

        harness.player.play([song], startAt: 0)
        await waitUntil("the copy is proved", timeout: 15) { blend.provedAt != nil }
        // Inside the two-second hold, a blend begins.
        try await Task.sleep(for: .milliseconds(500))
        blend.isRunning = true
        try await Task.sleep(for: .seconds(4))
        XCTAssertFalse(upgradeAsked(harness), "the swap cut into a crossfade")
        XCTAssertNotNil(upgrades.upgrade.shelved(song.videoId), "the proved copy is kept for the next look")
    }

    /// The second look doesn't wait on a slow start: a below-request track whose copy takes
    /// seconds to open is searched for within a couple of seconds, not once it sounds or the
    /// ten-second wait for the decoder's length runs out.
    func testTheSecondLookDoesNotWaitForASlowStart() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let harness = PlayerHarness(test: self, cache: cache, session: FileRangeProtocol.session())
        let search = FakeUpgradeSearch()
        _ = controller(harness, search: search)
        let remote = URL(string: "http://slow.test/slowStart1.m4a")!
        FileRangeProtocol.serve(remote, from: try TestAudio.tone(seconds: 20, in: harness.directory, name: "slowStart1"), after: 6)
        harness.resolver.serve("slowStart1", from: remote)
        harness.resolver.markBelowRequest("slowStart1")
        let song = Song(videoId: "slowStart1", title: "Slow Start", artist: "Artist", durationText: "0:20")

        let tapped = ContinuousClock.now
        harness.player.play([song], startAt: 0)
        await waitUntil("the second look searches", timeout: 15) { !search.searchedTitles.isEmpty }
        guard !search.searchedTitles.isEmpty else { return }
        XCTAssertLessThan(ContinuousClock.now - tapped, QualityUpgradeController.decoderGrace + .seconds(2),
                          "the search waited for the slow copy to sound")
    }

    /// A row with no catalogue length is still searched when its copy is slow to open: with
    /// neither length the search can't run, so it waits for the open.
    func testTheSecondLookOfARowWithNoLengthWaitsForTheOpen() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let harness = PlayerHarness(test: self, cache: cache, session: FileRangeProtocol.session())
        let search = FakeUpgradeSearch()
        _ = controller(harness, search: search)
        let remote = URL(string: "http://slow.test/slowStart2.m4a")!
        FileRangeProtocol.serve(remote, from: try TestAudio.tone(seconds: 20, in: harness.directory, name: "slowStart2"), after: 4)
        harness.resolver.serve("slowStart2", from: remote)
        harness.resolver.markBelowRequest("slowStart2")
        let song = Song(videoId: "slowStart2", title: "No Length", artist: "Artist")

        harness.player.play([song], startAt: 0)
        await waitUntil("the second look searches", timeout: 15) { !search.searchedTitles.isEmpty }
    }

    /// A segmented copy still arriving at ``QualityUpgradeController/proveTimeout``, but arriving
    /// faster than it plays, is waited for and swapped in.
    func testASegmentedCopyArrivingFasterThanItPlaysOutlastsTheProofsDeadline() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let harness = PlayerHarness(test: self, cache: cache, session: FileRangeProtocol.session())
        let search = FakeUpgradeSearch()
        _ = controller(harness, search: search)
        let song = try harness.song("slowCopy1", seconds: 120)
        harness.resolver.markBelowRequest(song.videoId)
        // Each segment's audio (not the layout's head reads) 0.8 s late: the copy is whole at
        // about 25 s, past the proof's deadline, while arriving five times faster than it plays.
        try await answerWithSegmentedCopy(harness, search, of: song, seconds: 120) { _ in .milliseconds(800) }

        harness.player.play([song], startAt: 0)
        await waitUntil("the copy is swapped in once it has arrived", timeout: 50) {
            harness.engine.currentItem?.id.hasSuffix("#hifi") == true && harness.engine.isPlaying
        }
    }

    /// A copy arriving slower than it plays (a Dolby Atmos copy at 85 KB/s of the 96 it
    /// needs) is given up on at the proof's deadline, and isn't looked for again on its own; a
    /// press of Upgrade quality that finds it again ends the same way. The press proves the
    /// same URL into the slot the first proof part-filled, and counted as arriving, those bytes
    /// held it on "proving" for minutes.
    func testACopyArrivingSlowerThanItPlaysIsGivenUpOnAtTheProofsDeadlineAutomaticallyAndByHand() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let harness = PlayerHarness(test: self, cache: cache, session: FileRangeProtocol.session())
        let search = FakeUpgradeSearch()
        let upgrades = controller(harness, search: search, proofClock: Self.shortProof)
        let song = try harness.song("slowCopy2", seconds: 120)
        harness.resolver.markBelowRequest(song.videoId)
        // Four seconds of audio every four and a half: 0.89 of the rate it plays.
        try await answerWithSegmentedCopy(harness, search, of: song, seconds: 120) { name in name.hasPrefix("seg") ? .milliseconds(4_500) : .zero }

        harness.player.play([song], startAt: 0)
        await expectGivenUpAtTheProofsDeadline(harness, "the automatic upgrade", clock: Self.shortProof)
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(search.searchedTitles.count, 1, "a copy given up on isn't looked for again on its own")

        let playing = try XCTUnwrap(harness.player.currentSong)
        XCTAssertEqual(upgrades.requestByHand(for: playing, playing: harness.player.currentStream), .searching)
        await expectGivenUpAtTheProofsDeadline(harness, "the press", clock: Self.shortProof)
        XCTAssertEqual(search.searchedTitles.count, 2)
    }

    /// A copy whose fetch stops part-way (the connection dropped and the cache's retry never
    /// lands) is given up on once nothing has arrived for a while, not waited on for as long as
    /// what did arrive would have played.
    func testACopyThatStopsArrivingIsGivenUpOnAtTheProofsDeadline() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let harness = PlayerHarness(test: self, cache: cache, session: FileRangeProtocol.session())
        let search = FakeUpgradeSearch()
        _ = controller(harness, search: search, proofClock: Self.shortProof)
        let song = try harness.song("stuckCopy1", seconds: 120)
        harness.resolver.markBelowRequest(song.videoId)
        // The first forty seconds at once, then a segment that never comes.
        try await answerWithSegmentedCopy(harness, search, of: song, seconds: 120) { name in name == "seg10.m4s" ? .seconds(3_600) : .zero }

        harness.player.play([song], startAt: 0)
        await expectGivenUpAtTheProofsDeadline(harness, "the upgrade", clock: Self.shortProof)
    }

    /// The proof's rules on a clock a test can wait out well inside its minute: a 6 s deadline
    /// instead of 20, checks every half second, and a 5 s stall, still longer than the 4.5 s a slow
    /// copy's segments take, so a copy arriving slower than it plays is caught by that rule and not
    /// by the stall. A whole run used to wait out two real 20 s deadlines and timed out the gate.
    static let shortProof = QualityUpgradeController.ProofClock(timeout: .seconds(6), check: .milliseconds(500),
                                                                stall: .seconds(5), ceiling: .seconds(30))

    /// Waits for the copy to be proved, then for the proof to give up within its deadline (and a
    /// margin), without the copy ever being swapped in.
    private func expectGivenUpAtTheProofsDeadline(_ harness: PlayerHarness, _ what: String, clock: QualityUpgradeController.ProofClock) async {
        await waitUntil("\(what) proves its copy", timeout: 15) {
            if case .proving? = harness.player.qualityUpgrade?.phase { return true }
            return false
        }
        let proving = ContinuousClock.now
        let budget = clock.timeout + .seconds(4)
        await waitUntil("\(what) is given up on within the proof's deadline", timeout: budget / .seconds(1)) {
            harness.player.qualityUpgrade?.phase == .unavailable
        }
        XCTAssertLessThan(ContinuousClock.now - proving, budget, "\(what) stayed on proving")
        XCTAssertFalse(upgradeAsked(harness), "a copy that can't keep up is never swapped in")
    }

    /// Answers the second look for `song` with a segmented copy of it (an add-on's fMP4 playlist,
    /// through the cache), each segment's audio arriving `delay(name)` late; the layout's head
    /// reads aren't held.
    private func answerWithSegmentedCopy(_ harness: PlayerHarness, _ search: FakeUpgradeSearch, of song: Song, seconds: Double,
                                         delay: @escaping @Sendable (String) -> Duration) async throws {
        let copy = try await fragmentedHLS(of: TestAudio.tone(seconds: seconds, in: harness.directory, name: "\(song.videoId)Body"), every: 4)
        let playlist = copy.playlist
        let bodies = copy.bodies
        harness.factory.segmented = SegmentedSources(playlistText: { _, _ in playlist }, fetch: { url, _, range in
            guard let body = bodies[url.lastPathComponent] else { throw URLError(.fileDoesNotExist) }
            if (range?.count ?? .max) > SegmentedAudioSource.headBytes { try await Task.sleep(for: delay(url.lastPathComponent)) }
            let slice = (range ?? 0..<Int64(body.count)).clamped(to: 0..<Int64(body.count))
            return (body.subdata(in: Int(slice.lowerBound)..<Int(slice.upperBound)), Int64(body.count))
        })
        // Claimed as what it is: its segments are AAC, and a copy promising FLAC that decodes as AAC
        // is refused by the proof.
        search.answer(song.title, with: ResolvedStream(url: URL(string: "vibramusic-hls://playlist/\(song.videoId).m3u8")!, origin: .addon,
                                                       mimeType: "application/x-mpegURL",
                                                       format: StreamFormat(codec: "aac", kbps: 256),
                                                       durationSeconds: Int(seconds), sourceConfigId: "lossless-addon"))
    }

    /// The upgrade's cache slot is emptied before its copy is warmed, as Android's audition
    /// does. `<id>#hifi` names a slot, not a file, and the cache outlives the launch while the
    /// generation tag restarts at `hifi`: another file of the same length left there by an earlier
    /// session passes the length check and would be read as the new copy.
    func testTheUpgradeSlotIsEmptiedBeforeItsCopyIsWarmed() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let harness = PlayerHarness(test: self, cache: cache, session: FileRangeProtocol.session())
        let search = FakeUpgradeSearch()
        // The second look answers only once the slot has been seeded and the playhead parked at 10 s.
        search.hold()
        let snapshot = UpgradeWarmSnapshot()
        _ = controller(harness, search: search, prove: { _, _, _ in
            snapshot.position = harness.engine.position
            return 20
        })
        let song = try harness.song("staleSlot01", seconds: 20, format: .wav)
        harness.resolver.markBelowRequest(song.videoId)
        // Two files of one length that differ from the first second on: what an earlier session
        // left in the slot, and the copy found now.
        let stale = try Data(contentsOf: TestAudio.pattern(seconds: 20, in: harness.directory, name: "staleSlotOld"))
        let freshFile = try TestAudio.pattern(seconds: 19, leadingSilence: 1, in: harness.directory, name: "staleSlotNew")
        let fresh = try Data(contentsOf: freshFile)
        XCTAssertEqual(stale.count, fresh.count, "same length: the cache's length check cannot tell them apart")
        let remote = URL(string: "http://upgrade.test/staleSlotNew.wav")!
        FileRangeProtocol.serve(remote, from: freshFile)
        search.answer(song.title, with: ResolvedStream(url: remote, origin: .addon, mimeType: "audio/wav",
                                                       format: StreamFormat(codec: "flac", sampleRateHz: 22_050, bitDepth: 16),
                                                       durationSeconds: 20, sourceConfigId: "lossless-addon"))

        harness.player.play([song], startAt: 0)
        // The look is under way and held: the slot is seeded while it waits.
        await waitUntil("the second look searches", timeout: 15) { !search.searchedTitles.isEmpty }
        let slot = AudioCacheKey(trackID: song.videoId, rendition: "hifi")
        let seeded = await cache.cacheCompletely(slot, source: InMemoryAudioSource(data: stale, mimeType: "audio/wav"))
        XCTAssertTrue(seeded, "the earlier session's bytes are in the slot")
        await waitUntil("playing") { harness.engine.isPlaying }
        harness.player.seek(to: 10)
        await waitUntil("at 10 s") { harness.player.position >= 10 }
        // Paused, so the playhead is where the swap lands however long the warm-ups take.
        harness.player.pause()
        search.release()
        await waitUntil("the upgrade is swapped in", timeout: 30) {
            harness.engine.currentItem?.id.hasSuffix("#hifi") == true
        }

        // 16-bit mono PCM at 22.05 kHz: 44,100 bytes a second after the header.
        let swapByte = try wavAudioStart(of: freshFile) + Int64(snapshot.position * 44_100)
        let region = Int(swapByte)..<(Int(swapByte) + 4_096)
        XCTAssertNotEqual(stale.subdata(in: region), fresh.subdata(in: region), "the two files differ where the swap lands")
        let opened = await cache.reader(for: slot, requireComplete: false)
        let reader = try XCTUnwrap(opened)
        let held = await reader.read(at: swapByte, count: region.count)
        XCTAssertEqual(held, fresh.subdata(in: region), "the slot holds the copy that was swapped in, not the earlier session's file")
    }

    /// No upgrade pending, nothing warmed: the rendition entry the swap would read stays empty
    /// when the second look finds nothing better — the head warm is spent only on a copy that is
    /// about to be proven and swapped in.
    func testNothingIsWarmedWhenNoUpgradeIsPending() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let harness = PlayerHarness(test: self, cache: cache, session: FileRangeProtocol.session())
        let search = FakeUpgradeSearch() // no answer: the second look finds nothing better
        _ = controller(harness, search: search)
        let song = try harness.song("noUpgradeHead", seconds: 8)
        harness.resolver.markBelowRequest(song.videoId)

        harness.player.play([song], startAt: 0)
        await waitUntil("the second look finishes without a copy", timeout: 20) {
            harness.player.qualityUpgrade?.phase == .unavailable
        }
        try await Task.sleep(for: .milliseconds(500))

        let warmed = await cache.cachedRanges(of: AudioCacheKey(trackID: song.videoId, rendition: "hifi"))
        XCTAssertTrue(warmed.isEmpty, "nothing is warmed when no upgrade is pending: \(warmed)")
    }

    // MARK: The ceiling

    /// The listener leaves Wi-Fi (lossless) for cellular (High) while the look is searching: the
    /// look is asked again under the new ceiling, and the add-on's FLAC it finds, which High
    /// doesn't pay for, is never warmed, proved or swapped in.
    func testALoweredCeilingAsksAgainAndRefusesACopyItNoLongerPaysFor() async throws {
        let harness = PlayerHarness(test: self)
        let search = FakeUpgradeSearch()
        let network = FakeNetworkStatusProvider(.wifi)
        let ceiling = PlaybackQualityCeiling(network: network, wifi: .lossless, cellular: .high)
        let proved = AtomicFlag(false)
        let upgrades = controller(harness, search: search, ceiling: ceiling, prove: { _, _, _ in
            proved.value = true
            return 10
        })
        let song = try harness.song("ceilingLow01", seconds: 10)
        harness.resolver.markBelowRequest(song.videoId)
        search.answer(song.title, with: try losslessCopy(harness, seconds: 10, name: "ceilingLowFlac"))
        search.hold()

        harness.player.play([song], startAt: 0)
        await waitUntil("the second look searches", timeout: 15) { search.searchedTitles.count == 1 }
        network.send(.cellular)
        await waitUntil("the look is asked again under the new ceiling") { search.searchedTitles.count == 2 }
        search.release()

        await waitUntil("the upgrade ends", timeout: 15) { upgrades.status?.phase == .unavailable }
        XCTAssertFalse(proved.value, "a copy the ceiling doesn't pay for is never proved")
        XCTAssertFalse(upgradeAsked(harness))
    }

    /// A copy shelved under lossless isn't proved back in once the listener lowers the ceiling in
    /// Settings: it leaves the shelf with the change, as Android's `onCeilingLowered` drops it.
    func testALoweredCeilingLetsGoOfAShelvedCopyItNoLongerPaysFor() async throws {
        let harness = PlayerHarness(test: self)
        let search = FakeUpgradeSearch()
        let ceiling = PlaybackQualityCeiling(network: FakeNetworkStatusProvider(.wifi), wifi: .lossless, cellular: .lossless)
        let upgrades = controller(harness, search: search, ceiling: ceiling)
        let first = try harness.song("ceilingShf01", seconds: 12)
        let second = try harness.song("ceilingShf02", seconds: 12)
        harness.resolver.markBelowRequest(first.videoId)
        search.answer(first.title, with: try losslessCopy(harness, seconds: 12, name: "ceilingShelfFlac"))

        harness.player.play([first, second], startAt: 0)
        await waitUntil("the first track is upgraded", timeout: 20) { harness.engine.currentItem?.id.hasSuffix("#hifi") == true }
        XCTAssertTrue(harness.player.next())
        await waitUntil("the better copy is shelved for a return") { upgrades.upgrade.shelved(first.videoId) != nil }

        ceiling.setCeilings(wifi: .high, cellular: .high)

        await waitUntil("the shelved copy is let go") { upgrades.upgrade.shelved(first.videoId) == nil }
    }

    // MARK: The proof

    /// A copy that promises FLAC and decodes as AAC is refused by the proof: the swap would buy a
    /// break in the audio for nothing, and the badge would read "Lossless" over AAC.
    func testACopyThatPromisesLosslessAndDecodesLossyIsRefused() async throws {
        let harness = PlayerHarness(test: self)
        let search = FakeUpgradeSearch()
        let upgrades = controller(harness, search: search)
        let song = try harness.song("codecLie001", seconds: 10)
        harness.resolver.markBelowRequest(song.videoId)
        let aac = try TestAudio.tone(seconds: 10, in: harness.directory, name: "codecLieBody")
        search.answer(song.title, with: ResolvedStream(url: aac, origin: .addon, mimeType: "audio/mp4",
                                                       format: StreamFormat(codec: "flac", sampleRateHz: 44_100, bitDepth: 16),
                                                       durationSeconds: 10, sourceConfigId: "lossless-addon"))

        harness.player.play([song], startAt: 0)

        await waitUntil("the upgrade gives up", timeout: 20) { upgrades.status?.phase == .unavailable }
        XCTAssertFalse(upgradeAsked(harness), "a copy that isn't what it promised is never swapped in")
    }

    /// The swap waits for twelve seconds past the playhead on disk, as Android's audition buffers
    /// before its verdict: a copy whose server stops after its opening is let go unheard, not cut
    /// over to mid-song and stalled on.
    func testACopyWhoseSwapWindowNeverArrivesIsNotSwappedIn() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let harness = PlayerHarness(test: self, cache: cache, session: FileRangeProtocol.session())
        let search = FakeUpgradeSearch()
        let upgrades = controller(harness, search: search, prove: { _, _, _ in 30 })
        let song = try harness.song("windowGone1", seconds: 30, format: .wav)
        harness.resolver.markBelowRequest(song.videoId)
        let body = try TestAudio.tone(seconds: 30, format: .wav, in: harness.directory, name: "windowGoneBody")
        let remote = URL(string: "http://upgrade.test/windowGoneBody.wav")!
        // The header and the first second and a half; nothing past them.
        FileRangeProtocol.serve(remote, from: body, refusingPast: HTTPAudioSource.probeBytes)
        search.answer(song.title, with: ResolvedStream(url: remote, origin: .addon, mimeType: "audio/wav",
                                                       format: StreamFormat(codec: "flac", sampleRateHz: 44_100, bitDepth: 16),
                                                       durationSeconds: 30, sourceConfigId: "lossless-addon"))

        harness.player.play([song], startAt: 0)

        // Watched throughout: a copy swapped in and then put back when its reads fail ends on
        // "unavailable" too.
        let swapped = AtomicFlag(false)
        await waitUntil("the upgrade gives up", timeout: 30) {
            if self.upgradeAsked(harness) { swapped.value = true }
            return upgrades.status?.phase == .unavailable
        }
        XCTAssertFalse(swapped.value, "a copy not on disk ahead of the playhead is never swapped in")
    }

    // MARK: The end of the track, and a press

    /// Under twenty seconds left (Android's `UPGRADE_MIN_REMAINING_MS`): the copy found isn't
    /// fetched for the last seconds or swapped in over the track's end, but kept for a replay.
    func testACopyFoundTooNearTheEndIsShelvedNotSwappedIn() async throws {
        let harness = PlayerHarness(test: self)
        let search = FakeUpgradeSearch()
        let proved = AtomicFlag(false)
        let upgrades = controller(harness, search: search, minRemaining: QualityUpgradeController.minRemaining, prove: { _, _, _ in
            proved.value = true
            return 12
        })
        let song = try harness.song("nearEnd0001", seconds: 12)
        harness.resolver.markBelowRequest(song.videoId)
        search.answer(song.title, with: try losslessCopy(harness, seconds: 12, name: "nearEndFlac"))

        harness.player.play([song], startAt: 0)

        await waitUntil("the copy is kept for a replay", timeout: 15) { upgrades.upgrade.shelved(song.videoId) != nil }
        XCTAssertFalse(proved.value, "nothing is fetched for a swap that has no room")
        XCTAssertFalse(upgradeAsked(harness))
        XCTAssertNotEqual(upgrades.status?.isUpgrading, true, "the badge doesn't stay on upgrading")
    }

    /// A press of "Upgrade quality" asks the sources afresh: their completed answers are dropped
    /// before the search (Android `clearCompletedAddonTrackCalls`), so an add-on's "nothing" from a
    /// minute ago isn't served again. The automatic look keeps them.
    func testAPressAsksTheSourcesAfreshWhereTheAutomaticLookDoesNot() async throws {
        let harness = PlayerHarness(test: self)
        let search = FakeUpgradeSearch() // no answer: nothing better, both times
        let upgrades = controller(harness, search: search)
        let song = try harness.song("pressFresh1", seconds: 10)
        harness.resolver.markBelowRequest(song.videoId)

        harness.player.play([song], startAt: 0)
        await waitUntil("the automatic look finds nothing", timeout: 15) { upgrades.status?.phase == .unavailable }
        XCTAssertEqual(search.trail, ["search"], "the automatic look keeps the sources' answers")

        let playing = try XCTUnwrap(harness.player.currentSong)
        XCTAssertEqual(upgrades.requestByHand(for: playing, playing: harness.player.currentStream), .searching)

        await waitUntil("the press searches") { search.trail.count == 3 }
        XCTAssertEqual(search.trail, ["search", "clear", "search"])
    }
}

// MARK: - Starting a track

/// A source in the list. An add-on built with a `song` holds it as one lossless row streamed from
/// `url`; anything else holds nothing.
final class StubAddon: MusicSource, @unchecked Sendable {
    let configId: String
    let kind: SourceKind
    let displayName: String
    private let row: Song?
    private let url: URL?
    private let format: StreamFormat

    /// `format` is what its stream claims; a lossless WAV served as FLAC by default.
    init(_ config: SourceConfig, serving song: Song? = nil, at url: URL? = nil,
         format: StreamFormat = StreamFormat(codec: "flac", sampleRateHz: 44_100, bitDepth: 16)) {
        configId = config.id
        kind = config.kind
        displayName = config.displayName
        row = song.map { Song(videoId: "\(config.id)-1", title: $0.title, artist: $0.artist, durationText: $0.durationText, sourceQuality: .lossless) }
        self.url = url
        self.format = format
    }

    func health() async -> SourceHealth { .ok() }

    func search(_ query: String, limit: Int, waitForAll: Bool, tier: StreamRequest.Tier?) async throws -> [Song] {
        row.map { [$0] } ?? []
    }

    func stream(trackId: String, tier: StreamRequest.Tier) async throws -> ResolvedStream? {
        url.map { ResolvedStream(url: $0, origin: .addon, mimeType: format.isLossless == true ? "audio/wav" : "audio/mp4", format: format) }
    }
}

/// A lossless add-on holding `song` whose searches answer only once ``release()`` is called,
/// counting them.
final class HeldAddon: MusicSource, @unchecked Sendable {
    let configId = "lossless"
    let kind = SourceKind.addon
    let displayName = "Lossless add-on"
    private let row: Song
    private let url: URL
    private let lock = NSLock()
    private var released = false
    private var asked = 0

    init(serving song: Song, at url: URL) {
        row = Song(videoId: "lossless-1", title: song.title, artist: song.artist, durationText: song.durationText, sourceQuality: .lossless)
        self.url = url
    }

    var searches: Int { lock.withLock { asked } }
    func release() { lock.withLock { released = true } }

    func health() async -> SourceHealth { .ok() }

    func search(_ query: String, limit: Int, waitForAll: Bool, tier: StreamRequest.Tier?) async throws -> [Song] {
        lock.withLock { asked += 1 }
        // Polled, so a search the race cancels ends at once instead of holding the race open.
        while !lock.withLock({ released }) { try await Task.sleep(for: .milliseconds(20)) }
        return [row]
    }

    func stream(trackId: String, tier: StreamRequest.Tier) async throws -> ResolvedStream? {
        ResolvedStream(url: url, origin: .addon, mimeType: "audio/wav", format: StreamFormat(codec: "flac", sampleRateHz: 44_100, bitDepth: 16))
    }
}

@MainActor
final class StartRaceWiringTests: XCTestCase {
    /// A track starts on whichever copy sends audio first. The lossless add-on answers its
    /// search and stream lookup at once (as it does once read-ahead has asked), but its server takes
    /// 3 s to send a byte; YouTube's copy is ready in 300 ms. The start must not wait on the
    /// lossless server: YouTube's copy plays, marked below the request for the upgrade to replace.
    func testASlowLosslessServerDoesNotHoldTheStart() async throws {
        let song = Song(videoId: "slowLossless", title: "Slow Lossless", artist: "Some Artist", durationText: "0:20")
        let harness = try slowLosslessHarness(for: song)

        let tapped = ContinuousClock.now
        harness.player.play([song], startAt: 0)
        await waitUntil("audio starts", timeout: 15) { harness.engine.isPlaying }
        let firstAudio = ContinuousClock.now - tapped

        XCTAssertLessThan(firstAudio, .seconds(2), "the start waited on the lossless server")
        XCTAssertEqual(harness.player.currentStream?.origin, .youtube)
        XCTAssertEqual(harness.player.currentStream?.belowRequest, true, "the lossless copy is left to the upgrade")
    }

    /// Direct source stream's Queue only: a track tapped from outside the queue (search, an album,
    /// a link) starts on YouTube at once, as with the setting off, and the upgrade can bring the
    /// add-on's copy in. Always would hold YouTube's ready stream for the add-on's 3 s server.
    func testQueueOnlyStartsATappedTrackOnYouTubeWithoutWaitingForTheAddon() async throws {
        let song = Song(videoId: "tappedQueue", title: "Tapped Queue Only", artist: "Some Artist", durationText: "0:20")
        let harness = try slowLosslessHarness(for: song, request: { .playback(.lossless, directSource: .queueOnly) })
        // As the app wires it: a row opened while it is the current song is being played now.
        harness.factory.isPlaying = { [weak player = harness.player] in player?.currentSong?.videoId == $0 }

        let tapped = ContinuousClock.now
        harness.player.play([song], startAt: 0)
        await waitUntil("audio starts", timeout: 15) { harness.engine.isPlaying }
        let firstAudio = ContinuousClock.now - tapped

        XCTAssertLessThan(firstAudio, .seconds(2), "the tapped track waited on the add-on")
        XCTAssertEqual(harness.player.currentStream?.origin, .youtube)
        XCTAssertEqual(harness.player.currentStream?.belowRequest, true, "the add-on's copy is left to the upgrade")
    }

    /// YouTube wins the start while the lossless add-on is still searching: the add-on's
    /// lookup isn't cancelled but handed to the second look, which swaps its copy in once it lands,
    /// rather than searching the add-on again (Android `DirectSourceGate.startedOnYouTube`).
    func testTheLookupThatLostTheRaceIsSwappedInWithOneAddonSearch() async throws {
        let song = Song(videoId: "lostRace001", title: "Lost Race", artist: "Some Artist", durationText: "0:20")
        let directory = makeTemporaryDirectory(self)
        let youTube = FakeStreamResolver()
        youTube.serve(song.videoId, from: try TestAudio.tone(seconds: 20, in: directory, name: "lostRaceYouTube"), origin: .youtube)
        let addon = HeldAddon(serving: song, at: try TestAudio.tone(seconds: 20, format: .wav, in: directory, name: "lostRaceFlac"))
        let registry = SourceRegistry(
            store: nil,
            environment: SourceEnvironment(session: VibraMusicHTTP.session, dolbyAtmosEnabled: { false }, youTubeStreams: youTube),
            factory: { config, _ in config.kind == .addon ? addon as MusicSource : StubAddon(config) }
        )
        registry.add(SourceConfig(id: "lossless", kind: .addon, label: "Lossless add-on", baseUrl: "https://addon.test", enabled: true))
        let resolver = SourceResolver(registry: registry)
        let harness = PlayerHarness(test: self, streams: resolver)
        let stats = NerdStats()
        let search = SourceUpgradeSearch(resolver: resolver, registry: registry, request: { .playback(.lossless) })
        let upgrades = QualityUpgradeController(
            upgrade: QualityUpgrade(search: search, requestForNow: { .playback(.lossless) }, streamChoice: StreamChoice(), nerdStats: stats),
            search: search, nerdStats: stats, settings: harness.settings, isPinned: { _ in false }, minRemaining: 0
        )
        harness.player.qualityUpgrades = upgrades

        harness.player.play([song], startAt: 0)
        await waitUntil("YouTube's copy plays while the add-on searches", timeout: 15) {
            harness.engine.isPlaying && upgrades.status?.phase == QualityUpgradeStatus.Phase.searching
        }
        XCTAssertEqual(harness.player.currentStream?.origin, .youtube)
        XCTAssertEqual(addon.searches, 1)

        // The add-on answers once YouTube's copy is playing, as a slow one does seconds after.
        addon.release()

        await waitUntil("the add-on's copy is swapped in", timeout: 20) {
            harness.engine.currentItem?.id.hasSuffix("#hifi") == true && harness.engine.isPlaying
        }
        XCTAssertEqual(harness.player.currentStream?.format.codec, "flac")
        XCTAssertEqual(addon.searches, 1, "the second look took the race's lookup instead of searching the add-on again")
    }

    /// A row played whole off the disk is adopted with a floor measured off the decoder or the
    /// entry (YouTube's Opus at about 130 kbps). The sources' search weighs a lossy copy against
    /// that floor too: it used to be asked against none, which nothing lossy clears, so a cached
    /// row could only ever be upgraded to lossless.
    func testACachedRowsSecondLookWeighsALossyCopyAgainstItsMeasuredFloor() async throws {
        let song = Song(videoId: "cachedFloor1", title: "Cached Floor", artist: "Some Artist", durationText: "0:20")
        let copy = try TestAudio.tone(seconds: 20, in: makeTemporaryDirectory(self), name: "cachedFloor320")
        let registry = SourceRegistry(
            store: nil,
            environment: SourceEnvironment(session: VibraMusicHTTP.session, dolbyAtmosEnabled: { false }, youTubeStreams: FakeStreamResolver()),
            factory: { config, _ in
                config.kind == .addon ? StubAddon(config, serving: song, at: copy, format: StreamFormat(codec: "aac", kbps: 320)) : StubAddon(config)
            }
        )
        registry.add(SourceConfig(id: "lossy", kind: .addon, label: "Lossy add-on", baseUrl: "https://addon.test", enabled: true))
        let search = SourceUpgradeSearch(resolver: SourceResolver(registry: registry), registry: registry, request: { .playback(.lossless) })
        let upgrade = QualityUpgrade(search: search, requestForNow: { .playback(.lossless) }, streamChoice: StreamChoice(), nerdStats: NerdStats())
        let adopted = upgrade.adoptUnresolved(song.videoId, uri: PlaybackURI.forStreaming(song, pinnedToOriginal: false),
                                              target: QualityUpgrade.Target(song: song), playingMime: "audio/webm", playing: StreamFormat(kbps: 130))
        XCTAssertTrue(adopted)

        let found = await upgrade.lookAgain(song.videoId, playingDurationSec: 20)

        XCTAssertEqual(found?.format.kbps, 320, "a 320 kbps copy clears a 130 kbps floor")
        XCTAssertEqual(found?.sourceConfigId, "lossy")
    }

    /// A player over the real SourceResolver, with one lossless add-on that has `song` and answers
    /// its search and stream lookup at once, but whose server takes 3 s to send a byte. YouTube's
    /// copy is ready in 300 ms.
    private func slowLosslessHarness(
        for song: Song,
        request: @escaping @Sendable () -> StreamRequest = { .playback(.lossless) }
    ) throws -> PlayerHarness {
        let directory = makeTemporaryDirectory(self)
        let cache = try makeTestCache(in: directory)
        let youTube = FakeStreamResolver()
        youTube.serve(song.videoId, from: try TestAudio.tone(seconds: 20, in: directory, name: "\(song.videoId)YouTube"), origin: .youtube)
        youTube.delay(song.videoId, by: .milliseconds(300))
        let remote = URL(string: "http://lossless.test/\(song.videoId).wav")!
        FileRangeProtocol.serve(remote, from: try TestAudio.tone(seconds: 20, format: .wav, in: directory, name: "\(song.videoId)Flac"), after: 3)
        let session = FileRangeProtocol.session()
        let registry = SourceRegistry(
            store: nil,
            environment: SourceEnvironment(session: session, dolbyAtmosEnabled: { false }, youTubeStreams: youTube),
            factory: { config, _ in config.kind == .addon ? StubAddon(config, serving: song, at: remote) : StubAddon(config) }
        )
        registry.add(SourceConfig(id: "lossless", kind: .addon, label: "Lossless add-on", baseUrl: "https://addon.test", enabled: true))
        return PlayerHarness(test: self, cache: cache, session: session, request: request, streams: SourceResolver(registry: registry))
    }
}

// MARK: - Listen Together

@MainActor
final class ListenTogetherWiringTests: XCTestCase {
    private func partyState(code: String = "ABC123", hostOnly: Bool = true, youAreHost: Bool = false) -> PartySessionState {
        let host = PartyMember(memberId: "m-host", displayName: "Host", isHost: true, connected: true)
        let you = PartyMember(memberId: "m-you", displayName: "You", isHost: youAreHost, connected: true)
        var playback = PartyPlayback()
        playback.autoplayEnabled = false
        let items = [
            PartyTrack(videoId: "partyTrack0", title: "Zero", artist: "A", durationMs: 200_000),
            PartyTrack(videoId: "partyTrack1", title: "One", artist: "B", durationMs: 180_000),
            PartyTrack(videoId: "partyTrack2", title: "Two", artist: "C", durationMs: 190_000, fromAutoplay: true),
        ]
        return PartySessionState(code: code, you: you, members: [host, you], hostOnlyControl: hostOnly, playback: playback,
                                 queue: PartyQueue(seq: 3, index: 0, items: items), connection: .live)
    }

    func testPartyStateReachesTheQueueContext() {
        let context = ListenTogetherSession.context(from: partyState())

        XCTAssertEqual(context.code, "ABC123")
        XCTAssertEqual(context.yourMemberId, "m-you")
        XCTAssertEqual(context.members.map(\.memberId), ["m-host", "m-you"])
        XCTAssertEqual(context.members.first?.isHost, true)
        XCTAssertFalse(context.partyAutoplayEnabled, "the party's AutoPlay switch, not this phone's")
        XCTAssertTrue(context.hostOnlyControl)
        XCTAssertTrue(context.controlsLocked, "a listener in a locked party")
        XCTAssertEqual(context.upcomingTracks.map(\.videoId), ["partyTrack1", "partyTrack2"], "the party's queue after its current track")
        XCTAssertEqual(context.upcomingTracks.map(\.queueTier), [.userQueue, .autoplay])
        XCTAssertEqual(AutoplayPolicy.supplierId(party: context), "m-host")

        XCTAssertFalse(ListenTogetherSession.context(from: partyState(youAreHost: true)).controlsLocked, "the host is never locked out")
        XCTAssertEqual(ListenTogetherSession.context(from: PartySessionState()), .solo)
    }

    func testJoiningAndLeavingStartsAndStopsTheSyncAndGivesTheQueueBack() async throws {
        let stash = PartyPersonalQueueStash(store: JSONFileStore(directory: makeTemporaryDirectory(self)))
        let harness = PlayerHarness(test: self, partyStash: stash)
        let songs = try (1...2).map { try harness.song("personal000\($0)") }
        harness.player.play(songs, startAt: 1)
        await waitUntil("playing") { harness.engine.isPlaying }
        let client = PartyClient(store: PartyServerStore(files: JSONFileStore(directory: makeTemporaryDirectory(self)), defaultServer: "http://127.0.0.1:9"))
        let sync = PartySyncCoordinator(client: client, bridge: PartyPlaybackBridge(player: harness.player),
                                        stash: PartyQueueStashAdapter(queue: harness.queue))
        let session = ListenTogetherSession(client: client, sync: sync, player: harness.player)

        await session.apply(partyState())

        XCTAssertTrue(session.isSyncing, "the sync coordinator starts on joining")
        XCTAssertEqual(harness.queue.party.code, "ABC123", "the party reaches the queue")
        XCTAssertTrue(harness.player.controlsLocked)
        XCTAssertTrue(harness.player.isInParty)
        XCTAssertTrue(harness.engine.transitionsSuspended, "every device changes track together: no crossfades")
        XCTAssertNotNil(stash.load(), "the personal queue is put aside")
        XCTAssertFalse(harness.player.next(), "a locked listener can't skip")

        // The party's queue replaces this device's while in it.
        harness.queue.setItems([Song(videoId: "partyTrack0", title: "Zero", artist: "A")], startIndex: 0, playback: .pause)

        await session.apply(PartySessionState())

        XCTAssertFalse(session.isSyncing, "the sync coordinator stops on leaving")
        XCTAssertEqual(harness.queue.party, .solo)
        XCTAssertFalse(harness.player.isInParty)
        XCTAssertFalse(harness.engine.transitionsSuspended)
        XCTAssertEqual(harness.player.songs.map(\.videoId), songs.map(\.videoId), "the personal queue comes back")
        XCTAssertEqual(harness.player.currentSong?.videoId, songs[1].videoId, "on the track it was on")
        XCTAssertNil(stash.load())
    }

    func testAPartyLeftWhileItWasStillBeingJoinedEndsSolo() async throws {
        // A kick (or the party closing) right behind the join: the leave must not be overtaken by
        // the join's own start of the sync.
        let stash = PartyPersonalQueueStash(store: JSONFileStore(directory: makeTemporaryDirectory(self)))
        let harness = PlayerHarness(test: self, partyStash: stash)
        let songs = try (1...2).map { try harness.song("kickedSong\($0)") }
        harness.player.play(songs, startAt: 0)
        await waitUntil("playing") { harness.engine.isPlaying }
        let client = PartyClient(store: PartyServerStore(files: JSONFileStore(directory: makeTemporaryDirectory(self)), defaultServer: "http://127.0.0.1:9"))
        let session = ListenTogetherSession(client: client, sync: PartySyncCoordinator(client: client, bridge: PartyPlaybackBridge(player: harness.player),
                                                                                       stash: PartyQueueStashAdapter(queue: harness.queue)),
                                            player: harness.player)

        let join = Task { await session.apply(partyState()) }
        let leave = Task { await session.apply(PartySessionState()) }
        await join.value
        await leave.value

        XCTAssertFalse(session.isSyncing, "the sync is stopped, not restarted by the join finishing late")
        XCTAssertEqual(harness.queue.party, .solo)
        XCTAssertFalse(harness.player.isInParty)
        XCTAssertFalse(harness.engine.transitionsSuspended)
        XCTAssertEqual(harness.player.songs.map(\.videoId), songs.map(\.videoId), "the personal queue is still there")
    }

    func testAPartyMemberWhoStartedTheTrackIsNamed() async throws {
        let harness = PlayerHarness(test: self)
        let song = try harness.song("partyTrack0")
        harness.player.play([song], startAt: 0)
        let client = PartyClient(store: PartyServerStore(files: JSONFileStore(directory: makeTemporaryDirectory(self)), defaultServer: "http://127.0.0.1:9"))
        let session = ListenTogetherSession(client: client, sync: PartySyncCoordinator(client: client, bridge: PartyPlaybackBridge(player: harness.player)),
                                            player: harness.player)
        var state = partyState(hostOnly: false)
        state.playback.track = PartyTrack(videoId: song.videoId, title: song.title)
        state.playback.startedBy = "m-host"
        state.playback.startedByName = "Host"
        await session.apply(state)

        XCTAssertEqual(harness.player.playedBy?(song), "Host")
        await session.apply(PartySessionState())
        XCTAssertNil(harness.player.playedBy?(song))
    }
}

/// Blocks the calling thread: work that never checks for cancellation (a decode, an AVFoundation
/// load). Synchronous so the async test can call it without Swift 6's sleep-in-async warning.
private func blockThread(seconds: TimeInterval) {
    Thread.sleep(forTimeInterval: seconds)
}

// MARK: - Read-ahead

/// Answers the audio cache's range reads for a local file, so read-ahead can be driven in a test
/// with no network. `HTTPAudioSource` fetches through `URLSession`, which won't open a `file://`
/// URL unless a protocol class claims it.
final class FileRangeProtocol: URLProtocol, @unchecked Sendable {
    /// Local files standing behind `http` URLs: an upgrade rendition is remote in production and
    /// the cache only warms it over HTTP, so its stub must be a URL the cache will fetch rather
    /// than a file it would never cache.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var remoteFiles: [String: URL] = [:]
    nonisolated(unsafe) private static var delays: [String: TimeInterval] = [:]
    nonisolated(unsafe) private static var refusals: [String: Int64] = [:]
    nonisolated(unsafe) private static var requested: [String: [Range<Int64>]] = [:]
    private let stateLock = NSLock()
    private var stopped = false

    /// Answers range requests to `url` with the bytes of `file`, each answer `after` seconds late:
    /// a server slow to its first byte. A range reaching past `refusingPast` is answered 500: a
    /// server that sends the opening and then fails.
    static func serve(_ url: URL, from file: URL, after delay: TimeInterval = 0, refusingPast cut: Int64? = nil) {
        lock.withLock {
            remoteFiles[url.absoluteString] = file
            delays[url.absoluteString] = delay
            refusals[url.absoluteString] = cut
        }
    }

    /// The byte ranges asked of `url` so far, in order.
    static func requests(for url: URL) -> [Range<Int64>] {
        lock.withLock { requested[url.absoluteString] ?? [] }
    }

    /// The local file `serve(_:from:)` registered for `url`, if any.
    private static func file(behind url: URL) -> URL? {
        guard url.scheme == "http" || url.scheme == "https" else { return nil }
        return lock.withLock { remoteFiles[url.absoluteString] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return url.isFileURL || file(behind: url) != nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let delay = request.url.map { url in Self.lock.withLock { Self.delays[url.absoluteString] ?? 0 } } ?? 0
        guard delay > 0 else { return answer() }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stateLock.withLock({ self.stopped }) else { return }
            self.answer()
        }
    }

    private func answer() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let file = url.isFileURL ? url : Self.file(behind: url)
        guard let file, let data = try? Data(contentsOf: file) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let total = Int64(data.count)
        let range = request.value(forHTTPHeaderField: "Range").flatMap(Self.parseRange)
        if let range { Self.lock.withLock { Self.requested[url.absoluteString, default: []].append(range) } }
        if let cut = Self.lock.withLock({ Self.refusals[url.absoluteString] }), min(range?.upperBound ?? total, total) > cut {
            if let refused = HTTPURLResponse(url: url, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"]) {
                client?.urlProtocol(self, didReceive: refused, cacheStoragePolicy: .notAllowed)
            }
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        var headers: [String: String] = ["Accept-Ranges": "bytes", "Content-Type": "audio/mp4"]
        let status: Int
        let body: Data
        if let range {
            let lower = min(range.lowerBound, total)
            let upper = min(range.upperBound, total)
            body = data.subdata(in: Int(lower)..<Int(upper))
            status = 206
            headers["Content-Range"] = "bytes \(lower)-\(max(lower, upper - 1))/\(total)"
        } else {
            body = data
            status = 200
        }
        headers["Content-Length"] = String(body.count)
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        stateLock.withLock { stopped = true }
    }

    /// A session that routes the cache's range reads through this protocol.
    static func session() -> URLSession {
        let configuration = VibraMusicHTTP.makeConfiguration()
        configuration.protocolClasses = [FileRangeProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func parseRange(_ header: String) -> Range<Int64>? {
        guard header.hasPrefix("bytes=") else { return nil }
        let parts = header.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int64(parts[0]) else { return nil }
        if parts[1].isEmpty { return start..<Int64.max }
        guard let end = Int64(parts[1]) else { return nil }
        return start..<(end + 1)
    }
}

/// The queue hands the cache the tracks ahead of the one playing, the cache fetches the next one
/// whole, and a reorder or a stop moves the target. Exercised through the real
/// `PlayerController`, a real `AudioStreamCache` and a resolver whose only source is local bytes.
@MainActor
final class ReadAheadWiringTests: XCTestCase {
    private func makeHarness(cache: AudioStreamCache) -> PlayerHarness {
        PlayerHarness(test: self, cache: cache, session: FileRangeProtocol.session(), canSubstitute: { _ in false })
    }

    private func waitForFullCache(_ cache: AudioStreamCache, _ key: AudioCacheKey, timeout: TimeInterval = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await cache.isFullyCached(key) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await cache.isFullyCached(key)
    }

    /// The tracks ahead get YouTube's URL warmed, as Android's `prefetchQueue` does, and no add-on
    /// is searched or asked for a stream of a track that may never play. Whether a source
    /// outranks YouTube decides if the next track's bytes are read, not who is asked to warm.
    func testReadAheadWarmsYouTubesURLAndAsksNoAddonForTheTracksAhead() async throws {
        for substitutable in [true, false] {
            let addons = FakeStreamResolver()
            let youTube = FakeStreamResolver()
            let ids = ["warmAhead01", "warmAhead02"]
            for id in ids { youTube.serve(id, from: URL(string: "https://rr.test/\(id).m4a")!, origin: .youtube) }
            let cache = try makeTestCache(in: makeTemporaryDirectory(self))
            let factory = PlaybackSourceFactory(resolver: addons, youTube: youTube, cache: cache, facts: StreamFactsBook(),
                                                request: { .playback(.lossless) }, atmosAllowed: { true })
            factory.isPinnedToOriginal = { _ in false }
            factory.canSubstitute = { _ in substitutable }
            let songs = ids.map { Song(videoId: $0, title: "Title \($0)", artist: "Artist", durationText: "3:00") }

            let items = factory.prefetchItems(for: songs)
            XCTAssertEqual(items.count, 2)
            for item in items { try await item.warmUp?() }

            XCTAssertEqual(youTube.requestedIds, ids, "YouTube's URL is warmed (substitutable: \(substitutable))")
            XCTAssertEqual(addons.requestedIds, [], "no add-on is asked (substitutable: \(substitutable))")
        }
    }

    /// Read-ahead asks the add-ons (the whole race, waiting for them) only with Direct source
    /// stream's Queue only; Off warms YouTube's URL alone. Always reads
    /// nothing ahead: the track's own open asks the add-ons, so a YouTube URL would go unused, and
    /// Android switches ordinary read-ahead off in Direct mode.
    func testReadAheadAsksTheAddonsOnlyInQueueOnly() async throws {
        for mode in DirectSourceStream.allCases {
            let addons = FakeStreamResolver()
            let youTube = FakeStreamResolver()
            let id = "askAhead\(mode.rawValue)"
            addons.serve(id, from: URL(string: "https://addon.test/\(id).flac")!)
            youTube.serve(id, from: URL(string: "https://rr.test/\(id).m4a")!, origin: .youtube)
            let cache = try makeTestCache(in: makeTemporaryDirectory(self))
            let factory = PlaybackSourceFactory(resolver: addons, youTube: youTube, cache: cache, facts: StreamFactsBook(),
                                                request: { .playback(.lossless, directSource: mode) }, atmosAllowed: { true })
            factory.isPinnedToOriginal = { _ in false }

            for item in factory.prefetchItems(for: [Song(videoId: id, title: "Title", artist: "Artist", durationText: "3:00")]) {
                try await item.warmUp?()
            }

            if mode == .queueOnly {
                XCTAssertEqual(addons.requestedIds, [id], "the add-ons are asked")
                XCTAssertEqual(addons.requests.first?.request.waitsForSources, true, "the race waits for them")
                XCTAssertEqual(youTube.requestedIds, [])
            } else if mode == .always {
                XCTAssertEqual(addons.requestedIds, [], "no add-on is asked ahead (\(mode))")
                XCTAssertEqual(youTube.requestedIds, [], "nor YouTube (\(mode))")
            } else {
                XCTAssertEqual(addons.requestedIds, [], "no add-on is asked (\(mode))")
                XCTAssertEqual(youTube.requestedIds, [id], "YouTube's URL is warmed (\(mode))")
            }
        }
    }

    /// Queue only: a track whose add-on stream read-ahead found starts on that stream, from its
    /// first second and with nothing resolved again, so the upgrade has nothing to swap. A reopen
    /// (a skip onto the preloaded row) plays the same stream; a retry after it died resolves afresh,
    /// without waiting for the add-ons.
    func testAReadAheadTrackPlaysTheAddonStreamReadAheadFound() async throws {
        let addons = FakeStreamResolver()
        let song = Song(videoId: "foundAhead1", title: "Found Ahead", artist: "Artist", durationText: "3:00")
        let found = URL(string: "https://addon.test/foundAhead1.flac")!
        addons.serve(song.videoId, from: found, format: StreamFormat(codec: "flac"))
        let facts = StreamFactsBook()
        let factory = PlaybackSourceFactory(resolver: addons, youTube: nil, cache: try makeTestCache(in: makeTemporaryDirectory(self)),
                                            facts: facts, request: { .playback(.lossless, directSource: .queueOnly) }, atmosAllowed: { true })
        factory.isPinnedToOriginal = { _ in false }
        factory.isPlaying = { $0 == song.videoId }
        for item in factory.prefetchItems(for: [song]) { try await item.warmUp?() }
        XCTAssertEqual(addons.requestedIds, [song.videoId], "read-ahead found the add-on's stream")

        let item = factory.item(for: song)
        guard case .resolvedAsset(let open) = item.source else { return XCTFail("a streamed row opens an asset") }
        for _ in 0..<2 {
            _ = try await open()
            let played = facts.stream(for: PlaybackSourceFactory.itemID(for: song))
            XCTAssertEqual(played?.origin, .addon)
            XCTAssertEqual(played?.url, found)
            XCTAssertEqual(played?.belowRequest, false, "nothing for the upgrade to replace")
        }
        XCTAssertEqual(addons.requestedIds, [song.videoId], "the track started without resolving again")

        let retried = await factory.recoveredSource(for: item, reason: .retry(attempt: 1))
        guard case .resolvedAsset(let reopen)? = retried else {
            return XCTFail("a retried stream reopens an asset")
        }
        _ = try await reopen()
        XCTAssertEqual(addons.requestedIds, [song.videoId, song.videoId], "a retry resolves afresh")
        XCTAssertEqual(addons.requests.last?.request.waitsForSources, false, "and doesn't wait for the add-ons")
    }

    /// The engine opens the next row while the current one plays, for a gapless advance. In Queue
    /// only that open is read-ahead too: it waits for the add-ons, and keeps what they answer for a
    /// skip onto the row. Off doesn't wait.
    func testQueueOnlyOpensTheNextRowWaitingForTheAddons() async throws {
        for mode in [DirectSourceStream.off, .queueOnly] {
            let addons = FakeStreamResolver()
            let song = Song(videoId: "openAhead\(mode.rawValue)", title: "Open Ahead", artist: "Artist", durationText: "3:00")
            addons.serve(song.videoId, from: URL(string: "https://addon.test/\(song.videoId).flac")!)
            let factory = PlaybackSourceFactory(resolver: addons, youTube: nil, cache: try makeTestCache(in: makeTemporaryDirectory(self)),
                                                facts: StreamFactsBook(), request: { .playback(.lossless, directSource: mode) }, atmosAllowed: { true })
            factory.isPinnedToOriginal = { _ in false }
            var playing: String?
            factory.isPlaying = { $0 == playing }

            guard case .resolvedAsset(let open) = factory.item(for: song).source else { return XCTFail("a streamed row opens an asset") }
            _ = try await open()
            XCTAssertEqual(addons.requests.last?.request.waitsForSources, mode == .queueOnly, "\(mode)")

            playing = song.videoId
            _ = try await open()
            XCTAssertEqual(addons.requestedIds.count, mode == .queueOnly ? 1 : 2, "a skip onto the row reuses its stream only in Queue only")
        }
    }

    /// Queue only: a row opened ahead of time waits for the ranked sources as long as nobody is
    /// listening. Once the queue reaches it (a skip, an advance) it keeps waiting until
    /// `lookupJoinWait` after its lookup started, then starts without their copy.
    func testQueueOnlyGivesAPlayingRowItsLookUntilTheJoinWaitThenStarts() async throws {
        let resolver = AddonWaitResolver()
        let song = Song(videoId: "aheadThenPlaying", title: "Ahead Then Playing", artist: "Artist", durationText: "3:00")
        let factory = queueOnlyFactory(resolver)
        factory.lookupJoinWait = .seconds(1.5)
        var playing: String?
        factory.isPlaying = { $0 == playing }
        guard case .resolvedAsset(let open) = factory.item(for: song).source else { return XCTFail("a streamed row opens an asset") }

        let started = ContinuousClock.now
        let opening = Task { _ = try await open() }
        await waitUntil("the row is opened ahead, waiting for its sources") { resolver.requests.count == 1 }
        XCTAssertEqual(resolver.requests.first?.waitsForSources, true)
        // Not yet playing: the open keeps waiting, and asks nothing else.
        try await Task.sleep(for: .milliseconds(1_000))
        XCTAssertEqual(resolver.requests.count, 1, "a row that isn't playing yet waits for its sources")
        playing = song.videoId
        try await opening.value
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .seconds(1.4), "a playing row still gets the rest of the join wait")
        // Counted from the lookup's start (about 1.5 s in), not from when the row began playing
        // (which would be 2.5 s or later).
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2.2), "and no more")
        XCTAssertEqual(resolver.requests.last?.waitsForSources, false, "then starts as a tapped row does")

        resolver.answerSources()
        await waitUntil("the waited-for answer is kept") { factory.readAheadStreams.stream(for: song.videoId, request: Self.queueOnly, atmosAllowed: true) != nil }
    }

    /// A skip onto a row whose look ahead is still running joins it, and starts on the sources'
    /// copy when it lands inside the join wait: never YouTube first and a swap after.
    func testQueueOnlyASkipOntoARowJoinsItsLookAndStartsOnTheSourcesCopy() async throws {
        let resolver = AddonWaitResolver()
        let song = Song(videoId: "skipJoins", title: "Skip Joins", artist: "Artist", durationText: "3:00")
        let factory = queueOnlyFactory(resolver)
        factory.lookupJoinWait = .seconds(10)
        var playing: String?
        factory.isPlaying = { $0 == playing }
        let items = factory.prefetchItems(for: [song])
        let warming = Task { try await items.first?.warmUp?() }
        await waitUntil("the look ahead is running") { resolver.requests.count == 1 }

        playing = song.videoId
        guard case .resolvedAsset(let open) = factory.item(for: song).source else { return XCTFail("a streamed row opens an asset") }
        let opening = Task { _ = try await open() }
        try await Task.sleep(for: .milliseconds(300))
        resolver.answerSources()
        try await opening.value
        warming.cancel()
        XCTAssertEqual(resolver.requests.count, 1, "the skip joined the look ahead instead of starting a race of its own")
        XCTAssertEqual(factory.facts.stream(for: factory.engineItemID(for: song))?.origin, .addon, "it starts on the sources' copy")
    }

    /// A look ahead outlives the read-ahead that started it (replaced on every queue edit, AutoPlay
    /// appending most often), and once it lands the track's opening is put on disk.
    func testALookAheadOutlivesItsReadAheadAndPutsTheOpeningOnDisk() async throws {
        let directory = makeTemporaryDirectory(self)
        let cache = try makeTestCache(in: directory)
        let file = try TestAudio.tone(seconds: 20, format: .wav, in: directory, name: "aheadOpening")
        let remote = URL(string: "http://addon.test/aheadOpening.wav")!
        FileRangeProtocol.serve(remote, from: file)
        let resolver = AddonWaitResolver(addonURL: remote)
        let song = Song(videoId: "aheadOpening", title: "Ahead Opening", artist: "Artist", durationText: "0:20")
        let factory = PlaybackSourceFactory(resolver: resolver, youTube: nil, cache: cache, facts: StreamFactsBook(), session: FileRangeProtocol.session(),
                                            request: { Self.queueOnly }, atmosAllowed: { true })
        factory.isPinnedToOriginal = { _ in false }

        let first = Task { try await factory.prefetchItems(for: [song]).first?.warmUp?() }
        await waitUntil("the look ahead is running") { resolver.requests.count == 1 }
        first.cancel()
        resolver.answerSources()
        await waitUntil("its answer is kept though the read-ahead was cancelled") {
            factory.readAheadStreams.stream(for: song.videoId, request: Self.queueOnly, atmosAllowed: true) != nil
        }

        // Only the cancelled read-ahead's lookup can put it there: nothing else asks for this track.
        let key = AudioCacheKey.substitute(videoId: song.videoId, atmosAllowed: true)
        var head = Data()
        for _ in 0..<100 where head.count < 4_096 {
            if let reader = await cache.reader(for: key, requireComplete: false) { head = await reader.read(at: 0, count: 4_096) }
            if head.count < 4_096 { try await Task.sleep(for: .milliseconds(100)) }
        }
        XCTAssertEqual(head, try Data(contentsOf: file).prefix(4_096), "the track's opening is on disk")
        XCTAssertEqual(resolver.requests.count, 1, "from the one lookup")
    }

    /// The engine's early open of the next row can start its lookup before read-ahead does; the
    /// read-ahead joining it still gets the track's opening onto disk.
    func testAReadAheadJoiningTheOpensLookupStillPutsTheOpeningOnDisk() async throws {
        let directory = makeTemporaryDirectory(self)
        let cache = try makeTestCache(in: directory)
        let file = try TestAudio.tone(seconds: 20, format: .wav, in: directory, name: "joinedOpening")
        let remote = URL(string: "http://addon.test/joinedOpening.wav")!
        FileRangeProtocol.serve(remote, from: file)
        let resolver = AddonWaitResolver(addonURL: remote)
        let song = Song(videoId: "joinedOpening", title: "Joined Opening", artist: "Artist", durationText: "0:20")
        let factory = PlaybackSourceFactory(resolver: resolver, youTube: nil, cache: cache, facts: StreamFactsBook(), session: FileRangeProtocol.session(),
                                            request: { Self.queueOnly }, atmosAllowed: { true })
        factory.isPinnedToOriginal = { _ in false }
        factory.isPlaying = { _ in false }
        guard case .resolvedAsset(let open) = factory.item(for: song).source else { return XCTFail("a streamed row opens an asset") }

        let opening = Task { _ = try await open() }
        await waitUntil("the early open's lookup is running") { resolver.requests.count == 1 }
        let warming = Task { try await factory.prefetchItems(for: [song]).first?.warmUp?() }
        try await Task.sleep(for: .milliseconds(200))
        resolver.answerSources()
        try await opening.value
        _ = try await warming.value

        let key = AudioCacheKey.substitute(videoId: song.videoId, atmosAllowed: true)
        var head = Data()
        for _ in 0..<100 where head.count < 4_096 {
            if let reader = await cache.reader(for: key, requireComplete: false) { head = await reader.read(at: 0, count: 4_096) }
            if head.count < 4_096 { try await Task.sleep(for: .milliseconds(100)) }
        }
        XCTAssertEqual(head, try Data(contentsOf: file).prefix(4_096), "the joined lookup warmed the opening")
        XCTAssertEqual(resolver.requests.count, 1, "one lookup between them")
    }

    /// Queue only: once its look ahead lands, the next track's add-on copy goes onto disk whole,
    /// under the key the open reads, so a skip onto it starts from disk. The track after it gets
    /// only its opening.
    func testQueueOnlyPutsTheNextTracksCopyWholeOnDiskAndOnlyTheOpeningOfTheOneAfter() async throws {
        let (factory, cache, resolver, file) = try queueOnlyFactoryServingAFile("wholeAhead")
        let next = Song(videoId: "wholeNext", title: "Whole Next", artist: "Artist", durationText: "0:20")
        let after = Song(videoId: "openingAfter", title: "Opening After", artist: "Artist", durationText: "0:20")

        await cache.prefetch(factory.prefetchItems(for: [next, after]))
        await waitUntil("both look aheads are running") { resolver.requests.count == 2 }
        resolver.answerSources()

        let nextKey = AudioCacheKey.substitute(videoId: next.videoId, atmosAllowed: true)
        let whole = await waitForFullCache(cache, nextKey)
        XCTAssertTrue(whole, "the next track's copy is whole on disk")
        let reader = await cache.reader(for: nextKey, requireComplete: true)
        let bytes = try Data(contentsOf: file)
        let onDisk = await reader?.read(at: 0, count: bytes.count)
        XCTAssertEqual(onDisk, bytes, "and it is the add-on's file")

        let afterKey = AudioCacheKey.substitute(videoId: after.videoId, atmosAllowed: true)
        let opening = await waitForBytes(cache, afterKey, atLeast: PlaybackSourceFactory.openingBytes)
        XCTAssertEqual(opening, PlaybackSourceFactory.openingBytes, "the track after it has its opening")
        try await Task.sleep(for: .milliseconds(500))
        let held = await heldBytes(cache, afterKey)
        XCTAssertEqual(held, PlaybackSourceFactory.openingBytes, "and only its opening")
        XCTAssertEqual(resolver.requests.count, 2, "one lookup each")
        await cache.cancelPrefetch()
    }

    /// The queue moving on (a skip, a reorder) stops the whole-copy fetch: a track that is no
    /// longer next keeps only its opening, and the new next track is the one fetched whole.
    func testQueueOnlyRetargetingStopsTheWholeCopyFetch() async throws {
        let (factory, cache, resolver, _) = try queueOnlyFactoryServingAFile("retargetWhole")
        let first = Song(videoId: "wasNext", title: "Was Next", artist: "Artist", durationText: "0:20")
        let second = Song(videoId: "nowNext", title: "Now Next", artist: "Artist", durationText: "0:20")

        await cache.prefetch(factory.prefetchItems(for: [first, second]))
        await waitUntil("both look aheads are running") { resolver.requests.count == 2 }
        // Read-ahead retargets while the first track's whole-copy fetch waits on its look ahead.
        await cache.prefetch(factory.prefetchItems(for: [second]))
        resolver.answerSources()

        let secondKey = AudioCacheKey.substitute(videoId: second.videoId, atmosAllowed: true)
        let whole = await waitForFullCache(cache, secondKey)
        XCTAssertTrue(whole, "the new next track is fetched whole")
        let firstKey = AudioCacheKey.substitute(videoId: first.videoId, atmosAllowed: true)
        let opening = await waitForBytes(cache, firstKey, atLeast: PlaybackSourceFactory.openingBytes)
        XCTAssertEqual(opening, PlaybackSourceFactory.openingBytes, "the track that was next still has its opening")
        try await Task.sleep(for: .milliseconds(500))
        let held = await heldBytes(cache, firstKey)
        XCTAssertEqual(held, PlaybackSourceFactory.openingBytes, "and nothing past it: its whole-copy fetch stopped")
        await cache.cancelPrefetch()
    }

    /// On a metered connection (cellular, Low Data Mode) the next track's add-on copy isn't fetched
    /// whole: by design it gets its opening, like the tracks after it.
    func testQueueOnlyOnAMeteredConnectionPutsOnlyTheNextTracksOpeningOnDisk() async throws {
        let (factory, cache, resolver, _) = try queueOnlyFactoryServingAFile("meteredNext")
        factory.isUnmetered = { false }
        let next = Song(videoId: "meteredNext", title: "Metered Next", artist: "Artist", durationText: "0:20")

        await cache.prefetch(factory.prefetchItems(for: [next]))
        await waitUntil("the look ahead is running") { resolver.requests.count == 1 }
        resolver.answerSources()

        let key = AudioCacheKey.substitute(videoId: next.videoId, atmosAllowed: true)
        let opening = await waitForBytes(cache, key, atLeast: PlaybackSourceFactory.openingBytes)
        XCTAssertEqual(opening, PlaybackSourceFactory.openingBytes, "the next track has its opening")
        try await Task.sleep(for: .milliseconds(500))
        let held = await heldBytes(cache, key)
        XCTAssertEqual(held, PlaybackSourceFactory.openingBytes, "and only its opening")
        await cache.cancelPrefetch()
    }

    /// Nothing is looked up for a track ahead until the playing one sounds: on a weak link its
    /// start has the connection to itself. Queue only still looks the next track up as a song
    /// starts, a moment later, and the engine's early open shares that lookup.
    func testALookAheadWaitsUntilThePlayingTrackSounds() async throws {
        let addons = FakeStreamResolver()
        let song = Song(videoId: "holdAhead01", title: "Hold Ahead", artist: "Artist", durationText: "3:00")
        addons.serve(song.videoId, from: URL(string: "https://addon.test/holdAhead01.flac")!, format: StreamFormat(codec: "flac"))
        let factory = queueOnlyFactory(addons)
        var sounding = false
        factory.isSounding = { sounding }

        let warming = Task { try await factory.prefetchItems(for: [song]).first?.warmUp?() }
        guard case .resolvedAsset(let open) = factory.item(for: song).source else { return XCTFail("a streamed row opens an asset") }
        let opening = Task { _ = try await open() }
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(addons.requestedIds, [], "nothing is asked before the playing track sounds")

        sounding = true
        try await opening.value
        _ = try await warming.value
        XCTAssertEqual(addons.requestedIds, [song.videoId], "then one lookup, shared by read-ahead and the open")
    }

    /// The engine's early open of the next row asks after its wait for the playing track's start,
    /// by when read-ahead's look ahead may have landed already. It takes that answer: the add-on is
    /// asked once, whichever of the two asks second.
    func testAnEarlyOpenTakesTheAnswerOfALookAheadThatLandedWhileItWaited() async throws {
        let addons = FakeStreamResolver()
        let song = Song(videoId: "landedAhead1", title: "Landed Ahead", artist: "Artist", durationText: "3:00")
        addons.serve(song.videoId, from: URL(string: "https://addon.test/landedAhead1.flac")!, format: StreamFormat(codec: "flac"))
        let factory = queueOnlyFactory(addons)
        var sounding = false
        var waiting = false
        factory.isSounding = { waiting = true; return sounding }

        guard case .resolvedAsset(let open) = factory.item(for: song).source else { return XCTFail("a streamed row opens an asset") }
        let opening = Task { _ = try await open() }
        await waitUntil("the open waits for the playing track to sound") { waiting }

        // Read-ahead's own wait has run out: its look ahead asks and lands while the open still waits.
        factory.soundingWait = .zero
        try await factory.prefetchItems(for: [song]).first?.warmUp?()
        XCTAssertEqual(addons.requestedIds, [song.videoId], "read-ahead's look ahead asked")

        sounding = true
        try await opening.value
        XCTAssertEqual(addons.requestedIds, [song.videoId], "the open took its answer rather than asking again")
        XCTAssertEqual(factory.facts.stream(for: factory.engineItemID(for: song))?.origin, .addon, "and starts on the add-on's copy")
    }

    /// Off: YouTube's tracks ahead wait for the playing one to sound too, the next track's first
    /// bytes and the URL warm-ups after it alike. Read-ahead's own 2 s grace alone let the next
    /// track's opening compete with a start still struggling on a weak link (Android waits
    /// 8 s before reading ahead).
    func testOffReadAheadWaitsUntilThePlayingTrackSounds() async throws {
        let youTube = FakeStreamResolver()
        let songs = ["offHold01", "offHold02"].map { Song(videoId: $0, title: "Title \($0)", artist: "Artist", durationText: "3:00") }
        for song in songs { youTube.serve(song.videoId, from: URL(string: "https://rr.test/\(song.videoId).m4a")!, origin: .youtube) }
        let cache = try makeTestCache(in: makeTemporaryDirectory(self), prefetchDelay: .zero)
        let factory = PlaybackSourceFactory(resolver: youTube, youTube: youTube, cache: cache, facts: StreamFactsBook(),
                                            request: { .playback(.lossless) }, atmosAllowed: { true })
        factory.isPinnedToOriginal = { _ in false }
        factory.canSubstitute = { _ in false }
        var sounding = false
        factory.isSounding = { sounding }

        await cache.prefetch(factory.prefetchItems(for: songs))
        try await Task.sleep(for: .milliseconds(1_000))
        XCTAssertEqual(youTube.requestedIds, [], "nothing is resolved before the playing track sounds")

        sounding = true
        await waitUntil("then the next track's bytes and the one after's URL") { Set(youTube.requestedIds) == Set(songs.map(\.videoId)) }
        await cache.cancelPrefetch()
    }

    /// The wait for the playing track's start isn't counted against a skip's join: a row reached
    /// after a slow start still gets `lookupJoinWait` from when its lookup began asking.
    func testTheWaitForThePlayingTracksStartIsNotChargedToASkipsJoin() async throws {
        let resolver = AddonWaitResolver()
        let song = Song(videoId: "slowStartJoin", title: "Slow Start Join", artist: "Artist", durationText: "3:00")
        let factory = queueOnlyFactory(resolver)
        factory.lookupJoinWait = .seconds(1)
        var sounding = false
        factory.isSounding = { sounding }
        var playing: String?
        factory.isPlaying = { $0 == playing }

        let warming = Task { try await factory.prefetchItems(for: [song]).first?.warmUp?() }
        // Longer than the join wait before the playing track sounds.
        try await Task.sleep(for: .milliseconds(1_500))
        XCTAssertEqual(resolver.requests.count, 0)
        sounding = true
        await waitUntil("the look ahead starts asking") { resolver.requests.count == 1 }

        playing = song.videoId
        guard case .resolvedAsset(let open) = factory.item(for: song).source else { return XCTFail("a streamed row opens an asset") }
        let opening = Task { _ = try await open() }
        try await Task.sleep(for: .milliseconds(300))
        resolver.answerSources()
        try await opening.value
        warming.cancel()
        XCTAssertEqual(resolver.requests.count, 1, "the skip joined the look ahead")
        XCTAssertEqual(factory.facts.stream(for: factory.engineItemID(for: song))?.origin, .addon, "and starts on the sources' copy")
    }

    /// A copy the look ahead found counts as expired past its freshness, and the byte source the
    /// track opens on finds it again, from the same source, before reading from it: a long track
    /// can outlive an add-on's URL before it hands over.
    func testACopyFoundAheadIsFoundAgainOnceStaleBeforeItIsRead() async throws {
        let directory = makeTemporaryDirectory(self)
        let cache = try makeTestCache(in: directory)
        let file = try TestAudio.tone(seconds: 5, in: directory, name: "refound")
        let live = URL(string: "http://addon.test/refound.m4a")!
        FileRangeProtocol.serve(live, from: file)
        // As good as expired (inside the margin a fetch needs), as a long track's hand-over finds it.
        let stale = ResolvedStream(url: URL(string: "http://addon.test/stale.m4a")!, origin: .addon, mimeType: "audio/mp4",
                                   expiresAt: Date().addingTimeInterval(30), sourceConfigId: "addon1")
        let resolver = SequenceResolver([stale, ResolvedStream(url: live, origin: .addon, mimeType: "audio/mp4", sourceConfigId: "addon1")])
        let factory = PlaybackSourceFactory(resolver: resolver, youTube: nil, cache: cache, facts: StreamFactsBook(), session: FileRangeProtocol.session(),
                                            request: { Self.queueOnly }, atmosAllowed: { true })
        factory.isPinnedToOriginal = { _ in false }
        let song = Song(videoId: "refound01", title: "Refound", artist: "Artist", durationText: "0:05")

        guard case .resolvedAsset(let open) = factory.item(for: song).source else { return XCTFail("a streamed row opens an asset") }
        let asset = try await open().asset
        _ = try? await asset.load(.duration)

        await waitUntil("the copy is read from where it was found again") { !FileRangeProtocol.requests(for: live).isEmpty }
        XCTAssertEqual(resolver.requests.count, 2, "found ahead, then found again before the first read")
        XCTAssertEqual(resolver.requests.last?.waitsForSources, true, "from the ranked sources")
        XCTAssertEqual(resolver.requests.last?.readsAheadFromSources, false, "at play-time limits")
    }

    /// A lookup's copy counts as expired once past its freshness, even when its URL doesn't say.
    func testALookAheadsCopyExpiresWithItsFreshness() async throws {
        let streams = ReadAheadStreams()
        let flac = ResolvedStream(url: URL(string: "https://addon.test/fresh.flac")!, origin: .addon, format: StreamFormat(codec: "flac"))
        let found = try await streams.lookUp("freshAhead", request: Self.queueOnly, atmosAllowed: true) { flac }.task.value
        let expiry = try XCTUnwrap(found.expiresAt)
        XCTAssertEqual(expiry.timeIntervalSinceNow, ReadAheadStreams.freshness, accuracy: 5)
    }

    /// Queue only: a row reached after the copy found for it went stale looks again and joins that
    /// lookup, rather than starting on YouTube.
    func testQueueOnlyARowWhoseFoundCopyWentStaleLooksAgain() async throws {
        let addons = FakeStreamResolver()
        let song = Song(videoId: "staleAhead01", title: "Stale Ahead", artist: "Artist", durationText: "3:00")
        addons.serve(song.videoId, from: URL(string: "https://addon.test/staleAhead01.flac")!, format: StreamFormat(codec: "flac"))
        let factory = queueOnlyFactory(addons)
        factory.isPlaying = { $0 == song.videoId }
        let old = ResolvedStream(url: URL(string: "https://addon.test/old.flac")!, origin: .addon, format: StreamFormat(codec: "flac"),
                                 expiresAt: Date().addingTimeInterval(30))
        factory.readAheadStreams.put(old, for: song.videoId, request: Self.queueOnly, atmosAllowed: true)
        XCTAssertTrue(factory.readAheadStreams.wentStale(song.videoId, request: Self.queueOnly, atmosAllowed: true))

        guard case .resolvedAsset(let open) = factory.item(for: song).source else { return XCTFail("a streamed row opens an asset") }
        _ = try await open()
        XCTAssertEqual(addons.requests.first?.request.waitsForSources, true, "it looked again, waiting for the sources")
        XCTAssertEqual(factory.facts.stream(for: factory.engineItemID(for: song))?.url, URL(string: "https://addon.test/staleAhead01.flac")!,
                       "and starts on what they found, not the stale copy")
    }

    /// Always: a track whose only whole copy on disk is YouTube's asks the ranked sources first and
    /// starts on their copy, rather than playing YouTube's off the disk and swapping mid-song
    /// (Android's `settleDirectEntry`). Off still plays it from disk, and so does a row that fell
    /// back to YouTube after its copy above YouTube broke.
    func testAlwaysAsksTheSourcesBeforePlayingYouTubesCopyFromDisk() async throws {
        let cases: [(mode: DirectSourceStream, refused: Bool)] = [(.always, false), (.off, false), (.always, true)]
        for (mode, refused) in cases {
            let cache = try makeTestCache(in: makeTemporaryDirectory(self))
            let song = Song(videoId: "diskYT\(mode.rawValue)\(refused)", title: "Disk YouTube", artist: "Artist", durationText: "3:00")
            let filled = await cache.cacheCompletely(.youtube(videoId: song.videoId),
                                                     source: InMemoryAudioSource(data: Data(repeating: 7, count: 200_000), mimeType: "audio/mp4"))
            XCTAssertTrue(filled)
            let addons = FakeStreamResolver()
            addons.serve(song.videoId, from: URL(string: "https://addon.test/\(song.videoId).flac")!, format: StreamFormat(codec: "flac"))
            let factory = PlaybackSourceFactory(resolver: addons, youTube: FakeStreamResolver(), cache: cache, facts: StreamFactsBook(),
                                                request: { .playback(.lossless, directSource: mode) }, atmosAllowed: { true })
            factory.isPinnedToOriginal = { _ in false }
            factory.streamChoice = StreamChoice()
            if refused { factory.streamChoice.refuseSubstitutes(for: song.videoId) }

            guard case .resolvedAsset(let open) = factory.item(for: song).source else { return XCTFail("a streamed row opens an asset") }
            _ = try await open()
            let asksFirst = mode == .always && !refused
            XCTAssertEqual(addons.requestedIds, asksFirst ? [song.videoId] : [], "\(mode), refused: \(refused)")
            XCTAssertEqual(factory.playingFromCache(for: song.videoId), !asksFirst, "\(mode), refused: \(refused)")
            if asksFirst {
                XCTAssertEqual(factory.facts.stream(for: factory.engineItemID(for: song))?.origin, .addon, "it starts on the add-on's copy")
            }
        }
    }

    /// A song played from the Offline backup page starts on the copy on this device under Always,
    /// with no add-on asked first: on a slow link it sat buffering though every byte was on disk.
    func testAlwaysPlaysASongFromTheOfflineBackupPageOffTheDisk() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        var song = Song(videoId: "backupYT01", title: "Backup", artist: "Artist", durationText: "3:00")
        song.playbackSourceId = LocalBrowseID.offlineBackup
        let filled = await cache.cacheCompletely(.youtube(videoId: song.videoId),
                                                 source: InMemoryAudioSource(data: Data(repeating: 7, count: 200_000), mimeType: "audio/mp4"))
        XCTAssertTrue(filled)
        let addons = FakeStreamResolver()
        addons.serve(song.videoId, from: URL(string: "https://addon.test/\(song.videoId).flac")!, format: StreamFormat(codec: "flac"))
        let factory = PlaybackSourceFactory(resolver: addons, youTube: FakeStreamResolver(), cache: cache, facts: StreamFactsBook(),
                                            request: { .playback(.lossless, directSource: .always) }, atmosAllowed: { true })
        factory.isPinnedToOriginal = { _ in false }
        factory.streamChoice = StreamChoice()

        guard case .resolvedAsset(let open) = factory.item(for: song).source else { return XCTFail("a streamed row opens an asset") }
        _ = try await open()
        XCTAssertEqual(addons.requestedIds, [], "no add-on is asked before it starts")
        XCTAssertTrue(factory.playingFromCache(for: song.videoId), "it plays the copy on disk")
    }

    /// A row that resolved to an add-on's copy and later plays YouTube's whole off the disk drops
    /// what that resolve recorded: a retry of the disk copy isn't counted as dying above YouTube,
    /// and the row's next item isn't declared as the add-on's FLAC.
    func testAWholeCopyOffTheDiskDropsTheFactsOfAnEarlierResolve() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let song = Song(videoId: "staleFacts01", title: "Stale Facts", artist: "Artist", durationText: "3:00")
        let addons = FakeStreamResolver()
        addons.serve(song.videoId, from: URL(string: "https://addon.test/staleFacts01.flac")!, format: StreamFormat(codec: "flac"))
        let factory = PlaybackSourceFactory(resolver: addons, youTube: FakeStreamResolver(), cache: cache, facts: StreamFactsBook(),
                                            request: { .playback(.lossless) }, atmosAllowed: { true })
        factory.isPinnedToOriginal = { _ in false }
        factory.streamChoice = StreamChoice()
        guard case .resolvedAsset(let resolve) = factory.item(for: song).source else { return XCTFail("a streamed row opens an asset") }
        _ = try await resolve()
        XCTAssertEqual(factory.facts.stream(for: factory.engineItemID(for: song))?.origin, .addon, "the first play resolved the add-on's copy")

        let filled = await cache.cacheCompletely(.youtube(videoId: song.videoId),
                                                 source: InMemoryAudioSource(data: Data(repeating: 7, count: 200_000), mimeType: "audio/mp4"))
        XCTAssertTrue(filled)
        let item = factory.item(for: song)
        guard case .resolvedAsset(let open) = item.source else { return XCTFail("a streamed row opens an asset") }
        _ = try await open()
        XCTAssertTrue(factory.playingFromCache(for: song.videoId), "the replay plays YouTube's copy off the disk")

        XCTAssertFalse(factory.diedAboveYouTube(item), "its retry stays on YouTube's copy")
        XCTAssertNil(factory.item(for: song).declaredFormat, "nothing claims the add-on's FLAC is playing")
    }

    /// A row whose last resolve was an add-on's Atmos mix is built declaring it, before its open
    /// finds YouTube's copy whole on disk and plays that. The engine goes by what the open played:
    /// the AAC goes through the DSP chain rather than past it as Atmos, and the stats describe it,
    /// not the mix.
    func testARowReplayedFromYouTubesCopyOnDiskIsProcessedAfterAnAtmosResolve() async throws {
        let directory = makeTemporaryDirectory(self)
        let cache = try makeTestCache(in: directory)
        let song = Song(videoId: "atmosReplay01", title: "Atmos Replay", artist: "Artist", durationText: "0:06")
        let addons = FakeStreamResolver()
        addons.serve(song.videoId, from: URL(string: "https://addon.test/atmosReplay01.ec3")!,
                     format: StreamFormat(codec: "eac3-joc", kbps: 768, channels: 6))
        let facts = StreamFactsBook()
        let factory = PlaybackSourceFactory(resolver: addons, youTube: FakeStreamResolver(), cache: cache, facts: facts,
                                            request: { .playback(.lossless) }, atmosAllowed: { true })
        factory.isPinnedToOriginal = { _ in false }
        factory.streamChoice = StreamChoice()
        guard case .resolvedAsset(let resolve) = factory.item(for: song).source else { return XCTFail("a streamed row opens an asset") }
        _ = try await resolve()
        let filled = await cache.fillFullyCachedYouTube(song.videoId, from: try TestAudio.tone(seconds: 6, in: directory, name: "atmosReplay01"))
        XCTAssertTrue(filled)
        let item = factory.item(for: song)
        XCTAssertEqual(item.declaredFormat?.isDolbyAtmos, true, "the item still carries the last resolve's claim")

        let processors = [AudioDSPProcessor(facts: facts), AudioDSPProcessor(facts: facts)]
        let engine = AudioPlayerEngine(configuration: AudioPlayerEngine.Configuration(
            audioProcessorFactory: { deck in processors[deck == .a ? 0 : 1] },
            integratesWithSystem: false,
            scansAheadForSilence: false,
            positionUpdateInterval: 0.05,
            sampleInterval: 0.5
        ))
        addTeardownBlock { @MainActor in engine.shutdown() }
        engine.load(item, playWhenReady: true)
        await waitUntil("the replay opens") { engine.signalPath != nil }
        XCTAssertTrue(factory.playingFromCache(for: song.videoId), "the replay plays YouTube's copy off the disk")
        XCTAssertEqual(engine.signalPath, .processed, "with the DSP chain on, not passed through as Atmos")

        await waitUntil("stats") { engine.stats?.itemID == item.id && engine.stats?.codec != nil }
        XCTAssertEqual(engine.stats?.codec, "aac", "the stats describe YouTube's copy")
        XCTAssertNil(engine.stats?.declared, "and nothing claims the Atmos mix")
    }

    /// The same replay through the player: the row becomes current with its last resolve's add-on
    /// stream on record, and only then does its open pick YouTube's copy off the disk. The stats and
    /// the pipeline's Source name YouTube, and the add-on's 96 kHz FLAC claim doesn't call YouTube's
    /// AAC downgraded.
    func testTheStatsNameYouTubeForARowReplayedFromItsCopyOnDisk() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let store = JSONFileStore(directory: makeTemporaryDirectory(self))
        // What the app keeps across launches: the restart snapshot, and each row's last resolve.
        let facts = StreamFactsBook()
        let song: Song
        do {
            // Not lossless: the add-on's copy this play leaves on disk would be picked over YouTube's.
            let first = PlayerHarness(test: self, lastPlayed: LastPlayedStore(store: store), cache: cache,
                                      request: { .playback(.high) }, facts: facts)
            song = try first.song("diskSource01", seconds: 8, streamFormat: StreamFormat(codec: "flac", sampleRateHz: 96_000, bitDepth: 24))
            first.player.play([song])
            await waitUntil("the add-on's stream is current") { first.player.currentStream?.origin == .addon }
            first.player.flushPersistence()
            first.engine.shutdown()
            let filled = await cache.fillFullyCachedYouTube(song.videoId, from: first.directory.appending(path: "diskSource01.m4a"))
            XCTAssertTrue(filled)
        }

        // Relaunched: the same row comes back and opens again, now off the disk.
        let harness = PlayerHarness(test: self, lastPlayed: LastPlayedStore(store: store), cache: cache,
                                    request: { .playback(.high) }, facts: facts)
        XCTAssertTrue(harness.player.restore())
        harness.player.play()
        await waitUntil("the replay is measured") {
            harness.player.sources.playingFromCache(for: song.videoId)
                && harness.player.stats?.itemID == PlayerQuality.playingItemID(harness.player) && harness.player.stats?.codec != nil
        }
        let snapshot = try XCTUnwrap(PlayerQuality.snapshot(player: harness.player))
        XCTAssertEqual(snapshot.sourceName, "YouTube", "the Source row names YouTube, not the add-on")
        XCTAssertNil(snapshot.claimed, "nothing claims the add-on's FLAC")
        XCTAssertFalse(snapshot.downgraded)
    }

    /// Off with a quick source (JioSaavn) ranked above YouTube: the engine's early open of the next
    /// row asks it first and starts on its copy, and read-ahead puts that same copy on disk whole,
    /// under the key the open reads (Android's `prefetchQueue` with `prefetchSubstitute`). One
    /// question between them, and no race.
    func testOffPutsTheQuickSourcesCopyOfTheNextTrackWholeOnDiskAndStartsOnIt() async throws {
        let (factory, cache, racer, quick, file) = try offFactoryWithAQuickCopy("quickNext")
        let song = Song(videoId: "quickNext01", title: "Quick Next", artist: "Artist", durationText: "0:20")
        quick.release()

        guard case .resolvedAsset(let open) = factory.item(for: song).source else { return XCTFail("a streamed row opens an asset") }
        _ = try await open()
        await cache.prefetch(factory.prefetchItems(for: [song]))

        let key = AudioCacheKey.substitute(videoId: song.videoId, atmosAllowed: true)
        let whole = await waitForFullCache(cache, key)
        XCTAssertTrue(whole, "the next track's quick copy is whole on disk")
        let bytes = try Data(contentsOf: file)
        let reader = await cache.reader(for: key, requireComplete: true)
        let onDisk = await reader?.read(at: 0, count: bytes.count)
        XCTAssertEqual(onDisk, bytes, "and it is that copy")
        XCTAssertEqual(factory.facts.stream(for: factory.engineItemID(for: song))?.origin, .jioSaavn, "the row starts on it")
        XCTAssertEqual(quick.asked, [song.videoId], "asked once between them")
        XCTAssertEqual(racer.requestedIds, [], "and nothing raced")
        await cache.cancelPrefetch()
    }

    /// Off: a row reached before its quick copy answers races as before, and the late answer is let
    /// go of, so nothing is fetched under the key the race's copy fills.
    func testOffARowReachedBeforeItsQuickCopyAnswersRacesAndKeepsNothing() async throws {
        let (factory, cache, racer, quick, _) = try offFactoryWithAQuickCopy("quickLate")
        let song = Song(videoId: "quickLate01", title: "Quick Late", artist: "Artist", durationText: "0:20")
        racer.serve(song.videoId, from: URL(string: "https://rr.test/quickLate01.m4a")!, origin: .youtube)
        var playing: String?
        factory.isPlaying = { $0 == playing }

        guard case .resolvedAsset(let open) = factory.item(for: song).source else { return XCTFail("a streamed row opens an asset") }
        let opening = Task { _ = try await open() }
        await waitUntil("the quick source is asked") { quick.asked.count == 1 }
        playing = song.videoId
        try await opening.value
        XCTAssertEqual(racer.requestedIds, [song.videoId], "the reached row races, as Off does")

        quick.release()
        await cache.prefetch(factory.prefetchItems(for: [song]))
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertNil(factory.readAheadStreams.stream(for: song.videoId, request: .playback(.lossless), atmosAllowed: true), "the late answer isn't kept")
        let held = await heldBytes(cache, .substitute(videoId: song.videoId, atmosAllowed: true))
        XCTAssertEqual(held, 0, "and nothing is fetched under the sources' key")
        await cache.cancelPrefetch()
    }

    /// An Off factory whose quick source answers every track with one 20 s WAV served over HTTP,
    /// once ``QuickCopyStub/release()`` is called, and whose race answers nothing unless told.
    private func offFactoryWithAQuickCopy(_ name: String) throws -> (PlaybackSourceFactory, AudioStreamCache, FakeStreamResolver, QuickCopyStub, URL) {
        let directory = makeTemporaryDirectory(self)
        let cache = try makeTestCache(in: directory, prefetchDelay: .zero)
        let file = try TestAudio.tone(seconds: 20, format: .wav, in: directory, name: name)
        let remote = URL(string: "http://saavn.test/\(name).wav")!
        FileRangeProtocol.serve(remote, from: file)
        let racer = FakeStreamResolver()
        let factory = PlaybackSourceFactory(resolver: racer, youTube: nil, cache: cache, facts: StreamFactsBook(), session: FileRangeProtocol.session(),
                                            request: { .playback(.lossless) }, atmosAllowed: { true })
        factory.isPinnedToOriginal = { _ in false }
        // JioSaavn's AAC on a lossless request comes back below it; Off would start on it anyway.
        let quick = QuickCopyStub(ResolvedStream(url: remote, origin: .jioSaavn, mimeType: "audio/wav", belowRequest: true, sourceConfigId: "saavn"))
        factory.quickCopy = { song, _ in try await quick.answer(song) }
        return (factory, cache, racer, quick, file)
    }

    /// A Queue only factory whose add-on answers every track with one 20 s WAV (about 3.5 MB, past
    /// the opening), served over HTTP so the cache fetches it, with no read-ahead delay.
    private func queueOnlyFactoryServingAFile(_ name: String) throws -> (PlaybackSourceFactory, AudioStreamCache, AddonWaitResolver, URL) {
        let directory = makeTemporaryDirectory(self)
        let cache = try makeTestCache(in: directory, prefetchDelay: .zero)
        let file = try TestAudio.tone(seconds: 20, format: .wav, in: directory, name: name)
        let remote = URL(string: "http://addon.test/\(name).wav")!
        FileRangeProtocol.serve(remote, from: file)
        let resolver = AddonWaitResolver(addonURL: remote)
        let factory = PlaybackSourceFactory(resolver: resolver, youTube: nil, cache: cache, facts: StreamFactsBook(), session: FileRangeProtocol.session(),
                                            request: { Self.queueOnly }, atmosAllowed: { true })
        factory.isPinnedToOriginal = { _ in false }
        factory.isUnmetered = { true }
        return (factory, cache, resolver, file)
    }

    private func heldBytes(_ cache: AudioStreamCache, _ key: AudioCacheKey) async -> Int64 {
        await cache.cachedRanges(of: key).reduce(Int64(0)) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    private func waitForBytes(_ cache: AudioStreamCache, _ key: AudioCacheKey, atLeast bytes: Int64, timeout: TimeInterval = 15) async -> Int64 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let held = await heldBytes(cache, key)
            if held >= bytes { return held }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await heldBytes(cache, key)
    }

    private static let queueOnly = StreamRequest.playback(.lossless, directSource: .queueOnly)

    private func queueOnlyFactory(_ resolver: StreamResolving) -> PlaybackSourceFactory {
        let factory = PlaybackSourceFactory(resolver: resolver, youTube: nil, cache: try? makeTestCache(in: makeTemporaryDirectory(self)),
                                            facts: StreamFactsBook(), request: { Self.queueOnly }, atmosAllowed: { true })
        factory.isPinnedToOriginal = { _ in false }
        return factory
    }

    /// A track ahead keeps a source's answer, never YouTube's stand-in taken while the sources were
    /// still looking: kept, the track would start on YouTube, which is what Queue only is there to
    /// avoid (in one log the add-on's FLAC came 2 s after the look ahead settled for AAC).
    func testReadAheadKeepsASourcesAnswerButNotYouTubesStandIn() {
        let streams = ReadAheadStreams()
        let request = StreamRequest.playback(.lossless, directSource: .queueOnly)
        let standIn = ResolvedStream(url: URL(string: "https://youtube.test/a.m4a")!, origin: .youtube, belowRequest: true)
        streams.put(standIn, for: "aheadKeep", request: request, atmosAllowed: true)
        XCTAssertNil(streams.stream(for: "aheadKeep", request: request, atmosAllowed: true))

        let flac = ResolvedStream(url: URL(string: "https://addon.test/a.flac")!, origin: .addon, format: StreamFormat(codec: "flac"))
        streams.put(flac, for: "aheadKeep", request: request, atmosAllowed: true)
        XCTAssertEqual(streams.stream(for: "aheadKeep", request: request, atmosAllowed: true)?.url, flac.url)
        streams.put(standIn, for: "aheadKeep", request: request, atmosAllowed: true)
        XCTAssertEqual(streams.stream(for: "aheadKeep", request: request, atmosAllowed: true)?.url, flac.url, "a later stand-in leaves the source's answer standing")
    }

    func testTheNextTrackReadsAheadIntoTheCacheWithoutStarting() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self), prefetchDelay: .zero)
        let harness = makeHarness(cache: cache)
        let first = try harness.song("readAhead01", seconds: 30, origin: .youtube)
        let next = try harness.song("readAhead02", seconds: 30, origin: .youtube)

        harness.player.play([first, next], startAt: 0)
        await waitUntil("the current track is loaded and told to play", timeout: 30) {
            harness.engine.currentItem?.song?.videoId == first.videoId && harness.engine.playWhenReady
        }

        let cached = await waitForFullCache(cache, .youtube(videoId: next.videoId))
        XCTAssertTrue(cached, "the next track is fetched whole while the current one plays")
        XCTAssertEqual(harness.player.currentSong?.videoId, first.videoId, "the next track never started")
        XCTAssertEqual(harness.player.currentIndex, 0)
        XCTAssertEqual(harness.engine.currentItem?.song?.videoId, first.videoId)
    }

    func testReorderingTheQueueRetargetsTheReadAhead() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self), prefetchDelay: .zero)
        let harness = makeHarness(cache: cache)
        let first = try harness.song("retarget01", seconds: 30, origin: .youtube)
        let second = try harness.song("retarget02", seconds: 30, origin: .youtube)
        let third = try harness.song("retarget03", seconds: 30, origin: .youtube)

        harness.player.play([first, second, third], startAt: 0)
        await waitUntil("the current track is loaded and told to play", timeout: 30) {
            harness.engine.currentItem?.song?.videoId == first.videoId && harness.engine.playWhenReady
        }
        let secondCached = await waitForFullCache(cache, .youtube(videoId: second.videoId))
        XCTAssertTrue(secondCached, "the next track is read ahead first")

        _ = harness.player.move(from: 2, to: 1)

        XCTAssertEqual(harness.player.songs.map(\.videoId), [first.videoId, third.videoId, second.videoId])
        let thirdCached = await waitForFullCache(cache, .youtube(videoId: third.videoId))
        XCTAssertTrue(thirdCached, "the read-ahead followed the reorder to the new next track")
    }

    func testStoppingPlaybackCancelsTheReadAhead() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self), prefetchDelay: .zero)
        let harness = makeHarness(cache: cache)
        let first = try harness.song("stopCancel1", seconds: 8, origin: .youtube)
        let next = try harness.song("stopCancel2", seconds: 8, origin: .youtube)
        // Hold every resolve of the next track open, so the read-ahead is genuinely in flight when
        // playback stops. Releasing it afterwards proves the stop, not a lost race, is what stopped
        // the fetch.
        let gate = harness.resolver.gate(next.videoId)

        harness.player.play([first, next], startAt: 0)
        await waitUntil("the next track is being resolved", timeout: 30) {
            harness.resolver.requestedIds.contains(next.videoId)
        }
        // A turn for the read-ahead's own resolve to reach the gate too (the engine's preload may
        // have been the first caller).
        try await Task.sleep(for: .milliseconds(300))

        harness.queue.setItems([], startIndex: 0, playback: .pause)
        await waitUntil("playback stopped") { !harness.engine.isPlaying }

        gate.open()
        try await Task.sleep(for: .seconds(1))
        let cached = await cache.isFullyCached(.youtube(videoId: next.videoId))
        XCTAssertFalse(cached, "a read-ahead cancelled by the stop writes nothing")
    }

    func testASubstitutableNextTrackIsWarmedButNotFetched() async throws {
        // With a source outranking YouTube, read-ahead must warm the stream URL only: fetching
        // bytes would write them into an entry a substitute is about to fill from another server.
        let cache = try makeTestCache(in: makeTemporaryDirectory(self), prefetchDelay: .zero)
        let harness = PlayerHarness(test: self, cache: cache, session: FileRangeProtocol.session(), canSubstitute: { _ in true })
        let first = try harness.song("warmOnly01", seconds: 30, origin: .youtube)
        let next = try harness.song("warmOnly02", seconds: 30, origin: .youtube)

        harness.player.play([first, next], startAt: 0)
        await waitUntil("the current track is loaded and told to play", timeout: 30) {
            harness.engine.currentItem?.song?.videoId == first.videoId && harness.engine.playWhenReady
        }
        await waitUntil("the next track's URL is warmed", timeout: 30) {
            harness.resolver.requestedIds.contains(next.videoId)
        }
        // Give the byte half every chance to (wrongly) run.
        try await Task.sleep(for: .seconds(1))
        let cached = await cache.isFullyCached(.youtube(videoId: next.videoId))
        XCTAssertFalse(cached, "a substitutable next track is warmed, never fetched")
    }

    func testDownloadedPinnedAndSourceBackedRowsAreNeverReadAhead() async throws {
        let sourceBacked = Song(videoId: "src:jiosaavn::abc", title: "Source", artist: "A", durationText: "3:00")

        try await assertReadAheadSkips(makeFiltered: { try $0.song("filterDown1", seconds: 30, origin: .youtube) }) { harness, filtered in
            harness.factory.savedFile = { song in
                song.videoId == filtered.videoId
                    ? SavedAudioFile(url: harness.directory.appending(path: "filterDown1.m4a"), isYouTubeOrigin: false)
                    : nil
            }
        }
        try await assertReadAheadSkips(makeFiltered: { try $0.song("filterPin01", seconds: 30, origin: .youtube) }) { harness, filtered in
            harness.factory.isPinnedToOriginal = { $0 == filtered.videoId }
        }
        try await assertReadAheadSkips(makeFiltered: { _ in sourceBacked }) { _, _ in }
    }

    /// Puts `filtered` between the playing track and an eligible control. The control becoming
    /// fully cached is the proof read-ahead ran and skipped `filtered`, rather than never starting
    /// (a negative assertion alone can pass on a plan that never fired).
    private func assertReadAheadSkips(
        makeFiltered: (PlayerHarness) throws -> Song,
        configure: (PlayerHarness, Song) -> Void
    ) async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self), prefetchDelay: .zero)
        let harness = makeHarness(cache: cache)
        let playing = try harness.song("filterPlay1", seconds: 30, origin: .youtube)
        let filtered = try makeFiltered(harness)
        let control = try harness.song("filterCtrl1", seconds: 30, origin: .youtube)
        configure(harness, filtered)

        harness.player.play([playing, filtered, control], startAt: 0)
        await waitUntil("the current track is loaded and told to play", timeout: 30) {
            harness.engine.currentItem?.song?.videoId == playing.videoId && harness.engine.playWhenReady
        }
        let controlCached = await waitForFullCache(cache, .youtube(videoId: control.videoId))
        XCTAssertTrue(controlCached, "read-ahead ran: the eligible control was fetched")
        let filteredCached = await cache.isFullyCached(.youtube(videoId: filtered.videoId))
        XCTAssertFalse(filteredCached, "\(filtered.videoId) must never be read ahead")
    }
}

/// A settable clock for ``AudioCacheRenditions``'s `now`.
private final class SweepTestClock: @unchecked Sendable {
    var date = Date()
}

/// `file` as an fMP4 HLS package, the shape an add-on's DASH copy arrives in: an init segment that
/// declares no length, then one `moof`/`mdat` segment every `seconds`, and the playlist naming them.
func fragmentedHLS(of file: URL, every seconds: Double) async throws -> (playlist: String, bodies: [String: Data]) {
    let asset = AVURLAsset(url: file)
    let track = try await asset.loadTracks(withMediaType: .audio)[0]
    let format = try await track.load(.formatDescriptions)[0]
    let collector = SegmentCollector()
    let writer = AVAssetWriter(contentType: .mpeg4Movie)
    writer.outputFileTypeProfile = .mpeg4AppleHLS
    writer.preferredOutputSegmentInterval = CMTime(seconds: seconds, preferredTimescale: 1)
    writer.initialSegmentStartTime = .zero
    writer.delegate = collector
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
    input.expectsMediaDataInRealTime = false
    writer.add(input)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    guard writer.startWriting(), reader.startReading() else { throw writer.error ?? reader.error ?? URLError(.cannotCreateFile) }
    writer.startSession(atSourceTime: .zero)
    while let sample = output.copyNextSampleBuffer() {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
        input.append(sample)
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? URLError(.cannotCreateFile) }
    var bodies = ["init.mp4": collector.initialization]
    var playlist = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(Int(seconds))\n#EXT-X-MAP:URI=\"https://cdn.example/init.mp4\"\n"
    for (index, segment) in collector.segments.enumerated() {
        bodies["seg\(index).m4s"] = segment
        playlist += "#EXTINF:\(seconds),\nhttps://cdn.example/seg\(index).m4s\n"
    }
    return (playlist + "#EXT-X-ENDLIST\n", bodies)
}

final class SegmentCollector: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var head = Data()
    private var parts: [Data] = []
    var initialization: Data { lock.withLock { head } }
    var segments: [Data] { lock.withLock { parts } }

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType) {
        lock.withLock {
            if segmentType == .initialization { head = segmentData } else { parts.append(segmentData) }
        }
    }
}

/// A quick source (JioSaavn) that answers every track with one stream, once released.
private final class QuickCopyStub: @unchecked Sendable {
    private let lock = NSLock()
    private let stream: ResolvedStream
    private var log: [String] = []
    private var released = false

    init(_ stream: ResolvedStream) { self.stream = stream }

    var asked: [String] { lock.withLock { log } }

    func release() { lock.withLock { released = true } }

    func answer(_ song: Song) async throws -> ResolvedStream? {
        lock.withLock { log.append(song.videoId) }
        while !lock.withLock({ released }) { try await Task.sleep(for: .milliseconds(20)) }
        return stream
    }
}

/// Answers each resolve with the next of `streams` (the last one again once they run out).
private final class SequenceResolver: StreamResolving, @unchecked Sendable {
    private let lock = NSLock()
    private let streams: [ResolvedStream]
    private var log: [StreamRequest] = []

    init(_ streams: [ResolvedStream]) { self.streams = streams }

    var requests: [StreamRequest] { lock.withLock { log } }

    func resolveStream(for song: Song, request: StreamRequest) async throws -> ResolvedStream {
        lock.withLock {
            log.append(request)
            return streams[min(log.count, streams.count) - 1]
        }
    }
}

/// Answers a plain request at once, the way YouTube's leg does, and holds every request that waits
/// for the ranked sources until ``answerSources()``.
private final class AddonWaitResolver: StreamResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [StreamRequest] = []
    private var answered = false
    private let addonURL: URL?

    init(addonURL: URL? = nil) { self.addonURL = addonURL }

    var requests: [StreamRequest] { lock.withLock { log } }

    func answerSources() { lock.withLock { answered = true } }

    func resolveStream(for song: Song, request: StreamRequest) async throws -> ResolvedStream {
        lock.withLock { log.append(request) }
        if request.waitsForSources {
            while !lock.withLock({ answered }) { try await Task.sleep(for: .milliseconds(20)) }
            return ResolvedStream(url: addonURL ?? URL(string: "https://addon.test/\(song.videoId).flac")!, origin: .addon,
                                  mimeType: addonURL == nil ? "audio/flac" : "audio/wav",
                                  format: StreamFormat(codec: "flac", sampleRateHz: 44_100, bitDepth: 16))
        }
        return ResolvedStream(url: URL(string: "https://youtube.test/\(song.videoId).m4a")!, origin: .youtube, mimeType: "audio/mp4",
                              format: StreamFormat(codec: "aac", kbps: 128), belowRequest: true)
    }
}
