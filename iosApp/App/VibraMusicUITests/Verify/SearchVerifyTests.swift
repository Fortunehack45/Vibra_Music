import XCTest

/// Verifies Search, driven the way a user does it, with a screenshot per step. Run it from the
/// folder that holds `VibraMusic.xcworkspace`:
/// `xcodebuild test -workspace VibraMusic.xcworkspace -scheme Vibra Music -testPlan Vibra MusicE2E
/// -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:VibraMusicUITests/SearchVerifyTests`.
/// Results come from the live YouTube Music, so the last step waits for a row but keeps its
/// screenshot either way: a stall shows up in the evidence instead of hiding behind a timeout.
final class SearchVerifyTests: XCTestCase {
    func testSearchingAQueryShowsResults() {
        continueAfterFailure = false
        let app = launchForVerify()
        capture(app, "1-launched")

        let searchTab = app.tabBars.buttons.element(boundBy: 3)
        XCTAssertTrue(searchTab.waitForExistence(timeout: 15), "no Search tab")
        searchTab.tap()
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "search.field is missing")
        capture(app, "2-search-tab")

        field.typeText("daft punk\n")
        XCTAssertEqual(field.value as? String, "daft punk", "the field lost the query")

        let result = app.descendants(matching: .any).matching(identifier: "search.topResult").firstMatch
        let row = app.descendants(matching: .any).matching(identifier: "songRow").firstMatch
        let found = result.waitForExistence(timeout: 20) || row.waitForExistence(timeout: 5)
        capture(app, "3-results")
        XCTAssertTrue(found, "no top result or song row 25 s after searching (see 3-results)")
    }
}
