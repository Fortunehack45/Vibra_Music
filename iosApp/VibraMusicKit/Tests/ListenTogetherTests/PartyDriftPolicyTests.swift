import XCTest
@testable import ListenTogether

/// The drift rule: within the limit is tolerated, one over-limit reading cannot trigger,
/// two in a row seek, and the cooldown lets the player settle afterwards.
final class PartyDriftPolicyTests: XCTestCase {
    func testWithinLimitNeverSeeks() {
        var policy = PartyDriftPolicy()
        for t in [0, 100, 500, 1_199, 1_200] {
            XCTAssertFalse(policy.evaluate(driftMs: Int64(t), nowMs: 10_000))
            XCTAssertFalse(policy.evaluate(driftMs: Int64(-t), nowMs: 10_000))
        }
        XCTAssertEqual(0, policy.strikes)
    }

    func testTwoConsecutiveOverLimitReadingsSeek() {
        var policy = PartyDriftPolicy()
        XCTAssertFalse(policy.evaluate(driftMs: 1_500, nowMs: 0))
        XCTAssertTrue(policy.evaluate(driftMs: 1_500, nowMs: 100))
    }

    func testSingleReadingResetsAfterQuiet() {
        var policy = PartyDriftPolicy()
        XCTAssertFalse(policy.evaluate(driftMs: 1_500, nowMs: 0))
        XCTAssertFalse(policy.evaluate(driftMs: 100, nowMs: 100))
        // The strike did not stick: one more over-limit reading is still only the first.
        XCTAssertFalse(policy.evaluate(driftMs: 1_500, nowMs: 200))
        XCTAssertTrue(policy.evaluate(driftMs: 1_500, nowMs: 300))
    }

    func testCooldownSuppressesImmediateReseek() {
        var policy = PartyDriftPolicy()
        XCTAssertFalse(policy.evaluate(driftMs: 5_000, nowMs: 0))
        XCTAssertTrue(policy.evaluate(driftMs: 5_000, nowMs: 100))
        // A seek just happened 100 ms ago; the player has not settled yet.
        XCTAssertFalse(policy.evaluate(driftMs: 5_000, nowMs: 200))
        XCTAssertFalse(policy.evaluate(driftMs: 5_000, nowMs: 6_099))
        // After the 6 s cooldown, over-limit readings count again from the first.
        XCTAssertFalse(policy.evaluate(driftMs: 5_000, nowMs: 6_100))
        XCTAssertTrue(policy.evaluate(driftMs: 5_000, nowMs: 6_200))
    }
}
