import VibraMusicCore
import Lyrics
import SwiftUI
import XCTest
@testable import VibraMusic

/// PORTING.md "Synced lyrics": line and word highlighting, duet sides, backing vocals,
/// instrumental gaps, blur on unfocused lines — the panel's state, its clock and its renderer.
@MainActor
final class SyncedLyricsPanelTests: XCTestCase {
    private let lines = LyricsDemo.wordSynced

    /// A known track shows word-by-word highlighting in time with the music. As the
    /// clock moves through a line the sweep's edge moves across it, word by word, and the lit
    /// copy is only redrawn while the clock is inside the line.
    func testAKnownTrackHighlightsWordByWordInTimeWithTheMusic() throws {
        let line = lines[5] // "Hold on, hold on to me", 15.0 s on
        let layout = LyricTextLayout(text: line.text, typeface: .synced, width: 320)
        XCTAssertGreaterThan(layout.rows.count, 1, "34 pt heavy wraps at phone width")

        // Before the line nothing is lit, after it everything is.
        XCTAssertEqual(line.revealedChars(14_900), 0)
        XCTAssertEqual(line.revealedChars(line.endMs + 1), Float((line.text as NSString).length))

        // Each word lights over its own timing: halfway through "Hold" (15.0–15.45 s) is two
        // letters in, and the edge advances monotonically across the first row.
        XCTAssertEqual(line.revealedChars(15_225), 2, accuracy: 0.01)
        var previous: CGFloat = -1
        for position in stride(from: 15_000, through: 16_300, by: 50) {
            let revealed = line.revealedChars(position)
            guard let row = layout.rows.firstIndex(where: { Float($0.characters.upperBound) >= revealed }), row == 0 else { continue }
            let edge = layout.sweepEdge(revealed: revealed, row: 0)
            XCTAssertGreaterThanOrEqual(edge, previous, "the highlight never steps backwards (\(position) ms)")
            previous = edge
        }
        // "on," starts the moment "Hold" ends, so the edge is already past the space.
        XCTAssertEqual(line.revealedChars(15_450), 5)
        XCTAssertEqual(layout.sweepEdge(revealed: 5, row: 0), layout.x(ofBoundary: 5, row: 0), accuracy: 0.5)
        XCTAssertGreaterThan(layout.x(ofBoundary: 5, row: 0), layout.x(ofBoundary: 4, row: 0), "\"Hold\" is fully lit as it ends")

        // The renderer follows the frame clock.
        let clock = LyricFrameClock()
        clock.now = { 100 }
        clock.reset(positionMs: 15_225, isPlaying: false)
        let view = LyricLineUIView(frame: CGRect(x: 0, y: 0, width: 340, height: 200))
        view.configure(line: line, style: LyricVoiceStyle(typeface: .synced, room: 10, feather: true), rightToLeftLayout: false,
                       dimAlpha: LyricRowStyle.unsungAlpha, glowAlpha: 0.62, clock: clock, animated: false)
        view.layoutIfNeeded()
        XCTAssertEqual(view.fittingSize(forWidth: 340).height, layout.size.height + 20, accuracy: 2)
        let renderer = UIGraphicsImageRenderer(size: view.bounds.size)
        let image = renderer.image { view.layer.render(in: $0.cgContext) }
        XCTAssertGreaterThan(image.size.width, 0)
    }

    func testThePlayingRowIsTrackedAndThePageLeadsItByTheRunUp() {
        let model = LyricsPanelModel()
        model.setLines(lines)
        XCTAssertTrue(model.isSynced)

        model.update(positionMs: 2_500)
        XCTAssertEqual(model.activeRows, [1])
        XCTAssertEqual(model.scrollLine, 1)
        XCTAssertTrue(model.isActive(1))
        XCTAssertEqual(model.offset(of: 4), 3)

        // 350–500 ms before the next line lands, the page is already heading for it while the
        // brightness stays on the line still being sung.
        model.update(positionMs: 4_500)
        XCTAssertEqual(model.scrollLine, 1)
        XCTAssertEqual(model.leadLine, 2)
        XCTAssertEqual(model.focusLine, 2)

        // The answering vocal keeps its line active past the lead's own last word.
        model.update(positionMs: 8_200)
        XCTAssertEqual(model.activeRows, [2, 3], "the line with a backing vocal is still sung as the gap opens")
    }

    func testInstrumentalBreaksDuetSidesAndBackingVocals() {
        let model = LyricsPanelModel()
        model.setLines(lines)
        XCTAssertTrue(model.isDuet, "a song naming a second voice is laid out in two lanes")
        model.update(positionMs: 10_000)
        XCTAssertEqual(model.scrollLine, 3)
        XCTAssertTrue(lines[3].isGap, "the break is the playing row")

        let backing = try! XCTUnwrap(lines[2].background).withoutBracketPunctuation()
        XCTAssertEqual(backing.text, "calling me home")
        XCTAssertEqual(backing.words.map(\.text), ["calling", "me", "home"], "the sweep still finds each word")

        let single = LyricsPanelModel()
        single.setLines(LyricsDemo.japanese)
        XCTAssertFalse(single.isDuet)
        let plain = LyricsPanelModel()
        plain.setLines(LyricsDemo.plain)
        XCTAssertFalse(plain.isSynced)
        plain.update(positionMs: 5_000)
        XCTAssertEqual(plain.activeRows, [], "plain lyrics don't follow the song")
    }

