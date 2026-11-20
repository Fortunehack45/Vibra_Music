import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import AudioCache

/// DynamicLruCacheEvictor: LRU under a movable ceiling, with track openings held back up to a
/// budget, plus free-space awareness in the store.
final class CacheEvictionTests: XCTestCase {
    private let mb: Int64 = 1_024 * 1_024

    private func span(_ key: String, _ start: Int64, _ length: Int64, at time: Int64) -> AudioCacheSpan {
        AudioCacheSpan(key: AudioCacheKey(rawValue: key), start: start, length: length, touched: time)
    }

    // MARK: Evictor

    func testLeastRecentlyUsedSpanGoesFirst() {
        var evictor = AudioCacheEvictor(maxBytes: 30 * mb, headBytes: 0, headBudgetBytes: 0)
        XCTAssertTrue(evictor.spanAdded(span("a", 10 * mb, 10 * mb, at: 1)).isEmpty)
        XCTAssertTrue(evictor.spanAdded(span("b", 10 * mb, 10 * mb, at: 2)).isEmpty)
        XCTAssertTrue(evictor.spanAdded(span("c", 10 * mb, 10 * mb, at: 3)).isEmpty)

        let evicted = evictor.spanAdded(span("d", 10 * mb, 10 * mb, at: 4))

        XCTAssertEqual(evicted.map(\.key.rawValue), ["a"])
        XCTAssertEqual(evictor.currentSize, 30 * mb)
    }

    func testTouchedSpanMovesToTheYoungEnd() {
        var evictor = AudioCacheEvictor(maxBytes: 30 * mb, headBytes: 0, headBudgetBytes: 0)
        let a = span("a", 5 * mb, 10 * mb, at: 1)
        _ = evictor.spanAdded(a)
        _ = evictor.spanAdded(span("b", 5 * mb, 10 * mb, at: 2))
        _ = evictor.spanAdded(span("c", 5 * mb, 10 * mb, at: 3))
        XCTAssertTrue(evictor.spanTouched(a, a.touched(at: 4)).isEmpty)

        let evicted = evictor.spanAdded(span("d", 5 * mb, 10 * mb, at: 5))

        XCTAssertEqual(evicted.map(\.key.rawValue), ["b"])
    }

    func testTiesAreBrokenByKeyThenPosition() {
        var evictor = AudioCacheEvictor(maxBytes: 2 * mb, headBytes: 0, headBudgetBytes: 0)
        _ = evictor.spanAdded(span("b", 0, mb, at: 1))
        _ = evictor.spanAdded(span("a", mb, mb, at: 1))
        let evicted = evictor.spanAdded(span("a", 0, mb, at: 1))
        XCTAssertEqual(evicted.map { "\($0.key)@\($0.start)" }, ["a@0"])
    }

    func testOpeningsAreHeldBackWhileTailsGo() {
        var evictor = AudioCacheEvictor(maxBytes: 18 * mb, headBytes: 4 * mb, headBudgetBytes: 96 * mb)
        let head = span("track", 0, 5 * mb, at: 1)
        _ = evictor.spanAdded(head)
        _ = evictor.spanAdded(span("track", 5 * mb, 5 * mb, at: 2))
        _ = evictor.spanAdded(span("other", 5 * mb, 5 * mb, at: 3))
        XCTAssertTrue(evictor.isProtected(head))

        let evicted = evictor.spanAdded(span("other", 10 * mb, 5 * mb, at: 4))

        XCTAssertEqual(evicted.map { "\($0.key)@\($0.start)" }, ["track@\(5 * mb)"], "the older tail goes, not the oldest span (the head)")
        XCTAssertEqual(evictor.protectedSize, 5 * mb)
    }

    func testAHeadIsAnythingStartingWithinTheHeadRegion() {
        let evictor = AudioCacheEvictor(maxBytes: mb, headBytes: 4 * mb, headBudgetBytes: 96 * mb)
        XCTAssertTrue(evictor.isHead(span("a", 0, 1, at: 0)))
        XCTAssertTrue(evictor.isHead(span("a", 4 * mb - 1, 1, at: 0)))
        XCTAssertFalse(evictor.isHead(span("a", 4 * mb, 1, at: 0)))
    }

