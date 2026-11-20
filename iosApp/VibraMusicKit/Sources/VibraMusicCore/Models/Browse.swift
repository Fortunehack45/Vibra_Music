import Foundation

// Ports data/model/Models.kt (browse, search and feed types) and MainViewModel.browseTypeOf.

/// What a browse id opens.
public enum BrowseType: String, Codable, Hashable, Sendable, CaseIterable {
    case album = "ALBUM"
    case artist = "ARTIST"
    case playlist = "PLAYLIST"
    case other = "OTHER"

    /// The page type a browse id names, read off its prefix.
    ///
    /// Local download playlists (``LocalBrowseID/playlistPrefix``) are playlists; `UC…` is an
    /// artist channel; `MPREb…`, `OLAK…` and `VLOLAK…` are album releases (an album is backed by an
    /// `OLAK5uy_…` playlist, so this must be checked before the generic `VL`/`PL` playlist rule);
    /// anything unrecognised returns `fallback`.
    public static func of(browseId: String, fallback: BrowseType = .other) -> BrowseType {
        if browseId.hasPrefix(LocalBrowseID.playlistPrefix) { return .playlist }
        if browseId.hasPrefix("UC") { return .artist }
        if browseId.hasPrefix("MPREb") || browseId.hasPrefix("VLOLAK") || browseId.hasPrefix("OLAK") {
            return .album
        }
        if browseId.hasPrefix("VL") || browseId.hasPrefix("PL") { return .playlist }
        return fallback
    }
}

/// App-local browse ids: pages that don't come from YouTube Music. Shared by Downloads,
/// NetworkLibrary, the Library screen and deep links, so they must agree on the strings.
public enum LocalBrowseID {
    /// The Downloads page.
    public static let downloads = "local:downloads"
    /// Every local track (downloads plus imported files).
    public static let all = "local:all"
    /// A downloaded collection's page: `playlistPrefix + recordId`.
    public static let playlistPrefix = "local:playlist:"
    /// Offline backup: everything already whole on this device.
    public static let offlineBackup = "local:offline"
    /// The WebDAV library root.
    public static let webDAV = "local:webdav"
    /// The SMB library root.
    public static let smb = "local:smb"

    /// Whether `browseId` is any app-local page rather than a YouTube one.
    public static func isLocal(_ browseId: String) -> Bool { browseId.hasPrefix("local:") }
}

/// A non-track search result or card: album, artist or playlist.
public struct BrowseItem: Codable, Hashable, Sendable, Identifiable {
    public var browseId: String
    public var title: String
    public var subtitle: String
    public var thumbnailUrl: String?
    public var type: BrowseType

    public init(browseId: String, title: String, subtitle: String, thumbnailUrl: String?, type: BrowseType) {
        self.browseId = browseId
        self.title = title
        self.subtitle = subtitle
        self.thumbnailUrl = thumbnailUrl
        self.type = type
    }

    public var id: String { browseId }
}

/// A search row. Rows are heterogeneous once filters other than Songs are used.
public enum SearchResult: Codable, Hashable, Sendable, Identifiable {
    /// The promoted card returned only at the head of an unfiltered search.
    case topTrack(Song)
    case track(Song)
    case browse(BrowseItem)

    public var id: String {
        switch self {
        case .topTrack(let song): return "top:\(song.id)"
        case .track(let song): return "track:\(song.id)"
        case .browse(let item): return "browse:\(item.browseId)"
        }
    }

    /// The song behind a track row, nil for a browse row.
    public var song: Song? {
        switch self {
        case .topTrack(let song), .track(let song): return song
        case .browse: return nil
        }
    }
}

/// Search filter chips, with the exact Innertube `params` each one sends.
public enum SearchFilter: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    /// YouTube Music's mixed search page: songs, artists, albums and playlists.
    case all = "ALL"
    case songs = "SONGS"
    case videos = "VIDEOS"
    case albums = "ALBUMS"
    case artists = "ARTISTS"
    case playlists = "PLAYLISTS"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: return "All"
        case .songs: return "Songs"
        case .videos: return "Videos"
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .playlists: return "Playlists"
        }
    }

    /// The `params` value for `youtubei/v1/search`; nil for the unfiltered page.
    public var params: String? {
        switch self {
        case .all: return nil
        case .songs: return "EgWKAQIIAWoKEAkQChAFEAMQBA=="
        case .videos: return "EgWKAQIQAWoKEAkQChAFEAMQBA=="
        case .albums: return "EgWKAQIYAWoKEAkQChAFEAMQBA=="
        case .artists: return "EgWKAQIgAWoKEAkQChAFEAMQBA=="
        case .playlists: return "EgWKAQIoAWoKEAkQChAFEAMQBA=="
        }
    }
}

/// A card in a home-feed carousel: either a track (`videoId`) or an album/playlist (`browseId`).
public struct ShelfItem: Codable, Hashable, Sendable {
    public var title: String
    public var subtitle: String
    public var thumbnailUrl: String?
    public var videoId: String?
    public var browseId: String?

    public init(title: String, subtitle: String, thumbnailUrl: String?, videoId: String?, browseId: String?) {
        self.title = title
        self.subtitle = subtitle
        self.thumbnailUrl = thumbnailUrl
        self.videoId = videoId
        self.browseId = browseId
    }
}

/// One carousel of the Home feed, Library or an artist page.
public struct HomeShelf: Codable, Hashable, Sendable {
    public var title: String
    public var items: [ShelfItem]
    /// YouTube's "strapline": the grey line Apple Music runs under a heading.
    public var subtitle: String
    public var moreBrowseId: String?
    public var moreParams: String?

    public init(
        title: String,
        items: [ShelfItem],
        subtitle: String = "",
        moreBrowseId: String? = nil,
        moreParams: String? = nil
    ) {
        self.title = title
        self.items = items
        self.subtitle = subtitle
        self.moreBrowseId = moreBrowseId
        self.moreParams = moreParams
    }
}

/// A page of the Home feed, plus the token for the next one (nil once exhausted).
public struct HomeFeed: Codable, Hashable, Sendable {
    public var shelves: [HomeShelf]
    public var continuation: String?

    public init(shelves: [HomeShelf], continuation: String?) {
        self.shelves = shelves
        self.continuation = continuation
    }
}

/// One server-defined group of the buttons shown on Explore.
public struct MoodGenreSection: Codable, Hashable, Sendable {
    public var title: String
    public var items: [MoodGenre]

    public init(title: String, items: [MoodGenre]) {
        self.title = title
        self.items = items
    }
}

/// A mood or genre button and the exact browse request it represents.
public struct MoodGenre: Codable, Hashable, Sendable, Identifiable {
    public var title: String
    public var browseId: String
    public var params: String?
    /// First real cover from the category's playlist shelves, loaded in the background.
    public var thumbnailUrl: String?

    public init(title: String, browseId: String, params: String?, thumbnailUrl: String? = nil) {
        self.title = title
        self.browseId = browseId
        self.params = params
        self.thumbnailUrl = thumbnailUrl
    }

    /// Browse id and params together: every mood shares one browse id and differs by params.
    public var id: String { "\(browseId)|\(params ?? "")" }
}
