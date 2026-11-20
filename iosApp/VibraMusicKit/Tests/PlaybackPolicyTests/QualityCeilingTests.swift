import XCTest
import AVFoundation
import VibraMusicCore
import VibraMusicTestSupport
@testable import PlaybackPolicy

/// Separate quality limits for Wi-Fi and mobile data (PORTING.md, Audio quality per network).
final class QualityCeilingTests: XCTestCase {
    func testTheCellularCeilingAppliesOnlyOnAMeteredConnection() {
        let network = FakeNetworkMonitor(.wifi)
        let ceiling = PlaybackQualityCeiling(network: network, wifi: .lossless, cellular: .low)

        XCTAssertEqual(ceiling.effectiveQuality, .lossless)
        XCTAssertFalse(ceiling.isCellularCeilingActive)
        XCTAssertEqual(ceiling.currentRequest.tier, .lossless)

        network.send(.cellular)
        XCTAssertEqual(ceiling.effectiveQuality, .low)
        XCTAssertTrue(ceiling.isCellularCeilingActive)
        XCTAssertEqual(ceiling.currentRequest.tier, .capped(kbps: 64))
        XCTAssertEqual(ceiling.currentRequest.permittedSources, [.youtube], "Low asks YouTube alone")
    }

    /// Metered, not literally cellular: a hotspot is Wi-Fi that costs money, and Low Data Mode is the
    /// user saying so about any network. Offline counts as Wi-Fi.
    func testHotspotsAndLowDataModeCountAsMetered() {
        let network = FakeNetworkMonitor(NetworkStatus(interface: .wifi, isExpensive: true))
        let ceiling = PlaybackQualityCeiling(network: network, wifi: .lossless, cellular: .medium)
        XCTAssertEqual(ceiling.effectiveQuality, .medium)

        network.send(NetworkStatus(interface: .wifi, isConstrained: true))
        XCTAssertEqual(ceiling.effectiveQuality, .medium)

        network.send(.offline)
        XCTAssertEqual(ceiling.effectiveQuality, .lossless)
    }

    func testEachRungAsksForTheRightTier() {
        let network = FakeNetworkMonitor(.wifi)
        let ceiling = PlaybackQualityCeiling(network: network)
        let expected: [(AudioQuality, StreamRequest.Tier)] = [
            (.lossless, .lossless), (.high, .best), (.medium, .best), (.low, .capped(kbps: 64)),
        ]
        for (quality, tier) in expected {
            ceiling.setCeilings(wifi: quality, cellular: .lossless)
            XCTAssertEqual(ceiling.currentRequest.tier, tier, "\(quality)")
        }
        ceiling.setCeilings(wifi: .high, cellular: .lossless)
        XCTAssertFalse(ceiling.currentRequest.permits(.addon), "High skips the slow lossless sources")
        XCTAssertTrue(ceiling.currentRequest.permits(.jioSaavn))
    }

