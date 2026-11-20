import AVFoundation
import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import AudioCache

/// Against real googlevideo. Skipped unless `VIBRAMUSIC_LIVE_TESTS=1`.
///
/// Streams are minted here with a bare `player` request rather than through StreamResolution,
/// which this module doesn't depend on: VISIONOS (what the resolver tries first, and the client
/// whose URLs serve the whole file) and ANDROID_VR 1.65.10 with a visitor id (whose URLs are only
/// served in ranges of 512 KB or less).
final class AudioCacheLiveTests: XCTestCase {
    private static let videoId = "dQw4w9WgXcQ"
    private let session = URLSession(configuration: VibraMusicHTTP.makeConfiguration())

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VIBRAMUSIC_LIVE_TESTS"] == "1", "set VIBRAMUSIC_LIVE_TESTS=1 to run live tests")
    }

    func testRealStreamIsCachedWholeAndReplaysInAirplaneMode() async throws {
        let minted = try await Self.mint(client: .visionOS, itag: 140, session: session)
        let expected = Double(minted.approxDurationMs) / 1_000
        let directory = try makeTemporaryDirectory()
        let key = AudioCacheKey.youtube(videoId: Self.videoId, rendition: "140")
        let cache = try makeCache(directory: directory)
        let source = HTTPAudioSource(stream: minted.stream, session: session)

        // Opened through the resource loader: the duration AVFoundation reports is the real one,
        // not twice it (the cache patched the init segment on the way to disk).
        let duration = try await cache.makeAsset(for: key, source: source).load(.duration).seconds
        XCTAssertEqual(duration, expected, accuracy: 0.5)

        let complete = await cache.cacheCompletely(key, source: source)
        XCTAssertTrue(complete)
        let length = await cache.contentLength(of: key)
        XCTAssertEqual(length, minted.stream.contentLength)
        XCTAssertFalse(source.requestedRanges.isEmpty)
        XCTAssertTrue(source.requestedRanges.allSatisfy { $0.count <= 1_024 * 1_024 }, "\(source.requestedRanges)")

        // The tail on disk is the tail googlevideo serves.
        let total = try XCTUnwrap(minted.stream.contentLength)
        let tailRange = (total - 65_536)..<total
        let direct = try await HTTPAudioSource(stream: minted.stream, session: session).read(tailRange)
        let cachedTail = try await readThroughCache(cache, key: key, source: nil, range: tailRange)
        XCTAssertEqual(cachedTail, direct)
        await cache.flush()

        // Airplane mode, after a relaunch: no source at all.
        let reopened = try makeCache(directory: directory)
        let offline = reopened.makeAsset(for: key, source: nil)
        let offlineDuration = try await offline.load(.duration).seconds
        XCTAssertEqual(offlineDuration, expected, accuracy: 0.5)
        let frames = try await decodeAllFrames(of: reopened.makeAsset(for: key, source: nil))
        XCTAssertEqual(Double(frames) / 44_100, expected, accuracy: 0.5, "the whole track decodes from disk")
        let usage = await reopened.usage()
        XCTAssertGreaterThanOrEqual(usage.cachedBytes, total)
        let freed = await reopened.clear()
        XCTAssertGreaterThanOrEqual(freed, total)
    }

    func testAndroidVRStreamIsReadInHalfMegabyteRangesWithItsHeaders() async throws {
        let minted = try await Self.mint(client: .androidVR, itag: 140, session: session)
        XCTAssertEqual(HTTPAudioSource.rangeBytes(for: minted.stream.url), 512 * 1_024)
        let cache = try makeCache()
        let key = AudioCacheKey.youtube(videoId: Self.videoId, rendition: "140")
        let source = HTTPAudioSource(stream: minted.stream, session: session)

        // ANDROID_VR URLs stop being served after roughly the first minute of audio, so the
        // opening megabyte is what's checked here.
        let opening = try await readThroughCache(cache, key: key, source: source, range: 0..<1_000_000)

        XCTAssertEqual(opening.count, 1_000_000)
        XCTAssertEqual(Array(opening[4..<8]), Array("ftyp".utf8))
        XCTAssertEqual(source.requestedRanges, [0..<524_288, 524_288..<1_048_576])
        await eventually { !(await cache.store.isFetching(key)) }
        let ranges = await cache.cachedRanges(of: key)
        XCTAssertEqual(ranges, [0..<1_048_576])
    }

    // MARK: Minting

    private enum Client {
        case visionOS
        case androidVR
    }

    private struct Minted {
        let stream: ResolvedStream
        let approxDurationMs: Int
    }

    private static func mint(client: Client, itag: Int, session: URLSession) async throws -> Minted {
        var context: [String: Any] = ["hl": "en", "gl": "US", "utcOffsetMinutes": 0]
        var headers: [String: String] = ["Content-Type": "application/json"]
        let userAgent: String
        let url: URL
        switch client {
        case .visionOS:
            userAgent = "com.google.visionos.youtube/1.02(RealityDevice14,1; U; CPU visionOS 25_6_0 like Mac OS X; US)"
            context.merge([
                "clientName": "VISIONOS", "clientVersion": "1.02", "clientScreen": "WATCH", "platform": "MOBILE",
                "deviceMake": "Apple", "deviceModel": "RealityDevice14,1", "osName": "visionOS", "osVersion": "25.6.0.23O471",
            ]) { $1 }
            headers["X-YouTube-Client-Name"] = "101"
            headers["X-YouTube-Client-Version"] = "1.02"
            headers["X-Goog-Api-Format-Version"] = "2"
            url = URL(string: "https://youtubei.googleapis.com/youtubei/v1/player?prettyPrint=false&t=\(UUID().uuidString.prefix(12))&id=\(videoId)")!
        case .androidVR:
            userAgent = "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"
            let visitorData = try await visitorData(session: session)
            context.merge([
                "clientName": "ANDROID_VR", "clientVersion": "1.65.10", "deviceMake": "Oculus", "deviceModel": "Quest 3",
                "osName": "Android", "osVersion": "12L", "androidSdkVersion": 32, "visitorData": visitorData,
            ]) { $1 }
            headers["X-YouTube-Client-Name"] = "28"
            headers["X-YouTube-Client-Version"] = "1.65.10"
            headers["X-Goog-Visitor-Id"] = visitorData
            url = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
        }
        context["userAgent"] = userAgent
        headers["User-Agent"] = userAgent
        let body: [String: Any] = [
            "context": ["client": context, "request": ["useSsl": true], "user": ["lockedSafetyMode": false]] as [String: Any],
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, _) = try await session.data(for: request)

        struct Player: Decodable {
            struct Status: Decodable { let status: String; let reason: String? }
            struct Streaming: Decodable { let adaptiveFormats: [Format] }
            struct Format: Decodable {
                let itag: Int
                let url: String?
                let mimeType: String
                let contentLength: String?
                let approxDurationMs: String?
            }
            let playabilityStatus: Status
            let streamingData: Streaming?
        }
        let player = try JSONDecoder().decode(Player.self, from: data)
        guard player.playabilityStatus.status == "OK",
              let format = player.streamingData?.adaptiveFormats.first(where: { $0.itag == itag }),
              let mediaURL = format.url.flatMap(URL.init(string:)) else {
            throw AudioCacheError.badResponse("\(client) player: \(player.playabilityStatus.status) \(player.playabilityStatus.reason ?? "")")
        }
        let stream = ResolvedStream(
            url: mediaURL,
            origin: .youtube,
            mimeType: format.mimeType,
            headers: ["User-Agent": userAgent],
            contentLength: format.contentLength.flatMap { Int64($0) },
            expiresAt: ResolvedStream.expiry(in: mediaURL)
        )
        return Minted(stream: stream, approxDurationMs: format.approxDurationMs.flatMap { Int($0) } ?? 0)
    }

    /// The music.youtube.com shell's `VISITOR_DATA`, which ANDROID_VR won't answer without.
    private static func visitorData(session: URLSession) async throws -> String {
        var request = URLRequest(url: URL(string: "https://music.youtube.com/")!)
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        let html = String(decoding: data, as: UTF8.self)
        guard let match = html.range(of: #""VISITOR_DATA":"([^"]+)""#, options: .regularExpression) else {
            throw AudioCacheError.badResponse("no VISITOR_DATA on music.youtube.com")
        }
        let raw = html[match].dropFirst(#""VISITOR_DATA":""#.count).dropLast()
        return String(raw).removingPercentEncoding ?? String(raw)
    }
}
