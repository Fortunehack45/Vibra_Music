import VibraMusicCore
import SwiftUI

// Ports ui/components/MiniPlayer.kt: the frosted bar above the tab bar. Play/pause, next, a
// horizontal swipe to change track, and a tap that opens Now Playing.

/// What a horizontal drag on the mini player does when it ends (Android's `miniPlayerTrackSwipe`):
/// left past the threshold is next, right is previous. Deciding on release means one long drag
/// never skips more than one track.
enum MiniPlayerSwipe: Hashable {
    case next
    case previous
    /// Past the threshold while a party host holds the controls: say so rather than skip.
    case blocked
    case none

    /// Android's `TRACK_SWIPE_THRESHOLD`.
    static let threshold: CGFloat = 72

    static func action(forTranslation dx: CGFloat, verticalTranslation dy: CGFloat = 0, locked: Bool, threshold: CGFloat = threshold) -> MiniPlayerSwipe {
        // A mostly vertical drag is someone scrolling the page behind the bar.
        guard abs(dx) > abs(dy) else { return .none }
        let crossed = dx <= -threshold || dx >= threshold
        if locked { return crossed ? .blocked : .none }
        if dx <= -threshold { return .next }
        if dx >= threshold { return .previous }
        return .none
    }
}

/// The mini player. Shown by the tab shell only while something is loaded.
struct MiniPlayer: View {
    let tab: AppTab

    @Environment(PlayerController.self) private var player
    @Environment(AppRouter.self) private var router
    @Environment(AppSettings.self) private var settings

    @State private var dragOffset: CGFloat = 0
    /// How far a pull has raised the bar (a rubber band on the finger's travel).
    @State private var lift: CGFloat = 0
    @State private var axis: PlayerDockMotion.MiniAxis?
    @State private var slop: (y: CGFloat, began: Date)?
    /// True while the drag is alive. SwiftUI resets it even when the system cancels the drag and
    /// `onEnded` never runs.
    @GestureState private var dragging = false

    var body: some View {
        if let song = player.currentSong {
            content(song)
        }
    }

