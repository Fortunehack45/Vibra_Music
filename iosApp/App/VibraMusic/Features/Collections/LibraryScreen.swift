import VibraMusicCore
import Downloads
import InnerTube
import Replay
import SwiftUI

/// The Library tab (ports ui/screens/LibraryScreen.kt, placed the way MainActivity.kt places it).
///
/// Top to bottom, as on Android: the page title; Replay — its headline cards once there is
/// listening to show, a single banner before that; the On device shelf (Downloads, Local music,
/// WebDAV, SMB, then every playlist downloaded whole); and then, signed out, the sign-in prompt —
/// or, signed in, the account's shelves: Playlists (always drawn, led by the New playlist tile,
/// pinned playlists first — Liked Music is one of its cards), Albums, Artists, Subscriptions… Each
/// row stops at five cards with "Show all" opening the rest as a grid. Holding a card opens its
/// menu; pull to refresh fetches the feed again. The History button, the download manager and the
/// account photo are the shared top bar's (Features/Account).
struct LibraryScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    private var store: CollectionsStore { CollectionsStore.shared(for: model) }

    var body: some View {
        let store = store
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ReplayEntry(cards: store.replayCards, holder: store.service.accountName,
                            memberSince: store.replayMemberSince) { _ in
                    // Android opens Replay at the tapped card's chart (the banner: the intro). The
                    // shell's route carries no landing page yet — requested change in the
                    // Collections report: `.replay(landing: page)`.
                    model.router.open(.replay)
                }
                let onDevice = LibraryShelves.onDevice(settings: settings, downloadedPlaylists: store.service.downloadedPlaylists)
                LibraryGridShelf(shelf: onDevice, onOpen: open, onLongPress: longPress) {
                    showAll(onDevice)
                }
                if !store.service.isSignedIn {
                    MessageState(message: L10n.librarySignInDescription, actionLabel: L10n.signIn) {
                        model.router.present(.googleSignIn)
                    }
                } else {
                    switch store.library {
                    case .loading:
                        ForEach(0..<3, id: \.self) { _ in ShelfSkeleton().padding(.bottom, 26) }
                    case .error(let message):
                        MessageState(message: message, actionLabel: L10n.retry) {
                            Task { await store.loadLibrary() }
                        }
                    case .success(let page):
                        accountShelves(page)
                    }
                }
            }
        }
        .collectionsListBottomInset()
        .navigationTitle(L10n.library)
        .navigationBarTitleDisplayMode(.large)
        .refreshable {
            async let replay: Void = store.loadReplay()
            if store.service.isSignedIn { await store.refreshLibrary() }
            await replay
        }
        .task(id: store.service.listenerKey) {
            await store.loadLibraryIfNeeded()
            await store.libraryShown()
        }
        .task { await store.loadReplay() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.library")
    }

    @ViewBuilder
    private func accountShelves(_ page: LibraryPage) -> some View {
        let pinned = settings.pinnedPlaylists
        let playlistsTitle = YTMusicRepository.playlistsShelfTitle
        // A fresh account has no Playlists shelf at all — and is the one most in need of the tile
        // that makes one, so the row is drawn either way.
        if !page.shelves.contains(where: { $0.title == playlistsTitle }) {
            let empty = HomeShelf(title: playlistsTitle, items: [])
            playlistShelf(empty, pinned: pinned)
        }
        ForEach(Array(page.shelves.enumerated()), id: \.element.title) { _, shelf in
            if shelf.title == playlistsTitle {
                playlistShelf(shelf.pinnedFirst(pinned), pinned: pinned)
            } else {
                LibraryGridShelf(shelf: shelf, onOpen: open, onLongPress: longPress) { showAll(shelf) }
            }
        }
    }

    /// The one shelf that can be written to: it leads with the tile that creates a playlist.
    private func playlistShelf(_ shelf: HomeShelf, pinned: [String]) -> some View {
        LibraryGridShelf(shelf: shelf, pinned: pinned, onOpen: open, onLongPress: longPress, leading: {
            NewShelfCard(label: L10n.newPlaylist, subtitle: L10n.savedToYoutubeMusic) {
                model.router.present(.playlistPicker([]))
            }
        }, onShowAll: { showAll(shelf) })
    }

    private func open(_ item: ShelfItem) {
        guard let browse = item.asBrowseItem() else { return }
        model.router.open(AppRoute.browse(browse.browseId, seed: browse))
    }

    /// Holding a card (MainActivity's `onBrowseLongPress`): the album or playlist menu. An artist is a
    /// selection of work rather than a running order, so holding one does nothing.
    private func longPress(_ item: ShelfItem) {
        guard let browse = item.asBrowseItem(), browse.type != .artist, browse.browseId != LocalBrowseID.offlineBackup else { return }
        Haptics.shared.play(.tap)
        model.router.present(.browseActions(browse))
    }

    private func showAll(_ shelf: HomeShelf) {
        model.router.open(.libraryShowAll(browseId: LibraryShelves.key(for: shelf), title: localizedLibraryShelfTitle(shelf.title)))
    }
}

