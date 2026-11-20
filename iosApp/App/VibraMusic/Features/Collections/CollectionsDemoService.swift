#if DEBUG
import VibraMusicCore
import Canvas
import Downloads
import Foundation
import InnerTube
import Replay

/// Debug builds only: launched with `-collectionsDemo`, the Collections screens act as if a listener
/// were signed in, so the signed-in Library, the save and subscribe circles and the account rows of
/// the menus can be seen (and screenshotted) on a simulator with no Google account. The "library"
/// is real YouTube Music content found by searching; pages load live; every account write succeeds
/// without being sent.
@MainActor
final class CollectionsDemoService: CollectionsService {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-collectionsDemo") }

    private let live: LiveCollectionsService
    private let repository: YTMusicRepository
    private var owned: Set<String> = []

    init(live: LiveCollectionsService, repository: YTMusicRepository) {
        self.live = live
        self.repository = repository
    }

    var isSignedIn: Bool { true }
    var listenerKey: String? { "demo" }
    var accountName: String { "Demo Listener" }

    private func browseItems(_ query: String, _ filter: SearchFilter) async -> [BrowseItem] {
        let rows = (try? await repository.search(query: query, filter: filter)) ?? []
        return rows.compactMap { row in
            if case .browse(let item) = row { return item }
            return nil
        }
    }

    private func cards(_ items: [BrowseItem]) -> [ShelfItem] {
        items.map { ShelfItem(title: $0.title, subtitle: $0.subtitle, thumbnailUrl: $0.thumbnailUrl, videoId: nil, browseId: $0.browseId) }
    }

    func library() async throws -> LibraryPage {
        async let playlists = browseItems("Daft Punk", .playlists)
        async let albums = browseItems("Daft Punk", .albums)
        async let artists = browseItems("French house", .artists)
        let found = await (playlists, albums, artists)
        owned = Set(found.0.prefix(2).map(\.browseId))
        let liked = ShelfItem(title: "Liked Music", subtitle: "Auto playlist", thumbnailUrl: found.1.first?.thumbnailUrl, videoId: nil,
                              browseId: YTMusicRepository.likedMusicBrowseId)
        return LibraryPage(likedSongs: [], librarySongs: [], shelves: [
            HomeShelf(title: YTMusicRepository.playlistsShelfTitle, items: [liked] + cards(found.0)),
            HomeShelf(title: "Albums", items: cards(found.1)),
            HomeShelf(title: "Artists", items: cards(Array(found.2.prefix(4)))),
            HomeShelf(title: "Subscriptions", items: cards(Array(found.2.suffix(3)))),
        ])
    }

    func syncLikedMusic(from token: String) async {}

    func userPlaylists() async throws -> [UserPlaylist] {
        await browseItems("Daft Punk", .playlists).map {
            UserPlaylist(playlistId: String($0.browseId.dropFirst(2)), title: $0.title, subtitle: $0.subtitle, thumbnailUrl: $0.thumbnailUrl)
        }
    }

    func history() async throws -> [Song] {
        try await repository.search(query: "Daft Punk", filter: .songs).compactMap(\.song)
    }

    func browseSongs(_ browseId: String) async throws -> YTMusicRepository.SongPage {
        var page = try await live.browseSongs(browseId)
        if page.library == nil { page.library = LibraryState(playlistId: browseId, saved: false) }
        if owned.contains(browseId) { page.owned = true }
        return page
    }

    func moreSongs(_ token: String) async throws -> YTMusicRepository.SongPage { try await live.moreSongs(token) }

    func artistPage(_ browseId: String) async throws -> ArtistPage {
        var page = try await live.artistPage(browseId)
        if page.subscription == nil { page.subscription = SubscriptionState(channelId: browseId, subscribed: false) }
        return page
    }

    func allSongs(_ browseId: String) async throws -> [Song] { try await live.allSongs(browseId) }
    func shelfItems(_ browseId: String) async throws -> [ShelfItem] { try await live.shelfItems(browseId) }
    func playlistOwned(_ browseId: String) async throws -> Bool? { owned.contains(browseId) }
    func setSaved(playlistId: String, saved: Bool) async throws {}
    func setSubscribed(channelId: String, subscribed: Bool) async throws {}
    func createPlaylist(title: String, privacy: PlaylistPrivacy, videoIds: [String]) async throws -> String { "PLdemo\(UUID().uuidString.prefix(6))" }
    func addToPlaylist(playlistId: String, videoIds: [String]) async throws -> [String: String] { [:] }
    func removeFromPlaylist(playlistId: String, entries: [PlaylistEntryRef]) async throws {}
    func renamePlaylist(playlistId: String, title: String) async throws {}
    func deletePlaylist(playlistId: String) async throws {}
    func songMenu(videoId: String) async throws -> SongMenu {
        SongMenu(likeStatus: nil, inLibrary: false, addToLibraryToken: nil, removeFromLibraryToken: nil)
    }
    func setLibraryStatus(token: String) async throws {}
    func downloadedPlaylistSongs(_ browseId: String) -> [Song]? { live.downloadedPlaylistSongs(browseId) }
    func localSongs(_ browseId: String) -> [Song]? { live.localSongs(browseId) }
    var downloadedPlaylists: [SavedCollection] { live.downloadedPlaylists }

    func replayCards() async -> (cards: [ReplayHeroCard], memberSince: String?) {
        // `-collectionsDemoNoReplay`: a listener with nothing to show yet, so the banner is drawn.
        if ProcessInfo.processInfo.arguments.contains("-collectionsDemoNoReplay") { return ([], nil) }
        let songs = (try? await history()) ?? []
        guard let top = songs.first else { return ([], nil) }
        return ([
            ReplayHeroCard(label: L10n.minutesListened, value: "5,231", detail: "1,204 plays · 2026", artworkUrl: top.thumbnailUrl, page: .minutes),
            ReplayHeroCard(label: L10n.topSong, value: top.title, detail: "\(top.artist) · 212 plays", artworkUrl: top.thumbnailUrl, page: .songs),
        ], "03/24")
    }

    func albumCanvas(_ album: String, artist: String, spotifyFirst: Bool) async -> CanvasArtwork? {
        await live.albumCanvas(album, artist: artist, spotifyFirst: spotifyFirst)
    }

    func downloadState(_ videoId: String) -> DownloadState? { live.downloadState(videoId) }
    func isDownloaded(_ videoId: String) -> Bool { live.isDownloaded(videoId) }
    func cancelDownload(_ videoId: String) { live.cancelDownload(videoId) }
    func deleteDownload(_ videoId: String) { live.deleteDownload(videoId) }
    func dismissDownloadFailure(_ videoId: String) { live.dismissDownloadFailure(videoId) }
    var isWaitingForWiFi: Bool { live.isWaitingForWiFi }
    func downloadRecordId(for browseId: String) -> String? { live.downloadRecordId(for: browseId) }
    func deleteDownloadedCollection(_ recordId: String) { live.deleteDownloadedCollection(recordId) }
    func releaseIsDownloading(_ browseId: String) -> Bool { live.releaseIsDownloading(browseId) }
}
#endif
