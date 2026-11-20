import XCTest

/// Verifies Library and playlists, driven the way a user does it. A song goes into two
/// playlists from one sheet, and a page's header carries its total play time. Run it from the
/// folder that holds `VibraMusic.xcworkspace`:
/// `xcodebuild test -workspace VibraMusic.xcworkspace -scheme Vibra Music -testPlan Vibra MusicE2E
/// -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:VibraMusicUITests/PlaylistsVerifyTests`.
/// Launched with `-collectionsDemo`: the account is signed in and every write succeeds without
/// being sent, while playlists and pages come from the live YouTube Music.
final class PlaylistsVerifyTests: XCTestCase {
    /// The Android 1.8 picker (PlaylistPickerSheet.kt, commit 21c5831c): rows tick instead of
    /// closing the sheet, the button counts the ticks, and one notice sums up the batch.
    func testTickingTwoPlaylistsAddsToBothWithOneNotice() {
        continueAfterFailure = false
        let app = launchForVerify(["-collectionsDemo"])
        capture(app, "1-launched")

        let searchTab = app.tabBars.buttons.element(boundBy: 3)
        XCTAssertTrue(searchTab.waitForExistence(timeout: 15), "no Search tab")
        searchTab.tap()
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "search.field is missing")
        field.typeText("daft punk\n")

        let row = app.descendants(matching: .any).matching(identifier: "songRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "no song row 30 s after searching")
        capture(app, "2-results")

        row.press(forDuration: 0.8)
        let actions = app.descendants(matching: .any).matching(identifier: "sheet.songActions").firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 10), "the song menu did not open")
        capture(app, "3-song-menu")

        let addToPlaylist = app.descendants(matching: .any).matching(identifier: "songActions.addToPlaylist").firstMatch
        XCTAssertTrue(addToPlaylist.waitForExistence(timeout: 10), "no Add to playlist row")
        addToPlaylist.tap()

        let picker = app.descendants(matching: .any).matching(identifier: "sheet.playlistPicker").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 20), "the picker did not open")
        let button = app.descendants(matching: .any).matching(identifier: "picker.add").firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 20), "the picker has no add button")
        XCTAssertEqual(button.label, "Add to playlist", "nothing ticked: the button names the action")
        XCTAssertFalse(button.isEnabled, "nothing ticked: the button is off")
        capture(app, "4-picker-nothing-ticked")

        let rows = app.descendants(matching: .any).matching(identifier: "picker.playlist")
        XCTAssertGreaterThanOrEqual(rows.count, 2, "the demo account has fewer than two playlists to tick")
        rows.element(boundBy: 0).tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "a tick closed the sheet")
        XCTAssertTrue(button.waitForExistence(timeout: 5), "a tick took the button away")
        XCTAssertEqual(button.label, "Add to 1 playlist", "one ticked: the button counts it")
        capture(app, "5-picker-one-ticked")

        rows.element(boundBy: 1).tap()
        XCTAssertEqual(button.label, "Add to 2 playlists", "two ticked: the button counts them")
        XCTAssertTrue(button.isEnabled, "two ticked: the button is on")
        capture(app, "6-picker-two-ticked")

        button.tap()
        // The playlists are live YouTube Music ones, so a ticked list may already hold the song:
        // the demo cannot reach "Failed" (its writes never leave the device), but it can land on
        // "Already in playlist" or "Added to playlist". The exact mapping from counts to text is
        // pinned by the store tests; here the proof is that the batch leaves one notice.
        let notice = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR label == %@",
                                                          "Added to", "Already in playlist")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 30), "the batch left no notice")
        capture(app, "7-notice")
        XCTAssertTrue(["Added to 2 playlists", "Added to playlist", "Already in playlist"].contains(notice.label),
                      "unexpected notice for a two-playlist batch: \(notice.label)")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "sheet.playlistPicker").firstMatch.exists,
                       "the batch left the picker up")
    }

    /// DetailScreen.kt's `playtime` (same commit): a page's header shows the rows' lengths summed,
    /// "41 min" under an hour and "1h 25m" over it, next to the track count.
    func testAnOpenedPageShowsItsTotalPlayTime() {
        continueAfterFailure = false
        let app = launchForVerify(["-collectionsDemo"])

        let libraryTab = app.tabBars.buttons.element(boundBy: 2)
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 15), "no Library tab")
        libraryTab.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "screen.library").firstMatch
            .waitForExistence(timeout: 20), "the Library did not open")
        capture(app, "1-library")

        // An album from Search rather than a Library card: the On device shelf's cards carry the
        // same `libraryCard` identifier and open Downloads, not a release page.
        let searchTab = app.tabBars.buttons.element(boundBy: 3)
        XCTAssertTrue(searchTab.waitForExistence(timeout: 10), "no Search tab")
        searchTab.tap()
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "search.field is missing")
        field.typeText("daft punk\n")

        let albums = app.descendants(matching: .any).matching(identifier: "search.filter.ALBUMS").firstMatch
        XCTAssertTrue(albums.waitForExistence(timeout: 20), "no Albums filter")
        albums.tap()
        let album = app.descendants(matching: .any).matching(identifier: "browseRow").firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 30), "no album row 30 s after filtering")
        capture(app, "2-albums")
        album.tap()

        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "screen.detail").firstMatch
            .waitForExistence(timeout: 25), "the album page did not open")
        // The metadata line is uppercased: "ALBUM • 2001 • 14 TRACKS • 41 MIN", or "1H 25M".
        let meta = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@",
                                                        ".*([0-9]+ MIN|[0-9]+H [0-9]+M).*"))
            .firstMatch
        XCTAssertTrue(meta.waitForExistence(timeout: 30), "the header shows no play time next to the track count")
        capture(app, "3-page-header-play-time")
    }
}
