import AudioCache
import AVFoundation
import XCTest
@testable import Playback

/// AVPlayer reporting an item's end well short of its length: the song isn't over, and the
/// queue doesn't move. A real end, whatever the catalogue claims, still moves it.
@MainActor
final class ShortEndTests: EngineTestCase {
    /// A file's bytes, withheld from `gate` on until `openGate()`: a segment still on its way.
    private final class GatedSource: AudioRangeDataSource, @unchecked Sendable {
        let data: Data
        let knownDuration: TimeInterval?
        private let lock = NSLock()
        private var gate: Int64
        private var failure: Error?

        init(data: Data, gate: Int, knownDuration: TimeInterval?) {
            self.data = data
            self.gate = Int64(gate)
            self.knownDuration = knownDuration
        }

        func openGate() { lock.withLock { gate = .max } }

        /// The link dies: anything past the gate fails from now on.
        func fail(with error: Error) { lock.withLock { failure = error } }

        func contentInfo() async throws -> AudioContentInfo {
            AudioContentInfo(contentLength: Int64(data.count), mimeType: "audio/mp4")
        }

        func read(_ range: Range<Int64>) async throws -> Data {
            while range.lowerBound >= lock.withLock({ gate }) {
                if let failure = lock.withLock({ failure }) { throw failure }
                try await Task.sleep(for: .milliseconds(20))
            }
            let end = min(range.upperBound, lock.withLock { gate }, Int64(data.count))
            return data.subdata(in: Int(range.lowerBound)..<Int(end))
        }
    }

    private func makeCache() throws -> AudioStreamCache {
        // Free space on the machine running this doesn't come into it.
        try AudioStreamCache(configuration: .init(directory: directory.appendingPathComponent("cache-\(UUID().uuidString)"), networkRetryDelays: [], availableCapacity: { _ in nil }))
    }

    /// A tone played through the cache but never stored: the copy is never whole on disk.
    private func uncachedTone(_ seconds: Double, name: String, catalogue: TimeInterval? = nil) throws -> PlayableItem {
        let url = try ToneFile.write([.tone(frequency: 440, seconds: seconds)], to: directory, name: name, container: .aac(bitrate: 128_000))
        let cache = try makeCache()
        return PlayableItem(id: name, title: name, artist: "A", duration: catalogue, source: .asset {
            cache.makeAsset(for: AudioCacheKey(rawValue: name), source: FileAudioSource(url: url, mimeType: "audio/mp4"))
        })
    }

    func testAnEndReportedFarShortOfTheTrackReopensItAtItsPosition() async throws {
        let item = try uncachedTone(10, name: "short-end")
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing", timeout: 10) { h.engine.isPlaying && h.engine.position > 0.5 }
        let deck = h.engine.deck(h.engine.activeDeckID)
        let first = try XCTUnwrap(deck.current)
        let at = h.engine.position

        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: first.playerItem)

