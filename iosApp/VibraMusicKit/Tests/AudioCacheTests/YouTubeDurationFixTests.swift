import AVFoundation
import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import AudioCache

/// YouTube's fragmented AAC declares its whole duration in the `moov` as well as in the fragments,
/// and AVFoundation adds the two. The cache zeroes the declaration in the bytes it stores, so the
/// player sees the real length online, offline and after a restart.
final class YouTubeDurationFixTests: XCTestCase {
    private func initSegment() throws -> Data {
        try FixtureLoader(bundle: .module).data("itag140_init_segment.mp4")
    }

    // MARK: The patch

    func testRealInitSegmentHasItsThreeDurationsZeroed() throws {
        let original = try initSegment()
        XCTAssertEqual(FragmentedMP4Durations.scan(original), .initSegment(end: 24 + 0x2BB), "ftyp + moov")
        XCTAssertTrue(FragmentedMP4Durations.isFragmented(original), "mvex marks it fragmented")

        var patched = original
        XCTAssertEqual(FragmentedMP4Durations.patchYouTubeInitSegment(&patched), 3, "mvhd, tkhd, mdhd")

        XCTAssertEqual(patched.count, original.count)
        let changed = (0..<original.count).filter { original[$0] != patched[$0] }
        XCTAssertFalse(changed.isEmpty)
        XCTAssertTrue(changed.allSatisfy { patched[$0] == 0 }, "only zeroes are written")
        XCTAssertTrue(changed.allSatisfy { $0 < 24 + 0x2BB }, "nothing past the moov changes")
        XCTAssertEqual(patched.subdata(in: 0x38..<0x3C), Data(count: 4), "mvhd duration")
        XCTAssertEqual(patched.subdata(in: 0xD8..<0xDC), Data(count: 4), "tkhd duration")
        XCTAssertEqual(patched.subdata(in: 0x138..<0x13C), Data(count: 4), "mdhd duration")

        var again = patched
        XCTAssertEqual(FragmentedMP4Durations.patchYouTubeInitSegment(&again), 0, "idempotent")
        XCTAssertEqual(again, patched)
    }

    func testOrdinaryMP4IsLeftAlone() throws {
        let file = try makeTemporaryDirectory().appending(path: "plain.m4a")
        try writeTone(to: file, seconds: 2)
        let original = try Data(contentsOf: file)
        XCTAssertFalse(FragmentedMP4Durations.isFragmented(original), "no mvex: not fragmented")

        var copy = original
        XCTAssertEqual(FragmentedMP4Durations.patchYouTubeInitSegment(&copy), 0, "no mvex: its moov's duration is the real one")
        XCTAssertEqual(copy, original)
    }

    func testOpeningIsHeldOnlyUntilTheMoovIsComplete() throws {
        let segment = try initSegment()
        var gate = InitSegmentGate()
        var released: Data?
        var fed = 0
        while released == nil, fed < segment.count {
            let end = min(segment.count, fed + 100)
            released = gate.feed(segment.subdata(in: fed..<end), patch: FragmentedMP4Durations.patchYouTubeInitSegment)
            fed = end
        }
        XCTAssertEqual(fed, 800, "released with the piece that completed the moov at 723")
        var expected = segment.prefix(800)
        FragmentedMP4Durations.patchYouTubeInitSegment(&expected)
        XCTAssertEqual(released, expected)
        XCTAssertEqual(gate.feed(Data([1, 2, 3])), Data([1, 2, 3]), "everything after passes straight through")
    }

    func testGateWithoutAPatchPassesTheOpeningThroughUntouched() throws {
        let segment = try initSegment()
        var gate = InitSegmentGate()
        var released: Data?
        var fed = 0
        while released == nil, fed < segment.count {
            let end = min(segment.count, fed + 100)
            released = gate.feed(segment.subdata(in: fed..<end))
            fed = end
        }
        XCTAssertEqual(released, segment.prefix(fed), "no patch: byte-identical")
    }

