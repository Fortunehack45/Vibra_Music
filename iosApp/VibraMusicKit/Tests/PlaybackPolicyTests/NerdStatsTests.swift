import XCTest
import Observation
import VibraMusicCore
@testable import PlaybackPolicy

/// Stats for nerds: the line, the claim-versus-measurement rule, and how a measurement becomes a
/// snapshot (PORTING.md, Stats for nerds).
final class NerdStatsTests: XCTestCase {
    private var stats: NerdStats!

    override func setUp() {
        super.setUp()
        stats = NerdStats()
    }

    // MARK: The stats line

    func testTheLineStatesOnlyWhatWasReported() {
        let hiRes = NerdStats.Snapshot(mimeType: "audio/flac", bitrateKbps: 4608, sampleRateHz: 96_000, channels: 2, bitDepth: 24)
        XCTAssertEqual(hiRes.statsLine, "FLAC · 24-bit · 96.0 kHz · 4608 kbps · Stereo")

        let aac = NerdStats.Snapshot(mimeType: "audio/mp4a-latm", bitrateKbps: 128, sampleRateHz: 44_100, channels: 1)
        XCTAssertEqual(aac.statsLine, "AAC · 44.1 kHz · 128 kbps · Mono")

        let surround = NerdStats.Snapshot(mimeType: "audio/eac3", bitrateKbps: nil, sampleRateHz: nil, channels: 6)
        XCTAssertEqual(surround.statsLine, "E-AC-3 · 6 ch")

        XCTAssertNil(NerdStats.Snapshot(mimeType: nil, bitrateKbps: nil, sampleRateHz: nil, channels: nil).statsLine)
    }

    /// A source promising 24/192 while the decoder reports 16/48 is the most likely way for a
    /// lossless setting to be quietly doing nothing.
    func testADowngradeFromTheClaimIsStatedOutright() {
        let claimed = StreamFormat(codec: "flac", sampleRateHz: 192_000, bitDepth: 24)
        let arrived = NerdStats.Snapshot(mimeType: "audio/flac", bitrateKbps: 1536, sampleRateHz: 48_000, channels: 2, bitDepth: 16, claimed: claimed)
        XCTAssertTrue(arrived.downgraded)
        XCTAssertEqual(arrived.statsLine, "FLAC · 16-bit · 48.0 kHz · 1536 kbps · Stereo · ↓ from FLAC · 24-bit · 192 kHz")
    }

    /// An absent measurement is not evidence of a downgrade.
    func testAnUnstatedFigureIsNeverADowngrade() {
        let claimed = StreamFormat(codec: "flac", sampleRateHz: 192_000, bitDepth: 24)
        let unmeasured = NerdStats.Snapshot(mimeType: "audio/flac", bitrateKbps: nil, sampleRateHz: nil, channels: 2, bitDepth: nil, claimed: claimed)
        XCTAssertFalse(unmeasured.downgraded)
        let asPromised = NerdStats.Snapshot(mimeType: "audio/flac", bitrateKbps: nil, sampleRateHz: 192_000, channels: 2, bitDepth: 24, claimed: claimed)
        XCTAssertFalse(asPromised.downgraded)
    }

    /// The decoder gets the only word: a source that said "FLAC" and served AAC lights nothing.
    func testTheClaimAloneNeverMakesAStreamLossless() {
        let lying = NerdStats.Snapshot(mimeType: "audio/mp4a-latm", bitrateKbps: 160, sampleRateHz: 44_100, channels: 2, claimed: StreamFormat(codec: "flac"))
        XCTAssertFalse(lying.isLossless)
        XCTAssertFalse(lying.isHiRes)
        XCTAssertTrue(NerdStats.Snapshot(mimeType: "audio/raw", bitrateKbps: nil, sampleRateHz: nil, channels: nil).isLossless)
        XCTAssertTrue(NerdStats.Snapshot(mimeType: "audio/eac3-joc", bitrateKbps: 768, sampleRateHz: 48_000, channels: 6).isDolbyAtmos)
        XCTAssertFalse(NerdStats.isLosslessMime(nil))
    }

    // MARK: Publishing a measurement

    /// A lossless stream reports what its samples decode to, not its compressed rate.
    func testALosslessMeasurementReportsItsPCMRate() {
        stats.publish(
            measured: MeasuredAudioFormat(mimeType: "audio/flac", sampleRateHz: 96_000, channels: 2, bitDepth: 24, bitrateKbps: 3_827),
            mediaId: "t",
            sourceName: "Unified Addon"
        )
        XCTAssertEqual(stats.current?.bitrateKbps, 4608)
        XCTAssertEqual(stats.current?.sourceName, "Unified Addon")
        XCTAssertTrue(stats.current?.isHiRes == true)
    }

