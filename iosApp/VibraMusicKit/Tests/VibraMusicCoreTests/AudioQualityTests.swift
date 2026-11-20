import XCTest
import VibraMusicTestSupport
@testable import VibraMusicCore

/// Quality ceilings per network, what they let each source do, and the requests they turn into.
/// The download cases are ported from DownloadStoreTest.kt.
@MainActor
final class AudioQualityTests: XCTestCase {
    private func makeSettings() -> AppSettings {
        AppSettings(defaults: makeEphemeralDefaults(), credentials: InMemoryCredentialStore())
    }

    // MARK: Effective quality per network

    func testTheCellularCeilingAppliesOnlyOnAMeteredConnection() {
        let s = makeSettings()
        s.audioQualityWifi = .lossless
        s.audioQualityCellular = .low
        XCTAssertEqual(s.effectiveAudioQuality(for: .wifi), .lossless)
        XCTAssertEqual(s.effectiveAudioQuality(for: .cellular), .low)
        XCTAssertEqual(s.effectiveAudioQuality(for: NetworkStatus(interface: .wifi, isExpensive: true)), .low, "a hotspot is Wi-Fi that costs money")
        XCTAssertEqual(s.effectiveAudioQuality(for: NetworkStatus(interface: .wifi, isConstrained: true)), .low, "Low Data Mode counts as metered")
        XCTAssertEqual(s.effectiveAudioQuality(for: NetworkStatus(interface: .wired)), .lossless)
        XCTAssertEqual(s.effectiveAudioQuality(for: .offline), .lossless)
    }

    /// PORTING 2.1 "Audio quality per network": on cellular with Low set, about 64 kbps.
    func testLowOnCellularAsksYouTubeForAbout64Kbps() {
        let s = makeSettings()
        s.audioQualityCellular = .low
        let request = s.playbackStreamRequest(for: .cellular)
        XCTAssertEqual(request.tier, .capped(kbps: 64))
        XCTAssertEqual(request.maxKbps, 64)
        XCTAssertEqual(request.permittedSources, [.youtube])
        XCTAssertEqual(request.purpose, .playback)
    }

    /// Direct source stream reaches the request for playback only; a download never waits on sources.
    func testDirectSourceStreamMapsIntoThePlaybackRequestOnly() {
        let s = makeSettings()
        XCTAssertFalse(s.playbackStreamRequest(for: .cellular).waitsForSources)
        XCTAssertFalse(s.playbackStreamRequest(for: .cellular).readsAheadFromSources)
        s.directSourceStream = .always
        XCTAssertTrue(s.playbackStreamRequest(for: .cellular).waitsForSources)
        XCTAssertTrue(s.playbackStreamRequest(for: .offline).waitsForSources)
        XCTAssertFalse(s.playbackStreamRequest(for: .cellular).readsAheadFromSources)
        XCTAssertFalse(s.downloadStreamRequest.waitsForSources)
    }

    /// Queue only reads ahead from the sources and never holds a track's start for them.
    func testQueueOnlyReadsAheadFromTheSourcesWithoutWaiting() {
        let s = makeSettings()
        s.directSourceStream = .queueOnly
        XCTAssertTrue(s.playbackStreamRequest(for: .cellular).readsAheadFromSources)
        XCTAssertFalse(s.playbackStreamRequest(for: .cellular).waitsForSources)
        XCTAssertFalse(s.downloadStreamRequest.readsAheadFromSources)
    }

    func testPlaybackRequestsPerRung() {
        XCTAssertEqual(StreamRequest.playback(.lossless).tier, .lossless)
        XCTAssertEqual(StreamRequest.playback(.high).tier, .best)
        XCTAssertEqual(StreamRequest.playback(.medium).tier, .best, "Medium is uncapped, not capped very high")
        XCTAssertNil(StreamRequest.playback(.medium).maxKbps)
        XCTAssertEqual(StreamRequest.playback(.low).tier, .capped(kbps: 64))
    }

    func testEachRungPermitsTheRightSources() {
        XCTAssertEqual(StreamRequest.playback(.lossless).permittedSources, Set(SourceKind.allCases))
        XCTAssertEqual(StreamRequest.playback(.high).permittedSources, [.jioSaavn, .youtube], "the slow lossless half is skipped")
        XCTAssertEqual(StreamRequest.playback(.medium).permittedSources, [.youtube])
        XCTAssertEqual(StreamRequest.playback(.low).permittedSources, [.youtube])
        for quality in AudioQuality.allCases {
            XCTAssertTrue(quality.permits(.youtube), "YouTube answers on every rung")
        }
    }