    func testOtherContainersAreNotHeldBack() {
        var flac = InitSegmentGate()
        XCTAssertEqual(flac.feed(Data("fLaC\0\0\0\"".utf8)), Data("fLaC\0\0\0\"".utf8))
        var moovAtTheEnd = InitSegmentGate()
        let head = Data([0, 0, 0, 16]) + Data("ftypM4A ".utf8) + Data([0, 0, 0, 0]) + Data([0, 0, 0, 8]) + Data("mdat".utf8)
        XCTAssertEqual(moovAtTheEnd.feed(head), head)
        var short = InitSegmentGate()
        XCTAssertNil(short.feed(Data([0, 0, 0])))
        XCTAssertEqual(short.release(), Data([0, 0, 0]), "a stream that ends early gives back what it had")
    }

    // MARK: Through the cache

    func testCachedCopyOfAYouTubeStreamCarriesThePatch() async throws {
        let segment = try initSegment()
        let body = segment + patternData(count: 900_000)
        let server = RangeServer()
        let url = googlevideoURL(client: "VISIONOS", length: body.count)
        server.host(body, at: url)
        let directory = try makeTemporaryDirectory()
        let key = AudioCacheKey.youtube(videoId: "rick")
        var expected = body
        FragmentedMP4Durations.patchYouTubeInitSegment(&expected)

        let cache = try makeCache(directory: directory)
        let source = HTTPAudioSource(stream: stream(url, length: body.count), session: server.session)
        XCTAssertTrue(source.requiresYouTubeDurationFix, "YouTube origin opts in")
        // The player's two-byte probe first, as AVFoundation opens every asset.
        let probe = try await readThroughCache(cache, key: key, source: source, range: 0..<2)
        let played = try await readThroughCache(cache, key: key, source: source, range: 0..<Int64(body.count))
        await cache.flush()
        let replayed = try await readThroughCache(try makeCache(directory: directory), key: key, source: nil, range: 0..<Int64(body.count))

        XCTAssertEqual(probe, body.prefix(2))
        XCTAssertEqual(played, expected)
        XCTAssertEqual(replayed, expected, "the patch is what's on disk")
        XCTAssertEqual(server.requestedBytes(total: Int64(body.count)), Int64(body.count), "held-back bytes aren't fetched twice")
    }

    func testAVFoundationReadsTheRealLengthThroughTheCache() async throws {
        let seconds = 20.0
        let body = try await makeYouTubeShapedAAC(seconds: seconds)
        let file = try makeTemporaryDirectory().appending(path: "youtube.mp4")
        try body.write(to: file)
        let unpatched = try await AVURLAsset(url: file).load(.duration).seconds
        XCTAssertEqual(unpatched, 2 * seconds, accuracy: 0.2, "the bug this fixes: the declared length plus the fragments")

        let server = RangeServer()
        let url = googlevideoURL(client: "VISIONOS", length: body.count)
        server.host(body, at: url)
        let cache = try makeCache()
        let key = AudioCacheKey.youtube(videoId: "fragmented")
        let source = HTTPAudioSource(stream: stream(url, length: body.count, mimeType: "audio/mp4; codecs=\"mp4a.40.2\""), session: server.session)

        let online = try await cache.makeAsset(for: key, source: source).load(.duration).seconds
        XCTAssertEqual(online, seconds, accuracy: 0.2)
        _ = await cache.cacheCompletely(key, source: source)
        server.offline = true
        let offline = try await cache.makeAsset(for: key, source: nil).load(.duration).seconds
        XCTAssertEqual(offline, seconds, accuracy: 0.2)
        let frames = try await decodeAllFrames(of: cache.makeAsset(for: key, source: nil))
        XCTAssertEqual(Double(frames), seconds * 44_100, accuracy: 4_096, "every sample decodes, once")
    }

    func testDownloadedYouTubeFileIsPatchedOnTheWayOut() async throws {
        let seconds = 8.0
        let body = try await makeYouTubeShapedAAC(seconds: seconds)
        let file = try makeTemporaryDirectory().appending(path: "download.m4a")
        try body.write(to: file)
        let cache = try makeCache()

        let duration = try await cache.makeAsset(for: .youtube(videoId: "saved"), source: FileAudioSource(url: file, mimeType: "audio/mp4", requiresYouTubeDurationFix: true)).load(.duration).seconds

        XCTAssertEqual(duration, seconds, accuracy: 0.2)
        XCTAssertEqual(try Data(contentsOf: file), body, "the file itself is not modified")
    }

