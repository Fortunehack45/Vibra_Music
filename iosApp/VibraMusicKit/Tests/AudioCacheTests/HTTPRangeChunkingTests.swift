import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import AudioCache

/// ChunkedDataSource and PlayerClient.rangeBytesFor: bounded ranges, per-client limits, headers,
/// and the ways a server can answer a range badly.
final class HTTPRangeChunkingTests: XCTestCase {
    private func gv(_ client: String, _ version: String = "1.0") -> URL {
        URL(string: "https://rr1---sn-abc.googlevideo.com/videoplayback?c=\(client)&cver=\(version)&clen=5000000")!
    }

    // Ported from PlayerClientRangeTest.

    func testGooglevideoRangesAreCappedAtOneMegabyte() {
        XCTAssertEqual(HTTPAudioSource.rangeBytes(for: gv("IOS")), 1_024 * 1_024)
        XCTAssertEqual(HTTPAudioSource.rangeBytes(for: gv("VISIONOS", "1.02")), 1_024 * 1_024)
        XCTAssertEqual(HTTPAudioSource.rangeBytes(for: gv("TVHTML5")), 1_024 * 1_024)
    }

    func testClientsRefusedPastAMegabyteGetHalfThat() {
        XCTAssertEqual(HTTPAudioSource.rangeBytes(for: gv("ANDROID_VR", "1.65.10")), 512 * 1_024)
        XCTAssertEqual(HTTPAudioSource.rangeBytes(for: gv("TVHTML5_SIMPLY")), 512 * 1_024)
        XCTAssertEqual(HTTPAudioSource.rangeBytes(for: gv("tvhtml5_simply_embedded_player")), 512 * 1_024)
    }

    func testNonGooglevideoHostsAreNotCapped() {
        XCTAssertEqual(HTTPAudioSource.rangeBytes(for: URL(string: "https://sp-ad-cf.audio.tidal.com/x.flac")!), .max)
        XCTAssertEqual(HTTPAudioSource.rangeBytes(for: URL(string: "not a url")!), .max)
    }

    func testClenIsTheDeclaredLength() {
        XCTAssertEqual(HTTPAudioSource.declaredLength(of: gv("IOS")), 5_000_000)
        XCTAssertNil(HTTPAudioSource.declaredLength(of: URL(string: "https://example.com/a.m4a")!))
    }

    // The captured live exchange.

    func testCapturedGooglevideoExchangeParses() throws {
        let fixture = try FixtureLoader(bundle: .module).decode(CapturedRange.self, from: "googlevideo_android_vr_range.json")
        let url = try XCTUnwrap(URL(string: fixture.url))
        XCTAssertEqual(HTTPAudioSource.rangeBytes(for: url), 512 * 1_024, "ANDROID_VR URLs must be fetched in 512 KB ranges")
        XCTAssertEqual(HTTPAudioSource.declaredLength(of: url), Int64(fixture.contentLength))
        let parsed = try XCTUnwrap(HTTPAudioSource.parseContentRange(fixture.rangeResponse.headers["Content-Range"]!))
        XCTAssertEqual(parsed.start, 0)
        XCTAssertEqual(parsed.end, 524_287)
        XCTAssertEqual(parsed.total, Int64(fixture.contentLength))
        XCTAssertEqual(fixture.oversizedRange.status, 403, "googlevideo refuses ANDROID_VR ranges past 512 KB")
        XCTAssertTrue(HTTPAudioSource.refusalCodes.contains(fixture.oversizedRange.status))
        XCTAssertEqual(AudioContentType.uti(mimeType: fixture.mimeType), AudioContentType.mpeg4Audio)
        XCTAssertEqual(AudioContentType.uti(mimeType: fixture.rangeResponse.headers["Content-Type"]), AudioContentType.mpeg4Audio)
        let prefix = Data(hex: fixture.prefixHex)
        XCTAssertEqual(AudioContentType.sniff(prefix), AudioContentType.mpeg4Audio, "YouTube's DASH-branded m4a")
        XCTAssertNotNil(ResolvedStream.expiry(in: url))
    }

