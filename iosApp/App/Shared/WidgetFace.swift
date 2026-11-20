import Foundation

/// What a widget draws for a snapshot: the text, glyphs, labels and which controls are live.
///
/// The decisions MediaWidget.views / MediaWidgetPill.views make, kept apart from the drawing so they
/// can be tested without WidgetKit.
struct WidgetFace: Equatable {
    /// Whether anything has ever played. Without a track every button is dimmed and opens the app,
    /// because a control that opens the library is more use than one that does nothing.
    var hasTrack: Bool
    /// The 2×2 / 4×2 title line.
    var title: String
    /// Only the 4×2 has room for it; nil hides the line (blank artist).
    var artist: String?
    /// The 4×1's single line: "Title - Artist", the title alone, or "Nothing played yet".
    var pillTitle: String
    var isPlaying: Bool
    var isLiked: Bool
    var shuffleEnabled: Bool
    /// Dimmed at the ends of the queue, as the media notification does.
    var previousEnabled: Bool
    var nextEnabled: Bool

    init(_ snapshot: NowPlayingSnapshot?) {
        hasTrack = snapshot != nil
        let title = snapshot?.title ?? ""
        let artist = snapshot?.artist.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.title = snapshot == nil ? SharedStrings.widgetNothingPlayed : title
        self.artist = artist.isEmpty ? nil : artist
        if snapshot == nil {
            pillTitle = SharedStrings.widgetNothingPlayed
        } else if artist.isEmpty {
            pillTitle = title
        } else {
            pillTitle = "\(title) - \(artist)"
        }
        isPlaying = snapshot?.isPlaying ?? false
        isLiked = snapshot?.isLiked ?? false
        shuffleEnabled = snapshot?.shuffleEnabled ?? false
        previousEnabled = snapshot?.hasPrevious ?? false
        nextEnabled = snapshot?.hasNext ?? false
    }

    /// The play/pause glyph follows `playWhenReady` (the snapshot's `isPlaying`), so a tap flips it
    /// at once even while a stream is still resolving.
    var toggleSymbol: String { isPlaying ? "pause.fill" : "play.fill" }
    var toggleLabel: String { isPlaying ? SharedStrings.widgetPause : SharedStrings.widgetPlay }
    var likeSymbol: String { isLiked ? "heart.fill" : "heart" }
    var likeLabel: String { isLiked ? SharedStrings.removeFromLiked : SharedStrings.like }
    var shuffleLabel: String { shuffleEnabled ? SharedStrings.shuffleOn : SharedStrings.shuffleOff }

    /// Opacity of a control (MediaWidget's ALPHA_ENABLED 255 / ALPHA_DISABLED 90).
    static let enabledOpacity = 1.0
    static let disabledOpacity = 90.0 / 255.0

    func opacity(_ control: WidgetTransportAction) -> Double {
        guard hasTrack else { return Self.disabledOpacity }
        switch control {
        case .previous: return previousEnabled ? Self.enabledOpacity : Self.disabledOpacity
        case .next: return nextEnabled ? Self.enabledOpacity : Self.disabledOpacity
        case .togglePlayPause, .like, .shuffle: return Self.enabledOpacity
        }
    }

    /// What the widget gallery shows before anything has played (the Android picker's preview
    /// layout with stand-in text over the placeholder cover).
    static var previewSnapshot: NowPlayingSnapshot {
        NowPlayingSnapshot(
            videoId: "preview",
            title: SharedStrings.widgetPreviewTitle,
            artist: SharedStrings.widgetPreviewArtist,
            isPlaying: false,
            isLiked: false,
            shuffleEnabled: false,
            repeatMode: "OFF",
            hasNext: true,
            hasPrevious: true,
            positionMs: 0,
            durationMs: 0,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
