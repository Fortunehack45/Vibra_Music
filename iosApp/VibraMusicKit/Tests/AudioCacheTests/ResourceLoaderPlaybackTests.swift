import AVFoundation
import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import AudioCache

/// AVFoundation integration on the Mac host: a real audio file served through the stub, opened
/// with an `AVURLAsset` on the cache's resource loader, then opened again with the network gone.
final class ResourceLoaderPlaybackTests: XCTestCase {
    private func tone(_ name: String, seconds: Double) throws -> Data {
        let directory = try makeTemporaryDirectory()
        let url = directory.appending(path: name)
        try writeTone(to: url, seconds: seconds)
        return try Data(contentsOf: url)
    }

    func testM4AOpensThroughTheLoaderAndReopensOffline() async throws {
        let body = try tone("tone.m4a", seconds: 20)
        let server = RangeServer()
        let url = googlevideoURL(client: "ANDROID_VR", length: body.count)
        server.host(body, at: url, mimeType: "audio/mp4")
        let directory = try makeTemporaryDirectory()
        let key = AudioCacheKey.youtube(videoId: "tone")
        let headers = ["User-Agent": "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"]
        let cache = try makeCache(directory: directory)
        let source = HTTPAudioSource(
            stream: stream(url, length: body.count, mimeType: "audio/mp4; codecs=\"mp4a.40.2\"", headers: headers),
            session: server.session,
            chunkBytes: 64 * 1_024
        )

        let asset = cache.makeAsset(for: key, source: source)
        XCTAssertEqual(asset.url.scheme, AudioStreamCache.urlScheme)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 20, accuracy: 0.1)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)

        XCTAssertFalse(server.requests.isEmpty)
        for request in server.requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), headers["User-Agent"])
            let range = try XCTUnwrap(request.value(forHTTPHeaderField: "Range").flatMap(RangeServer.parseRange))
            XCTAssertLessThanOrEqual(range.count, 64 * 1_024, "no range larger than the chunk size")
        }

        // Only what loading the duration read is on disk (AVFoundation cancels its whole-file
        // request once it has the header, which stops that fetch). The app is later relaunched.
        await eventually { !(await cache.store.isFetching(key)) }
        await cache.flush()

        // The network goes. A new asset on the same cache, and one on a fresh cache over the same
        // directory, both open with the source still wired in and failing: the header comes off
        // disk, and a speculative read past it waits out its retries instead of failing the asset.
        server.offline = true
        let again = try await cache.makeAsset(for: key, source: source).load(.duration)
        XCTAssertEqual(again.seconds, 20, accuracy: 0.1)
        let reopened = try makeCache(directory: directory)
        let offlineAsset = reopened.makeAsset(for: key, source: source)
        let offlineDuration = try await offlineAsset.load(.duration)
        XCTAssertEqual(offlineDuration.seconds, 20, accuracy: 0.1)
    }

    func testReadAHoleOfflineIsRetriedThenFails() async throws {
        let cache = try makeCache()
        let source = MemoryAudioSource(patternData(count: 3_000_000))
        let key = AudioCacheKey.youtube(videoId: "hole")
        // The opening is cached; the network goes before anything else is.
        _ = try await readThroughCache(cache, key: key, source: source, range: 0..<1_000)
        await eventually { !(await cache.store.isFetching(key)) }
        source.failing = true
        let readsBefore = source.reads.count

        let loader = AudioCacheResourceLoader(key: key, source: source, store: cache.store, retryDelays: [.milliseconds(20), .milliseconds(20)])
        do {
            try await loader.serveBytes(2_000_000..<2_100_000) { _ in }
            XCTFail("a hole can't be read with the network gone")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
        XCTAssertEqual(source.reads.count - readsBefore, 3, "asked once, then once per retry")
        XCTAssertTrue(AudioCacheResourceLoader.isTransientNetworkError(URLError(.networkConnectionLost)))
        XCTAssertFalse(AudioCacheResourceLoader.isTransientNetworkError(AudioCacheError.httpStatus(403, url: URL(string: "https://x.test")!)))
    }

    func testReadingResumesWhenTheNetworkReturnsWithinTheRetries() async throws {
        let cache = try makeCache()
        let source = MemoryAudioSource(patternData(count: 3_000_000))
        let key = AudioCacheKey.youtube(videoId: "blip")
        _ = try await cache.store.contentInfo(for: key, source: source)
        source.failing = true
        let loader = AudioCacheResourceLoader(key: key, source: source, store: cache.store, retryDelays: [.milliseconds(100), .milliseconds(100)])
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            source.failing = false
        }

        var received = Data()
        try await loader.serveBytes(1_000_000..<1_200_000) { received.append($0) }

        XCTAssertEqual(received, source.data.subdata(in: 1_000_000..<1_200_000))
    }

    private func lines(about trackID: String) -> [String] {
        TrackLog.shared.heldLines.filter { $0.track == trackID }.map(\.text)
    }

    /// A -1005 partway through a read. The read carries on from the byte reached and gets
    /// every byte; nothing ends where the bytes stopped.
    func testAConnectionDroppedMidReadResumesAtTheByteReached() async throws {
        let cache = try makeCache()
        let source = DroppingAudioSource(patternData(count: 3_000_000), dropAt: 1_200_000, drops: 1)
        let key = AudioCacheKey.youtube(videoId: "drop279once")
        let loader = AudioCacheResourceLoader(key: key, source: source, store: cache.store, retryDelays: [.milliseconds(20), .milliseconds(20)])

        var received = Data()
        try await loader.serveBytes(1_000_000..<1_400_000) { received.append($0) }

        XCTAssertEqual(received, source.data.subdata(in: 1_000_000..<1_400_000), "every byte")
        XCTAssertEqual(source.reads.map(\.lowerBound).filter { $0 >= 1_000_000 }, [1_000_000, 1_200_000], "the retry asks from the byte reached")
        let length = await cache.contentLength(of: key)
        XCTAssertEqual(length, 3_000_000, "the known length is unchanged")
        let log = lines(about: "drop279once")
        XCTAssertTrue(log.contains { $0.contains("[1000000, 1400000) at 1200000") && $0.contains("retry 1 of 2") }, "\(log)")
        XCTAssertTrue(log.contains { $0.contains("[1000000, 1400000) resumed at 1200000 after 1 retry") }, "\(log)")
    }

    /// A connection that keeps dropping fails the read with its error once the retries are
    /// spent. It never returns as if the resource ended where the bytes stopped.
    func testAConnectionThatKeepsDroppingFailsTheReadRatherThanEndingIt() async throws {
        let cache = try makeCache()
        let source = DroppingAudioSource(patternData(count: 3_000_000), dropAt: 1_200_000, drops: .max)
        let key = AudioCacheKey.youtube(videoId: "drop279always")
        let loader = AudioCacheResourceLoader(key: key, source: source, store: cache.store, retryDelays: [.milliseconds(20), .milliseconds(20)])

        var received = Data()
        do {
            try await loader.serveBytes(1_000_000..<1_400_000) { received.append($0) }
            XCTFail("a read that can't be finished must not return as finished")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }

        XCTAssertEqual(received, source.data.subdata(in: 1_000_000..<1_200_000), "what arrived, and nothing past it")
        XCTAssertEqual(source.reads.filter { $0.lowerBound >= 1_000_000 }.count, 3, "asked once, then once per retry")
        let length = await cache.contentLength(of: key)
        XCTAssertEqual(length, 3_000_000, "the known length is unchanged")
        let log = lines(about: "drop279always")
        XCTAssertTrue(log.contains { $0.contains("[1000000, 1400000) gave up at 1200000 after 2 retries") }, "\(log)")
    }

    /// AVFoundation often has two requests waiting on the same bytes. Through a drop and its
    /// retries they share the fetches: no byte is asked of the source twice.
    func testTwoRequestsThroughOneDropFetchEachByteOnce() async throws {
        let cache = try makeCache()
        let source = DroppingAudioSource(patternData(count: 3_000_000), dropAt: 1_200_000, drops: 1)
        let key = AudioCacheKey.youtube(videoId: "drop279twice")
        let loader = AudioCacheResourceLoader(key: key, source: source, store: cache.store, retryDelays: [.milliseconds(50), .milliseconds(50)])

        async let first = Self.collect(loader, 1_000_000..<1_400_000)
        async let second = Self.collect(loader, 1_000_000..<1_300_000)
        let (a, b) = try await (first, second)

        XCTAssertEqual(a, source.data.subdata(in: 1_000_000..<1_400_000))
        XCTAssertEqual(b, source.data.subdata(in: 1_000_000..<1_300_000))
        XCTAssertEqual(source.reads.map(\.lowerBound).filter { $0 >= 1_000_000 }, [1_000_000, 1_200_000], "one fetch before the drop, one after")
    }

    private static func collect(_ loader: AudioCacheResourceLoader, _ range: Range<Int64>) async throws -> Data {
        var data = Data()
        try await loader.serveBytes(range) { data.append($0) }
        return data
    }

    /// A retry that ends because nobody wants the bytes any more (a skip) says so: every retry's
    /// lines end in how it ended.
    func testARetryCancelledByASkipIsLogged() async throws {
        let cache = try makeCache()
        let source = DroppingAudioSource(patternData(count: 3_000_000), dropAt: 1_200_000, drops: .max)
        let key = AudioCacheKey.youtube(videoId: "drop279skip")
        let loader = AudioCacheResourceLoader(key: key, source: source, store: cache.store, retryDelays: [.seconds(30)])

        let read = Task { try await loader.serveBytes(1_000_000..<1_400_000) { _ in } }
        await eventually { self.lines(about: "drop279skip").contains { $0.contains("retry 1 of 1") } }
        read.cancel()
        let result = await read.result

        XCTAssertThrowsError(try result.get())
        let log = lines(about: "drop279skip")
        XCTAssertTrue(log.contains { $0.contains("[1000000, 1400000) at 1200000: cancelled while retrying") }, "\(log)")
    }

    func testFullyCachedTrackDecodesCompletelyInAirplaneMode() async throws {
        let body = try tone("song.m4a", seconds: 12)
        let server = RangeServer()
        let url = googlevideoURL(client: "IOS", length: body.count)
        server.host(body, at: url, mimeType: "audio/mp4")
        let key = AudioCacheKey.youtube(videoId: "song")
        let cache = try makeCache()
        let source = HTTPAudioSource(stream: stream(url, length: body.count), session: server.session)

        // Played once, online.
        let online = try await decodeAllFrames(of: cache.makeAsset(for: key, source: source))
        XCTAssertEqual(Double(online), 12 * 44_100, accuracy: 4_096)
        await eventually { await cache.isFullyCached(key) }

        // Airplane mode: no source at all, and the network failing for good measure.
        server.offline = true
        let offline = try await decodeAllFrames(of: cache.makeAsset(for: key, source: nil))
        XCTAssertEqual(offline, online)
    }

    func testFLACContentTypeReachesAVFoundation() async throws {
        let body = try tone("tone.flac", seconds: 3)
        XCTAssertEqual(AudioContentType.sniff(body), AudioContentType.flac)
        let server = RangeServer()
        let url = URL(string: "https://addon.example.com/stream/tone")!
        server.host(body, at: url, mimeType: "audio/flac")
        let cache = try makeCache()
        let key = AudioCacheKey.source("addon", track: "tone")
        let source = HTTPAudioSource(stream: stream(url, length: body.count, mimeType: "audio/flac"), session: server.session)

        let asset = cache.makeAsset(for: key, source: source)
        let duration = try await asset.load(.duration)

        XCTAssertEqual(duration.seconds, 3, accuracy: 0.05)
        let info = try await cache.store.contentInfo(for: key, source: nil)
        XCTAssertEqual(info.contentType, AudioContentType.flac)
    }

    /// Precise timing makes the player walk a FLAC's frames before it plays, so a play from the top
    /// doesn't ask for it; an open landing mid-song does, over the same cache entry.
    func testAFLACIsPreciselyTimedOnlyWhenAsked() async throws {
        let body = try tone("tone.flac", seconds: 3)
        let server = RangeServer()
        let url = URL(string: "https://addon.example.com/stream/tone")!
        server.host(body, at: url, mimeType: "audio/flac")
        let cache = try makeCache()
        let source = HTTPAudioSource(stream: stream(url, length: body.count, mimeType: "audio/flac"), session: server.session)

        let plain = cache.makeAsset(for: .source("addon", track: "tone"), source: source)
        let plainIsPrecise = try await plain.load(.providesPreciseDurationAndTiming)
        XCTAssertFalse(plainIsPrecise)

        let precise = AudioStreamCache.preciselyTimed(plain)
        let preciseIsPrecise = try await precise.load(.providesPreciseDurationAndTiming)
        XCTAssertTrue(preciseIsPrecise)
        let duration = try await precise.load(.duration)
        XCTAssertEqual(duration.seconds, 3, accuracy: 0.05, "read through the same loader")
    }

    /// Precise timing looks at the end of the file before it opens; a copy whose end never arrived
    /// still opens with the network gone, and plays what it has.
    func testAFLACMissingItsEndOpensOffline() async throws {
        let body = try tone("long.flac", seconds: 120)
        let headBytes = 64 * 1_024
        XCTAssertGreaterThan(body.count, headBytes + 128 * 1_024, "the end has to be out of the head's reach")
        let server = RangeServer()
        let url = URL(string: "https://addon.example.com/stream/long")!
        server.host(body, at: url, mimeType: "audio/flac")
        let cache = try makeCache()
        let key = AudioCacheKey.source("addon", track: "long")
        let source = HTTPAudioSource(stream: stream(url, length: body.count, mimeType: "audio/flac"), session: server.session, chunkBytes: Int64(headBytes))
        _ = try await readThroughCache(cache, key: key, source: source, range: 0..<Int64(headBytes))
        await eventually { !(await cache.store.isFetching(key)) }
        server.offline = true

        let tracks = try await AudioStreamCache.preciselyTimed(cache.makeAsset(for: key, source: source)).loadTracks(withMediaType: .audio)

        XCTAssertEqual(tracks.count, 1)
    }

    func testUntypedStreamIsSniffed() async throws {
        let body = try tone("mystery.m4a", seconds: 2)
        let server = RangeServer()
        let url = URL(string: "https://dav.example.com/music/mystery")!
        server.host(body, at: url, mimeType: "application/octet-stream")
        let cache = try makeCache()
        let key = AudioCacheKey.source("webdav", track: "mystery")
        let source = HTTPAudioSource(stream: stream(url, length: nil, mimeType: nil), session: server.session)

        let duration = try await cache.makeAsset(for: key, source: source).load(.duration)

        XCTAssertEqual(duration.seconds, 2, accuracy: 0.1)
        let info = try await cache.store.contentInfo(for: key, source: nil)
        XCTAssertEqual(info.contentType, AudioContentType.mpeg4Audio)
    }

    func testCustomDataSourcePlugsIn() async throws {
        let body = try tone("smb.m4a", seconds: 4)
        let cache = try makeCache()
        let key = AudioCacheKey.source("smb", track: "share/smb.m4a")
        let source = MemoryAudioSource(body, mimeType: "audio/mp4", rangeBytes: 32 * 1_024)

        let duration = try await cache.makeAsset(for: key, source: source).load(.duration)

        XCTAssertEqual(duration.seconds, 4, accuracy: 0.1)
        XCTAssertFalse(source.reads.isEmpty)
        XCTAssertTrue(source.reads.allSatisfy { $0.count <= 32 * 1_024 }, "never asked for more than the source's range size")
        XCTAssertEqual(source.infoCalls, 1)
    }

    func testLocalFileIsServedWithoutCaching() async throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appending(path: "download.m4a")
        try writeTone(to: file, seconds: 3)
        let cache = try makeCache()
        let key = AudioCacheKey.youtube(videoId: "downloaded")

        let duration = try await cache.makeAsset(for: key, source: FileAudioSource(url: file)).load(.duration)

        XCTAssertEqual(duration.seconds, 3, accuracy: 0.1)
        let usage = await cache.usage()
        XCTAssertEqual(usage.cachedBytes, 0, "a file on this device is not copied into the cache")
    }

    func testResolvedFileAndHLSStreamsBypassTheCache() throws {
        let cache = try makeCache()
        let file = ResolvedStream(url: URL(fileURLWithPath: "/tmp/x.m4a"), origin: .local)
        let hls = ResolvedStream(url: URL(string: "https://example.com/master.m3u8")!, origin: .youtube, headers: ["User-Agent": "UA"])
        let progressive = stream(googlevideoURL(length: 100), length: 100)

        XCTAssertEqual(cache.makeAsset(for: .youtube(videoId: "f"), stream: file).url, file.url)
        XCTAssertEqual(cache.makeAsset(for: .youtube(videoId: "h"), stream: hls).url, hls.url)
        XCTAssertEqual(cache.makeAsset(for: .youtube(videoId: "p"), stream: progressive).url.scheme, AudioStreamCache.urlScheme)
    }

    func testAssetURLRoundTripsTheKey() {
        for key in [AudioCacheKey.youtube(videoId: "abc_-123"), .substitute(videoId: "x", atmosAllowed: false), .source("addon 1", track: "a/b?c#d")] {
            let url = AudioStreamCache.url(for: key)
            XCTAssertEqual(url.scheme, "vibramusic-cache")
            XCTAssertEqual(AudioStreamCache.key(from: url), key)
        }
        XCTAssertNil(AudioStreamCache.key(from: URL(string: "https://example.com/x")!))
    }

    func testOfflineAssetForUncachedTrackFailsToLoad() async throws {
        let cache = try makeCache()
        let asset = cache.makeAsset(for: .youtube(videoId: "nothing"), source: nil)
        do {
            _ = try await asset.load(.duration)
            XCTFail("nothing to play")
        } catch {
            // AVFoundation wraps the loader's error; failing is what matters.
        }
    }
}