    func testContentRangeParsing() {
        XCTAssertEqual(HTTPAudioSource.parseContentRange("bytes 100-199/1000")?.total, 1_000)
        XCTAssertNil(HTTPAudioSource.parseContentRange("bytes 100-199/*")?.total)
        XCTAssertEqual(HTTPAudioSource.parseContentRange("bytes 100-199/*")?.start, 100)
        XCTAssertNil(HTTPAudioSource.parseContentRange("items 1-2/3"))
        XCTAssertNil(HTTPAudioSource.parseContentRange("bytes 5-2/10"))
    }

    // Chunking against a stub.

    func testAndroidVRStreamIsFetchedInHalfMegabyteRanges() async throws {
        let server = RangeServer()
        let body = patternData(count: 1_300_000)
        let url = googlevideoURL(client: "ANDROID_VR", length: body.count)
        server.host(body, at: url)
        let source = HTTPAudioSource(stream: stream(url, length: body.count), session: server.session)

        let data = try await source.read(0..<Int64(body.count))

        XCTAssertEqual(data, body)
        XCTAssertEqual(server.ranges(), [0..<524_288, 524_288..<1_048_576, 1_048_576..<1_300_000])
        XCTAssertEqual(source.requestRangeBytes, 512 * 1_024)
    }

    func testIOSStreamIsFetchedInOneMegabyteRanges() async throws {
        let server = RangeServer()
        let body = patternData(count: 2_500_000)
        let url = googlevideoURL(client: "IOS", length: body.count)
        server.host(body, at: url)
        let source = HTTPAudioSource(stream: stream(url, length: body.count), session: server.session)

        let data = try await source.read(100..<2_200_000)

        XCTAssertEqual(data, body.subdata(in: 100..<2_200_000))
        XCTAssertEqual(server.ranges(), [100..<1_048_676, 1_048_676..<2_097_252, 2_097_252..<2_200_000])
    }

    func testChunkSizeIsAnUpperBoundEvenForGenerousClients() async throws {
        let server = RangeServer()
        let body = patternData(count: 300_000)
        let url = googlevideoURL(client: "IOS", length: body.count)
        server.host(body, at: url)
        let source = HTTPAudioSource(stream: stream(url, length: body.count), session: server.session, chunkBytes: 100_000)

        _ = try await source.read(0..<300_000)

        XCTAssertEqual(server.ranges().map(\.count), [100_000, 100_000, 100_000])
    }

    func testOtherHostsAreAskedInOneRequest() async throws {
        let server = RangeServer()
        let body = patternData(count: 3_000_000)
        let url = URL(string: "https://cdn.example.com/track.flac")!
        server.host(body, at: url, mimeType: "audio/flac")
        let source = HTTPAudioSource(stream: stream(url, length: body.count, mimeType: "audio/flac"), session: server.session)

        let data = try await source.read(0..<3_000_000)

        XCTAssertEqual(data, body)
        XCTAssertEqual(server.ranges(), [0..<3_000_000])
    }

