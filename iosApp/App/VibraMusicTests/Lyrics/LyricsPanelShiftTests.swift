import VibraMusicCore
import Lyrics
import SwiftUI
import XCTest
@testable import VibraMusic

/// The panel inside Now Playing's column (the player pads it by the gutter, the list bleeds back
/// out to the screen edge): while the playing line hands over, no line moves sideways and nothing
/// clips the words or their glow room at the column's edge.
///
/// Lyrics cut off and shifted slightly to the left (every line missing
/// its first letters at the column's edge) came from the fading-edge mask being applied after the
/// list's negative padding, which sized it to the column instead of the bled width.
@MainActor
final class LyricsPanelShiftTests: XCTestCase {
    func testLinesKeepTheirLeadingEdgeAndAreNotClippedAcrossALineChange() {
        let settings = makeTestSettings()
        let clock = LyricFrameClock()
        clock.reset(positionMs: 12_500, isPlaying: false)
        let translation = LyricsTranslationController()
        let gutter = LyricsPanelMetrics.gutter
        let room = LyricsPanelMetrics.glowRoom
        let lines = LyricsDemo.wordSynced
        // Now Playing's panel block: a header, the panel filling what's left, the deck under it,
        // all in a column padded by the gutter.
        let host = renderLyricsView(
            VStack(spacing: 0) {
                Color.clear.frame(height: 120)
                LyricsPanelContent(lines: lines, subLines: nil, looking: false, trackKey: "t", clock: clock,
                                   isPlaying: false, translation: translation, onSeek: { _ in })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Color.clear.frame(height: 300)
            }
            .padding(.horizontal, gutter),
            settings: settings
        )
        var checked = 0
        func check(_ moment: String) {
            host.view.layoutIfNeeded()
            let voices = host.view.lyricsDescendants(of: LyricLineUIView.self).filter { $0.window != nil }
            for voice in voices where voice.style.room == room {
                let frame = voice.convert(voice.bounds, to: nil)
                let line = lines.first { $0.text == voice.line.text }
                if line?.alignment == .end {
                    // A duet's second voice is written from the far edge.
                    XCTAssertEqual(frame.maxX, 393 - gutter + room, accuracy: 0.5, "\(moment): \(voice.line.text)")
                } else {
                    // The words start on the column's edge; the glow room reaches into the gutter.
                    XCTAssertEqual(frame.minX, gutter - room, accuracy: 0.5, "\(moment): \(voice.line.text)")
                }
                checked += 1
                // Nothing between the line and the window clips it inside the bled width.
                var ancestor = voice.superview
                while let view = ancestor, view !== host.view {
                    let bounds = view.convert(view.bounds, to: nil)
                    if view.clipsToBounds || view.layer.masksToBounds {
                        XCTAssertLessThanOrEqual(bounds.minX, frame.minX + 0.5, "\(moment): clipped by \(type(of: view))")
                    }
                    if let mask = view.layer.mask {
                        let maskFrame = view.layer.convert(mask.frame, to: host.view.layer)
                        XCTAssertLessThanOrEqual(maskFrame.minX, frame.minX + 0.5, "\(moment): masked by \(type(of: view)) at \(maskFrame)")
                        XCTAssertGreaterThanOrEqual(maskFrame.maxX, frame.maxX - 0.5, "\(moment): masked by \(type(of: view)) at \(maskFrame)")
                    }
                    ancestor = view.superview
                }
            }
        }
        check("start")
        // Into "Hold on, hold on to me" and on to the duet line after it.
        for position in [14_900, 15_000, 15_600, 20_200, 23_700] {
            clock.report(positionMs: position, isPlaying: false)
            for step in 0..<8 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.06))
                check("\(position) ms, frame \(step)")
            }
        }
        XCTAssertGreaterThan(checked, 100)
    }

    /// While the lookup is out, the placeholder bars must not run on past
    /// the panel over the scrubber, the transport and the volume row. They stay inside the panel.
    func testTheLoadingPlaceholderStaysInsideThePanel() {
        let settings = makeTestSettings()
        let clock = LyricFrameClock()
        let translation = LyricsTranslationController()
        let panelBottom: CGFloat = 120 + 220
        let host = renderLyricsView(
            VStack(spacing: 0) {
                Color.black.frame(height: 120)
                LyricsPanelContent(lines: [], subLines: nil, looking: true, trackKey: "t", clock: clock,
                                   isPlaying: false, translation: translation, onSeek: { _ in })
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                // Where the player's controls are: see-through, as they are over the backdrop.
                Color.clear
            }
            .padding(.horizontal, LyricsPanelMetrics.gutter)
            .background(Color.black)
            .ignoresSafeArea(),
            settings: settings
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let renderer = UIGraphicsImageRenderer(bounds: host.view.bounds)
        let image = renderer.image { _ in _ = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
        guard let cg = image.cgImage else { return XCTFail("no image") }
        let scale = CGFloat(cg.width) / host.view.bounds.width
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        func brightest(fromY y0: CGFloat, toY y1: CGFloat) -> Int {
            var most = 0
            // A bitmap context's memory holds the drawn image top row first.
            for row in Int(y0 * scale)..<min(Int(y1 * scale), height) {
                for x in stride(from: 0, to: width, by: 2) {
                    let i = (row * width + x) * 4
                    most = max(most, Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
                }
            }
            return most
        }
        XCTAssertGreaterThan(brightest(fromY: 120, toY: panelBottom - 40), 10, "the bars are drawn in the panel")
        XCTAssertLessThanOrEqual(brightest(fromY: panelBottom + 1, toY: 852), 2, "nothing drawn over the controls")
    }

    /// Lyrics must not move left when the line changes. Following the new line, the
    /// list scrolled to it with an anchor at the row's leading edge. `scrollTo` lines the anchor
    /// point of the row up with the same point of the viewport, on both axes; the rows start
    /// inside the list's content padding (the bleed less the glow room, 20 pt), so a leading
    /// anchor asked for a 20 pt sideways scroll too, and every line slid left while one was being
    /// sung. The follow anchor is centred across, which for
    /// a full-width row is no sideways scroll at all, whatever the widths.
    func testFollowingALineScrollsOnlyVertically() {
        let inset = LyricsPanelMetrics.gutter - LyricsPanelMetrics.glowRoom
        for viewport in [CGFloat(393), 430, 620] {
            let anchor = LyricsPanelMetrics.followAnchor
            XCTAssertEqual(Self.sideways(anchor: anchor, rowMinX: inset, rowWidth: viewport - inset * 2, viewport: viewport), 0, accuracy: 0.01)
        }
        // What the leading anchor asked for.
        XCTAssertEqual(Self.sideways(anchor: UnitPoint(x: 0, y: 0.1), rowMinX: inset, rowWidth: 393 - inset * 2, viewport: 393), 20, accuracy: 0.01)
    }

    /// The page must not "breathe". The scroll anchor used to be a fraction of the viewport
    /// applied to the row as well, so a tall row came to rest higher than a short one (about 6 pt
    /// between three lines and one). The followed line rests 30 pt from the panel's top whatever
    /// its height, as on Android.
    func testTheFollowedLineRestsAtTheSameHeightWhateverItsHeight() {
        let clock = LyricFrameClock()
        clock.reset(positionMs: 500, isPlaying: false)
        let lines = lyricsHandoverLines
        let host = hostLyricsPanel(lines: lines, clock: clock, settings: makeTestSettings())
        var heights = Set<Int>()
        // Mid-line, away from the next line's run-up: a one-row line, a wrapping one, and so on.
        for index in 0..<5 {
            let line = lines[index]
            clock.report(positionMs: line.timeMs + 1_000, isPlaying: false)
            // Up to a second for the follow to land, and no longer than it takes: done once the
            // line has stayed at its resting height for three polls.
            var rested = 0
            let deadline = Date().addingTimeInterval(1.0)
            while rested < 3, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                host.view.layoutIfNeeded()
                if let top = host.lyricsVoice(line.text)?.drawnTopInWindow, abs(top - 120 - 30) <= 0.5 { rested += 1 } else { rested = 0 }
            }
            guard let voice = host.lyricsVoice(line.text) else { return XCTFail("\(line.text) is not on screen") }
            heights.insert(Int(voice.bounds.height.rounded()))
            XCTAssertEqual(voice.drawnTopInWindow - 120, 30, accuracy: 0.5, "\(line.text)")
        }
        XCTAssertGreaterThan(heights.count, 1, "the song covers rows of different heights (\(heights))")
    }

    /// How far `scrollTo(_:anchor:)` scrolls sideways to put `anchor` of a row at `anchor` of the viewport.
    private static func sideways(anchor: UnitPoint, rowMinX: CGFloat, rowWidth: CGFloat, viewport: CGFloat) -> CGFloat {
        (rowMinX + anchor.x * rowWidth) - anchor.x * viewport
    }
}
