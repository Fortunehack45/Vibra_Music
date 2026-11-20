import XCTest
import VibraMusicCore
@testable import PlaybackPolicy

/// The player menu's "Upgrade quality": the throttle (ports ManualUpgradeThrottleTest) and the
/// session side of the request (Android `PlaybackService.upgradeQualityNow`).
final class ManualUpgradeTests: XCTestCase {
    func testManualRetriesAreAcceptedOnlyOncePerCooldown() {
        let throttle = ManualUpgradeThrottle(cooldownMs: 30_000)

        XCTAssertEqual(throttle.tryAcquire(nowMs: 1_000), 0)
        XCTAssertEqual(throttle.tryAcquire(nowMs: 1_000), 30_000)
        XCTAssertEqual(throttle.tryAcquire(nowMs: 30_999), 1)
        XCTAssertEqual(throttle.tryAcquire(nowMs: 31_000), 0)
    }

    func testTimeBeforeTheFirstManualRequestDoesNotConsumeTheCooldown() {
        let throttle = ManualUpgradeThrottle(cooldownMs: 30_000)

        // Automatic upgrade activity never calls tryAcquire. However long the app has been
        // playing, the first explicit request is accepted.
        XCTAssertEqual(throttle.tryAcquire(nowMs: 9_000_000), 0)
    }

    func testAnAcceptedRequestUnpinsTheTrackAndReopensItsVerdicts() {
        let pins = OriginalVersion(defaults: nil)
        let upgrade = QualityUpgrade.testInstance()
        pins.pin("track")
        upgrade.markAnsweredForTest("track")
        upgrade.refuseUpgrades("track")

        let outcome = upgrade.requestByHand("track", nowMs: 5_000, upgradeRunning: false, originalVersion: pins)

        XCTAssertEqual(outcome, .accepted)
        XCTAssertFalse(pins.isPinned("track"), "the request to search again is the way back from a revert")
        XCTAssertFalse(upgrade.hasAnswered("track"))
        XCTAssertTrue(
            upgrade.couldStillUpgrade("track", uri: "vibramusic://watch?v=track&direct_youtube=1&q=original"),
            "a hand request exempts the reverted item's marker, so it is a candidate again without a rebuild"
        )
    }

    /// The UI disables the row too, but a controller that doesn't use that UI (CarPlay) reaches the
    /// session anyway; a command arriving mid-search must not be charged the cooldown.
    func testARequestWhileTheUpgradeIsRunningIsIgnoredWithoutChargingTheCooldown() {
        let stats = NerdStats()
        let pins = OriginalVersion(defaults: nil)
        let upgrade = QualityUpgrade.testInstance(nerdStats: stats)
        pins.pin("track")
        stats.onLosslessRaceStart("track")

        XCTAssertEqual(upgrade.requestByHand("track", nowMs: 1_000, upgradeRunning: false, originalVersion: pins), .alreadyRunning)
        XCTAssertEqual(upgrade.requestByHand("track", nowMs: 1_000, upgradeRunning: true, originalVersion: pins), .alreadyRunning)
        XCTAssertTrue(pins.isPinned("track"), "an ignored request changes nothing")

        stats.onLosslessRaceEnd("track")
        XCTAssertEqual(
            upgrade.requestByHand("track", nowMs: 1_001, upgradeRunning: false, originalVersion: pins),
            .accepted,
            "the ignored commands did not start the cooldown"
        )
    }

    func testASecondRequestInsideTheCooldownIsThrottled() {
        let pins = OriginalVersion(defaults: nil)
        let upgrade = QualityUpgrade.testInstance()

        XCTAssertEqual(upgrade.requestByHand("a", nowMs: 10_000, upgradeRunning: false, originalVersion: pins), .accepted)
        pins.pin("b")
        XCTAssertEqual(
            upgrade.requestByHand("b", nowMs: 20_000, upgradeRunning: false, originalVersion: pins),
            .coolingDown(remainingMs: 20_000)
        )
        XCTAssertTrue(pins.isPinned("b"), "a throttled request leaves the pin alone")
        XCTAssertEqual(upgrade.requestByHand("b", nowMs: 40_000, upgradeRunning: false, originalVersion: pins), .accepted)
    }
}
