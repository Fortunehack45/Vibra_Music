import VibraMusicCore
import Lyrics
import SwiftUI
import XCTest
@testable import Vibra Music

/// PORTING.md "Lyrics providers": 16 providers the listener turns on or off and reorders, and a
/// picker to choose one for the current track.
@MainActor
final class LyricsProviderUITests: XCTestCase {
    /// Turning off the top provider makes lyrics load from the next one, through the
    /// sources sheet's own toggle rule and the settings it writes.
    func testTurningOffTheTopProviderLoadsFromTheNextOne() async throws {
        let settings = makeTestSettings()
        let repository = LyricsDemo.repository()

        let first = LyricsSession(repository: repository)
        first.load(LyricsDemo.track, preferences: LyricsPreferences(settings: settings))
        await waitUntil("the first lookup") { first.isChecked }
        XCTAssertEqual(first.source, .biniLyrics)

        let top = try XCTUnwrap(settings.lyricsSourceOrder.first)
        XCTAssertEqual(top, .biniLyrics)
        settings.lyricsSources = try XCTUnwrap(LyricsSourceSelection.toggling(top, in: settings.lyricsSources))
        XCTAssertFalse(settings.lyricsSources.contains(.biniLyrics))

        // Changing the enabled set re-runs the lookup for the same track.
        first.load(LyricsDemo.track, preferences: LyricsPreferences(settings: settings))
        await waitUntil("the second lookup") { first.isChecked }
        XCTAssertEqual(first.source, .betterLyrics)
        XCTAssertFalse(first.lines?.isEmpty ?? true)
    }

    func testTheLastSourceStandingCantBeUntickedAndOrderIsIndependent() {
        XCTAssertEqual(LyricsSource.allCases.count, 16)
        XCTAssertNil(LyricsSourceSelection.toggling(.genius, in: [.genius]))
        XCTAssertFalse(LyricsSourceSelection.isToggleable(.genius, in: [.genius]))
        XCTAssertTrue(LyricsSourceSelection.isToggleable(.lrcLib, in: [.genius]))
        XCTAssertEqual(LyricsSourceSelection.toggling(.lrcLib, in: [.genius]), [.genius, .lrcLib])

        let settings = makeTestSettings()
        let order = LyricsSourceSelection.moving(settings.lyricsSourceOrder, from: IndexSet(integer: 0), to: 3)
        settings.lyricsSourceOrder = order
        XCTAssertEqual(settings.lyricsSourceOrder[2], .biniLyrics)
        XCTAssertEqual(Set(settings.lyricsSourceOrder), Set(LyricsSource.allCases), "still every source")
        settings.resetLyricsSourceSettings()
        XCTAssertEqual(settings.lyricsSourceOrder, LyricsSource.allCases)
    }

    func testProviderRowsSayWhereEachSourceStands() {
        let current = LyricsProviderRowState(source: .biniLyrics, state: .found, current: true)
        XCTAssertFalse(current.enabled)
        XCTAssertEqual(current.status, L10n.lyricsProviderCurrent)
        XCTAssertEqual(current.mark, .check)

        let found = LyricsProviderRowState(source: .lrcLib, state: .found, current: false)
        XCTAssertTrue(found.enabled)
        XCTAssertEqual(found.status, L10n.lyricsProviderFound)

        let missing = LyricsProviderRowState(source: .kuGou, state: .notFound, current: false)
        XCTAssertFalse(missing.enabled, "a miss can't be asked twice")
        XCTAssertEqual(missing.mark, .cross)

        let running = LyricsProviderRowState(source: .paxSenix, state: .fetching, current: false)
        XCTAssertTrue(running.enabled, "a running request can still be picked")
        XCTAssertEqual(running.mark, .spinner)
        XCTAssertEqual(LyricsProviderRowState(source: .genius, state: .notFetched, current: false).mark, .search)

        XCTAssertEqual(LyricsProviderRowState.orderedSources([.genius, .lrcLib]).prefix(2), [.genius, .lrcLib])
        XCTAssertEqual(LyricsProviderRowState.orderedSources([.genius]).count, 16)
    }

    func testPickingAFoundProviderSwitchesTheLyrics() async {
        let session = LyricsSession(repository: LyricsDemo.repository())
        session.load(LyricsDemo.track, preferences: .default)
        await waitUntil("lookup") { session.isChecked && session.providerStates[.lrcLib] == .found }
        XCTAssertEqual(session.source, .biniLyrics)
        session.selectProvider(.lrcLib)
        XCTAssertEqual(session.source, .lrcLib)
        XCTAssertFalse(session.lines?.first(where: { !$0.isGap })?.isWordSynced ?? true, "LRCLIB's answer is line-synced")
    }

    /// Picking another provider for the same song hands its lines to the translation too, even
    /// when the answer has the same number of lines and the same first line (review fix: the
    /// panel used to key the translation on a summary of the lines and kept the old timings).
    func testPickingAProviderRekeysTheTranslationToTheNewLines() async {
        let settings = makeTestSettings()
        let session = LyricsSession(repository: LyricsDemo.repository())
        session.load(LyricsDemo.track, preferences: .default)
        await waitUntil("lookup") { session.isChecked && session.providerStates[.lrcLib] == .found }
        let translation = LyricsTranslationController()
        let host = renderLyricsView(LyricsPanel().environment(session).environment(translation), settings: settings)
        XCTAssertEqual(translation.displayedLines, session.lines ?? [])

        let before = session.lines ?? []
        session.selectProvider(.lrcLib)
        let after = session.lines ?? []
        XCTAssertEqual(after.count, before.count)
        XCTAssertEqual(after.first?.text, before.first?.text)
        XCTAssertNotEqual(after, before)
        await waitUntil("the translation follows the new lines") {
            host.view.layoutIfNeeded()
            return translation.displayedLines == after
        }
    }

    func testTheSourcesAndProviderSheetsRender() async {
        let settings = makeTestSettings()
        renderLyricsView(LyricsSourcesSheet(), settings: settings)
        let session = LyricsSession(repository: LyricsDemo.repository())
        session.load(LyricsDemo.track, preferences: .default)
        await waitUntil("lookup") { session.isChecked }
        renderLyricsView(LyricsProviderSheet().environment(session), settings: settings)
        renderLyricsView(LyricsProviderSheet(), settings: settings)
    }
}