/// Where the Library's shelves come from, shared with the "Show all" page.
enum LibraryShelves {
    /// "Show all" keys for the Library's own shelves; anything else a Show all page is handed is a
    /// real browse id (a Home shelf's "more").
    static let keyPrefix = "library:shelf:"

    static func key(for shelf: HomeShelf) -> String { keyPrefix + shelf.title }

    /// The On device shelf (LibraryScreen.kt): the two device folders, the two network shares
    /// (saying whether they are set up), then each playlist downloaded whole — billed with the
    /// credit it was downloaded with, which is also what its page reads its header from.
    @MainActor
    static func onDevice(settings: AppSettings, downloadedPlaylists: [SavedCollection]) -> HomeShelf {
        let remotes: [ShelfItem] = [
            ShelfItem(title: L10n.webdav, subtitle: settings.webdavUrl.isEmpty ? L10n.webdavNotConfigured : L10n.webdavSubtitle,
                      thumbnailUrl: nil, videoId: nil, browseId: LocalBrowseID.webDAV),
            ShelfItem(title: L10n.smb, subtitle: settings.smbHost.isEmpty || settings.smbShare.isEmpty ? L10n.smbNotConfigured : L10n.smbSubtitle,
                      thumbnailUrl: nil, videoId: nil, browseId: LocalBrowseID.smb),
        ]
        let playlists = downloadedPlaylists.map { playlist in
            ShelfItem(title: playlist.title, subtitle: playlist.subtitle.isEmpty ? L10n.downloadedPlaylist : playlist.subtitle,
                      thumbnailUrl: playlist.thumbnailUrl, videoId: nil, browseId: LocalBrowseID.playlistPrefix + playlist.id)
        }
        return HomeShelf(title: L10n.onDevice, items: [
            ShelfItem(title: L10n.downloads, subtitle: L10n.downloadedSongs, thumbnailUrl: nil, videoId: nil, browseId: LocalBrowseID.downloads),
            ShelfItem(title: L10n.localMusic, subtitle: L10n.audioFilesOnDevice, thumbnailUrl: nil, videoId: nil, browseId: LocalBrowseID.all),
            ShelfItem(title: DownloadsText.offlineBackup, subtitle: DownloadsText.offlineBackupSubtitle, thumbnailUrl: nil, videoId: nil,
                      browseId: LocalBrowseID.offlineBackup),
        ] + remotes + playlists)
    }
}

/// A Library shelf (LibraryScreen.kt's LibraryGridShelf): the heading with "Show all" when more
/// than five slots' worth is there, and a sideways row of at most five cards — a leading card
/// counting against the cap.
struct LibraryGridShelf<Leading: View>: View {
    let shelf: HomeShelf
    var pinned: [String] = []
    let onOpen: (ShelfItem) -> Void
    let onLongPress: (ShelfItem) -> Void
    let leading: Leading?
    let onShowAll: () -> Void

    init(shelf: HomeShelf, pinned: [String] = [], onOpen: @escaping (ShelfItem) -> Void, onLongPress: @escaping (ShelfItem) -> Void,
         @ViewBuilder leading: () -> Leading, onShowAll: @escaping () -> Void) {
        self.shelf = shelf
        self.pinned = pinned
        self.onOpen = onOpen
        self.onLongPress = onLongPress
        self.leading = leading()
        self.onShowAll = onShowAll
    }

    var body: some View {
        let row = shelf.libraryRow(hasLeadingCard: leading != nil)
        VStack(alignment: .leading, spacing: 0) {
            CollectionsSectionHeader(title: localizedLibraryShelfTitle(shelf.title), subtitle: shelf.subtitle,
                                     onShowAll: row.showsShowAll ? onShowAll : nil)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: CollectionsMetrics.gridSpacing) {
                    if let leading { leading }
                    ForEach(Array(row.items.enumerated()), id: \.offset) { _, item in
                        LibraryShelfCard(item: item, isPinned: item.browseId.map(pinned.contains) ?? false)
                            .onTapGesture { onOpen(item) }
                            .onLongPressGesture(minimumDuration: 0.4) { onLongPress(item) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityIdentifier("libraryCard")
                    }
                }
                .padding(.horizontal, CollectionsMetrics.gutter)
            }
            .scrollClipDisabled()
        }
        .padding(.bottom, 26)
        // A container, so the heading's Show all and the cards keep their own identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("libraryShelf")
    }
}

extension LibraryGridShelf where Leading == EmptyView {
    init(shelf: HomeShelf, pinned: [String] = [], onOpen: @escaping (ShelfItem) -> Void, onLongPress: @escaping (ShelfItem) -> Void,
         onShowAll: @escaping () -> Void) {
        self.shelf = shelf
        self.pinned = pinned
        self.onOpen = onOpen
        self.onLongPress = onLongPress
        self.leading = nil
        self.onShowAll = onShowAll
    }
}
