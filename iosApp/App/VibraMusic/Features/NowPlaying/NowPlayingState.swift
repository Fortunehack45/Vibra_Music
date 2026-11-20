import VibraMusicCore
import Foundation
import Observation
import Playback
import PlaybackPolicy
import PlaybackQueue

// The Now Playing screen's own state and decisions, kept apart from the views so they can be tested
// without a screen: which panel is up (NowPlayingScreen.kt's lyricsOpen / queueOpen), the scrub
// handle held at its drop point (PlayerState.kt's PlayerScrub), the skip swipe, the artwork's
// poses, the transport's enabled states, and the layout decision (landscapePlayerAvailable).

// MARK: - Panes

/// What the player shows in its main area: the artwork, the lyrics or the queue. Lyrics and the
/// queue are two things to show in one place, so opening either closes the other.
enum PlayerPane: String, Hashable, CaseIterable {
    case main, lyrics, queue

    init(_ screen: LastPlayerScreen) {
        switch screen {
        case .main: self = .main
        case .lyrics: self = .lyrics
        case .queue: self = .queue
        }
    }

    /// Persisted so reopening the player (and a relaunch) returns to the same surface, as Android's
    /// `AppSettings.lastPlayerScreen` does.
    var lastPlayerScreen: LastPlayerScreen {
        switch self {
        case .main: return .main
        case .lyrics: return .lyrics
        case .queue: return .queue
        }
    }
}

/// The pane switches, as NowPlayingScreen.kt spells them: `openLyrics`, `closeLyrics`,
/// `toggleLyrics`, `toggleQueue`, and the collapsed sleeve's tap back to the artwork.
///
/// The pane is a place, not a property of the track: nothing here resets it on a track change, so
/// someone reading along who skips carries on reading.
struct PlayerPaneState: Hashable {
    private(set) var pane: PlayerPane {
        // Only the lyrics have controls to put away; whichever way the page leaves them, it comes
        // back to them with the deck up (Android's `closeLyrics`, which `toggleQueue` also runs).
        didSet { if pane != .lyrics { lyricsControlsOpen = false } }
    }
    /// Whether the deck is up under the lyrics (NowPlayingScreen.kt's `lyricsControlsOpen`).
    /// Scrolling on or the idle wait puts it away; scrolling back or a tap on the panel's lower
    /// half brings it back.
    var lyricsControlsOpen: Bool

    init(restoring screen: LastPlayerScreen = .main) {
        pane = PlayerPane(screen)
        lyricsControlsOpen = pane == .lyrics
    }

    var lyricsOpen: Bool { pane == .lyrics }
    var queueOpen: Bool { pane == .queue }
    var panelOpen: Bool { pane != .main }

    /// Whether the deck (lyric strip, scrubber, transport, volume, bottom row) is on screen. A pick
    /// owns the screen, so the deck stands down for as long as one is on.
    func deckShown(picking: Bool) -> Bool {
        !picking && (!lyricsOpen || lyricsControlsOpen)
    }

    /// The deck comes up with the lyrics, in the same change as the pane: set apart, there was a
    /// frame with the lyrics open and the deck away, and every trip in started the deck's exit and
    /// reversed it on the next frame (Android's `openLyrics`).
    mutating func openLyrics() {
        pane = .lyrics
        lyricsControlsOpen = true
    }

    mutating func closeLyrics() {
        if pane == .lyrics { pane = .main }
    }

    mutating func toggleLyrics() {
        if lyricsOpen { closeLyrics() } else { openLyrics() }
    }

    /// Opening the queue closes the lyrics behind it; closing it goes back to the artwork.
    mutating func toggleQueue() {
        pane = queueOpen ? .main : .queue
    }

    mutating func openQueue() { pane = .queue }

    /// The collapsed sleeve is the way back: tapping it puts the queue or the lyrics away.
    mutating func showMain() { pane = .main }
}

// MARK: - Scrub

/// The seek bar's state: a drag in progress, and where the handle was dropped until the player's
/// position catches up with it (PlayerState.kt's `PlayerScrub` + `rememberPlayerScrub`).
///
/// After a release the player needs to buffer before it reports the new position; the handle is
/// kept where it was dropped so it doesn't snap back and then jump forward. It lets go as soon as
/// the position agrees (within ``settleTolerance``), and unconditionally after ``settleTimeout``:
/// the agreement test alone was the only thing that ever cleared the override on Android, and a
/// clamped or rejected seek left the bar frozen for the rest of the track.
@MainActor
@Observable
final class PlayerScrub {
    /// Wide enough to swallow a coarse progress tick, tight enough that the handle doesn't hand
    /// over while it is still visibly wrong. Absolute rather than a share of the duration.
    static let settleTolerance: TimeInterval = 1.5
    /// A backstop, not a schedule: how long a seek that never settles can freeze the bar for.
    static let settleTimeout: TimeInterval = 4

