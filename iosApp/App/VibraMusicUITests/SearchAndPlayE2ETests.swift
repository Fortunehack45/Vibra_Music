import XCTest

/// The app working end to end against the real YouTube Music: search, tap, hear it (the position
/// advances), and an album played from its page. Part of the VibraMusicE2E test plan: they need the
/// network. PORTING.md "YouTube Music API client" done criterion: a signed-out user searches
/// "Daft Punk" and a song plays.
final class SearchAndPlayE2ETests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        // Starts from an empty queue, so what the test plays is what the mini player shows.
        app.launchArguments = ["-uitesting"]
        app.launch()
    }

    override func tearDown() {
        app.terminate()
        super.tearDown()
    }

    func testSearchingDaftPunkAndTappingTheFirstSongPlaysIt() throws {
        search("Daft Punk")

        let firstSong = element("songRow")
        XCTAssertTrue(firstSong.waitForExistence(timeout: 30), "no song in the results")
        let rowLabel = firstSong.label
        firstSong.tap()

        let title = app.staticTexts["miniPlayer.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 20), "the mini player never appeared")
        XCTAssertFalse(title.label.isEmpty)
        XCTAssertTrue(rowLabel.hasPrefix(title.label), "mini player shows \"\(title.label)\", the row was \"\(rowLabel)\"")

        let started = try waitForPosition(atLeast: 0.5, timeout: 45)
        Thread.sleep(forTimeInterval: 5)
        let later = try position()
        XCTAssertGreaterThan(later - started, 3, "playback did not advance: \(started) s â†’ \(later) s")
    }

    func testAnAlbumOpenedFromSearchPlaysOneOfItsTracksOnShuffle() throws {
        search("Daft Punk")

        let album = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'browseRow' AND label CONTAINS[c] 'Album'"))
            .firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 30), "no album in the results")
        album.tap()

        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: 20), "the album page did not open")
        XCTAssertTrue(element("songRow").waitForExistence(timeout: 30), "the album has no tracks")
        let shuffle = app.buttons["detail.shuffle"]
        XCTAssertTrue(shuffle.waitForExistence(timeout: 5))
        shuffle.tap()

        let title = app.staticTexts["miniPlayer.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 20), "the mini player never appeared")
        let playing = title.label
        XCTAssertFalse(playing.isEmpty)

        // The playing track is one of this album's rows (scrolling to it if the list is long).
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'songRow' AND label BEGINSWITH %@", playing))
            .firstMatch
        var swipes = 0
        while !row.exists && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(row.exists, "\"\(playing)\" is not on the album page")
        _ = try waitForPosition(atLeast: 0.5, timeout: 45)
    }

    // MARK: - Helpers

    private func search(_ query: String) {
        let searchTab = app.tabBars.buttons.element(boundBy: 3)
        XCTAssertTrue(searchTab.waitForExistence(timeout: 15))
        searchTab.tap()
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(query + "\n")
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The mini player's playback position, in seconds (its progress line's accessibility value).
    private func position() throws -> Double {
        let progress = element("miniPlayer.progress")
        guard progress.exists else { return 0 }
        return Double(progress.value as? String ?? "") ?? 0
    }

    private func waitForPosition(atLeast seconds: Double, timeout: TimeInterval) throws -> Double {
        let deadline = Date().addingTimeInterval(timeout)
        var last = 0.0
        while Date() < deadline {
            last = (try? position()) ?? 0
            if last >= seconds { return last }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("playback never started (position stayed at \(last) s)")
        return last
    }
}
