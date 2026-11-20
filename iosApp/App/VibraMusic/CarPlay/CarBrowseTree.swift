import VibraMusicCore
import Foundation
import InnerTube

// Ports the Android Auto browse tree in playback/PlaybackService.kt (MediaLibraryCallback:
// onGetLibraryRoot / onGetChildren / onGetItem / onSearch, and the cached folder loaders above it).
// Kept free of CarPlay so the tree can be tested without a car; CarPlaySceneDelegate draws it.

/// Media ids of the tree, as PlaybackService names them.
enum CarNodeID {
    static let root = "root"
    static let recents = "recents"
    static let quickPicks = "quick_picks"
    static let playlists = "playlists"
    static let more = "more"
    static let liked = "liked"
    static let downloads = "downloads"
    static let localMusic = "local_music"
    static let loginRequired = "msg:login_required"

    static let playlistPrefix = "playlist:"
    static let browsePrefix = "browse:"
}

/// One row of the car's browse tree.
enum CarNode: Equatable, Identifiable {
    /// A browsable folder: a root tab, More's entries, or a playlist / album to open.
    case folder(id: String, title: String, subtitle: String? = nil, artworkURL: String? = nil)
    /// A song; choosing it plays it.
    case song(Song)
    /// A message row that does nothing: an empty folder, or "sign in on your phone".
    case info(id: String, title: String, subtitle: String?)

    var id: String {
        switch self {
        case .folder(let id, _, _, _), .info(let id, _, _): return id
        case .song(let song): return song.videoId
        }
    }

    var title: String {
        switch self {
        case .folder(_, let title, _, _), .info(_, let title, _): return title
        case .song(let song): return song.title
        }
    }
}

/// Where the car's folders come from. The app's is ``LiveCarLibrarySource``; tests supply fixtures.
@MainActor
protocol CarLibrarySource: AnyObject, Sendable {
    func isSignedIn() async -> Bool
    /// Who the account folders belong to (`accountId:profileId`); a change drops them from the cache.
    var accountKey: String? { get }
    func recents() async throws -> [Song]
    func quickPicks(excluding: Set<String>) async throws -> [Song]
    /// Songs on the home feed's shelves: Quick Picks' fallback when it comes back empty.
    func homeSongs() async -> [Song]
    func likedSongs() async throws -> [Song]
    func libraryPlaylists() async throws -> [ShelfItem]
    func songs(browseId: String) async throws -> [Song]
    func search(_ query: String) async throws -> [SearchResult]
    func downloadedSongs() -> [Song]
    func localSongs() -> [Song]
}

/// The tree with PlaybackService's caching: each folder is fetched once and served from memory for
/// a short time, because the car re-asks every time a folder is opened (backing out and in again
/// included). A stale folder is shown at once and refreshed behind it (``onFolderRefreshed``).
@MainActor
final class CarLibrary {
    /// How long a folder is served without asking again (RECENTS 30 s, the others 60 s).
    static let recentsTTL: TimeInterval = 30
    static let folderTTL: TimeInterval = 60
    /// PlaybackService's network budgets: 4 s for a folder, 2.5 s to open a playlist, 3.5 s to search.
    static let folderTimeout: Duration = .seconds(4)
    static let pageTimeout: Duration = .seconds(2.5)
    static let searchTimeout: Duration = .seconds(3.5)
    static let maxSearchQueryCharacters = 200
    static let maxSearchCacheEntries = 20

    private let source: CarLibrarySource
    private let now: () -> Date
    /// A folder shown from a stale cache was refetched and has new rows.
    var onFolderRefreshed: ((String) -> Void)?

    private struct Cached<Value> {
        var at: Date
        var value: Value
    }

    private var recentsCache: Cached<[Song]>?
    private var quickPicksCache: Cached<[Song]>?
    private var likedCache: Cached<[Song]>?
    private var playlistsCache: Cached<[ShelfItem]>?
    /// The account liked songs and playlists were cached for.
    private var cachedAccountKey: String?
    private var searchCache: [(query: String, songs: [Song], pages: [BrowseItem])] = []
    /// Every song the tree has shown, by id, so a choice can be played with its full metadata.
    private(set) var songCache: [String: Song] = [:]

    init(source: CarLibrarySource, now: @escaping () -> Date = Date.init) {
        self.source = source
        self.now = now
    }

    // MARK: - Tree

    /// The five tabs, in Android Auto's order (AndroidAutoMediaLibraryTest.testGetTopLevelChildren).
    var rootFolders: [CarNode] {
        [
            .folder(id: CarNodeID.quickPicks, title: L10n.autoQuickPicks),
            .folder(id: CarNodeID.recents, title: L10n.autoRecents),
            .folder(id: CarNodeID.playlists, title: L10n.playlists),
            .folder(id: CarNodeID.liked, title: L10n.autoLiked),
            .folder(id: CarNodeID.more, title: L10n.more),
        ]
    }

