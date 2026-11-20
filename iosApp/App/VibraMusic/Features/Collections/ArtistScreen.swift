import VibraMusicCore
import InnerTube
import PlaybackQueue
import SwiftUI
import Theming

/// An artist page (ports ui/screens/DetailScreen.kt's artist half, placed the way MainActivity.kt
/// places it).
///
/// The photo across the top with the name under it; the subscriber and monthly-listener chips;
/// Subscribe (signed in, where the header offers it), the labelled Play pill and Shuffle; "About the
/// artist"; Top songs — up to twenty, paged sideways four to a column; then each release shelf
/// (Albums, Singles & EPs…) capped at five cards with "Show all" opening the whole shelf as a grid.
struct ArtistScreen: View {
    let browseId: String
    let seed: BrowseItem?

    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player
    @Environment(AppSettings.self) private var settings
    @State private var opened = false
    @State private var scrolled = false
    @State private var activeShelf: HomeShelf?

    private var store: CollectionsStore { CollectionsStore.shared(for: model) }

    private var page: DetailPage {
        store.page(browseId) ?? DetailPage(
            browseId: browseId, title: seed?.title ?? "", subtitle: seed?.subtitle ?? "",
            thumbnailUrl: seed?.thumbnailUrl, songs: .loading, type: .artist
        )
    }

    var body: some View {
        let page = page
        ArtworkPaletteReader(artwork: page.thumbnailUrl) { palette in
            GeometryReader { proxy in
                content(page: page, palette: palette, size: proxy.size)
            }
            // Outside the scroll view, so the header's reading moves as the page scrolls.
            .coordinateSpace(name: "artist")
            .background(ArtworkWash(palette: palette))
            .navigationDestination(item: $activeShelf) { shelf in
                ArtistShelfGridPage(shelf: shelf, palette: palette, onOpen: open, onLongPress: longPress)
                    .navigationTitle(shelf.title)
            }
        }
        .navigationTitle(scrolled ? page.title : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(scrolled ? .visible : .hidden, for: .navigationBar)
        .task {
            guard !opened else { return }
            opened = true
            await store.openPage(browseId, seed: seed, type: .artist)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.artist")
    }

    @ViewBuilder
    private func content(page: DetailPage, palette: ArtworkPalette, size: CGSize) -> some View {
        let artHeight = detailArtHeight(size: size, isArtist: true)
        let songs = page.songs.value ?? []
        ScrollView {
            // The header outside the lazy stack, so its scroll reading survives it going out of
            // sight (see AlbumPlaylistScreen).
            VStack(spacing: 0) {
            header(page: page, palette: palette, artHeight: artHeight)
            LazyVStack(spacing: 0) {
                if page.subscriberCountText != nil || page.monthlyListenerCount != nil {
                    statsRow(page: page, palette: palette)
                }
                if !songs.isEmpty {
                    actionRow(page: page, palette: palette, songs: songs)
                        // Halved when About follows directly; its own top inset makes up the rest.
                        .padding(.bottom, (page.description ?? "").isEmpty ? 22 : 11)
                }
                if let description = page.description, !description.isEmpty {
                    AboutSection(title: L10n.aboutArtist, text: description, palette: palette)
                }
                switch page.songs {
                case .loading:
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(0..<4, id: \.self) { _ in SongRowSkeleton() }
                        ShelfSkeleton()
                    }
                case .error(let message):
                    MessageState(message: message, textColor: palette.onBackgroundVariantColor)
                case .success(let all):
                    topSongs(CollectionsLimits.topSongs(of: all), page: page, palette: palette, width: size.width)
                }
                ForEach(Array(page.sections.enumerated()), id: \.offset) { _, shelf in
                    releaseShelf(shelf, palette: palette)
                        .padding(.top, 22)
                }
            }
            }
        }
        .refreshable {
            await store.openPage(browseId, seed: seed, type: .artist)
        }
        .collectionsListBottomInset()
        .ignoresSafeArea(edges: .top)
    }

    private func header(page: DetailPage, palette: ArtworkPalette, artHeight: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            DetailArtworkHeaderBackground(artwork: page.thumbnailUrl, palette: palette, artHeight: artHeight,
                                          reduceBlur: settings.reduceDynamicBlur)
            Text(page.title)
                .font(CollectionsType.display)
                .foregroundStyle(palette.onBackgroundColor)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, CollectionsMetrics.headerGutter)
                .padding(.top, 14)
                // Half the top inset: the chips (or the actions) sit closer under the name than the
                // name sits under the photo.
                .padding(.bottom, 7)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("detail.title")
        }
        // Where the header sits against the page: past the foot of the artwork, its title is under
        // the bar and the bar takes it (MainActivity's `detailScrolled`). Read as geometry rather
        // than through a preference, which a scroll view does not re-send as it scrolls.
        .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named("artist")).minY }) { minY in
            guard artHeight > 0 else { return }
            let now = -minY > artHeight - 40
            if now != scrolled { withAnimation(.easeInOut(duration: 0.2)) { scrolled = now } }
        }
    }

    private func statsRow(page: DetailPage, palette: ArtworkPalette) -> some View {
        HStack(spacing: 8) {
            if let subscribers = page.subscriberCountText {
                StatChip(symbol: "person.fill", text: L10n.subscribers(DetailText.leadingNumber(subscribers)), palette: palette)
            }
            if let listeners = page.monthlyListenerCount {
                StatChip(symbol: "waveform", text: L10n.monthlyListeners(DetailText.leadingNumber(listeners)), palette: palette)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, CollectionsMetrics.gutter)
        .padding(.bottom, 14)
    }

    private func actionRow(page: DetailPage, palette: ArtworkPalette, songs: [Song]) -> some View {
        let subscription = store.service.isSignedIn ? page.subscription : nil
        return HStack(spacing: 10) {
            // Subscribing sits where saving does on a release, with the same pair of icons.
            if let subscription {
                CircleIconButton(symbol: subscription.subscribed ? AppSymbol.check : AppSymbol.plus,
                                 label: subscription.subscribed ? L10n.unsubscribe : L10n.subscribe,
                                 haptic: subscription.subscribed ? .toggleOff : .toggleOn, identifier: "artist.subscribe") {
                    Task { await store.toggleSubscription(browseId) }
                }
            }
            PlayPill {
                player.play(songs, startAt: 0, source: source(page))
            }
            CircleIconButton(symbol: AppSymbol.shuffle, label: L10n.shuffle, haptic: .resume, identifier: "detail.shuffle") {
                player.shufflePlay(songs, source: source(page))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, CollectionsMetrics.headerGutter)
    }

    /// Twenty songs at most, four to a column, paged sideways so the release shelves stay in reach.
    private func topSongs(_ top: [Song], page: DetailPage, palette: ArtworkPalette, width: CGFloat) -> some View {
        let columns = CollectionsLimits.columns(of: top)
        // Track columns leave the next one peeking in, the cue that the grid pages sideways.
        let columnWidth = max(min(width - CollectionsMetrics.gutter * 2 - 36, 420), 240)
        return VStack(alignment: .leading, spacing: 0) {
            DetailSectionHeading(title: L10n.topSongs, palette: palette)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                        VStack(spacing: 0) {
                            ForEach(column, id: \.videoId) { song in
                                CompactSongRow(song: song, palette: palette) {
                                    player.play(top, startAt: top.firstIndex(of: song) ?? 0, source: source(page))
                                } onMore: {
                                    model.router.present(.songActions(song))
                                }
                            }
                        }
                        .frame(width: columnWidth)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, CollectionsMetrics.gutter)
            }
            .scrollTargetBehavior(.viewAligned)
            .accessibilityIdentifier("artist.topSongs")
        }
    }

    private func releaseShelf(_ shelf: HomeShelf, palette: ArtworkPalette) -> some View {
        let (items, canShowAll) = CollectionsLimits.releaseRow(shelf.items)
        return VStack(alignment: .leading, spacing: 0) {
            DetailSectionHeading(title: shelf.title, palette: palette, onShowAll: canShowAll ? { activeShelf = shelf } : nil)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        SectionCard(item: item, palette: palette)
                            .onTapGesture { open(item) }
                            .onLongPressGesture(minimumDuration: 0.4) { longPress(item) }
                    }
                }
                .padding(.horizontal, CollectionsMetrics.gutter)
            }
        }
    }

    private func source(_ page: DetailPage) -> QueueSource {
        QueueSource(title: page.title, type: .browse, id: browseId)
    }

    private func open(_ item: ShelfItem) {
        guard let route = Self.route(for: item) else { return }
        model.router.open(route)
    }

    /// Where a card on an artist page goes (MainActivity's `onSectionItemClick`): opened as an album
    /// unless its id says otherwise — `openDetail` runs the id through `browseTypeOf` first, so a
    /// "Fans might also like" artist or a "Featured on" playlist opens as what it is.
    static func route(for item: ShelfItem) -> AppRoute? {
        guard let id = item.browseId, !id.isEmpty else { return nil }
        let seed = BrowseItem(browseId: id, title: item.title, subtitle: item.subtitle, thumbnailUrl: item.thumbnailUrl,
                              type: BrowseType.of(browseId: id, fallback: .album))
        return AppRoute.browse(id, seed: seed)
    }

    /// Holding a card: the release's menu, the same one every shelf opens; an artist card gets none.
    private func longPress(_ item: ShelfItem) {
        guard let browse = item.asBrowseItem(), browse.type != .artist else { return }
        Haptics.shared.play(.tap)
        model.router.present(.browseActions(browse))
    }
}

