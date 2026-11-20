import XCTest

/// The Search tab's field: tapping the tab focuses it and brings the keyboard up (Android's
/// `LaunchedEffect(focusRequested)`), and every keystroke lands — the field and keyboard stay put
/// while the completions list takes over the page beneath them.
///
/// Offline-safe: it asserts only on what was typed into the field, never on a network answer.
final class SearchTypingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uitesting"]
        app.launch()
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    /// Tapping the Search tab brings the keyboard up, and the field takes input straight away.
    func testTappingTheSearchTabFocusesTheField() {
        tapSearchTab()

        XCTAssertTrue(waitForKeyboard(), "tapping the Search tab did not focus the field")
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10),
                      "search.field is not reachable under the screen.search identifier")
        field.typeText("daft punk")
        XCTAssertEqual(field.value as? String, "daft punk", "the focused field did not take the query")
    }

    /// Type the whole query, let the completions list take over, then type once more: nothing is
    /// lost, because the field keeps focus and the keyboard stays up the way Android's does.
    func testTypingDaftPunkKeepsFocusAndUpdatesTheField() {
        tapSearchTab()

        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10),
                      "search.field is not reachable under the screen.search identifier")
        field.tap()

        field.typeText("daft punk")
        XCTAssertEqual(field.value as? String, "daft punk", "the field did not take the whole query")

        // Long enough for the 180 ms completion debounce (and the 350 ms typeahead one) to land and
        // swap the list out from under the field.
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(waitForKeyboard(), "the keyboard came down while typing")
        field.typeText("!")
        XCTAssertEqual(field.value as? String, "daft punk!", "a keystroke after the completions appeared was lost")
    }

    // MARK: - Helpers

    private func tapSearchTab() {
        let searchTab = app.tabBars.buttons.element(boundBy: 3)
        XCTAssertTrue(searchTab.waitForExistence(timeout: 15))
        searchTab.tap()
    }

    private func waitForKeyboard(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.keyboards.count == 1 { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }
}
