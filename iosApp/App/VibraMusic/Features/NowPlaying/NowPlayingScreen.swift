import VibraMusicCore
import Canvas
import ListenTogether
import Lyrics
import PlaybackPolicy
import PlaybackQueue
import SwiftUI
import Theming

/// The full player (ports ui/player/NowPlayingScreen.kt, PlayerControls.kt, PlayerDrawer.kt and
/// LandscapePlayer.kt).
///
/// Apple Music's Now Playing, closely: artwork that shrinks back while paused (or, with full-bleed
/// artwork on, the cover edge to edge dissolving into the backdrop), a hairline scrubber with the
/// quality badge between elapsed and remaining, oversized transport glyphs, the volume, and
/// lyrics / output / queue along the bottom. Lyrics and the queue open in place: the sleeve
/// collapses into a header and the panel takes its room. The backdrop is the artwork's own colours
/// as a mesh, crossfading on every track. A landscape window splits into two columns.
///
/// Swipe the artwork sideways to skip, down to close, up to open the queue.
struct NowPlayingScreen: View {
    @Environment(PlayerController.self) private var player
    @Environment(AppRouter.self) private var router
    @Environment(AppModel.self) private var app
    @Environment(AppSettings.self) private var settings

    /// Handed the app's lyrics up front, so the first frame already shows what is loaded rather
    /// than a stand-in's loading state.
    @State private var model = NowPlayingModel(restoring: AppSettings.shared.lastPlayerScreen,
                                               lyrics: AppModel.current?.currentLyrics)
    /// The pick mode and the card it makes. Shared with the lyrics panel through the environment so
    /// the rows, the bar under them and the deck that stands down all read one state.
    @State private var lyricsShare = LyricsShareController()

