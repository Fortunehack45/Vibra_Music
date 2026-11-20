import VibraMusicCore
import Foundation
import InnerTube

// The pure pieces of DetailScreen.kt and LibraryScreen.kt: sorting and filtering a release's track
// list, splitting a browse subtitle into the header's two lines, the page's play time, and the
// Library shelves' pin-first / sort / five-card rules. Kept apart from the views so each rule is
// tested on its own (CollectionsLogicTests).

/// How many cards a Library shelf's row shows before "Show all" (LibraryScreen.kt's
/// `LIBRARY_ROW_MAX_ITEMS`), and an artist page's release rows (DetailScreen.kt's
/// `ARTIST_ROW_MAX_ITEMS`).
enum CollectionsLimits {
    static let libraryRowMaxItems = 5
    static let artistRowMaxItems = 5
    /// An artist's full song list would bury the release shelves, so it stops at twenty…
    static let maxArtistSongs = 20
    /// …paged sideways four at a time.
    static let songsPerColumn = 4

    /// The top songs an artist page shows: the first twenty.
    static func topSongs(of all: [Song]) -> [Song] { Array(all.prefix(maxArtistSongs)) }

    /// `top` laid out four to a column, the way the top-songs grid pages sideways.
    static func columns(of top: [Song]) -> [[Song]] {
        stride(from: 0, to: top.count, by: songsPerColumn).map { Array(top[$0..<min($0 + songsPerColumn, top.count)]) }
    }

    /// A release shelf's row on an artist page: five cards, and "Show all" when there are more.
    static func releaseRow(_ items: [ShelfItem]) -> (shown: [ShelfItem], canShowAll: Bool) {
        items.count > artistRowMaxItems ? (Array(items.prefix(artistRowMaxItems)), true) : (items, false)
    }
}

extension Array where Element == Song {
    /// The track list in `sort`'s order (DetailScreen.kt's `sortedForDetail`).
    ///
    /// A catalogue row carries no added date, so its place in the running order stands in for one:
    /// a playlist is appended to as songs are added, and reversed that puts the most recent
    /// addition on top. Rows that do carry a timestamp (downloads) are dated properly, with the
    /// position order left to break ties.
    func sortedForDetail(_ sort: SongSort) -> [Song] {
        switch sort {
        case .default:
            return self
        case .titleAsc:
            return enumerated().sorted { lhs, rhs in
                let order = lhs.element.title.caseInsensitiveCompare(rhs.element.title)
                return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedAscending
            }.map(\.element)
        case .titleDesc:
            return enumerated().sorted { lhs, rhs in
                let order = lhs.element.title.caseInsensitiveCompare(rhs.element.title)
                return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedDescending
            }.map(\.element)
        case .dateAddedAsc:
            return enumerated().sorted { lhs, rhs in
                let l = lhs.element.localDateAddedSeconds ?? .max
                let r = rhs.element.localDateAddedSeconds ?? .max
                return l == r ? lhs.offset < rhs.offset : l < r
            }.map(\.element)
        case .dateAddedDesc:
            return enumerated().sorted { lhs, rhs in
                let l = lhs.element.localDateAddedSeconds ?? .min
                let r = rhs.element.localDateAddedSeconds ?? .min
                return l == r ? lhs.offset > rhs.offset : l > r
            }.map(\.element)
        }
    }

