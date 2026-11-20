import Foundation
import Lyrics
import Observation
import SwiftUI

/// The panel's line-level state: which rows are being sung, which one the page is heading for,
/// and whether the reader has taken over the scroll (Android: the state half of `LyricsPanel` in
/// PlayerLyrics.kt). Updated from the frame clock, but only *published* when a value changes, so a
/// frame costs a comparison and the SwiftUI list re-renders a few times per line, not per frame.
@MainActor
@Observable
final class LyricsPanelModel {
    private(set) var lines: [LyricLine] = []
    /// Whether the source stamps its lines at all. Plain lyrics don't follow the song.
    private(set) var isSynced = false
    /// Only a song that actually names a second voice is laid out as a duet.
    private(set) var isDuet = false
    /// Every row still being sung (overlapping vocals included).
    private(set) var activeRows: [Int] = []
    /// The uppermost unfinished vocal: owns the brightness until its end.
    private(set) var scrollLine = -1
    /// Where the page is heading — a run-up ahead of the singing, so the words are under your
    /// eye when they land rather than settling after the downbeat.
    private(set) var leadLine = -1
    /// Reading by hand: following is suspended, the blur clears and the stack flattens.
    var browsing = false
    /// The list is moving under a finger or a fling.
    var isScrolling = false

    /// The row the stack arranges itself around.
    var focusLine: Int { leadLine >= 0 ? leadLine : scrollLine }

    func setLines(_ lines: [LyricLine]) {
        guard lines != self.lines else { return }
        self.lines = lines
        let synced = lines.contains { $0.timeMs > 0 }
        if synced != isSynced { isSynced = synced }
        let duet = lines.contains { $0.alignment == .end }
        if duet != isDuet { isDuet = duet }
        activeRows = []
        scrollLine = -1
        leadLine = -1
    }

    /// Re-derives the line-level state for a lyric position. Cheap, and silent unless something
    /// changed.
    func update(positionMs: Int) {
        guard isSynced else {
            if !activeRows.isEmpty { activeRows = [] }
            if scrollLine != -1 { scrollLine = -1 }
            if leadLine != -1 { leadLine = -1 }
            return
        }
        let rows = LyricFocus.activeRows(lines, positionMs: positionMs)
        if rows != activeRows { activeRows = rows }
        let scroll = rows.first ?? -1
        if scroll != scrollLine { scrollLine = scroll }
        let ahead = positionMs + LyricFocus.scrollLeadMs(lines, positionMs: positionMs)
        let lead = LyricFocus.activeRows(lines, positionMs: ahead).first ?? -1
        if lead != leadLine { leadLine = lead }
    }

    func isActive(_ index: Int) -> Bool { isSynced && activeRows.contains(index) }

    /// Signed distance from the line being sung — brightness can't run ahead of the words.
    func offset(of index: Int) -> Int { scrollLine < 0 ? 0 : index - scrollLine }
}

/// How a row looks for where it sits relative to the singing (Android's LINE_FALLOFF_*, the
/// browsing flatten, INACTIVE_SCALE / PRESSED_SCALE). Pure, so the hierarchy is testable.
enum LyricRowStyle {
    /// Indexed by distance from the playing line; the last entry stands for everything further.
    static let falloffAlpha: [Double] = [1, 0.8, 0.7, 0.58, 0.46]
    static let falloffBlur: [CGFloat] = [0, 1, 1, 1.7, 2.4]
    static let browsingAlpha = 0.8
    static let inactiveScale: CGFloat = 0.98
    static let pressedScale: CGFloat = 0.96
    /// The unsung tail of a word-synced line, and a not-yet-sung line on a line-synced source.
    static let unsungAlpha = 0.45
    static let plainAlpha = 0.95
    static let backingAlpha = 0.72
    static let subAlpha = 0.85
    /// Apple's bloom on the line being sung, at its very strongest.
    static let glowAlpha: CGFloat = 0.62

    static func step(forDistance distance: Int) -> Int { min(abs(distance), falloffAlpha.count - 1) }

    static func alpha(synced: Bool, active: Bool, browsing: Bool, distance: Int) -> Double {
        if !synced { return plainAlpha }
        if active { return 1 }
        if browsing { return browsingAlpha }
        return falloffAlpha[step(forDistance: distance)]
    }

    /// Blur only where the listener wants it and the page is following along; never on the
    /// playing line.
    static func blur(synced: Bool, active: Bool, browsing: Bool, distance: Int, blurEnabled: Bool) -> CGFloat {
        if !synced || !blurEnabled || browsing || active { return 0 }
        return falloffBlur[step(forDistance: distance)]
    }

    static func scale(pressed: Bool, active: Bool) -> CGFloat {
        if pressed { return pressedScale }
        return active ? 1 : inactiveScale
    }

    /// The whole-line brightness of a line with no word timings: lit once it starts (or when the
    /// source has no timing at all), otherwise held back to match a word-synced line's tail.
    static func litAlpha(synced: Bool, sung: Bool, active: Bool) -> Double {
        (!synced || sung || active) ? 1 : unsungAlpha
    }

    /// The dim copy under a word-synced line's sweep: fully lit once the page has left it.
    static func tailAlpha(sung: Bool) -> Double { sung ? 1 : unsungAlpha }
}