    private(set) var scrubbing = false
    /// The fraction under the finger while scrubbing.
    private(set) var value: Double = 0
    /// The fraction the handle was dropped at, until the position catches up.
    private(set) var pendingSeek: Double?
    @ObservationIgnored private var pendingSince: Date?

    /// Where the handle is drawn, as a fraction of the track.
    func shown(position: TimeInterval, duration: TimeInterval) -> Double {
        if scrubbing { return value }
        if let pendingSeek { return pendingSeek }
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    func drag(to fraction: Double) {
        scrubbing = true
        value = min(max(fraction, 0), 1)
    }

    /// The finger lifted: returns the fraction to seek to, and holds the handle there.
    @discardableResult
    func release(now: Date = Date()) -> Double {
        pendingSeek = value
        pendingSince = now
        scrubbing = false
        return value
    }

    /// A drag that ended without a seek (the gesture was cancelled).
    func cancel() {
        scrubbing = false
    }

    /// Fed with every position report: releases the held handle once the player agrees with it,
    /// or once ``settleTimeout`` has passed whether it agrees or not.
    func positionDidChange(_ position: TimeInterval, duration: TimeInterval, now: Date = Date()) {
        guard let target = pendingSeek else { return }
        if let pendingSince, now.timeIntervalSince(pendingSince) >= Self.settleTimeout {
            clearPending()
            return
        }
        guard duration > 0 else { return }
        if abs(position - target * duration) < Self.settleTolerance {
            clearPending()
        }
    }

    /// A new track: whatever was held belonged to the last one.
    func trackDidChange() {
        clearPending()
        scrubbing = false
    }

    private func clearPending() {
        pendingSeek = nil
        pendingSince = nil
    }
}

// MARK: - Skip swipe

/// A horizontal fling on the player skips tracks; the artwork follows the finger, damped, so the
/// gesture has something to hold on to (NowPlayingScreen.kt's `skipSwipeGesture`).
enum PlayerSkipSwipe {
    /// How far the finger has to travel for a release to skip.
    static let threshold: CGFloat = 72
    /// The artwork moves this share of the finger's travel: it's a hint, not a drag-to-position.
    static let damping: CGFloat = 0.35

    enum Outcome: Equatable {
        case next, previous
        /// Past the threshold while a party host holds the controls: say why nothing happened.
        case blocked
        case none
    }

    /// What a release after `translation` points of horizontal travel does. Towards the leading
    /// edge is "next" (left in a left-to-right layout, right in a right-to-left one).
    static func outcome(translation: CGFloat, controlsLocked: Bool, rightToLeft: Bool = false) -> Outcome {
        let towardsLeading = rightToLeft ? translation : -translation
        let crossed = abs(translation) >= threshold
        if controlsLocked { return crossed ? .blocked : .none }
        guard crossed else { return .none }
        return towardsLeading > 0 ? .next : .previous
    }

    /// Where the artwork is drawn for a finger `translation` along.
    static func artworkOffset(translation: CGFloat) -> CGFloat {
        translation * damping
    }
}

// MARK: - Vertical gestures on the artwork

/// The artwork-and-credits block's vertical drag: down closes the player, up pulls the queue in
/// (NowPlayingScreen.kt's dismiss band and `dragQueueIn`).
enum PlayerVerticalDrag {
    /// Share of the queue's travel past which a release carries on opening it. Well under half:
    /// nothing else an upward drag on the artwork could have meant.
    static let queueCarryFraction: CGFloat = 0.3
    /// A flick decides on its own, in points a second.
    static let flickVelocity: CGFloat = 450
    /// How far down (or how fast) a release has to be to close the player rather than spring back.
    static let dismissDistance: CGFloat = 140

    enum Outcome: Equatable {
        case openQueue, dismiss, none
    }

    /// `translation` is positive downwards; `predictedEnd` is where the fling would coast to.
    static func outcome(translation: CGFloat, predictedEnd: CGFloat, queueTravel: CGFloat) -> Outcome {
        let velocity = predictedEnd - translation
        if translation < 0 {
            if -velocity >= flickVelocity * 0.25 { return .openQueue }
            guard queueTravel > 1 else { return .none }
            return -translation / queueTravel >= queueCarryFraction ? .openQueue : .none
        }
        if translation >= dismissDistance || predictedEnd >= dismissDistance * 2.2 { return .dismiss }
        return .none
    }
}

// MARK: - Artwork poses

/// The sleeve's scale: Apple Music's signature shrink while paused.
enum PlayerArtworkPose {
    /// The portrait player's pose: a bouncy spring between playing and paused.
    static func portraitScale(isPlaying: Bool) -> CGFloat {
        isPlaying ? 1 : 0.86
    }