    /// The rows a typed query leaves standing, each still carrying its place in the full list, so an
    /// album's track numbers stay the album's (DetailScreen.kt's `matching`).
    func matching(_ query: String) -> [(offset: Int, element: Song)] {
        let all = Array<(offset: Int, element: Song)>(enumerated())
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return all }
        return all.filter { entry in
            let song = entry.element
            return song.title.localizedCaseInsensitiveContains(query)
                || song.artist.localizedCaseInsensitiveContains(query)
                || (song.albumName?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    /// An album's track listing doesn't repeat the cover on every row, so rows fall back to the
    /// page's (MainViewModel's `withArtwork`).
    func withArtwork(_ fallback: String?) -> [Song] {
        guard let fallback else { return self }
        return map { song in
            guard song.thumbnailUrl == nil else { return song }
            var copy = song
            copy.thumbnailUrl = fallback
            return copy
        }
    }

    /// "41 min", "1h 25m" — the page's length, or nil when no row carries a duration
    /// (DetailScreen.kt's `playtime`).
    var playtime: String? {
        let minutes = reduce(0) { $0 + DetailText.seconds($1.durationText) } / 60
        if minutes <= 0 { return nil }
        if minutes < 60 { return L10n.minutesShort(minutes) }
        return L10n.hoursMinutesShort(minutes / 60, minutes % 60)
    }
}

/// What an album or playlist page draws of its tracks, worked out from its songs, its sort and the
/// filter (DetailScreen.kt's `remember` blocks over `sortedForDetail` and `matching`). Built once per
/// change of those, not on every pass of the page's body (see ``ViewMemo``).
struct DetailTrackList {
    struct Input: Equatable {
        var songs: [Song]
        var suggested: [Song]
        var sort: SongSort
        var query: String
    }

    /// Every track, in the sort's order.
    let sorted: [Song]
    /// Each track's place on the release, which a filter or a sort leaves alone.
    let numbers: [String: Int]
    /// The tracks the filter leaves, in the sort's order: the rows, and the queue a tap plays.
    let rows: [Song]
    /// The Suggested songs the filter leaves.
    let suggested: [Song]
    /// The header's running time.
    let playtime: String?

    init(_ input: Input) {
        sorted = input.songs.sortedForDetail(input.sort)
        numbers = Dictionary(input.songs.enumerated().map { ($0.element.videoId, $0.offset + 1) },
                             uniquingKeysWith: { first, _ in first })
        rows = sorted.matching(input.query).map(\.element)
        suggested = input.suggested.matching(input.query).map(\.element)
        playtime = sorted.playtime
    }
}

/// The one notice a batch of adds leaves (MainActivity's `onAdd`): what went in, else that it was
/// all there already, else that it didn't work.
enum PlaylistBatchNotice {
    static func text(added: Int, alreadyThere: Int, failed: Int) -> String {
        if added > 1 { return L10n.addedToPlaylistsNotice(added) }
        if added == 1 { return L10n.songAddedToPlaylist }
        if alreadyThere > 0 && failed == 0 { return L10n.songAlreadyInPlaylist }
        return L10n.failed
    }
}

enum DetailText {
    /// Subtitle words that name what a page *is* rather than who made it.
    static let kindWords: Set<String> = ["album", "single", "ep", "playlist", "artist", "podcast", "episode", "song", "video"]

    /// "3:45" or "1:02:33" as seconds; 0 for anything that isn't a duration.
    static func seconds(_ text: String?) -> Int {
        guard let text else { return 0 }
        var parts: [Int] = []
        for piece in text.split(separator: ":", omittingEmptySubsequences: false) {
            guard let value = Int(piece.trimmingCharacters(in: .whitespaces)) else { return 0 }
            parts.append(value)
        }
        switch parts.count {
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return 0
        }
    }

    /// Splits the one subtitle a browse row hands over — "Album • Travis Scott • 2023", or just
    /// "Travis Scott" — into the credit line and the metadata line the header shows separately
    /// (DetailScreen.kt's `headerLines`).
    static func headerLines(subtitle: String, type: BrowseType, trackCount: Int, playtime: String? = nil) -> (credit: String, meta: String) {
        let parts = subtitle
            .components(separatedBy: CharacterSet(charactersIn: "•·"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let year = parts.last { $0.count == 4 && $0.allSatisfy(\.isNumber) }
        let kind = parts.first { kindWords.contains($0.lowercased()) }
        let credit = parts.filter { $0 != year && $0 != kind }.joined(separator: ", ")
        let meta = [kind ?? label(of: type), year, trackCount > 0 ? L10n.trackCountPlural(trackCount) : nil, playtime]
            .compactMap { $0 }
            .joined(separator: " • ")
            .uppercased(with: LanguageBundle.locale)
        return (credit, meta)
    }

    static func label(of type: BrowseType) -> String? {
        switch type {
        case .album: return L10n.album
        case .playlist: return L10n.playlist
        case .artist: return L10n.artist
        case .other: return nil
        }
    }

    /// "Open album" / "Open artist" / "Open playlist" / "Open" (BrowseActionsSheet.kt).
    static func openLabel(of type: BrowseType) -> String {
        switch type {
        case .album: return L10n.openAlbum
        case .artist: return L10n.openArtist
        case .playlist: return L10n.openPlaylist
        case .other: return L10n.open
        }
    }

    /// YouTube's count text already reads "1.2M subscribers" in full, so only the number is kept
    /// and the label re-said in the app's words (DetailScreen.kt's ArtistStatsRow).
    static func leadingNumber(_ text: String) -> String {
        String(text.split(separator: " ", maxSplits: 1).first ?? Substring(text))
    }

    /// The public link a release shares (MainActivity's BrowseActionsSheet `onShare`).
    static func shareURL(browseId: String, type: BrowseType) -> URL? {
        if type == .playlist {
            let id = browseId.hasPrefix("VL") ? String(browseId.dropFirst(2)) : browseId
            return URL(string: "https://music.youtube.com/playlist?list=\(id)")
        }
        return URL(string: "https://music.youtube.com/browse/\(browseId)")
    }

    /// A track's link (MainActivity's song-menu `share`).
    /// What VoiceOver reads for a track row: the title first — the row is found by its song, not by
    /// its sleeve number or the now-playing glyph drawn before it — then artist, download format and
    /// length. The now-playing state is the row's value, not part of its name.
    static func songRowLabel(_ song: Song) -> String {
        [song.title, song.artist, song.downloadFormat, song.durationText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    static func shareURL(videoId: String) -> URL? {
        URL(string: "https://music.youtube.com/watch?v=\(videoId)")
    }
}

extension HomeShelf {
    /// Moves whichever of this shelf's cards are pinned to the front, in pin order, leaving
    /// everything else in its order behind them (LibraryScreen.kt's `pinnedFirst`). A no-op on any
    /// shelf with no pinned card: pins only ever hold playlist browse ids.
    func pinnedFirst(_ pinned: [String]) -> HomeShelf {
        guard !pinned.isEmpty else { return self }
        var byId: [String: ShelfItem] = [:]
        for item in items {
            if let id = item.browseId, byId[id] == nil { byId[id] = item }
        }
        let pinnedItems = pinned.compactMap { byId[$0] }
        guard !pinnedItems.isEmpty else { return self }
        let pinnedIds = Set(pinnedItems.compactMap(\.browseId))
        var copy = self
        copy.items = pinnedItems + items.filter { item in
            guard let id = item.browseId else { return true }
            return !pinnedIds.contains(id)
        }
        return copy
    }

    /// A card's title is all a Library shelf carries, so everything but `.default` sorts on it
    /// (LibraryScreen.kt's `sortedForLibrary`).
    func sortedForLibrary(_ sort: LibrarySort) -> HomeShelf {
        var copy = self
        switch sort {
        case .default:
            return self
        case .titleAsc:
            copy.items = items.enumerated().sorted { lhs, rhs in
                let order = lhs.element.title.caseInsensitiveCompare(rhs.element.title)
                return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedAscending
            }.map(\.element)
        case .titleDesc:
            copy.items = items.enumerated().sorted { lhs, rhs in
                let order = lhs.element.title.caseInsensitiveCompare(rhs.element.title)
                return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedDescending
            }.map(\.element)
        }
        return copy
    }

    /// What a shelf's row shows: at most five slots, a leading card counting against the cap
    /// (LibraryScreen.kt's `LibraryGridShelf`).
    func libraryRow(hasLeadingCard: Bool) -> (items: [ShelfItem], showsShowAll: Bool) {
        let leading = hasLeadingCard ? 1 : 0
        let visible = Array(items.prefix(Swift.max(CollectionsLimits.libraryRowMaxItems - leading, 0)))
        return (visible, items.count + leading > CollectionsLimits.libraryRowMaxItems)
    }
}

extension ShelfItem {
    /// The card as the browse item the pages and menus take. Android's `browseTypeOf` reads the
    /// id's prefix; `fallback` covers ids that say nothing (a card of unknown kind).
    func asBrowseItem(fallback: BrowseType = .other) -> BrowseItem? {
        guard let browseId, !browseId.isEmpty else { return nil }
        return BrowseItem(browseId: browseId, title: title, subtitle: subtitle, thumbnailUrl: thumbnailUrl,
                          type: BrowseType.of(browseId: browseId, fallback: fallback))
    }
}
