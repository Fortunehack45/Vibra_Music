import XCTest
@testable import Vibra Music

/// HomeScreen.kt's shelf-title, strapline and card-subtitle translations (part of "Home feed").
final class ShelfLocalizationTests: XCTestCase {
    func testKnownShelfTitlesUseTheAppsStringsInAnyOfYouTubesLanguages() {
        XCTAssertEqual(ShelfLocalization.title("Quick picks"), L10n.shelfQuickPicks)
        XCTAssertEqual(ShelfLocalization.title("  listen again "), L10n.shelfListenAgain)
        XCTAssertEqual(ShelfLocalization.title("Nghe lại"), L10n.shelfListenAgain)
        XCTAssertEqual(ShelfLocalization.title("チャート"), L10n.shelfCharts)
        XCTAssertEqual(ShelfLocalization.title("Recently played"), L10n.shelfRecents)
        XCTAssertEqual(ShelfLocalization.title("Similar to Daft Punk"), L10n.shelfSimilarTo("Daft Punk"))
        XCTAssertEqual(ShelfLocalization.title("Shorts for you"), L10n.shelfShorts)
        XCTAssertEqual(ShelfLocalization.title("India’s biggest hits"), "India’s biggest hits", "unknown titles pass through")
    }

    func testStraplines() {
        XCTAssertEqual(ShelfLocalization.subtitle("TOP TUNES RIGHT NOW"), L10n.shelfTopTunesRightNow)
        XCTAssertEqual(ShelfLocalization.subtitle("YouTube Charts"), L10n.shelfYoutubeCharts)
        XCTAssertEqual(ShelfLocalization.subtitle("MUSIC THAT'S HOT"), "MUSIC THAT'S HOT")
    }

    func testCardSubtitlesTranslateTypeWordsAndTallies() {
        XCTAssertEqual(ShelfLocalization.cardSubtitle("Song • Daft Punk"), "\(L10n.shelfSongItem) • Daft Punk")
        XCTAssertEqual(ShelfLocalization.cardSubtitle("Single • IU"), "\(L10n.shelfSingle) • IU")
        XCTAssertEqual(ShelfLocalization.cardSubtitle("Daft Punk • 1.2M plays"), "Daft Punk • \(L10n.cardPlaysFormat("1.2M"))")
        XCTAssertEqual(ShelfLocalization.cardSubtitle("Playlist • 35 songs"), "\(L10n.playlist) • \(L10n.cardSongsFormat("35"))")
        XCTAssertEqual(ShelfLocalization.cardSubtitle("Artist • many views"), "Artist • many views", "no number, no rewrite")
        XCTAssertEqual(ShelfLocalization.cardSubtitle(""), "")
    }

    /// Review fix: the four strings Android hard-codes in English live in an English-only table;
    /// with the app's language set to one that table lacks, they showed as their bare keys
    /// ("search_filter_all").
    func testBrowseOwnStringsFallBackToEnglishUnderALanguageOverride() {
        let saved = LanguageBundle.override
        defer { LanguageBundle.override = saved }
        for language in ["fr", "he", "en"] {
            LanguageBundle.override = language
            XCTAssertEqual(BrowseStrings.filterLabel(.all), "All", language)
            XCTAssertEqual(BrowseStrings.filterLabel(.videos), "Videos", language)
            XCTAssertEqual(BrowseStrings.topResult, "Top result", language)
            XCTAssertEqual(BrowseStrings.sectionMore, "More", language)
        }
    }
}