        await waitUntil("reopened", timeout: 10) { deck.current != nil && deck.current !== first }
        await waitUntil("playing on", timeout: 10) { h.engine.isPlaying }
        XCTAssertGreaterThanOrEqual(h.engine.position, at - 0.3, "it carries on where it was, not from the top")
        XCTAssertTrue(h.delegate.finished.isEmpty, "the queue hasn't run dry")
        XCTAssertEqual(h.delegate.changes.map(\.reason), [.requested])
        XCTAssertTrue(h.delegate.failures.isEmpty, "not a failure: nothing is thrown off the disk for it")
    }

    func testTheQueuePlayerMovingOnFarShortOfTheTrackIsTakenBack() async throws {
        let item = try uncachedTone(10, name: "short-gapless")
        let next = try tone(5, frequency: 660, name: "short-gapless-next")
        let h = harness(queue: [item, next])
        h.engine.load(item, playWhenReady: true)
        let deck = h.engine.deck(h.engine.activeDeckID)
        await waitUntil("preloaded", timeout: 10) { deck.queued?.item.id == next.id }
        await waitUntil("playing", timeout: 10) { h.engine.isPlaying && h.engine.position > 0.5 }
        let first = try XCTUnwrap(deck.current)

        // What the queue player does by itself at an item's end, with the next one queued.
        deck.player.advanceToNextItem()

        await waitUntil("reopened", timeout: 10) { deck.current?.item.id == item.id && deck.current !== first }
        XCTAssertEqual(h.delegate.changes.map(\.reason), [.requested], "the next track was never announced")
        XCTAssertEqual(h.engine.currentItem?.id, item.id)
        await waitUntil("the next track queued again", timeout: 10) { deck.queued?.item.id == next.id }
    }

    /// The catalogue is wrong and the whole file is on disk: nothing to reopen.
    func testARealEndShortOfAWrongCatalogueLengthMovesOnAtOnceWhenTheCopyIsWhole() async throws {
        let url = try ToneFile.write([.tone(frequency: 440, seconds: 1)], to: directory, name: "whole", container: .aac(bitrate: 128_000))
        let source = GatedSource(data: try Data(contentsOf: url), gate: .max, knownDuration: nil)
        let cache = try makeCache()
        let key = AudioCacheKey(rawValue: "whole")
        let filled = await cache.cacheCompletely(key, source: source)
        XCTAssertTrue(filled)
        let item = PlayableItem(id: "whole", title: "W", artist: "A", duration: 300, source: .asset { cache.makeAsset(for: key, source: source) })
        let next = try tone(5, frequency: 660, name: "whole-next")
        let h = harness(queue: [item, next])
        var reopened = false
        h.engine.load(item, playWhenReady: true)

        await waitUntil("moved on", timeout: 10) {
            reopened = reopened || h.engine.shortEnd != nil
            return h.engine.currentItem?.id == next.id
        }
        XCTAssertFalse(reopened)
        XCTAssertEqual(h.delegate.changes.map(\.reason), [.requested, .ended])
    }

    /// The catalogue is wrong and the copy isn't whole: one reopen, then it's believed, so a wrong
    /// length can't hold the queue up for long or send it round for ever.
    func testAnEndThatComesBackAtTheSamePlaceIsTakenAsItsEnd() async throws {
        let item = try uncachedTone(1, name: "same-place", catalogue: 300)
        let next = try tone(5, frequency: 660, name: "same-place-next")
        let h = harness(queue: [item, next])
        var reopened = false
        h.engine.load(item, playWhenReady: true)

        await waitUntil("moved on", timeout: 15) {
            reopened = reopened || h.engine.shortEnd != nil
            return h.engine.currentItem?.id == next.id
        }
        XCTAssertTrue(reopened, "it was given the one chance")
        XCTAssertEqual(h.delegate.changes.map(\.reason), [.requested, .ended])
        XCTAssertTrue(h.delegate.failures.isEmpty)
    }

    /// The device's case end to end: a segmented copy whose next fragment is still on its way when
    /// the playhead reaches the last one read. No test double stands in for AVPlayer here.
    func testACopyStillArrivingWaitsAtTheEndOfItsBytesAndPlaysOnWhenTheyArrive() async throws {
        let (item, source, firstSeconds) = try await arrivingCopy(id: "arriving")
        let next = try tone(5, frequency: 660, name: "arriving-next")
        let h = harness(queue: [item, next])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing the first fragment", timeout: 15) { h.engine.position > 0.3 }

        // Long past the end of the first fragment: it would have ended by now.
        try await Task.sleep(for: .seconds(firstSeconds + 1.5))
        XCTAssertEqual(h.delegate.changes.map(\.reason), [.requested], "the end of the bytes isn't the end of the track")
        XCTAssertEqual(h.engine.duration, 12, accuracy: 0.5)
        XCTAssertLessThanOrEqual(h.engine.position, firstSeconds + 0.1)
        XCTAssertTrue(h.engine.isBuffering, "the wait shows")

        source.openGate()
        await waitUntil("played on past the gap", timeout: 30) { h.engine.position > firstSeconds + 0.5 }
        XCTAssertEqual(h.engine.currentItem?.id, item.id)
        XCTAssertEqual(h.delegate.changes.map(\.reason), [.requested])
    }

    /// An end reported with the next fragment still missing: the song waits for it, and is opened
    /// again over it. It doesn't reopen onto nothing, end again at the same place and skip.
    func testAnEndWhileBytesAreMissingWaitsForThemThenPlaysOn() async throws {
        let (item, source, firstSeconds) = try await arrivingCopy(id: "ended-early")
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing the first fragment", timeout: 30) { h.engine.position > 0.3 }
        let deck = h.engine.deck(h.engine.activeDeckID)
        let first = try XCTUnwrap(deck.current)

        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: first.playerItem)
        await waitUntil("waiting for the bytes", timeout: 10) { deck.current == nil && h.engine.isBuffering }
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(h.delegate.changes.map(\.reason), [.requested], "nothing moved while the bytes are missing")
        XCTAssertTrue(h.delegate.finished.isEmpty)

        source.openGate()
        await waitUntil("played on past the gap", timeout: 30) { h.engine.position > firstSeconds + 0.5 }
        XCTAssertEqual(h.engine.currentItem?.id, item.id)
        XCTAssertEqual(h.delegate.changes.map(\.reason), [.requested])
    }

    /// A dead link ends in the usual recovery and then a visible failure: never endless silence, and
    /// never the next song.
    func testAHeldCopyOnADeadLinkFailsIntoRecoveryInsteadOfWaitingForever() async throws {
        let (item, source, _) = try await arrivingCopy(id: "dead-link")
        let next = try tone(5, frequency: 660, name: "dead-link-next")
        let h = harness(queue: [item, next])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing the first fragment", timeout: 30) { h.engine.position > 0.3 }

        source.fail(with: URLError(.notConnectedToInternet))

        await waitUntil("given up on", timeout: 30) { h.delegate.failures.contains { !$0.willRetry } }
        XCTAssertEqual(h.engine.currentItem?.id, item.id, "a track that was playing stays put")
        XCTAssertEqual(h.delegate.changes.map(\.reason), [.requested])
        XCTAssertNotNil(h.engine.lastError, "the failure shows")
    }

    func testAFetchOnALinkThatBringsNothingGivesUpAtItsLimit() async throws {
        let source = GatedSource(data: Data(count: 100_000), gate: 0, knownDuration: 4)
        let asset = try makeCache().makeAsset(for: AudioCacheKey(rawValue: "hung"), source: source)
        do {
            try await AudioStreamCache.fetchAhead(of: asset, at: 0, of: 4, ahead: 2, stallLimit: .milliseconds(200))
            XCTFail("it returned with nothing fetched")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
    }

    /// A segmented copy with only its first fragment available, until the source's gate opens.
    private func arrivingCopy(id: String) async throws -> (item: PlayableItem, source: GatedSource, firstSeconds: Double) {
        let (initialization, segments) = try await FragmentedAAC.make(seconds: 12, segmentSeconds: 2)
        var file = initialization
        var firstEnd = 0
        for (index, segment) in segments.enumerated() {
            file.append(segment.data.dropFirst(try moofOffset(in: segment.data)))
            if index == 0 { firstEnd = file.count }
        }
        let source = GatedSource(data: file, gate: firstEnd, knownDuration: 12)
        let cache = try makeCache()
        let item = PlayableItem(id: id, title: "A", artist: "A", source: .asset {
            cache.makeAsset(for: AudioCacheKey(rawValue: id), source: source)
        })
        return (item, source, segments[0].duration)
    }

    /// A preloaded copy slower than its bitrate, skipped to with its first fragment in hand. It
    /// plays what it has and goes on when the rest comes. Left to AVPlayer's waiting to minimise
    /// stalls, which never predicts such a stream keeps up through a resource loader, it sat silent
    /// with half a minute of it on disk.
    func testAPreloadedCopySlowerThanItsBitratePlaysWhatItHasAndGoesOn() async throws {
        let (second, source, firstSeconds) = try await arrivingCopy(id: "slow-link")
        // Long enough to outlast the preload on a slow machine: if it ends first there's no skip.
        let first = try tone(60, frequency: 660, name: "slow-link-first")
        let h = harness(queue: [first, second])
        h.engine.load(first, playWhenReady: true)
        let deckID = h.engine.activeDeckID
        await waitUntil("preloaded", timeout: 40) { h.engine.deck(deckID).queued?.item.id == second.id }
        XCTAssertTrue(h.engine.skipToNext())

        await waitUntil("playing the audio it has", timeout: 20) { h.engine.currentItem?.id == second.id && h.engine.position > 0.3 }
        source.openGate()
        await waitUntil("played on past what it had", timeout: 30) { h.engine.position > firstSeconds + 0.5 }
        XCTAssertEqual(h.engine.currentItem?.id, second.id)
        XCTAssertNil(h.engine.lastError)
    }

    /// Where a segment's `moof` starts: what precedes it means nothing mid-file, as in
    /// `SegmentedAudioSource`.
    private func moofOffset(in data: Data) throws -> Int {
        var offset = 0
        let bytes = [UInt8](data)
        while offset + 8 <= bytes.count {
            if bytes[offset + 4...offset + 7].elementsEqual("moof".utf8) { return offset }
            let size = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            guard size >= 8 else { break }
            offset += size
        }
        throw URLError(.cannotParseResponse)
    }
}
