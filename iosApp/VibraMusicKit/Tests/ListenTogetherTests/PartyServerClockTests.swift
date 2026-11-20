import XCTest
@testable import ListenTogether

/// The NTP-cut-down clock: offset from the midpoint, smallest round trip wins, stale
/// samples age out, and the wall clock never enters the measurement.
final class PartyServerClockTests: XCTestCase {
    func testUnsyncedUntilFirstPong() {
        let clock = PartyServerClock(monotonicMs: { 1_000 })
        XCTAssertFalse(clock.isSynced)
        XCTAssertNil(clock.serverNowMs())
        XCTAssertNil(clock.offsetMs)
    }

    func testOffsetIsServerMinusMidpoint() {
        let manual = ManualClock(now: 1_000)
        let clock = PartyServerClock(monotonicMs: { manual.now })
        // t0 = 1000, server = 5000, t1 = 1100 → midpoint 1050, offset 3950.
        clock.record(sentAtLocalMs: 1_000, serverMs: 5_000, receivedAtLocalMs: 1_100)
        XCTAssertTrue(clock.isSynced)
        XCTAssertEqual(3_950, clock.offsetMs)
        XCTAssertEqual(100, clock.roundTripMs)
        manual.now = 2_000
        XCTAssertEqual(2_000 + 3_950, clock.serverNowMs())
    }

    func testSmallestRoundTripWinsNotNewestOrAverage() {
        let clock = PartyServerClock(monotonicMs: { 0 })
        // A clean sample first…
        clock.record(sentAtLocalMs: 0, serverMs: 1_000, receivedAtLocalMs: 100)
        XCTAssertEqual(950, clock.offsetMs)
        // …then a sample delayed behind a radio wake-up. Averaging would fold its error
        // in; the clock keeps the clean one.
        clock.record(sentAtLocalMs: 200, serverMs: 1_300, receivedAtLocalMs: 1_200)
        XCTAssertEqual(950, clock.offsetMs)
        XCTAssertEqual(100, clock.roundTripMs)
    }

    func testStaleSamplesAgeOut() {
        let clock = PartyServerClock(monotonicMs: { 0 })
        clock.record(sentAtLocalMs: 0, serverMs: 1_000, receivedAtLocalMs: 100)
        XCTAssertEqual(950, clock.offsetMs)
        // More than the 120 s TTL later, the lucky early sample no longer pins the offset.
        clock.record(sentAtLocalMs: 200_000, serverMs: 203_000, receivedAtLocalMs: 200_200)
        XCTAssertEqual(2_900, clock.offsetMs)
    }

    func testNegativeRoundTripClamps() {
        let clock = PartyServerClock(monotonicMs: { 0 })
        clock.record(sentAtLocalMs: 500, serverMs: 1_000, receivedAtLocalMs: 400)
        XCTAssertEqual(0, clock.roundTripMs)
        XCTAssertEqual(500, clock.offsetMs)
    }

    func testResetClearsEverything() {
        let clock = PartyServerClock(monotonicMs: { 0 })
        clock.record(sentAtLocalMs: 0, serverMs: 1_000, receivedAtLocalMs: 100)
        XCTAssertTrue(clock.isSynced)
        clock.reset()
        XCTAssertFalse(clock.isSynced)
        XCTAssertNil(clock.serverNowMs())
        XCTAssertEqual(0, clock.roundTripMs)
    }

    func testWindowKeepsTwelveSamples() {
        let clock = PartyServerClock(monotonicMs: { 0 })
        // Thirteen samples with growing offsets and equal round trips: the newest wins only
        // because the oldest fell out of the window, not because it is newest.
        for i in 0 ..< 13 {
            let base = Int64(i) * 10_000
            clock.record(sentAtLocalMs: base, serverMs: base + 1_000 + Int64(i), receivedAtLocalMs: base + 100)
        }
        // All round trips tie, so the earliest surviving sample wins — and the very first
        // fell out of the 12-sample window.
        XCTAssertEqual(951, clock.offsetMs)
    }
}
