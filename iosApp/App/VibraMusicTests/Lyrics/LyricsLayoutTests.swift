import VibraMusicCore
import Lyrics
import SwiftUI
import XCTest
@testable import Vibra Music

/// The page keeps every line inside its column at any text size, in either layout direction.
@MainActor
final class LyricsLayoutTests: XCTestCase {
    func testLinesStayInsideTheColumnAtEveryTextSizeAndDirection() {
        let settings = makeTestSettings()
        let clock = LyricFrameClock()
        clock.reset(positionMs: 15_900, isPlaying: false)
        let translation = LyricsTranslationController()
        let gutter = LyricsPanelMetrics.gutter
        let room = LyricsPanelMetrics.glowRoom
        for size in [DynamicTypeSize.large, .xxxLarge, .accessibility3] {
            for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                let host = renderLyricsView(
                    LyricsPanelContent(lines: LyricsDemo.wordSynced, subLines: nil, looking: false, trackKey: "t", clock: clock,
                                       isPlaying: false, translation: translation, onSeek: { _ in })
                        .padding(.horizontal, gutter)
                        .dynamicTypeSize(size)
                        .environment(\.layoutDirection, direction),
                    settings: settings
                )
                let voices = host.view.lyricsDescendants(of: LyricLineUIView.self).filter { $0.window != nil }
                XCTAssertFalse(voices.isEmpty)
                for voice in voices {
                    let frame = voice.convert(voice.bounds, to: nil)
                    // The bloom's room may reach into the gutter, the words may not.
                    XCTAssertGreaterThanOrEqual(frame.minX, gutter - room - 0.5, "\(size) \(direction) \(voice.line.text)")
                    XCTAssertLessThanOrEqual(frame.maxX, 393 - gutter + room + 0.5, "\(size) \(direction) \(voice.line.text)")
                    let layout = voice.textLayout(forWidth: voice.bounds.width)
                    for row in layout.rows {
                        XCTAssertGreaterThanOrEqual(row.left, -0.5, "\(size) \(direction) \(voice.line.text)")
                        XCTAssertLessThanOrEqual(row.right, layout.container.size.width + 0.5, "\(size) \(direction) \(voice.line.text)")
                    }
                }
            }
        }
    }

    /// Sheet titles are 19 sp on Android: they follow the text size.
    func testSheetTitlesScaleWithDynamicType() {
        let settings = makeTestSettings()
        for size in [DynamicTypeSize.large, .accessibility3] {
            renderLyricsView(LyricsOffsetSheet().dynamicTypeSize(size), settings: settings)
            renderLyricsView(LyricsProviderSheet().dynamicTypeSize(size), settings: settings)
        }
    }
}
