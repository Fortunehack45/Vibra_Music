import XCTest
@testable import Automix

/// Switching between a song and its music video: measuring the offset between the two cuts so the
/// switch carries on from about the same spot.
final class VersionAudioAlignerTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = try SyntheticAudio.temporaryDirectory(for: self)
    }

    private let rate = 22_050.0

    /// The "song": a minute of distinctive material. The "video": `intro` seconds of an unrelated
    /// skit, then the same song.
    private func versions(intro: Double) throws -> (song: URL, video: URL) {
        let song = SyntheticAudio.alignmentProgram(seconds: 60, sampleRate: rate, seed: 21)
        let skit = SyntheticAudio.alignmentProgram(seconds: intro, sampleRate: rate, seed: 99).map { $0 * 0.5 }
        let songURL = directory.appendingPathComponent("song.m4a")
        let videoURL = directory.appendingPathComponent("video.m4a")
        try SyntheticAudio.write(mono: song, sampleRate: rate, to: songURL)
        try SyntheticAudio.write(mono: skit + song, sampleRate: rate, to: videoURL)
        return (songURL, videoURL)
    }

    func testAMusicVideoWithAnIntroSkitLinesUpWithTheSong() async throws {
        let (song, video) = try versions(intro: 7.3)
        let aligner = VersionAudioAligner()

        let offset = try await XCTUnwrapAsync(await aligner.findOffsetMs(sourceURL: song, targetURL: video, sourceId: "song", targetId: "video"))
        XCTAssertEqual(Double(offset), 7_300, accuracy: 30, "the video is 7.3 s behind the song")
        XCTAssertEqual(aligner.cachedOffsetMs(sourceVideoId: "song", targetVideoId: "video"), offset)
        XCTAssertEqual(aligner.cachedOffsetMs(sourceVideoId: "video", targetVideoId: "song"), -offset, "both directions from one pass")

        // One minute into the song is 1:07.3 into the video, and the start of the video's skit maps to 0.
        XCTAssertEqual(VersionAudioAligner.targetPositionMs(sourcePositionMs: 60_000, offsetMs: offset), 60_000 + offset)
        XCTAssertEqual(VersionAudioAligner.targetPositionMs(sourcePositionMs: 3_000, offsetMs: -offset), 0)
    }

    func testTheSwitchBackIsTheSameMeasurementReversed() async throws {
        let (song, video) = try versions(intro: 4.5)
        let aligner = VersionAudioAligner()
        let offset = try await XCTUnwrapAsync(await aligner.findOffsetMs(sourceURL: video, targetURL: song, sourceId: "video", targetId: "song"))
        XCTAssertEqual(Double(offset), -4_500, accuracy: 30)
    }

    func testUnrelatedRecordingsAreNotAMeasurement() async throws {
        let first = directory.appendingPathComponent("a.m4a")
        let second = directory.appendingPathComponent("b.m4a")
        try SyntheticAudio.write(mono: SyntheticAudio.alignmentProgram(seconds: 45, sampleRate: rate, seed: 1), sampleRate: rate, to: first)
        try SyntheticAudio.write(mono: SyntheticAudio.alignmentProgram(seconds: 45, sampleRate: rate, seed: 2), sampleRate: rate, to: second)
        let aligner = VersionAudioAligner()
        let offset = await aligner.findOffsetMs(sourceURL: first, targetURL: second, sourceId: "a", targetId: "b")
        XCTAssertNil(offset, "nil, never a silent zero")
        XCTAssertNil(aligner.cachedOffsetMs(sourceVideoId: "a", targetVideoId: "b"))
    }

    func testTheSameVersionNeedsNoMeasurement() async throws {
        let aligner = VersionAudioAligner()
        XCTAssertEqual(aligner.cachedOffsetMs(sourceVideoId: "x", targetVideoId: "x"), 0)
        let offset = await aligner.findOffsetMs(source: VersionAlignmentTrack(videoId: "x"), target: VersionAlignmentTrack(videoId: "x"))
        XCTAssertEqual(offset, 0)
    }

    func testNoAudioToReadIsNoMeasurement() async throws {
        let aligner = VersionAudioAligner(renditions: FakeRenditionProvider())
        let offset = await aligner.findOffsetMs(source: VersionAlignmentTrack(videoId: "a"), target: VersionAlignmentTrack(videoId: "b"))
        XCTAssertNil(offset)
    }

    func testTracksAreMeasuredFromTheirCachedOpenings() async throws {
        let (song, video) = try versions(intro: 6)
        let provider = FakeRenditionProvider()
        provider.set([try FakeRenditionProvider.rendition(key: "songId", file: song)], for: "songId")
        provider.set([try FakeRenditionProvider.rendition(key: "videoId", file: video)], for: "videoId")
        let aligner = VersionAudioAligner(renditions: provider)
        let offset = await aligner.findOffsetMs(
            source: VersionAlignmentTrack(videoId: "songId", title: "Song"),
            target: VersionAlignmentTrack(videoId: "videoId", title: "Song (Official Video)")
        )
        XCTAssertEqual(Double(offset ?? 0), 6_000, accuracy: 30)
    }

    func testRemoteStreamsAreFetchedWithTheirOwnHeadersAndPatched() async throws {
        let (song, video) = try versions(intro: 5)
        let bodies = ["/song": try Data(contentsOf: song), "/video": try Data(contentsOf: video)]
        let seen = RequestLog()
        let session = StubURLProtocol.session { request in
            let path = request.url?.path ?? ""
            seen.append(path, request.value(forHTTPHeaderField: "X-Stream") ?? "")
            return (200, ["Content-Type": "audio/mp4"], bodies[path] ?? Data())
        }
        let patches = PatchCounter()
        let aligner = VersionAudioAligner(session: session, remoteHeadPatch: { _ in patches.count += 1 })
        let offset = await aligner.findOffsetMs(
            source: VersionAlignmentTrack(videoId: "s", remoteAudioURL: URL(string: "https://media.example.com/song"), remoteAudioHeaders: ["X-Stream": "song"]),
            target: VersionAlignmentTrack(videoId: "v", remoteAudioURL: URL(string: "https://media.example.com/video"), remoteAudioHeaders: ["X-Stream": "video"])
        )
        XCTAssertEqual(Double(offset ?? 0), 5_000, accuracy: 30)
        XCTAssertEqual(seen.entries.sorted { $0.0 < $1.0 }.map(\.1), ["song", "video"], "each stream carries its own headers")
        XCTAssertEqual(patches.count, 2, "both remote openings go through the patch")
    }

    func testTheLargestSameSourceOpeningIsPreferredOverASubstitute() throws {
        let provider = FakeRenditionProvider()
        let file = { (name: String) in URL(fileURLWithPath: "/cache/\(name)") }
        let aligner = VersionAudioAligner(renditions: provider)

        provider.set([
            AutomixRendition(key: "v", contentLength: 0, cachedPrefix: 500_000, fileURL: file("v")),
            AutomixRendition(key: "v#alt", contentLength: 0, cachedPrefix: 3_000_000, fileURL: file("alt")),
            AutomixRendition(key: "v#hifi", contentLength: 0, cachedPrefix: 900_000, fileURL: file("hifi")),
        ], for: "v")
        XCTAssertEqual(aligner.audioURL(for: VersionAlignmentTrack(videoId: "v")), file("hifi"), "enough same-source bytes win")

        provider.set([
            AutomixRendition(key: "v", contentLength: 0, cachedPrefix: 100_000, fileURL: file("v")),
            AutomixRendition(key: "v#alt", contentLength: 0, cachedPrefix: 3_000_000, fileURL: file("alt")),
        ], for: "v")
        XCTAssertEqual(aligner.audioURL(for: VersionAlignmentTrack(videoId: "v")), file("alt"), "a stub loses to a real opening")

        let local = directory.appendingPathComponent("song.m4a")
        try Data(repeating: 1, count: 64).write(to: local)
        XCTAssertEqual(aligner.audioURL(for: VersionAlignmentTrack(videoId: "v", localURL: local)), local, "the user's own file first")

        // A stale Song.localUri (deleted or offloaded) must not shut out the cached copy.
        let gone = directory.appendingPathComponent("gone.m4a")
        XCTAssertEqual(aligner.audioURL(for: VersionAlignmentTrack(videoId: "v", localURL: gone)), file("alt"), "an unreadable device file falls through to the cache")

        provider.set([], for: "v")
        let remote = try XCTUnwrap(URL(string: "https://cdn.example.com/v.m4a"))
        XCTAssertEqual(aligner.audioURL(for: VersionAlignmentTrack(videoId: "v", remoteAudioURL: remote)), remote)
    }

    func testAPeakPinnedToTheSearchEdgeIsNotBelieved() {
        XCTAssertEqual(VersionAudioAligner.acceptedLag(.init(lagFrames: 730, confidence: 0.8, floor: -1000, ceiling: 1500)), 730)
        XCTAssertNil(VersionAudioAligner.acceptedLag(.init(lagFrames: 1500, confidence: 0.95, floor: -1000, ceiling: 1500)))
        XCTAssertNil(VersionAudioAligner.acceptedLag(.init(lagFrames: -1000, confidence: 0.95, floor: -1000, ceiling: 1500)))
        XCTAssertNil(VersionAudioAligner.acceptedLag(.init(lagFrames: 10, confidence: 0.39, floor: -1000, ceiling: 1500)))
    }

    func testTheEnvelopeIsWindowedRMS() {
        let samples = [Float](repeating: 0.5, count: 44_100)
        let envelope = VersionAudioAligner.energyEnvelope(samples, sampleRate: 44_100)
        XCTAssertEqual(envelope.count, (44_100 - 1_764) / 441)
        XCTAssertTrue(envelope.allSatisfy { abs($0 - 0.5) < 1e-6 })
        XCTAssertTrue(VersionAudioAligner.energyEnvelope([0.1, 0.2], sampleRate: 44_100).isEmpty)
    }

    // MARK: - Status

    func testStatusWalksThroughThePhasesOfTheCurrentSwitchOnly() {
        let aligner = VersionAudioAligner()
        XCTAssertNil(aligner.status)
        let first = aligner.beginAttempt(sourceId: "song", targetId: "video")
        XCTAssertEqual(aligner.status, .init(sourceId: "song", targetId: "video", phase: .fetching))
        aligner.publishPhase(first, phase: .measuring)
        XCTAssertEqual(aligner.status?.phase, .measuring)

        // A second switch outranks the first; the first one's late result must not describe it.
        let second = aligner.beginAttempt(sourceId: "video", targetId: "song")
        aligner.publishPhase(first, phase: .aligned, offsetMs: 1234)
        XCTAssertEqual(aligner.status, .init(sourceId: "video", targetId: "song", phase: .fetching))
        aligner.publishPhase(second, phase: .aligned, offsetMs: -7300, fromCache: true)
        XCTAssertEqual(aligner.status, .init(sourceId: "video", targetId: "song", phase: .aligned, offsetMs: -7300, fromCache: true))
    }

    func testStatusUpdatesStreamTheCurrentValueThenChanges() async {
        let aligner = VersionAudioAligner()
        let token = aligner.beginAttempt(sourceId: "a", targetId: "b")
        var iterator = aligner.statusUpdates().makeAsyncIterator()
        let current = await iterator.next()
        XCTAssertEqual(current??.phase, .fetching)
        aligner.publishPhase(token, phase: .failed)
        let next = await iterator.next()
        XCTAssertEqual(next??.phase, .failed)
    }
}

final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(String, String)] = []
    func append(_ path: String, _ header: String) { lock.withLock { stored.append((path, header)) } }
    var entries: [(String, String)] { lock.withLock { stored } }
}