/// "1.2M subscribers" / "3.4M monthly listeners" (DetailScreen.kt's StatChip).
private struct StatChip: View {
    let symbol: String
    let text: String
    let palette: ArtworkPalette

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
            Text(text).font(CollectionsType.label).lineLimit(1).minimumScaleFactor(0.75)
        }
        .foregroundStyle(palette.onBackgroundVariantColor)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// A release shelf's "Show all" (DetailScreen.kt's ArtistShelfGridPage): the whole shelf as a grid,
/// on the page's own background.
struct ArtistShelfGridPage: View {
    let shelf: HomeShelf
    let palette: ArtworkPalette
    let onOpen: (ShelfItem) -> Void
    let onLongPress: (ShelfItem) -> Void

    var body: some View {
        GeometryReader { proxy in
            let available = proxy.size.width - CollectionsMetrics.gutter * 2
            let count = CollectionsMetrics.gridColumns(available: available)
            let columns = Array(repeating: GridItem(.flexible(), spacing: CollectionsMetrics.gridSpacing, alignment: .top), count: count)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(Array(shelf.items.enumerated()), id: \.offset) { _, item in
                        SectionCard(item: item, palette: palette, width: nil)
                            .onTapGesture { onOpen(item) }
                            .onLongPressGesture(minimumDuration: 0.4) { onLongPress(item) }
                    }
                }
                .padding(.horizontal, CollectionsMetrics.gutter)
                .padding(.vertical, 16)
            }
            .collectionsListBottomInset()
        }
        .background(palette.backgroundColor.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.artistShelf")
    }
}
