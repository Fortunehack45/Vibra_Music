import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import AudioCache

/// Settings → Storage: the size the cache reports, "Clear song cache" freeing it, the limit
/// following the setting, and discarding individual tracks and renditions.
final class CacheStorageControlTests: XCTestCase {
    private let mb: Int64 = 1_024 * 1_024

    func testUsageReportsWhatIsOnDisk() async throws {
        let directory = try makeTemporaryDirectory()
        let cache = try makeCache(directory: directory)
        for index in 0..<3 {
            await assertCachesCompletely(cache, .youtube(videoId: "u\(index)"), source: MemoryAudioSource(patternData(count: 1_000_000)))
        }

        let usage = await cache.usage()

        XCTAssertEqual(usage.cachedBytes, 3_000_000)
        XCTAssertEqual(usage.entryCount, 3)
        XCTAssertEqual(usage.diskBytes, AudioCacheStore.allocatedSize(of: directory))
        XCTAssertGreaterThanOrEqual(usage.diskBytes, 3_000_000)
        XCTAssertLessThan(usage.diskBytes, 3_000_000 + 1 * mb, "holes cost nothing; the index is small")
    }

    func testClearFreesTheSpaceItReports() async throws {
        let directory = try makeTemporaryDirectory()
        let cache = try makeCache(directory: directory)
        let server = RangeServer()
        for index in 0..<3 {
            let body = patternData(count: 1_500_000, seed: UInt8(index))
            let url = googlevideoURL(client: "IOS", length: body.count, id: "c\(index)")
            server.host(body, at: url)
            await assertCachesCompletely(cache, .youtube(videoId: "c\(index)"), source: HTTPAudioSource(stream: stream(url, length: body.count), session: server.session))
        }
        // A partially cached one too: sparse files count by allocated blocks.
        let partial = MemoryAudioSource(patternData(count: 5_000_000))
        _ = try await readThroughCache(cache, key: .youtube(videoId: "partial"), source: partial, range: 3_000_000..<3_200_000)
        await eventually { !(await cache.store.isFetching(.youtube(videoId: "partial"))) }
        let reported = await cache.usage().diskBytes
        XCTAssertGreaterThan(reported, 4_500_000)

        let freed = await cache.clear()

        XCTAssertEqual(freed, reported)
        let after = await cache.usage()
        XCTAssertEqual(after.diskBytes, 0)
        XCTAssertEqual(after.cachedBytes, 0)
        XCTAssertEqual(after.entryCount, 0)
        XCTAssertEqual(AudioCacheStore.allocatedSize(of: directory), 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)), [])
    }

    func testClearWhileATrackStreamsKeepsItPlaying() async throws {
        let cache = try makeCache()
        let source = MemoryAudioSource(patternData(count: 3_000_000), rangeBytes: 256 * 1_024)
        let key = AudioCacheKey.youtube(videoId: "playing")
        let info = try await cache.store.contentInfo(for: key, source: source)
        let head = try await readThroughCache(cache, key: key, source: source, range: 0..<500_000, knownInfo: info)

        await cache.clear()
        // The player carries on with the content information it was already given.
        let rest = try await readThroughCache(cache, key: key, source: source, range: 500_000..<3_000_000, knownInfo: info)

        XCTAssertEqual(head + rest, source.data)
    }

    func testClearStopsReadAhead() async throws {
        let cache = try makeCache()
        let source = MemoryAudioSource(patternData(count: 1_000_000))
        await cache.prefetch([AudioCachePrefetchItem(key: .youtube(videoId: "next"), source: source)])
        await cache.clear()
        let target = await cache.readAhead.target
        XCTAssertNil(target)
    }

    func testDiscardingATrackRemovesEveryRendition() async throws {
        let cache = try makeCache()
        let keys: [AudioCacheKey] = [
            .youtube(videoId: "vid"),
            .youtube(videoId: "vid", rendition: "hifi"),
            .substitute(videoId: "vid", atmosAllowed: true),
            .youtube(videoId: "other"),
        ]
        for key in keys {
            await assertCachesCompletely(cache, key, source: MemoryAudioSource(patternData(count: 10_000)))
        }

        await cache.discard(trackID: "vid")

        let remaining = await cache.store.keys().sorted()
        XCTAssertEqual(remaining, [.youtube(videoId: "other")])
    }

    /// After a network failure the whole copies stay and the partial ones go, and the track's log
    /// says which kind of failure each discard was for, as Android's `discard(keepComplete)` does.
    func testADiscardSaysWhyItRan() async throws {
        let cache = try makeCache()
        let whole = AudioCacheKey.youtube(videoId: "whyDiscard")
        let partial = AudioCacheKey.substitute(videoId: "whyDiscard", atmosAllowed: true)
        await assertCachesCompletely(cache, whole, source: MemoryAudioSource(patternData(count: 10_000)))
        await cache.warmRange(partial, source: MemoryAudioSource(patternData(count: 900_000)), range: 0..<100_000)

        await cache.discard(trackID: "whyDiscard", keepComplete: true)
        await cache.discard(trackID: "whyDiscard")

        let log = TrackLog.shared.heldLines.filter { $0.track == "whyDiscard" }.map(\.text)
        XCTAssertTrue(log.contains { $0.contains("kept complete cache entry \(whole) through a network failure") }, "\(log)")
        XCTAssertTrue(log.contains { $0.contains("discarded cache entry \(partial) after a network failure") }, "\(log)")
        XCTAssertTrue(log.contains { $0.contains("discarded cache entry \(whole) after a failure that may be the bytes'") }, "\(log)")
    }

    func testDiscardingARenditionLeavesItsSiblings() async throws {
        let cache = try makeCache()
        let plain = AudioCacheKey.youtube(videoId: "vid")
        let upgrade = AudioCacheKey.youtube(videoId: "vid", rendition: "hifi")
        await assertCachesCompletely(cache, plain, source: MemoryAudioSource(patternData(count: 10_000)))
        await assertCachesCompletely(cache, upgrade, source: MemoryAudioSource(patternData(count: 20_000)))

        await cache.discardRendition(upgrade)

        let plainCached = await cache.isFullyCached(plain)
        let upgradeCached = await cache.isFullyCached(upgrade)
        XCTAssertTrue(plainCached)
        XCTAssertFalse(upgradeCached)
    }

    func testUndecodableRenditionIsKeptWhileItIsTheOnePlaying() async throws {
        let cache = try makeCache()
        let playing = AudioCacheKey.youtube(videoId: "vid", rendition: "hifi")
        let sibling = AudioCacheKey.substitute(videoId: "vid", atmosAllowed: true)
        await assertCachesCompletely(cache, playing, source: MemoryAudioSource(patternData(count: 10_000)))
        await assertCachesCompletely(cache, sibling, source: MemoryAudioSource(patternData(count: 10_000)))

        let refused = await cache.discardBadRendition(playing, playing: playing)
        let discarded = await cache.discardBadRendition(sibling, playing: playing)

        XCTAssertFalse(refused)
        XCTAssertTrue(discarded)
        let playingCached = await cache.isFullyCached(playing)
        let siblingCached = await cache.isFullyCached(sibling)
        XCTAssertTrue(playingCached)
        XCTAssertFalse(siblingCached)
    }

    /// Partial add-on and upgrade copies of tracks the queue has moved past are dropped, as
    /// Android's `dropForeignEntries` does; whole ones, YouTube's own entries, and anything of the
    /// tracks kept are left alone.
    func testPartialAddonCopiesAreDroppedExceptForTheTracksKept() async throws {
        let cache = try makeCache()
        let partialSubstitute = AudioCacheKey.substitute(videoId: "behind", atmosAllowed: true)
        let partialUpgrade = AudioCacheKey.youtube(videoId: "behind", rendition: "hifi-2")
        let partialYouTube = AudioCacheKey.youtube(videoId: "behind")
        let wholeSubstitute = AudioCacheKey.substitute(videoId: "wholeBehind", atmosAllowed: false)
        let keptPartial = AudioCacheKey.substitute(videoId: "playing", atmosAllowed: true)
        for key in [partialSubstitute, partialUpgrade, partialYouTube, keptPartial] {
            await cache.warmRange(key, source: MemoryAudioSource(patternData(count: 900_000)), range: 0..<100_000)
        }
        await assertCachesCompletely(cache, wholeSubstitute, source: MemoryAudioSource(patternData(count: 100_000)))

        let dropped = await cache.dropPartialAddonEntries(keepingTracks: ["playing"])

        XCTAssertEqual(dropped, 2)
        let remaining = await cache.store.keys().sorted()
        XCTAssertEqual(remaining, [partialYouTube, keptPartial, wholeSubstitute].sorted())
        let wholePlays = await cache.isFullyCached(wholeSubstitute)
        XCTAssertTrue(wholePlays, "a whole add-on copy still plays off disk")
    }

    @MainActor
    func testLimitFollowsTheSetting() async throws {
        let settings = AppSettings(defaults: makeEphemeralDefaults(), credentials: InMemoryCredentialStore())
        let cache = try makeCache(limit: 1)
        let task = cache.followLimit(of: settings)
        defer { task.cancel() }

        await eventually { await cache.usage().limitBytes == AppSettings.defaultAudioCacheLimitBytes }
        settings.audioCacheLimitBytes = 2 * 1_024 * mb
        await eventually { await cache.usage().limitBytes == 2 * 1_024 * self.mb }
        settings.audioCacheLimitBytes = 20 * 1_024 * mb
        await eventually("clamped to 10 GB by the setting") { await cache.usage().limitBytes == AppSettings.maxAudioCacheLimitBytes }
    }
}
