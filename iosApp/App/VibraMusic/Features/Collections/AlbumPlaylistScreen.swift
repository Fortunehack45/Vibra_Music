import VibraMusicCore
import Canvas
import InnerTube
import PlaybackQueue
import SwiftUI
import Theming

/// An album or playlist page (ports ui/screens/DetailScreen.kt's release half, placed the way
/// MainActivity.kt places it).
///
/// The page paints itself in the artwork's colours: the wash behind everything, the sleeve across
/// the top running up under the bar, and glass across the join so the two read as one surface.
/// Under the sleeve: the title, the credit (tap → the artist), the metadata line and the circles —
/// save to library (signed in, where YouTube offers it), Shuffle, Play, search this list, More (the
/// release's actions sheet). Then the About block (albums), the track list — filtered live by the
/// search field, reordered by the bar's sort button, album rows numbered by the sleeve — and a
/// playlist's Suggested songs with their add buttons.
struct AlbumPlaylistScreen: View {
    let browseId: String
    let seed: BrowseItem?

    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player
    @Environment(AppSettings.self) private var settings
    @State private var opened = false
    @State private var searching = false
    @State private var query = ""
    /// Whether the header has gone under the bar, read only by ``DetailBar``: it flips mid-scroll,
    /// and read here it would rebuild the whole track list each time it did.
    @State private var bar = DetailBarState()
    @State private var trackList = ViewMemo<DetailTrackList.Input, DetailTrackList>()
    /// The album's looping clip over the sleeve, when its label published one.
    @State private var canvas: CanvasArtwork?
    @FocusState private var searchFocused: Bool

    private var store: CollectionsStore { CollectionsStore.shared(for: model) }

    private var page: DetailPage {
        store.page(browseId) ?? DetailPage(
            browseId: browseId, title: seed?.title ?? "", subtitle: seed?.subtitle ?? "",
            thumbnailUrl: seed?.thumbnailUrl, songs: .loading, type: type
        )
    }

    private var type: BrowseType { BrowseType.of(browseId: browseId, fallback: seed?.type ?? .playlist) }

    var body: some View {
        let page = page
        ArtworkPaletteReader(artwork: page.thumbnailUrl) { palette in
            GeometryReader { proxy in
                content(page: page, palette: palette, size: proxy.size, topInset: proxy.safeAreaInsets.top,
                        bottomInset: proxy.safeAreaInsets.bottom)
            }
            // Named outside the scroll view: named on it, the space scrolls with the content and the
            // header's reading never moves.
            .coordinateSpace(name: "detail")
            .background(ArtworkWash(palette: palette))
            .environment(\.colorScheme, palette.background.luminance < 0.5 ? .dark : .light)
        }
        .modifier(DetailBar(state: bar, title: page.title))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !opened else { return }
            opened = true
            await store.openPage(browseId, seed: seed, type: type)
        }
        .task(id: CanvasQuery(type: page.type, title: page.title, credit: credit(of: page), enabled: canvasAllowed,
                              spotifyFirst: settings.prioritizeSpotifyCanvas)) {
            await loadCanvas(page: page)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.detail")
    }

    // MARK: - Content

