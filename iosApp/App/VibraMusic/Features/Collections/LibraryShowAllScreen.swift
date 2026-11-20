import VibraMusicCore
import InnerTube
import PlaybackQueue
import SwiftUI

/// A shelf's "Show all" (ports LibraryScreen.kt's LibraryGridPage, with the sort button
/// MainActivity.kt puts in the bar on this page).
///
/// The same cards, at the grid width (as many columns as fit, two to five), run down the screen.
/// Pins are re-read live, so a pin toggled from this page's own long-press menu moves the card at
/// once; an explicit sort outranks the pins and orders the whole grid. The Playlists shelf keeps its
/// New playlist tile at the head of the grid.
///
/// `browseId` is a Library shelf's key (`LibraryShelves.key(for:)`), read live from the library;
/// any other id — a Home shelf's "more" — is fetched as a feed of cards.
struct LibraryShowAllScreen: View {
    let browseId: String
    let title: String

    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @State private var remote: LoadState<[ShelfItem]> = .loading

    private var store: CollectionsStore { CollectionsStore.shared(for: model) }

    private var isLibraryShelf: Bool { browseId.hasPrefix(LibraryShelves.keyPrefix) }
    private var shelfTitle: String { String(browseId.dropFirst(LibraryShelves.keyPrefix.count)) }
    private var isPlaylists: Bool { isLibraryShelf && shelfTitle == YTMusicRepository.playlistsShelfTitle }

    /// The shelf as it stands now: the library's (or the on-device one), not a snapshot.
    private var shelf: LoadState<HomeShelf> {
        guard isLibraryShelf else {
            return remote.map { HomeShelf(title: title, items: $0) }
        }
        if shelfTitle == L10n.onDevice {
            return .success(LibraryShelves.onDevice(settings: settings, downloadedPlaylists: store.service.downloadedPlaylists))
        }
        switch store.library {
        case .success(let page):
            return .success(page.shelves.first { $0.title == shelfTitle } ?? HomeShelf(title: shelfTitle, items: []))
        case .loading: return .loading
        case .error(let message): return .error(message)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let available = proxy.size.width - CollectionsMetrics.gutter * 2
            let count = CollectionsMetrics.gridColumns(available: available)
            let columns = Array(repeating: GridItem(.flexible(), spacing: CollectionsMetrics.gridSpacing, alignment: .top), count: count)
            ScrollView {
                switch shelf {
                case .loading:
                    ListSkeleton()
                case .error(let message):
                    MessageState(message: message, actionLabel: L10n.retry) { Task { await reload() } }
                case .success(let loaded):
                    let sorted = loaded.pinnedFirst(settings.pinnedPlaylists).sortedForLibrary(settings.librarySort)
                    LazyVGrid(columns: columns, spacing: 20) {
                        if isPlaylists {
                            NewShelfCard(label: L10n.newPlaylist, subtitle: L10n.savedToYoutubeMusic, width: nil) {
                                model.router.present(.playlistPicker([]))
                            }
                        }
                        ForEach(Array(sorted.items.enumerated()), id: \.offset) { index, item in
                            LibraryShelfCard(item: item, width: nil, isPinned: item.browseId.map(settings.pinnedPlaylists.contains) ?? false)
                                .onTapGesture { open(item) }
                                .onLongPressGesture(minimumDuration: 0.4) { longPress(item) }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityIdentifier("libraryCard")
                                .prefetchingCovers(after: index, in: sorted.items, pixels: ArtworkSize.card) { [$0.thumbnailUrl] }
                        }
                    }
                    .padding(.horizontal, CollectionsMetrics.gutter)
                    .padding(.vertical, 12)
                }
            }
            .collectionsListBottomInset()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { if !isLibraryShelf, remote.isLoading { await reload() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.libraryShowAll")
    }

    private func reload() async {
        guard !isLibraryShelf else {
            await store.loadLibrary()
            return
        }
        remote = .loading
        do {
            let items = try await store.service.shelfItems(browseId)
            remote = items.isEmpty ? .error(L10n.noTracksHere) : .success(items)
        } catch {
            remote = .error(error.localizedDescription)
        }
    }

    private func open(_ item: ShelfItem) {
        if let videoId = item.videoId, !videoId.isEmpty {
            // A song card on a Home shelf's page starts a station off itself, as on Home.
            let song = Song(videoId: videoId, title: item.title, artist: InnerTubeParser.artistFromSubtitle(item.subtitle),
                            thumbnailUrl: item.thumbnailUrl)
            model.player.playSong(song, source: QueueSource(title: title, type: .home))
            return
        }
        guard let browse = item.asBrowseItem() else { return }
        model.router.open(AppRoute.browse(browse.browseId, seed: browse))
    }

    private func longPress(_ item: ShelfItem) {
        if let videoId = item.videoId, !videoId.isEmpty {
            model.router.present(.songActions(Song(videoId: videoId, title: item.title,
                                                   artist: InnerTubeParser.artistFromSubtitle(item.subtitle), thumbnailUrl: item.thumbnailUrl)))
            return
        }
        guard let browse = item.asBrowseItem(), browse.type != .artist else { return }
        Haptics.shared.play(.tap)
        model.router.present(.browseActions(browse))
    }
}