    func testEveryRungIsDescribable() {
        for quality in AudioQuality.allCases {
            XCTAssertFalse(quality.label.isEmpty)
            XCTAssertFalse(quality.detail.isEmpty)
            XCTAssertFalse(quality.hourly.isEmpty)
        }
    }

    // MARK: Downloads (DownloadStoreTest.kt)

    func testOnlyLosslessAsksASourceForTheFileItHolds() {
        XCTAssertEqual(StreamRequest.download(.lossless).tier, .lossless)
        XCTAssertEqual(StreamRequest.download(.high).tier, .best)
        XCTAssertEqual(StreamRequest.download(.standard).tier, .capped(kbps: 128))
        XCTAssertEqual(StreamRequest.download(.lossless).purpose, .download)
    }

    func testHighIsUncappedRatherThanCappedVeryHigh() {
        XCTAssertNil(DownloadQuality.high.maxKbps)
        XCTAssertNil(StreamRequest.download(.high).maxKbps)
    }

    func testEveryDownloadRungIsDescribable() {
        for quality in DownloadQuality.allCases {
            XCTAssertFalse(quality.label.isEmpty)
            XCTAssertFalse(quality.detail.isEmpty)
            XCTAssertFalse(quality.perTrack.isEmpty)
        }
    }

    /// The Wi-Fi-only gate, including the case easiest to get backwards: offline is let through, to
    /// fail on the network and say so, rather than blaming a Wi-Fi setting for an outage.
    func testWifiOnlyRefusesMeteredConnectionsAndNothingElse() {
        let s = makeSettings()
        s.wifiOnlyDownloads = true
        XCTAssertFalse(s.downloadsAllowed(on: .cellular))
        XCTAssertTrue(s.downloadsAllowed(on: .wifi))
        XCTAssertTrue(s.downloadsAllowed(on: .offline))
        s.wifiOnlyDownloads = false
        XCTAssertTrue(s.downloadsAllowed(on: .cellular))
    }

    /// A capped mobile-data *stream* must not quietly downgrade a *file*.
    func testACappedStreamingCeilingDoesNotDecideWhatADownloadKeeps() {
        let s = makeSettings()
        s.audioQualityCellular = .low
        s.downloadQuality = .lossless
        XCTAssertEqual(s.effectiveAudioQuality(for: .cellular), .low)
        XCTAssertEqual(s.downloadStreamRequest.tier, .lossless)
        XCTAssertEqual(s.downloadStreamRequest.permittedSources, Set(SourceKind.allCases))
    }

    // MARK: Canvas

    func testAnimatedCanvasStaysOffMeteredConnectionsUnlessAllowed() {
        let s = makeSettings()
        XCTAssertTrue(s.animatedCanvasAllowed(on: .wifi))
        XCTAssertFalse(s.animatedCanvasAllowed(on: .cellular))
        s.canvasOverCellular = true
        XCTAssertTrue(s.animatedCanvasAllowed(on: .cellular))
        s.animatedCanvas = false
        XCTAssertFalse(s.animatedCanvasAllowed(on: .wifi))
    }

    // MARK: Source kinds

    func testSourceKindsRankUserAddedFirstAndYouTubeLast() {
        let ranked = SourceKind.allCases.sorted { $0.rank < $1.rank }
        XCTAssertEqual(ranked.last, .youtube)
        XCTAssertTrue(SourceKind.addon.isUserAdded)
        XCTAssertTrue(SourceKind.customModule.isUserAdded)
        XCTAssertFalse(SourceKind.jioSaavn.isUserAdded)
        XCTAssertEqual(SourceKind.allCases.filter(\.canServeLossless), [.addon, .customModule, .module])
        XCTAssertEqual(SourceKind.allCases.filter(\.worthPrefetching), [.jioSaavn])
        XCTAssertEqual(SourceKind.allCases.map(\.rawValue), ["ADDON", "CUSTOM_MODULE", "MODULE", "JIOSAAVN", "YOUTUBE"])
    }
}
