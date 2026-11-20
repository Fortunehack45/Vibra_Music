import Foundation
import VibraMusicCore

// Ports the list logic of ui/screens/LocalMusicScreen.kt (sortedForLibrary, matchesSearch, the
// Artists grouping and albumEntries), which is pure and belongs beside the library rather than in a
// view.

/// One row of the Artists tab: every track credited to exactly this artist string.
public struct LocalArtistGroup: Hashable, Sendable, Identifiable {
    public var name: String
    public var songs: [Song]
    public var id: String { name }
}

/// One row of the Albums tab: a release downloaded whole, or a grouping inferred from album tags.
public struct LocalAlbumGroup: Hashable, Sendable, Identifiable {
    public var title: String
    public var artist: String
    public var thumbnailUrl: String?
    /// Billed as a playlist rather than by artist.
    public var playlist: Bool
    /// In the order it was downloaded in, which is the release's own.
    public var songs: [Song]
    /// Whether this is a release the user asked for, or a grouping inferred.
    public var asked: Bool
    /// The release's own id where it has one (`asked:<id>`), else `tagged:<album>`. Not the title:
    /// an album and a playlist can share one, and two rows sharing a key breaks a `ForEach`.
    public var key: String
    public var id: String { key }
}

/// Sorting, searching and grouping the Downloads page's songs into its Songs / Artists / Albums tabs.
public enum LocalLibraryListing {
    /// `songs` in the order the sort menu asks for. Date orders are newest first, with the title
    /// breaking ties; a track with no date sorts last.
    public static func sorted(_ songs: [Song], by order: LocalMusicSort) -> [Song] {
        let indexed = Array(songs.enumerated())
        func titleAscending(_ a: Song, _ b: Song) -> Bool? {
            let result = a.title.compare(b.title, options: .caseInsensitive)
            return result == .orderedSame ? nil : result == .orderedAscending
        }
        let ordered: [(offset: Int, element: Song)]
        switch order {
        case .titleAsc:
            ordered = indexed.sorted { lhs, rhs in titleAscending(lhs.element, rhs.element) ?? (lhs.offset < rhs.offset) }
        case .titleDesc:
            // Lowercased once per song rather than twice per comparison.
            let keys = songs.map { $0.title.lowercased() }
            ordered = indexed.sorted { lhs, rhs in
                let a = keys[lhs.offset], b = keys[rhs.offset]
                return a == b ? lhs.offset < rhs.offset : a > b
            }
        case .dateAdded, .dateModified:
            ordered = indexed.sorted { lhs, rhs in
                let key: (Song) -> Int64 = order == .dateAdded
                    ? { $0.localDateAddedSeconds ?? .min }
                    : { $0.localDateModifiedSeconds ?? .min }
                let a = key(lhs.element), b = key(rhs.element)
                if a != b { return a > b }
                return titleAscending(lhs.element, rhs.element) ?? (lhs.offset < rhs.offset)
            }
        }
        return ordered.map(\.element)
    }

    /// Whether `song` is a hit for a query typed into the search field: title, artist or album,
    /// case-insensitively.
    public static func matches(_ song: Song, query: String) -> Bool {
        song.title.range(of: query, options: .caseInsensitive) != nil
            || song.artist.range(of: query, options: .caseInsensitive) != nil
            || song.albumName?.range(of: query, options: .caseInsensitive) != nil
    }

    /// The Songs tab: `songs` narrowed by `query` (blank = everything). Pass them already sorted.
    public static func songs(_ songs: [Song], matching query: String) -> [Song] {
        query.isBlank ? songs : songs.filter { matches($0, query: query) }
    }

    /// The Artists tab: one row per artist string, narrowed by name, in name order. Each row keeps
    /// the order of `songs`, so pass them already sorted.
    public static func artists(in songs: [Song], matching query: String = "") -> [LocalArtistGroup] {
        var order: [String] = []
        var groups: [String: [Song]] = [:]
        for song in songs {
            if groups[song.artist] == nil { order.append(song.artist) }
            groups[song.artist, default: []].append(song)
        }
        return order
            .filter { query.isBlank || $0.range(of: query, options: .caseInsensitive) != nil }
            .map { (key: $0.lowercased(), name: $0) }
            .sorted { $0.key < $1.key }
            .map { LocalArtistGroup(name: $0.name, songs: groups[$0.name] ?? []) }
    }

    /// The Albums tab: the releases downloaded whole, then whatever else the files' own album tags
    /// group up, narrowed by title or artist.
    ///
    /// Merged rather than shown as separate sections because they are the same kind of thing to
    /// whoever is looking. What matters is that the *named* ones win a collision: an album
    /// downloaded whole also stamps its name onto each track, so without this every one would
    /// appear twice. Releases lead, because a tag grouping is a guess and a recorded release is not.
    public static func albums(in songs: [Song], collections: [DownloadedCollection], matching query: String = "") -> [LocalAlbumGroup] {
        let asked = collections.map { collection in
            LocalAlbumGroup(
                title: collection.title,
                artist: collection.subtitle.isBlank ? (collection.songs.first?.artist ?? "") : collection.subtitle,
                thumbnailUrl: collection.thumbnailUrl,
                playlist: collection.playlist,
                songs: collection.songs,
                asked: true,
                key: "asked:\(collection.id)"
            )
        }
        let claimed = Set(asked.map { $0.title.lowercased() })
        var order: [String] = []
        var groups: [String: [Song]] = [:]
        for song in songs {
            // No album is every track that never said what release it was off, and there is no row
            // to draw for "no album" — those are the Songs tab's alone.
            guard let name = song.albumName else { continue }
            if groups[name] == nil { order.append(name) }
            groups[name, default: []].append(song)
        }
        let derived = order.compactMap { name -> LocalAlbumGroup? in
            guard !claimed.contains(name.lowercased()), let group = groups[name] else { return nil }
            return LocalAlbumGroup(
                title: name,
                artist: group.first?.artist ?? "",
                thumbnailUrl: group.lazy.compactMap(\.thumbnailUrl).first,
                playlist: false,
                songs: group,
                asked: false,
                key: "tagged:\(name)"
            )
        }
        return (asked + derived)
            .map { (key: $0.title.lowercased(), album: $0) }
            .sorted { lhs, rhs in
                if lhs.album.asked != rhs.album.asked { return lhs.album.asked }
                return lhs.key < rhs.key
            }
            .map(\.album)
            .filter { album in
                query.isBlank
                    || album.title.range(of: query, options: .caseInsensitive) != nil
                    || album.artist.range(of: query, options: .caseInsensitive) != nil
            }
    }
}
