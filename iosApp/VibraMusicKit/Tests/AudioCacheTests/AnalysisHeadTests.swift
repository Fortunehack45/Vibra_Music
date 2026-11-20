import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import AudioCache

/// requestAnalysisHead / awaitAnalysisHead and the rendition queries Automix's analyzer reads the
/// cache through.
final class AnalysisHeadTests: XCTestCase {
    private let mb: Int64 = 1_024 * 1_024

    func testHeadIsSizedOnceFromTheRealLength() {
        XCTAssertEqual(AudioCacheAnalysisHeads.headSize(total: 0), 4 * mb, "unknown length: twelve seconds of anything short of lossless")
        XCTAssertEqual(AudioCacheAnalysisHeads.headSize(total: 3_000_000), 3_000_000, "a whole compressed track")
        XCTAssertEqual(AudioCacheAnalysisHeads.headSize(total: 40 * mb), 16 * mb, "not a whole 40 MB FLAC")
    }

    func testRequestPullsTheOpeningOnceASession() async throws {
        let cache = try makeCache()
        let key = AudioCacheKey.youtube(videoId: "head")
        let source = MemoryAudioSource(patternData(count: 3_000_000))

        await cache.requestAnalysisHead(for: key, source: source)
        await eventually { await cache.isFullyCached(key) }
        let reads = source.reads.count
        await cache.requestAnalysisHead(for: key, source: source)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(source.reads.count, reads, "one round per track per session")
        let prefix = await cache.cachedPrefixBytes(of: key)
        XCTAssertEqual(prefix, 3_000_000)
    }

    func testAwaitReturnsOnceTheOpeningIsOnDisk() async throws {
        let cache = try makeCache()
        let key = AudioCacheKey.youtube(videoId: "wait")
        let source = MemoryAudioSource(patternData(count: 20 * 1_024 * 1_024))

        let ready = await cache.awaitAnalysisHead(for: key, source: source, timeout: .seconds(10))

        XCTAssertTrue(ready)
        let prefix = await cache.cachedPrefixBytes(of: key)
        XCTAssertGreaterThanOrEqual(prefix, AudioStreamCache.minAlignmentPrefixBytes)
        let rendition = await cache.renditions(ofTrack: "wait").first
        XCTAssertEqual(rendition?.contentLength, 20 * mb)
        await eventually { !(await cache.heads.isInFlight(key)) }
        let finished = await cache.cachedPrefixBytes(of: key)
        XCTAssertEqual(finished, 16 * mb, "the round runs on to its full size")
    }

    func testPartOfAnotherEncodingIsClearedBeforeAFreshPull() async throws {
        let cache = try makeCache()
        let key = AudioCacheKey.youtube(videoId: "seam")
        // An earlier session left the first 100 KB of one encoding.
        let earlier = MemoryAudioSource(patternData(count: 2_000_000, seed: 1), rangeBytes: 100_000)
        _ = try await cache.store.contentInfo(for: key, source: earlier)
        try await cache.store.fill(key, range: 0..<100_000, source: earlier)
        let partial = await cache.cachedPrefixBytes(of: key)
        XCTAssertEqual(partial, 100_000)

        let cleared = await cache.heads.clearPartialHead(key, want: 2_000_000)

        XCTAssertTrue(cleared)
        let after = await cache.cachedPrefixBytes(of: key)
        XCTAssertEqual(after, 0, "thrown away rather than spliced onto")
        let complete = await cache.heads.clearPartialHead(key, want: 0)
        XCTAssertTrue(complete, "an empty entry needs no clearing")
    }

    func testCompleteHeadIsNotFetchedAgain() async throws {
        let cache = try makeCache()
        let key = AudioCacheKey.youtube(videoId: "done")
        await assertCachesCompletely(cache, key, source: MemoryAudioSource(patternData(count: 500_000)))

        let proceed = await cache.heads.clearPartialHead(key, want: 500_000)

        XCTAssertFalse(proceed)
    }

    func testFallbackCopyIsPulledWhenThePinnedOneWontCome() async throws {
        let cache = try makeCache()
        let pinned = AudioCacheKey.youtube(videoId: "fb")
        let substitute = AudioCacheKey.substitute(videoId: "fb", atmosAllowed: true)
        let refusing = MemoryAudioSource(patternData(count: 3_000_000))
        refusing.failing = true
        let working = MemoryAudioSource(patternData(count: 5_000_000, seed: 9))

        let ready = await cache.awaitAnalysisHead(for: pinned, source: refusing, fallback: (substitute, working), timeout: .seconds(10))

        XCTAssertTrue(ready)
        // `ready` means the minimum is on disk; the round goes on to the full size, so read the
        // size once it has stopped (CI caught it at 3 MiB of 4).
        await eventually { !(await cache.heads.isInFlight(pinned)) }
        let renditions = await cache.renditions(ofTrack: "fb")
        XCTAssertEqual(renditions.map(\.key), [substitute])
        XCTAssertEqual(renditions.first?.cachedPrefix, 4 * mb, "sized blind, as the pinned copy's length couldn't be had")
    }

