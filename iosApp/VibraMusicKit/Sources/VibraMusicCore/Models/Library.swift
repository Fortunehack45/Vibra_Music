import Foundation

// Ports data/model/Models.kt (account, library, detail and rating types).

/// The signed-in Google account, as YouTube Music reports it.
public struct Account: Codable, Hashable, Sendable {
    public var name: String
    public var email: String
    public var thumbnailUrl: String?

    public init(name: String, email: String, thumbnailUrl: String?) {
        self.name = name
        self.email = email
        self.thumbnailUrl = thumbnailUrl
    }
}

/// One identity the signed-in session can act as: the account's own channel, or a brand channel
/// it owns.
///
/// A brand channel is a separate YouTube identity on the same login, and YouTube Music treats it as
/// a separate listener with its own library, likes, history and recommendations. Nothing in the
/// cookie says which one is meant, so a client that never asks gets whichever one the web player
/// defaults to — which is how a listener whose music lives on a brand channel signs in and sees a
/// stranger's account.
public struct AccountChannel: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var subtitle: String
    public var thumbnailUrl: String?
    /// `X-Goog-PageId`. Nil for the account's own channel, which is not a delegated page and must
    /// not be given one.
    public var pageId: String?
    /// `context.user.onBehalfOfUser`, taken from the switcher's `datasyncIdToken`. Never guessed:
    /// Google answers one it can't tie to the session with 401.
    public var dataSyncId: String?
    /// Whether YouTube's own switcher marks this as the session's active one.
    public var activeOnWeb: Bool

    public init(
        name: String,
        subtitle: String,
        thumbnailUrl: String?,
        pageId: String?,
        dataSyncId: String?,
        activeOnWeb: Bool
    ) {
        self.name = name
        self.subtitle = subtitle
        self.thumbnailUrl = thumbnailUrl
        self.pageId = pageId
        self.dataSyncId = dataSyncId
        self.activeOnWeb = activeOnWeb
    }

    /// Identity of the selection, stable across refetches of the list.
    public var key: String { pageId ?? dataSyncId ?? name }

    public var id: String { key }
}

/// The signed-in library as YouTube Music splits it: the auto-generated Liked Music playlist, the
/// tracks explicitly added to the library, and a shelf per saved collection.
public struct LibraryPage: Codable, Hashable, Sendable {
    public var likedSongs: [Song]
    public var librarySongs: [Song]
    public var shelves: [HomeShelf]
    /// The continuation behind `likedSongs`' first page, when Liked Music has more. Consumed by
    /// whoever owns the library's lifecycle to finish syncing likes into ``LikeState``; never
    /// stored as page state.
    public var likedContinuation: String?

    public init(likedSongs: [Song], librarySongs: [Song], shelves: [HomeShelf], likedContinuation: String? = nil) {
        self.likedSongs = likedSongs
        self.librarySongs = librarySongs
        self.shelves = shelves
        self.likedContinuation = likedContinuation
    }

    public var isEmpty: Bool { likedSongs.isEmpty && librarySongs.isEmpty && shelves.isEmpty }
}

/// A browsed album, artist or playlist page.
public struct DetailPage: Codable, Hashable, Sendable {
    public var browseId: String
    public var title: String
    public var subtitle: String
    public var thumbnailUrl: String?
    public var songs: LoadState<[Song]>
    public var type: BrowseType
    /// Albums and singles carousels, populated for artist pages.
    public var sections: [HomeShelf]
    /// Tracks YouTube offers to round out a playlist but that were never added. Shown as their own
    /// section with a button to add them, rather than folded into `songs` where they'd read as the
    /// user's own picks.
    public var suggestedSongs: [Song]
    /// Whether this release can be saved to the library and whether it is; nil when the page doesn't
    /// offer it. Only set for an album or playlist fetched with a session.
    public var library: LibraryState?
    /// The editorial blurb for a release or artist; absent for most playlists.
    public var description: String?
    /// "1.2M subscribers" off an artist page's header.
    public var subscriberCountText: String?
    /// "3.4M monthly listeners" off an artist page's header.
    public var monthlyListenerCount: String?
    /// Whether this artist's channel can be subscribed to and whether it is; nil when the page
    /// doesn't offer it. Only set for an artist page fetched with a session.
    public var subscription: SubscriptionState?

    public init(
        browseId: String,
        title: String,
        subtitle: String,
        thumbnailUrl: String?,
        songs: LoadState<[Song]>,
        type: BrowseType = .other,
        sections: [HomeShelf] = [],
        suggestedSongs: [Song] = [],
        library: LibraryState? = nil,
        description: String? = nil,
        subscriberCountText: String? = nil,
        monthlyListenerCount: String? = nil,
        subscription: SubscriptionState? = nil
    ) {
        self.browseId = browseId
        self.title = title
        self.subtitle = subtitle
        self.thumbnailUrl = thumbnailUrl
        self.songs = songs
        self.type = type
        self.sections = sections
        self.suggestedSongs = suggestedSongs
        self.library = library
        self.description = description
        self.subscriberCountText = subscriberCountText
        self.monthlyListenerCount = monthlyListenerCount
        self.subscription = subscription
    }
}

/// Whether an album or playlist is in the library, and the id that changes that.
///
/// YouTube has no "save" verb for a release: a saved album is a *liked* one, and what gets liked is
/// the playlist behind the page (an `MPREb…` album is backed by an `OLAK5uy_…` playlist), not the
/// browse id the page was fetched with. So the id is read off the page.
public struct LibraryState: Codable, Hashable, Sendable {
    public var playlistId: String
    public var saved: Bool

