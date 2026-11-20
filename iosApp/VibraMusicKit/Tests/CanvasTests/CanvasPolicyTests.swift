import VibraMusicCore
import VibraMusicTestSupport
import XCTest
@testable import Canvas

/// The enable/disable and Wi-Fi-only gates (Android: `AppSettings.animatedCanvas`,
/// `canvasOverCellular` and the `NowPlayingScreen` check).
final class CanvasPolicyTests: XCTestCase {
    func testDisabledMasterSwitchBlocksEverything() {
        XCTAssertFalse(CanvasPolicy.isAllowed(
            animatedCanvas: false, canvasOverCellular: true, network: .wifi))
        XCTAssertFalse(CanvasPolicy.isAllowed(
            animatedCanvas: false, canvasOverCellular: true, network: .offline))
    }

    func testWiFiStreamsByDefault() {
        XCTAssertTrue(CanvasPolicy.isAllowed(
            animatedCanvas: true, canvasOverCellular: false, network: .wifi))
    }

    func testCellularNeedsTheOptIn() {
        XCTAssertFalse(CanvasPolicy.isAllowed(
            animatedCanvas: true, canvasOverCellular: false, network: .cellular))
        XCTAssertTrue(CanvasPolicy.isAllowed(
            animatedCanvas: true, canvasOverCellular: true, network: .cellular))
    }

    func testOfflineIsNotMetered() {
        // Offline there is nothing to stream, but the gate itself must not claim the
        // (nonexistent) connection is metered — `isMetered` is nil offline.
        XCTAssertNil(NetworkStatus.offline.isMetered)
        XCTAssertTrue(CanvasPolicy.isAllowed(
            animatedCanvas: true, canvasOverCellular: false, network: .offline))
    }

    func testConstrainedWiFiCountsAsMetered() {
        let hotspot = NetworkStatus(interface: .wifi, isExpensive: true)
        XCTAssertFalse(CanvasPolicy.isAllowed(
            animatedCanvas: true, canvasOverCellular: false, network: hotspot))
        XCTAssertTrue(CanvasPolicy.isAllowed(
            animatedCanvas: true, canvasOverCellular: true, network: hotspot))
    }

    /// The policy helper and `AppSettings.animatedCanvasAllowed(on:)` must agree — the player
    /// reads the settings, the repository documents the same rule.
    @MainActor
    func testMatchesAppSettings() {
        let settings = AppSettings(
            defaults: makeEphemeralDefaults(), credentials: InMemoryCredentialStore())
        let networks: [NetworkStatus] = [
            .wifi, .cellular, .offline,
            NetworkStatus(interface: .wifi, isExpensive: true),
        ]
        for animated in [true, false] {
            for cellular in [true, false] {
                settings.animatedCanvas = animated
                settings.canvasOverCellular = cellular
                for network in networks {
                    XCTAssertEqual(
                        CanvasPolicy.isAllowed(
                            animatedCanvas: animated, canvasOverCellular: cellular, network: network),
                        settings.animatedCanvasAllowed(on: network),
                        "animated=\(animated) cellular=\(cellular) network=\(network)")
                }
            }
        }
    }
}
