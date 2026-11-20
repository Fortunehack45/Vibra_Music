import VibraMusicCore
import Playback
import PlaybackPolicy
import PlaybackQueue
import SwiftUI

// The pieces both layouts of the player share: the "Playing from" strip, the credits with the like
// and menu discs, the menu itself, and the deck of controls under the artwork.

// MARK: - Caption

extension PlaybackOrigin {
    /// "Played by …", "Playing … Radio", "Playing from …".
    var caption: String {
        switch self {
        case .playedBy(let name): return L10n.playedBy(name)
        case .radio(let name): return L10n.playingRadio(name)
        case .playingFrom(let name): return L10n.playingFrom(name)
        }
    }
}

/// The grab handle — the promise that the player closes downwards — and under it where the music
/// is playing from.
struct PlayerTopStrip: View {
    var caption: String?
    var captionVisible = true
    var onCaption: () -> Void
    var onClose: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Button(action: onClose) {
                Capsule()
                    .fill(Color.white.opacity(0.7))
                    .frame(width: 38, height: 5)
                    .shadow(color: .black.opacity(0.25), radius: 2)
                    .frame(width: 88, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.close)
            .accessibilityIdentifier("nowPlaying.close")
            if let caption, captionVisible {
                Button(action: onCaption) {
                    Text(caption)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                        .lineLimit(1)
                        .padding(.horizontal, NowPlayingLayout.gutter)
                }
                .buttonStyle(.plain)
                .padding(.top, 15)
                .transition(.opacity)
                .accessibilityIdentifier("nowPlaying.playingFrom")
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 34, alignment: .top)
    }
}

/// Where the "Playing from" caption leads, in both layouts (NowPlayingScreen.kt's
/// `openPlaybackOrigin`): the party for a track someone else queued, the queue itself for a
/// queue-built session, otherwise back to the album or playlist the session started from.
@MainActor
enum PlayerPlaybackOrigin {
    static func open(song: Song, player: PlayerController, router: AppRouter, model: NowPlayingModel) {
        Haptics.shared.play(.tap)
        if case .playedBy = player.playingFrom {
            router.nowPlaying.close()
            router.open(.listenTogether)
        } else if song.playbackSourceType == .queue {
            withAnimation(NowPlayingMotion.collapse) { model.panes.openQueue() }
        } else if let source = player.playingFromSource {
            router.openPlaybackSource(source)
        }
    }
}

// MARK: - Credits

/// Title and artist, the heart, and the menu. The title opens the album and the artist the artist,
/// when YouTube gave ids for them. Liking is about this song, so it sits by the credits; guests
/// get nothing to tap, and neither does a local file, which has no YouTube identity to rate.
struct PlayerCredits: View {
    let song: Song
    let model: NowPlayingModel
    /// The collapsed header over the lyrics or the queue: smaller, and it doesn't crawl.
    var compact = false

    @Environment(PlayerController.self) private var player
    @Environment(AppModel.self) private var app
    @Environment(AppRouter.self) private var router
    @State private var titleOverflowing = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: compact ? 0 : 1) {
                HStack(spacing: 6) {
                    PlayerMarqueeText(text: song.title, font: compact ? .headline : .title3.weight(.bold), enabled: !compact,
                                onOverflowChange: { titleOverflowing = $0 })
                        .accessibilityIdentifier("nowPlaying.title")
                    if song.isExplicit == true {
                        Image(systemName: AppSymbol.explicit)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { open(song.albumId) }
                .accessibilityAddTraits(song.albumId == nil ? [] : .isLink)
                PlayerMarqueeText(text: song.artist, font: compact ? .subheadline.weight(.medium) : .title3.weight(.medium),
                            color: .white.opacity(0.55), enabled: !compact,
                            startDelay: titleOverflowing ? PlayerMarqueeText.artistStagger : 0)
                    .contentShape(Rectangle())
                    .onTapGesture { open(song.artistId) }
                    .accessibilityAddTraits(song.artistId == nil ? [] : .isLink)
                    .accessibilityIdentifier("nowPlaying.artist")
            }
            .id("\(song.title)\u{1F}\(song.artist)")
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.3), value: "\(song.title)\u{1F}\(song.artist)")
            if app.accounts.isSignedIn && song.localUri == nil {
                let liked = player.likeStatus(of: song) == .like
                Button {
                    Haptics.shared.play(liked ? .toggleOff : .toggleOn)
                    player.toggleLike(song)
                } label: {
                    PlayerCircleGlyph(symbol: liked ? AppSymbol.heartFilled : AppSymbol.heart, active: liked)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(liked ? L10n.removeFromLiked : L10n.like)
                .accessibilityIdentifier("nowPlaying.like")
            }
            PlayerMenuButton(model: model)
        }
        .frame(height: compact ? NowPlayingLayout.thumbSize : NowPlayingLayout.headerHeight)
    }

    private func open(_ browseId: String?) {
        guard let browseId, !browseId.isEmpty else { return }
        Haptics.shared.play(.tap)
        router.nowPlaying.close()
        router.open(AppRoute.browse(browseId))
    }
}

