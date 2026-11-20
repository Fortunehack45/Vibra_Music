import VibraMusicCore
import InnerTube
import PlaybackQueue
import SwiftUI

/// Search (ports ui/screens/SearchScreen.kt and its wiring in MainActivity.kt).
///
/// The field and, once there are results, the filter pills (All, Songs, Videos, Albums, Artists,
/// Playlists) stay pinned under the bar; everything else scrolls beneath them:
/// - while typing: up to three completions (tap to search one, the arrow to put it in the field
///   and keep typing), then a divider and live results;
/// - with nothing searched: recent searches (up to 20, each removable, Clear for all), or a line
///   saying what to do;
/// - results: on All, the top-result card with Play and Playlist, then the hits grouped as Songs,
///   Artists, Albums, Playlists and More; on any other filter, one list. More load at the end.
///
/// A song starts a one-off from itself (Android's `playRadio`) and is remembered as a recent
/// search; swiping a song row queues it (play next or add to queue, per the setting); holding it
/// opens the song menu. An album, playlist or artist opens its page; holding an album or playlist
/// opens its menu.
struct SearchScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(SearchHistory.self) private var history
    @State private var search = SearchModel()
    @State private var pendingPlay: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                SearchField(text: queryBinding, focus: $fieldFocused) { search.submit() }
                    .padding(.horizontal, BrowseMetrics.gutter)
                    .padding(.bottom, 4)
                if search.showsFilters {
                    SearchFilterPills(filter: search.filter) { search.onFilterChange($0) }
                }
            }
            .padding(.top, 4)
            ScrollViewReader { proxy in
                ScrollView {
                    Color.clear.frame(height: 0).id(Self.topAnchor)
                    content
                        .padding(.bottom, 16)
                }
                // Android keeps the keyboard up while the list under it changes (recent searches
                // give way to completions as you type); it never drops on a scroll or a content
                // swap, so neither does this.
                .onChange(of: search.scrollResetTrigger) { _, _ in proxy.scrollTo(Self.topAnchor, anchor: .top) }
            }
        }
        // Search has no big in-list heading to hand its title to — the field takes that space —
        // so the bar's title is always up, as on Android.
        .navigationTitle(L10n.search)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if search.catalog == nil { search.catalog = model.repository }
            #if DEBUG
            if let text = BrowseDebugLaunch.take("typing:") { search.onQueryChange(text) }
            #endif
        }
        // Tapping the Search tab focuses the field and brings the keyboard up. `.task(id:)` runs
        // on appear — with the request the tab tap already made — as well as on every later tap,
        // the way Android's `LaunchedEffect(focusRequested)` does. `.onChange` alone missed the
        // first tap: the screen is created in the same update, so the request looked unchanged.
        .task(id: model.router.searchFocusRequest) { fieldFocused = true }
        .task(id: model.router.pendingSearch) { consumePendingSearch() }
        .onChange(of: search.results) { _, _ in playPendingIfReady() }
        // The real answer can be the very rows already up as a preview, so `results` doesn't change.
        .onChange(of: search.resultsAreFinal) { _, _ in playPendingIfReady() }
        // A play handed over for a query is dropped once the field moves to another.
        .onChange(of: search.query) { _, query in
            if pendingPlay != query { pendingPlay = nil }
        }
        // A container: without this the screen identifier lands on every child and hides theirs.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.search")
    }

    private static let topAnchor = "search.top"

    private var queryBinding: Binding<String> {
        Binding(get: { search.query }, set: { search.onQueryChange($0) })
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        // One container per phase (see HomeScreen: rows of different branches sharing ids in one
        // lazy stack keep drawing the old branch).
        if search.isSuggesting {
            suggestionList
        } else if let results = search.results {
            switch results {
            case .loading:
                VStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { BrowseRowSkeleton(index: $0, circular: search.filter == .artists) }
                }
            case .error(let message):
                BrowseMessage(message: message)
            case .success(let rows):
                resultList(rows)
            }
        } else if history.recent.isEmpty {
            BrowseMessage(message: L10n.searchEmpty)
        } else {
            recentSearches
        }
    }

    private var suggestionList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 8)
            ForEach(search.visibleSuggestions, id: \.self) { term in
                SuggestionRow(term: term) {
                    // Picking one is done typing: the keyboard comes down with it.
                    fieldFocused = false
                    search.searchFor(term)
                } onFill: {
                    search.onQueryChange(term)
                }
            }
            if search.showsTypeahead {
                Divider()
                    .padding(.horizontal, BrowseMetrics.gutter)
                ForEach(search.typeahead) { row in
                    switch row {
                    case .topTrack(let song), .track(let song):
                        TypeaheadSongRow(song: song) { playSong(song) } onMenu: {
                            model.router.present(.songActions(song))
                        }
                    case .browse(let item):
                        BrowseResultRow(item: item, onTap: { openBrowse(item) }, onMenu: nil)
                    }
                }
            }
        }
    }

    private var recentSearches: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.recentSearches)
                    .font(BrowseFont.headline)
                    .accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(L10n.clear) { history.clear() }
                    .font(BrowseFont.title)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("search.clearHistory")
            }
            .padding(.horizontal, BrowseMetrics.gutter)
            .padding(.vertical, 10)
            ForEach(history.recent) { entity in
                RecentSearchRow(entity: entity) { openHistory(entity) } onRemove: {
                    history.remove(id: entity.id)
                }
            }
        }
    }

    private func resultList(_ rows: [SearchResult]) -> some View {
        let top = rows.lazy.compactMap { row -> Song? in
            if case .topTrack(let song) = row { return song } else { return nil }
        }.first
        let sections = SearchSection.sections(rows, filter: search.filter)
        let ordered = sections.flatMap(\.rows)
        let total = ordered.count
        return LazyVStack(alignment: .leading, spacing: 0) {
            if search.filter == .all, let top {
                TopResultCard(song: top) { playSong(top) } onPlaylist: {
                    history.record(SearchHistoryEntity(song: top))
                    model.router.present(.playlistPicker([top]))
                } onMenu: {
                    model.router.present(.songActions(top))
                }
            }
            ForEach(Array(sections.enumerated()), id: \.element.id) { sectionIndex, section in
                if let title = section.title {
                    Text(title)
                        .font(BrowseFont.titleSmall)
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, BrowseMetrics.gutter)
                        .padding(.top, 16)
                        .padding(.bottom, 6)
                }
                let before = sections[..<sectionIndex].reduce(0) { $0 + $1.rows.count }
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                    resultRow(row)
                        .onAppear { search.rowAppeared(at: before + index, of: total) }
                        .prefetchingCovers(after: before + index, in: ordered, covers: Self.cover)
                    if index < section.rows.count - 1 {
                        Divider().padding(.leading, BrowseMetrics.rowDividerInset)
                    }
                }
            }
            if search.loadingMore {
                ForEach(0..<3, id: \.self) { BrowseRowSkeleton(index: $0, circular: search.filter == .artists) }
            }
        }
    }

    @ViewBuilder
    private func resultRow(_ row: SearchResult) -> some View {
        switch row {
        case .topTrack:
            EmptyView()
        case .track(let song):
            // The shared row: tap, the More button, long-press → song menu, swipe → queue.
            SongRow(song: song) { playSong(song) }
        case .browse(let item):
            // Holding an artist does nothing, as on Android.
            BrowseResultRow(item: item, onTap: { openBrowse(item) },
                            onMenu: item.type == .artist ? nil : { model.router.present(.browseActions(item)) })
        }
    }

    // MARK: - Actions

    /// The cover a result row draws; the top result is its own card.
    private static func cover(_ row: SearchResult) -> [String?] {
        switch row {
        case .topTrack: []
        case .track(let song): [song.thumbnailUrl]
        case .browse(let item): [item.thumbnailUrl]
        }
    }

    /// Search hits are alternatives to each other, not a running order: play the one tapped as a
    /// one-off and let AutoPlay carry on from it.
    private func playSong(_ song: Song) { BrowseNavigator(app: model).playSearchHit(song) }

    private func openBrowse(_ item: BrowseItem) { BrowseNavigator(app: model).openSearchHit(item) }

    private func openHistory(_ entity: SearchHistoryEntity) { BrowseNavigator(app: model).openRecent(entity) }

    /// A search handed over by a deep link or Siri: run it, and play the best match if asked.
    private func consumePendingSearch() {
        if search.catalog == nil { search.catalog = model.repository }
        guard let pending = model.router.pendingSearch else { return }
        model.router.pendingSearch = nil
        fieldFocused = false
        search.searchFromOutside(pending.query)
        pendingPlay = pending.play ? pending.query : nil
        playPendingIfReady()
    }

    private func playPendingIfReady() {
        guard let query = pendingPlay, query == search.query else { return }
        switch search.results {
        case .success(let rows):
            // A shorter query's rows shown meanwhile are not what was asked for.
            guard search.resultsAreFinal else { return }
            pendingPlay = nil
            if let first = rows.lazy.compactMap(\.song).first { playSong(first) }
        case .error:
            pendingPlay = nil
        default:
            break
        }
    }
}