    func testLocalFileWithoutTheFlagIsServedByteIdentical() async throws {
        let seconds = 8.0
        let body = try await makeYouTubeShapedAAC(seconds: seconds)
        let file = try makeTemporaryDirectory().appending(path: "plain.m4a")
        try body.write(to: file)
        let cache = try makeCache()
        let source = FileAudioSource(url: file, mimeType: "audio/mp4")
        XCTAssertFalse(source.requiresYouTubeDurationFix)

        let duration = try await cache.makeAsset(for: .youtube(videoId: "plain"), source: source).load(.duration).seconds

        XCTAssertEqual(duration, 2 * seconds, accuracy: 0.2, "unpatched: AVFoundation still sees the declared length plus the fragments")
    }

    func testNonYouTubeStreamIsStoredByteIdentical() async throws {
        let body = try await makeYouTubeShapedAAC(seconds: 8)
        let server = RangeServer()
        let url = URL(string: "https://cdn.example.com/track.m4a")!
        server.host(body, at: url)
        let addon = ResolvedStream(url: url, origin: .addon, mimeType: "audio/mp4", contentLength: Int64(body.count))
        let source = HTTPAudioSource(stream: addon, session: server.session)
        XCTAssertFalse(source.requiresYouTubeDurationFix)
        let cache = try makeCache()
        let key = AudioCacheKey.source("addon", track: "42")

        let played = try await readThroughCache(cache, key: key, source: source, range: 0..<Int64(body.count))

        XCTAssertEqual(played, body, "an addon's fragmented MP4 is not ours to rewrite")
    }
}

/// Fragmented AAC shaped like YouTube's itag 140: AVAssetWriter's fMP4 output (`ftyp`, a `moov`
/// with `mvex`, then `moof`/`mdat` fragments), with the `moov` then made to declare the whole
/// duration in `mvhd`, `tkhd` and `mdhd` as YouTube's does.
func makeYouTubeShapedAAC(seconds: Double) async throws -> Data {
    let m4a = FileManager.default.temporaryDirectory.appending(path: "tone-\(UUID().uuidString).m4a")
    defer { try? FileManager.default.removeItem(at: m4a) }
    try writeTone(to: m4a, seconds: seconds)
    let asset = AVURLAsset(url: m4a)
    let track = try await asset.loadTracks(withMediaType: .audio)[0]
    let format = try await track.load(.formatDescriptions)[0]

    let collector = SegmentCollector()
    let writer = AVAssetWriter(contentType: .mpeg4Movie)
    writer.outputFileTypeProfile = .mpeg4AppleHLS
    writer.preferredOutputSegmentInterval = CMTime(seconds: 4, preferredTimescale: 1)
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

    var data = collector.data
    func box(_ type: String) -> Int? {
        let wanted = Array(type.utf8)
        return (4..<min(data.count - 4, 4_096)).first { Array(data[$0..<($0 + 4)]) == wanted }.map { $0 - 4 }
    }
    func uint32(at offset: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(data[offset + $1]) } }
    func set(_ value: UInt32, at offset: Int) {
        for index in 0..<4 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (24 - 8 * UInt32(index))) }
    }
    guard let mvhd = box("mvhd"), let tkhd = box("tkhd"), let mdhd = box("mdhd"),
          data[mvhd + 8] == 0, data[mdhd + 8] == 0 else { throw URLError(.cannotParseResponse) }
    // Version-0 layouts: mvhd/mdhd timescale at +12 and duration at +16 of the body; tkhd duration at +20.
    let movieTimescale = uint32(at: mvhd + 8 + 12)
    let mediaTimescale = uint32(at: mdhd + 8 + 12)
    set(UInt32(seconds * Double(movieTimescale)), at: mvhd + 8 + 16)
    set(UInt32(seconds * Double(movieTimescale)), at: tkhd + 8 + 20)
    set(UInt32(seconds * Double(mediaTimescale)), at: mdhd + 8 + 16)
    return data
}

private final class SegmentCollector: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var collected = Data()
    var data: Data { lock.withLock { collected } }

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType) {
        lock.withLock { collected.append(segmentData) }
    }
}