    private func content(_ song: Song) -> some View {
        let shape = Capsule(style: .continuous)
        return HStack(spacing: 10) {
            ArtworkImage(song: song, pixels: ArtworkSize.row)
                .frame(width: 40, height: 40)
                .opacity(router.nowPlaying.coversMiniArt ? 0 : 1)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { rect in
                    router.nowPlaying.reportMiniArt(MiniArt(rect: rect, corner: AppTheme.artCorner), on: tab)
                }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(song.title)
                        .font(AppTheme.Typeface.title)
                        .lineLimit(1)
                        .accessibilityIdentifier("miniPlayer.title")
                    if song.isExplicit == true {
                        Image(systemName: AppSymbol.explicit).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(song.artist)
                    .font(AppTheme.Typeface.bodySmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("miniPlayer.artist")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .offset(x: dragOffset * 0.35)

            playPauseButton
            Button {
                Haptics.shared.play(.skipNext)
                player.next()
            } label: {
                Image(systemName: AppSymbol.next)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(player.controlsLocked)
            .opacity(player.controlsLocked ? 0.3 : 1)
            .accessibilityLabel(L10n.widgetNext)
            .accessibilityIdentifier("miniPlayer.next")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            if settings.reduceDynamicBlur {
                shape.fill(Color(.secondarySystemBackground))
            } else {
                shape.fill(.regularMaterial)
            }
        }
        .overlay(alignment: .bottom) {
            MiniPlayerProgress()
                .padding(.horizontal, 22)
                .padding(.bottom, 1)
        }
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .clipShape(shape)
        .contentShape(shape)
        .onTapGesture {
            // Deliberately silent (Android): the sheet rising is its own confirmation.
            router.nowPlaying.open()
        }
        .gesture(drag)
        .onChange(of: dragging) { _, now in
            guard !now, let cancelled = axis else { return }
            cancelDrag(cancelled)
        }
        .offset(y: -lift)
        .padding(.horizontal, AppTheme.gutter)
        .frame(maxWidth: AppTheme.floatingBarMaxWidth)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("miniPlayer")
        .accessibilityAction(named: Text(L10n.nowPlaying)) { router.nowPlaying.open() }
    }

    @ViewBuilder
    private var playPauseButton: some View {
        if player.isBuffering && player.playWhenReady {
            ProgressView()
                .frame(width: 40, height: 40)
                .accessibilityIdentifier("miniPlayer.loading")
        } else {
            Button {
                Haptics.shared.play(player.playWhenReady ? .pause : .resume)
                player.togglePlayPause()
            } label: {
                Image(systemName: player.playWhenReady ? AppSymbol.pause : AppSymbol.play)
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.playWhenReady ? L10n.pause : L10n.play)
            .accessibilityIdentifier("miniPlayer.playPause")
        }
    }

    /// The finger is read in the window's space because the bar itself moves under it.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in
                let dock = router.nowPlaying
                if axis == nil {
                    axis = PlayerDockMotion.miniAxis(value.translation, pullAllowed: dock.allowsPull)
                    slop = (value.translation.height, value.time)
                }
                switch axis {
                case .swipe:
                    dragOffset = value.translation.width
                case .pull:
                    dock.hold(offset: PlayerDockMotion.pullOffset(
                        value.translation.height, from: value.startLocation.y, travel: dock.travel))
                    lift = PlayerDockMotion.pullLift((slop?.y ?? 0) - value.translation.height)
                case .scroll, nil:
                    break
                }
            }
            .onEnded { value in
                defer { axis = nil; slop = nil }
                switch axis {
                case .swipe:
                    withAnimation(.spring(duration: 0.25)) { dragOffset = 0 }
                    perform(MiniPlayerSwipe.action(
                        forTranslation: value.translation.width,
                        verticalTranslation: value.translation.height,
                        locked: player.controlsLocked
                    ))
                case .pull:
                    endPull(value)
                case .scroll, nil:
                    break
                }
            }
    }

    /// The drag died without `onEnded`. A pull raised the cover and nobody released it.
    private func cancelDrag(_ cancelled: PlayerDockMotion.MiniAxis) {
        axis = nil
        slop = nil
        switch cancelled {
        case .pull:
            withAnimation(PlayerDockMotion.liftSpringBack) { lift = 0 }
            router.nowPlaying.abandonHold()
        case .swipe:
            withAnimation(.spring(duration: 0.25)) { dragOffset = 0 }
        case .scroll:
            break
        }
    }

    private func endPull(_ value: DragGesture.Value) {
        let dock = router.nowPlaying
        withAnimation(PlayerDockMotion.liftSpringBack) { lift = 0 }
        guard dock.isPresented else { return }
        let seconds = max(value.time.timeIntervalSince(slop?.began ?? value.time), 0.05)
        let release = PlayerDockMotion.pullRelease(
            offset: dock.travel * (1 - dock.fraction),
            travel: dock.travel,
            releaseVelocity: value.velocity.height,
            averageVelocity: (value.translation.height - (slop?.y ?? 0)) / seconds
        )
        if release.opens {
            dock.open(velocity: release.velocity)
        } else {
            dock.close(velocity: release.velocity)
        }
    }

    private func perform(_ action: MiniPlayerSwipe) {
        Self.perform(action, on: player)
    }

    /// Applies a swipe's outcome to the player (separate so tests can drive it).
    @MainActor
    static func perform(_ action: MiniPlayerSwipe, on player: PlayerController, haptics: Haptics? = nil) {
        let haptics = haptics ?? .shared
        switch action {
        case .next:
            haptics.play(.skipNext)
            player.next()
        case .previous:
            haptics.play(.skipPrevious)
            player.previous()
        case .blocked:
            player.notice = QueueNotice(message: L10n.listenTogetherHostOnlyNotice, symbol: nil)
        case .none:
            break
        }
    }
}

/// The thin progress line along the bottom of the mini player. Its own view so the four-times-a-
/// second position only redraws this, not the bar (PlayerConnection.kt's `PlaybackPosition`).
private struct MiniPlayerProgress: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        let duration = player.duration
        let position = player.position
        let fraction = duration > 0 ? min(max(position / duration, 0), 1) : 0
        GeometryReader { proxy in
            Capsule()
                .fill(Color.primary.opacity(0.55))
                .frame(width: proxy.size.width * fraction, height: 2)
        }
        .frame(height: 2)
        .accessibilityElement()
        .accessibilityIdentifier("miniPlayer.progress")
        .accessibilityLabel(L10n.nowPlaying)
        .accessibilityValue(String(format: "%.1f", position))
    }
}
