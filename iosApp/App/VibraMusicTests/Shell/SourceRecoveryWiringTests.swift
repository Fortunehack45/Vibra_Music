import AudioCache
import VibraMusicCore
import Foundation
import Playback
import XCTest
@testable import Vibra Music

/// The engine's `sourceRecovery` hook is wired to the app's sources: a download whose file has
/// gone from under it streams, and a stream that dies is rebuilt on a clean cache.
@MainActor
final class SourceRecoveryWiringTests: XCTestCase {
    func testADownloadWhoseFileIsGoneStreamsInstead() async throws {
        let harness = PlayerHarness(test: self)
        let song = try harness.song("goneDownload", seconds: 8)
        let gone = harness.directory.appending(path: "gone.m4a")
        // The library said the file was there when the queue was built; it is not when it opens.
        var forgotten: [String] = []
        harness.factory.savedFile = { _ in forgotten.isEmpty ? SavedAudioFile(url: gone, isYouTubeOrigin: false) : nil }
        harness.factory.forgetMissing = { forgotten.append($0.videoId) }
        // Watches what the engine asks for, so a missing file that only played after a retry fails.
        var reasons: [RecoveryReason] = []
        let wired = try XCTUnwrap(harness.engine.sourceRecovery)
        harness.engine.sourceRecovery = { item, reason in
            reasons.append(reason)
            return try await wired(item, reason)
        }

        harness.player.play([song], startAt: 0)

        await waitUntil("the stream plays") { harness.engine.isPlaying }
        XCTAssertEqual(forgotten, [song.videoId], "the dead record is dropped so the next play doesn't hit it")
        XCTAssertEqual(harness.engine.currentItem?.song?.videoId, song.videoId)
        XCTAssertEqual(reasons, [.missingLocalFile(gone)], "streamed straight away, without spending a retry")
        XCTAssertNil(harness.engine.lastError)
    }

    func testARowWhoseIdIsTheMissingPathHasNoStreamToFallBackOn() async {
        let harness = PlayerHarness(test: self)
        let path = harness.directory.appending(path: "device-track.m4a").path
        let song = Song(videoId: path, title: "Device", artist: "A")
        let item = harness.factory.item(for: song)

        let replacement = await harness.factory.recoveredSource(for: item, reason: .missingLocalFile(URL(fileURLWithPath: path)))

        XCTAssertNil(replacement, "reopening the same dead path would fail the same way")
    }

    func testADyingStreamLosesItsCachedBytesBeforeItIsReopened() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let harness = PlayerHarness(test: self, cache: cache)
        let song = try harness.song("dyingStream", seconds: 6)
        let filled = await cache.fillFullyCachedYouTube(song.videoId, from: harness.directory.appending(path: "dyingStream.m4a"))
        XCTAssertTrue(filled)
        let item = harness.factory.item(for: song)

        let replacement = await harness.factory.recoveredSource(for: item, reason: .retry(attempt: 1))

