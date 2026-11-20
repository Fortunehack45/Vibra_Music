import XCTest
@testable import VibraMusicCore

/// The stream contract. Format cases are ported from SourcesTest.kt ("Format reporting").
final class ResolvedStreamTests: XCTestCase {
    // MARK: StreamFormat

    func testLosslessIsDecidedByCodecNotBitrate() {
        XCTAssertEqual(StreamFormat(codec: "flac", kbps: 900).isLossless, true)
        XCTAssertEqual(StreamFormat(codec: "alac").isLossless, true)
        XCTAssertEqual(StreamFormat(codec: "opus", sampleRateHz: 192_000).isLossless, false, "a high rate doesn't rescue a lossy codec")
        XCTAssertNil(StreamFormat().isLossless, "unknown stays unknown rather than defaulting to no")
        XCTAssertEqual(StreamFormat(codec: "FLAC").isLossless, true, "codec names are lowercased")
    }

    func testSummaryStatesDepthAndRateAndDropsBitrateWhenLossless() {
        XCTAssertEqual(StreamFormat(codec: "flac", kbps: 4_608, sampleRateHz: 192_000, bitDepth: 24).summary, "FLAC · 24-bit · 192 kHz")
        XCTAssertEqual(StreamFormat(codec: "mp3", kbps: 320, sampleRateHz: 44_100).summary, "MP3 · 44.1 kHz · 320 kbps")
        XCTAssertEqual(StreamFormat().summary, "Unknown format")
    }

    func testDolbyAtmosIsADistinctPremiumCodec() {
        let atmos = StreamFormat(codec: "eac3-joc")
        XCTAssertTrue(atmos.isDolbyAtmos)
        XCTAssertEqual(atmos.isLossless, false)
        XCTAssertEqual(atmos.summary, "Dolby Atmos")
    }

    func testHiResIsLosslessAboveCDResolution() {
        XCTAssertTrue(StreamFormat(codec: "flac", sampleRateHz: 96_000, bitDepth: 24).isHiRes)
        XCTAssertFalse(StreamFormat(codec: "flac", sampleRateHz: 44_100, bitDepth: 16).isHiRes)
        XCTAssertFalse(StreamFormat(codec: "aac", sampleRateHz: 96_000).isHiRes)
    }

    // MARK: ResolvedStream

    func testRoundTripsThroughJSON() throws {
        let stream = ResolvedStream(
            url: URL(string: "https://rr1---sn.googlevideo.com/videoplayback?expire=1700000000&itag=140")!,
            origin: .youtube,
            mimeType: "audio/mp4; codecs=\"mp4a.40.2\"",
            format: StreamFormat(codec: "aac", kbps: 128, sampleRateHz: 44_100, channels: 2),
            headers: ["User-Agent": VibraMusicHTTP.UserAgent.chromeDesktop],
            loudnessDb: -7.5,
            contentLength: 3_456_789,
            expiresAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 213,
            belowRequest: true,
            sourceConfigId: nil
        )
        XCTAssertEqual(try JSONDecoder().decode(ResolvedStream.self, from: JSONEncoder().encode(stream)), stream)
    }

    func testReadsGooglevideoExpiry() {
        let url = URL(string: "https://rr1---sn.googlevideo.com/videoplayback?expire=1700000000&itag=140")!
        XCTAssertEqual(ResolvedStream.expiry(in: url), Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(ResolvedStream.expiry(in: URL(string: "https://example.com/a.flac")!))
    }

    func testExpiryUsesASafetyMargin() {
        let now = Date(timeIntervalSince1970: 1_000)
        let stream = ResolvedStream(url: URL(string: "https://x/a")!, origin: .addon, expiresAt: now.addingTimeInterval(30))
        XCTAssertTrue(stream.isExpired(at: now), "30 s left is inside the default 60 s margin")
        XCTAssertFalse(stream.isExpired(at: now, margin: 10))
        XCTAssertFalse(ResolvedStream(url: URL(string: "https://x/a")!, origin: .local).isExpired(), "unknown expiry never expires")
    }

    func testRecognisesHLS() {
        XCTAssertTrue(ResolvedStream(url: URL(string: "https://x/master.m3u8")!, origin: .youtube).isHLS)
        XCTAssertTrue(ResolvedStream(url: URL(string: "https://x/manifest")!, origin: .youtube, mimeType: "application/x-mpegURL").isHLS)
        XCTAssertFalse(ResolvedStream(url: URL(string: "https://x/a.flac")!, origin: .addon, mimeType: "audio/flac").isHLS)
    }

    func testOriginsMapToSourceKinds() {
        XCTAssertEqual(StreamOrigin.youtube.sourceKind, .youtube)
        XCTAssertEqual(StreamOrigin.jioSaavn.sourceKind, .jioSaavn)
        XCTAssertNil(StreamOrigin.local.sourceKind)
        XCTAssertNil(StreamOrigin.networkShare.sourceKind)
    }

    // MARK: StreamResolving

    private struct RecordingResolver: StreamResolving {
        let seen = RequestBox()
        func resolveStream(for song: Song, request: StreamRequest) async throws -> ResolvedStream {
            seen.set(request)
            return ResolvedStream(url: URL(string: "https://example.com/\(song.videoId)")!, origin: .youtube)
        }
    }

    private final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: StreamRequest?
        func set(_ request: StreamRequest) { lock.withLock { value = request } }
        var request: StreamRequest? { lock.withLock { value } }
    }

    func testTheMaxKbpsConvenienceMapsToARequest() async throws {
        let resolver = RecordingResolver()
        let song = Song(videoId: "v", title: "T", artist: "A")
        let capped = try await resolver.resolveStream(for: song, maxKbps: 64)
        XCTAssertEqual(capped.url.absoluteString, "https://example.com/v")
        XCTAssertEqual(resolver.seen.request?.tier, .capped(kbps: 64))
        XCTAssertEqual(resolver.seen.request?.permittedSources, [.youtube])
        _ = try await resolver.resolveStream(for: song, maxKbps: nil)
        XCTAssertEqual(resolver.seen.request?.tier, .lossless)
    }
}
