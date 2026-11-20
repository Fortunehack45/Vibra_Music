import VibraMusicCore
import Lyrics
import SwiftUI
import XCTest
@testable import Vibra Music

/// PORTING.md "Lyrics translation and romanization": translate into the app's language or a
/// chosen one of ~130, or romanize.
@MainActor
final class LyricsTranslationUITests: XCTestCase {
    private let japanese = [
        LyricLine(timeMs: 1_410, text: "静かな港に灯りがともる頃に", sungUntilMs: 6_830),
        LyricLine(timeMs: 6_830, text: ""),
        LyricLine(timeMs: 8_920, text: "遠い波の音が窓をたたく朝", sungUntilMs: 15_680),
    ]

    private func controller() -> LyricsTranslationController {
        let controller = LyricsTranslationController(translator: LyricsTranslator(session: RecordedTranslateURLProtocol.session(), cacheDirectory: nil))
        controller.configure(trackId: "minato", lines: japanese, preferredLanguage: "", appLanguageTag: "en")
        return controller
    }

    /// Japanese lyrics become English, and the timing still matches: the panel's
    /// translate disc, the lines it hangs under each original, and the status line.
    func testJapaneseLyricsBecomeEnglishAndTheTimingStillMatches() async throws {
        let translation = controller()
        XCTAssertEqual(translation.targetLanguage, "en", "blank setting follows the app language")
        translation.toggleTranslation()
        XCTAssertEqual(LyricsStatus.text(translation: translation, source: .lrcLib, unavailable: false, hasLyrics: true, loadingText: ""),
                       L10n.translatingLyricsTo(translation.targetLanguageName))
        await waitUntil("translated") { translation.showingTranslation }

        let sub = try XCTUnwrap(translation.subLines)
        XCTAssertEqual(sub.map(\.text), ["As the quiet harbor lights up", "", "In the morning, distant waves knock at the window"])
        XCTAssertEqual(sub.map(\.timeMs), japanese.map(\.timeMs), "each translation sits under its own line, on its clock")
        XCTAssertEqual(sub.map(\.endMs), japanese.map(\.endMs))
        XCTAssertEqual(translation.displayedLines.map(\.text), sub.map(\.text), "the strip reads the translation")
        XCTAssertEqual(LyricsStatus.text(translation: translation, source: .lrcLib, unavailable: false, hasLyrics: true, loadingText: ""),
                       L10n.lyricsTranslatedTo(translation.targetLanguageName))

        // The panel hangs them under the originals.
        let clock = LyricFrameClock()
        clock.reset(positionMs: 9_500, isPlaying: false)
        let host = renderLyricsView(
            LyricsPanelContent(lines: japanese, subLines: translation.subLines, looking: false, trackKey: "minato", clock: clock, isPlaying: false, translation: translation, onSeek: { _ in }),
            settings: makeTestSettings()
        )
        let drawn = host.view.lyricsDescendants(of: LyricLineUIView.self).map(\.line.text)
        XCTAssertTrue(drawn.contains("In the morning, distant waves knock at the window"), "drawn: \(drawn)")

        // Tapping again goes straight back, with no second request.
        translation.toggleTranslation()
        XCTAssertFalse(translation.showingTranslation)
        XCTAssertNil(translation.subLines)
        XCTAssertEqual(LyricsStatus.text(translation: translation, source: .lrcLib, unavailable: false, hasLyrics: true, loadingText: ""),
                       L10n.lyricsBy(LyricsSource.lrcLib.label))
    }

    func testJapaneseLyricsRomanize() async throws {
        let translation = controller()
        translation.toggleRomanization()
        await waitUntil("romanized") { translation.showingRomanization }
        let sub = try XCTUnwrap(translation.subLines)
        XCTAssertTrue(sub[0].text.lowercased().contains("shizuka"))
        XCTAssertEqual(sub.map(\.timeMs), japanese.map(\.timeMs))
        XCTAssertEqual(LyricsStatus.text(translation: translation, source: nil, unavailable: false, hasLyrics: true, loadingText: ""), L10n.lyricsRomanized)
    }

    func testTheLanguagePickerListsAboutOneHundredThirtyAndFiltersInEitherLanguage() {
        let english = TranslationLanguageChoices(locale: Locale(identifier: "en"))
        XCTAssertGreaterThanOrEqual(english.rows.count, 130)
        XCTAssertTrue(english.filtered(by: "japan").contains { $0.language.code == "ja" })
        XCTAssertEqual(english.filtered(by: "  ").count, english.rows.count)
        XCTAssertTrue(english.filtered(by: "zzzz").isEmpty)

        // Reading the app in German, "Japanese" still finds Japanisch.
        let german = TranslationLanguageChoices(locale: Locale(identifier: "de"))
        let row = german.filtered(by: "Japanese").first { $0.language.code == "ja" }
        XCTAssertEqual(row?.name, "Japanisch")
        XCTAssertEqual(row?.detail, "Japanese")

        XCTAssertTrue(TranslationLanguageChoices.showsAppDefault(query: ""))
        XCTAssertFalse(TranslationLanguageChoices.showsAppDefault(query: "ja"))
        XCTAssertTrue(TranslationLanguageChoices.isSelected("zh-TW", stored: "zh-tw"))
        XCTAssertEqual(LyricsTranslationTarget.resolve(preferred: "zh-TW", appLanguageTag: "en"), "zh-TW", "a chosen language is sent as is")
    }

    func testNoticesAndDiscsAndTheSheetRender() {
        XCTAssertEqual(LyricsStatus.message(for: .alreadyInLanguage(languageName: "English")), L10n.lyricsAlreadyInLanguage("English"))
        XCTAssertEqual(LyricsStatus.message(for: .romanizationUnavailable), L10n.lyricsRomanizationUnavailable)
        let settings = makeTestSettings()
        settings.translationLanguage = "ja"
        renderLyricsView(TranslationLanguageSheet(), settings: settings)
        renderLyricsView(LyricsTranslationDisc(kind: .translate, state: .loading, showing: false, enabled: true, action: {}), settings: settings)
    }
}
