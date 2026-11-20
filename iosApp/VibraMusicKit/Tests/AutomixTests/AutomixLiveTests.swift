import XCTest
@testable import Automix

/// Real music from a real server, through the whole pipeline. Skipped unless
/// `VIBRAMUSIC_LIVE_TESTS=1`; with `VIBRAMUSIC_RECORD_FIXTURES=1` as well, the two analyses are
/// written into Fixtures/ for ``RecordedAnalysisPlanningTests``.
///
/// The songs are SoundHelix's example renders (full-length, drums, bass and lead), served as
/// plain MP3 over HTTPS.
final class AutomixLiveTests: XCTestCase {

    static let songs = [
        (id: "soundhelix-song-1", url: URL(string: "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3")!),
        (id: "soundhelix-song-2", url: URL(string: "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-2.mp3")!),
    ]

    private var directory: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VIBRAMUSIC_LIVE_TESTS"] == "1", "live tests need VIBRAMUSIC_LIVE_TESTS=1")
        directory = try SyntheticAudio.temporaryDirectory(for: self)
    }

    private func download(_ url: URL) async throws -> URL {
        let local = try await AutomixRemoteAudioFetcher(directory: directory).localCopy(of: url)
        let size = (try FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(size, 1_000_000, "a whole song came back")
        return local
    }

    func testLiveSongsAreAnalysedWithBothModelsAndPlanIntoEachOther() async throws {
        let store = AutomixAnalysisStore(directory: directory.appendingPathComponent("store"))
        let analyzer = TrackAnalyzer(store: store, budget: { .performance })
        var analyses: [TrackAnalysis] = []
        for song in Self.songs {
            let file = try await download(song.url)
            let duration = try await XCTUnwrapAsync(await AutomixAudioDecoder.containerDuration(of: file))
            let started = Date()
            analyzer.request(trackId: song.id, uri: file, durationSeconds: duration)
            await analyzer.waitUntilIdle()
            let analysis = analyzer.analysis(for: song.id)
            print("LIVE \(song.id): \(Int(Date().timeIntervalSince(started) * 1000))ms bpm=\(analysis.bpm) conf=\(analysis.beatConfidence) key=\(analysis.key) contentEnd=\(analysis.contentEndTime)/\(duration) downbeats=\(analysis.downbeats.count) mixIn=\(analysis.mixInCandidates.map(\.type)) mixOut=\(analysis.mixOutCandidates.map(\.type)) vocalMax=\(analysis.vocalActivityMask.max() ?? -1)")

            XCTAssertTrue(analysis.isUsable, song.id)
            XCTAssertTrue((TransitionPolicy.minBPM...TransitionPolicy.maxBPM).contains(analysis.bpm))
            XCTAssertGreaterThan(analysis.beatConfidence, TransitionPolicy.minDJConfidence, "a produced track with a kit is a usable grid")
            XCTAssertEqual(analysis.contentEndTime, duration, accuracy: 15)
            XCTAssertGreaterThan(analysis.downbeats.count, 8)
            XCTAssertEqual(analysis.vocalActivityMask.count, analysis.energyCurve.count)
            XCTAssertFalse(analysis.key.isEmpty)
            analyses.append(analysis)

            if ProcessInfo.processInfo.environment["VIBRAMUSIC_RECORD_FIXTURES"] == "1" {
                let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
                let stored = try Data(contentsOf: store.fileURL(for: song.id))
                try stored.write(to: fixtures.appendingPathComponent("\(song.id).analysis.json"))
            }
        }

        let plan = TransitionPlanner.plan(
            analysis: analyses[0],
            nextAnalysis: analyses[1],
            currentTrack: TransitionTrackInfo(id: analyses[0].trackId, durationMs: Int64(analyses[0].duration * 1000)),
            nextTrack: TransitionTrackInfo(id: analyses[1].trackId, durationMs: Int64(analyses[1].duration * 1000)),
            currentTime: 30,
            duration: analyses[0].duration,
            mode: .smart
        )
        print("LIVE plan: \(plan.reason) style=\(plan.transitionStyle) start=\(plan.transitionStart) fade=\(plan.fadeSeconds) cue=\(plan.incomingCueTime) rate=\(plan.incomingPlaybackRate) beats=\(plan.transitionBeats) vocalOverlap=\(plan.vocalOverlap) policy=\(plan.policyReasons)")
        XCTAssertFalse(plan.blocked)
        XCTAssertTrue(plan.markerVisible)
        XCTAssertGreaterThan(plan.fadeSeconds, 0)
        XCTAssertLessThanOrEqual(plan.fadeSeconds, 16)
        XCTAssertLessThanOrEqual(plan.transitionEnd, analyses[0].duration)
        XCTAssertLessThanOrEqual(abs(plan.incomingPlaybackRate - 1), 0.1)
        analyzer.release()
    }

    func testLiveRemoteAssetDecodesWithoutACache() async throws {
        let fetcher = AutomixRemoteAudioFetcher(directory: directory, maxBytes: 2 * 1024 * 1024)
        let pcm = try await XCTUnwrapAsync(await AutomixAudioDecoder.decodeMono(
            Self.songs[0].url,
            from: 0,
            to: 60,
            sampleRate: AutomixAudioDecoder.analysisSampleRate,
            fetcher: fetcher
        ))
        XCTAssertEqual(pcm.sampleRate, 11_025)
        XCTAssertGreaterThan(pcm.durationSeconds, 50, "two megabytes of a 192 kbps MP3 hold most of a minute")
        let features = try XCTUnwrap(TrackFeatures.analyze(pcm.samples, durationSeconds: pcm.durationSeconds))
        XCTAssertGreaterThan(features.bpm, 0)
    }

    func testLiveVersionAlignmentFindsASkitInFrontOfTheSong() async throws {
        // A "music video" made from the real song: a 6.5 s skit, then the song's first 45 s.
        let song = try await XCTUnwrapAsync(await AutomixAudioDecoder.decodeStereo(
            Self.songs[0].url,
            from: 0,
            to: 45,
            fetcher: AutomixRemoteAudioFetcher(directory: directory, maxBytes: 2 * 1024 * 1024)
        ))
        let skit = SyntheticAudio.alignmentProgram(seconds: 6.5, sampleRate: song.sampleRate, seed: 5).map { $0 * 0.3 }
        let video = directory.appendingPathComponent("video.m4a")
        try SyntheticAudio.write([skit + song.left, skit + song.right], sampleRate: song.sampleRate, to: video)

        let aligner = VersionAudioAligner()
        let offset = try await XCTUnwrapAsync(await aligner.findOffsetMs(
            source: VersionAlignmentTrack(videoId: "song", title: "SoundHelix Song 1", remoteAudioURL: Self.songs[0].url),
            target: VersionAlignmentTrack(videoId: "video", title: "SoundHelix Song 1 (video)", localURL: video)
        ))
        print("LIVE alignment offset \(offset)ms")
        XCTAssertEqual(Double(offset), 6_500, accuracy: 50)
    }
}
