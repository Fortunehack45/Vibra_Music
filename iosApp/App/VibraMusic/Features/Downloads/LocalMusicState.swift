import VibraMusicCore
import Downloads
import Foundation
import Observation

// The state LocalMusicScreen.kt kept in `remember` blocks — which tab is up, the filter, the
// Downloads folder's long-press selection and the artist/album drill-down — with the rules its
// click handlers applied, pulled out of the view so they can be tested.

/// Strings the Downloads screens need that Android had no resource for (Downloads.xcstrings).
enum DownloadsText {
    static func tr(_ key: String) -> String {
        NSLocalizedString(key, tableName: "Downloads", bundle: LanguageBundle.current, comment: "")
    }

    static var noDownloadedTracks: String { tr("no_downloaded_tracks") }
    static var offlineBackup: String { tr("offline_backup") }
    static var offlineBackupSubtitle: String { tr("offline_backup_subtitle") }
    static var offlineBackupEmpty: String { tr("offline_backup_empty") }
}

/// What one LocalMusicScreen page is showing and what is selected on it.
@MainActor
@Observable
final class LocalMusicState {
    /// LOCAL_TAB_SONGS / _ARTISTS / _ALBUMS.
    enum Tab: Int, CaseIterable, Identifiable {
        case songs, artists, albums
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .songs: return L10n.songs
            case .artists: return L10n.artists
            case .albums: return L10n.albums
            }
        }

        /// Rounded.MusicNote / Person / Album.
        var symbol: String {
            switch self {
            case .songs: return "music.note"
            case .artists: return "person.fill"
            case .albums: return "square.stack.fill"
            }
        }
    }

    /// The inline song list for one artist or album, slid in over the tab content.
    struct DrillDown: Equatable {
        var label: String
        var songs: [Song]
        /// The release's own cover. Only a downloaded album or playlist has one worth showing — a
        /// tag-derived grouping's "artwork" is just whichever of its rows happened to be first.
        var artworkUrl: String?
    }

    /// Whether this is the Downloads folder, where holding a row selects it.
    let isDownloads: Bool

    var tab: Tab = .songs
    /// Narrows whichever tab is showing — songs by title/artist/album, artists and albums by name.
    var query = ""
    private(set) var selectedIds: Set<String> = []
    /// Kept separately from the tracks selected: different albums can share tracks, so inferring an
    /// album's selection from its track ids made one held playlist appear to select unrelated albums.
    private(set) var selectedAlbumKeys: Set<String> = []
    private(set) var drillDown: DrillDown?

    init(isDownloads: Bool) {
        self.isDownloads = isDownloads
    }

    /// The selection bar replaces the search field while anything is selected.
    var isSelecting: Bool { isDownloads && !selectedIds.isEmpty }
    var inDrillDown: Bool { drillDown != nil }

    /// A tab tap: switches, and always leaves a drill-down.
    func select(_ tab: Tab) {
        self.tab = tab
        leaveDrillDown()
    }

    func leaveDrillDown() {
        drillDown = nil
    }

    /// Back (Android's BackHandlers): clears a selection first, then leaves a drill-down. False when
    /// there was nothing to undo and the page itself should close.
    func back() -> Bool {
        if isSelecting {
            clearSelection()
            return true
        }
        if inDrillDown {
            leaveDrillDown()
            return true
        }
        return false
    }

    func clearSelection() {
        selectedIds = []
        selectedAlbumKeys = []
    }

    func isSelected(_ song: Song) -> Bool { selectedIds.contains(song.videoId) }
    func isSelected(_ album: LocalAlbumGroup) -> Bool { selectedAlbumKeys.contains(album.key) }

    func toggle(_ song: Song) {
        if selectedIds.contains(song.videoId) {
            selectedIds.remove(song.videoId)
        } else {
            selectedIds.insert(song.videoId)
        }
        if selectedIds.isEmpty { selectedAlbumKeys = [] }
    }

    func toggle(_ album: LocalAlbumGroup) {
        let ids = Set(album.songs.map(\.videoId))
        if selectedAlbumKeys.contains(album.key) {
            selectedAlbumKeys.remove(album.key)
            selectedIds.subtract(ids)
        } else {
            selectedAlbumKeys.insert(album.key)
            selectedIds.formUnion(ids)
        }
    }

    // MARK: - Gestures

    /// A row tapped: while selecting it toggles, otherwise the caller plays. Returns true when the
    /// tap was taken as selection.
    func tap(_ song: Song) -> Bool {
        guard isSelecting else { return false }
        toggle(song)
        return true
    }

    /// A row held: in the Downloads folder that selects it (and, from the Songs tab, puts the page
    /// back on Songs out of any drill-down); elsewhere the caller opens the song menu. Returns true
    /// when the hold was taken as selection.
    func hold(_ song: Song, fromDrillDown: Bool) -> Bool {
        guard isDownloads else { return false }
        selectedIds.insert(song.videoId)
        if !fromDrillDown {
            tab = .songs
            leaveDrillDown()
        }
        return true
    }

    /// An album card tapped: toggles while selecting, otherwise drills in with the release's cover.
    func tap(_ album: LocalAlbumGroup) {
        if isSelecting {
            toggle(album)
        } else {
            drillDown = DrillDown(label: album.title, songs: album.songs, artworkUrl: album.thumbnailUrl)
        }
    }

    /// An album card held: selects every one of its tracks in the Downloads folder. False elsewhere,
    /// where the caller opens the album menu.
    func hold(_ album: LocalAlbumGroup) -> Bool {
        guard isDownloads else { return false }
        selectedIds.formUnion(album.songs.map(\.videoId))
        selectedAlbumKeys.insert(album.key)
        return true
    }

    /// An artist tapped: drills in. Artists have no cover of their own, so the header shows the
    /// person glyph.
    func open(_ artist: LocalArtistGroup) {
        drillDown = DrillDown(label: artist.name, songs: artist.songs, artworkUrl: nil)
    }

    // MARK: - Selection bar

    func allSelected(of songs: [Song]) -> Bool {
        !songs.isEmpty && songs.allSatisfy { selectedIds.contains($0.videoId) }
    }

    /// "Select all" selects every track in the folder (the whole sorted list, not just the filter).
    func selectAll(_ songs: [Song]) {
        selectedIds = Set(songs.map(\.videoId))
    }

    /// The selected rows, in `songs` order, and the selection cleared — what Delete and Upload hand on.
    func takeSelection(from songs: [Song]) -> [Song] {
        let chosen = songs.filter { selectedIds.contains($0.videoId) }
        clearSelection()
        return chosen
    }
}

