import Foundation
import Theming

// When the backdrop reads a frame off a playing Canvas clip (CanvasArtworkPlayer.kt's two
// `LaunchedEffect(rendered…)` blocks and NowPlayingScreen.kt's MESH_REFRESH_MS). Kept apart from
// the AVFoundation plumbing so the timing can be tested without a decoder.

/// Decides when the next frame read happens.
///
/// - Nothing is read until the clip's first frame is on screen: a read before then is the empty
///   buffer that turned the backdrop black.
/// - The first read happens the moment the clip is displayed, not a refresh interval later, so the
///   backdrop picks the clip's colours up together with the fade-in.
/// - A first read that comes back black or empty (the decoder's buffer lagging the layer by a
///   frame or two) is retried shortly rather than left for the whole interval.
/// - After that, one read every ``ArtworkMeshBackdropStyle/canvasRefreshInterval`` while the clip
///   plays; none while it's paused — the frame on screen isn't changing.
struct CanvasFrameReadSchedule: Equatable {
    enum Next: Equatable {
        case now
        case after(TimeInterval)
        case none
    }

    static let interval = ArtworkMeshBackdropStyle.canvasRefreshInterval
    static let firstFrameRetry: TimeInterval = 0.25
    static let firstFrameAttempts = 8

    private(set) var displayed = false
    private(set) var playing = false
    private(set) var hasValidRead = false
    private var failedFirstReads = 0

    /// The clip's first frame appeared on (or left) the screen.
    mutating func displayChanged(_ isDisplayed: Bool) -> Next {
        guard isDisplayed != displayed else { return .none }
        displayed = isDisplayed
        hasValidRead = false
        failedFirstReads = 0
        return isDisplayed ? .now : .none
    }

    mutating func playingChanged(_ isPlaying: Bool) -> Next {
        guard isPlaying != playing else { return .none }
        playing = isPlaying
        guard displayed, isPlaying else { return .none }
        return hasValidRead ? .after(Self.interval) : .now
    }

    /// A read finished; `valid` is false for no buffer or a frame ``ArtworkPixels/isLikelyBlackFrame``.
    mutating func readFinished(valid: Bool) -> Next {
        guard displayed else { return .none }
        if valid {
            hasValidRead = true
        } else if !hasValidRead {
            failedFirstReads += 1
            if failedFirstReads < Self.firstFrameAttempts { return .after(Self.firstFrameRetry) }
        }
        return playing ? .after(Self.interval) : .none
    }
}
