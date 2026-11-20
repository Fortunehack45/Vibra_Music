import XCTest

/// Verifies the queue's "Previously played" history (Android v1.8.1, kushagrasinghx/Vibra Music#167),
/// driven the way a user does it, with a screenshot per step. Run it from the folder that holds
/// `VibraMusic.xcworkspace`:
/// `xcodebuild test -workspace VibraMusic.xcworkspace -scheme VibraMusic -testPlan VibraMusicE2E
/// -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:VibraMusicUITests/QueueHistoryVerifyTests`.
/// The history builds from what the drive plays: two songs, so a skip leaves one played row.
/// Streaming on a simulator sometimes never starts; the queue still moves on `next`, so the drive
/// keeps its screenshots either way and a stall shows up in the evidence.
final class QueueHistoryVerifyTests: XCTestCase {
    func testPreviouslyPlayedListedAboveNowPlaying() {
        continueAfterFailure = false
        let app = launchForVerify()

        // The setting persists, so restore it off whatever happens: even an assertion on the
        // condition this drive exists to check must not leave it on for a rerun.
        addTeardownBlock {
            app.open(URL(string: "vibramusic://settings")!)
            let row = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "Show queue history")).firstMatch
            var swipes = 0
            while !row.exists && swipes < 14 {
                app.swipeUp()
                swipes += 1
            }
            if row.waitForExistence(timeout: 5), row.value as? String == "1" {
                row.tap()
            }
            self.capture(app, "99-settings-restored")
        }
        capture(app, "1-launched")

        // Play the first song out of Search (the user path; queue starts empty under -uitesting).
        app.tabBars.buttons.element(boundBy: 3).tap()
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "search.field is missing")
        field.typeText("daft punk\n")
        let row = app.descendants(matching: .any).matching(identifier: "songRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no song row after searching (see 2-search-results)")
        capture(app, "2-search-results")
        row.tap()

        let skipped = app.descendants(matching: .any)
            .matching(identifier: "miniPlayer.title").firstMatch
        XCTAssertTrue(skipped.waitForExistence(timeout: 30), "no mini player after tapping a song (see 3-playing)")
        capture(app, "3-playing")

        // Down the queue once, so the tapped song sits above Now playing.
        app.descendants(matching: .any).matching(identifier: "miniPlayer").firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "screen.nowPlaying").firstMatch.waitForExistence(timeout: 15), "Now Playing did not open")
        app.buttons["nowPlaying.next"].tap()
        capture(app, "4-now-playing-after-next")
        XCTAssertTrue(app.buttons["nowPlaying.queue"].waitForExistence(timeout: 10), "no queue button on Now Playing")

        // The queue, with the setting still off: no "Previously played".
        app.buttons["nowPlaying.queue"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "nowPlaying.queuePanel").firstMatch.waitForExistence(timeout: 10), "the queue panel did not open")
        capture(app, "5-queue-history-off")
        XCTAssertFalse(app.staticTexts["Previously played"].exists, "history is listed while the setting is off")

        // Settings: turn "Show queue history" on (it sits under Playback, so scroll to it).
        app.open(URL(string: "vibramusic://settings")!)
        let historyRow = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "Show queue history")).firstMatch
        var swipes = 0
        while !historyRow.exists && swipes < 12 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(historyRow.waitForExistence(timeout: 10), "the Show queue history row never appeared (see 6-settings)")
        capture(app, "6-settings")
        historyRow.tap()
        capture(app, "7-settings-toggled")

        // Back to the queue the way a user returns: open the mini player again.
        let mini = app.descendants(matching: .any).matching(identifier: "miniPlayer").firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 15), "the mini player is gone after Settings")
        mini.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "screen.nowPlaying").firstMatch.waitForExistence(timeout: 15), "Now Playing did not reopen")
        app.buttons["nowPlaying.queue"].tap()
        let panel = app.descendants(matching: .any).matching(identifier: "nowPlaying.queuePanel").firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "the queue panel did not reopen")
        let history = app.staticTexts["Previously played"]
        XCTAssertTrue(history.waitForExistence(timeout: 10), "no Previously played heading with the setting on (see 8-queue-history-on)")
        let nowPlayingRow = app.descendants(matching: .any).matching(identifier: "queue.nowPlaying").firstMatch
        XCTAssertTrue(nowPlayingRow.exists, "Now playing is missing beside the history")
        XCTAssertLessThan(history.frame.minY, nowPlayingRow.frame.minY, "the history is not above Now playing")
        capture(app, "8-queue-history-on")

        // The panel opens on Now playing by design (Android 59211f2a scrolls to the Now playing
        // row), so the history sits above the viewport: prove it is reachable by scrolling up.
        panel.swipeDown()
        XCTAssertTrue(history.isHittable, "the Previously played heading is not reachable by scrolling up (see 9-history-reached)")
        capture(app, "9-history-reached")
    }
}