/// The three tabs' contents for one folder, derived from its songs (LocalMusicScreen's `remember`
/// blocks over `sortedSongs` and `searchQuery`).
struct LocalMusicListing: Equatable {
    var sorted: [Song]
    var songs: [Song]
    var artists: [LocalArtistGroup]
    var albums: [LocalAlbumGroup]

    /// What the tabs are worked out from.
    struct Input: Equatable {
        var songs: [Song]
        var collections: [DownloadedCollection]
        var sort: LocalMusicSort
        var query: String
    }

    init(songs all: [Song], collections: [DownloadedCollection], sort: LocalMusicSort, query: String) {
        sorted = LocalLibraryListing.sorted(all, by: sort)
        songs = LocalLibraryListing.songs(sorted, matching: query)
        artists = LocalLibraryListing.artists(in: sorted, matching: query)
        albums = LocalLibraryListing.albums(in: sorted, collections: collections, matching: query)
    }

    init(_ input: Input) {
        self.init(songs: input.songs, collections: input.collections, sort: input.sort, query: input.query)
    }
}

extension LocalMusicSort {
    /// LocalMusicSort.localizedLabel().
    var label: String {
        switch self {
        case .titleAsc: return L10n.sortTitleAscending
        case .titleDesc: return L10n.sortTitleDescending
        case .dateAdded: return L10n.sortDateAdded
        case .dateModified: return L10n.sortDateModified
        }
    }
}
