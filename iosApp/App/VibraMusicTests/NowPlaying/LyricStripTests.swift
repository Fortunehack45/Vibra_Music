import VibraMusicCore
import Lyrics
import SwiftUI
import XCTest
@testable import VibraMusic

/// The one-line lyric over the scrubber (CurrentLyricLine): one line cut with "…", the words'
/// leading edge fixed while lines hand over, the chevron right after the words.
@MainActor
final class LyricStripTests: XCTestCase {
    /// A long line is one row ending in an ellipsis, and the sweep never runs past it.
    func testALongLineIsOneRowCutWithAnEllipsis() {
        let text = "We'll find the shore tonight and every wave will carry us back to where we started"
        let layout = LyricTextLayout(text: text, typeface: .strip, width: 280, maxLines: 1)
        XCTAssertEqual(layout.rows.count, 1)
        let row = layout.rows[0]
        XCTAssertNotNil(row.truncatedFrom, "cut short")
        XCTAssertLessThanOrEqual(row.right, 280.5)
        XCTAssertEqual(layout.size.height, LyricTypeface.strip.lineHeight, accuracy: 1)
        // Past the cut, the sweep waits at the row's end instead of jumping back.
        let length = (text as NSString).length
        XCTAssertEqual(layout.x(ofBoundary: length - 3, row: 0), row.right, accuracy: 0.5)
        var previous: CGFloat = -1
        for revealed in stride(from: Float(0), through: Float(length), by: 1) {
            let edge = layout.sweepEdge(revealed: revealed, row: 0)
            XCTAssertGreaterThanOrEqual(edge, previous - 0.5, "the edge never steps back (\(revealed))")
            previous = edge
        }
        // A short line isn't cut.
        XCTAssertNil(LyricTextLayout(text: "Hold on", typeface: .strip, width: 280, maxLines: 1).rows.first?.truncatedFrom)
    }

    /// The strip's swept voice takes only the width its words need, so the chevron sits after
    /// them; a line too long for the row takes the row.
    func testTheStripVoiceHugsItsWords() {
        let view = LyricLineUIView(frame: .zero)
        let style = LyricVoiceStyle(typeface: .strip, room: 0, rises: false, maxLines: 1, hugs: true)
        view.configure(line: LyricsDemo.wordSynced[5], style: style, rightToLeftLayout: false, dimAlpha: 0.55, glowAlpha: 0, clock: nil, animated: false)
        let short = view.fittingSize(forWidth: 320)
        XCTAssertLessThan(short.width, 320)
        XCTAssertGreaterThan(short.width, 100)
        // Laid out again at exactly that width, it still isn't cut.
        XCTAssertNil(view.textLayout(forWidth: short.width).rows.first?.truncatedFrom)
        XCTAssertEqual(view.textLayout(forWidth: short.width).rows.count, 1)
        let long = LyricsDemo.line(0, [("And", 300), ("every", 300), ("wave", 300), ("will", 300), ("carry", 300), ("us", 300), ("back", 300), ("to", 300), ("the", 300), ("shore", 300)])
        view.configure(line: long, style: style, rightToLeftLayout: false, dimAlpha: 0.55, glowAlpha: 0, clock: nil, animated: false)
        XCTAssertEqual(view.fittingSize(forWidth: 200).width, 200)
    }

    /// Changing line moves nothing sideways: every copy of the words — the one going out and the
    /// one coming in, at every frame of the handover — starts at the row's leading edge.
    func testTheWordsLeadingEdgeStaysPutWhileLinesHandOver() {
        let settings = makeTestSettings()
        let clock = LyricFrameClock()
        clock.reset(positionMs: 16_000, isPlaying: false)
        let lines = LyricsDemo.wordSynced
        let state = StripHarnessState()
        state.index = 5
        let host = renderLyricsView(StripHarness(lines: lines, clock: clock, state: state).padding(.horizontal, 30), settings: settings)
        func voiceEdges() -> [CGFloat] {
            host.view.layoutIfNeeded()
            return host.view.lyricsDescendants(of: LyricLineUIView.self)
                .filter { $0.window != nil }
                .map { $0.convert($0.bounds, to: nil).minX }
        }
        XCTAssertEqual(voiceEdges().count, 1)
        XCTAssertEqual(voiceEdges().first ?? -1, 30, accuracy: 0.5)
        state.index = 6
        var seen = 0
        for _ in 0..<12 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
            for edge in voiceEdges() {
                seen += 1
                XCTAssertEqual(edge, 30, accuracy: 0.5, "a line moved sideways during the handover")
            }
        }
        XCTAssertGreaterThanOrEqual(seen, 12)
        XCTAssertEqual(voiceEdges().count, 1, "the old line is gone once the handover ends")
    }

    /// The status line says who the lyrics are by (LyricsStatusWithChange's status), says nothing
    /// while they are still being looked up, and says so when the lookup found none.
    func testTheStatusLineNamesTheSource() async throws {
        let session = LyricsSession(repository: LyricsDemo.repository())
        XCTAssertEqual(PlayerLyricsStatus.status(session), "", "nothing yet while no lookup has started")
        session.load(LyricsDemo.track, preferences: .default)
        await waitUntil("lookup") { session.isChecked && session.source != nil }
        let source = try XCTUnwrap(session.source)
        XCTAssertEqual(PlayerLyricsStatus.status(session), L10n.lyricsBy(source.label))

        let silent = LyricsRepository(overrides: Dictionary(uniqueKeysWithValues: LyricsSource.allCases.map {
            ($0, LyricsDemo.Provider(lines: nil) as any LyricsProvider)
        }))
        let empty = LyricsSession(repository: silent)
        empty.load(LyricsDemo.track, preferences: .default)
        await waitUntil("every source has answered") { empty.isChecked }
        XCTAssertEqual(PlayerLyricsStatus.status(empty), L10n.noLyricsFound)
    }
}

@MainActor
@Observable
private final class StripHarnessState {
    var index = 0
}

/// The strip's row as SyncedLyricStripLine builds it, driven by a plain index.
private struct StripHarness: View {
    let lines: [LyricLine]
    let clock: LyricFrameClock
    let state: StripHarnessState

    var body: some View {
        let item = LyricStripItem(lines: lines, index: state.index)
        LyricStripRow(instrumental: item.instrumental, onOpen: {}) {
            LyricStripSlot(current: item.key) {
                Group {
                    if let swept = item.swept {
                        LyricVoice(
                            line: swept,
                            style: LyricVoiceStyle(typeface: .strip, room: 0, rises: false, feather: true, maxLines: 1, hugs: true),
                            dimAlpha: 0.55, glowAlpha: 0, clock: clock
                        )
                    } else {
                        Text(item.text)
                    }
                }
                .layoutValue(key: LyricStripSlot.ItemKey.self, value: item.key)
                .id(item.key)
                .transition(LyricStripSlot.handover)
            }
        }
        .animation(LyricStripMetrics.handover(reduceMotion: false), value: item.key)
        .frame(height: 26)
    }
}
