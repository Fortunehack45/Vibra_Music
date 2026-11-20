import SwiftUI

/// What the player around the lyrics panel tells it, and what it wants to hear back (Android:
/// `LyricsPanel`'s `active`, `controlsOpen`, `onRevealControls`, `onHideControls` and
/// `onScrollingChange` parameters).
///
/// ``LyricsPanel`` keeps the shell's no-argument initialiser, so the player hands these over
/// through the environment: `.environment(\.lyricsPanelChrome, …)`. The defaults describe a player
/// that never hides its controls — the landscape layout's case, where Android passes a constant
/// `controlsOpen = true` and no-op callbacks.
struct LyricsPanelChrome {
    /// False while the panel is kept laid out off screen; it stops following and stops the clock.
    var active = true
    /// Whether the player's controls are showing under the panel. The translate and romanize
    /// discs ride on them, and a tap on the lower half brings them back when they're away.
    var controlsOpen = true
    var onRevealControls: () -> Void = {}
    var onHideControls: () -> Void = {}
    /// Whether the list is mid-scroll, so the player can stand down its own swipe gestures.
    var onScrollingChange: (Bool) -> Void = { _ in }
    /// How far the list reaches past the panel's own frame on each side. The player pads its
    /// column by its gutter; the lyrics bleed back out to the screen edge and put the gutter back
    /// as content padding (Android's `bleedHorizontally(PLAYER_GUTTER)`), so the bloom has room.
    var bleed: CGFloat = LyricsPanelMetrics.gutter
}

private struct LyricsPanelChromeKey: EnvironmentKey {
    static let defaultValue = LyricsPanelChrome()
}

extension EnvironmentValues {
    var lyricsPanelChrome: LyricsPanelChrome {
        get { self[LyricsPanelChromeKey.self] }
        set { self[LyricsPanelChromeKey.self] = newValue }
    }
}

/// The panel's fixed metrics (PlayerLyrics.kt constants).
enum LyricsPanelMetrics {
    /// PLAYER_GUTTER.
    static let gutter: CGFloat = 30
    /// GLOW_ROOM: room inside each lead line for the bloom.
    static let glowRoom: CGFloat = 10
    /// The list's top padding before the glow room is taken back (40 dp).
    static let topPadding: CGFloat = 40
    /// DUET_LANE: the lane kept clear on the far side of a duet line.
    static let duetLane: CGFloat = 44
    /// GAP_ROW_HEIGHT + GAP_ROW_SPACING.
    static let gapRowHeight: CGFloat = 40
    static let gapRowSpacing: CGFloat = 16
    static let gapDotSize: CGFloat = 13
    static let gapDotGap: CGFloat = 5
    static let gapDotRest = 0.25
    static let gapRestScale: CGFloat = 0.76
    /// SUB_LYRIC_TUCK.
    static let subTuck: CGFloat = 6
    /// CONTROLS_SCROLL_SLOP: roughly a line of body text.
    static let controlsScrollSlop: CGFloat = 20
    /// The fade at the list's top and bottom edges (fadingEdges).
    static let edgeFade: CGFloat = 28

    /// Where the line being sung is held while the page follows it: its top at the list's top
    /// content margin (`topPadding` less the glow room), the same 30 pt for a one-line row and a
    /// three-line one, as on Android. Centred across, deliberately: every row spans the list's
    /// width, so its middle is the viewport's and the scroll stays purely vertical (Android's
    /// animateScrollToItem has no other axis). Anchored at the row's leading edge instead, the
    /// scroll also tried to take the row's content padding off the side, and the whole page slid
    /// 20 pt left while it followed. The top is `y: 0` because the margin, not a fraction of the
    /// viewport, does the offsetting: a fractional y applies to the row's height as well, and a
    /// tall row rested higher than a short one.
    static let followAnchor = UnitPoint(x: 0.5, y: 0)
    static let followTop = topPadding - glowRoom
}