    @ViewBuilder
    private func content(page: DetailPage, palette: ArtworkPalette, size: CGSize, topInset: CGFloat, bottomInset: CGFloat) -> some View {
        let artHeight = detailArtHeight(size: size, isArtist: false)
        let tracks = trackList.value(for: DetailTrackList.Input(songs: page.songs.value ?? [], suggested: page.suggestedSongs,
                                                                sort: settings.detailSongSort(for: browseId), query: query),
                                     DetailTrackList.init)
        let suggested = tracks.suggested
        // Every row qualifies on a page that is itself a reading of this device, where the badge
        // would say nothing.
        let downloadedTint: Color? = LocalBrowseID.isLocal(browseId) ? nil : palette.accentColor

        ScrollViewReader { reader in
            ScrollView {
                // The header sits outside the lazy stack: it reports how far the page has scrolled,
                // and a lazy stack drops it once it is out of sight — which put the bar's title
                // back to hidden just as the header's own title had gone under it.
                VStack(spacing: 0) {
                header(page: page, palette: palette, artHeight: artHeight, songs: tracks.sorted, playtime: tracks.playtime)
                    .id("header")
                LazyVStack(spacing: 0) {
                    if searching {
                        DetailSearchField(query: $query, focused: $searchFocused, palette: palette, onClose: closeSearch)
                            .id("search")
                    }
                    if page.type == .album, let description = page.description, !description.isEmpty {
                        AboutSection(title: L10n.aboutAlbum, text: description, palette: palette)
                            .padding(.bottom, 12)
                    }
                    trackRows(page: page, palette: palette, queue: tracks.rows, numbers: tracks.numbers, downloadedTint: downloadedTint)
                    if !suggested.isEmpty {
                        DetailSectionHeading(title: L10n.suggested, palette: palette)
                        ForEach(Array(suggested.enumerated()), id: \.element.videoId) { index, song in
                            SuggestedSongRow(song: song, palette: palette) {
                                player.play(suggested, startAt: index, source: source(page))
                            } onMore: {
                                openSongMenu(song, page: page)
                            } onAdd: {
                                Task { await store.addSuggestedSong(browseId, song: song) }
                            }
                            .prefetchingCovers(after: index, in: suggested) { [$0.thumbnailUrl] }
                            if index < suggested.count - 1 { RowDivider(color: palette.dividerColor) }
                        }
                    }
                }
                }
                .padding(.bottom, detailBottomInset(bottomInset: bottomInset, isPlaying: player.currentSong != nil))
            }
            .refreshable {
                await store.openPage(browseId, seed: seed, type: type)
            }
            .ignoresSafeArea(edges: .top)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: searching) { _, isSearching in
                // Opening the search carries the page up to it, so the field lands under the bar
                // with the tracks beneath it.
                guard isSearching else { return }
                searchFocused = true
                // The list runs up under the bar, so "top" would park the field beneath it: the
                // anchor is set just clear of the bar instead (Android scrolls to the item less the
                // top bar's padding).
                let viewport = size.height + topInset
                let anchor = UnitPoint(x: 0.5, y: viewport > 0 ? min(0.5, (topInset + 8) / viewport) : 0)
                withAnimation(.easeInOut(duration: 0.3)) { reader.scrollTo("search", anchor: anchor) }
            }
        }
    }

    private func header(page: DetailPage, palette: ArtworkPalette, artHeight: CGFloat, songs: [Song], playtime: String?) -> some View {
        let lines = DetailText.headerLines(subtitle: page.subtitle, type: page.type, trackCount: songs.count,
                                           playtime: playtime)
        // A browse card's subtitle sometimes omits the artist; the tracks know who it is.
        let credit = lines.credit.isEmpty ? (songs.first?.artist ?? "") : lines.credit
        let artist = songs.first
        return ZStack(alignment: .bottom) {
            DetailArtworkHeaderBackground(artwork: page.thumbnailUrl, palette: palette, artHeight: artHeight,
                                          reduceBlur: settings.reduceDynamicBlur, canvas: canvas)
            VStack(spacing: 0) {
                Text(page.title)
                    .font(CollectionsType.headline)
                    .foregroundStyle(palette.onBackgroundColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("detail.title")
                if !credit.isEmpty {
                    creditLine(credit, artist: artist, palette: palette)
                        .padding(.top, 2)
                }
                if !lines.meta.isEmpty {
                    Text(lines.meta)
                        .font(CollectionsType.labelSmall)
                        .tracking(0.7)
                        .foregroundStyle(palette.onBackgroundVariantColor)
                        .lineLimit(1)
                        .padding(.top, 5)
                }
                if !songs.isEmpty {
                    actionRow(page: page, songs: songs)
                        .padding(.top, 14)
                }
            }
            .padding(.horizontal, CollectionsMetrics.headerGutter)
            .padding(.bottom, 14)
        }
        // Where the header sits against the page: past the foot of the artwork, its title is under
        // the bar and the bar takes it (MainActivity's `detailScrolled`). Read as geometry rather
        // than through a preference, which a scroll view does not re-send as it scrolls.
        .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named("detail")).minY }) { minY in
            guard artHeight > 0 else { return }
            let now = -minY > artHeight - 40
            if now != bar.scrolled { withAnimation(.easeInOut(duration: 0.2)) { bar.scrolled = now } }
        }
    }

    @ViewBuilder
    private func creditLine(_ credit: String, artist: Song?, palette: ArtworkPalette) -> some View {
        let text = Text(credit)
            .font(CollectionsType.title)
            .foregroundStyle(palette.accentColor)
            .lineLimit(1)
        if let artist, let id = artist.artistId, !id.isEmpty {
            Button {
                model.router.open(.artist(browseId: id, seed: BrowseItem(browseId: id, title: artist.artist, subtitle: L10n.artist,
                                                                          thumbnailUrl: nil, type: .artist)))
            } label: { text }
                .buttonStyle(.plain)
                .accessibilityIdentifier("detail.credit")
        } else {
            text
        }
    }

    /// Every release action is a circle; five of them come down a size so the row stays inside the
    /// header's gutter.
    private func actionRow(page: DetailPage, songs: [Song]) -> some View {
        let library = store.service.isSignedIn ? page.library : nil
        let circles = (library == nil ? 0 : 1) + 3
        let full = circles >= 4
        let size: CGFloat = full ? 46 : 50
        return HStack(spacing: full ? 8 : 10) {
            if let library {
                // A tick, not a filled plus: the pair reads "not yet / done", which is the state.
                CircleIconButton(symbol: library.saved ? AppSymbol.check : AppSymbol.plus,
                                 label: library.saved ? L10n.removeFromLibrary : L10n.addToLibrary,
                                 size: size, haptic: library.saved ? .toggleOff : .toggleOn, identifier: "detail.library") {
                    Task { await store.toggleLibrary(browseId) }
                }
            }
            CircleIconButton(symbol: AppSymbol.shuffle, label: L10n.shuffle, size: size, haptic: .resume, identifier: "detail.shuffle") {
                player.shufflePlay(songs, source: source(page))
            }
            PlayPill(iconOnly: true, size: size) {
                player.play(songs, startAt: 0, source: source(page))
            }
            CircleIconButton(symbol: searching ? AppSymbol.close : AppSymbol.search,
                             label: searching ? L10n.closeSearch : L10n.searchThisList, size: size, identifier: "detail.search") {
                if searching { closeSearch() } else { searching = true }
            }
            CircleIconButton(symbol: AppSymbol.more, label: L10n.more, size: size, identifier: "detail.more") {
                openPageMenu(page: page, songs: songs)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func trackRows(page: DetailPage, palette: ArtworkPalette, queue: [Song], numbers: [String: Int],
                           downloadedTint: Color?) -> some View {
        switch page.songs {
        case .loading:
            ForEach(0..<8, id: \.self) { _ in SongRowSkeleton() }
        case .error(let message):
            MessageState(message: message, textColor: palette.onBackgroundVariantColor)
        case .success(let all):
            // Every row on an album carries the same sleeve, so an album numbers its rows instead.
            let numbered = page.type == .album
            if queue.isEmpty && !all.isEmpty {
                MessageState(message: L10n.nothingMatches(query), textColor: palette.onBackgroundVariantColor)
            }
            ForEach(queue.indices, id: \.self) { position in
                let song = queue[position]
                CollectionsSongRow(
                    song: numbered ? song : song.withFallbackArtwork(page.thumbnailUrl),
                    // The track's place on the release, not in what a filter or sort left.
                    trackNumber: numbered ? numbers[song.videoId] : nil,
                    subtitleColor: palette.onBackgroundVariantColor,
                    titleColor: palette.onBackgroundColor,
                    downloadedTint: downloadedTint,
                    activeTint: palette.accentColor
                ) {
                    player.play(queue, startAt: position, source: source(page))
                } onMore: {
                    openSongMenu(song, page: page)
                }
                // An album's rows are numbered and draw no cover.
                .prefetchingCovers(after: position, in: numbered ? [] : queue) {
                    [$0.withFallbackArtwork(page.thumbnailUrl).thumbnailUrl]
                }
                if position < queue.count - 1 { RowDivider(color: palette.dividerColor) }
            }
        }
    }

    // MARK: - Canvas

    private struct CanvasQuery: Equatable {
        let type: BrowseType
        let title: String
        let credit: String
        let enabled: Bool
        let spotifyFirst: Bool
    }

    /// The animated-canvas switch, with the player's Wi-Fi-only rule (Settings' "over cellular"
    /// switch) — a looping clip re-fetched on every loop is the same data cost on either page.
    private var canvasAllowed: Bool {
        CanvasPolicy.isAllowed(animatedCanvas: settings.animatedCanvas, canvasOverCellular: settings.canvasOverCellular,
                               network: model.network.status)
    }

    /// The credit line as the header shows it: the card's, or failing that the tracks' own artist.
    private func credit(of page: DetailPage) -> String {
        let lines = DetailText.headerLines(subtitle: page.subtitle, type: page.type, trackCount: page.songs.value?.count ?? 0)
        return lines.credit.isEmpty ? (page.songs.value?.first?.artist ?? "") : lines.credit
    }

    /// Animated cover art on the header, as the player has (DetailScreen.kt): albums only — a
    /// playlist's artwork is a collage, and nobody publishes a clip for one. Runs again when the
    /// credit fills in with the tracks, keeping a clip already playing if that pass finds nothing.
    private func loadCanvas(page: DetailPage) async {
        guard canvasAllowed, page.type == .album else {
            canvas = nil
            return
        }
        let credit = credit(of: page)
        // Nothing to search by until the header or the tracks have said whose album this is.
        guard !page.title.isEmpty, !credit.isEmpty else { return }
        let found = await store.service.albumCanvas(page.title, artist: credit, spotifyFirst: settings.prioritizeSpotifyCanvas)
        if let found { canvas = found }
    }

    // MARK: - Actions

    private func source(_ page: DetailPage) -> QueueSource {
        QueueSource(title: page.title, type: .browse, id: browseId)
    }

    private func closeSearch() {
        searching = false
        query = ""
        searchFocused = false
    }

    /// An album page's rows carry no album name of their own, so the page title is stamped on as
    /// they leave for the track menu or the download queue (MainActivity's `withAlbum`).
    private func withAlbum(_ song: Song, page: DetailPage) -> Song {
        guard page.type == .album, song.albumName == nil else { return song }
        var copy = song
        copy.albumName = page.title
        return copy
    }

    private func openSongMenu(_ song: Song, page: DetailPage) {
        model.router.present(.songActions(withAlbum(song, page: page)))
    }

    private func openPageMenu(page: DetailPage, songs: [Song]) {
        store.pageMenuContext = (browseId, songs.map { withAlbum($0, page: page) })
        model.router.present(.browseActions(BrowseItem(browseId: browseId, title: page.title, subtitle: page.subtitle,
                                                       thumbnailUrl: page.thumbnailUrl, type: page.type)))
    }
}

/// Whether an album or playlist page has scrolled its header under the bar.
@MainActor
@Observable
final class DetailBarState {
    var scrolled = false
}

/// The bar's title and background, which come in once the header's own title has gone under it
/// (MainActivity's `detailScrolled`). A modifier of its own so the flag is read here alone: the
/// page's body, and the track list it builds, stay put as the flag flips.
private struct DetailBar: ViewModifier {
    let state: DetailBarState
    let title: String

    func body(content: Content) -> some View {
        content
            .navigationTitle(state.scrolled ? title : "")
            .toolbarBackground(state.scrolled ? .visible : .hidden, for: .navigationBar)
    }
}

/// The filter box under the header while the search circle is lit (DetailScreen.kt's
/// DetailSearchField): live rather than submit-on-enter, since the list is already in memory. Its
/// ✕ clears the text, or closes the search when there is nothing to clear.
struct DetailSearchField: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    let palette: ArtworkPalette
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: AppSymbol.search)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.onBackgroundVariantColor)
            TextField(L10n.searchThisList, text: $query)
                .font(CollectionsType.body)
                .foregroundStyle(palette.onBackgroundColor)
                .tint(palette.accentColor)
                .focused(focused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityIdentifier("detail.searchField")
            Button {
                if query.isEmpty { onClose() } else { query = "" }
            } label: {
                Image(systemName: AppSymbol.close)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.onBackgroundVariantColor)
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(query.isEmpty ? L10n.closeSearch : L10n.clearSearch)
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
        .padding(.horizontal, CollectionsMetrics.headerGutter)
        .padding(.bottom, 10)
    }
}

extension Song {
    /// A playlist row with no cover of its own borrows the page's.
    func withFallbackArtwork(_ fallback: String?) -> Song {
        guard thumbnailUrl == nil, let fallback else { return self }
        var copy = self
        copy.thumbnailUrl = fallback
        return copy
    }
}