    /// The landscape player's three flat poses. Paused wins outright over a scrub in progress —
    /// one artwork in one of three settled poses, never a blend of two.
    static func landscapeScale(isPlaying: Bool, scrubbing: Bool) -> CGFloat {
        if !isPlaying { return 0.88 }
        if scrubbing { return 0.94 }
        return 1
    }
}

// MARK: - Full-bleed banner

/// Whether the full-bleed banner has settled for the current track (NowPlayingScreen.kt's
/// `heroSettled`).
///
/// Sticky, unlike the still art's `loaded`: once the track's cover has loaded or its clip has
/// painted a frame, the banner stays out for the rest of the track. A clip that drops its frame —
/// leaving the screen, a decoder restart — must not fold the banner back into the square sleeve
/// and blow it out again on the way in. It is per track, so a skip starts the banner over.
struct PlayerHeroState: Equatable {
    private(set) var settled = false

    /// Fed with the two things the banner can settle from. Sticky once either is true.
    mutating func settle(artworkLoaded: Bool, canvasRendered: Bool) {
        guard !settled else { return }
        if artworkLoaded || canvasRendered { settled = true }
    }

    /// A new track: the banner has not settled for it yet.
    mutating func trackDidChange() {
        settled = false
    }

    /// Whether the player draws full-bleed: the setting, the window, and something to blow out —
    /// the clip or the cover now, or either one earlier this track.
    func isHero(fullBleedArtwork: Bool, fillsWindow: Bool, artworkLoaded: Bool, canvasRendered: Bool) -> Bool {
        fullBleedArtwork && fillsWindow && (canvasRendered || artworkLoaded || settled)
    }
}

// MARK: - Layout

enum NowPlayingLayout {
    /// The player's side margin (Android's `PLAYER_GUTTER`).
    static let gutter: CGFloat = 30
    /// The widest the player's column gets on a big window.
    static let maxWidth: CGFloat = 560
    /// The least a landscape window has to offer before the player splits into two columns.
    static let landscapeMinWidth: CGFloat = 560
    /// Below this height the landscape player tightens its right column.
    static let landscapeCompactHeight: CGFloat = 440
    /// The collapsed sleeve over the lyrics and the queue.
    static let thumbSize: CGFloat = 54
    static let headerHeight: CGFloat = 60
    static let artTitleGap: CGFloat = 20
    /// Share of the full-bleed banner's height given over to its dissolve.
    static let heroFadeFraction: CGFloat = 0.42

    /// Whether the player takes its two-column landscape shape: a landscape window, wide enough.
    /// A phone on its side and a tablet in landscape are the same shape and get the same layout;
    /// an upright tablet as wide as a sideways phone does not.
    static func isLandscape(_ size: CGSize) -> Bool {
        size.width > size.height && size.width >= landscapeMinWidth
    }

    /// Whether the player is narrow enough that full-bleed artwork means "the artwork is the
    /// screen" rather than a picture wider than the controls under it.
    static func fillsWindow(width: CGFloat) -> Bool {
        width <= maxWidth + gutter * 2
    }

    /// The expanded sleeve's side: square, bounded by whichever axis runs out first once the
    /// credits and the gap above them have had theirs.
    static func sleeveSide(width: CGFloat, height: CGFloat) -> CGFloat {
        max(min(width, height - artTitleGap - headerHeight), thumbSize)
    }
}

// MARK: - Transport

@MainActor
enum PlayerTransportState {
    /// Back is lit whenever it has something to do — a track to step to, or enough elapsed to
    /// restart this one — and dimmed, not removed, while a party host holds the controls.
    static func previousEnabled(controlsLocked: Bool, hasPrevious: Bool, position: TimeInterval) -> Bool {
        !controlsLocked && (hasPrevious || position > AudioPlayerEngine.backRestartsAfter)
    }

    static func nextEnabled(controlsLocked: Bool, hasNext: Bool) -> Bool {
        !controlsLocked && hasNext
    }
}

// MARK: - Times

enum PlayerTime {
    /// "3:07" — minutes are not padded and never roll into hours, as on Android's scrubber.
    static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let whole = Int(seconds)
        return String(format: "%d:%02d", locale: Locale(identifier: "en_US_POSIX"), whole / 60, whole % 60)
    }

    /// Elapsed and "-remaining" for a handle at `fraction` of `duration`.
    static func labels(fraction: Double, duration: TimeInterval) -> (elapsed: String, remaining: String) {
        let elapsed = max(duration, 0) * min(max(fraction, 0), 1)
        return (format(elapsed), "-" + format(max(duration, 0) - floor(elapsed)))
    }
}

// MARK: - Revert cue

/// A brief, non-modal confirmation that the menu now holds a way back to YouTube's own upload:
/// after the player swaps the playing entry to a better copy, the menu glyph shows the undo arrow
/// for ``duration`` (NowPlayingScreen.kt's `showRevertCue`). The menu keeps its usual action.
enum PlayerRevertCue {
    static let duration: TimeInterval = 2.6

    /// Whether moving from `old` to `new` for the same queue entry was a quality upgrade: YouTube's
    /// stream replaced by a substitute (an add-on, JioSaavn, a module) mid-track.
    static func isUpgrade(from old: ResolvedStream?, to new: ResolvedStream?, sameEntry: Bool) -> Bool {
        guard sameEntry, let old, let new else { return false }
        return old.origin == .youtube && new.origin != .youtube && new.origin != .local
    }
}