    func testFallbackCopyHoldingPartOfAnotherEncodingIsPulledCleanNotSplicedOnto() async throws {
        let cache = try makeCache()
        let pinned = AudioCacheKey.youtube(videoId: "fbseam")
        let substitute = AudioCacheKey.substitute(videoId: "fbseam", atmosAllowed: true)
        // An earlier resolve of the substitute left its first 100 KB, at the same length.
        let earlier = MemoryAudioSource(patternData(count: 5_000_000, seed: 1), rangeBytes: 100_000)
        _ = try await cache.store.contentInfo(for: substitute, source: earlier)
        try await cache.store.fill(substitute, range: 0..<100_000, source: earlier, exact: true)
        await eventually { !(await cache.store.isFetching(substitute)) }
        let partial = await cache.cachedPrefixBytes(of: substitute)
        XCTAssertLessThan(partial, AudioStreamCache.minAlignmentPrefixBytes)
        let refusing = MemoryAudioSource(patternData(count: 3_000_000))
        refusing.failing = true
        let working = MemoryAudioSource(patternData(count: 5_000_000, seed: 9))

        let ready = await cache.awaitAnalysisHead(for: pinned, source: refusing, fallback: (substitute, working), timeout: .seconds(10))

        XCTAssertTrue(ready)
        await eventually { !(await cache.heads.isInFlight(pinned)) }
        let partialReader = await cache.reader(for: substitute, requireComplete: false)
        let reader = try XCTUnwrap(partialReader)
        let opening = await reader.read(at: 0, count: 200_000)
        XCTAssertEqual(opening, working.data.prefix(200_000), "one encoding from the first byte, not the old prefix with the new tail")
    }

    func testWaitGivesUpAfterItsRounds() async throws {
        let cache = try makeCache()
        let key = AudioCacheKey.youtube(videoId: "never")
        let source = MemoryAudioSource(patternData(count: 3_000_000))
        source.failing = true

        let started = ContinuousClock.now
        let ready = await cache.awaitAnalysisHead(for: key, source: source, timeout: .seconds(20))

        XCTAssertFalse(ready)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10), "stopped after its rounds, not at the deadline")
        XCTAssertLessThanOrEqual(source.infoCalls, AudioCacheAnalysisHeads.maxRounds)
    }

    func testDiscardingAnUndecodableCopyReArmsItsHead() async throws {
        let cache = try makeCache()
        let key = AudioCacheKey.youtube(videoId: "bad")
        let source = MemoryAudioSource(patternData(count: 1_000_000))
        await cache.requestAnalysisHead(for: key, source: source)
        await eventually { await cache.isFullyCached(key) }
        // A request while the first round is still in the air is dropped (one round per track at a
        // time), so the discard has to come after the round has ended, as a real decode failure does.
        await eventually { !(await cache.heads.isInFlight(key)) }

        let discarded = await cache.discardBadRendition(key, playing: .youtube(videoId: "bad", rendition: "hifi"))
        XCTAssertTrue(discarded)
        await cache.requestAnalysisHead(for: key, source: source)

        await eventually { await cache.isFullyCached(key) }
    }

    func testAlignmentPrefersSameSourceCopiesOverASubstitute() async throws {
        let cache = try makeCache()
        let plain = AudioCacheKey.youtube(videoId: "mix")
        let substitute = AudioCacheKey.substitute(videoId: "mix", atmosAllowed: true)
        await assertCachesCompletely(cache, substitute, source: MemoryAudioSource(patternData(count: 3_000_000)))
        let onlySubstitute = await cache.heads.alignmentPrefixBytes("mix")
        XCTAssertEqual(onlySubstitute, 3_000_000, "a substitute counts when it is all there is")

        await assertCachesCompletely(cache, plain, source: MemoryAudioSource(patternData(count: 1_000_000)))
        let withPlain = await cache.heads.alignmentPrefixBytes("mix")
        XCTAssertEqual(withPlain, 1_000_000, "a measurable same-source copy wins over a bigger substitute")

        let renditions = await cache.renditions(ofTrack: "mix")
        XCTAssertEqual(renditions.map(\.key), [plain, substitute], "smallest first")
        XCTAssertTrue(renditions.allSatisfy(\.isComplete))
    }

    func testRenditionsListOnlyCopiesWithAnOpening() async throws {
        let cache = try makeCache()
        let tailOnly = AudioCacheKey.youtube(videoId: "tail", rendition: "hifi")
        let source = MemoryAudioSource(patternData(count: 3_000_000))
        _ = try await readThroughCache(cache, key: tailOnly, source: source, range: 2_500_000..<2_600_000)
        await eventually { !(await cache.store.isFetching(tailOnly)) }

        let renditions = await cache.renditions(ofTrack: "tail")
        let prefix = await cache.cachedPrefixBytes(of: tailOnly)

        XCTAssertTrue(renditions.isEmpty, "95% of a track without byte 0 is nothing a decoder can open")
        XCTAssertEqual(prefix, 0)
    }

    func testReaderStopsAtTheFirstHole() async throws {
        let cache = try makeCache()
        let key = AudioCacheKey.youtube(videoId: "gappy")
        let source = MemoryAudioSource(patternData(count: 5_000_000), rangeBytes: 256 * 1_024)
        _ = try await readThroughCache(cache, key: key, source: source, range: 0..<300_000)
        _ = try await readThroughCache(cache, key: key, source: source, range: 4_000_000..<4_100_000)
        await eventually { !(await cache.store.isFetching(key)) }

        let complete = await cache.reader(for: key, requireComplete: true)
        XCTAssertNil(complete, "not every byte is there")
        let partialReader = await cache.reader(for: key, requireComplete: false)
        let reader = try XCTUnwrap(partialReader)
        XCTAssertEqual(reader.size, 5_000_000, "the real length, so a container describing the whole track parses")
        let head = await reader.read(at: 0, count: 2_000_000)
        let prefix = await cache.cachedPrefixBytes(of: key)
        XCTAssertEqual(Int64(head.count), prefix, "reads end where the cached prefix does")
        XCTAssertEqual(head, source.data.prefix(head.count))
        let past = await reader.read(at: 3_000_000, count: 10)
        XCTAssertTrue(past.isEmpty)
        let tail = await reader.read(at: 4_000_000, count: 1_000)
        XCTAssertEqual(tail, source.data.subdata(in: 4_000_000..<4_001_000))
    }
}
