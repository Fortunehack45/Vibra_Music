import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import AudioCache

/// One fetch per hole, shared by everyone who needs it; cancellation and disk failures.
final class SharedFetchTests: XCTestCase {
    func testConcurrentReadersOfOneRangeShareOneDownload() async throws {
        let server = RangeServer()
        let body = patternData(count: 2_000_000)
        let url = googlevideoURL(client: "ANDROID_VR", length: body.count)
        server.host(body, at: url)
        let cache = try makeCache()
        let key = AudioCacheKey.youtube(videoId: "shared")
        let source = HTTPAudioSource(stream: stream(url, length: body.count), session: server.session)
        _ = try await cache.store.contentInfo(for: key, source: source)

        async let player = readThroughCache(cache, key: key, source: source, range: 0..<2_000_000)
        async let readAhead: Void = cache.store.fill(key, range: 0..<2_000_000, source: source)
        let (played, _) = try await (player, readAhead)

        XCTAssertEqual(played, body)
        XCTAssertEqual(server.requestedBytes(total: 2_000_000), 2_000_000, "every byte asked for once")
        let complete = await cache.isFullyCached(key)
        XCTAssertTrue(complete)
    }

    func testAProbeReadsOnIntoAUsefulFirstRange() async throws {
        let source = MemoryAudioSource(patternData(count: 5_000_000), rangeBytes: .max)
        let cache = try makeCache()
        let key = AudioCacheKey.youtube(videoId: "probe")

        let probe = try await readThroughCache(cache, key: key, source: source, range: 0..<2)

        XCTAssertEqual(probe, source.data.prefix(2))
        await eventually { !(await cache.store.isFetching(key)) }
        let ranges = await cache.cachedRanges(of: key)
        XCTAssertEqual(ranges, [0..<AudioCacheStore.lingerBytes], "the fetch read on to the end of its first megabyte, then stopped")
    }

    func testCancelledReaderStopsItsFetch() async throws {
        let source = SlowSource(patternData(count: 8_000_000))
        let cache = try makeCache()
        let key = AudioCacheKey.youtube(videoId: "skip")
        _ = try await cache.store.contentInfo(for: key, source: source)

        let reader = Task { try await self.readThroughCache(cache, key: key, source: source, range: 0..<8_000_000) }
        await eventually { source.delivered > 100_000 }
        reader.cancel()
        _ = try? await reader.value
        await eventually { !(await cache.store.isFetching(key)) }
        let stoppedAt = source.delivered
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(source.delivered, stoppedAt)
        XCTAssertLessThan(stoppedAt, 8_000_000)
        let prefix = await cache.cachedPrefixBytes(of: key)
        XCTAssertGreaterThan(prefix, 0, "what arrived before the skip is kept")
    }

    func testReaderFarAheadOfAFetchStartsItsOwnWithoutOverlap() async throws {
        let source = SlowSource(patternData(count: 6_000_000))
        let cache = try makeCache()
        let key = AudioCacheKey.youtube(videoId: "seek")
        _ = try await cache.store.contentInfo(for: key, source: source)

        let early = Task { try await self.readThroughCache(cache, key: key, source: source, range: 0..<6_000_000) }
        await eventually { source.delivered > 50_000 }
        let seek = try await readThroughCache(cache, key: key, source: source, range: 4_000_000..<4_100_000)
        source.speedUp()
        let all = try await early.value

        XCTAssertEqual(seek, source.data.subdata(in: 4_000_000..<4_100_000))
        XCTAssertEqual(all, source.data)
        XCTAssertGreaterThan(source.reads.count, 1, "the seek opened its own fetch rather than waiting behind the first")
        let reads = source.reads.sorted { $0.lowerBound < $1.lowerBound }
        for (a, b) in zip(reads, reads.dropFirst()) {
            // At most a piece or two in flight when the next fetch took over.
            XCTAssertLessThanOrEqual(a.lowerBound + source.deliveredBytes(for: a), b.lowerBound + 2 * 16_384, "no range fetched twice: \(a) and \(b)")
        }
    }

