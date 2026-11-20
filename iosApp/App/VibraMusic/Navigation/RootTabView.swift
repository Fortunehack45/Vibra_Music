import VibraMusicCore
import SwiftUI

// Ports the scaffold of MainActivity.kt: four tabs (FloatingBottomBar), each with its own page
// stack, the mini player riding above the tab bar, the queue-action toast, sheets over everything,
// and Now Playing rising from the mini player.

/// The app's tab shell.
struct RootTabView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PlayerController.self) private var player
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(LikeState.self) private var likeState
    @Environment(SearchHistory.self) private var searchHistory
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var downloadsReady = false

    var body: some View {
        @Bindable var router = router
        TabView(selection: tabSelection) {
            ForEach(AppTab.allCases) { tab in
                TabStack(tab: tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        .sheet(item: $router.sheet) { sheet in
            presented(SheetDestination(sheet: sheet))
        }
        .fullScreenCover(isPresented: router.nowPlaying.presentation) {
            // Not themed: the player is always dark, and a forced Light theme from here would
            // compete with its own `.preferredColorScheme(.dark)`.
            presented(NowPlayingScreen(), themed: false)
                // The tabs stay drawn under the player, so pulling it down shows them.
                .presentationBackground(.clear)
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height + $0.safeAreaInsets.top + $0.safeAreaInsets.bottom }) {
            router.nowPlaying.travel = $0
        }
        .onChange(of: player.currentSong == nil) { _, nothingLoaded in
            // The queue was cleared under an open player.
            if nothingLoaded { router.nowPlaying.close() }
        }
        .environment(\.downloadsReady, downloadsReady)
        // The account menu's answer for the identity requests act as (MainViewModel's
        // `loadAccount` after every identity change): the top bar's photo and the account card.
        .task(id: model.accounts.listenerKey) {
            guard model.accounts.isSignedIn, model.accounts.account == nil else { return }
            await model.accounts.refreshAccount()
        }
        .task {
            // AppModel opens the download manager a moment after launch, off the first frame; the
            // top bar's batch indicator reads it only after that.
            try? await Task.sleep(for: .seconds(2.5))
            downloadsReady = true
        }
        #if DEBUG
        .task { openAccountDebugTarget() }
        .dockProbe()
        #endif
    }

    /// A sheet or cover hung from the TabView, given the environment this view reads. On a Mac
    /// (Catalyst) such a presentation does not inherit it, and its first view reading `AppModel`
    /// stops the app. Passed on from what is here rather than rebuilt from `AppModel`, so a host
    /// that wires its own player or settings keeps them.
    private func presented<Content: View>(_ content: Content, themed: Bool = true) -> some View {
        content
            .environment(model)
            .environment(router)
            .environment(player)
            .environment(settings)
            .environment(likeState)
            .environment(searchHistory)
            .environment(\.locale, locale)
            .environment(\.layoutDirection, layoutDirection)
            // Light and Dark force the theme on presented screens too (Theme.kt).
            .preferredColorScheme(themed ? settings.themeMode.colorScheme : nil)
    }

    #if DEBUG
    /// `-accountOpen …` (AccountDebugLaunch): the account pages open on the Home tab, stacked the
    /// way they are reached (Settings → Account & integrations → Discord).
    private func openAccountDebugTarget() {
        switch AccountDebugLaunch.target {
        case .account, .listenBrainzToken, .lastfmLogin:
            router.open(.settings)
            router.open(.account)
        case .discord, .discordToken, .discordStatus, .discordLogin:
            router.open(.settings)
            router.open(.account)
            router.open(.discord)
        case .profiles: router.present(.profileSwitcher)
        case .signIn: router.present(.googleSignIn)
        case .library: router.selectedTab = .library
        case nil: break
        }
    }
    #endif

    /// Goes through the router so re-selecting a tab pops it to its root and the Search tab
    /// focuses its field.
    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { router.selectedTab },
            set: { tab in
                if tab != router.selectedTab { Haptics.shared.play(.select) }
                router.select(tab)
            }
        )
    }
}

/// One tab: its root screen in a NavigationStack over the router's path for it, with the mini
/// player and the queue notice inset above the tab bar so every page scrolls clear of them.
struct TabStack: View {
    let tab: AppTab
    @Environment(AppRouter.self) private var router

