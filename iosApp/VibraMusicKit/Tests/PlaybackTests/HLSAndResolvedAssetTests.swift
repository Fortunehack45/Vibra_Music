import AVFoundation
import VibraMusicCore
import XCTest
@testable import Playback

/// Items whose asset has no asset-level audio track (an HLS playlist) and items opened through
/// ``PlayableItem/Source/resolvedAsset(_:)``.
@MainActor
final class HLSAndResolvedAssetTests: EngineTestCase {
    func testAnHLSPlaylistWithNoAssetLevelAudioTrackBecomesReadyAndPlays() async throws {
        let (server, playlist) = try await HLSFixture.serve(seconds: 7)
        defer { server.stop() }
        let tracks = try await AVURLAsset(url: playlist).loadTracks(withMediaType: .audio)
        XCTAssertTrue(tracks.isEmpty, "the case under test: HLS exposes no asset-level audio track")
        XCTAssertTrue(AVURLAsset(url: playlist).isStreamingPlaylist)

        let item = PlayableItem(id: "hls", title: "HLS", artist: "Test", source: .asset { AVURLAsset(url: playlist) })
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("HLS playing", timeout: 20) { h.engine.isPlaying && h.engine.position > 1 }
        XCTAssertNil(h.engine.lastError)
        XCTAssertTrue(h.delegate.failures.isEmpty, "\(h.delegate.failures)")
        XCTAssertEqual(h.engine.duration ?? 0, 7, accuracy: 0.5)
        XCTAssertTrue(server.requestedPaths.contains("/hls/seg-0.m4s"), "\(server.requestedPaths)")
        await waitUntil("stats from the variant's track", timeout: 10) { h.engine.stats?.codec != nil }
        XCTAssertEqual(h.engine.stats?.codec, "aac")
    }

    func testANonPlaylistAssetWithNoAudioStillFails() async throws {
        let empty = directory.appendingPathComponent("empty.m4a")
        try Data().write(to: empty)
        XCTAssertFalse(AVURLAsset(url: empty).isStreamingPlaylist)
        let item = PlayableItem(id: "none", title: "None", artist: "Test", source: .asset { AVURLAsset(url: empty) })
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("failure reported", timeout: 10) { !h.delegate.failures.isEmpty || h.engine.lastError != nil }
        XCTAssertFalse(h.engine.isPlaying)
    }

    func testAResolvedAssetReportsItsStreamsLoudnessAndDeclaredFormat() async throws {
        let url = try ToneFile.write([.tone(frequency: 440, seconds: 4)], to: directory, name: "cached", container: .aac(bitrate: 128_000))
        let declared = StreamFormat(codec: "aac", kbps: 256)
        let item = PlayableItem(id: "resolved", title: "Resolved", artist: "Test", source: .resolvedAsset {
            let stream = ResolvedStream(url: URL(string: "https://example.com/remote")!, origin: .youtube, format: declared, loudnessDb: -7.5)
            return (AVURLAsset(url: url), stream)
        }, loudnessDb: -1)
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("playing", timeout: 10) { h.engine.isPlaying && h.engine.position > 0.3 }
        let processor = try XCTUnwrap(h.processors[h.engine.activeDeckID])
        await waitUntil("processor told about the item") { !processor.begunItems.isEmpty }
        XCTAssertEqual(processor.begunItems.last?.id, "resolved")
        XCTAssertEqual(processor.begunItems.last?.loudnessDb, -7.5, "the stream's loudness wins over the item's")
        await waitUntil("stats", timeout: 10) { h.engine.stats?.declared != nil }
        XCTAssertEqual(h.engine.stats?.declared, declared)
        XCTAssertEqual(h.engine.stats?.codec, "aac")
    }

    /// The item was built declaring the Atmos mix its row last resolved to, but the open played a
    /// copy nothing resolved (YouTube's, whole on disk) and says so with a nil stream. The engine
    /// goes by the open: the AAC is processed, not passed through, and its stats claim nothing.
    /// Going by the item's stale claim would keep the DSP chain off for that play.
    func testAResolvedAssetWithNoStreamOverridesTheItemsDeclaredFormat() async throws {
        let url = try ToneFile.write([.tone(frequency: 440, seconds: 4)], to: directory, name: "from-disk", container: .aac(bitrate: 128_000))
        let item = PlayableItem(id: "from-disk", title: "From Disk", artist: "Test", source: .resolvedAsset {
            (AVURLAsset(url: url), nil)
        }, declaredFormat: StreamFormat(codec: "eac3-joc", kbps: 768, channels: 6))
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("opened") { h.engine.signalPath != nil }
        XCTAssertEqual(h.engine.signalPath, .processed, "the copy that plays is AAC")

        await waitUntil("stats", timeout: 10) { h.engine.stats?.itemID == item.id && h.engine.stats?.codec != nil }
        XCTAssertEqual(h.engine.stats?.codec, "aac")
        XCTAssertNil(h.engine.stats?.declared, "nothing claims the Atmos mix is playing")
    }
}