    func testHeadBudgetBoundsTheExemption() {
        var evictor = AudioCacheEvictor(maxBytes: 100 * mb, headBytes: 4 * mb, headBudgetBytes: 10 * mb)
        let first = span("a", 0, 4 * mb, at: 1)
        let second = span("b", 0, 4 * mb, at: 2)
        let third = span("c", 0, 4 * mb, at: 3)
        _ = evictor.spanAdded(first)
        _ = evictor.spanAdded(second)
        _ = evictor.spanAdded(third)

        XCTAssertTrue(evictor.isProtected(first))
        XCTAssertTrue(evictor.isProtected(second))
        XCTAssertFalse(evictor.isProtected(third), "past the budget a head is ordinary LRU")
        XCTAssertEqual(evictor.protectedSize, 8 * mb)
    }

    func testOnlyHeadsLeftReleasesTheOldestSoTheCeilingHolds() {
        var evictor = AudioCacheEvictor(maxBytes: 8 * mb, headBytes: 4 * mb, headBudgetBytes: 96 * mb)
        _ = evictor.spanAdded(span("a", 0, 3 * mb, at: 1))
        _ = evictor.spanAdded(span("b", 0, 3 * mb, at: 2))

        let evicted = evictor.spanAdded(span("c", 0, 3 * mb, at: 3))

        XCTAssertEqual(evicted.map(\.key.rawValue), ["a"])
        XCTAssertLessThanOrEqual(evictor.currentSize, 8 * mb)
        XCTAssertEqual(evictor.protectedSize, 6 * mb)
    }

    func testRaisingAndLoweringTheCeilingInPlace() {
        var evictor = AudioCacheEvictor(maxBytes: 100 * mb, headBytes: 0, headBudgetBytes: 0)
        for index in 0..<10 {
            _ = evictor.spanAdded(span("k\(index)", mb, 5 * mb, at: Int64(index)))
        }
        XCTAssertEqual(evictor.currentSize, 50 * mb)

        evictor.maxBytes = 20 * mb
        let evicted = evictor.applyNow()

        XCTAssertEqual(evicted.map(\.key.rawValue), ["k0", "k1", "k2", "k3", "k4", "k5"])
        XCTAssertEqual(evictor.currentSize, 20 * mb)
    }

    func testStartingAFileMakesRoomFirst() {
        var evictor = AudioCacheEvictor(maxBytes: 10 * mb, headBytes: 0, headBudgetBytes: 0)
        _ = evictor.spanAdded(span("a", mb, 4 * mb, at: 1))
        _ = evictor.spanAdded(span("b", mb, 4 * mb, at: 2))

        let evicted = evictor.startFile(length: 5 * mb)

        XCTAssertEqual(evicted.map(\.key.rawValue), ["a"])
    }

    // MARK: Store

    func testCacheStaysUnderItsLimitWhileFilling() async throws {
        let clock = TestClock()
        let cache = try makeCache(limit: 6 * mb, headBytes: 0, headBudget: 0, clock: clock)
        var keys: [AudioCacheKey] = []
        for index in 0..<4 {
            let key = AudioCacheKey.youtube(videoId: "track\(index)")
            keys.append(key)
            let source = MemoryAudioSource(patternData(count: 2_500_000, seed: UInt8(index)))
            await assertCachesCompletely(cache, key, source: source)
            clock.advance()
            let usage = await cache.usage()
            XCTAssertLessThanOrEqual(usage.cachedBytes, 6 * mb)
        }
        let first = await cache.isFullyCached(keys[0])
        let last = await cache.isFullyCached(keys[3])
        XCTAssertFalse(first, "the least recently used track made room")
        XCTAssertTrue(last)
    }

    func testRecentlyReadTrackOutlivesAnOlderOne() async throws {
        let clock = TestClock()
        // Room for two of the three.
        let cache = try makeCache(limit: 5 * mb, headBytes: 0, headBudget: 0, clock: clock)
        let a = AudioCacheKey.youtube(videoId: "a")
        let b = AudioCacheKey.youtube(videoId: "b")
        let c = AudioCacheKey.youtube(videoId: "c")
        let sourceA = MemoryAudioSource(patternData(count: 2_000_000, seed: 1))
        await assertCachesCompletely(cache, a, source: sourceA)
        clock.advance()
        await assertCachesCompletely(cache, b, source: MemoryAudioSource(patternData(count: 2_000_000, seed: 2)))
        clock.advance()
        _ = try await readThroughCache(cache, key: a, source: sourceA, range: 0..<2_000_000)
        clock.advance()

        await assertCachesCompletely(cache, c, source: MemoryAudioSource(patternData(count: 2_000_000, seed: 3)))

        let aCached = await cache.isFullyCached(a)
        let bCached = await cache.isFullyCached(b)
        XCTAssertTrue(aCached, "played again, so it is young")
        XCTAssertFalse(bCached)
    }

