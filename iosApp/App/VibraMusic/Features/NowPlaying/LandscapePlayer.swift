import VibraMusicCore
import PlaybackQueue
import SwiftUI

/// The player in a landscape window — a phone on its side, or a tablet (ports
/// ui/player/LandscapePlayer.kt).
///
/// Two columns of equal width. The left one is the same in every state: the sleeve, and under it
/// the lyrics / output / queue row — the controls for which of three things the right column
/// shows. The right one is that thing: the credits and transport, the lyrics, or the queue, turned
/// like a page. Nothing is drawn twice and nothing moves between columns. The whole screen stands
/// on one blurred copy of the cover: there is no artwork edge here for a mesh to continue from.
struct LandscapePlayer: View {
    let song: Song
    let model: NowPlayingModel
    let size: CGSize

    @Environment(PlayerController.self) private var player
    @Environment(AppRouter.self) private var router
    @Environment(AppModel.self) private var app
    @Environment(AppSettings.self) private var settings
    @Environment(\.layoutDirection) private var layoutDirection
    /// True while the player's drag is alive. SwiftUI resets it even when the system cancels the
    /// drag and `onEnded` never runs.
    @GestureState private var dragging = false
    @GestureState private var swiping = false

    /// The widest the two columns get between them; lyrics are read down, not across.
    static let maxWidth: CGFloat = 1100

