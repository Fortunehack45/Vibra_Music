import VibraMusicCore
import Downloads
import PlaybackQueue
import SwiftUI

/// Ports ui/screens/LocalMusicScreen.kt, with the callbacks MainActivity.kt handed it.
///
/// The Downloads folder, the Local Music folder and the SMB/WebDAV libraries are all this one page:
/// a flat list of tracks with Songs, Artists and Albums tabs, a filter and a sort above them. What
/// differs is where the list came from, what to say when it is empty, and — for the Downloads
/// folder only — that holding a row selects it, so the selection bar can delete or upload.
///
/// Tapping an artist or album slides its songs in inline, so the tab row stays and Back returns to
/// the grid rather than leaving the page.
struct LocalMusicView: View {
    /// The page's title, which is also what "Playing from" says.
    let title: String
    let browseId: String
    let songs: [Song]
    var collections: [DownloadedCollection] = []
    /// Shown instead of the tabs' content when there are no songs at all.
    var emptyMessage: String?
    /// The listing hasn't answered yet (a remote library).
    var isLoading = false
    /// Deletes the rows selected in the Downloads folder.
    var onDelete: (([Song]) -> Void)?
    /// Copies the selected rows to WebDAV; nil (no server) hides the action.
    var onUpload: (([Song]) -> Void)?
    var isDownloaded: (String) -> Bool = { _ in false }

    @State private var state: LocalMusicState
    /// The three tabs, kept until the songs, the sort or the filter change: a selection toggled or
    /// the playing row moving on re-runs the body, and must not sort and group the folder again.
    @State private var listings = ViewMemo<LocalMusicListing.Input, LocalMusicListing>()
    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player
    @Environment(AppRouter.self) private var router
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    init(title: String, browseId: String, songs: [Song], collections: [DownloadedCollection] = [],
         isDownloads: Bool, emptyMessage: String? = nil, isLoading: Bool = false,
         onDelete: (([Song]) -> Void)? = nil, onUpload: (([Song]) -> Void)? = nil,
         isDownloaded: @escaping (String) -> Bool = { _ in false }) {
        self.title = title
        self.browseId = browseId
        self.songs = songs
        self.collections = collections
        self.emptyMessage = emptyMessage
        self.isLoading = isLoading
        self.onDelete = onDelete
        self.onUpload = onUpload
        self.isDownloaded = isDownloaded
        _state = State(initialValue: LocalMusicState(isDownloads: isDownloads))
    }

    private var sort: LocalMusicSort {
        state.isDownloads ? settings.downloadedMusicSort : settings.localMusicSort
    }

    private var viewType: LibraryViewType {
        state.isDownloads ? settings.downloadedMusicViewType : settings.localMusicViewType
    }