    func testUnfocusedLinesFallAwayAndBlurUnlessBrowsingOrSwitchedOff() {
        XCTAssertEqual(LyricRowStyle.alpha(synced: true, active: true, browsing: false, distance: 0), 1)
        XCTAssertEqual(LyricRowStyle.alpha(synced: true, active: false, browsing: false, distance: 1), 0.8)
        XCTAssertEqual(LyricRowStyle.alpha(synced: true, active: false, browsing: false, distance: -9), 0.46)
        XCTAssertEqual(LyricRowStyle.alpha(synced: true, active: false, browsing: true, distance: 3), 0.8, "reading by hand flattens the stack")
        XCTAssertEqual(LyricRowStyle.alpha(synced: false, active: false, browsing: false, distance: 3), 0.95)

        XCTAssertEqual(LyricRowStyle.blur(synced: true, active: false, browsing: false, distance: 4, blurEnabled: true), 2.4)
        XCTAssertEqual(LyricRowStyle.blur(synced: true, active: true, browsing: false, distance: 0, blurEnabled: true), 0)
        XCTAssertEqual(LyricRowStyle.blur(synced: true, active: false, browsing: true, distance: 4, blurEnabled: true), 0)
        XCTAssertEqual(LyricRowStyle.blur(synced: true, active: false, browsing: false, distance: 4, blurEnabled: false), 0)

        XCTAssertEqual(LyricRowStyle.scale(pressed: true, active: true), 0.96)
        XCTAssertEqual(LyricRowStyle.scale(pressed: false, active: false), 0.98)
        XCTAssertEqual(LyricRowStyle.tailAlpha(sung: false), 0.45)
        XCTAssertEqual(LyricRowStyle.litAlpha(synced: true, sung: false, active: false), 0.45)
        XCTAssertEqual(LyricRowStyle.litAlpha(synced: false, sung: false, active: false), 1)
    }

    func testTheClockCarriesAReportForwardAndJumpsOnASeek() {
        var now: CFTimeInterval = 10
        let clock = LyricFrameClock()
        clock.now = { now }
        clock.isRunnable = false
        clock.reset(positionMs: 1_000, isPlaying: true)
        now += 0.2
        clock.advance()
        XCTAssertEqual(clock.positionMs, 1_200, "a frame carries the last report forward")
        // A late report slightly behind the display is a delivery delay, not a seek: held.
        clock.report(positionMs: 1_150, isPlaying: true)
        XCTAssertEqual(clock.positionMs, 1_200)
        // A real seek jumps at once.
        now += 0.05
        clock.report(positionMs: 40_000, isPlaying: true)
        XCTAssertEqual(clock.positionMs, 40_000)
        // Pausing settles on the report.
        clock.report(positionMs: 39_900, isPlaying: false)
        XCTAssertEqual(clock.positionMs, 39_900)
        XCTAssertFalse(clock.isTicking)
    }

    func testThePanelRendersEveryState() {
        let settings = makeTestSettings()
        let clock = LyricFrameClock()
        clock.reset(positionMs: 15_900, isPlaying: false)
        let translation = LyricsTranslationController()
        for (lines, looking) in [(LyricsDemo.wordSynced, false), (LyricsDemo.plain, false), ([], true), ([], false)] {
            let host = renderLyricsView(
                LyricsPanelContent(lines: lines, subLines: nil, looking: looking, trackKey: "t", clock: clock, isPlaying: false, translation: translation, onSeek: { _ in }),
                settings: settings
            )
            XCTAssertNotNil(host.view)
            if lines == LyricsDemo.wordSynced {
                XCTAssertFalse(host.view.lyricsDescendants(of: LyricLineUIView.self).isEmpty, "lines are drawn by the lyric renderer")
            }
        }
        // The entry view on its own: no player, no session injected.
        renderLyricsView(LyricsPanel(), settings: settings)
    }

    // MARK: The line's own crossfades

    /// Hosts a `LyricLineUIView` in a key window, the way the panel does, so Core Animation
    /// actually renders its fades and the presentation layers sample right.
    private func hostedLineView() -> LyricLineUIView {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let view = LyricLineUIView(frame: CGRect(x: 0, y: 0, width: 340, height: 90))
        window.addSubview(view)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        return view
    }