    var body: some View {
        let compact = size.height < NowPlayingLayout.landscapeCompactHeight
        let gutter: CGFloat = compact ? 20 : NowPlayingLayout.gutter
        ZStack(alignment: .top) {
            PlayerArtworkBlurBackdrop(url: PlayerArtworkLoader.url(for: song), palettes: app.palettes)
                .dockFade()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    GeometryReader { geo in
                        let side = min(geo.size.width, geo.size.height)
                        sleeve(side: side)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                    Spacer().frame(height: compact ? 10 : 22)
                    PlayerActions(song: song, model: model)
                }
                .padding(.horizontal, gutter)
                .frame(maxWidth: .infinity)

                ZStack {
                    switch model.panes.pane {
                    case .main:
                        mainPane(compact: compact)
                            .padding(.horizontal, gutter)
                            .transition(.opacity)
                    case .lyrics:
                        LyricsPanel()
                            .padding(.horizontal, NowPlayingLayout.gutter)
                            .transition(.opacity)
                    case .queue:
                        QueuePanel()
                            .padding(.horizontal, NowPlayingLayout.gutter)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .animation(.easeInOut(duration: 0.22), value: model.panes.pane)
            }
            .frame(maxWidth: Self.maxWidth)
            .padding(.top, 24)
            .padding(.bottom, compact ? 8 : 20)
            .dockFade()

            Button {
                router.nowPlaying.close()
            } label: {
                Capsule()
                    .fill(Color.white.opacity(0.7))
                    .frame(width: 38, height: 5)
                    .frame(width: 88, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .accessibilityLabel(L10n.close)
            .accessibilityIdentifier("nowPlaying.close")
            .dockFade()

            DockEdgeShade()
                .ignoresSafeArea()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlayPreferenceValue(ArtworkSlotKey.self) { slots in
            artworkOverlay(slots)
        }
        .gesture(
            DragGesture(minimumDistance: 20, coordinateSpace: .global)
                .updating($dragging) { _, state, _ in state = true }
                .onChanged { value in
                    let down = value.translation.height > 0 && abs(value.translation.width) < value.translation.height
                    let dock = router.nowPlaying
                    let reach = PlayerDockMotion.reach(value.translation.height, from: value.startLocation.y, toward: dock.travel, travel: dock.travel)
                    dock.hold(offset: down ? reach : 0)
                }
                .onEnded { value in
                    if value.translation.height > 120, abs(value.translation.width) < value.translation.height {
                        router.nowPlaying.close(velocity: value.velocity.height)
                    } else {
                        router.nowPlaying.open(velocity: value.velocity.height)
                    }
                }
        )
        .onChange(of: dragging) { _, now in
            if !now { router.nowPlaying.abandonHold(settlingOpen: true) }
        }
        .onChange(of: swiping) { _, now in
            if !now { withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { model.swipeTranslation = 0 } }
        }
    }

    /// The sleeve's place: this column's square, the same in every state. The artwork itself is
    /// drawn by ``artworkOverlay``: the still cover with the clip over it, which keeps playing
    /// whichever pane is up. With a panel up, tapping it is the way back. Sideways drags skip,
    /// here only: the right column is full of horizontal sliders.
    private func sleeve(side: CGFloat) -> some View {
        let panelOpen = model.panes.panelOpen
        return Color.clear
            .frame(width: side, height: side)
            .artworkSlot(.landscape)
            .contentShape(Rectangle())
            .onTapGesture {
                if panelOpen { withAnimation(.easeInOut(duration: 0.22)) { model.panes.showMain() } }
            }
            .gesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .global)
                    .updating($swiping) { _, state, _ in state = true }
                    .onChanged { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        model.swipeTranslation = value.translation.width
                    }
                    .onEnded { value in
                        switch PlayerSkipSwipe.outcome(translation: model.swipeTranslation, controlsLocked: player.controlsLocked, rightToLeft: layoutDirection == .rightToLeft) {
                        case .next:
                            Haptics.shared.play(.skipNext)
                            player.next()
                        case .previous:
                            Haptics.shared.play(.skipPrevious)
                            player.previous()
                        case .blocked:
                            player.notice = QueueNotice(message: L10n.listenTogetherHostOnlyNotice, symbol: nil)
                        case .none:
                            break
                        }
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { model.swipeTranslation = 0 }
                    }
            )
            .accessibilityIdentifier("nowPlaying.landscapeArtwork")
    }

    /// The sleeve, once, above the player and outside its fade, and the stats on its foot. Paused,
    /// scrubbing and playing are its three settled poses.
    private func artworkOverlay(_ slots: [ArtworkSlot]) -> some View {
        GeometryReader { proxy in
            if let slot = slots.last(where: { $0.surface == .landscape }) {
                let rect = proxy[slot.bounds]
                let image = model.artwork.image ?? PlayerArtworkLoader.standIn(for: song)
                let pose = ArtworkPose(
                    scale: PlayerArtworkPose.landscapeScale(isPlaying: player.playWhenReady, scrubbing: model.scrub.scrubbing),
                    offset: CGSize(width: PlayerSkipSwipe.artworkOffset(translation: model.swipeTranslation), height: 0)
                )
                ZStack {
                    PlayerSleeve(
                        image: image,
                        canvas: model.canvas.canvas,
                        isPlaying: player.isPlaying,
                        pausedForTransition: router.nowPlaying.isMoving,
                        onCanvasRendered: { model.canvas.rendered = $0 }
                    )
                    .docked(open: rect, shape: ArtworkShape(corner: 10, castsShadow: image != nil), pose: pose)
                    .animation(.timingCurve(0.215, 0.61, 0.355, 1, duration: 0.5), value: player.playWhenReady)
                    .animation(.timingCurve(0.215, 0.61, 0.355, 1, duration: 0.5), value: model.scrub.scrubbing)
                    if settings.showNerdStats && !model.panes.panelOpen {
                        PlayerNerdStatsOverlay(
                            statsLine: PlayerNerdStatsText.line(PlayerQuality.snapshot(player: player)),
                            automixLine: PlayerNerdStatsText.automixLine(smartFadeEnabled: settings.smartFadeEnabled, inParty: model.party.inParty, song: song),
                            lockArt: app.currentCanvas.diagnostic
                        )
                        .frame(width: rect.width, height: rect.height, alignment: .bottom)
                        .scaleEffect(pose.scale)
                        .offset(pose.offset)
                        .position(x: rect.midX, y: rect.midY)
                        .dockStats()
                    }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// Where the session came from, the credits, the scrubber, the transport and the volume — the
    /// portrait deck less the row the left column already has. Centred: there's no artwork above
    /// it to hand spare height to.
    private func mainPane(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 8) {
            if !settings.hideSongStatus, let caption = player.playingFrom?.caption {
                // Tappable, as LandscapeMainPane's `onOpenCaption`: back to where the music came from.
                Button {
                    PlayerPlaybackOrigin.open(song: song, player: player, router: router, model: model)
                } label: {
                    Text(caption)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("nowPlaying.playingFrom")
            }
            PlayerCredits(song: song, model: model)
            PlayerDeck(song: song, model: model, showsActions: false, compact: compact)
        }
        .frame(maxWidth: NowPlayingLayout.maxWidth)
        .frame(maxHeight: .infinity)
    }
}
