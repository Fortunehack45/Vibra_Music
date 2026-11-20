import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import AudioCache

/// Resolved URLs expire and get refused; the source re-mints them through the injected resolver
/// and reports the refusal, and the cache never resolves for bytes it already has.
final class ExpiredURLRefreshTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        private var refusals: [(URL, Int)] = []

        func next() -> Int { lock.withLock { value += 1; return value } }
        var count: Int { lock.withLock { value } }
        func refused(_ url: URL, _ code: Int) { lock.withLock { refusals.append((url, code)) } }
        var refused: [(URL, Int)] { lock.withLock { refusals } }
    }

    func testRefusedURLIsReMintedAndTheRangeAskedAgain() async throws {
        let server = RangeServer()
        let body = patternData(count: 600_000)
        let first = googlevideoURL(client: "ANDROID_VR", length: body.count, id: "first")
        let second = googlevideoURL(client: "ANDROID_VR", length: body.count, id: "second")
        server.host(body, at: first)
        server.host(body, at: second)
        let counter = Counter()
        let source = HTTPAudioSource(
            stream: stream(first, length: body.count),
            session: server.session,
            refresh: { counter.next(); return stream(second, length: body.count) },
            onRefused: { url, code in counter.refused(url, code) }
        )

        let head = try await source.read(0..<100_000)
        server.refuse(first, status: 403)
        let rest = try await source.read(100_000..<600_000)

        XCTAssertEqual(head + rest, body)
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(counter.refused.map(\.0), [first])
        XCTAssertEqual(counter.refused.map(\.1), [403])
        XCTAssertEqual(source.resolvedStream?.url, second)
        XCTAssertEqual(server.requests.last?.url, second)
    }

    func testRefusalWithoutAResolverSurfacesTheStatus() async throws {
        let server = RangeServer()
        let url = googlevideoURL(client: "IOS", length: 1_000)
        server.refuse(url, status: 410)
        let counter = Counter()
        let source = HTTPAudioSource(stream: stream(url, length: 1_000), session: server.session, onRefused: { counter.refused($0, $1) })

        do {
            _ = try await source.read(0..<1_000)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? AudioCacheError, .httpStatus(410, url: url))
        }
        XCTAssertEqual(counter.refused.map(\.1), [410])
    }

    /// A status other than 403/404/410 (a 503, a 429) fails the read, and the track's log says who
    /// refused it, as Android's ChunkedDataSource logs every refused open.
    func testAnyOtherRefusalIsLoggedAgainstTheTrack() async throws {
        let server = RangeServer()
        let url = googlevideoURL(client: "WEB_REMIX", length: 1_000, id: "busy")
        server.refuse(url, status: 503)
        let source = HTTPAudioSource(stream: stream(url, length: 1_000), session: server.session)

        do {
            _ = try await TrackLog.about("busy503") { try await source.read(0..<1_000) }
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? AudioCacheError, .httpStatus(503, url: url))
        }
        let log = TrackLog.shared.heldLines.filter { $0.track == "busy503" }.map(\.text)
        XCTAssertTrue(log.contains { $0.contains("refused (503) for WEB_REMIX") }, "\(log)")
    }

    func testReMintIsTriedOnceNotForever() async throws {
        let server = RangeServer()
        let url = googlevideoURL(client: "IOS", length: 1_000)
        server.refuse(url, status: 403)
        let counter = Counter()
        let source = HTTPAudioSource(stream: stream(url, length: 1_000), session: server.session, refresh: {
            counter.next()
            return stream(url, length: 1_000)
        })

        do {
            _ = try await source.read(0..<1_000)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? AudioCacheError, .httpStatus(403, url: url))
        }
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(server.requests.count, 2)
    }

    func testURLPastItsExpiryIsReMintedBeforeUse() async throws {
        let server = RangeServer()
        let body = patternData(count: 50_000)
        let stale = googlevideoURL(client: "IOS", length: body.count, id: "stale", expire: Date().addingTimeInterval(-10))
        let fresh = googlevideoURL(client: "IOS", length: body.count, id: "fresh")
        server.host(body, at: fresh)
        let counter = Counter()
        let source = HTTPAudioSource(stream: stream(stale, length: body.count), session: server.session, refresh: {
            counter.next()
            return stream(fresh, length: body.count)
        })

        let data = try await source.read(0..<50_000)

        XCTAssertEqual(data, body)
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(server.requests.map(\.url), [fresh], "the expired URL is never asked")
    }

    func testReMintedURLForADifferentFileIsNotSpliced() async throws {
        let server = RangeServer()
        let first = googlevideoURL(client: "IOS", length: 400_000, id: "a")
        let other = googlevideoURL(client: "IOS", length: 380_000, id: "b")
        server.host(patternData(count: 400_000), at: first)
        server.host(patternData(count: 380_000, seed: 9), at: other)
        let source = HTTPAudioSource(stream: stream(first, length: 400_000), session: server.session, refresh: {
            stream(other, length: 380_000)
        })
        _ = try await source.read(0..<10)
        server.refuse(first)

        do {
            _ = try await source.read(10..<400_000)
            XCTFail("a different file must not be read into the same entry")
        } catch {
            XCTAssertEqual(error as? AudioCacheError, .contentChanged(key: nil, expected: 400_000, actual: 380_000))
        }
    }

    func testLazySourceResolvesOnFirstUseOnly() async throws {
        let server = RangeServer()
        let body = patternData(count: 20_000)
        let url = googlevideoURL(client: "IOS", length: body.count)
        server.host(body, at: url)
        let counter = Counter()
        let source = HTTPAudioSource(session: server.session) {
            counter.next()
            return stream(url, length: body.count)
        }
        XCTAssertEqual(counter.count, 0)

        async let one = source.read(0..<10_000)
        async let two = source.read(10_000..<20_000)
        let joined = try await one + two

        XCTAssertEqual(joined, body)
        XCTAssertEqual(counter.count, 1, "concurrent first reads share one resolve")
    }

    func testCachedTrackOpensWithoutResolving() async throws {
        let server = RangeServer()
        let body = patternData(count: 300_000)
        let url = googlevideoURL(client: "IOS", length: body.count)
        server.host(body, at: url)
        let cache = try makeCache()
        let key = AudioCacheKey.youtube(videoId: "cached1")
        let first = HTTPAudioSource(stream: stream(url, length: body.count), session: server.session)
        await assertCachesCompletely(cache, key, source: first)

        let counter = Counter()
        let lazy = HTTPAudioSource(session: server.session) {
            counter.next()
            throw URLError(.notConnectedToInternet)
        }
        let data = try await readThroughCache(cache, key: key, source: lazy, range: 0..<300_000)

        XCTAssertEqual(data, body)
        XCTAssertEqual(counter.count, 0, "a cache hit never resolves a URL")
    }

    func testRefusalDuringCachedPlaybackIsRecoveredThroughTheStore() async throws {
        let server = RangeServer()
        let body = patternData(count: 1_200_000)
        let first = googlevideoURL(client: "ANDROID_VR", length: body.count, id: "one")
        let second = googlevideoURL(client: "ANDROID_VR", length: body.count, id: "two")
        server.host(body, at: first)
        server.host(body, at: second)
        let cache = try makeCache()
        let key = AudioCacheKey.youtube(videoId: "refused")
        let source = HTTPAudioSource(stream: stream(first, length: body.count), session: server.session, refresh: {
            stream(second, length: body.count)
        })
        let head = try await readThroughCache(cache, key: key, source: source, range: 0..<300_000)
        server.refuse(first)

        let tail = try await readThroughCache(cache, key: key, source: source, range: 300_000..<1_200_000)

        XCTAssertEqual(head + tail, body)
        let isComplete = await cache.isFullyCached(key)
        XCTAssertTrue(isComplete)
    }
}