    func testStreamHeadersAreForwardedOnEveryRange() async throws {
        let server = RangeServer()
        let body = patternData(count: 700_000)
        let url = googlevideoURL(client: "ANDROID_VR", length: body.count)
        server.host(body, at: url)
        let headers = [
            "User-Agent": "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
            "Origin": "https://www.youtube.com",
        ]
        let source = HTTPAudioSource(stream: stream(url, length: body.count, headers: headers), session: server.session)

        _ = try await source.read(0..<700_000)

        XCTAssertEqual(server.requests.count, 2)
        for request in server.requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), headers["User-Agent"])
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), headers["Origin"])
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        }
    }

    func testTruncatedRangeIsReopenedForTheRest() async throws {
        let server = RangeServer()
        server.maxBytesPerResponse = 200_000
        let body = patternData(count: 500_000)
        let url = googlevideoURL(client: "ANDROID_VR", length: body.count)
        server.host(body, at: url)
        let source = HTTPAudioSource(stream: stream(url, length: body.count), session: server.session)

        let data = try await source.read(0..<500_000)

        XCTAssertEqual(data, body)
        XCTAssertEqual(server.ranges().map(\.lowerBound), [0, 200_000, 400_000])
    }

    func testServerSendingNothingIsGivenUpOnAfterThreeRanges() async throws {
        let server = RangeServer()
        server.emptyBodies = true
        let body = patternData(count: 500_000)
        let url = googlevideoURL(client: "ANDROID_VR", length: body.count)
        server.host(body, at: url)
        let source = HTTPAudioSource(stream: stream(url, length: body.count), session: server.session)

        let data = try await source.read(0..<500_000)

        XCTAssertTrue(data.isEmpty)
        XCTAssertEqual(server.requests.count, HTTPAudioSource.maxEmptyRanges)
    }

    func testServerIgnoringRangesStillYieldsTheRightBytes() async throws {
        let server = RangeServer()
        server.ignoreRanges = true
        let body = patternData(count: 2_000_000)
        let url = URL(string: "https://files.example.com/song.m4a")!
        server.host(body, at: url)
        let source = HTTPAudioSource(stream: stream(url, length: body.count), session: server.session, chunkBytes: 256 * 1_024)

        let data = try await source.read(700_000..<1_500_000)

        XCTAssertEqual(data, body.subdata(in: 700_000..<1_500_000))
        XCTAssertEqual(server.requests.count, 1, "a server without range support must not be asked again per chunk")
    }

    func testContentInfoComesFromTheResolvedStreamWithoutARequest() async throws {
        let server = RangeServer()
        let url = googlevideoURL(client: "IOS", length: 4_025_466)
        let source = HTTPAudioSource(stream: stream(url, length: nil, mimeType: "audio/mp4; codecs=\"mp4a.40.2\""), session: server.session)

        let info = try await source.contentInfo()

        XCTAssertEqual(info.contentLength, 4_025_466, "clen is read off the URL")
        XCTAssertEqual(info.contentType, AudioContentType.mpeg4Audio)
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testContentInfoProbeIsReusedByTheFirstRead() async throws {
        let server = RangeServer()
        let body = patternData(count: 900_000)
        let url = URL(string: "https://addon.example.com/stream/42")!
        server.host(body, at: url, mimeType: "audio/flac")
        let source = HTTPAudioSource(stream: stream(url, length: nil, mimeType: nil), session: server.session)

        let info = try await source.contentInfo()
        let data = try await source.read(0..<900_000)

        XCTAssertEqual(info.contentLength, 900_000)
        XCTAssertEqual(info.mimeType, "audio/flac")
        XCTAssertEqual(info.contentType, AudioContentType.flac)
        XCTAssertEqual(data, body)
        XCTAssertEqual(server.ranges(), [0..<HTTPAudioSource.probeBytes, HTTPAudioSource.probeBytes..<900_000])
    }

    func testHLSIsRefused() async throws {
        let server = RangeServer()
        let hls = ResolvedStream(url: URL(string: "https://manifest.googlevideo.com/api/manifest/hls_playlist/x/index.m3u8")!, origin: .youtube, mimeType: "application/x-mpegURL")
        let source = HTTPAudioSource(stream: hls, session: server.session)
        do {
            _ = try await source.contentInfo()
            XCTFail("HLS can't be cached by range")
        } catch {
            XCTAssertEqual(error as? AudioCacheError, .notProgressive)
        }
    }

    func testStoppingEarlyCancelsTheRestOfTheRange() async throws {
        let server = RangeServer()
        let body = patternData(count: 2_000_000)
        let url = googlevideoURL(client: "ANDROID_VR", length: body.count)
        server.host(body, at: url)
        let source = HTTPAudioSource(stream: stream(url, length: body.count), session: server.session)

        var received = 0
        for try await piece in source.stream(0..<2_000_000) {
            received += piece.count
            break
        }

        XCTAssertEqual(received, 512 * 1_024)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(server.requests.count, 1, "no further range after the reader stopped")
    }
}

private struct CapturedRange: Decodable {
    struct Response: Decodable {
        let status: Int
        let headers: [String: String]
    }

    struct Oversized: Decodable {
        let range: String
        let status: Int
    }

    let url: String
    let mimeType: String
    let contentLength: String
    let rangeResponse: Response
    let oversizedRange: Oversized
    let prefixHex: String
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            if let byte = UInt8(hex[index..<next], radix: 16) { bytes.append(byte) }
            index = next
        }
        self.init(bytes)
    }
}
