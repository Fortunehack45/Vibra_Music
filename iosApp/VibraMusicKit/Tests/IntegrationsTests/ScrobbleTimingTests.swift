import VibraMusicCore
import VibraMusicTestSupport
import XCTest
@testable import Integrations

/// Scrobble timing: a track must exceed 30 s, then scrobbles after half its
/// duration or 4 minutes, whichever comes first (`ScrobbleManager.kt`).
final class ScrobbleTimingTests: XCTestCase {
    func testShortTracksNeverScrobble() {
        XCTAssertNil(ScrobbleTiming.delayMilliseconds(durationSeconds: 29))
        XCTAssertNil(ScrobbleTiming.delayMilliseconds(durationSeconds: 30))
        XCTAssertNil(ScrobbleTiming.delayMilliseconds(durationSeconds: nil))
        XCTAssertNil(ScrobbleTiming.delayMilliseconds(durationSeconds: 0))
    }

    func testHalfDurationBelowTheCap() {
        // 200 s → half is 100 s.
        XCTAssertEqual(ScrobbleTiming.delayMilliseconds(durationSeconds: 200), 100_000)
    }

    func testLongTracksCapAtFourMinutes() {
        // 600 s → half is 300 s, capped to 180 s.
        XCTAssertEqual(ScrobbleTiming.delayMilliseconds(durationSeconds: 600), 180_000)
        // Boundary: 360 s → half is exactly the cap.
        XCTAssertEqual(ScrobbleTiming.delayMilliseconds(durationSeconds: 360), 180_000)
        XCTAssertEqual(ScrobbleTiming.delayMilliseconds(durationSeconds: 359), 179_500)
    }

    func testCustomThresholds() {
        XCTAssertEqual(
            ScrobbleTiming.delayMilliseconds(
                durationSeconds: 100, minDurationSeconds: 10, delayPercent: 1.0, maxDelaySeconds: 30
            ),
            30_000
        )
        XCTAssertNil(ScrobbleTiming.delayMilliseconds(durationSeconds: 10, minDurationSeconds: 10))
    }

    func testDurationLabelParsing() {
        XCTAssertEqual(ScrobbleTiming.parseDurationSeconds("3:47"), 227)
        XCTAssertEqual(ScrobbleTiming.parseDurationSeconds("1:04"), 64)
        XCTAssertEqual(ScrobbleTiming.parseDurationSeconds(nil), 0)
        XCTAssertEqual(ScrobbleTiming.parseDurationSeconds("bogus"), 0)
        XCTAssertEqual(ScrobbleTiming.parseDurationMs("3:47"), 227_000)
    }

    func testTrackerDoesNotScheduleShortTracks() async {
        let tracker = ScrobbleTracker()
        let song = Song(videoId: "v", title: "Short", artist: "A", durationText: "0:20")
        await tracker.noteStarted(song: song)
        let remaining = await tracker.remainingMilliseconds()
        XCTAssertEqual(remaining, 0)
    }

    func testTrackerSchedulesAndPauses() async {
        let tracker = ScrobbleTracker()
        let song = Song(videoId: "v", title: "Long", artist: "A", durationText: "3:20")
        let started = Date()
        await tracker.noteStarted(song: song, at: started)
        // 200 s → 100 s countdown.
        let scheduled = await tracker.remainingMilliseconds()
        XCTAssertEqual(scheduled, 100_000)
        // Pausing 1 s in freezes ~99 s remaining; stopping clears it.
        await tracker.notePaused(at: started.addingTimeInterval(1))
        let remaining = await tracker.remainingMilliseconds()
        XCTAssertTrue(remaining > 98_000 && remaining <= 99_500, "remaining was \(remaining)")
        await tracker.noteStopped()
        let stopped = await tracker.remainingMilliseconds()
        XCTAssertEqual(stopped, 0)
    }

    func testPrimaryArtistOnlyAppliesToScrobbleEvents() async {
        var seen: [ScrobbleTracker.ScrobbleEvent] = []
        let tracker = ScrobbleTracker(
            configuration: ScrobbleTracker.Configuration(
                minDurationSeconds: 0, delayPercent: 0.0, maxDelaySeconds: 0,
                useNowPlaying: false, usePrimaryArtistOnly: true
            ),
            scrobble: { seen.append($0) }
        )
        let song = Song(videoId: "v", title: "T", artist: "Anitta & Shakira", durationText: "4:00")
        await tracker.noteStarted(song: song)
        // Zero delay scrobbles on the next runloop turn; poll briefly.
        for _ in 0 ..< 50 {
            if !seen.isEmpty { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(seen.first?.artist, "Anitta")
    }
}
