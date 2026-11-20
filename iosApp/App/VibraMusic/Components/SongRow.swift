import VibraMusicCore
import SwiftUI

// Ports the song row of ui/components/Common.kt (SongRow, ExplicitSongTitle) and the swipe-to-
// queue plumbing MainActivity.kt gave every list.

/// One track in a list: artwork (or a track number), title with the explicit badge, artist, and a
/// More button. Long-press opens the song actions sheet; a horizontal swipe queues the track (play
/// next or add to queue, per the setting); the playing track is highlighted.
struct SongRow: View {
    let song: Song
    /// Shown instead of the artwork on album pages (the track number).
    var number: Int?
    /// Replaces the artist line (e.g. "Song • Artist • 3:20" on search results).
    var subtitle: String?
    /// Whether the swipe queues the row. Off on the queue panel itself.
    var swipeToQueue = true
    let onTap: () -> Void

    @Environment(PlayerController.self) private var player
    @Environment(AppRouter.self) private var router

    var body: some View {
        let isCurrent = player.currentSong?.isSameTrackAs(song) == true
        HStack(spacing: 12) {
            leading(isCurrent: isCurrent)
            VStack(alignment: .leading, spacing: 2) {
                ExplicitSongTitle(song: song, font: AppTheme.Typeface.title, color: isCurrent ? .accentColor : .primary)
                Text(subtitle ?? song.artist)
                    .font(AppTheme.Typeface.bodySmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let duration = song.durationText, !duration.isEmpty, subtitle == nil {
                Text(duration)
                    .font(AppTheme.Typeface.bodySmall.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button {
                Haptics.shared.play(.tap)
                router.present(.songActions(song))
            } label: {
                Image(systemName: AppSymbol.more)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.more)
        }
        .padding(.horizontal, AppTheme.gutter)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onLongPressGesture(minimumDuration: 0.4) {
            Haptics.shared.play(.tap)
            router.present(.songActions(song))
        }
        .modifier(SwipeToQueue(enabled: swipeToQueue, playNext: player.settings.swipeToPlayNext) {
            player.queueFromSwipe(song)
        })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("songRow")
        .accessibilityAction(named: Text(player.settings.swipeToPlayNext ? L10n.playNext : L10n.addToQueue)) {
            player.queueFromSwipe(song)
        }
    }

    @ViewBuilder
    private func leading(isCurrent: Bool) -> some View {
        if let number {
            ZStack {
                if isCurrent {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text("\(number)")
                        .font(AppTheme.Typeface.bodySmall.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28)
        } else {
            ArtworkImage(song: song, pixels: ArtworkSize.row)
                .frame(width: 48, height: 48)
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: AppTheme.artCorner, style: .continuous).fill(.black.opacity(0.35))
                        Image(systemName: "waveform")
                            .foregroundStyle(.white)
                            .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                    }
                }
        }
    }
}

/// A title with YouTube Music's "E" badge when the track is explicit (Common.kt's
/// ExplicitSongTitle).
struct ExplicitSongTitle: View {
    let song: Song
    var font: Font = AppTheme.Typeface.title
    var color: Color = .primary

    var body: some View {
        HStack(spacing: 4) {
            Text(song.title)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
            if song.isExplicit == true {
                Image(systemName: AppSymbol.explicit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Explicit")
            }
        }
    }
}

/// Swipe a row sideways to queue it: the row follows the finger, the queue glyph appears behind it,
/// and letting go past the threshold queues the track (MainActivity's swipe-to-queue). Works in any
/// container, not only a List, and ignores mostly vertical drags so scrolling is untouched.
struct SwipeToQueue: ViewModifier {
    let enabled: Bool
    let playNext: Bool
    let action: () -> Void

    static let threshold: CGFloat = 80
    @State private var offset: CGFloat = 0
    @State private var armed = false

    func body(content: Content) -> some View {
        if enabled {
            content
                .offset(x: offset)
                .background(alignment: .leading) {
                    if offset > 4 {
                        Image(systemName: playNext ? AppSymbol.playNext : AppSymbol.addToQueue)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(armed ? Color.accentColor : .secondary)
                            .padding(.leading, AppTheme.gutter)
                            .scaleEffect(armed ? 1.15 : 1)
                    }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 18)
                        .onChanged { value in
                            let dx = value.translation.width
                            guard dx > 0, abs(dx) > abs(value.translation.height) * 1.5 else { return }
                            offset = min(dx, Self.threshold * 1.4)
                            let nowArmed = dx >= Self.threshold
                            if nowArmed != armed {
                                armed = nowArmed
                                if nowArmed { Haptics.shared.play(.tick) }
                            }
                        }
                        .onEnded { _ in
                            if armed {
                                Haptics.shared.play(.select)
                                action()
                            }
                            armed = false
                            withAnimation(.spring(duration: 0.3)) { offset = 0 }
                        }
                )
        } else {
            content
        }
    }
}
