import XCTest

/// Verifies sharing lyrics end to end. Run it from the folder that holds `VibraMusic.xcworkspace`:
/// `xcodebuild test -workspace VibraMusic.xcworkspace -scheme Vibra Music -testPlan Vibra MusicE2E
/// -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:VibraMusicUITests/LyricsShareVerifyTests`.
///
/// Android 1.8's share lyrics, driven the way a user does it: long-press a lyric line to start
/// picking (3b4a12e1), tap a second line, Share, then the card, "Make it a story" and back, and Save
/// to Photos (89912638's header entry is captured along the way, since it is the way out while a
/// pick is open). The song comes from live YouTube Music, so a run with no lyrics proves nothing
/// about the pick; the screenshot shows which state it reached.
final class LyricsShareVerifyTests: XCTestCase {
    func testPickingLinesAndSendingTheCard() throws {
        continueAfterFailure = false
        let app = launchForVerify()
        try playASong(app)

        app.descendants(matching: .any).matching(identifier: "miniPlayer").firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "screen.nowPlaying").firstMatch
            .waitForExistence(timeout: 15), "the mini player did not open the player")
        capture(app, "1-player")

        app.buttons["nowPlaying.lyrics"].firstMatch.tap()
        // A line with words: an empty row is nothing to pick and nothing to read.
        let rows = app.buttons.matching(identifier: "lyrics.line").matching(NSPredicate(format: "label.length > 0"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 40), "no lyric lines: the lookup did not answer")
        capture(app, "2-lyrics-up")

        rows.element(boundBy: 0).press(forDuration: 0.8)
        let share = app.buttons["lyrics.pick.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 5), "a long press on a line did not open the pick bar")
        XCTAssertEqual(app.buttons["nowPlaying.more"].label, "Cancel",
                       "the header disc is the menu, not the way out of a pick")
        XCTAssertTrue(waitForValue("Selected", on: rows.element(boundBy: 0)),
                      "the long-pressed line does not say it was chosen")
        capture(app, "3-long-press-started-picking")

        rows.element(boundBy: 1).tap()
        // The second line has to join the pick: the first one already lit Share, so the row marking
        // is the only thing that says this tap landed.
        XCTAssertTrue(waitForValue("Selected", on: rows.element(boundBy: 1)),
                      "the tapped second line was not added to the pick")
        XCTAssertTrue(waitForValue("Selected", on: rows.element(boundBy: 0)),
                      "the first line fell out of the pick")
        capture(app, "4-second-line-picked")

        XCTAssertTrue(share.isEnabled, "Share is dim with two lines chosen")
        share.tap()
        let card = app.descendants(matching: .any).matching(identifier: "lyricsShare.card").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "the share sheet never drew a card")
        XCTAssertTrue(app.staticTexts["Share lyrics"].exists, "the sheet is not titled the way Android's is")
        capture(app, "5-share-sheet-card")

        let story = app.buttons["lyricsShare.story"]
        XCTAssertTrue(story.waitForExistence(timeout: 5))
        XCTAssertEqual(story.label, "Make it a story")
        story.tap()
        XCTAssertTrue(waitForLabel("Back to the card", on: story), "the story toggle did not redraw the card: \(story.label)")
        capture(app, "6-story")

        story.tap()
        XCTAssertTrue(waitForLabel("Make it a story", on: story), "the story toggle did not go back: \(story.label)")
        capture(app, "7-back-to-the-card")

        saveToPhotos(app)
        XCTAssertTrue(waitForLabel("Saved!", on: app.buttons["lyricsShare.save"]),
                      "the card was not written to Photos: \(app.buttons["lyricsShare.save"].label)")
        capture(app, "8-saved")
    }

    // MARK: Helpers

    private func playASong(_ app: XCUIApplication) throws {
        let searchTab = app.tabBars.buttons.element(boundBy: 3)
        XCTAssertTrue(searchTab.waitForExistence(timeout: 15), "no Search tab")
        searchTab.tap()
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "search.field is missing")
        field.typeText("daft punk\n")
        let row = app.descendants(matching: .any).matching(identifier: "songRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "no song row 30 s after searching")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "miniPlayer").firstMatch
            .waitForExistence(timeout: 30), "the mini player never appeared")
    }

    /// Save asks Photos for add-only access the first time; the system alert belongs to SpringBoard,
    /// and the button says "Saved!" once the write lands.
    private func saveToPhotos(_ app: XCUIApplication) {
        app.buttons["lyricsShare.save"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // The add-only prompt's accept button has been labelled differently across releases.
        let allow = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "Add Photos", "Allow Access to All Photos"])).firstMatch
        if allow.waitForExistence(timeout: 6) { allow.tap() }
    }

    private func waitForLabel(_ label: String, on element: XCUIElement, timeout: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.label == label { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return element.label == label
    }

    /// The marking on a chosen line rides in the accessibility value — the selected trait belongs
    /// to the line being sung — so that is where the drive reads what is picked.
    private func waitForValue(_ value: String, on element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.value as? String == value { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return element.value as? String == value
    }
}