    var body: some View {
        NavigationStack(path: pathBinding) {
            root
                .appTopBar(TopBarPlacement(tab: tab, route: nil, path: router.path(for: tab)))
                .navigationDestination(for: AppRoute.self) { route in
                    RouteDestination(route: route)
                        .appTopBar(TopBarPlacement(tab: tab, route: route, path: router.path(for: tab)))
                }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomAccessory(tab: tab)
        }
    }

    private var pathBinding: Binding<[AppRoute]> {
        Binding(get: { router.path(for: tab) }, set: { router.setPath($0, for: tab) })
    }

    @ViewBuilder
    private var root: some View {
        switch tab {
        case .home: HomeScreen()
        case .explore: ExploreScreen()
        case .library: LibraryScreen()
        case .search: SearchScreen()
        }
    }
}

/// The queue notice and the mini player, stacked above the tab bar.
private struct BottomAccessory: View {
    let tab: AppTab
    @Environment(PlayerController.self) private var player

    var body: some View {
        VStack(spacing: 8) {
            if let notice = player.notice {
                QueueNoticeView(notice: notice)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: notice.id) {
                        try? await Task.sleep(for: .seconds(2.5))
                        guard player.notice?.id == notice.id else { return }
                        withAnimation(.easeOut(duration: 0.25)) { player.notice = nil }
                    }
            }
            if player.currentSong != nil {
                MiniPlayer(tab: tab)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, player.currentSong == nil && player.notice == nil ? 0 : 8)
        .animation(.spring(duration: 0.3), value: player.notice?.id)
        .animation(.spring(duration: 0.3), value: player.currentSong == nil)
    }
}

/// The screen for a pushed route.
struct RouteDestination: View {
    let route: AppRoute

    var body: some View {
        switch route {
        case .album(let browseId, let seed), .playlist(let browseId, let seed):
            AlbumPlaylistScreen(browseId: browseId, seed: seed)
        case .artist(let browseId, let seed):
            ArtistScreen(browseId: browseId, seed: seed)
        case .moodGenre(let moodGenre):
            MoodGenreScreen(moodGenre: moodGenre)
        case .history:
            HistoryScreen()
        case .offlineBackup:
            OfflineBackupScreen()
        case .folder(let folder):
            DownloadsScreen(folder: folder)
        case .networkLibrary(let kind):
            NetworkLibraryScreen(kind: kind)
        case .settings:
            SettingsScreen()
        case .equalizer:
            EqualizerScreen()
        case .sources:
            SourcesScreen()
        case .account:
            AccountScreen()
        case .discord:
            DiscordScreen()
        case .listenTogether:
            ListenTogetherScreen()
        case .replay:
            ReplayScreen()
        case .libraryShowAll(let browseId, let title):
            LibraryShowAllScreen(browseId: browseId, title: title)
        }
    }
}

/// The view for a sheet.
struct SheetDestination: View {
    let sheet: AppSheet

    var body: some View {
        switch sheet {
        case .songActions(let song):
            SongActionsSheet(song: song)
                .presentationDetents([.medium, .large])
        case .browseActions(let item):
            BrowseActionsSheet(item: item)
                .presentationDetents([.medium, .large])
        case .playlistPicker(let songs):
            PlaylistPickerSheet(songs: songs)
                .presentationDetents([.medium, .large])
        case .downloadManager:
            DownloadManagerSheet()
                .presentationDetents([.medium, .large])
        case .lyricsSources:
            LyricsSourcesSheet()
        case .lyricsProvider:
            LyricsProviderSheet()
                .presentationDetents([.medium, .large])
        case .lyricsOffset:
            LyricsOffsetSheet()
                .presentationDetents([.medium])
        case .translationLanguage:
            TranslationLanguageSheet()
        case .profileSwitcher:
            ProfileSwitcher()
                .presentationDetents([.medium, .large])
        case .googleSignIn:
            // Android covers the whole app; a full-height sheet is the iOS form of an in-app
            // sign-in page, and swiping it down is the back gesture that closed Android's.
            GoogleSignInScreen()
                .presentationDetents([.large])
        case .partyInvite:
            NavigationStack { ListenTogetherScreen() }
        }
    }
}