// MARK: - Menu

/// What the disc beside the credits is, and what pressing it does (Android's `CircleGlyph` in
/// NowPlayingScreen.kt, commit 89912638).
///
/// While the lyrics are up the menu glyph becomes the share entry: the same pick mode a long press
/// on a line opens, only on a player whose panel actually has lines to pick. While picking it
/// becomes the way back out — the bar below already holds Share. The revert cue keeps the glyph it
/// always had, because it is about the recording that is playing rather than about the page.
struct PlayerMenuEntry: Equatable {
    enum Action: Equatable {
        /// The song's menu, the disc's usual job.
        case menu
        /// Enter the pick mode with nothing chosen: the header names no line.
        case startPick
        /// Leave the pick mode.
        case cancelPick
    }

    var action: Action
    /// What the disc draws.
    var symbol: String
    /// What VoiceOver reads, and what the glyph means.
    var label: String
    /// The press that goes with it. Android gives the share glyph `Select` and the menu `Tap`.
    var haptic: Haptic

    static func entry(showsRevertCue: Bool, lyricsShareVisible: Bool, picking: Bool) -> PlayerMenuEntry {
        if showsRevertCue {
            return PlayerMenuEntry(action: .menu, symbol: "arrow.uturn.backward", label: L10n.more, haptic: .tap)
        }
        guard lyricsShareVisible else {
            return PlayerMenuEntry(action: .menu, symbol: AppSymbol.more, label: L10n.more, haptic: .tap)
        }
        if picking {
            return PlayerMenuEntry(action: .cancelPick, symbol: "xmark", label: L10n.cancel, haptic: .select)
        }
        return PlayerMenuEntry(action: .startPick, symbol: AppSymbol.share, label: L10n.share, haptic: .select)
    }
}

/// The disc beside the credits: opens the song's menu with the player's own rows in it (which
/// recording is playing, the sleep timer, the lyrics offset), as MainActivity's `onOpenMenu` does
/// with `menuFromPlayer` — and, while the lyrics are up, the way into and out of the pick mode.
struct PlayerMenuButton: View {
    let model: NowPlayingModel
    @Environment(LyricsShareController.self) private var share: LyricsShareController?

    /// Android's `lyricsShareGlyphVisible`: the page has to be the lyrics, there has to be a card
    /// to make here, and the panel has to hold something to pick.
    private var lyricsShareVisible: Bool {
        guard share != nil else { return false }
        return model.panes.lyricsOpen && !(model.lyrics.lines?.isEmpty ?? true)
    }

    private var entry: PlayerMenuEntry {
        PlayerMenuEntry.entry(showsRevertCue: model.showsRevertCue,
                              lyricsShareVisible: lyricsShareVisible,
                              picking: share?.picking ?? false)
    }

    var body: some View {
        let entry = self.entry
        Button {
            Haptics.shared.play(entry.haptic)
            switch entry.action {
            case .menu: model.sheet = .songActions
            case .startPick: share?.beginPicking()
            case .cancelPick: share?.cancel()
            }
        } label: {
            PlayerCircleGlyph(symbol: entry.symbol)
        }
        .buttonStyle(.plain)
        // The identifier stays the same handle for the disc wherever it leads; the label is what
        // says which of the three it is.
        .accessibilityLabel(entry.label)
        .accessibilityIdentifier("nowPlaying.more")
    }
}

// MARK: - Deck

/// The controls pinned to the foot of the player: the scrubber, the transport, the volume, and the
/// lyrics / output / queue row with the output name under it. Measured at its natural height, so
/// the controls sit in the same place on every screen and the artwork gets what's left.
struct PlayerDeck: View {
    let song: Song
    let model: NowPlayingModel
    /// Spare height a tall screen spends around the transport rather than as a hole.
    var spread: CGFloat = 0
    var showsActions = true
    var compact = false

    @Environment(PlayerController.self) private var player
    @Environment(AppModel.self) private var app
    @Environment(AppSettings.self) private var settings
    @Environment(AppRouter.self) private var router