    public init(playlistId: String, saved: Bool) {
        self.playlistId = playlistId
        self.saved = saved
    }
}

/// Whether an artist's channel is subscribed to, and the `UC…` channel that changes.
public struct SubscriptionState: Codable, Hashable, Sendable {
    public var channelId: String
    public var subscribed: Bool

    public init(channelId: String, subscribed: Bool) {
        self.channelId = channelId
        self.subscribed = subscribed
    }
}

/// A parsed artist landing page.
public struct ArtistPage: Codable, Hashable, Sendable {
    public var songs: [Song]
    /// Playlist holding the artist's full song list, when the page links one.
    public var moreSongsBrowseId: String?
    public var sections: [HomeShelf]
    /// The artist's own picture, off the page header.
    public var thumbnailUrl: String?
    /// The single artist this page is for, as the header bills them.
    public var name: String?
    public var description: String?
    public var subscriberCountText: String?
    public var monthlyListenerCount: String?
    /// The header's subscribe button, when the page carries one.
    public var subscription: SubscriptionState?

    public init(
        songs: [Song],
        moreSongsBrowseId: String?,
        sections: [HomeShelf],
        thumbnailUrl: String? = nil,
        name: String? = nil,
        description: String? = nil,
        subscriberCountText: String? = nil,
        monthlyListenerCount: String? = nil,
        subscription: SubscriptionState? = nil
    ) {
        self.songs = songs
        self.moreSongsBrowseId = moreSongsBrowseId
        self.sections = sections
        self.thumbnailUrl = thumbnailUrl
        self.name = name
        self.description = description
        self.subscriberCountText = subscriberCountText
        self.monthlyListenerCount = monthlyListenerCount
        self.subscription = subscription
    }
}

/// A track's thumbs rating on the signed-in account.
///
/// `indifferent` is YouTube's word for "neither" and is a real state: clearing a like is a request
/// in its own right (`like/removelike`), not the omission of one.
public enum LikeStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case like = "LIKE"
    case dislike = "DISLIKE"
    case indifferent = "INDIFFERENT"
}

/// Who can see a playlist. YouTube's own three values, sent verbatim (``apiValue``).
public enum PlaylistPrivacy: String, Codable, Hashable, Sendable, CaseIterable {
    case `private` = "PRIVATE"
    case unlisted = "UNLISTED"
    case `public` = "PUBLIC"

    public var label: String {
        switch self {
        case .private: return "Private"
        case .unlisted: return "Unlisted"
        case .public: return "Public"
        }
    }

    /// The value the playlist create/edit endpoints take.
    public var apiValue: String { rawValue }
}

/// One of the account's own playlists, as the picker lists them.
///
/// `playlistId` is the raw id (no `VL`), which is what the edit endpoint takes; ``browseId`` is the
/// same playlist addressed as a page.
public struct UserPlaylist: Codable, Hashable, Sendable, Identifiable {
    public var playlistId: String
    public var title: String
    public var subtitle: String
    public var thumbnailUrl: String?

    public init(playlistId: String, title: String, subtitle: String, thumbnailUrl: String?) {
        self.playlistId = playlistId
        self.title = title
        self.subtitle = subtitle
        self.thumbnailUrl = thumbnailUrl
    }

    public var browseId: String { "VL\(playlistId)" }
    public var id: String { playlistId }
}

/// The per-track state only YouTube can answer: its rating, and whether it is in the library.
///
/// Library membership isn't addressable by video id — it's toggled with opaque feedback tokens
/// YouTube mints per row and per direction, so the tokens are fetched before the action can be
/// offered. Both arrive on the watch queue's menu, hence one lookup.
public struct SongMenu: Codable, Hashable, Sendable {
    /// The rating stated on this row, or nil when the row states none — which is common and is
    /// *not* the same as `.indifferent`. Reading that silence as "not liked" is how a liked song
    /// ends up claiming it isn't.
    public var likeStatus: LikeStatus?
    public var inLibrary: Bool
    public var addToLibraryToken: String?
    public var removeFromLibraryToken: String?

    public init(likeStatus: LikeStatus?, inLibrary: Bool, addToLibraryToken: String?, removeFromLibraryToken: String?) {
        self.likeStatus = likeStatus
        self.inLibrary = inLibrary
        self.addToLibraryToken = addToLibraryToken
        self.removeFromLibraryToken = removeFromLibraryToken
    }
}

/// Loading / loaded / failed, for any asynchronously fetched value (Android's `UiState`).
public enum LoadState<Value> {
    case loading
    case success(Value)
    /// A user-presentable message.
    case error(String)

    /// The loaded value, or nil while loading or after a failure.
    public var value: Value? {
        if case .success(let value) = self { return value }
        return nil
    }

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    public var errorMessage: String? {
        if case .error(let message) = self { return message }
        return nil
    }

    public func map<T>(_ transform: (Value) throws -> T) rethrows -> LoadState<T> {
        switch self {
        case .loading: return .loading
        case .success(let value): return .success(try transform(value))
        case .error(let message): return .error(message)
        }
    }
}

extension LoadState: Equatable where Value: Equatable {}
extension LoadState: Hashable where Value: Hashable {}
extension LoadState: Sendable where Value: Sendable {}
extension LoadState: Codable where Value: Codable {}
