import XCTest
@testable import Vibra Music

/// Android 89912638 (after 1.8): while the lyrics are up, the header's three-dot disc becomes the
/// share entry — the same pick mode a long press on a line opens, with nothing preselected — and,
/// once a pick is on, the way back out. Everywhere else it is still the song menu.
final class PlayerMenuEntryTests: XCTestCase {
    private var savedOverride: String?

    /// The entry's labels are the app's copy, which follows the reader's language: an English
    /// system alone is not enough to compare them.
    override func setUp() {
        super.setUp()
        savedOverride = LanguageBundle.override
        LanguageBundle.override = "en"
    }

    override func tearDown() {
        LanguageBundle.override = savedOverride
        super.tearDown()
    }

    func testWithTheLyricsUpTheDiscIsTheShareEntry() {
        let entry = PlayerMenuEntry.entry(showsRevertCue: false, lyricsShareVisible: true, picking: false)

        XCTAssertEqual(entry.action, .startPick)
        XCTAssertEqual(entry.symbol, "square.and.arrow.up")
        XCTAssertEqual(entry.label, "Share")
        XCTAssertEqual(entry.haptic, .select)
    }

    func testWhilePickingTheDiscIsTheWayBackOut() {
        let entry = PlayerMenuEntry.entry(showsRevertCue: false, lyricsShareVisible: true, picking: true)

        XCTAssertEqual(entry.action, .cancelPick)
        XCTAssertEqual(entry.symbol, "xmark")
        XCTAssertEqual(entry.label, "Cancel")
    }

    func testEverywhereElseTheDiscIsTheSongMenu() {
        let closed = PlayerMenuEntry.entry(showsRevertCue: false, lyricsShareVisible: false, picking: false)
        XCTAssertEqual(closed.action, .menu)
        XCTAssertEqual(closed.symbol, "ellipsis")
        XCTAssertEqual(closed.label, "More")
        XCTAssertEqual(closed.haptic, .tap)

        // A pick belongs to the panel, so a disc outside it must not offer to cancel one.
        let awayFromTheLyrics = PlayerMenuEntry.entry(showsRevertCue: false, lyricsShareVisible: false, picking: true)
        XCTAssertEqual(awayFromTheLyrics.action, .menu)
        XCTAssertEqual(awayFromTheLyrics.label, "More")
    }

    func testTheRevertCueKeepsTheUndoArrowEvenWithTheLyricsUp() {
        let entry = PlayerMenuEntry.entry(showsRevertCue: true, lyricsShareVisible: true, picking: true)

        XCTAssertEqual(entry.action, .menu, "the undo arrow still opens the menu")
        XCTAssertEqual(entry.symbol, "arrow.uturn.backward")
        XCTAssertEqual(entry.label, "More")
    }
}
