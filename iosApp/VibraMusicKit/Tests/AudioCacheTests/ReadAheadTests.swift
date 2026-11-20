import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import AudioCache

/// prefetchQueue: the next track's bytes in full, the one after warmed only, a queue change
/// replacing the job, and nothing for tracks read-ahead must not write.
final class ReadAheadTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func record(_ name: String) { lock.withLock { names.append(name) } }
        var all: [String] { lock.withLock { names } }
    }

    func testNextTrackIsCachedWholeAndTheOneAfterOnlyWarmed() async throws {
        let server = RangeServer()
        let body = patternData(count: 5_000_000)
        let url = googlevideoURL(client: "ANDROID_VR", length: body.count)
        server.host(body, at: url)
        let cache = try makeCache()
        let calls = Calls()
        let next = AudioCacheKey.youtube(videoId: "next")
        let after = AudioCacheKey.youtube(videoId: "after")
        let beyond = AudioCacheKey.youtube(videoId: "beyond")

        await cache.prefetch([
            AudioCachePrefetchItem(key: next, source: HTTPAudioSource(stream: stream(url, length: body.count), session: server.session), warmUp: { calls.record("next") }),
            AudioCachePrefetchItem(key: after, source: MemoryAudioSource(patternData(count: 100)), warmUp: { calls.record("after") }),
            AudioCachePrefetchItem(key: beyond, source: MemoryAudioSource(patternData(count: 100)), warmUp: { calls.record("beyond") }),
        ])

        await eventually(timeout: 10) { await cache.isFullyCached(next) }
        await eventually { calls.all == ["after", "beyond"] }
        let ranges = server.ranges().sorted { $0.lowerBound < $1.lowerBound }
        for (a, b) in zip(ranges, ranges.dropFirst()) {
            XCTAssertLessThanOrEqual(a.upperBound, b.lowerBound, "no byte fetched twice: \(a) and \(b)")
        }
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, 5_000_000)
        XCTAssertTrue(server.ranges().allSatisfy { $0.count <= 512 * 1_024 })
        let afterBytes = await cache.cachedPrefixBytes(of: after)
        XCTAssertEqual(afterBytes, 0, "only the next track gets bytes")
        XCTAssertEqual(AudioStreamCache.queueDepth, 4)
    }

    /// A quick run of skips lands on a track whose URL is already minted: the warm-ups don't wait
    /// out the delay that holds the next track's bytes back from the start of the one playing.
    func testTheQueueAheadIsWarmedAtOnceWhileTheNextTracksBytesWait() async throws {
        let cache = try makeCache(prefetchDelay: .seconds(30))
        let calls = Calls()
        let next = AudioCacheKey.youtube(videoId: "next")
        await cache.prefetch([
            AudioCachePrefetchItem(key: next, source: MemoryAudioSource(patternData(count: 100_000)), warmUp: { calls.record("next") }),
            AudioCachePrefetchItem(key: .youtube(videoId: "second"), source: nil, warmUp: { calls.record("second") }),
            AudioCachePrefetchItem(key: .youtube(videoId: "third"), source: nil, warmUp: { calls.record("third") }),
            AudioCachePrefetchItem(key: .youtube(videoId: "fourth"), source: nil, warmUp: { calls.record("fourth") }),
        ])

        await eventually(timeout: 3) { calls.all == ["second", "third", "fourth"] }
        let nextBytes = await cache.cachedPrefixBytes(of: next)
        XCTAssertEqual(nextBytes, 0, "the next track's bytes still wait out the delay")
    }

    func testOnlyWholeRenditionsAreListedAsComplete() async throws {
        let cache = try makeCache()
        let whole = AudioCacheKey.youtube(videoId: "whole")
        let upgraded = AudioCacheKey(trackID: "whole", rendition: "hifi")
        let partial = AudioCacheKey.youtube(videoId: "partial")
        let saved = await cache.cacheCompletely(whole, source: MemoryAudioSource(patternData(count: 300_000)))
        let savedUpgrade = await cache.cacheCompletely(upgraded, source: MemoryAudioSource(patternData(count: 900_000)))
        XCTAssertTrue(saved && savedUpgrade)
        await cache.warmRange(partial, source: MemoryAudioSource(patternData(count: 4_000_000)), range: 0..<100_000)

        let complete = await cache.completeRenditions()
        XCTAssertEqual(Set(complete.map(\.key)), [whole, upgraded], "a track with only its opening on disk is not complete")
    }

    func testOpeningIsFetchedBeforeTheRest() async throws {
        let source = MemoryAudioSource(patternData(count: 4_000_000))
        let cache = try makeCache()
        let key = AudioCacheKey.youtube(videoId: "ordered")

        await cache.prefetch([AudioCachePrefetchItem(key: key, source: source)])

        await eventually { await cache.isFullyCached(key) }
        XCTAssertEqual(source.reads.first?.lowerBound, 0)
        XCTAssertEqual(source.reads.first?.upperBound, AudioCacheReadAhead.preloadBytes)
    }

    func testTrackWithoutASourceIsOnlyWarmed() async throws {
        let cache = try makeCache()
        let calls = Calls()
        let unpinned = AudioCacheKey.substitute(videoId: "sub", atmosAllowed: true)

        await cache.prefetch([
            AudioCachePrefetchItem(key: unpinned, source: nil, warmUp: { calls.record("sub") }),
            AudioCachePrefetchItem(key: .youtube(videoId: "two"), source: nil, warmUp: { calls.record("two") }),
        ])

        await eventually { calls.all == ["sub", "two"] }
        let usage = await cache.usage()
        XCTAssertEqual(usage.cachedBytes, 0, "no bytes under a key playback may fill from another source")
    }

    func testSameQueueIsLeftAlone() async throws {
        let cache = try makeCache()
        let calls = Calls()
        let items = [
            AudioCachePrefetchItem(key: .youtube(videoId: "a"), source: nil, warmUp: { calls.record("a") }),
        ]
        await cache.prefetch(items)
        await eventually { calls.all == ["a"] }

        await cache.prefetch(items)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(calls.all, ["a"])
    }

    /// The caller sends a fresh source on every call, so the same queue with a source again is the
    /// same plan: the fetch already under way carries on rather than starting over.
    func testTheSameQueueWithAFreshSourceKeepsTheFetchUnderWay() async throws {
        let cache = try makeCache(prefetchDelay: .milliseconds(200))
        let key = AudioCacheKey.youtube(videoId: "same")
        let first = MemoryAudioSource(patternData(count: 2_000_000))
        let again = MemoryAudioSource(patternData(count: 2_000_000))

        await cache.prefetch([AudioCachePrefetchItem(key: key, source: first)])
        await cache.prefetch([AudioCachePrefetchItem(key: key, source: again)])

        await eventually { await cache.isFullyCached(key) }
        XCTAssertFalse(first.reads.isEmpty)
        XCTAssertTrue(again.reads.isEmpty, "the second call was the same plan")
    }

    /// A track's substitution pinned after the plan went out: same key, but now with a source. The
    /// plan that only warmed it would never fetch its bytes, so the new one replaces it.
    func testTheSameQueueGainingASourceFetchesTheNextTrack() async throws {
        let cache = try makeCache()
        let calls = Calls()
        let key = AudioCacheKey.substitute(videoId: "pinned", atmosAllowed: true)
        await cache.prefetch([AudioCachePrefetchItem(key: key, source: nil, warmUp: { calls.record("pinned") })])
        await eventually { calls.all == ["pinned"] }
        let before = await cache.cachedPrefixBytes(of: key)
        XCTAssertEqual(before, 0)

        let source = MemoryAudioSource(patternData(count: 1_500_000))
        await cache.prefetch([AudioCachePrefetchItem(key: key, source: source, warmUp: { calls.record("pinned") })])

        await eventually { await cache.isFullyCached(key) }
    }

    /// Pausing clears the plan and playing sends it back. The tracks were warmed a moment ago, and
    /// each warm-up is a whole race in the app, so they are not warmed again.
    func testAPausedAndResumedQueueIsNotWarmedAgain() async throws {
        let cache = try makeCache()
        let calls = Calls()
        let items = [
            AudioCachePrefetchItem(key: .youtube(videoId: "a"), source: nil, warmUp: { calls.record("a") }),
            AudioCachePrefetchItem(key: .youtube(videoId: "b"), source: nil, warmUp: { calls.record("b") }),
        ]
        await cache.prefetch(items)
        await eventually { calls.all == ["a", "b"] }

        await cache.prefetch([])
        await cache.prefetch(items)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(calls.all, ["a", "b"])
    }

    func testAWarmUpThatFailedIsTriedAgain() async throws {
        struct Offline: Error {}
        let cache = try makeCache()
        let calls = Calls()
        let item = AudioCachePrefetchItem(key: .youtube(videoId: "a"), source: nil, warmUp: {
            calls.record("a")
            throw Offline()
        })
        await cache.prefetch([item])
        await eventually { calls.all == ["a"] }

        await cache.prefetch([])
        await cache.prefetch([item])

        await eventually { calls.all == ["a", "a"] }
    }

    func testNewQueueReplacesTheOldOne() async throws {
        let slow = SlowMemorySource(patternData(count: 20_000_000))
        let cache = try makeCache()
        let first = AudioCacheKey.youtube(videoId: "first")
        let second = AudioCacheKey.youtube(videoId: "second")
        let secondSource = MemoryAudioSource(patternData(count: 1_000_000))

        await cache.prefetch([AudioCachePrefetchItem(key: first, source: slow)])
        await eventually { slow.delivered > 0 }
        await cache.prefetch([AudioCachePrefetchItem(key: second, source: secondSource)])

        await eventually { await cache.isFullyCached(second) }
        await eventually { !(await cache.store.isFetching(first)) }
        let stoppedAt = slow.delivered
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(slow.delivered, stoppedAt, "the skipped-past track stops downloading")
        let firstComplete = await cache.isFullyCached(first)
        XCTAssertFalse(firstComplete)
    }

    func testCancelStopsReadAheadAndResumeStartsAgain() async throws {
        let slow = SlowMemorySource(patternData(count: 20_000_000))
        let cache = try makeCache()
        let key = AudioCacheKey.youtube(videoId: "paused")
        let items = [AudioCachePrefetchItem(key: key, source: slow)]

        await cache.prefetch(items)
        await eventually { slow.delivered > 0 }
        await cache.cancelPrefetch()
        await eventually { !(await cache.store.isFetching(key)) }
        let stoppedAt = slow.delivered
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(slow.delivered, stoppedAt)

        await cache.prefetch(items)
        await eventually { slow.delivered > stoppedAt }
        await cache.cancelPrefetch()
    }

    func testFailedFetchIsRetriedThenLeftAlone() async throws {
        let source = MemoryAudioSource(patternData(count: 3_000_000))
        let cache = try makeCache()
        let key = AudioCacheKey.youtube(videoId: "flaky")
        _ = try await cache.store.contentInfo(for: key, source: source)
        source.failing = true

        await cache.prefetch([AudioCachePrefetchItem(key: key, source: source)])

        // The opening plus one read per whole-track attempt.
        await eventually { source.reads.count >= 1 + AudioCacheReadAhead.maxAttempts }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(source.reads.count, 1 + AudioCacheReadAhead.maxAttempts)
    }

    func testWarmRangePullsJustThatRange() async throws {
        let source = MemoryAudioSource(patternData(count: 3_000_000), rangeBytes: 64 * 1_024)
        let cache = try makeCache()
        let key = AudioCacheKey.youtube(videoId: "audition", rendition: "hifi")

        await cache.warmRange(key, source: source, range: 0..<200_000)

        // Exactly the range: a warm-up doesn't linger on to a whole megabyte the way a player's
        // read does, since nothing is about to read past it.
        let prefix = await cache.cachedPrefixBytes(of: key)
        XCTAssertEqual(prefix, 200_000)
        let summary = await cache.cachedSummary(of: key)
        XCTAssertTrue(summary.hasPrefix("audition#hifi holds "), summary)
        let empty = await cache.cachedSummary(of: .youtube(videoId: "none"))
        XCTAssertEqual(empty, "none holds nothing")
    }

    /// A warm-up in the middle of a file (a quality upgrade's swap point) asks the server for that
    /// range and no more. Outside googlevideo a request isn't split, so asking for the whole hole
    /// to the end of the file and cancelling at the warm's end leaves the overshoot in flight.
    func testWarmRangeAsksTheServerForJustThatRange() async throws {
        let server = RangeServer()
        let body = patternData(count: 3_000_000)
        let url = URL(string: "https://lossless.example/track.flac")!
        server.host(body, at: url, mimeType: "audio/flac")
        let source = HTTPAudioSource(stream: stream(url, length: body.count, mimeType: "audio/flac"), session: server.session)
        let cache = try makeCache()
        let key = AudioCacheKey.youtube(videoId: "swapPoint", rendition: "hifi")

        await cache.warmRange(key, source: source, range: 1_000_000..<1_200_000)

        XCTAssertEqual(server.ranges(for: url), [1_000_000..<1_200_000])
        let held = await cache.cachedRanges(of: key)
        XCTAssertEqual(held, [1_000_000..<1_200_000])
    }
}

/// A memory source that yields 64 KB pieces slowly and counts them.
final class SlowMemorySource: AudioRangeDataSource, @unchecked Sendable {
    let data: Data
    private let lock = NSLock()
    private var _delivered = 0

    init(_ data: Data) { self.data = data }

    var delivered: Int { lock.withLock { _delivered } }

    func contentInfo() async throws -> AudioContentInfo {
        AudioContentInfo(contentLength: Int64(data.count), mimeType: "audio/mp4")
    }

    func read(_ range: Range<Int64>) async throws -> Data {
        var result = Data()
        for try await piece in stream(range) { result.append(piece) }
        return result
    }

    func stream(_ range: Range<Int64>) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var position = range.lowerBound
                while position < min(range.upperBound, Int64(self.data.count)), !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                    let end = min(position + 65_536, range.upperBound, Int64(self.data.count))
                    let piece = self.data.subdata(in: Int(position)..<Int(end))
                    self.lock.withLock { self._delivered += piece.count }
                    if case .terminated = continuation.yield(piece) { break }
                    position = end
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    var maxRangeBytes: Int64 { .max }
}