    var body: some View {
        VStack(spacing: 0) {
            if model.panes.lyricsOpen {
                PlayerLyricsStatus(session: model.lyrics) { model.sheet = .lyricsProvider }
            } else {
                PlayerLyricStrip(session: model.lyrics) {
                    withAnimation(NowPlayingMotion.collapse) { model.panes.openLyrics() }
                }
            }
            PlayerScrubberView(scrub: model.scrub, loading: player.isSwappingVersion, badge: PlayerQuality.badge(player: player, app: app))
            Spacer().frame(height: (compact ? 0 : 8) + spread / 2)
            PlayerTransport(compact: compact)
            Spacer().frame(height: (compact ? 0 : 12) + spread / 2)
            if settings.hideVolumeBar {
                // The slot keeps its footprint: a display preference shouldn't move the controls.
                Color.clear.frame(height: 32)
            } else {
                PlayerVolumeRow { model.volumeDragging = $0 }
            }
            if showsActions {
                Spacer().frame(height: 6)
                PlayerActions(song: song, model: model)
            }
        }
    }
}

/// The transport, reading the playhead in a scope of its own: back is lit once the track is far
/// enough in to restart, and that check ticks with the position.
struct PlayerTransport: View {
    var compact = false

    @Environment(PlayerController.self) private var player

    var body: some View {
        let locked = player.controlsLocked
        PlayerTransportRow(
            isPlaying: player.playWhenReady,
            isLoading: player.pipelineStatus == .resolving || player.isSwappingVersion,
            previousEnabled: PlayerTransportState.previousEnabled(controlsLocked: locked, hasPrevious: player.hasPrevious, position: player.position),
            nextEnabled: PlayerTransportState.nextEnabled(controlsLocked: locked, hasNext: player.hasNext),
            compact: compact,
            onPrevious: { player.previous() },
            onPlayPause: { player.togglePlayPause() },
            onNext: { player.next() }
        )
    }
}

/// The lyrics / output / queue row and the output name under it.
struct PlayerActions: View {
    let song: Song
    let model: NowPlayingModel

    @Environment(PlayerController.self) private var player
    @Environment(AppModel.self) private var app
    @Environment(AppRouter.self) private var router

    var body: some View {
        let output = AudioOutputStatus.shared.current
        let accountName = app.accounts.activeProfile?.name
        VStack(spacing: 12) {
            PlayerActionRow(
                panes: model.panes,
                shuffleEnabled: player.shuffleEnabled,
                repeatMode: player.repeatMode,
                autoplayEnabled: player.isAutoplayEnabled,
                party: model.party,
                onToggleLyrics: { withAnimation(NowPlayingMotion.collapse) { model.panes.toggleLyrics() } },
                onToggleQueue: { withAnimation(NowPlayingMotion.collapse) { model.panes.toggleQueue() } },
                onToggleShuffle: { player.toggleShuffle() },
                onCycleRepeat: { player.cycleRepeatMode() },
                onToggleAutoplay: { player.toggleAutoplay() },
                onOpenOutput: { model.sheet = .output },
                onParty: openListenTogether
            )
            PlayerOutputCaption(
                outputName: PlayerOutputLabel.activeName(of: output.outputs, accountName: accountName),
                party: model.party,
                shines: PlaybackQualityBadge.outputCaptionShines(
                    stats: PlayerQuality.snapshot(player: player),
                    output: output,
                    inParty: model.party.inParty
                ),
                action: { if model.party.inParty { openListenTogether() } else { model.sheet = .output } }
            )
        }
    }

    private func openListenTogether() {
        router.nowPlaying.close()
        router.open(.listenTogether)
    }
}

// MARK: - Quality

@MainActor
enum PlayerQuality {
    static func snapshot(player: PlayerController) -> NerdStats.Snapshot? {
        PlayerNerdStatsText.snapshot(
            stats: player.stats,
            stream: player.currentStream,
            itemID: playingItemID(player),
            sourceOnDisk: player.sourceOnDisk
        )
    }

    /// The id the engine plays the current row under, rendition tag included: a quality upgrade
    /// reopens the row as `<id>#<tag>`, and the stats measured on that copy are the ones to show.
    static func playingItemID(_ player: PlayerController) -> String? {
        player.currentSong.map(player.sources.engineItemID(for:))
    }

    /// The badge between the timestamps, decided by PlaybackPolicy on measured figures.
    static func badge(player: PlayerController, app: AppModel) -> PlaybackQualityBadge? {
        // A copy opening off the disk isn't waiting on a better one: before it is measured, its
        // load read as "Upgrading quality" over an Atmos copy already kept whole.
        let onDisk = player.currentSong.map { player.sources.playingFromCache(for: $0.videoId) } ?? false
        return PlaybackQualityBadge.resolve(
            isLoading: player.isBuffering && !onDisk,
            stillRacing: NerdStats.shared.isRacing(player.currentSong?.videoId),
            effectiveQuality: app.qualityCeiling.effectiveQuality,
            stats: snapshot(player: player)
        )
    }
}

enum NowPlayingMotion {
    /// The sleeve collapsing into the header and back: one 420 ms curve for both panels.
    static let collapseDuration = 0.42
    static let collapse = Animation.timingCurve(0.4, 0, 0.2, 1, duration: collapseDuration)
}