/// A connection that drops: bytes arrive in pieces, and a read across `dropAt` (while drops are
/// left) delivers what comes before it, then fails with -1005.
private final class DroppingAudioSource: AudioRangeDataSource, @unchecked Sendable {
    let data: Data
    let dropAt: Int64
    private let lock = NSLock()
    private var dropsLeft: Int
    private var _reads: [Range<Int64>] = []

    init(_ data: Data, dropAt: Int64, drops: Int) {
        self.data = data
        self.dropAt = dropAt
        self.dropsLeft = drops
    }

    var reads: [Range<Int64>] { lock.withLock { _reads } }

    func contentInfo() async throws -> AudioContentInfo {
        AudioContentInfo(contentLength: Int64(data.count), mimeType: "audio/mp4")
    }

    func read(_ range: Range<Int64>) async throws -> Data {
        var out = Data()
        for try await piece in stream(range) { out.append(piece) }
        return out
    }

    func stream(_ range: Range<Int64>) -> AsyncThrowingStream<Data, Error> {
        let drops: Bool = lock.withLock {
            _reads.append(range)
            guard range.contains(dropAt), dropsLeft > 0 else { return false }
            dropsLeft -= 1
            return true
        }
        let end = drops ? dropAt : min(range.upperBound, Int64(data.count))
        let data = self.data
        return AsyncThrowingStream { continuation in
            var position = range.lowerBound
            while position < end {
                let next = min(end, position + 64 * 1_024)
                continuation.yield(data.subdata(in: Int(position)..<Int(next)))
                position = next
            }
            if drops {
                continuation.finish(throwing: URLError(.networkConnectionLost))
            } else {
                continuation.finish()
            }
        }
    }
}