    @MainActor
    func testTheCeilingFollowsSettingsChanges() async throws {
        let settings = AppSettings(defaults: makeEphemeralDefaults(), credentials: InMemoryCredentialStore())
        settings.audioQualityCellular = .high
        let network = FakeNetworkMonitor(.cellular)
        let ceiling = PlaybackQualityCeiling(settings: settings, network: network)
        XCTAssertEqual(ceiling.effectiveQuality, .high)

        settings.audioQualityCellular = .low
        for _ in 0..<50 where ceiling.effectiveQuality != .low {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(ceiling.effectiveQuality, .low)

        settings.audioQualityWifi = .medium
        network.send(.wifi)
        for _ in 0..<50 where ceiling.effectiveQuality != .medium {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(ceiling.effectiveQuality, .medium)
    }

    /// The request the player loads with carries "Direct source stream", now and after a change.
    @MainActor
    func testTheRequestWaitsForSourcesWhileDirectSourceStreamIsOn() async throws {
        let settings = AppSettings(defaults: makeEphemeralDefaults(), credentials: InMemoryCredentialStore())
        let ceiling = PlaybackQualityCeiling(settings: settings, network: FakeNetworkMonitor(.wifi))
        XCTAssertFalse(ceiling.currentRequest.waitsForSources)

        settings.directSourceStream = .always
        for _ in 0..<50 where !ceiling.currentRequest.waitsForSources {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(ceiling.currentRequest.waitsForSources)
        XCTAssertTrue(PlaybackQualityCeiling(settings: settings, network: FakeNetworkMonitor(.wifi)).currentRequest.waitsForSources)

        settings.directSourceStream = .queueOnly
        for _ in 0..<50 where !ceiling.currentRequest.readsAheadFromSources {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(ceiling.currentRequest.readsAheadFromSources)
        XCTAssertFalse(ceiling.currentRequest.waitsForSources, "Queue only never holds a track's start")
    }

    /// In a Listen Together party Direct source stream stands aside, Always and Queue only alike:
    /// every member starts where the host is (Android's `DirectSourceGate.isActive`). It comes back
    /// when the party ends.
    func testDirectSourceStreamIsOffDuringAParty() {
        for mode in [DirectSourceStream.always, .queueOnly] {
            let ceiling = PlaybackQualityCeiling(network: FakeNetworkMonitor(.wifi), directSource: mode)
            ceiling.setInParty(true)
            XCTAssertFalse(ceiling.currentRequest.waitsForSources, "\(mode)")
            XCTAssertFalse(ceiling.currentRequest.readsAheadFromSources, "\(mode)")
            XCTAssertEqual(ceiling.currentRequest.tier, .lossless, "the quality ceiling still applies")

            ceiling.setInParty(false)
            XCTAssertEqual(ceiling.currentRequest, .playback(.lossless, directSource: mode), "\(mode)")
        }
    }

    /// The lossless follow-up after a lossy upgrade depends on the connection in hand *now*.
    func testTheUpgradePolicyReadsTheCeilingAtTheMomentOfAsking() {
        let network = FakeNetworkMonitor(.wifi)
        let ceiling = PlaybackQualityCeiling(network: network, wifi: .lossless, cellular: .high)
        let upgrade = QualityUpgrade(search: FakeUpgradeSearch(), requestForNow: { ceiling.currentRequest }, streamChoice: StreamChoice(), nerdStats: NerdStats())
        let aac = StreamFormat(codec: "aac", kbps: 320)

        XCTAssertTrue(upgrade.needsLosslessFollowUp(aac))
        network.send(.cellular)
        XCTAssertFalse(upgrade.needsLosslessFollowUp(aac))
    }

    /// "On cellular with Low set, stats for nerds shows about 64 kbps": the ceiling caps the request
    /// at 64, the stream YouTube serves at that rung is measured off its own track, and the stats
    /// line and badge describe what was measured.
    func testOnCellularWithLowSetStatsShowAbout64Kbps() async throws {
        let network = FakeNetworkMonitor(.cellular)
        let ceiling = PlaybackQualityCeiling(network: network, wifi: .lossless, cellular: .low)
        XCTAssertEqual(ceiling.currentRequest.maxKbps, 64)

        // The rung a capped request gets: HE-AAC at 64 kbps (fixture encoded with afconvert).
        let url = try FixtureLoader(bundle: .module).url("audio/heaac_64.m4a")
        let measured = try await AudioFormatMeasurement.measure(asset: AVURLAsset(url: url))
        let stats = NerdStats()
        stats.publish(measured: measured, mediaId: "dQw4w9WgXcQ", sourceName: "YouTube")

        let snapshot = try XCTUnwrap(stats.current)
        let kbps = try XCTUnwrap(snapshot.bitrateKbps)
        XCTAssertLessThanOrEqual(abs(kbps - 64), 8, "about 64 kbps, measured \(kbps)")
        XCTAssertTrue(snapshot.statsLine?.contains("\(kbps) kbps") == true, snapshot.statsLine ?? "no line")
        XCTAssertEqual(
            PlaybackQualityBadge.resolve(isLoading: false, stillRacing: false, effectiveQuality: ceiling.effectiveQuality, stats: snapshot),
            .dataSaver
        )
    }
}