    func testLoweringTheLimitEvictsAtOnce() async throws {
        let clock = TestClock()
        let cache = try makeCache(limit: 64 * mb, headBytes: 0, headBudget: 0, clock: clock)
        for index in 0..<5 {
            await assertCachesCompletely(cache, .youtube(videoId: "t\(index)"), source: MemoryAudioSource(patternData(count: 2_000_000)))
            clock.advance()
        }
        let before = await cache.usage()
        XCTAssertEqual(before.cachedBytes, 10_000_000)

        await cache.setLimit(5 * mb)

        let after = await cache.usage()
        XCTAssertLessThanOrEqual(after.cachedBytes, 5 * mb)
        XCTAssertLessThan(after.diskBytes, before.diskBytes, "evicted blocks are handed back")
        let newest = await cache.isFullyCached(.youtube(videoId: "t4"))
        XCTAssertTrue(newest)
    }

    func testLimitIsAppliedToWhatIsAlreadyOnDiskWhenOpening() async throws {
        let directory = try makeTemporaryDirectory()
        let clock = TestClock()
        do {
            let cache = try makeCache(directory: directory, limit: 64 * mb, headBytes: 0, headBudget: 0, clock: clock)
            for index in 0..<4 {
                await assertCachesCompletely(cache, .youtube(videoId: "t\(index)"), source: MemoryAudioSource(patternData(count: 2_000_000)))
                clock.advance()
            }
            await cache.flush()
        }
        let smaller = try makeCache(directory: directory, limit: 4 * mb, headBytes: 0, headBudget: 0, clock: clock)
        await eventually { await smaller.usage().cachedBytes <= 4 * self.mb }
        let oldest = await smaller.isFullyCached(.youtube(videoId: "t0"))
        let newest = await smaller.isFullyCached(.youtube(videoId: "t3"))
        XCTAssertFalse(oldest)
        XCTAssertTrue(newest)
    }

    func testFreeSpaceLowersTheCeiling() async throws {
        let available = LockedValue<Int64>(3 * mb)
        let cache = try makeCache(limit: 10 * 1_024 * mb, minimumFree: mb, capacity: { _ in available.value }, headBytes: 0, headBudget: 0)

        let usage = await cache.usage()
        XCTAssertEqual(usage.limitBytes, 10 * 1_024 * mb)
        XCTAssertEqual(usage.ceilingBytes, 2 * mb, "a 10 GB limit on a volume with 3 MB free leaves 1 MB free")

        await assertCachesCompletely(cache, .youtube(videoId: "a"), source: MemoryAudioSource(patternData(count: 1_500_000)))
        available.value = 3 * mb - 1_500_000
        await cache.setLimit(10 * 1_024 * mb)
        await assertCachesCompletely(cache, .youtube(videoId: "b"), source: MemoryAudioSource(patternData(count: 1_500_000)))

        let after = await cache.usage()
        XCTAssertLessThanOrEqual(after.cachedBytes, 2 * mb)
        let a = await cache.isFullyCached(.youtube(videoId: "a"))
        XCTAssertFalse(a, "room for the new track came out of the old one, not the last free megabyte")
    }

    func testUnknownFreeSpaceLeavesTheUserLimit() async throws {
        let cache = try makeCache(limit: 42 * mb, capacity: { _ in nil })
        let usage = await cache.usage()
        XCTAssertEqual(usage.ceilingBytes, 42 * mb)
    }

    func testDefaultCapacityReaderReportsTheVolume() throws {
        let directory = try makeTemporaryDirectory()
        let available = try XCTUnwrap(AudioStreamCache.availableCapacity(at: directory))
        XCTAssertGreaterThan(available, 0)
    }
}

final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