    /// What a folder holds (onGetChildren).
    func children(of id: String) async -> [CarNode] {
        switch id {
        case CarNodeID.root:
            return rootFolders
        case CarNodeID.more:
            return [
                .folder(id: CarNodeID.downloads, title: L10n.downloads),
                .folder(id: CarNodeID.localMusic, title: L10n.localMusic),
            ]
        case CarNodeID.recents:
            let songs = await recents()
            return songs.isEmpty
                ? [.info(id: "msg:empty_recents", title: L10n.autoEmptyRecentsTitle, subtitle: L10n.autoEmptyRecentsSubtitle)]
                : rows(songs)
        case CarNodeID.quickPicks:
            let songs = await quickPicks()
            return songs.isEmpty
                ? [.info(id: "msg:empty_quick_picks", title: L10n.autoEmptyQuickPicksTitle, subtitle: L10n.autoEmptyQuickPicksSubtitle)]
                : rows(songs)
        case CarNodeID.liked:
            guard await source.isSignedIn() else { return [loginPrompt] }
            let songs = await liked()
            return songs.isEmpty
                ? [.info(id: "msg:empty_liked", title: L10n.autoEmptyLikedTitle, subtitle: L10n.autoEmptyLikedSubtitle)]
                : rows(songs)
        case CarNodeID.playlists:
            guard await source.isSignedIn() else { return [loginPrompt] }
            let playlists = await playlists()
            return playlists.isEmpty
                ? [.info(id: "msg:empty_playlists", title: L10n.autoEmptyPlaylistsTitle, subtitle: L10n.autoEmptyPlaylistsSubtitle)]
                : playlists.map(Self.playlistFolder)
        case CarNodeID.downloads:
            let songs = source.downloadedSongs()
            return songs.isEmpty
                ? [.info(id: "msg:empty_downloads", title: L10n.autoEmptyOfflineTitle, subtitle: L10n.autoEmptyOfflineSubtitle)]
                : rows(songs)
        case CarNodeID.localMusic:
            let songs = source.localSongs()
            return songs.isEmpty
                ? [.info(id: "msg:empty_local", title: L10n.autoEmptyOfflineTitle, subtitle: L10n.autoEmptyOfflineSubtitle)]
                : rows(songs)
        default:
            if id.hasPrefix(CarNodeID.playlistPrefix) {
                let playlistId = String(id.dropFirst(CarNodeID.playlistPrefix.count))
                return rows(await page("VL\(playlistId)", orElse: playlistId))
            }
            if id.hasPrefix(CarNodeID.browsePrefix) {
                return rows(await page(String(id.dropFirst(CarNodeID.browsePrefix.count)), orElse: nil))
            }
            return songCache[id].map { [.song($0)] } ?? []
        }
    }

