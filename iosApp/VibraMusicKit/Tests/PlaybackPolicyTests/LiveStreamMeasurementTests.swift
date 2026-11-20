import XCTest
import AVFoundation
import VibraMusicCore
@testable import PlaybackPolicy

/// Measures real HLS streams through a playing `AVPlayerItem` — the access-log and item-track path
/// that files on disk can't exercise. Skipped unless `VIBRAMUSIC_LIVE_TESTS=1`.
///
/// Apple's public HLS example is used because it is stable and carries audio-only renditions in the
/// two shapes this module labels: stereo AAC (what YouTube's iOS formats and JioSaavn serve) and
/// 5.1 E-AC-3 (the codec Dolby Atmos rides in).
final class LiveStreamMeasurementTests: XCTestCase {
    private static let base = "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4"

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["VIBRAMUSIC_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Live test: set VIBRAMUSIC_LIVE_TESTS=1 to run against the real stream.")
        }
    }

    /// Plays `url` muted until the item has an audio track and an access-log entry, then measures it.
    private func measurePlaying(_ url: URL, timeout: TimeInterval = 30) async throws -> MeasuredAudioFormat {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()
        defer { player.pause() }

        let deadline = Date().addingTimeInterval(timeout)
        var last: MeasuredAudioFormat?
        while Date() < deadline {
            if item.status == .failed { throw item.error ?? URLError(.cannotLoadFromNetwork) }
            let ready = item.status == .readyToPlay && (item.accessLog()?.events.isEmpty == false)
            if ready, let measured = await AudioFormatMeasurement.measure(playerItem: item) {
                last = measured
                if measured.mimeType != nil && measured.bitrateKbps != nil { return measured }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        return try XCTUnwrap(last, "nothing measured within \(timeout) s")
    }

    func testAStereoAACRenditionIsMeasuredFromTheLiveStream() async throws {
        let measured = try await measurePlaying(URL(string: "\(Self.base)/a1/prog_index.m3u8")!)
        print("LIVE a1:", measured)

        XCTAssertEqual(measured.mimeType, "audio/mp4a-latm")
        XCTAssertEqual(measured.channels, 2)
        XCTAssertEqual(measured.sampleRateHz, 48_000)
        let kbps = try XCTUnwrap(measured.bitrateKbps, "the access log states the rendition's audio bitrate")
        XCTAssertTrue((64...400).contains(kbps), "implausible AAC bitrate \(kbps)")

        let stats = NerdStats()
        stats.publish(measured: measured, mediaId: "bipbop", sourceName: "Apple")
        XCTAssertEqual(stats.current?.statsLine?.hasPrefix("AAC · 48.0 kHz · "), true, stats.current?.statsLine ?? "")
        XCTAssertFalse(stats.current?.isLossless ?? true)
    }

    func testAnEAC3RenditionReadsAsDolby() async throws {
        let measured = try await measurePlaying(URL(string: "\(Self.base)/a3/prog_index.m3u8")!)
        print("LIVE a3:", measured)

        XCTAssertEqual(measured.mimeType, "audio/eac3")
        XCTAssertEqual(measured.channels, 6)
        let stats = NerdStats()
        stats.publish(measured: measured, mediaId: "bipbop", sourceName: "Apple")
        XCTAssertEqual(
            PlaybackQualityBadge.resolve(isLoading: false, stillRacing: false, effectiveQuality: .lossless, stats: stats.current),
            .dolbyAtmos
        )
    }
}