    func testFailedDiskWriteStreamsPastTheDisk() async throws {
        let directory = try makeTemporaryDirectory()
        let cache = try makeCache(directory: directory)
        let key = AudioCacheKey.youtube(videoId: "diskfull")
        let source = MemoryAudioSource(patternData(count: 600_000))
        let info = try await cache.store.contentInfo(for: key, source: source)
        // Make the entry's data file unwritable, as a full disk would.
        let dataFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
            .deletingPathExtension().appendingPathExtension("audio")
        FileManager.default.createFile(atPath: dataFile.path(percentEncoded: false), contents: nil)
        XCTAssertEqual(chflags(dataFile.path(percentEncoded: false), UInt32(UF_IMMUTABLE)), 0)
        addTeardownBlock { _ = chflags(dataFile.path(percentEncoded: false), 0) }

        let data = try await readThroughCache(cache, key: key, source: source, range: 0..<600_000, knownInfo: info)

        XCTAssertEqual(data, source.data, "the listener still gets the audio")
        let cached = await cache.cachedPrefixBytes(of: key)
        XCTAssertEqual(cached, 0)
    }

    func testSourceThatEndsEarlyFailsInsteadOfSpinning() async throws {
        let cache = try makeCache()
        let key = AudioCacheKey.youtube(videoId: "short")
        let source = LyingSource(claimed: 1_000_000, actual: patternData(count: 300_000))

        do {
            _ = try await readThroughCache(cache, key: key, source: source, range: 0..<1_000_000)
            XCTFail("the source can't deliver what it claimed")
        } catch {
            XCTAssertEqual(error as? AudioCacheError, .unexpectedEndOfStream(key: key, position: 300_000))
        }
    }
}

/// Streams in 16 KB pieces with a pause between them, so tests can act mid-fetch. Sped up, the
/// pause is short rather than gone: like a network, it keeps producing at a finite rate, so what
/// it delivered is what a consumer that stops could actually have been sent.
private final class SlowSource: AudioRangeDataSource, @unchecked Sendable {
    let data: Data
    private let lock = NSLock()
    private var _delivered = 0
    private var _reads: [Range<Int64>] = []
    private var _perRange: [Range<Int64>: Int64] = [:]
    private var _delay: Duration = .milliseconds(5)

    init(_ data: Data) { self.data = data }

    var delivered: Int { lock.withLock { _delivered } }
    var reads: [Range<Int64>] { lock.withLock { _reads } }
    func deliveredBytes(for range: Range<Int64>) -> Int64 { lock.withLock { _perRange[range] ?? 0 } }
    func speedUp() { lock.withLock { _delay = .milliseconds(1) } }

    func contentInfo() async throws -> AudioContentInfo {
        AudioContentInfo(contentLength: Int64(data.count), mimeType: "audio/mp4")
    }

    func read(_ range: Range<Int64>) async throws -> Data {
        var result = Data()
        for try await piece in stream(range) { result.append(piece) }
        return result
    }

    func stream(_ range: Range<Int64>) -> AsyncThrowingStream<Data, Error> {
        lock.withLock { _reads.append(range) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                var position = range.lowerBound
                while position < min(range.upperBound, Int64(self.data.count)) {
                    if Task.isCancelled { break }
                    let delay = self.lock.withLock { self._delay }
                    if delay > .zero { try? await Task.sleep(for: delay) }
                    let end = min(position + 16_384, range.upperBound, Int64(self.data.count))
                    let piece = self.data.subdata(in: Int(position)..<Int(end))
                    self.lock.withLock {
                        self._delivered += piece.count
                        self._perRange[range, default: 0] += Int64(piece.count)
                    }
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

/// Claims a length it can't deliver.
private struct LyingSource: AudioRangeDataSource {
    let claimed: Int64
    let actual: Data

    func contentInfo() async throws -> AudioContentInfo {
        AudioContentInfo(contentLength: claimed, mimeType: "audio/mp4")
    }

    func read(_ range: Range<Int64>) async throws -> Data {
        let end = min(range.upperBound, Int64(actual.count))
        guard range.lowerBound < end else { return Data() }
        return actual.subdata(in: Int(range.lowerBound)..<Int(end))
    }
}