    var body: some View {
        @Bindable var model = model
        GeometryReader { proxy in
            ZStack {
                if let song = player.currentSong {
                    if NowPlayingLayout.isLandscape(proxy.size) {
                        LandscapePlayer(song: song, model: model, size: proxy.size)
                            .safeAreaPadding(proxy.safeAreaInsets)
                    } else {
                        PortraitPlayer(song: song, model: model, size: proxy.size, insets: proxy.safeAreaInsets)
                    }
                }
            }
            // The window is claimed above the stage's offset, because SwiftUI resolves a safe area
            // against where a view is drawn. The portrait player takes the insets as values and has
            // no safe area below this line: ignoring one from inside the offset re-laid the player
            // out as its sheet crossed the top inset, a one-frame jump of up to 27 pt in the artwork
            // and 9 pt in the title, wherever the finger was (measured from a screen recording). The landscape
            // player still reads them as padding, for now.
            .dockStage()
            .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(settings.hideStatusBarInPlayer && router.nowPlaying.isPresented)
        // Capped where the fixed-height strips (caption, lyric line, credits) still hold their text;
        // the sheets presented from here are outside the cap and scale fully.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        // A container: without this the screen identifier lands on every child and hides theirs.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.nowPlaying")
        .accessibilityAction(.escape) { router.nowPlaying.close() }
        .sheet(item: $model.sheet) { sheet in
            sheetContent(sheet)
        }
        .environment(model.lyrics)
        .environment(lyricsShare)
        .onChange(of: router.sheet) { _, sheet in
            // A sheet the app asks for while the player is up (the song menu's "Add to playlist",
            // "Lyrics offset") would be presented under the player and never seen: it replaces the
            // player's own sheet instead, as it replaces the song menu everywhere else.
            guard let sheet else { return }
            router.sheet = nil
            model.sheet = .app(sheet)
        }
        .onChange(of: lyricsShare.request?.id) {
            // Share hands the passage over the moment it is confirmed: the sheet is drawn over the
            // panel, so backing out of it leaves the lyrics underneath exactly where they were.
            if lyricsShare.request != nil { model.sheet = .lyricsShare }
        }
        .onAppear {
            model.persistPane = { [settings] screen in settings.lastPlayerScreen = screen }
            router.nowPlaying.playerDidAppear()
        }
        // The lyrics were looked up when the track started (``CurrentTrackLyrics``, the app's);
        // the player only reads them, so reopening it finds them loaded.
        .onChange(of: ObjectIdentifier(app.currentLyrics), initial: true) {
            model.attachLyrics(app.currentLyrics)
        }
        .task(id: PlayerArtworkLoader.url(for: player.currentSong)) {
            await model.artwork.load(PlayerArtworkLoader.url(for: player.currentSong))
        }
        .task(id: meshKey) {
            let url = PlayerArtworkLoader.url(for: player.currentSong)
            if settings.legacyMeshGradient {
                await model.legacyPalette.load(url)
            } else {
                await model.mesh.load(url, trackID: player.currentSong?.videoId, artPixels: ArtworkSize.player)
            }
            await model.tint.load(url, artPixels: ArtworkSize.player)
        }
        .task(id: canvasKey) {
            await model.canvas.load(
                for: player.currentSong,
                allowed: canvasAllowed,
                spotifyFirst: settings.prioritizeSpotifyCanvas,
                lookup: app.canvas
            )
        }
        .task {
            // The route half of the pipeline, for the output caption and sheet, while the player
            // is up; and the party's badge, which changes about twice a party.
            let follow = AudioOutputStatus.shared.followAudioSession()
            defer { follow.cancel() }
            while !Task.isCancelled {
                let state = await app.party.state
                let badge = PlayerPartyBadge(
                    inParty: state.inParty,
                    members: state.members.count,
                    hostFirstName: PlayerPartyBadge.firstName(of: state.members.first(where: \.isHost)?.displayName)
                )
                if badge != model.party { model.party = badge }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onChange(of: player.currentSong?.id) {
            model.trackDidChange()
        }
        // Initial too: opened mid-track, the stream already playing is what an upgrade is judged
        // against.
        .onChange(of: player.currentStream, initial: true) { _, stream in
            model.streamDidChange(stream, entry: player.currentSong?.queueEntryId)
        }
        .onChange(of: model.panes.lyricsOpen, initial: true) { _, open in
            // Lyrics are read continuously: hold off the screen timeout while they're up.
            UIApplication.shared.isIdleTimerDisabled = open
            // A pick belongs to the panel and its bar: leaving the lyrics takes both away, and the
            // deck that stands down while picking comes back with the pane. Android gets the same
            // from its back handler, which is what a closed pane is here.
            if !open { lyricsShare.cancel() }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            router.nowPlaying.playerDidDisappear()
        }
        #if DEBUG
        .dockProbe()
        .task {
            // Screenshots and manual checks: `-nowPlayingOrientation landscape` turns the window
            // on its side (the simulator can't be rotated from the command line), and
            // `-nowPlayingNerdStats YES` / `-nowPlayingFullBleed NO` set those two switches.
            let arguments = UserDefaults.standard
            if arguments.object(forKey: "nowPlayingNerdStats") != nil {
                settings.showNerdStats = arguments.bool(forKey: "nowPlayingNerdStats")
            }
            if arguments.object(forKey: "nowPlayingFullBleed") != nil {
                settings.fullBleedArtwork = arguments.bool(forKey: "nowPlayingFullBleed")
            }
            guard arguments.string(forKey: "nowPlayingOrientation") == "landscape" else { return }
            try? await Task.sleep(for: .seconds(1))
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
            for window in scene.windows {
                var controller = window.rootViewController
                while let next = controller {
                    next.setNeedsUpdateOfSupportedInterfaceOrientations()
                    controller = next.presentedViewController
                }
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
        }
        #endif
    }

    @ViewBuilder
    private func sheetContent(_ sheet: NowPlayingSheet) -> some View {
        switch sheet {
        case .output:
            AudioOutputSheet(
                accountName: app.accounts.activeProfile?.name,
                makePipeline: { AudioPipelineSheet.build(player: player, settings: settings) },
                isPlaying: player.isPlaying
            )
            .presentationDetents([.medium, .large])
            .presentationBackground(.ultraThinMaterial)
            .preferredColorScheme(.dark)
        case .pipeline:
            AudioPipelineSheet(pipeline: AudioPipelineSheet.build(player: player, settings: settings), isPlaying: player.isPlaying)
                .presentationDetents([.large])
                .presentationBackground(.ultraThinMaterial)
                .preferredColorScheme(.dark)
        case .songActions:
            if let song = player.currentSong {
                // The song menu knows it was opened from the player (the player is up and this is
                // its track) and adds the player's rows: versions, sleep timer, lyrics offset, log.
                SongActionsSheet(song: song)
                    .presentationDetents([.medium, .large])
            }
        case .lyricsProvider:
            LyricsProviderSheet()
                .environment(model.lyrics)
                .presentationDetents([.medium, .large])
        case .lyricsShare:
            if let request = lyricsShare.request {
                // Keyed to the passage: a second share is a new card, and the sheet's own state —
                // the picture, whether it is saved, whether it is a story — belongs to this one
                // (Android's `remember(request)`).
                LyricsShareSheet(request: request)
                    .id(request.id)
            }
        case .app(let sheet):
            SheetDestination(sheet: sheet)
        }
    }

    private var meshKey: String {
        "\(player.currentSong?.videoId ?? "")|\(player.currentSong?.thumbnailUrl ?? "")|\(settings.legacyMeshGradient)"
    }

    private var canvasAllowed: Bool {
        CanvasPolicy.isAllowed(animatedCanvas: settings.animatedCanvas, canvasOverCellular: settings.canvasOverCellular, network: app.network.status)
    }

    private var canvasKey: String {
        let song = player.currentSong
        return "\(song?.videoId ?? "")|\(song?.albumName ?? "")|\(canvasAllowed)|\(settings.prioritizeSpotifyCanvas)"
    }
}

// MARK: - Portrait

/// One tall column that is the player, the lyrics and the queue in turn.
private struct PortraitPlayer: View {
    let song: Song
    let model: NowPlayingModel
    let size: CGSize
    let insets: EdgeInsets

    @Environment(PlayerController.self) private var player
    @Environment(AppRouter.self) private var router
    @Environment(AppModel.self) private var app
    @Environment(AppSettings.self) private var settings
    @Environment(LyricsShareController.self) private var lyricsShare: LyricsShareController?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @Namespace private var namespace

    @State private var sleeveFrame: CGRect = .zero
    @State private var deckBase: CGFloat = 300
    /// The deck is still sliding away: Android's `mounted` in `SlidingPlayerDeck`.
    @State private var deckMounted = false
    @State private var dragAxis: Axis?
    /// True while each drag is alive. SwiftUI resets it even when the system cancels the drag and
    /// `onEnded` never runs.
    @GestureState private var artworkDragging = false
    @GestureState private var dismissDragging = false

    private static let space = "nowPlaying.portrait"
    private static let topStrip: CGFloat = 34

    var body: some View {
        let main = model.panes.pane == .main
        let moving = router.nowPlaying.isMoving
        let hero = router.nowPlaying.isBanner(live: heroMode)
        let bannerHeight = sleeveFrame == .zero ? 0 : sleeveFrame.maxY + NowPlayingLayout.artTitleGap / 2
        let spread = self.spread
        let deckShown = model.panes.deckShown(picking: lyricsShare?.picking ?? false)
        ZStack(alignment: .top) {
            backdrop(main: main, seam: hero ? bannerHeight : 0)
                .dockFade()
            if hero, bannerHeight > 0 {
                PlayerHeroBanner(
                    image: artworkImage,
                    canvas: main ? model.canvas.canvas : nil,
                    isPlaying: player.isPlaying,
                    pausedForTransition: moving,
                    onCanvasRendered: { model.canvas.rendered = $0 },
                    onCanvasFrame: canvasFrameHandler(main: main)
                )
                .docked(
                    open: CGRect(x: 0, y: 0, width: size.width, height: bannerHeight),
                    shape: ArtworkShape(corner: 0, castsShadow: false, dissolves: true)
                )
                .opacity(main ? 1 : 0)
                .animation(NowPlayingMotion.collapse, value: main)
                // Under the handle and the scrim until the player has faded out, then over it: raised
                // as soon as the sheet moved, the handle, the caption and the scrim vanished at once
                // and came back on landing. A zIndex change keeps the view, so the clip's player
                // layer survives the flip.
                .zIndex(router.nowPlaying.bannerOverPlayer ? 3 : 1)
            }
            topScrim(main: main)
                .dockFade()
                .zIndex(2)
            VStack(spacing: 0) {
                PlayerTopStrip(
                    caption: settings.hideSongStatus ? nil : player.playingFrom?.caption,
                    captionVisible: main,
                    onCaption: openPlaybackOrigin,
                    onClose: { router.nowPlaying.close() }
                )
                .gesture(dismissDrag)
                Group {
                    if main {
                        mainBlock()
                    } else {
                        panelBlock
                    }
                }
                .frame(maxWidth: NowPlayingLayout.maxWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, NowPlayingLayout.gutter)
                // Away while the lyrics are being read (``PlayerPaneState/deckShown(picking:)``).
                // A pick owns the screen: the transport is hidden for as long as it is on, and a
                // scroll that would reveal it is refused (see the panel's lower-half tap), so
                // nothing brings the player back under somebody choosing lines.
                if deckShown || deckMounted {
                    PlayerDeck(song: song, model: model, spread: spread)
                        .frame(maxWidth: NowPlayingLayout.maxWidth)
                        .padding(.horizontal, NowPlayingLayout.gutter)
                        .padding(.top, 8)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                            let base = (height - spread).rounded()
                            if abs(base - deckBase) > 0.5 { deckBase = base }
                        }
                        // Back on the artwork with the deck away, it arrives at its full height and
                        // fades up instead: the sleeve sizes itself against the deck's room, and
                        // sliding the deck up under it squeezed the artwork over the whole trip.
                        // Slower than the slide, and linear: eased, it was nearly up within a few
                        // frames and read as simply being there (Android's PLAYER_DECK_FADE_IN_MS).
                        // Leaving, it stays in the layout until it has no height left, as Android's
                        // does. Removed at the start, it stopped taking room at once: the lyrics
                        // grew down under a deck still on screen.
                        .modifier(PlayerDeckReveal(reveal: deckShown ? 1 : 0))
                        .animation(NowPlayingMotion.collapse, value: deckShown)
                        .transition(.asymmetric(
                            insertion: main ? AnyTransition.opacity.animation(.linear(duration: 0.7)) : .playerDeckSlide,
                            removal: .identity
                        ))
                }
            }
            .padding(.top, insets.top)
            .padding(.bottom, max(insets.bottom, 12) + 4)
            .dockFade()
            .zIndex(2)
            // On the backdrop, under the banner and the artwork overlay: the artwork stays sharp, and
            // the handle and caption above it are cut by the same edge instead of being shaded.
            DockEdgeShade()
                .zIndex(0.5)
        }
        .coordinateSpace(.named(Self.space))
        // The one real artwork, drawn over the faded player and placed by the dock.
        .overlayPreferenceValue(ArtworkSlotKey.self) { slots in
            artworkOverlay(slots, main: main, hero: hero)
        }
        .onChange(of: heroMode, initial: true) { _, now in
            router.nowPlaying.reportBanner(now)
        }
        // A trip starting locks in the layout on screen at that moment.
        .onChange(of: router.nowPlaying.isMoving) { _, moving in
            if moving { router.nowPlaying.reportBanner(heroMode) }
        }
        .task(id: deckShown) {
            if deckShown {
                deckMounted = true
                return
            }
            try? await Task.sleep(for: .seconds(NowPlayingMotion.collapseDuration))
            if !Task.isCancelled { deckMounted = false }
        }
        .task(id: model.lyricsControlsIdleKey) {
            await model.hideLyricsControlsWhenIdle()
        }
        // Turned on with the deck away, VoiceOver would find no transport and no way to it.
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)) { _ in
            if UIAccessibility.isVoiceOverRunning { model.setLyricsControls(open: true) }
        }
        .onChange(of: artworkDragging) { _, now in
            if !now { cancelArtworkDrag() }
        }
        .onChange(of: dismissDragging) { _, now in
            if !now { router.nowPlaying.abandonHold(settlingOpen: true) }
        }
        // The banner settles — and stays settled — once the cover has loaded or the clip has
        // painted a frame (NowPlayingScreen.kt's `LaunchedEffect(art.loaded, canvasRendered)`).
        // Fed from both so a clip that drops out does not fold the banner back into the sleeve.
        .onChange(of: model.artwork.loaded, initial: true) { _, loaded in
            model.hero.settle(artworkLoaded: loaded, canvasRendered: model.canvas.rendered)
        }
        .onChange(of: model.canvas.rendered, initial: true) { _, rendered in
            model.hero.settle(artworkLoaded: model.artwork.loaded, canvasRendered: rendered)
        }
    }

    // MARK: Geometry

    /// Full-bleed is a phone idiom: on by setting, and only while the player fills its window.
    /// The banner also stays once it has settled for this track, so a clip dropping out does not
    /// flip the screen between the banner and the sleeve (NowPlayingScreen.kt's `heroT`).
    private var heroMode: Bool {
        model.hero.isHero(
            fullBleedArtwork: settings.fullBleedArtwork,
            fillsWindow: NowPlayingLayout.fillsWindow(width: size.width),
            // The mini player's cover counts: the banner draws it until the player's own arrives.
            // A fresh player waiting on its own took a pull's first frame for a sleeve, flew the
            // square and swapped to the banner on landing.
            artworkLoaded: model.artwork.loaded || artworkImage != nil,
            canvasRendered: model.canvas.rendered
        )
    }

    /// Height the artwork block doesn't need, handed to the two gaps around the transport, where a
    /// tall screen should do its breathing — at most 48 pt, the rest back to the artwork.
    private var spread: CGFloat {
        let width = min(size.width - NowPlayingLayout.gutter * 2, NowPlayingLayout.maxWidth)
        let middle = size.height - Self.topStrip - deckBase - 8 - max(insets.bottom, 12) - 4 + insets.bottom
        let block = NowPlayingLayout.artTitleGap + NowPlayingLayout.headerHeight
        let wantArt = min(width, middle - block)
        let slack = max(middle - wantArt - block, 0)
        return (min(slack, 48) / 2).rounded(.down) * 2
    }

    // MARK: Backdrop

    @ViewBuilder
    private func backdrop(main: Bool, seam: CGFloat) -> some View {
        let url = PlayerArtworkLoader.url(for: song)
        ZStack {
            ArtworkMeshBackdropStyle.fallback.color
            if settings.legacyMeshGradient {
                PlayerLegacyMeshBackdrop(palette: model.legacyPalette.palette, trackKey: song.videoId, reduceMotion: reduceAnimation)
            } else {
                PlayerMeshBackdrop(
                    mesh: model.mesh.currentMesh(for: url),
                    seam: seam,
                    reduceBlur: settings.reduceDynamicBlur,
                    reduceMotion: reduceAnimation
                )
            }
            // The lyrics and the queue have no artwork edge to continue from, so they stand on
            // one blurred copy of the cover instead. Kept mounted; only its opacity changes.
            PlayerArtworkBlurBackdrop(url: url, palettes: app.palettes)
                .opacity(main ? 0 : 1)
                .animation(.easeInOut(duration: 0.36), value: main)
        }
    }

    /// The status bar always sits on light glyphs; this gradient gives them their contrast,
    /// following the cover's top band rather than flipping the glyphs per cover. A panel gets a
    /// modest floor.
    private func topScrim(main: Bool) -> some View {
        let luminance = model.tint.topBandLuminance(for: PlayerArtworkLoader.url(for: song))
        let base = StatusBarContrast.topBandScrimAlpha(artworkLuminance: luminance)
        let alpha = main ? base : max(base, 0.4)
        let stops = (0..<8).map { index -> Gradient.Stop in
            let progress = Double(index) / 7
            return Gradient.Stop(color: .black.opacity(alpha * pow(1 - progress, 1.5)), location: progress)
        }
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
            .frame(height: insets.top + Self.topStrip)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.3), value: alpha)
    }

    private var reduceAnimation: Bool { reduceMotion || settings.reduceAnimation }

    // MARK: Main block

    private func mainBlock() -> some View {
        GeometryReader { geo in
            let side = NowPlayingLayout.sleeveSide(width: geo.size.width, height: geo.size.height)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                sleeve(side: side)
                Spacer().frame(height: NowPlayingLayout.artTitleGap)
                PlayerCredits(song: song, model: model)
                    .matchedGeometryEffect(id: "credits", in: namespace)
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .contentShape(Rectangle())
        .gesture(artworkDrag)
        .transition(.opacity)
    }

    /// The card's place in the layout. The artwork itself is drawn by ``artworkOverlay``.
    private func sleeve(side: CGFloat) -> some View {
        Color.clear
            .frame(width: side, height: side)
            .artworkSlot(.card)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.space)) }) { frame in
                if frame != sleeveFrame { sleeveFrame = frame }
            }
            .overlay(alignment: .bottom) { skipHint(side: side) }
    }

    /// The cover as the player shows it: its own, or the mini player's until that is in memory.
    private var artworkImage: UIImage? {
        model.artwork.image ?? PlayerArtworkLoader.standIn(for: song)
    }

    /// The sleeve (the card, or the thumb over a panel), once, above the player and outside its
    /// fade, and the stats on its foot. The banner is the sleeve's stand-in on the main pane.
    private func artworkOverlay(_ slots: [ArtworkSlot], main: Bool, hero: Bool) -> some View {
        let surface: ArtworkSurface = main ? .card : .thumb
        return GeometryReader { proxy in
            if let slot = slots.last(where: { $0.surface == surface }) {
                let rect = proxy[slot.bounds]
                let image = artworkImage
                let pose = main && !hero ? ArtworkPose(
                    scale: PlayerArtworkPose.portraitScale(isPlaying: player.playWhenReady),
                    offset: CGSize(width: PlayerSkipSwipe.artworkOffset(translation: model.swipeTranslation), height: -model.queuePull * 36)
                ) : .rest
                ZStack {
                    if !(main && hero) {
                        PlayerSleeve(
                            image: image,
                            canvas: main ? model.canvas.canvas : nil,
                            isPlaying: player.isPlaying,
                            pausedForTransition: router.nowPlaying.isMoving,
                            onCanvasRendered: { model.canvas.rendered = $0 },
                            onCanvasFrame: canvasFrameHandler(main: true)
                        )
                        .docked(open: rect, shape: ArtworkShape(corner: main ? 8 : 6, castsShadow: image != nil), pose: pose)
                        .animation(reduceAnimation ? nil : .spring(response: 0.55, dampingFraction: 0.62), value: player.playWhenReady)
                        .transition(.opacity)
                    }
                    if main, settings.showNerdStats {
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
                        .transition(.opacity)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// A glyph under the sleeve that fades in with the drag to say which way a release would skip.
    @ViewBuilder
    private func skipHint(side: CGFloat) -> some View {
        let travel = abs(model.swipeTranslation)
        if travel > 1 {
            let towardsNext = PlayerSkipSwipe.outcome(translation: model.swipeTranslation > 0 ? PlayerSkipSwipe.threshold : -PlayerSkipSwipe.threshold,
                                                controlsLocked: false, rightToLeft: layoutDirection == .rightToLeft) == .next
            let enabled = towardsNext ? player.hasNext : player.hasPrevious
            Image(systemName: towardsNext ? "forward.fill" : "backward.fill")
                .font(.footnote)
                .foregroundStyle(.white)
                .opacity(min(travel / PlayerSkipSwipe.threshold, 1) * (enabled ? 0.85 : 0.3))
                .offset(y: NowPlayingLayout.artTitleGap / 2 + 8)
                .accessibilityHidden(true)
        }
    }

    // MARK: Panel block

    private var panelBlock: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Color.clear
                    .frame(width: NowPlayingLayout.thumbSize, height: NowPlayingLayout.thumbSize)
                    .artworkSlot(.thumb)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(NowPlayingMotion.collapse) { model.panes.showMain() } }
                    .accessibilityElement()
                    .accessibilityLabel(L10n.nowPlaying)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { withAnimation(NowPlayingMotion.collapse) { model.panes.showMain() } }
                    .accessibilityIdentifier("nowPlaying.thumbnail")
                PlayerCredits(song: song, model: model, compact: true)
                    .matchedGeometryEffect(id: "credits", in: namespace)
            }
            .frame(height: NowPlayingLayout.headerHeight)
            .padding(.top, 8)
            .contentShape(Rectangle())
            .gesture(dismissDrag)
            Group {
                if model.panes.lyricsOpen {
                    // Only the portrait player puts its deck away; the landscape one leaves the
                    // panel the defaults, controls always up, as Android's side panel does.
                    LyricsPanel()
                        .environment(\.lyricsPanelChrome, model.lyricsPanelChrome)
                } else {
                    QueuePanel()
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The panel ends where the deck starts: the lyrics' loading skeleton (and a long list)
            // otherwise draws on over the scrubber and the transport. Top and bottom only: the
            // lyrics bleed sideways into the gutter (the bloom's room, Android's
            // bleedHorizontally), and a clip at the column cut the lit line's glow — and any
            // letter reaching past the edge — off on the left.
            .mask { Rectangle().padding(.horizontal, -NowPlayingLayout.gutter) }
            .transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.25)))
        }
    }

    // MARK: Gestures

    /// Sideways skips (the sleeve follows, damped); down closes the player; up pulls the queue in.
    private var artworkDrag: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .updating($artworkDragging) { _, state, _ in state = true }
            .onChanged { value in
                if dragAxis == nil {
                    dragAxis = abs(value.translation.width) > abs(value.translation.height) ? .horizontal : .vertical
                }
                switch dragAxis {
                case .horizontal:
                    model.swipeTranslation = value.translation.width
                case .vertical:
                    if value.translation.height > 0 {
                        router.nowPlaying.hold(offset: reach(value))
                        model.queuePull = 0
                    } else {
                        router.nowPlaying.hold(offset: 0)
                        model.queuePull = min(-value.translation.height / queueTravel, 1)
                    }
                case nil:
                    break
                }
            }
            .onEnded { value in
                defer { dragAxis = nil }
                switch dragAxis {
                case .horizontal:
                    endSwipe(value.translation.width)
                case .vertical:
                    endVertical(value)
                case nil:
                    break
                }
            }
    }

    /// The handle strip and the collapsed header: down closes the player; nothing else.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .updating($dismissDragging) { _, state, _ in state = true }
            .onChanged { value in
                router.nowPlaying.hold(offset: max(reach(value), 0))
            }
            .onEnded { value in
                if PlayerVerticalDrag.outcome(translation: value.translation.height, predictedEnd: value.predictedEndTranslation.height, queueTravel: 0) == .dismiss {
                    router.nowPlaying.close(velocity: value.velocity.height)
                } else {
                    router.nowPlaying.open(velocity: value.velocity.height)
                }
            }
    }

    /// A drag down's travel, scaled so the finger at the window's bottom is the player closed.
    private func reach(_ value: DragGesture.Value) -> CGFloat {
        let dock = router.nowPlaying
        return PlayerDockMotion.reach(value.translation.height, from: value.startLocation.y, toward: dock.travel, travel: dock.travel)
    }

    /// The artwork drag died without `onEnded`: the player was held part-way and the card was
    /// mid-swipe. Settle both back to rest.
    private func cancelArtworkDrag() {
        guard dragAxis != nil else { return }
        dragAxis = nil
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
            model.swipeTranslation = 0
            model.queuePull = 0
        }
        router.nowPlaying.abandonHold(settlingOpen: true)
    }

    private var queueTravel: CGFloat {
        max(sleeveFrame.height - NowPlayingLayout.thumbSize, 1)
    }

    private func endSwipe(_ translation: CGFloat) {
        switch PlayerSkipSwipe.outcome(translation: translation, controlsLocked: player.controlsLocked, rightToLeft: layoutDirection == .rightToLeft) {
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

    private func endVertical(_ value: DragGesture.Value) {
        switch PlayerVerticalDrag.outcome(translation: value.translation.height, predictedEnd: value.predictedEndTranslation.height, queueTravel: queueTravel) {
        case .dismiss:
            router.nowPlaying.close(velocity: value.velocity.height)
        case .openQueue:
            Haptics.shared.play(.expand)
            withAnimation(NowPlayingMotion.collapse) {
                model.queuePull = 0
                model.panes.openQueue()
            }
        case .none:
            router.nowPlaying.open(velocity: value.velocity.height)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { model.queuePull = 0 }
        }
    }

    // MARK: Actions

    private func openPlaybackOrigin() {
        PlayerPlaybackOrigin.open(song: song, player: player, router: router, model: model)
    }

    /// Frames off a playing clip re-tint the mesh, while the mesh is what's on screen.
    private func canvasFrameHandler(main: Bool) -> ((ArtworkPixels) -> Void)? {
        guard main, !settings.legacyMeshGradient else { return nil }
        let mesh = model.mesh
        return { frame in Task { await mesh.receiveCanvasFrame(frame) } }
    }
}

// MARK: - Deck motion

private extension AnyTransition {
    /// The deck going and coming under the lyrics (Android's `SlidingPlayerDeck`).
    static var playerDeckSlide: AnyTransition {
        .modifier(active: PlayerDeckReveal(reveal: 0), identity: PlayerDeckReveal(reveal: 1))
    }
}

/// One value owns both the deck's pixels and the room it takes: the deck reports that share of its
/// natural height and is drawn from its top, so its top slides down off the foot of the screen
/// while the panel above takes the freed height in step. A slide alone kept the full height until
/// the last frame; a slide and a resize as two motions drifted apart.
private struct PlayerDeckReveal: ViewModifier, Animatable {
    var reveal: CGFloat

    var animatableData: CGFloat {
        get { reveal }
        set { reveal = newValue }
    }

    func body(content: Content) -> some View {
        let layout = PlayerDeckRevealLayout(reveal: reveal)
        return layout { content }
    }
}

private struct PlayerDeckRevealLayout: Layout {
    var reveal: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let deck = subviews.first else { return .zero }
        let size = deck.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: (size.height * min(max(reveal, 0), 1)).rounded())
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let deck = subviews.first else { return }
        let size = deck.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        // No translation of its own: the shrinking frame moves the deck's top.
        deck.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}