        XCTAssertNotNil(replacement)
        let left = await cache.renditions(ofTrack: song.videoId)
        XCTAssertTrue(left.isEmpty, "an entry filled from two files reads fine until the seam: it goes, not just the choice of source")
    }

    /// A complete copy says nothing wrong when the network fails: a retry after a network fault
    /// keeps it and drops only what is half on disk (Android's `discard(keepComplete)`).
    func testARetryAfterANetworkFaultKeepsTheCompleteCopies() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let harness = PlayerHarness(test: self, cache: cache)
        let song = try harness.song("networkFault", seconds: 6)
        let file = harness.directory.appending(path: "networkFault.m4a")
        let filled = await cache.fillFullyCachedYouTube(song.videoId, from: file)
        XCTAssertTrue(filled)
        let partial = AudioCacheKey.substitute(videoId: song.videoId, atmosAllowed: true)
        await cache.warmRange(partial, source: InMemoryAudioSource(data: try Data(contentsOf: file), mimeType: "audio/mp4"), range: 0..<1_024)
        let before = await cache.renditions(ofTrack: song.videoId).map(\.key)
        XCTAssertEqual(Set(before), [.youtube(videoId: song.videoId), partial])

        _ = await harness.factory.recoveredSource(for: harness.factory.item(for: song), reason: .retry(attempt: 1, networkFault: true))

        let left = await cache.renditions(ofTrack: song.videoId).map(\.key)
        XCTAssertEqual(left, [.youtube(videoId: song.videoId)], "the whole copy stays for offline play; the half-filled one goes")
    }

    /// An add-on's stream that dies is not retried against the same dead copy: the track carries on
    /// from YouTube's own upload, and the add-on isn't asked again.
    func testAFailedSubstituteFallsBackToYouTube() async throws {
        let youTube = FakeStreamResolver()
        let harness = PlayerHarness(test: self, youTube: youTube)
        let id = "deadSubstitute"
        let dead = harness.directory.appending(path: "\(id).m4a")
        try Data(repeating: 0x5A, count: 4_096).write(to: dead)
        harness.resolver.serve(id, from: dead, origin: .addon)
        youTube.serve(id, from: try TestAudio.tone(seconds: 8, in: harness.directory, name: "\(id)-youtube"), origin: .youtube)

        harness.player.play([Song(videoId: id, title: "Dead", artist: "A", durationText: "0:08")], startAt: 0)

        await waitUntil("YouTube's copy plays") { harness.engine.isPlaying }
        XCTAssertEqual(harness.engine.currentItem?.id.hasSuffix("#original"), true, "a new item: the fallback spends none of YouTube's retries")
        XCTAssertEqual(harness.resolver.requestedIds, [id], "the add-on's dead copy is not asked for again")
        XCTAssertEqual(youTube.requestedIds, [id])
        XCTAssertEqual(harness.player.currentStream?.origin, .youtube)
        XCTAssertNil(harness.engine.lastError)
    }

    /// An upgrade's copy that dies is not reopened: the row goes back to YouTube's own at the place
    /// it had reached.
    func testAFailedUpgradeFallsBackToYouTubeWhereItWas() async throws {
        let youTube = FakeStreamResolver()
        let harness = PlayerHarness(test: self, youTube: youTube)
        let song = try harness.song("deadUpgrade", seconds: 20, origin: .youtube)
        youTube.serve(song.videoId, from: harness.directory.appending(path: "deadUpgrade.m4a"), origin: .youtube)
        let dead = harness.directory.appending(path: "deadUpgrade-flac.m4a")
        try Data(repeating: 0x5A, count: 4_096).write(to: dead)
        harness.player.play([song], startAt: 0)
        await waitUntil("playing") { harness.engine.isPlaying && harness.engine.position >= 1 }
        let reached = harness.engine.position

        harness.player.reopenCurrent(onRendition: "hifi", stream: ResolvedStream(url: dead, origin: .addon, mimeType: "audio/mp4",
                                                                                 format: StreamFormat(codec: "flac")))

        await waitUntil("YouTube's copy plays again") {
            harness.engine.currentItem?.id.hasSuffix("#original") == true && harness.engine.isPlaying
        }
        XCTAssertGreaterThanOrEqual(harness.engine.position, reached - 0.5, "it carries on where it was, not from the top")
        XCTAssertEqual(youTube.requestedIds, [song.videoId])
        XCTAssertNil(harness.engine.lastError)
    }

    /// A media services reset must not delete a whole copy: `-11819` while the row opens, with a whole add-on
    /// copy on disk and YouTube ready behind it. It says nothing against the copy, and the row is
    /// opened again as it was.
    func testAMediaServicesResetKeepsTheWholeCopyAndRefusesNothing() async throws {
        let cache = try makeTestCache(in: makeTemporaryDirectory(self))
        let streams = ResetOnceResolver()
        let youTube = FakeStreamResolver()
        let harness = PlayerHarness(test: self, cache: cache, request: { StreamRequest(tier: .best) }, streams: streams, youTube: youTube)
        let song = try harness.song("resetWhole", seconds: 6)
        let file = harness.directory.appending(path: "resetWhole.m4a")
        streams.answer = ResolvedStream(url: file, origin: .addon, mimeType: "audio/mp4", format: StreamFormat(codec: "flac"))
        let whole = AudioCacheKey.substitute(videoId: song.videoId, atmosAllowed: true)
        let filled = await cache.cacheCompletely(whole, source: InMemoryAudioSource(data: try Data(contentsOf: file), mimeType: "audio/mp4"))
        XCTAssertTrue(filled)

        harness.player.play([song], startAt: 0)
        await waitUntil("the row is current") { harness.engine.currentItem != nil }
        let row = harness.engine.currentItem?.id

        await waitUntil("opened again after the reset") { streams.asked >= 2 }
        let left = await cache.renditions(ofTrack: song.videoId)
        XCTAssertEqual(left.first { $0.key == whole }?.isComplete, true, "one system hiccup is no reason to fetch a whole copy again")
        XCTAssertFalse(harness.factory.streamChoice.substitutesRefused(for: song.videoId), "the add-on's copy stays allowed")
        XCTAssertEqual(harness.engine.currentItem?.id, row, "not moved to YouTube's rendition, which is a new item")
        XCTAssertEqual(youTube.requestedIds, [])
        XCTAssertNil(harness.engine.lastError)
    }

    /// A reset under a copy still streaming: a resolve could land on another copy, so the one that
    /// was playing opens again, with nothing asked of anyone.
    func testAMediaServicesResetReopensAStreamingCopyWithoutResolving() async throws {
        let youTube = FakeStreamResolver()
        let harness = PlayerHarness(test: self, youTube: youTube)
        let song = try harness.song("resetStream", seconds: 20)
        harness.player.play([song], startAt: 0)
        await waitUntil("playing") { harness.engine.isPlaying && harness.engine.position >= 1 }
        let reached = harness.engine.position
        let item = harness.engine.currentItem?.id

        // What an item's report asks of the app, on a copy that would fall to YouTube if it died.
        let playing = try XCTUnwrap(harness.engine.currentItem)
        XCTAssertTrue(harness.factory.diedAboveYouTube(playing), "the case a fallback would take")
        let wired = try XCTUnwrap(harness.engine.sourceRecovery)
        let sameCopy = try await wired(playing, .systemFault)
        XCTAssertNotNil(sameCopy, "the copy that was playing, handed back to open afresh")

        harness.engine.handleAudioSessionEvent(.mediaServicesReset)

        await waitUntil("playing again") { harness.engine.isPlaying }
        XCTAssertGreaterThanOrEqual(harness.engine.position, reached - 0.5, "where it was, not from the top")
        XCTAssertEqual(harness.engine.currentItem?.id, item)
        XCTAssertEqual(harness.resolver.requestedIds, [song.videoId], "not resolved a second time")
        XCTAssertEqual(youTube.requestedIds, [])
        XCTAssertEqual(harness.player.currentStream?.origin, .addon)
        XCTAssertFalse(harness.factory.streamChoice.substitutesRefused(for: song.videoId))
        XCTAssertNil(harness.engine.lastError)
    }
}

/// Reports a media-services reset to its first resolve, as an open under way would hear of one, and
/// answers the rest.
private final class ResetOnceResolver: StreamResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var stream: ResolvedStream?

    var asked: Int { lock.withLock { count } }
    var answer: ResolvedStream? {
        get { lock.withLock { stream } }
        set { lock.withLock { stream = newValue } }
    }

    func resolveStream(for song: Song, request: StreamRequest) async throws -> ResolvedStream {
        let (first, answer) = lock.withLock {
            count += 1
            return (count == 1, stream)
        }
        if first { throw NSError(domain: "AVFoundationErrorDomain", code: -11819) }
        guard let answer else { throw URLError(.fileDoesNotExist) }
        return answer
    }
}