    /// A line-synced line's brightness (the "lit" state carried by the dim copy,
    /// Android's default spring) crossfades instead of popping. The inert fade this replaces —
    /// a Core Animation action with no start or end — lands the new brightness in one frame,
    /// which is the sharp step a listener sees when a line starts.
    func testALineSyncedLinesBrightnessCrossfadesInsteadOfPopping() async throws {
        let view = hostedLineView()
        let style = LyricVoiceStyle(typeface: .plain, room: 0, sweeps: false, rises: false)
        let line = LyricsDemo.japanese[2] // 遠い波の音が窓をたたく朝, line-synced
        view.configure(line: line, style: style, rightToLeftLayout: false,
                       dimAlpha: LyricRowStyle.unsungAlpha, glowAlpha: 0, clock: nil, animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(view.layer.sublayers?.count ?? 0, 4, "the dim, bloom, lit and particle copies")
        let dim = view.layer.sublayers![0] as CALayer
        let glow = view.layer.sublayers![1] as CALayer
        XCTAssertEqual(dim.opacity, Float(LyricRowStyle.unsungAlpha), accuracy: .ulpOfOne, "the unsung line starts dim")

        // The line starts: its brightness rises on the spring, not in one frame.
        view.configure(line: line, style: style, rightToLeftLayout: false,
                       dimAlpha: 1, glowAlpha: 0, clock: nil, animated: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let mid = dim.presentation()?.opacity ?? 1
        XCTAssertGreaterThan(mid, 0.46, "still rising from the unsung tail (\(mid))")
        XCTAssertLessThan(mid, 0.99, "not there yet at 50 ms (\(mid))")
        await waitUntil("the fade settles") { dim.presentation()?.opacity ?? 1 >= 0.999 }
        XCTAssertEqual(dim.opacity, 1 as Float)

        // The bloom crossfades the same way (a held note's glow): held at 1.0 first, then
        // fifty ms into its 420 ms fade down to 0.62 it is already partway down — mid-fade,
        // not the 0.62 an inert action would land in the first frame.
        view.configure(line: LyricsDemo.wordSynced[5], style: style, rightToLeftLayout: false,
                       dimAlpha: 1, glowAlpha: 1, clock: nil, animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(glow.opacity, 1, "the bloom starts held at full")
        view.configure(line: LyricsDemo.wordSynced[5], style: style, rightToLeftLayout: false,
                       dimAlpha: 1, glowAlpha: LyricRowStyle.glowAlpha, clock: nil, animated: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let glowMid = glow.presentation()?.opacity ?? 0.62
        XCTAssertGreaterThanOrEqual(glowMid, 0.62, "the bloom is on its way down, not stepped (\(glowMid))")
        XCTAssertLessThan(glowMid, 0.999, "and not landed yet (\(glowMid))")
        await waitUntil("the bloom fades down to its rest strength") { glow.presentation()?.opacity ?? 1 <= 0.621 }
        XCTAssertEqual(glow.opacity, Float(LyricRowStyle.glowAlpha))
    }

    /// With the fade off (Reduce Motion, or a layout pass), the brightness lands at once.
    func testABrightnessChangeWithoutAnimationLandsAtOnce() {
        let view = hostedLineView()
        let style = LyricVoiceStyle(typeface: .plain, room: 0, sweeps: false, rises: false)
        view.configure(line: LyricsDemo.japanese[2], style: style, rightToLeftLayout: false,
                       dimAlpha: LyricRowStyle.unsungAlpha, glowAlpha: 0, clock: nil, animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        view.configure(line: LyricsDemo.japanese[2], style: style, rightToLeftLayout: false,
                       dimAlpha: 1, glowAlpha: 0, clock: nil, animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        let dim = view.layer.sublayers![0] as CALayer
        XCTAssertEqual(dim.presentation()?.opacity ?? 0, 1, accuracy: 0.001, "no fade when animated is false")
    }

    // MARK: The sweep's edge

    /// No line shows through the letter being sung. The soft edge's erase stopped
    /// exactly at the edge, where the lit copy's clip stops too, so the pixel the edge cuts kept
    /// part of the lit copy and shone as a thin bright line inside the dimmer letter. Across a held
    /// word, at many sub-pixel phases of the edge, how lit the letters are only ever falls through
    /// the soft edge, never rises again.
    func testNoLineShowsThroughTheLetterBeingSung() throws {
        // The second "on" is held from 16.35 s to 18.75 s.
        let line = try XCTUnwrap(lines.first { $0.text == "Hold on, hold on to me" })
        let (view, clock) = sweepView()
        var seams: [String] = []
        var checked = 0
        // Fully lit pixels actually read, so a lit copy that drew nothing can't pass.
        var litPixels = 0
        for position in stride(from: 16_400, to: 18_700, by: 97) {
            let frame = sweepFrame(view, line, clock, at: position)
            let layout = view.textLayout(forWidth: view.bounds.width)
            let revealed = line.revealedChars(position)
            // The row the renderer softens: none while the edge sits on a wrap.
            guard let index = layout.rows.firstIndex(where: { Float($0.characters.upperBound) > revealed && Float($0.characters.lowerBound) < revealed }) else { continue }
            let row = layout.rows[index]
            let room = LyricsPanelMetrics.glowRoom
            let edge = layout.sweepEdge(revealed: revealed, row: index) + room
            checked += 1
            for y in Int((row.top + room - 6) * frame.scale)..<Int((row.bottom + room) * frame.scale) {
                var last: Double?
                for x in Int((edge - 40) * frame.scale)..<Int((edge + 4) * frame.scale) {
                    guard let lit = frame.fraction(x, y) else { last = nil; continue }
                    if lit > 0.9 { litPixels += 1 }
                    if let last, lit > last + 0.06, lit > 0.08 {
                        seams.append("\(position) ms: \(Int(lit * 100))% lit after \(Int(last * 100))% at x \(x), y \(y)")
                        break
                    }
                    last = lit
                }
            }
        }
        XCTAssertGreaterThan(checked, 10, "the edge is measured through the held word")
        XCTAssertGreaterThan(litPixels, 100, "the lit copy is drawn and read")
        XCTAssertEqual(seams.count, 0, "the lit copy brightens again at the edge: \(seams.prefix(4))")
    }

    /// As the sweep reaches the end of a row, the row's last letter is lit by the sweep
    /// itself. The soft edge kept the last letter of each row partly dark until the row was done,
    /// then it came on in one frame, as the line handed over (Android draws the same pop). The
    /// edge now narrows over a row's last stretch.
    func testTheSweepLightsARowsLastLetterBeforeItMovesOn() throws {
        // It wraps: a row's end inside the line, and the line's own.
        let line = try XCTUnwrap(lines.first { $0.text == "Like a lighthouse in the dark" })
        let (view, clock) = sweepView()
        let room = LyricsPanelMetrics.glowRoom
        _ = sweepFrame(view, line, clock, at: line.timeMs)
        let layout = view.textLayout(forWidth: view.bounds.width)
        XCTAssertGreaterThan(layout.rows.count, 1)
        for (index, row) in layout.rows.enumerated() {
            guard !row.characters.isEmpty else {
                XCTFail("row \(index) holds only whitespace")
                continue
            }
            // A frame before the word that ends the row is done.
            // Found from the layout, not assumed: which word ends a row depends on the width.
            guard let word = line.wordSpans.firstIndex(where: { $0.upperBound == row.characters.upperBound }), line.words.indices.contains(word) else {
                XCTFail("row \(index) ends inside a word")
                continue
            }
            let position = line.words[word].endMs - 1
            let frame = sweepFrame(view, line, clock, at: position)
            let letter = layout.box(ofCharacter: row.characters.upperBound - 1).offsetBy(dx: room, dy: room)
            let edge = layout.sweepEdge(revealed: line.revealedChars(position), row: index) + room
            guard edge - 1 > letter.minX else {
                XCTFail("row \(index), \(position) ms: the sweep's edge (\(edge)) is not on the row's last letter (\(letter))")
                continue
            }
            var lit: [Double] = []
            for y in Int((letter.minY - 3) * frame.scale)..<Int(letter.maxY * frame.scale) {
                for x in Int(letter.minX * frame.scale)..<Int((edge - 1) * frame.scale) {
                    if let fraction = frame.fraction(x, y) { lit.append(fraction) }
                }
            }
            XCTAssertGreaterThan(lit.count, 50, "row \(index): the letter is measured")
            let mean = lit.reduce(0, +) / Double(max(lit.count, 1))
            XCTAssertGreaterThan(mean, 0.9, "row \(index), \(position) ms: its last letter is lit as the sweep reaches it (\(Int(mean * 100))%)")
        }
    }

    /// The strip over the scrubber cuts a long line at an ellipsis, and its sweep waits there while
    /// the hidden words are sung. That wait keeps its soft edge: only a row's real end narrows it.
    func testARowCutForAnEllipsisKeepsItsSoftEdge() throws {
        let line = try XCTUnwrap(lines.first { $0.text == "Like a lighthouse in the dark" })
        let strip = LyricVoiceStyle(typeface: .strip, room: 0, sweeps: true, rises: false, feather: true, maxLines: 1)
        let (view, clock) = sweepView(width: 140, height: 40)
        let position = 4_200 // "dark", past the ellipsis
        let frame = sweepFrame(view, line, clock, at: position, style: strip)
        let layout = view.textLayout(forWidth: view.bounds.width)
        guard let row = layout.rows.first, row.truncatedFrom != nil else { return XCTFail("the line is cut for an ellipsis at 140 pt (\(layout.rows))") }
        let edge = layout.sweepEdge(revealed: line.revealedChars(position), row: 0)
        XCTAssertEqual(edge, row.right, accuracy: 0.5, "the sweep waits at the ellipsis")
        var lit: [Double] = []
        for y in Int(row.top * frame.scale)..<Int(row.bottom * frame.scale) {
            for x in Int((edge - 12) * frame.scale)..<Int((edge - 1) * frame.scale) {
                if let fraction = frame.fraction(x, y) { lit.append(fraction) }
            }
        }
        XCTAssertGreaterThan(lit.count, 10, "the end of the row is measured")
        let mean = lit.reduce(0, +) / Double(max(lit.count, 1))
        XCTAssertLessThan(mean, 0.8, "the last points before the ellipsis are still soft (\(Int(mean * 100))% lit)")
    }

    /// A line view drawn the way the panel draws the line being sung, on black in a window.
    private func sweepView(width: CGFloat = 340, height: CGFloat = 130) -> (LyricLineUIView, LyricFrameClock) {
        let view = hostedLineView()
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        view.backgroundColor = .black
        return (view, LyricFrameClock())
    }

    /// One frame of the sweep at the screen's scale, drawn twice from the same layout: the lit
    /// copy alone, and every letter at full brightness (the dim copy at 1 under it).
    private struct SweepFrame {
        let scale: CGFloat
        let width: Int
        let lit: [UInt8]
        let whole: [UInt8]

        /// How lit the letters are at device pixel (x, y), 0…1; nil off the letters and on their
        /// anti-aliased rims, where two part-covered copies don't add up to one.
        func fraction(_ x: Int, _ y: Int) -> Double? {
            let index = y * width + x
            guard x >= 0, x < width, y >= 0, index < whole.count, index < lit.count, whole[index] == 255 else { return nil }
            return Double(lit[index]) / Double(whole[index])
        }
    }

    private func sweepFrame(_ view: LyricLineUIView, _ line: LyricLine, _ clock: LyricFrameClock, at positionMs: Int,
                            style: LyricVoiceStyle = LyricVoiceStyle(typeface: .synced, room: LyricsPanelMetrics.glowRoom, feather: true)) -> SweepFrame {
        clock.reset(positionMs: positionMs, isPlaying: false)
        func render(dim: Double) -> (width: Int, values: [UInt8]) {
            view.configure(line: line, style: style, rightToLeftLayout: false, dimAlpha: dim, glowAlpha: 0, clock: clock, animated: false)
            view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) }
            // A frame with nothing in it would let a test pass without reading a pixel.
            guard let cg = image.cgImage, cg.width > 0, cg.height > 0 else {
                XCTFail("\(positionMs) ms: the renderer gave no image")
                return (0, [])
            }
            var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            let context = CGContext(data: &pixels, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return (cg.width, stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] })
        }
        let lit = render(dim: 0)
        let whole = render(dim: 1)
        return SweepFrame(scale: CGFloat(lit.width) / view.bounds.width, width: lit.width, lit: lit.values, whole: whole.values)
    }

    /// The glow layer draws through UIKit's current context, which a layer's drawer has none of
    /// until it pushes one: nothing showed on an iPhone, and on a Mac the font read the
    /// missing context and the app stopped. Drawn into a bare bitmap, as Core Animation does.
    func testTheGlowUnderAGrowingWordDrawsIntoItsLayersContext() throws {
        let view = hostedLineView()
        let clock = LyricFrameClock()
        clock.reset(positionMs: 1_000, isPlaying: false)
        let line = LyricLine(timeMs: 0, text: "golden", words: [LyricWord(startMs: 0, endMs: 2_000, text: "golden")])
        XCTAssertTrue(line.isGrowing(1_000), "the fixture holds a word long enough to swell")
        view.configure(line: line, style: LyricVoiceStyle(typeface: .synced, room: LyricsPanelMetrics.glowRoom), rightToLeftLayout: false,
                       dimAlpha: 1, glowAlpha: 1, clock: clock, animated: false)
        view.layoutIfNeeded()
        // The layers are added dim, glow, lit, particles.
        let glow = try XCTUnwrap(view.layer.sublayers?.compactMap { $0 as? LyricDrawingLayer }[1])
        let (width, height) = (Int(view.bounds.width * 2), Int(view.bounds.height * 2))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: 2, y: 2)
        glow.draw(in: context)
        XCTAssertTrue(stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 0 }, "the glow drew no pixels")
    }

    // MARK: Handover motion (Android: PlayerLyrics.kt, the follow effect and ScrollRun)

    /// The motion settings: the page never snaps to a line it can travel to. The
    /// first line of a track is placed at once; the in-app toggle changes nothing about the follow
    /// (Android's Reduce animation gates only the glow and the sub-lyric reveal); iOS's Reduce
    /// Motion swaps the travel for a short ease (Apple: replace the motion, don't remove it).
    func testThePageFollowsALineByTheRightMotionForEachSetting() {
        // A track's first placement jumps, whatever the settings.
        XCTAssertEqual(LyricMotion.follow(placed: false, systemReduceMotion: false, rowOnScreen: false, leadMs: 500), .jump)
        XCTAssertEqual(LyricMotion.follow(placed: false, systemReduceMotion: true, rowOnScreen: true, leadMs: 500), .jump)
        // Otherwise: the run-up's own duration when the row is on screen, the staged scroll when not.
        XCTAssertEqual(LyricMotion.follow(placed: true, systemReduceMotion: false, rowOnScreen: true, leadMs: 420), .glide(milliseconds: 420))
        XCTAssertEqual(LyricMotion.follow(placed: true, systemReduceMotion: false, rowOnScreen: false, leadMs: 420), .staged)
        // Reduce Motion: a short ease, on screen or not, and never a snap.
        for onScreen in [true, false] {
            let motion = LyricMotion.follow(placed: true, systemReduceMotion: true, rowOnScreen: onScreen, leadMs: 500)
            XCTAssertEqual(motion, .shortEase)
            XCTAssertNotNil(motion.animation, "an ease to the line, not a jump")
        }
        XCTAssertNil(LyricFollow.jump.animation)
    }

    /// The fan-out schedule against Android's own formula (PlayerLyrics.kt:359-366, 1804-1868):
    /// `delay = clamp(behind, 0, 3) * 0.06 * D`, span `D * 1.18`, and a row's offset
    /// `delta * (ease(e / D) - ease((e - delay) / D))` on cubic-bezier(0.41, 0, 0.12, 0.99).
    /// Expected values are that formula worked by hand with an independent bezier solve, not read
    /// back from the helper.
    func testTheRowsFanOutOnAndroidsSchedule() {
        let d = 500
        XCTAssertEqual([1, 2, 3, 4, 0, -2].map { LyricHandover.delayMs(behind: $0, durationMs: d) }, [30, 60, 90, 90, 0, 0])
        XCTAssertEqual(LyricHandover.delayMs(behind: 3, durationMs: 350), 63, accuracy: 0.001)
        XCTAssertEqual(LyricHandover.spanMs(durationMs: d), 590, accuracy: 0.001)
        XCTAssertEqual(LyricHandover.spanMs(durationMs: 350), 413, accuracy: 0.001)

        // Which rows trail: those after the focus row on a forward move, those before it on a back move.
        XCTAssertEqual(LyricHandover.behind(index: 5, focus: 3, delta: 61), 2)
        XCTAssertEqual(LyricHandover.behind(index: 2, focus: 3, delta: 61), -1)
        XCTAssertEqual(LyricHandover.behind(index: 1, focus: 3, delta: -61), 2)
        XCTAssertEqual(LyricHandover.behind(index: 4, focus: 3, delta: -61), -1)

        // Nothing at the start, nothing once the span is over, and the hand-worked points between.
        func shift(_ delta: CGFloat, _ elapsed: Double, _ delay: Double) -> CGFloat {
            LyricHandover.shift(delta: delta, elapsedMs: elapsed, durationMs: d, delayMs: delay)
        }
        XCTAssertEqual(shift(61, 0, 90), 0, accuracy: 0.001)
        XCTAssertEqual(shift(61, 590, 90), 0, accuracy: 0.001)
        XCTAssertEqual(shift(61, 900, 90), 0, accuracy: 0.001)
        for (elapsed, expected) in [(100.0, 8.713), (200, 29.442), (300, 11.546), (400, 4.337), (500, 1.107)] {
            XCTAssertEqual(shift(61, elapsed, 90), CGFloat(expected), accuracy: 0.05, "behind 3 at \(elapsed) ms")
        }
        XCTAssertEqual(shift(61, 100, 30), 5.314, accuracy: 0.05)
        XCTAssertEqual(shift(61, 200, 30), 7.952, accuracy: 0.05)
        XCTAssertEqual(shift(-61, 100, 90), -8.713, accuracy: 0.05, "a back move trails the other way")
        XCTAssertEqual(shift(61, 200, 0), 0, "a row with no delay moves with the list")

        // Never negative, and the peak trail of a 61 pt move.
        func peak(_ delta: CGFloat, behind: Int) -> CGFloat {
            let delay = LyricHandover.delayMs(behind: behind, durationMs: d)
            let trail = stride(from: 0.0, through: 590, by: 1).map { shift(delta, $0, delay) }
            XCTAssertGreaterThanOrEqual(trail.min() ?? 0, 0)
            return trail.max() ?? 0
        }
        XCTAssertEqual(peak(61, behind: 3), 29.8, accuracy: 0.5)
        XCTAssertEqual(peak(61, behind: 2), 21.5, accuracy: 0.5)
        XCTAssertEqual(peak(61, behind: 1), 11.4, accuracy: 0.5)
        XCTAssertEqual(peak(143, behind: 3), 69.8, accuracy: 0.5)
    }

    /// With the in-app Reduce animation toggle on, a line change still travels: the new line's row
    /// is seen part way to its place in frames between the two, not in one jump (it used to snap).
    func testALineChangeStillGlidesWithTheInAppAnimationToggleOn() {
        let settings = makeTestSettings()
        settings.reduceAnimation = true
        let clock = LyricFrameClock()
        clock.reset(positionMs: 4_000, isPlaying: false)
        let host = hostLyricsPanel(lines: lyricsHandoverLines, clock: clock, settings: settings)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let next = lyricsHandoverLines[2].text
        guard let before = host.lyricsVoice(next)?.drawnTopInWindow else { return XCTFail("the next row is not on screen") }

        clock.report(positionMs: 5_700, isPlaying: false)
        let frames = host.recordLyricsTops(of: [next], seconds: 0.9).map { $0[0] }
        let after = frames.last ?? before
        XCTAssertGreaterThan(before - after, 40, "the page moved to the new line (\(before) to \(after))")
        let between = frames.filter { $0 < before - 3 && $0 > after + 3 }
        XCTAssertGreaterThan(between.count, 2, "seen part way along, not jumped (\(between.count) frames between)")
    }

    /// The rows after the new line set off later than the list does and catch up, one a little
    /// behind the next (30, 60, 90 ms at a 500 ms change), so the page opens and closes like
    /// Android's rather than moving as one block. Seen as each row's distance from the new line
    /// opening past where it rests, then closing again.
    func testRowsBelowTheNewLineTrailTheScrollThenCatchUp() throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "system Reduce Motion is on in this simulator: the fan-out is switched off with it")
        let clock = LyricFrameClock()
        clock.reset(positionMs: 10_000, isPlaying: false)
        let host = hostLyricsPanel(lines: lyricsHandoverLines, clock: clock, settings: makeTestSettings())
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        // Row 3 (several rows tall) hands over to row 4; rows 5, 6, 7 are one, two and three behind.
        let texts = [4, 5, 6, 7].map { lyricsHandoverLines[$0].text }
        let initial = host.recordLyricsTops(of: texts, seconds: 0.03).first
        guard let initial else { return XCTFail("rows 4 to 7 are not on screen") }

