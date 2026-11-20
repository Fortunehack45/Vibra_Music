import XCTest
@testable import Automix

/// The analysis orchestrator end to end: files on disk in, ``TrackAnalysis`` out.
final class TrackAnalyzerTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = try SyntheticAudio.temporaryDirectory(for: self)
    }

    /// A drum track written to disk as stereo (22.05 kHz unless asked otherwise: generating the
    /// audio is most of what these tests cost).
    private func drumFile(_ name: String, bpm: Double, seconds: Double, rate: Double = 22_050) throws -> URL {
        let samples = SyntheticAudio.drumTrack(bpm: bpm, seconds: seconds, sampleRate: rate)
        let url = directory.appendingPathComponent(name)
        try SyntheticAudio.write([samples, samples], sampleRate: rate, to: url)
        return url
    }

    /// DSP only: the model passes are exercised by their own tests and by the full-pipeline case,
    /// and leaving them out keeps the bookkeeping tests fast.
    private func dspAnalyzer(
        renditions: AutomixRenditionProvider? = nil,
        store: AutomixAnalysisStore? = nil,
        catalogMatcher: AutomixCatalogMatcher? = nil,
        isStopped: @escaping @Sendable () -> Bool = { false }
    ) -> TrackAnalyzer {
        TrackAnalyzer(
            renditions: renditions,
            store: store,
            catalogMatcher: catalogMatcher,
            isStopped: isStopped,
            budget: { .efficient },
            beatModelURL: nil,
            vocalModelURL: nil
        )
    }

    // MARK: - Local files

    func testALocalFileIsAnalysedWholeWithBothModelsAndPersisted() async throws {
        let file = try drumFile("local.m4a", bpm: 120, seconds: 40, rate: 44_100)
        let store = AutomixAnalysisStore(directory: directory.appendingPathComponent("store"))
        let analyzer = TrackAnalyzer(store: store, budget: { .balanced })

        XCTAssertEqual(analyzer.state(of: "local"), .waiting)
        analyzer.request(trackId: "local", uri: file, durationSeconds: 40)
        XCTAssertTrue(analyzer.isAnalysing("local"))
        XCTAssertEqual(analyzer.state(of: "local"), .analysing)
        await analyzer.waitUntilIdle()

        let analysis = analyzer.analysis(for: "local")
        XCTAssertTrue(analysis.isUsable)
        XCTAssertEqual(analyzer.state(of: "local"), .analysed)
        XCTAssertFalse(analyzer.isAnalysing("local"))
        XCTAssertEqual(analysis.trackId, "local")
        XCTAssertEqual(analysis.duration, 40)
        XCTAssertEqual(analysis.bpm, 120, accuracy: 2.4)
        XCTAssertGreaterThan(analysis.beatConfidence, 0.35)
        XCTAssertEqual(analysis.contentEndTime, 39.7, accuracy: 1)
        XCTAssertFalse(analysis.mixInCandidates.isEmpty)
        XCTAssertFalse(analysis.mixOutCandidates.isEmpty)
        XCTAssertFalse(analysis.downbeats.isEmpty)
        XCTAssertEqual(analysis.downbeats, analysis.downbeats.sorted())
        XCTAssertEqual(analysis.vocalActivityMask.count, analysis.energyCurve.count)

        // Persisted, so the next launch does not re-earn it.
        XCTAssertEqual(store.load("local")?.bpm, analysis.bpm)
        analyzer.release()
    }

    func testAStoredResultIsRestoredInsteadOfDecodedAgain() async throws {
        let store = AutomixAnalysisStore(directory: directory)
        let stored = AnalysisFixtures.track(id: "known", bpm: 99)
        store.save("known", stored)
        let analyzer = dspAnalyzer(store: store)
        // The file is gone: only the store can answer.
        analyzer.request(trackId: "known", uri: directory.appendingPathComponent("gone.m4a"), durationSeconds: 210)
        await analyzer.waitUntilIdle()
        XCTAssertEqual(analyzer.analysis(for: "known").bpm, 99)
        XCTAssertTrue(analyzer.analysis(for: "known").isUsable)
    }

    func testAFileThatWillNotDecodeIsRecordedAsFailedAndNotRetried() async throws {
        let garbage = directory.appendingPathComponent("garbage.m4a")
        try Data(repeating: 7, count: 10_000).write(to: garbage)
        let analyzer = dspAnalyzer()
        analyzer.request(trackId: "bad", uri: garbage, durationSeconds: 180)
        await analyzer.waitUntilIdle()
        XCTAssertEqual(analyzer.state(of: "bad"), .failed)
        XCTAssertFalse(analyzer.analysis(for: "bad").isUsable)

        analyzer.request(trackId: "bad", uri: garbage, durationSeconds: 180)
        XCTAssertFalse(analyzer.isAnalysing("bad"), "a local file is its only copy, and it was read")
    }

    func testATruncatedFileGetsThreeStrikesBeforeItIsWrittenOff() async throws {
        // Thirty seconds of audio claiming to be sixty: decoding it would read as a track that
        // goes quiet at 0:30, which is refused rather than published.
        let file = try drumFile("short.wav", bpm: 120, seconds: 30)
        let analyzer = dspAnalyzer()
        for attempt in 1...3 {
            analyzer.request(trackId: "short", uri: file, durationSeconds: 60)
            await analyzer.waitUntilIdle()
            XCTAssertEqual(analyzer.state(of: "short"), attempt < 3 ? .waiting : .failed, "after attempt \(attempt)")
        }
        XCTAssertEqual(analyzer.analysis(for: "short").duration, 60)
    }

    func testNothingHappensWhileStopped() async throws {
        let file = try drumFile("party.wav", bpm: 120, seconds: 50)
        let analyzer = dspAnalyzer(isStopped: { true })
        analyzer.request(trackId: "party", uri: file, durationSeconds: 50)
        XCTAssertFalse(analyzer.isAnalysing("party"))
        await analyzer.waitUntilIdle()
        XCTAssertEqual(analyzer.state(of: "party"), .waiting)
    }

    func testReleaseDropsQueuedWork() async throws {
        let file = try drumFile("released.wav", bpm: 120, seconds: 50)
        let analyzer = dspAnalyzer()
        // Queued first, so release has something to drop.
        analyzer.request(trackId: "released", uri: file, durationSeconds: 50)
        XCTAssertTrue(analyzer.isAnalysing("released"))
        analyzer.release()
        await analyzer.waitUntilIdle()
        XCTAssertFalse(analyzer.isAnalysed("released"))
        XCTAssertFalse(analyzer.isAnalysing("released"))
    }

    /// Closing the queue while a caller is waiting on it must not strand that caller, and must
    /// still drop the work that had not started.
    func testClosingTheQueueResolvesAWaitingDrainAndDropsPendingJobs() async throws {
        let jobs = AutomixSerialJobs()
        let gate = AsyncStream<Void>.makeStream()
        let started = expectation(description: "first job running")
        jobs.enqueue {
            started.fulfill()
            for await _ in gate.stream { break }
        }
        let dropped = expectation(description: "pending job ran")
        dropped.isInverted = true
        jobs.enqueue { dropped.fulfill() }
        await fulfillment(of: [started], timeout: 5)

        let drained = expectation(description: "drain returned")
        Task {
            await jobs.drain()
            drained.fulfill()
        }
        // Long enough for the drain marker to be buffered behind the running job.
        try await Task.sleep(nanoseconds: 100_000_000)
        jobs.close()
        gate.continuation.yield(())

        await fulfillment(of: [drained], timeout: 5)
        await fulfillment(of: [dropped], timeout: 0.2)
    }

    // MARK: - Cached renditions

    func testAHeadPassIsProvisionalUntilTheWholeTrackSupersedesIt() async throws {
        let whole = try drumFile("whole.wav", bpm: 124, seconds: 90)
        let data = try Data(contentsOf: whole)
        let head = directory.appendingPathComponent("head.wav")
        try data.prefix(data.count * 2 / 5).write(to: head)
        let provider = FakeRenditionProvider()
        let size = Int64(data.count)
        provider.set([AutomixRendition(key: "vid", contentLength: size, cachedPrefix: size * 2 / 5, fileURL: head)], for: "vid")
        let store = AutomixAnalysisStore(directory: directory.appendingPathComponent("store"))
        let analyzer = dspAnalyzer(renditions: provider, store: store)
        let uri = try XCTUnwrap(URL(string: "vibramusic://watch?v=vid"))

        analyzer.request(trackId: "vid", uri: uri, durationSeconds: 90)
        await analyzer.waitUntilIdle()
        let provisional = analyzer.analysis(for: "vid")
        XCTAssertTrue(provisional.isUsable, "an entry-only estimate from the cached opening")
        XCTAssertEqual(provisional.bpm, 124, accuracy: 0.5)
        XCTAssertFalse(provisional.mixInCandidates.isEmpty)
        XCTAssertEqual(provisional.contentEndTime, 0, "nothing about the rest of the track is claimed")
        XCTAssertTrue(provisional.energyCurve.isEmpty)
        XCTAssertTrue(provisional.mixOutCandidates.isEmpty)
        XCTAssertNil(store.load("vid"), "a head result is never persisted")

        // Still downloading: asking again only nudges the cache for the rest.
        analyzer.request(trackId: "vid", uri: uri, durationSeconds: 90)
        XCTAssertFalse(analyzer.isAnalysing("vid"))
        XCTAssertEqual(provider.requestedHeads.last, uri)

        // The download completes: the whole-track pass replaces the provisional numbers.
        provider.set([AutomixRendition(key: "vid", contentLength: size, cachedPrefix: size, fileURL: whole)], for: "vid")
        analyzer.request(trackId: "vid", uri: uri, durationSeconds: 90)
        XCTAssertEqual(analyzer.state(of: "vid"), .refining)
        await analyzer.waitUntilIdle()
        let complete = analyzer.analysis(for: "vid")
        XCTAssertEqual(complete.contentEndTime, 89.7, accuracy: 1)
        XCTAssertFalse(complete.energyCurve.isEmpty)
        XCTAssertFalse(complete.mixOutCandidates.isEmpty)
        XCTAssertEqual(analyzer.state(of: "vid"), .analysed)
        XCTAssertNotNil(store.load("vid"))
    }

    func testTooLittleCachedAsksTheCacheForTheOpening() async throws {
        let whole = try drumFile("tiny.wav", bpm: 124, seconds: 90)
        let size = Int64(try Data(contentsOf: whole).count)
        let provider = FakeRenditionProvider()
        // A sliver: under the twelve seconds' worth (plus margin) the head pass insists on.
        provider.set([AutomixRendition(key: "vid", contentLength: size, cachedPrefix: size / 20, fileURL: whole)], for: "vid")
        let analyzer = dspAnalyzer(renditions: provider)
        let uri = try XCTUnwrap(URL(string: "vibramusic://watch?v=vid"))
        analyzer.request(trackId: "vid", uri: uri, durationSeconds: 90)
        XCTAssertFalse(analyzer.isAnalysing("vid"))
        XCTAssertEqual(provider.requestedHeads, [uri])
    }

    func testASubstituteCopyIsNotBorrowedForAYouTubeTrack() async throws {
        let whole = try drumFile("alt.wav", bpm: 124, seconds: 90)
        let provider = FakeRenditionProvider()
        provider.set([try FakeRenditionProvider.rendition(key: "vid#alt", file: whole)], for: "vid")
        let analyzer = dspAnalyzer(renditions: provider)
        let uri = try XCTUnwrap(URL(string: "vibramusic://watch?v=vid"))
        analyzer.request(trackId: "vid", uri: uri, durationSeconds: 90)
        await analyzer.waitUntilIdle()
        XCTAssertFalse(analyzer.isAnalysed("vid"))
        XCTAssertEqual(provider.requestedHeads, [uri], "the canonical copy is fetched instead")
    }

    func testACompleteCopyThatDecodesShortIsThrownOffDiskOnce() async throws {
        // The header promises sixty seconds; the bytes hold about half.
        let full = try drumFile("full.caf", bpm: 124, seconds: 60)
        let data = try Data(contentsOf: full)
        let broken = directory.appendingPathComponent("broken.caf")
        try data.prefix(data.count / 2).write(to: broken)
        let provider = FakeRenditionProvider()
        provider.set([try FakeRenditionProvider.rendition(key: "vid", file: broken)], for: "vid")
        let analyzer = dspAnalyzer(renditions: provider)
        let uri = try XCTUnwrap(URL(string: "vibramusic://watch?v=vid"))

        analyzer.request(trackId: "vid", uri: uri, durationSeconds: 60)
        await analyzer.waitUntilIdle()
        XCTAssertEqual(provider.discarded, ["vid"])
        XCTAssertEqual(analyzer.state(of: "vid"), .waiting, "no copy was read to completion, so nothing is recorded")

        // The same broken copy again: a second discard would loop, so it is only struck.
        analyzer.request(trackId: "vid", uri: uri, durationSeconds: 60)
        await analyzer.waitUntilIdle()
        XCTAssertEqual(provider.discarded, ["vid"])
    }

    func testADifferentCutIsRejectedByItsLength() async throws {
        let edit = try drumFile("edit.wav", bpm: 124, seconds: 70)
        let provider = FakeRenditionProvider()
        provider.set([try FakeRenditionProvider.rendition(key: "vid", file: edit)], for: "vid")
        let analyzer = dspAnalyzer(renditions: provider)
        let uri = try XCTUnwrap(URL(string: "vibramusic://watch?v=vid"))
        analyzer.request(trackId: "vid", uri: uri, durationSeconds: 90)
        await analyzer.waitUntilIdle()
        XCTAssertFalse(analyzer.isAnalysed("vid"), "a 70 s copy does not describe a 90 s track")
    }

    func testASourceBackedTrackIsAnalysedFromItsYouTubeMatch() async throws {
        let whole = try drumFile("matched.wav", bpm: 124, seconds: 30)
        let provider = FakeRenditionProvider()
        provider.set([try FakeRenditionProvider.rendition(key: "yt123", file: whole)], for: "yt123")
        let analyzer = dspAnalyzer(renditions: provider, catalogMatcher: FixedCatalogMatcher(videoId: "yt123"))
        let uri = try XCTUnwrap(URL(string: "vibramusic://source?title=Song&artist=Artist&d=30"))

        // The first request only starts the match; later ticks pick the result up.
        let deadline = Date().addingTimeInterval(10)
        while !analyzer.isAnalysed("jio-1") && Date() < deadline {
            analyzer.request(trackId: "jio-1", uri: uri, durationSeconds: 30)
            await analyzer.waitUntilIdle()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(analyzer.analysis(for: "jio-1").isUsable)
        XCTAssertEqual(analyzer.analysis(for: "jio-1").bpm, 124, accuracy: 0.5)
    }

    func testASourceWithNoMatchIsNeverAnalysed() async throws {
        let analyzer = dspAnalyzer(renditions: FakeRenditionProvider(), catalogMatcher: FixedCatalogMatcher(videoId: nil))
        let uri = try XCTUnwrap(URL(string: "vibramusic://source?title=Unknown"))
        for _ in 0..<3 {
            analyzer.request(trackId: "jio-2", uri: uri, durationSeconds: 60)
            await analyzer.waitUntilIdle()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(analyzer.state(of: "jio-2"), .waiting)
    }

    // MARK: - Masks

    func testModelMasksOverlayTheNeutralCurveWhereTheyRan() {
        let merged = TrackAnalyzer.mergeMasks(size: 6, head: [0.9, 0.8, 0.5], tail: [0.5, 0.5, 0.5, 0.5, 0.1, 0.2])
        XCTAssertEqual(merged, [0.9, 0.8, 0.5, 0.5, 0.1, 0.2])
        XCTAssertNil(TrackAnalyzer.mergeMasks(size: 6, head: nil, tail: nil), "no model ran: keep the DSP estimate")
        XCTAssertNil(TrackAnalyzer.mergeMasks(size: 0, head: [1], tail: nil))
    }
}