    /// The car's search (onSearch / onGetSearchResult): songs first, then albums, artists and
    /// playlists as folders. On CarPlay this answers Siri ("play … in Vibra Music"): audio apps get no
    /// on-screen search template.
    func search(_ query: String) async -> [CarNode] {
        let safe = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxSearchQueryCharacters))
        guard !safe.isEmpty else { return [] }
        if let cached = searchCache.first(where: { $0.query == safe }) {
            return rows(cached.songs) + cached.pages.map(Self.pageFolder)
        }
        let source = self.source
        let results = await withDeadline(Self.searchTimeout) { @MainActor in try? await source.search(safe) } ?? []
        var seenSongs = Set<String>()
        let songs = results.compactMap(\.song).filter { seenSongs.insert($0.videoId).inserted }
        var seenPages = Set<String>()
        let pages = results.compactMap { result -> BrowseItem? in
            if case .browse(let item) = result { return item }
            return nil
        }.filter { seenPages.insert($0.browseId).inserted }
        // An empty answer may be a timeout or a dropped connection; remembering it would leave the
        // car with no results for this query for the rest of the drive.
        if !songs.isEmpty || !pages.isEmpty {
            while searchCache.count >= Self.maxSearchCacheEntries { searchCache.removeFirst() }
            searchCache.append((safe, songs, pages))
        }
        return rows(songs) + pages.map(Self.pageFolder)
    }

    /// The song a row stands for (a choice is played with what the tree loaded).
    func song(for id: String) -> Song? { songCache[id] }

    // MARK: - Rows

    private var loginPrompt: CarNode {
        .info(id: CarNodeID.loginRequired, title: L10n.autoLoginTitle, subtitle: L10n.autoLoginSubtitle)
    }

    private func rows(_ songs: [Song]) -> [CarNode] {
        for song in songs { songCache[song.videoId] = song }
        return songs.map(CarNode.song)
    }

    /// A library playlist card as a folder (shelfToGridPlaylistItem): `VL…` ids open as playlists,
    /// anything else (an album, a podcast) through its browse id.
    static func playlistFolder(_ item: ShelfItem) -> CarNode {
        let browseId = item.browseId ?? "VL\(item.videoId ?? "")"
        let id = browseId.hasPrefix("VL")
            ? CarNodeID.playlistPrefix + browseId.dropFirst(2)
            : CarNodeID.browsePrefix + browseId
        return .folder(id: id, title: item.title, subtitle: item.subtitle.isEmpty ? nil : item.subtitle, artworkURL: item.thumbnailUrl)
    }

    static func pageFolder(_ item: BrowseItem) -> CarNode {
        .folder(id: CarNodeID.browsePrefix + item.browseId, title: item.title,
                subtitle: item.subtitle.isEmpty ? nil : item.subtitle, artworkURL: item.thumbnailUrl)
    }

    // MARK: - Cached folders

    private func isFresh<Value>(_ cached: Cached<Value>?, ttl: TimeInterval) -> Bool {
        guard let cached else { return false }
        return now().timeIntervalSince(cached.at) < ttl
    }

    private func recents() async -> [Song] {
        if let cached = recentsCache, !cached.value.isEmpty {
            if !isFresh(recentsCache, ttl: Self.recentsTTL) { refreshInBackground(CarNodeID.recents) { await !$0.fetchRecents().isEmpty } }
            return cached.value
        }
        return await fetchRecents()
    }

    @discardableResult
    private func fetchRecents() async -> [Song] {
        let source = self.source
        let songs = await withDeadline(Self.folderTimeout) { @MainActor in try? await source.recents() } ?? []
        if !songs.isEmpty { recentsCache = Cached(at: now(), value: songs) }
        return songs
    }

    private func quickPicks() async -> [Song] {
        if let cached = quickPicksCache, !cached.value.isEmpty {
            if !isFresh(quickPicksCache, ttl: Self.folderTTL) { refreshInBackground(CarNodeID.quickPicks) { await !$0.fetchQuickPicks().isEmpty } }
            return cached.value
        }
        let fetched = await fetchQuickPicks()
        if !fetched.isEmpty { return fetched }
        // Nothing from Quick Picks: every song on the home feed's shelves, once each.
        var seen = Set<String>()
        return await source.homeSongs().filter { seen.insert($0.videoId).inserted }
    }

    /// Quick Picks leave out what is already in Recents, so the two tabs never repeat each other.
    @discardableResult
    private func fetchQuickPicks() async -> [Song] {
        // The car opens both tabs at once; without Recents in hand nothing would be left out.
        if recentsCache == nil { await fetchRecents() }
        let excluded = Set(recentsCache?.value.map(\.videoId) ?? [])
        let source = self.source
        let songs = await withDeadline(Self.folderTimeout) { @MainActor in try? await source.quickPicks(excluding: excluded) } ?? []
        if !songs.isEmpty { quickPicksCache = Cached(at: now(), value: songs) }
        return songs
    }

    private func liked() async -> [Song] {
        dropAccountFoldersIfAccountChanged()
        if let cached = likedCache, !cached.value.isEmpty {
            if !isFresh(likedCache, ttl: Self.folderTTL) { refreshInBackground(CarNodeID.liked) { await !$0.fetchLiked().isEmpty } }
            return cached.value
        }
        return await fetchLiked()
    }

    @discardableResult
    private func fetchLiked() async -> [Song] {
        let source = self.source
        let songs = await withDeadline(Self.folderTimeout) { @MainActor in try? await source.likedSongs() } ?? []
        if !songs.isEmpty { likedCache = Cached(at: now(), value: songs) }
        return songs
    }

    private func playlists() async -> [ShelfItem] {
        dropAccountFoldersIfAccountChanged()
        if let cached = playlistsCache, !cached.value.isEmpty {
            if !isFresh(playlistsCache, ttl: Self.folderTTL) { refreshInBackground(CarNodeID.playlists) { await !$0.fetchPlaylists().isEmpty } }
            return cached.value
        }
        return await fetchPlaylists()
    }

    @discardableResult
    private func fetchPlaylists() async -> [ShelfItem] {
        let source = self.source
        let cards = await withDeadline(.seconds(3)) { @MainActor in try? await source.libraryPlaylists() } ?? []
        if !cards.isEmpty { playlistsCache = Cached(at: now(), value: cards) }
        return cards
    }

    private func page(_ browseId: String, orElse fallback: String?) async -> [Song] {
        let source = self.source
        let songs = await withDeadline(Self.pageTimeout) { @MainActor in try? await source.songs(browseId: browseId) } ?? []
        if !songs.isEmpty { return songs }
        guard let fallback else { return [] }
        return await withDeadline(Self.pageTimeout) { @MainActor in try? await source.songs(browseId: fallback) } ?? []
    }

    /// Signing out (or in as someone else) drops what was cached for the account.
    func forgetAccountFolders() {
        likedCache = nil
        playlistsCache = nil
    }

    private func dropAccountFoldersIfAccountChanged() {
        let key = source.accountKey
        guard key != cachedAccountKey else { return }
        cachedAccountKey = key
        forgetAccountFolders()
    }

    private var refreshing: Set<String> = []

    private func refreshInBackground(_ id: String, _ fetch: @escaping @MainActor (CarLibrary) async -> Bool) {
        guard refreshing.insert(id).inserted else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let fresh = await fetch(self)
            self.refreshing.remove(id)
            if fresh { self.onFolderRefreshed?(id) }
        }
    }
}
