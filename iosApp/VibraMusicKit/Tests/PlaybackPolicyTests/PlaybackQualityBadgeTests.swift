import XCTest
import VibraMusicCore
@testable import PlaybackPolicy

/// The badge between the timestamps (Android `LosslessOrStats`).
final class PlaybackQualityBadgeTests: XCTestCase {
    private func stats(_ mime: String, kbps: Int?, rate: Int = 44_100, depth: Int? = nil) -> NerdStats.Snapshot {
        NerdStats.Snapshot(mimeType: mime, bitrateKbps: kbps, sampleRateHz: rate, channels: 2, bitDepth: depth)
    }

    func testConfirmedLosslessShimmersAndHiResIsNamed() {
        let cd = PlaybackQualityBadge.resolve(isLoading: false, stillRacing: false, effectiveQuality: .lossless, stats: stats("audio/flac", kbps: 1411, depth: 16))
        XCTAssertEqual(cd, .lossless)
        XCTAssertEqual(cd?.label, "Lossless")
        XCTAssertEqual(cd?.shimmers, true)

        let hiRes = PlaybackQualityBadge.resolve(isLoading: false, stillRacing: false, effectiveQuality: .lossless, stats: stats("audio/flac", kbps: 4608, rate: 96_000, depth: 24))
        XCTAssertEqual(hiRes?.label, "Hi-Res Lossless")
    }

    /// Still being looked for: a statement of intent, not a result, so no shimmer.
    func testARaceInProgressReadsAsUpgrading() {
        let badge = PlaybackQualityBadge.resolve(isLoading: false, stillRacing: true, effectiveQuality: .high, stats: stats("audio/mp4a-latm", kbps: 128))
        XCTAssertEqual(badge, .upgrading(alreadyHighQuality: false))
        XCTAssertEqual(badge?.label, "Upgrading quality")
        XCTAssertEqual(badge?.shimmers, false)
    }

    /// Naming the floor first: JioSaavn's 320 while a FLAC is chased is already at the top of lossy.
    func testARaceOverAHighQualityStreamNamesTheFloorFirst() {
        let badge = PlaybackQualityBadge.resolve(isLoading: false, stillRacing: true, effectiveQuality: .lossless, stats: stats("audio/mp4a-latm", kbps: 320))
        XCTAssertEqual(badge?.label, "High quality, upgrading")
    }

    /// A race that already found the lossless copy shows the result, not the wait.
    func testARaceOverALosslessStreamShowsLossless() {
        let badge = PlaybackQualityBadge.resolve(isLoading: false, stillRacing: true, effectiveQuality: .lossless, stats: stats("audio/alac", kbps: 1411, depth: 16))
        XCTAssertEqual(badge, .lossless)
    }

    /// Dolby Atmos is final: a look still marked as running doesn't read as "Upgrading quality"
    /// over a measured Atmos copy.
    func testAMeasuredAtmosCopyDoesNotReadAsUpgrading() {
        let atmos = stats("audio/eac3-joc", kbps: 768)
        XCTAssertTrue(atmos.isDolbyAtmos, "the fixture measures as Atmos")
        XCTAssertEqual(PlaybackQualityBadge.resolve(isLoading: false, stillRacing: true, effectiveQuality: .lossless, stats: atmos), .dolbyAtmos)
    }

    /// Buffering reads as "upgrading" only while nothing is measured and lossless was asked for: a
    /// seek rebuffers a track whose quality question was settled long ago.
    func testBufferingOnlyReadsAsUpgradingBeforeAnythingIsMeasured() {
        XCTAssertEqual(
            PlaybackQualityBadge.resolve(isLoading: true, stillRacing: false, effectiveQuality: .lossless, stats: nil),
            .upgrading(alreadyHighQuality: false)
        )
        XCTAssertNil(PlaybackQualityBadge.resolve(isLoading: true, stillRacing: false, effectiveQuality: .high, stats: nil))
        XCTAssertEqual(
            PlaybackQualityBadge.resolve(isLoading: true, stillRacing: false, effectiveQuality: .lossless, stats: stats("audio/mp4a-latm", kbps: 320)),
            .highQuality,
            "a rebuffer over a measured stream keeps its label"
        )
    }

    func testDolbyAtmosAndHighQuality() {
        let atmos = PlaybackQualityBadge.resolve(isLoading: false, stillRacing: false, effectiveQuality: .lossless, stats: stats("audio/eac3", kbps: 768, rate: 48_000))
        XCTAssertEqual(atmos, .dolbyAtmos)
        XCTAssertEqual(atmos?.usesDolbyAtmosGlyph, true)
        XCTAssertEqual(atmos?.shimmers, true)
        XCTAssertEqual(
            PlaybackQualityBadge.resolve(isLoading: false, stillRacing: false, effectiveQuality: .medium, stats: stats("audio/mp4a-latm", kbps: 256)),
            .highQuality
        )
    }

    /// The low and medium labels only describe the ceiling the listener chose.
    func testDataSaverAndMediumFollowTheCeilingInForce() {
        let low = stats("audio/mp4a-latm", kbps: 64)
        XCTAssertEqual(PlaybackQualityBadge.resolve(isLoading: false, stillRacing: false, effectiveQuality: .low, stats: low)?.label, "Data-Saver")
        XCTAssertNil(PlaybackQualityBadge.resolve(isLoading: false, stillRacing: false, effectiveQuality: .lossless, stats: low))

        let medium = stats("audio/mp4a-latm", kbps: 128)
        XCTAssertEqual(PlaybackQualityBadge.resolve(isLoading: false, stillRacing: false, effectiveQuality: .medium, stats: medium)?.label, "Medium Quality")
        XCTAssertNil(PlaybackQualityBadge.resolve(isLoading: false, stillRacing: false, effectiveQuality: .high, stats: medium))
    }

    func testNothingMeasuredAndNothingRacingShowsNothing() {
        XCTAssertNil(PlaybackQualityBadge.resolve(isLoading: false, stillRacing: false, effectiveQuality: .lossless, stats: nil))
    }

    /// The caption shine needs a hi-res stream *and* a route that carries it.
    func testTheOutputCaptionShinesOnlyForHiResOnAHiResRoute() {
        let hiRes = stats("audio/flac", kbps: 4608, rate: 96_000, depth: 24)
        let cd = stats("audio/flac", kbps: 1411, depth: 16)
        var usb = AudioOutputStatus.Snapshot()
        usb.routeKind = .usb
        var airPods = AudioOutputStatus.Snapshot()
        airPods.routeKind = .bluetooth
        airPods.hardwareSampleRateHz = 48_000
        var speakerAt96 = AudioOutputStatus.Snapshot()
        speakerAt96.hardwareSampleRateHz = 96_000

        XCTAssertTrue(PlaybackQualityBadge.outputCaptionShines(stats: hiRes, output: usb, inParty: false))
        XCTAssertTrue(PlaybackQualityBadge.outputCaptionShines(stats: hiRes, output: speakerAt96, inParty: false))
        XCTAssertFalse(PlaybackQualityBadge.outputCaptionShines(stats: hiRes, output: airPods, inParty: false), "Bluetooth re-encodes")
        XCTAssertFalse(PlaybackQualityBadge.outputCaptionShines(stats: cd, output: usb, inParty: false), "a CD-quality stream is not hi-res")
        XCTAssertFalse(PlaybackQualityBadge.outputCaptionShines(stats: hiRes, output: usb, inParty: true), "a party's caption names the jam")
    }
}
