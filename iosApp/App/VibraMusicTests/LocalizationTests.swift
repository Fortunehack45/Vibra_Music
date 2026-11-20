import SwiftUI
import XCTest
@testable import Vibra Music

/// The string catalog is generated from the Android strings.xml files; these pin that the
/// conversion kept every language, plural rules and the in-app language override working.
final class LocalizationTests: XCTestCase {
    private var savedOverride: String?

    override func setUp() {
        super.setUp()
        savedOverride = LanguageBundle.override
    }

    override func tearDown() {
        LanguageBundle.override = savedOverride
        super.tearDown()
    }

    func testEnglishIsTheFallback() {
        LanguageBundle.override = "en"
        XCTAssertEqual(L10n.cancel, "Cancel")
        XCTAssertEqual(L10n.songCountPlural(1), "1 song")
        XCTAssertEqual(L10n.songCountPlural(3), "3 songs")
    }

    func testOverrideSwitchesLanguageWithoutRelaunch() {
        LanguageBundle.override = "de"
        XCTAssertEqual(L10n.cancel, "Abbrechen")
        LanguageBundle.override = "he"
        XCTAssertEqual(L10n.cancel, "ביטול")
    }

    func testRussianUsesAllPluralCategories() {
        LanguageBundle.override = "ru"
        XCTAssertEqual(L10n.songCountPlural(1), "1 песня")
        XCTAssertEqual(L10n.songCountPlural(3), "3 песни")
        XCTAssertEqual(L10n.songCountPlural(5), "5 песен")
    }

    func testTextCountPluralsSelectOnTheNumberButPrintTheText() {
        LanguageBundle.override = "en"
        XCTAssertEqual(L10n.replayPlayCount(1, formatted: "1"), "1 play")
        XCTAssertEqual(L10n.replayPlayCount(1_234, formatted: "1,234"), "1,234 plays")
        LanguageBundle.override = "de"
        XCTAssertEqual(L10n.replayPlayCount(2, formatted: "2"), "2 Wiedergaben")
    }

    func testEveryShippedLanguageHasALocalizationBundle() {
        for code in LanguageBundle.supported {
            XCTAssertNotNil(Bundle.main.path(forResource: code, ofType: "lproj"), "missing \(code).lproj")
        }
    }

    func testHebrewMirrorsTheLayout() {
        LanguageBundle.override = "he"
        XCTAssertEqual(LanguageBundle.layoutDirection, .rightToLeft)
        LanguageBundle.override = "fr"
        XCTAssertEqual(LanguageBundle.layoutDirection, .leftToRight)
    }

    func testASystemLanguageTheAppDoesNotShipDoesNotMirrorTheEnglishFallback() {
        XCTAssertEqual(LanguageBundle.layoutDirection(override: nil, preferred: ["ar-SA"]), .leftToRight)
        XCTAssertEqual(LanguageBundle.layoutDirection(override: nil, preferred: ["fa", "he-IL"]), .rightToLeft)
        XCTAssertEqual(LanguageBundle.layoutDirection(override: "he", preferred: ["en-US"]), .rightToLeft)
    }

    func testUnsupportedOverrideFallsBackToSystem() {
        LanguageBundle.override = "xx"
        XCTAssertNil(LanguageBundle.override)
    }
}
