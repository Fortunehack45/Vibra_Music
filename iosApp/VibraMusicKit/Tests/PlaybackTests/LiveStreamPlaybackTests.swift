import AVFoundation
import VibraMusicCore
import XCTest
@testable import Playback

/// The engine playing a real remote stream over HTTPS through a ``PlayableItem/Source/stream(_:)``
/// source: resolved on demand, opened with the stream's headers and MIME hint, seekable by range
/// requests. Skipped unless `VIBRAMUSIC_LIVE_TESTS=1`.
@MainActor
final class LiveStreamPlaybackTests: EngineTestCase {
    /// A long-lived public MP3 (served with byte ranges since 2011).
    static let streamURL = URL(string: "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3")!

    override func setUp() async throws {
        try await super.setUp()
        guard ProcessInfo.processInfo.environment["VIBRAMUSIC_LIVE_TESTS"] == "1" else {
            throw XCTSkip("live network test; set VIBRAMUSIC_LIVE_TESTS=1 to run")
        }
    }

    func testARemoteStreamPlaysSeeksAndReportsItsFormat() async throws {
        var resolutions = 0
        let item = PlayableItem(id: "live-stream", title: "SoundHelix Song 1", artist: "SoundHelix", source: .stream {
            await MainActor.run { resolutions += 1 }
            return ResolvedStream(
                url: Self.streamURL,
                origin: .addon,
                mimeType: "audio/mpeg",
                format: StreamFormat(codec: "mp3", kbps: 192),
                headers: ["User-Agent": VibraMusicHTTP.UserAgent.app]
            )
        })
        let h = harness(queue: [item])
        h.engine.load(item, playWhenReady: true)
        await waitUntil("streaming", timeout: 30) { h.engine.isPlaying && h.engine.position > 1 }
        XCTAssertEqual(resolutions, 1, "resolved once, when it was needed")
        XCTAssertEqual(h.engine.duration, 372, accuracy: 3)
        XCTAssertEqual(h.engine.signalPath, .processed)
        XCTAssertGreaterThan(h.processors[h.engine.activeDeckID]?.frames ?? 0, 10_000, "the tap processes a remote stream too")

        await waitUntil("stats", timeout: 15) { h.engine.stats?.codec != nil }
        XCTAssertEqual(h.engine.stats?.codec, "mp3")
        XCTAssertEqual(h.engine.stats?.sampleRateHz, 44_100)
        XCTAssertEqual(h.engine.stats?.declared?.kbps, 192)

        // A seek far ahead is served by a range request, not by downloading up to it.
        h.engine.seek(to: 200)
        await waitUntil("playing past the seek", timeout: 30) { h.engine.isPlaying && h.engine.position > 201 }
        XCTAssertNil(h.engine.lastError)
    }
}
