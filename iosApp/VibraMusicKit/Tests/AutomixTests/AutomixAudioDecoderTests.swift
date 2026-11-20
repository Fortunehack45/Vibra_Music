import XCTest
@testable import Automix

/// AVAssetReader decoding of generated files: channel handling, regions, rates, remote assets.
final class AutomixAudioDecoderTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = try SyntheticAudio.temporaryDirectory(for: self)
    }

    /// Four seconds of stereo at 44.1 kHz: 440 Hz on the left, 660 Hz on the right.
    private func stereoTones(extension fileExtension: String) throws -> URL {
        let rate = 44_100.0
        var left = [Float](repeating: 0, count: Int(4 * rate))
        var right = left
        SyntheticAudio.addTone(into: &left, frequency: 440, start: 0, seconds: 4, sampleRate: rate, gain: 0.5)
        SyntheticAudio.addTone(into: &right, frequency: 660, start: 0, seconds: 4, sampleRate: rate, gain: 0.5)
        let url = directory.appendingPathComponent("tones.\(fileExtension)")
        try SyntheticAudio.write([left, right], sampleRate: rate, to: url)
        return url
    }

    func testStereoDecodeKeepsTheChannelsApart() async throws {
        let url = try stereoTones(extension: "caf")
        let pcm = try await XCTUnwrapAsync(await AutomixAudioDecoder.decodeStereo(url))
        XCTAssertEqual(pcm.sampleRate, 44_100)
        XCTAssertEqual(pcm.left.count, 176_400)
        XCTAssertEqual(pcm.startSeconds, 0, accuracy: 1e-6)
        XCTAssertEqual(SyntheticAudio.estimatedFrequency(pcm.left[4410..<88200], sampleRate: 44_100), 440, accuracy: 3)
        XCTAssertEqual(SyntheticAudio.estimatedFrequency(pcm.right[4410..<88200], sampleRate: 44_100), 660, accuracy: 3)
    }

    func testMonoDecodeAveragesTheChannels() async throws {
        let rate = 22_050.0
        let left = [Float](repeating: 0.6, count: 22_050)
        let right = [Float](repeating: 0.2, count: 22_050)
        let url = directory.appendingPathComponent("dc.caf")
        try SyntheticAudio.write([left, right], sampleRate: rate, to: url)
        let pcm = try await XCTUnwrapAsync(await AutomixAudioDecoder.decodeMono(url))
        XCTAssertEqual(pcm.samples.count, 22_050)
        XCTAssertEqual(pcm.samples[1000], 0.4, accuracy: 1e-6)
    }

    func testMonoSourceIsWidenedOntoBothSides() async throws {
        let url = directory.appendingPathComponent("mono.caf")
        var samples = [Float](repeating: 0, count: 44_100)
        SyntheticAudio.addTone(into: &samples, frequency: 300, start: 0, seconds: 1, sampleRate: 44_100, gain: 0.4)
        try SyntheticAudio.write(mono: samples, sampleRate: 44_100, to: url)
        let pcm = try await XCTUnwrapAsync(await AutomixAudioDecoder.decodeStereo(url))
        XCTAssertEqual(pcm.left, pcm.right)
    }

    func testAACFileDecodesToTheAnalyzerRate() async throws {
        let url = try stereoTones(extension: "m4a")
        let pcm = try await XCTUnwrapAsync(await AutomixAudioDecoder.decodeMono(url, sampleRate: AutomixAudioDecoder.analysisSampleRate))
        XCTAssertEqual(pcm.sampleRate, 11_025)
        XCTAssertEqual(pcm.durationSeconds, 4, accuracy: 0.1)
        // The mean of 440 and 660 Hz tones beats at 220 Hz; the energy should be clearly nonzero.
        let rms = (pcm.samples[11_025..<22_050].reduce(0) { $0 + Double($1 * $1) } / 11_025).squareRoot()
        XCTAssertGreaterThan(rms, 0.1)
        let duration = await AutomixAudioDecoder.containerDuration(of: url)
        XCTAssertEqual(duration ?? 0, 4, accuracy: 0.1)
    }

    func testARegionComesBackWithWhereItReallyStarts() async throws {
        let url = try stereoTones(extension: "m4a")
        let pcm = try await XCTUnwrapAsync(await AutomixAudioDecoder.decodeStereo(url, from: 1.5, to: 2.5))
        XCTAssertEqual(pcm.startSeconds, 1.5, accuracy: 0.05)
        XCTAssertEqual(pcm.startSeconds + pcm.durationSeconds, 2.5, accuracy: 0.05)
        XCTAssertEqual(SyntheticAudio.estimatedFrequency(pcm.left[2205..<22050], sampleRate: pcm.sampleRate), 440, accuracy: 5)
    }

    func testRegionPastTheEndOrInvertedDecodesNothing() async throws {
        let url = try stereoTones(extension: "caf")
        let inverted = await AutomixAudioDecoder.decodeMono(url, from: 2, to: 1)
        XCTAssertNil(inverted)
        let pastEnd = await AutomixAudioDecoder.decodeMono(url, from: 10, to: 20)
        XCTAssertNil(pastEnd)
    }

    func testMissingOrUndecodableFilesAreNoEvidenceNotErrors() async throws {
        let missing = await AutomixAudioDecoder.decodeMono(directory.appendingPathComponent("nope.m4a"))
        XCTAssertNil(missing)
        let garbage = directory.appendingPathComponent("garbage.m4a")
        try Data(repeating: 0x5A, count: 4096).write(to: garbage)
        let decoded = await AutomixAudioDecoder.decodeMono(garbage)
        XCTAssertNil(decoded)
        let duration = await AutomixAudioDecoder.containerDuration(of: garbage)
        XCTAssertNil(duration)
    }

    func testAbortAbandonsTheDecode() async throws {
        let url = try stereoTones(extension: "caf")
        let aborted = await AutomixAudioDecoder.decodeMono(url, abort: { true })
        XCTAssertNil(aborted)
    }

    func testATruncatedFileYieldsTheAudioBeforeTheCut() async throws {
        // A cached head: a file whose header promises twenty seconds, cut after about half.
        let rate = 22_050.0
        var samples = [Float](repeating: 0, count: Int(20 * rate))
        SyntheticAudio.addTone(into: &samples, frequency: 500, start: 0, seconds: 20, sampleRate: rate, gain: 0.3)
        let whole = directory.appendingPathComponent("whole.caf")
        try SyntheticAudio.write(mono: samples, sampleRate: rate, to: whole)
        let data = try Data(contentsOf: whole)
        let head = directory.appendingPathComponent("head.caf")
        try data.prefix(data.count / 2).write(to: head)

        let headDuration = await AutomixAudioDecoder.containerDuration(of: head)
        XCTAssertEqual(headDuration ?? 0, 20, accuracy: 0.1, "the header still describes the whole track")
        let pcm = try await XCTUnwrapAsync(await AutomixAudioDecoder.decodeMono(head))
        XCTAssertEqual(pcm.durationSeconds, 10, accuracy: 1, "what the bytes hold, to within one recovery range")
        let full = try await XCTUnwrapAsync(await AutomixAudioDecoder.decodeMono(whole))
        XCTAssertEqual(full.durationSeconds, 20, accuracy: 0.01)
    }

    func testATruncatedFileRecoversInABoundedNumberOfReaders() async throws {
        // A cached head that promises a minute but holds two fifths, the whole-track shape the
        // analyzer reads. The whole-range pass fails in flight near the cut, so the rest has to be
        // re-read; a tone that is cut mid-sample makes the decoder hand back its last fragment a
        // frame at a time as well, which is what turns a per-second recovery into thousands of
        // reader start-ups (measured: 7737 in the simulator).
        let rate = 22_050.0
        var samples = [Float](repeating: 0, count: Int(60 * rate))
        SyntheticAudio.addTone(into: &samples, frequency: 500, start: 0, seconds: 60, sampleRate: rate, gain: 0.3)
        let whole = directory.appendingPathComponent("long.caf")
        try SyntheticAudio.write(mono: samples, sampleRate: rate, to: whole)
        let data = try Data(contentsOf: whole)
        let head = directory.appendingPathComponent("long-head.caf")
        try data.prefix(Int(Double(data.count) * 0.4)).write(to: head)

        let sink = AutomixAudioDecoder.MonoSink()
        let format = try await XCTUnwrapAsync(await AutomixAudioDecoder.decode(head, from: 0, to: 60, into: sink, abort: { false }))
        let duration = Double(sink.frames) / format.sampleRate
        XCTAssertEqual(duration, 24, accuracy: 2, "the audio before the cut still comes back")
        // One reader opens the range, then growing chunks (1, 2, 4, 8 …) walk to the cut, and a
        // re-read that adds only the cut's own fragment ends the walk. The exact schedule is
        // pinned by the recover tests below; this only has to show the whole decode stays far
        // under a reader per second — 7737 in the simulator before the fix, six on the Mac. The
        // simulator varies with where the first pass stops (7–10 across runs), so the bound is
        // loose enough to hold there while still failing any return to a reader per second.
        XCTAssertLessThanOrEqual(sink.readerStarts, 16, "recovery opened \(sink.readerStarts) readers")
    }

    // MARK: - Recovery schedule

    /// The schedule is driven with scripted reads so its branches — not reachable from a
    /// generated file — are exercised directly: a long range that stops on the cut's own
    /// fragment, the reader ceiling, a reader that ends behind its seek point, and the stop.

    func testRecoveryRetryContinuesAfterTheFragmentItAlreadyDecoded() {
        let scripted: [AutomixAudioDecoder.RecoveryRead] = [
            .init(finished: true, framesAdded: 44_100, decodedEnd: 1.0),
            .init(finished: true, framesAdded: 88_200, decodedEnd: 3.0),
            // A 4 s range stops inside itself on the cut's own 5 ms fragment (220 frames at
            // 44.1 kHz), ending at 6.9 s rather than at the requested 7 s.
            .init(framesAdded: 220, decodedEnd: 6.9),
            .init(finished: true, framesAdded: 44_100, decodedEnd: 7.9),
        ]
        var ranges: [(Double, Double)] = []
        var index = 0
        AutomixAudioDecoder.recover(from: 0, to: 7.9, sampleRate: 44_100) { start, end in
            ranges.append((start, end))
            let read = index < scripted.count ? scripted[index] : AutomixAudioDecoder.RecoveryRead()
            index += 1
            return read
        }
        XCTAssertEqual(ranges.map(\.0), [0, 1.0, 3.0, 6.9], "the retry continues after the fragment, not over it")
        XCTAssertEqual(ranges.map(\.1), [1.0, 3.0, 7.0, 7.9])
    }

    func testRecoveryStopsAtTheReaderBudget() {
        var calls = 0
        AutomixAudioDecoder.recover(from: 0, to: 10_000, sampleRate: 44_100) { start, _ in
            calls += 1
            // Every range stops partway but still adds a second: the file broken throughout.
            return .init(framesAdded: 44_100, decodedEnd: start + 1.0)
        }
        XCTAssertEqual(AutomixAudioDecoder.recoveryReaderBudget(from: 0, to: 10_000), 689)
        XCTAssertEqual(AutomixAudioDecoder.recoveryReaderBudget(from: 0, to: .infinity),
                       AutomixAudioDecoder.recoveryMaxReaders, "an unmeasurable end gets the floor")
        XCTAssertEqual(calls, 689, "the budget is a hard ceiling on start-ups")
    }

    func testRecoveryStartsTheNextRangeWhereTheSinkReached() {
        var starts: [Double] = []
        AutomixAudioDecoder.recover(from: 0, to: 5, sampleRate: 44_100) { start, _ in
            starts.append(start)
            // Pre-skip: the 1 s delivered ends 0.1 s before `cursor + advance` would put it.
            return .init(finished: true, framesAdded: 44_100, decodedEnd: start + 0.9)
        }
        XCTAssertEqual(Array(starts.prefix(3)), [0, 0.9, 1.8],
                       "the next range starts where the sink got to, not past it")
    }

    func testRecoveryStopsWhenTheReaderEndsBehindTheSeek() {
        var starts: [Double] = []
        AutomixAudioDecoder.recover(from: 0, to: 5, sampleRate: 44_100) { start, _ in
            starts.append(start)
            // Audio entirely behind the seek point: nothing new arrived, so it stops rather than
            // re-reading the same place forever.
            return .init(framesAdded: 44_100, decodedEnd: start - 0.5)
        }
        XCTAssertEqual(starts, [0], "a reader that ends behind its seek does not spin")
    }

    func testRecoveryStopsWhenTheShortestRangeAddsNothing() {
        var calls = 0
        AutomixAudioDecoder.recover(from: 0, to: 30, sampleRate: 44_100) { _, _ in
            calls += 1
            return .init(framesAdded: 0, decodedEnd: 0)
        }
        XCTAssertEqual(calls, 1, "a 1 s range that adds nothing ends the recovery")
    }

    func testRecoveryReportsAnAbort() {
        var calls = 0
        let aborted = AutomixAudioDecoder.recover(from: 0, to: 30, sampleRate: 44_100) { _, _ in
            calls += 1
            return .init(aborted: true)
        }
        XCTAssertTrue(aborted)
        XCTAssertEqual(calls, 1)
    }

    func testRecoveryRetriesOnceAtTheShortestRangeThenStops() {
        var calls = 0
        AutomixAudioDecoder.recover(from: 0, to: 10, sampleRate: 44_100) { start, _ in
            calls += 1
            // The first range advances; the next two add nothing, so the pass drops to the
            // shortest range and ends rather than looping on the same place.
            return calls == 1
                ? .init(finished: true, framesAdded: 44_100, decodedEnd: start + 1.0)
                : .init(framesAdded: 0, decodedEnd: start)
        }
        XCTAssertEqual(calls, 3, "the shortest range is tried once, then the recovery ends")
    }

    func testBufferOverlapIsDroppedRatherThanDecodedTwice() {
        // 0.05 s of 44.1 kHz already in the sink is dropped from the head of the next buffer.
        XCTAssertEqual(AutomixAudioDecoder.leadingOverlapFrames(
            presentation: 10.0, decodedEnd: 10.05, sampleRate: 44_100, frames: 4_410), 2_205)
        XCTAssertEqual(AutomixAudioDecoder.leadingOverlapFrames(
            presentation: 10.0, decodedEnd: 9.95, sampleRate: 44_100, frames: 4_410), 0)
        XCTAssertEqual(AutomixAudioDecoder.leadingOverlapFrames(
            presentation: 10.0, decodedEnd: 10.5, sampleRate: 44_100, frames: 4_410), 4_410,
            "a buffer wholly behind the sink's end is dropped")
        XCTAssertEqual(AutomixAudioDecoder.leadingOverlapFrames(
            presentation: .infinity, decodedEnd: 10.0, sampleRate: 44_100, frames: 4_410), 0)
        XCTAssertEqual(AutomixAudioDecoder.leadingOverlapFrames(
            presentation: 10.0, decodedEnd: nil, sampleRate: 44_100, frames: 4_410), 0,
            "the first read has nothing to overlap")
        XCTAssertEqual(AutomixAudioDecoder.leadingOverlapFrames(
            presentation: 0, decodedEnd: .greatestFiniteMagnitude, sampleRate: .greatestFiniteMagnitude,
            frames: 4_410), 4_410,
            "a corrupt rate saturates to the whole buffer instead of trapping")
    }

    func testAudioRecoveredFromAPartialFileStaysOnItsTimeline() async throws {
        // Clicks every half second over a tone bed (so the AAC payload, not the header's padding,
        // is what the cut lands in), cut at 60%: the reader fails partway and the rest is re-read
        // in short ranges, which must line up with what came before.
        let rate = 44_100.0
        var samples = [Float](repeating: 0, count: Int(30 * rate))
        SyntheticAudio.addTone(into: &samples, frequency: 220, start: 0, seconds: 30, sampleRate: rate, gain: 0.15)
        for click in stride(from: 0.25, to: 30, by: 0.5) {
            SyntheticAudio.addTone(into: &samples, frequency: 3_000, start: click, seconds: 0.004, sampleRate: rate, gain: 0.8)
        }
        let whole = directory.appendingPathComponent("clicks.m4a")
        try SyntheticAudio.write(mono: samples, sampleRate: rate, to: whole)
        let data = try Data(contentsOf: whole)
        let head = directory.appendingPathComponent("clicks-head.m4a")
        try data.prefix(Int(Double(data.count) * 0.6)).write(to: head)

        let pcm = try await XCTUnwrapAsync(await AutomixAudioDecoder.decodeMono(head))
        XCTAssertGreaterThan(pcm.durationSeconds, 12, "the recovery pass reaches close to the cut")
        var checked = 0
        for click in stride(from: 0.25, to: pcm.durationSeconds - 0.5, by: 0.5) {
            // The loudest sample within 50 ms of where the click was written.
            let centre = Int((click - pcm.startSeconds) * pcm.sampleRate)
            let window = max(0, centre - 2205)..<min(pcm.samples.count, centre + 2205)
            guard let peak = window.max(by: { abs(pcm.samples[$0]) < abs(pcm.samples[$1]) }) else { continue }
            let found = pcm.startSeconds + Double(peak) / pcm.sampleRate
            XCTAssertEqual(found, click + 0.002, accuracy: 0.004, "click at \(click)s")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 20)
    }

    func testRemoteAssetsAreFetchedThenDecoded() async throws {
        let url = try stereoTones(extension: "m4a")
        let body = try Data(contentsOf: url)
        let session = StubURLProtocol.session { request in
            XCTAssertEqual(request.url?.host, "cdn.example.com")
            return (200, ["Content-Type": "audio/mp4"], body)
        }
        let fetcher = AutomixRemoteAudioFetcher(session: session, directory: directory)
        let remote = try XCTUnwrap(URL(string: "https://cdn.example.com/audio/stream"))
        let pcm = try await XCTUnwrapAsync(await AutomixAudioDecoder.decodeStereo(remote, fetcher: fetcher))
        XCTAssertEqual(pcm.durationSeconds, 4, accuracy: 0.1)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("automix-") }
        XCTAssertTrue(leftovers.isEmpty, "the temporary copy is removed after decoding")
    }

    func testRemoteFetchAsksForOnlyTheOpeningWhenBounded() async throws {
        let recorder = RangeRecorder()
        let session = StubURLProtocol.session { request in
            recorder.range = request.value(forHTTPHeaderField: "Range")
            return (206, ["Content-Type": "audio/mpeg"], Data(repeating: 1, count: 16))
        }
        let fetcher = AutomixRemoteAudioFetcher(session: session, directory: directory, maxBytes: 1024)
        let local = try await fetcher.localCopy(of: try XCTUnwrap(URL(string: "https://cdn.example.com/a")))
        XCTAssertEqual(recorder.range, "bytes=0-1023")
        XCTAssertEqual(local.pathExtension, "mp3", "the MIME type supplies the extension AVFoundation needs")
    }

    func testRemoteFetchSendsTheStreamsHeadersAndPatchesItsOpening() async throws {
        let body = Data((0..<4096).map { UInt8($0 % 251) })
        let recorder = HeaderRecorder()
        let session = StubURLProtocol.session { request in
            recorder.headers = request.allHTTPHeaderFields ?? [:]
            return (200, ["Content-Type": "audio/mp4"], body)
        }
        let patches = PatchCounter()
        let fetcher = AutomixRemoteAudioFetcher(
            session: session,
            directory: directory,
            headers: ["Origin": "https://music.youtube.com", "X-Goog-Visitor-Id": "abc"],
            patchHead: { data in
                patches.count += 1
                // What YouTubeMP4InitSegment.patchDurations does in miniature: header bytes zeroed
                // in place, length unchanged.
                data.replaceSubrange(8..<12, with: [0, 0, 0, 0])
            }
        )
        let local = try await fetcher.localCopy(of: try XCTUnwrap(URL(string: "https://rr1.googlevideo.com/videoplayback?itag=140")))
        XCTAssertEqual(recorder.headers["Origin"], "https://music.youtube.com")
        XCTAssertEqual(recorder.headers["X-Goog-Visitor-Id"], "abc")
        XCTAssertEqual(local.pathExtension, "mp4", "googlevideo URLs have no extension; the MIME type supplies one")
        XCTAssertEqual(patches.count, 1)
        let written = try Data(contentsOf: local)
        XCTAssertEqual(written.count, body.count)
        XCTAssertEqual(Array(written[8..<12]), [0, 0, 0, 0])
        XCTAssertEqual(written[0..<8], body[0..<8])
        XCTAssertEqual(written[12...], body[12...])
    }

    func testAPatchThatChangesNothingLeavesTheCopyAlone() async throws {
        let body = Data(repeating: 7, count: 512)
        let session = StubURLProtocol.session { _ in (200, ["Content-Type": "audio/mpeg"], body) }
        let fetcher = AutomixRemoteAudioFetcher(session: session, directory: directory, patchHead: { _ in })
        let local = try await fetcher.localCopy(of: try XCTUnwrap(URL(string: "https://cdn.example.com/a.mp3")))
        XCTAssertEqual(try Data(contentsOf: local), body)
    }

    func testRemoteErrorsAreReported() async throws {
        let session = StubURLProtocol.session { _ in (404, [:], Data()) }
        let fetcher = AutomixRemoteAudioFetcher(session: session, directory: directory)
        do {
            _ = try await fetcher.localCopy(of: try XCTUnwrap(URL(string: "https://cdn.example.com/gone.mp3")))
            XCTFail("expected an error")
        } catch let error as AutomixRemoteAudioFetcher.FetchError {
            XCTAssertEqual(error, .httpStatus(404))
        }
        let decoded = await AutomixAudioDecoder.decodeMono(try XCTUnwrap(URL(string: "https://cdn.example.com/gone.mp3")), fetcher: fetcher)
        XCTAssertNil(decoded)
    }
}

private final class RangeRecorder: @unchecked Sendable {
    var range: String?
}

final class HeaderRecorder: @unchecked Sendable {
    var headers: [String: String] = [:]
}

final class PatchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// `XCTUnwrap` for an async-produced optional.
func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let resolved = try await value()
    return try XCTUnwrap(resolved, file: file, line: line)
}

/// A URLProtocol stub for tests that must not touch the network.
final class StubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> (Int, [String: String], Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func session(_ handler: @escaping Handler) -> URLSession {
        let token = UUID().uuidString
        lock.lock()
        handlers[token] = handler
        lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Stub-Token": token]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let token = request.value(forHTTPHeaderField: "X-Stub-Token") ?? ""
        Self.lock.lock()
        let handler = Self.handlers[token]
        Self.lock.unlock()
        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (status, headers, body) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
