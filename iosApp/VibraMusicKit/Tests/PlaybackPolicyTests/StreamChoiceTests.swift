import XCTest
import VibraMusicCore
@testable import PlaybackPolicy

/// The promise StreamChoice makes: a track being served from one copy keeps being served from that
/// copy (ports StreamChoiceTest).
///
/// Every live entry stands behind a half-filled cache entry on disk, and breaking one costs a
/// corrupt file — the middle of an MP4 appended to a WebM — not a wrong bitrate. So these are about
/// what happens under pressure, which is where the promise was breakable.
final class StreamChoiceTests: XCTestCase {
    private var clock: ManualClock!
    private var choice: StreamChoice!

    override func setUp() {
        super.setUp()
        clock = ManualClock()
        choice = StreamChoice(now: clock.reader)
    }

    private func stream(_ host: String) -> ResolvedStream {
        ResolvedStream(url: URL(string: "https://\(host)/track.mp4")!, origin: .jioSaavn, format: StreamFormat(codec: "mp4", kbps: 320))
    }

    func testARememberedChoiceIsHandedBack() {
        choice.remember(stream("aac.saavncdn.com"), for: "track-1", substituted: true)
        XCTAssertEqual(choice.stream(for: "track-1")?.url.absoluteString, "https://aac.saavncdn.com/track.mp4")
    }

    func testATrackNothingHasChosenForIsFreeToResolve() {
        XCTAssertNil(choice.stream(for: "track-2"))
    }

    /// Only the substituted ones, so the recovery path can tell them apart.
    func testRemembersWhetherTheCopyCameFromASubstitute() {
        choice.remember(stream("aac.saavncdn.com"), for: "track-3", substituted: true)
        choice.remember(stream("googlevideo.com"), for: "track-4", substituted: false)
        XCTAssertTrue(choice.isSubstitute("track-3"))
        XCTAssertFalse(choice.isSubstitute("track-4"))
        XCTAssertFalse(choice.isSubstitute("never-seen"))
    }

    /// The eviction that mattered. Overflow used to empty the whole map, releasing every track being
    /// served — including ones with bytes half-written under a key only their own stream may finish.
    /// Read-ahead made this reachable: it pins the next track before the listener gets there.
    func testOverflowDropsTheOldestChoiceRatherThanAllOfThem() {
        for index in 0..<40 {
            choice.remember(stream("host-\(index).example"), for: "track-\(index)", substituted: true)
            clock.advance(by: 1)
        }

        // The newest write is always honoured: it is the track being read right now.
        XCTAssertEqual(choice.stream(for: "track-39")?.url.absoluteString, "https://host-39.example/track.mp4")

        // What separates evicting-the-oldest from emptying the map: track-20 is one of the most
        // recent writes, so any bounded map worth the name still holds it.
        XCTAssertEqual(
            choice.stream(for: "track-20")?.url.absoluteString,
            "https://host-20.example/track.mp4",
            "a recent choice was evicted, so overflow is still emptying the map wholesale"
        )
        XCTAssertNil(choice.stream(for: "track-0"), "the oldest promise is the one given up")
        let held = (0..<40).filter { choice.stream(for: "track-\($0)") != nil }
        XCTAssertEqual(held.count, StreamChoice.maxRemembered)
        XCTAssertEqual(held.first, 40 - StreamChoice.maxRemembered)
    }

    /// Expired promises go before live ones, however recent the live ones are.
    func testOverflowDropsExpiredChoicesFirst() {
        choice.remember(stream("stale.example"), for: "stale", substituted: true)
        clock.advance(by: StreamChoice.ttl + 1)
        for index in 0..<(StreamChoice.maxRemembered - 1) {
            choice.remember(stream("host-\(index).example"), for: "live-\(index)", substituted: true)
        }
        choice.remember(stream("newest.example"), for: "newest", substituted: true)

        XCTAssertNotNil(choice.stream(for: "live-0"), "a live promise survived because an expired one was there to drop")
        XCTAssertNotNil(choice.stream(for: "newest"))
    }

    /// Releasing a track lets the next resolve decide afresh.
    func testForgettingAChoiceReopensTheQuestion() {
        choice.remember(stream("aac.saavncdn.com"), for: "track-5", substituted: true)
        choice.forget("track-5")
        XCTAssertNil(choice.stream(for: "track-5"))
    }

    /// A signed module URL dies after about five hours; a choice is trusted for far less than that.
    func testAChoiceIsNotTrustedPastItsTimeLimit() {
        choice.remember(stream("aac.saavncdn.com"), for: "track-6", substituted: true)
        clock.advance(by: StreamChoice.ttl)
        XCTAssertNotNil(choice.stream(for: "track-6"), "still inside the limit")
        clock.advance(by: 1)
        XCTAssertNil(choice.stream(for: "track-6"))
    }

    /// A refusal is a cooling-off period, not a verdict for the session.
    func testRefusedSubstitutesExpireAfterTheRefusalPeriod() {
        XCTAssertFalse(choice.substitutesRefused(for: "track-7"))
        choice.refuseSubstitutes(for: "track-7")
        XCTAssertTrue(choice.substitutesRefused(for: "track-7"))
        clock.advance(by: StreamChoice.refusalPeriod)
        XCTAssertTrue(choice.substitutesRefused(for: "track-7"))
        clock.advance(by: 1)
        XCTAssertFalse(choice.substitutesRefused(for: "track-7"), "a module having a bad minute gets another chance")
    }

    /// Filling the map must not lift refusals that are still in force.
    func testTheRefusalCapEvictsTheOldestRatherThanForgivingEverything() {
        for i in 0..<StreamChoice.maxRemembered {
            choice.refuseSubstitutes(for: "track-\(i)")
            clock.advance(by: 1)
        }
        choice.refuseSubstitutes(for: "one-more")
        XCTAssertFalse(choice.substitutesRefused(for: "track-0"))
        XCTAssertTrue(choice.substitutesRefused(for: "track-1"))
        XCTAssertTrue(choice.substitutesRefused(for: "track-\(StreamChoice.maxRemembered - 1)"))
        XCTAssertTrue(choice.substitutesRefused(for: "one-more"))
    }

    func testTheSharedClockKeepsCountingForward() {
        let first = monotonicSeconds()
        let second = monotonicSeconds()
        XCTAssertGreaterThan(first, 0)
        XCTAssertGreaterThanOrEqual(second, first)
    }
}