    /// Lossy: the measured rate, then what the source declared, then what YouTube's resolver
    /// picked — the source ahead of YouTube because a track upgraded mid-song still has YouTube's
    /// stale figure recorded.
    func testALossyBitrateFallsBackFromMeasuredToDeclaredToPicked() {
        stats.onStreamPicked("t", kbps: 160)
        stats.onSourceStream("t", format: StreamFormat(codec: "aac", kbps: 320), source: "JioSaavn")

        stats.publish(measured: MeasuredAudioFormat(mimeType: "audio/mp4a-latm", sampleRateHz: 44_100, channels: 2, bitrateKbps: 317), mediaId: "t", sourceName: nil)
        XCTAssertEqual(stats.current?.bitrateKbps, 317)

        stats.publish(measured: MeasuredAudioFormat(mimeType: "audio/mp4a-latm", sampleRateHz: 44_100, channels: 2), mediaId: "t", sourceName: nil)
        XCTAssertEqual(stats.current?.bitrateKbps, 320)
        XCTAssertEqual(stats.current?.claimed?.kbps, 320)

        stats.clearDeclared("t")
        stats.publish(measured: MeasuredAudioFormat(mimeType: "audio/mp4a-latm", sampleRateHz: 44_100, channels: 2), mediaId: "t", sourceName: nil)
        XCTAssertEqual(stats.current?.bitrateKbps, 160)
        XCTAssertNil(stats.current?.claimed)
    }

    func testANotYetMeasuredItemPublishesOnlyTheClaim() {
        stats.onSourceStream("3919244", format: StreamFormat(codec: "flac", sampleRateHz: 44_100, bitDepth: 16))
        stats.publish(measured: nil, mediaId: "src:addon-1::3919244", sourceName: "Unified Addon")
        XCTAssertNil(stats.current?.mimeType)
        XCTAssertFalse(stats.current?.isLossless == true, "a claim never lights the badge")
        XCTAssertEqual(stats.current?.claimed?.codec, "flac", "declared formats unwrap source keys")
    }

    func testPickedBitratesIgnoreNonPositiveValues() {
        stats.onStreamPicked("t", kbps: 0, source: " ")
        XCTAssertNil(stats.pickedBitrateKbps(for: "t"))
        XCTAssertNil(stats.source(for: "t"))
    }

    // MARK: Racing

    /// Read-ahead starts races for other tracks on other threads; none may erase another's marker.
    func testConcurrentRaceStartsAreAllKept() {
        let ids = (0..<200).map { "track-\($0)" }
        DispatchQueue.concurrentPerform(iterations: ids.count) { index in
            stats.onLosslessRaceStart(ids[index])
        }
        XCTAssertEqual(stats.racingLossless, Set(ids))
        DispatchQueue.concurrentPerform(iterations: ids.count) { index in
            if index.isMultiple(of: 2) { stats.onLosslessRaceEnd(ids[index]) }
        }
        XCTAssertEqual(stats.racingLossless.count, 100)
    }

    func testTheBadgeStateIsObservable() {
        let changed = expectation(description: "racing changed")
        withObservationTracking {
            _ = stats.racingLossless
        } onChange: {
            changed.fulfill()
        }
        stats.onLosslessRaceStart("t")
        wait(for: [changed], timeout: 2)
    }

    // MARK: Who is serving the track

    func testSourceNamesFollowTheAndroidOrderOfPrecedence() {
        let choice = StreamChoice()
        let names = ["addon-1": "Unified Addon", "jiosaavn": "JioSaavn"]
        func name(_ id: String?, uri: String? = nil, local: Bool = false, upgrade: QualityUpgrade? = nil) -> String? {
            stats.sourceName(for: id, playbackURI: uri, isLocalPlayback: local, qualityUpgrade: upgrade, streamChoice: choice) { names[$0] }
        }

        XCTAssertNil(name(nil))
        XCTAssertEqual(name("abc", local: true), "Local Storage")

        let upgrade = QualityUpgrade.testInstance(streamChoice: choice)
        upgrade.force("5IX-nUxDtJI", stream: Streams.make("tidal", codec: "flac", sourceConfigId: "addon-1"))
        XCTAssertEqual(name("5IX-nUxDtJI", uri: "vibramusic://watch?v=5IX-nUxDtJI&q=hifi", upgrade: upgrade), "Unified Addon")

        stats.recordSource("recorded", "Recorded Name")
        XCTAssertEqual(name("recorded"), "Recorded Name")

        XCTAssertEqual(name("src:jiosaavn::123"), "JioSaavn")
        XCTAssertEqual(name("src:deleted-config::123"), "Unknown")

        choice.remember(Streams.make("saavn", codec: "aac", sourceConfigId: "jiosaavn"), for: "substituted", substituted: true)
        XCTAssertEqual(name("substituted"), "JioSaavn")
        choice.remember(Streams.make("module", codec: "aac"), for: "anon", substituted: true)
        XCTAssertEqual(name("anon"), "Module")

        XCTAssertEqual(name("key", uri: "vibramusic://source?s=addon-1&t=9"), "Unified Addon")
        XCTAssertEqual(name("key", uri: "vibramusic://source?s=gone&t=9"), "Unknown")

        XCTAssertEqual(name("5IX-nUxDtJI"), "YouTube", "an 11-character id")
        XCTAssertEqual(name("longer-than-eleven", uri: "vibramusic://watch?v=longer-than-eleven"), "YouTube")
        XCTAssertEqual(name("odd"), "Unknown")
    }
}