/// The curve and timings every handover runs on (Android's LYRIC_EASING, LYRIC_SETTLE_MS).
enum LyricMotion {
    /// Away quickly, in slowly and softly — one curve for dimming, blurring, scaling and the scroll.
    static func easing(milliseconds: Int) -> Animation {
        .timingCurve(0.41, 0, 0.12, 0.99, duration: Double(milliseconds) / 1_000)
    }

    static let settle = easing(milliseconds: 400)

    /// What iOS's Reduce Motion puts in place of the travel: a short, gentle ease, never a snap.
    static let reduced = Animation.easeInOut(duration: Double(LyricFollow.shortEase.durationMs) / 1_000)

    /// The panel's curve, or the short ease under Reduce Motion. The in-app "Reduce animation"
    /// toggle does not come here: on Android it gates only the glow and the sub-lyric reveal.
    static func easing(milliseconds: Int, reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : easing(milliseconds: milliseconds)
    }

    /// A line followed late, after a move that was still running when it landed: the
    /// move takes the time left to the line's stamp, so the page catches up rather than trailing a
    /// whole run-up behind. Never shorter than the Reduce Motion ease, never longer than the run-up.
    static func catchUpMs(lineStartMs: Int, positionMs: Int, runUpMs: Int) -> Int {
        min(max(lineStartMs - positionMs, LyricFollow.shortEase.durationMs), runUpMs)
    }

    /// How the page gets to the playing line.
    static func follow(placed: Bool, systemReduceMotion: Bool, rowOnScreen: Bool, leadMs: Int) -> LyricFollow {
        if !placed { return .jump }
        if systemReduceMotion { return .shortEase }
        return rowOnScreen ? .glide(milliseconds: leadMs) : .staged
    }
}

/// How the page gets to the playing line (Android: the `LaunchedEffect(focusLine, ...)` in PlayerLyrics.kt).
enum LyricFollow: Equatable {
    /// The first placement of a track: straight to the line, no travel.
    case jump
    /// The line is on screen: the run-up's own duration, on the panel's curve.
    case glide(milliseconds: Int)
    /// The line is somewhere off screen (a seek): the list's own staged scroll.
    case staged
    /// iOS's Reduce Motion: the travel is replaced by a short, gentle ease.
    case shortEase

    var animation: Animation? {
        switch self {
        case .jump: nil
        case .glide(let milliseconds): LyricMotion.easing(milliseconds: milliseconds)
        case .staged: .smooth(duration: Double(durationMs) / 1_000)
        case .shortEase: LyricMotion.reduced
        }
    }

    /// How long the move takes: the page is still on its way until then.
    var durationMs: Int {
        switch self {
        case .jump: 0
        case .glide(let milliseconds): milliseconds
        case .staged: 500
        case .shortEase: 200
        }
    }
}

/// How the rows fan out as the page moves between lines (Android: STAGGER_STEPS, STAGGER_FRACTION,
/// ScrollRun, and the row's `translationY`, PlayerLyrics.kt:359-366, 1804-1868).
///
/// The rows do not travel as a block. Each row after the one being scrolled to sets off a little
/// later than the row before it, up to three rows back, on the same curve as the scroll, so the
/// spacing opens as the page leaves and closes as it arrives. Rows at or above the new line move
/// with the list and carry no offset at all.
enum LyricHandover {
    static let steps = 3
    static let fraction = 0.06
    private static let curve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.41, y: 0), endControlPoint: UnitPoint(x: 0.12, y: 0.99))

    /// The last row to arrive does so this long after the page sets off.
    static func spanMs(durationMs: Int) -> Double { Double(durationMs) * (1 + fraction * Double(steps)) }

    /// How long a row `behind` rows after the new line waits before it follows.
    static func delayMs(behind: Int, durationMs: Int) -> Double {
        Double(min(max(behind, 0), steps)) * fraction * Double(durationMs)
    }

    /// Rows behind the one being scrolled to are the ones that fan out: those after it on a move
    /// down the list, those before it on a move back up.
    static func behind(index: Int, focus: Int, delta: CGFloat) -> Int {
        delta >= 0 ? index - focus : focus - index
    }

    /// How far below (for a downward move: the sign of `delta`) where the list has taken it a row
    /// is held back, `elapsedMs` into a move of `delta` points over `durationMs`.
    static func shift(delta: CGFloat, elapsedMs: Double, durationMs: Int, delayMs: Double) -> CGFloat {
        guard delayMs > 0, durationMs > 0 else { return 0 }
        func eased(_ ms: Double) -> Double { curve.value(at: min(max(ms / Double(durationMs), 0), 1)) }
        return delta * CGFloat(eased(elapsedMs) - eased(elapsedMs - delayMs))
    }
}

extension String {
    /// Whether a translation actually says something different from the original — a line the
    /// service handed back unchanged gets no second copy of itself.
    func lyricDiffers(from original: String) -> Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != original.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension LyricLine {
    /// The answering vocal without the parentheses text-only sources wrap it in; Apple Music
    /// draws the equivalent line bare. Applied to the words too, so the sweep still finds each
    /// word in the text it draws.
    func withoutBracketPunctuation() -> LyricLine {
        func strip(_ string: String) -> String {
            string.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var copy = self
        copy.text = strip(text)
        copy.words = words.compactMap { word in
            let text = strip(word.text)
            return text.isEmpty ? nil : LyricWord(startMs: word.startMs, endMs: word.endMs, text: text)
        }
        return copy
    }
}
