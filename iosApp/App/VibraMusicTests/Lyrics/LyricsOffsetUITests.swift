import VibraMusicCore
import Lyrics
import SwiftUI
import XCTest
@testable import VibraMusic

/// PORTING.md "Lyrics offset": the listener shifts lyric timing.
@MainActor
final class LyricsOffsetUITests: XCTestCase {
    /// +500 ms moves the highlight later. Five taps of + in the sheet, then the panel
    /// fed the same playback position lights the earlier line for half a second longer.
    func testPlusFiveHundredMillisecondsMovesTheHighlightLater() {
        let settings = makeTestSettings()
        let control = LyricsOffsetControl(settings: settings)
        for _ in 0..<5 { control.increase() }
        XCTAssertEqual(settings.lyricsOffsetMs, 500)
        XCTAssertEqual(control.readout, LyricsOffset.formatted(500, locale: LanguageBundle.locale))
        XCTAssertTrue(control.readout.hasPrefix("+"))

        let lines = LyricsDemo.wordSynced
        let playback = 12_200 // 0.2 s into "I hear you over the water" (12.0 s)
        let model = LyricsPanelModel()
        model.setLines(lines)

        model.update(positionMs: LyricsOffset.adjustedPosition(positionMs: playback, offsetMs: 0))
        XCTAssertEqual(model.scrollLine, 4, "without an offset the new line is lit")
        model.update(positionMs: LyricsOffset.adjustedPosition(positionMs: playback, offsetMs: settings.lyricsOffsetMs))
        XCTAssertNotEqual(model.scrollLine, 4, "with +500 ms it isn't yet")
        model.update(positionMs: LyricsOffset.adjustedPosition(positionMs: playback + 500, offsetMs: settings.lyricsOffsetMs))
        XCTAssertEqual(model.scrollLine, 4, "…and lights half a second later")

        // Tapping the line seeks to where it lands with the offset applied.
        XCTAssertEqual(LyricsOffset.seekTarget(lineTimeMs: lines[4].timeMs, offsetMs: 500), 12_500)
    }

    func testTheButtonsClampAndTheSliderSnapsToTheStep() {
        let settings = makeTestSettings()
        let control = LyricsOffsetControl(settings: settings)
        XCTAssertFalse(control.canReset)
        control.setFraction(1)
        XCTAssertEqual(settings.lyricsOffsetMs, 5_000)
        XCTAssertFalse(control.canIncrease)
        control.increase()
        XCTAssertEqual(settings.lyricsOffsetMs, 5_000)
        control.setFraction(0.5123)
        XCTAssertEqual(settings.lyricsOffsetMs % 100, 0)
        control.decrease()
        control.reset()
        XCTAssertEqual(settings.lyricsOffsetMs, 0)
        control.setFraction(0)
        XCTAssertFalse(control.canDecrease)
        XCTAssertEqual(control.readout.first, "-")
    }

    func testTheOffsetSheetRenders() {
        let settings = makeTestSettings()
        settings.lyricsOffsetMs = -1_200
        renderLyricsView(LyricsOffsetSheet(), settings: settings)
    }
}