    var body: some View {
        let listing = listings.value(for: LocalMusicListing.Input(songs: songs, collections: collections, sort: sort,
                                                                  query: state.query),
                                     LocalMusicListing.init(_:))
        VStack(spacing: 0) {
            Group {
                if state.isSelecting {
                    selectionBar(listing)
                } else {
                    searchBar
                }
            }
            .padding(.horizontal, AppTheme.gutter)
            .padding(.top, 6)
            .padding(.bottom, 4)
            LocalTabRow(selection: state.tab) { tab in
                if tab != state.tab { Haptics.shared.play(.select) }
                withAnimation(.snappy(duration: 0.3)) { state.select(tab) }
            }
            content(listing)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .animation(.snappy(duration: 0.25), value: state.isSelecting)
        .background(Color(.systemBackground))
        #if DEBUG
        .task(id: songs.count) { applyDebugTargets(listing) }
        #endif
        // Android's BackHandlers: Back clears a selection, then leaves a drill-down, before it
        // leaves the page. The system back button can't be intercepted, so it is swapped for one
        // that asks the page first while there is something to undo.
        .navigationBarBackButtonHidden(state.isSelecting || state.inDrillDown)
        .toolbar {
            if state.isSelecting || state.inDrillDown {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation(.snappy(duration: 0.3)) { _ = state.back() }
                    } label: {
                        Image(systemName: "chevron.backward")
                            .fontWeight(.semibold)
                    }
                    .accessibilityLabel(L10n.back)
                    .accessibilityIdentifier("downloads.back")
                }
            }
        }
    }

    #if DEBUG
    /// `-downloadsOpen` targets that set the page up (see ``DownloadsDemoService``).
    private func applyDebugTargets(_ listing: LocalMusicListing) {
        guard !songs.isEmpty else { return }
        if DownloadsDemoService.take("grid") {
            if state.isDownloads { settings.downloadedMusicViewType = .grid } else { settings.localMusicViewType = .grid }
        }
        if DownloadsDemoService.take("list") {
            if state.isDownloads { settings.downloadedMusicViewType = .list } else { settings.localMusicViewType = .list }
        }
        if DownloadsDemoService.take("artists") { state.select(.artists) }
        if DownloadsDemoService.take("albums") { state.select(.albums) }
        if DownloadsDemoService.take("drill"), let album = listing.albums.first { state.tap(album) }
        if state.isDownloads, DownloadsDemoService.take("select") {
            for song in listing.songs.prefix(3) { _ = state.hold(song, fromDrillDown: true) }
        }
    }
    #endif

    // MARK: - Search and selection

    /// LocalSearchField: live filter, view toggle and sort menu in one pill.
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: AppSymbol.search)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(L10n.searchThisFolder, text: $state.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityIdentifier("downloads.search")
            if !state.query.isEmpty {
                Button {
                    state.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.clearSearch)
            }
            Button {
                Haptics.shared.play(.select)
                let next: LibraryViewType = viewType == .grid ? .list : .grid
                withAnimation(.snappy(duration: 0.3)) {
                    if state.isDownloads { settings.downloadedMusicViewType = next } else { settings.localMusicViewType = next }
                }
            } label: {
                Image(systemName: viewType == .grid ? AppSymbol.listView : AppSymbol.gridView)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewType == .grid ? L10n.switchToListView : L10n.switchToGridView)
            .accessibilityIdentifier("downloads.viewType")
            Menu {
                ForEach(LocalMusicSort.allCases, id: \.self) { option in
                    Button {
                        if state.isDownloads { settings.downloadedMusicSort = option } else { settings.localMusicSort = option }
                    } label: {
                        if option == sort {
                            Label(option.label, systemImage: AppSymbol.check)
                        } else {
                            Text(option.label)
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .tint(.secondary)
            .accessibilityLabel(L10n.sortMusic)
            .accessibilityIdentifier("downloads.sort")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(minHeight: 44)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    /// DownloadSelectionBar: the Downloads folder's replacement for the search field.
    private func selectionBar(_ listing: LocalMusicListing) -> some View {
        let count = state.isSelecting ? songs.filter { state.isSelected($0) }.count : 0
        return HStack(spacing: 4) {
            Button {
                withAnimation { state.selectAll(listing.sorted) }
            } label: {
                Image(systemName: AppSymbol.check)
                    .fontWeight(.semibold)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .disabled(state.allSelected(of: listing.sorted))
            .accessibilityLabel(L10n.selectAll)
            .accessibilityIdentifier("downloads.selectAll")
            Text("\(count) \(L10n.selected)")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("downloads.selectedCount")
            if let onUpload {
                Button {
                    onUpload(state.takeSelection(from: songs))
                } label: {
                    // Android's text button, falling back to its icon alone when "Upload to WebDAV"
                    // and "Delete" don't both fit (large text sizes); VoiceOver reads the label.
                    ViewThatFits(in: .horizontal) {
                        Label(L10n.uploadToWebdav, systemImage: "square.and.arrow.up")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .fixedSize()
                        Label(L10n.uploadToWebdav, systemImage: "square.and.arrow.up")
                            .labelStyle(.iconOnly)
                            .frame(width: 36, height: 40)
                    }
                    .contentShape(Rectangle())
                }
                .disabled(count == 0)
                .accessibilityIdentifier("downloads.upload")
            }
            Button(role: .destructive) {
                let chosen = state.takeSelection(from: songs)
                onDelete?(chosen)
            } label: {
                Label(L10n.delete, systemImage: "trash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(red: 1, green: 0x45 / 255, blue: 0x3A / 255))
            }
            .disabled(count == 0)
            .accessibilityIdentifier("downloads.delete")
            Button(L10n.cancel) {
                withAnimation { state.clearSelection() }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 8)
            .accessibilityIdentifier("downloads.cancelSelection")
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 44)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ listing: LocalMusicListing) -> some View {
        Group {
            if isLoading {
                // Android drew "0 songs" until the listing arrived; placeholder rows say "loading"
                // without claiming the folder is empty.
                ScrollView { ListSkeleton(rows: 10).padding(.top, 8) }
                    .scrollDisabled(true)
            } else if listing.sorted.isEmpty, let emptyMessage {
                // The tab row stays put rather than being swapped out, so the page still reads as
                // itself while it says why it's empty.
                ScrollView { LocalMessageState(message: emptyMessage) }
            } else if let drill = state.drillDown {
                drillDownList(drill)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .trailing).combined(with: .opacity)))
            } else {
                switch state.tab {
                case .songs: songsTab(listing.songs)
                case .artists: artistsTab(listing.artists)
                case .albums: albumsTab(listing.albums)
                }
            }
        }
    }

    private var isGrid: Bool { viewType == .grid }

    private func grid(minimum: CGFloat) -> [GridItem] {
        [GridItem(.adaptive(minimum: minimum), spacing: 12, alignment: .top)]
    }

    private func songsTab(_ rows: [Song]) -> some View {
        ScrollView {
            if isGrid {
                VStack(spacing: 0) {
                    LocalSectionHeader(symbol: "music.note.list", title: L10n.songCountPlural(rows.count))
                        .padding(.vertical, 10)
                    LazyVGrid(columns: grid(minimum: 140), spacing: 16) {
                        ForEach(IndexedSong.list(rows)) { row in
                            let index = row.index, song = row.song
                            songCard(song, in: rows, at: index, fromDrillDown: false)
                                .prefetchingCovers(after: index, in: rows, pixels: ArtworkSize.card, covers: Self.cover)
                        }
                    }
                }
                .padding(.horizontal, AppTheme.gutter)
                .padding(.top, 6)
                .padding(.bottom, 8)
            } else {
                LazyVStack(spacing: 0) {
                    LocalSectionHeader(symbol: "music.note.list", title: L10n.songCountPlural(rows.count))
                        .padding(.horizontal, AppTheme.gutter)
                        .padding(.vertical, 14)
                    ForEach(IndexedSong.list(rows)) { row in
                        let index = row.index, song = row.song
                        songRow(song, in: rows, at: index, number: nil, fromDrillDown: false)
                            .prefetchingCovers(after: index, in: rows, covers: Self.cover)
                        if index < rows.count - 1 { LocalRowDivider() }
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .accessibilityIdentifier("downloads.songs")
    }

    private func artistsTab(_ artists: [LocalArtistGroup]) -> some View {
        ScrollView {
            if isGrid {
                VStack(spacing: 0) {
                    LocalSectionHeader(symbol: "person.fill", title: L10n.artistCount(artists.count))
                        .padding(.vertical, 10)
                    LazyVGrid(columns: grid(minimum: 130), spacing: 16) {
                        ForEach(artists) { artist in
                            LocalArtistCard(artist: artist, onTap: { open(artist) }, onHold: { openMenu(artist.name, artist.songs) })
                        }
                    }
                }
                .padding(.horizontal, AppTheme.gutter)
                .padding(.top, 6)
                .padding(.bottom, 8)
            } else {
                LazyVStack(spacing: 0) {
                    LocalSectionHeader(symbol: "person.fill", title: L10n.artistCount(artists.count))
                        .padding(.horizontal, AppTheme.gutter)
                        .padding(.vertical, 14)
                    ForEach(artists) { artist in
                        LocalArtistRow(artist: artist, onTap: { open(artist) }, onHold: { openMenu(artist.name, artist.songs) })
                        LocalRowDivider()
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .accessibilityIdentifier("downloads.artists")
    }

    private func albumsTab(_ albums: [LocalAlbumGroup]) -> some View {
        ScrollView {
            if isGrid {
                VStack(spacing: 0) {
                    LocalSectionHeader(symbol: "square.stack.fill", title: L10n.albumCount(albums.count))
                        .padding(.vertical, 10)
                    if albums.isEmpty { LocalMessageState(message: L10n.noLocalAlbums) }
                    LazyVGrid(columns: grid(minimum: 140), spacing: 16) {
                        ForEach(albums) { album in
                            LocalAlbumCard(album: album, selected: state.isSelected(album),
                                           onTap: { tap(album) }, onHold: { hold(album) })
                        }
                    }
                }
                .padding(.horizontal, AppTheme.gutter)
                .padding(.top, 6)
                .padding(.bottom, 8)
            } else {
                LazyVStack(spacing: 0) {
                    LocalSectionHeader(symbol: "square.stack.fill", title: L10n.albumCount(albums.count))
                        .padding(.horizontal, AppTheme.gutter)
                        .padding(.vertical, 14)
                    if albums.isEmpty { LocalMessageState(message: L10n.noLocalAlbums) }
                    ForEach(albums) { album in
                        LocalAlbumRow(album: album, selected: state.isSelected(album),
                                      onTap: { tap(album) }, onHold: { hold(album) })
                        LocalRowDivider()
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .accessibilityIdentifier("downloads.albums")
    }

    private func drillDownList(_ drill: LocalMusicState.DrillDown) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                DrillDownHeader(drill: drill,
                                onBack: { withAnimation(.snappy(duration: 0.3)) { state.leaveDrillDown() } },
                                onMore: { openMenu(drill.label, drill.songs) })
                DrillDownActions(onShuffle: { shuffle(drill.songs) }, onPlay: { play(drill.songs, at: 0) })
                if isGrid {
                    LazyVGrid(columns: grid(minimum: 140), spacing: 16) {
                        ForEach(IndexedSong.list(drill.songs)) { row in
                            let index = row.index, song = row.song
                            songCard(song, in: drill.songs, at: index, fromDrillDown: true)
                                .prefetchingCovers(after: index, in: drill.songs, pixels: ArtworkSize.card, covers: Self.cover)
                        }
                    }
                    .padding(.horizontal, AppTheme.gutter)
                    .padding(.bottom, 8)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(IndexedSong.list(drill.songs)) { row in
                            let index = row.index, song = row.song
                            songRow(song, in: drill.songs, at: index, number: index + 1, fromDrillDown: true)
                            if index < drill.songs.count - 1 { LocalRowDivider() }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("downloads.drillDown")
    }

    // MARK: - Rows

    /// The cover a row draws straight from its artwork string, to load ahead of the scroll. A remote
    /// track's cover goes through the resolver instead, which a prefetch can't reach.
    private static func cover(_ song: Song) -> [String?] {
        LocalArtwork.needsResolver(song) ? [] : [song.thumbnailUrl]
    }

    private func songRow(_ song: Song, in list: [Song], at index: Int, number: Int?, fromDrillDown: Bool) -> some View {
        let current = song.isSameTrackAs(player.currentSong)
        return LocalSongRow(
            song: song,
            trackNumber: number,
            selected: state.isSelected(song),
            isCurrent: current,
            isPlaying: current && player.isPlaying,
            isDownloaded: isDownloaded(song.videoId),
            onTap: { tap(list, at: index) },
            onHold: { hold(song, fromDrillDown: fromDrillDown) },
            // Downloads redefines the hold as "select", so the ⋯ carries the song menu itself.
            onMore: { router.present(.songActions(song)) },
            onSwipe: { _ = player.queueFromSwipe(song) }
        )
    }

    private func songCard(_ song: Song, in list: [Song], at index: Int, fromDrillDown: Bool) -> some View {
        let current = song.isSameTrackAs(player.currentSong)
        return LocalSongCard(
            song: song,
            selected: state.isSelected(song),
            isCurrent: current,
            isPlaying: current && player.isPlaying,
            onTap: { tap(list, at: index) },
            onHold: { hold(song, fromDrillDown: fromDrillDown) }
        )
    }

    // MARK: - Actions (MainActivity's callbacks)

    private var source: QueueSource { QueueSource(title: title, type: .browse, id: browseId) }

    private func tap(_ list: [Song], at index: Int) {
        guard list.indices.contains(index) else { return }
        if !state.tap(list[index]) { play(list, at: index) }
    }

    private func hold(_ song: Song, fromDrillDown: Bool) {
        let selected = withAnimation(.snappy(duration: 0.25)) { state.hold(song, fromDrillDown: fromDrillDown) }
        if !selected { router.present(.songActions(song)) }
    }

    private func tap(_ album: LocalAlbumGroup) {
        withAnimation(.snappy(duration: 0.3)) { state.tap(album) }
    }

    private func hold(_ album: LocalAlbumGroup) {
        let selected = withAnimation(.snappy(duration: 0.25)) { state.hold(album) }
        if !selected { openMenu(album.title, album.songs) }
    }

    private func open(_ artist: LocalArtistGroup) {
        withAnimation(.snappy(duration: 0.3)) { state.open(artist) }
    }

    private func play(_ list: [Song], at index: Int) {
        guard !list.isEmpty else { return }
        _ = player.play(list, startAt: index, source: source)
    }

    private func shuffle(_ list: [Song]) {
        guard !list.isEmpty else { return }
        _ = player.shufflePlay(list, source: source)
    }

    /// An artist or album grouping held, or a drill-down's ⋯: the album menu with the rows already in
    /// hand, since nothing here has a browse id to fetch (MainActivity's `onCollectionLongPress`).
    /// A release downloaded whole is named by its record, so the menu can offer Delete download.
    private func openMenu(_ label: String, _ grouped: [Song]) {
        let record = collections.first { $0.title == label && $0.songs == grouped }
        let browseId = record.map { DownloadLibrary.pageId(for: $0.id) } ?? "local:group:\(label)"
        let first = grouped.first
        let credit = first?.artist ?? ""
        let item = BrowseItem(browseId: browseId, title: label, subtitle: credit == label ? "" : credit,
                              thumbnailUrl: record?.thumbnailUrl ?? first?.thumbnailUrl, type: .other)
        // The rows go through the Collections menu's page context. That also leaves Play and Shuffle
        // off, which Android kept for these groupings (BrowseTarget with `songs` and no browse id is
        // still `fromCard`); the fix is in Collections — see the Downloads UI report's requested change.
        CollectionsStore.shared(for: model).pageMenuContext = (browseId, grouped)
        router.present(.browseActions(item))
    }
}

/// The Songs / Artists / Albums row (TabRow with LocalTab and the secondary indicator). A segmented
/// control is iOS's usual answer, but Android's tabs carry an icon beside each label and an
/// underline, and are kept.
struct LocalTabRow: View {
    let selection: LocalMusicState.Tab
    let onSelect: (LocalMusicState.Tab) -> Void
    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 0) {
            ForEach(LocalMusicState.Tab.allCases) { tab in
                let selected = tab == selection
                Button {
                    onSelect(tab)
                } label: {
                    VStack(spacing: 0) {
                        Label(tab.title, systemImage: tab.symbol)
                            .font(.subheadline.weight(.semibold))
                            .labelStyle(TabLabelStyle())
                            .foregroundStyle(selected ? Color.accentColor : .secondary)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 4)
                            .frame(maxWidth: .infinity)
                        ZStack {
                            if selected {
                                Capsule()
                                    .fill(Color.accentColor)
                                    .frame(height: 3)
                                    .matchedGeometryEffect(id: "indicator", in: indicator)
                            }
                        }
                        .frame(height: 3)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .accessibilityIdentifier("downloads.tab.\(tab)")
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
    }

    private struct TabLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 6) {
                configuration.icon.imageScale(.small)
                configuration.title.lineLimit(1).minimumScaleFactor(0.8)
            }
        }
    }
}

/// A row of a track list and its place in it, keyed by the track: an offset would hand one row's
/// state (a remote cover still loading, a swipe half done) to whichever track lands in its slot when
/// the filter or the sort changes. Android keyed by `"${videoId}_$index"`, but with the place in the
/// key one new download at the top of "newest first" shifts every place, so every row was rebuilt
/// and its cover drawn again. A track listed twice is told apart by how many times it has
/// come up so far, as the queue's rows are.
struct IndexedSong: Identifiable {
    let index: Int
    let song: Song
    let id: String

    static func list(_ songs: [Song]) -> [IndexedSong] {
        var seen: [String: Int] = [:]
        return songs.enumerated().map { index, song in
            let repeats = seen[song.videoId, default: 0]
            seen[song.videoId] = repeats + 1
            return IndexedSong(index: index, song: song, id: repeats == 0 ? song.videoId : "\(song.videoId)#\(repeats)")
        }
    }
}

/// The hairline between rows, inset to the text (ROW_DIVIDER_INSET).
private struct LocalRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(.separator).opacity(0.5))
            .frame(height: 0.5)
            .padding(.leading, AppTheme.gutter + 52 + 14)
            .accessibilityHidden(true)
    }
}

/// DrillDownHeader: back, the release's ⋯, a large cover (or the person glyph for an artist), the
/// name and the track count.
private struct DrillDownHeader: View {
    let drill: LocalMusicState.DrillDown
    let onBack: () -> Void
    let onMore: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "arrow.backward")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.back)
                .accessibilityIdentifier("downloads.drillDown.back")
                Spacer()
                Button(action: onMore) {
                    Image(systemName: AppSymbol.more)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.more)
                .accessibilityIdentifier("downloads.drillDown.more")
            }
            .padding(.leading, 6)
            .padding(.trailing, AppTheme.gutter)
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.secondary.opacity(0.18))
                Image(systemName: drill.artworkUrl == nil ? "person.fill" : "square.stack.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                if let artwork = drill.artworkUrl {
                    ArtworkImage(artwork, pixels: ArtworkSize.card, cornerRadius: 16)
                }
            }
            .frame(width: 188, height: 188)
            .padding(.top, 4)
            .accessibilityHidden(true)
            Text(drill.label)
                .font(.title.bold())
                .lineLimit(1)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppTheme.gutter)
                .padding(.top, 14)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("downloads.drillDown.title")
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    /// "Artist · 12 tracks" for an artist (no cover), "12 tracks" for a release.
    private var subtitle: String {
        let count = L10n.trackCountPlural(drill.songs.count)
        return drill.artworkUrl == nil ? L10n.artist + " · " + count : count
    }
}

/// DrillDownActionRow: the round Shuffle button and the Play pill, on frosted glass.
private struct DrillDownActions: View {
    let onShuffle: () -> Void
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onShuffle) {
                Image(systemName: AppSymbol.shuffle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 50, height: 50)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.shuffle)
            .accessibilityIdentifier("downloads.drillDown.shuffle")
            Button(action: onPlay) {
                Label(L10n.play, systemImage: AppSymbol.play)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 32)
                    .frame(minHeight: 50)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("downloads.drillDown.play")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, AppTheme.gutter)
        .padding(.vertical, 10)
        .padding(.bottom, 4)
    }
}