        clock.report(positionMs: 11_700, isPlaying: false)
        let frames = host.recordLyricsTops(of: texts, seconds: 1.0)
        guard let last = frames.last else { return XCTFail("no frames") }
        // How far below its place, next to the new line, each trailing row is at its worst.
        let trails = (1...3).map { row in frames.map { ($0[row] - $0[0]) - (last[row] - last[0]) }.max() ?? 0 }
        // Sampled peaks, so the margins are loose: a loaded simulator samples less often and can miss
        // the top of a ~11 pt trail. Without the fan-out every trail is 0.
        XCTAssertGreaterThan(trails[0], 3, "one row behind trails the page (\(trails))")
        XCTAssertGreaterThan(trails[1], trails[0], "two behind trails further (\(trails))")
        XCTAssertGreaterThan(trails[2], trails[1], "three behind trails furthest (\(trails))")
        // And they all arrive: the spacing is what it was before the change.
        for row in 1...3 {
            XCTAssertEqual(last[row] - last[0], initial[row] - initial[0], accuracy: 1.5, "row \(row + 4) catches up")
        }
    }

    /// A line that lands while the page is still moving to the last one comes to rest at
    /// the follow top. An animated scrollTo issued mid-move used to be lost, leaving the sung line a
    /// row low in about half the runs, so the handover is repeated.
    func testALineLandingMidMoveStillComesToRestAtTheFollowTop() throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "system Reduce Motion is on in this simulator: the first move is as short as the wait, so nothing lands mid-move")
        let next = lyricsHandoverLines[5].text
        var rests: [CGFloat] = []
        for _ in 0..<6 {
            let clock = LyricFrameClock()
            clock.reset(positionMs: 10_000, isPlaying: false)
            let host = hostLyricsPanel(lines: lyricsHandoverLines, clock: clock, settings: makeTestSettings())
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            clock.report(positionMs: 11_700, isPlaying: false)      // row 4's run-up: the page sets off
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            clock.report(positionMs: 14_600, isPlaying: false)      // row 5's, 200 ms into that move
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
            rests.append((host.lyricsVoice(next)?.drawnTopInWindow ?? 0) - 120)
            host.view.window?.isHidden = true
        }
        XCTAssertTrue(rests.allSatisfy { abs($0 - 30) <= 1.5 },
                      "the new line rests 30 pt below the panel's top every time: \(rests.map { Int($0) })")
    }

    /// Through an instrumental break, the rows below the three dots travel with the page
    /// as the dots open and close, and the line after the break comes to rest at the follow top like
    /// any other line. The row used to change height on its own clock: the rows below jumped 56 pt
    /// in one frame each way, and the line after the break, already at the top, was pulled up past
    /// it and left there.
    func testABreakOpensAndClosesWithThePageAndTheLineAfterItRestsAtTheFollowTop() {
        let lines: [LyricLine] = [
            LyricsDemo.line(1_000, [("One", 300), ("line", 300), ("before", 400)]),
            LyricsDemo.line(2_400, [("Then", 300), ("the", 300), ("break", 600)]),
            LyricLine(timeMs: 3_600, text: ""),
            LyricsDemo.line(7_600, [("Back", 300), ("again", 500), ("now", 500)]),
            LyricsDemo.line(9_300, [("And", 300), ("on", 300), ("we", 300), ("go", 500)]),
            LyricsDemo.line(11_000, [("Still", 300), ("more", 300), ("words", 500)]),
        ]
        let clock = LyricFrameClock()
        clock.reset(positionMs: 2_700, isPlaying: false)
        let host = hostLyricsPanel(lines: lines, clock: clock, settings: makeTestSettings())
        host.view.backgroundColor = .black // white words, for the snapshots
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let after = "Back again now"
        let below = [after, "And on we go"]
        var jumps: [String] = []
        // Plays from `from` to `to`, noting a row below the break that moves faster than the
        // page's glide. The limit is per elapsed time, not per runner frame, so a loaded runner
        // does not turn one sparse sample into a false jump.
        func play(from: Int, to: Int) {
            clock.reset(positionMs: from, isPlaying: true)
            var last: (tops: [CGFloat], at: Date)?
            while clock.positionMs < to {
                RunLoop.main.run(until: Date().addingTimeInterval(0.008))
                // A row's layer seen before its first commit reads as the window's origin: skipped.
                let tops = below.compactMap { host.lyricsVoice($0)?.drawnTopInWindow }.filter { abs($0) > 0.5 }
                let now = Date()
                guard tops.count == below.count else { last = nil; continue }
                if let last {
                    let maximumTravel = CGFloat(1_400 * now.timeIntervalSince(last.at) + 8)
                    for ((text, was), top) in zip(zip(below, last.tops), tops) where abs(top - was) > maximumTravel {
                        jumps.append("\(text) \(Int(was - 120)) to \(Int(top - 120)) at \(clock.positionMs) ms")
                    }
                }
                last = (tops, now)
            }
        }
        play(from: 2_900, to: 4_200)    // the page moves onto the break and the dots open
        uiSnapshot(host, "lyrics-break-open")
        play(from: 6_900, to: 8_300)    // and off it, onto the line after it
        clock.report(positionMs: 8_300, isPlaying: false)
        XCTAssertEqual(jumps, [], "the rows below the dots moved with the page, not in one frame")

        var rested = 0
        let deadline = Date().addingTimeInterval(1.0)
        while rested < 3, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if let top = host.lyricsVoice(after)?.drawnTopInWindow, abs(top - 120 - 30) <= 1 { rested += 1 } else { rested = 0 }
        }
        uiSnapshot(host, "lyrics-after-break")
        guard let voice = host.lyricsVoice(after) else { return XCTFail("the line after the break is not on screen") }
        let top = voice.drawnTopInWindow - 120
        XCTAssertEqual(top, 30, accuracy: 1, "the line after the break rests 30 pt below the panel's top")
    }

    /// The gap opens on the first placement before playback reaches its stamp. It
    /// must already be exposed to VoiceOver during that run-up.
    func testAnInstrumentalRunUpIsAccessibleOnFirstPlacement() async {
        let lines: [LyricLine] = [
            LyricsDemo.line(1_000, [("Before", 500), ("the", 300), ("break", 400)]),
            LyricLine(timeMs: 3_600, text: ""),
            LyricsDemo.line(7_600, [("After", 500), ("the", 300), ("break", 400)]),
        ]
        await enableAccessibilityTree()     // SwiftUI builds the labels VoiceOver reads only while this is on
        let clock = LyricFrameClock()
        // The gap's 350 ms run-up has started, but its own stamp is still ahead.
        clock.reset(positionMs: 3_300, isPlaying: false)
        let host = hostLyricsPanel(lines: lines, clock: clock, settings: makeTestSettings())
        let labels = await renderedLabelsSettling(host)

        XCTAssertTrue(labels.contains(L10n.instrumental),
                      "the open gap is available before its first silent beat")
    }

    /// A line followed late catches up in the time left to its stamp, between the Reduce
    /// Motion ease and the run-up, instead of taking a whole run-up after the wait.
    func testALateFollowCatchesUpInTheTimeLeft() {
        XCTAssertEqual(LyricMotion.catchUpMs(lineStartMs: 15_000, positionMs: 14_600, runUpMs: 500), 400)
        XCTAssertEqual(LyricMotion.catchUpMs(lineStartMs: 15_000, positionMs: 14_950, runUpMs: 500), 200, "never a snap")
        XCTAssertEqual(LyricMotion.catchUpMs(lineStartMs: 15_000, positionMs: 15_300, runUpMs: 500), 200, "already sung: the short ease")
        XCTAssertEqual(LyricMotion.catchUpMs(lineStartMs: 15_000, positionMs: 14_000, runUpMs: 450), 450, "never longer than the run-up")
    }

    /// The page's busy window belongs to the track it was moving over. A new track's
    /// first placement used to wait out the old track's move, up to one move late.
    func testAMoveOnOneTrackDoesNotMakeAnotherTracksFirstPlacementWait() throws {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let scroll = FollowScroll()
        XCTAssertNil(scroll.remaining(track: "a", now: start), "nothing has moved yet")
        scroll.began(track: "a", now: start, duration: 0.5)
        XCTAssertEqual(try XCTUnwrap(scroll.remaining(track: "a", now: start.addingTimeInterval(0.2))), 0.3, accuracy: 0.001)
        XCTAssertNil(scroll.remaining(track: "b", now: start.addingTimeInterval(0.2)), "another track has no move to wait for")
        XCTAssertNil(scroll.remaining(track: "a", now: start.addingTimeInterval(0.6)), "the move is over")
    }
}
