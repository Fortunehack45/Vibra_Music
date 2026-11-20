import VibraMusicCore
import Canvas
import Downloads
import Foundation
import InnerTube
import Replay

// What the Collections screens ask of the outside world: YouTube Music (YTMusicRepository), the
// account's sign-in state and the download library. A protocol so the view models are tested
// against a fake (CollectionsTestSupport) rather than the network.

@MainActor
protocol CollectionsService: AnyObject {
    /// Whether a YouTube Music account is signed in — every account write is refused without one.
    var isSignedIn: Bool { get }
    /// Who is signed in, so a library or history fetched for one listener is never shown to the
    /// next (MainViewModel's `listenerKey`).
    var listenerKey: String? { get }
    /// The signed-in account's name — the cardholder on Replay's cards.
    var accountName: String { get }

    func library() async throws -> LibraryPage
    /// Finishes seeding Liked Music's later pages into LikeState.
    func syncLikedMusic(from token: String) async
    func userPlaylists() async throws -> [UserPlaylist]
    func history() async throws -> [Song]

    func browseSongs(_ browseId: String) async throws -> YTMusicRepository.SongPage
    func moreSongs(_ token: String) async throws -> YTMusicRepository.SongPage
    func artistPage(_ browseId: String) async throws -> ArtistPage
    func allSongs(_ browseId: String) async throws -> [Song]
    func shelfItems(_ browseId: String) async throws -> [ShelfItem]
    func playlistOwned(_ browseId: String) async throws -> Bool?

    func setSaved(playlistId: String, saved: Bool) async throws
    func setSubscribed(channelId: String, subscribed: Bool) async throws
    func createPlaylist(title: String, privacy: PlaylistPrivacy, videoIds: [String]) async throws -> String
    func addToPlaylist(playlistId: String, videoIds: [String]) async throws -> [String: String]
    func removeFromPlaylist(playlistId: String, entries: [PlaylistEntryRef]) async throws
    func renamePlaylist(playlistId: String, title: String) async throws
    func deletePlaylist(playlistId: String) async throws
    func songMenu(videoId: String) async throws -> SongMenu
    func setLibraryStatus(token: String) async throws

    /// The tracks of a downloaded playlist's page (`local:playlist:<id>`), still on disk, in the
    /// order the playlist had; nil for any other id.
    func downloadedPlaylistSongs(_ browseId: String) -> [Song]?
    /// The tracks behind one of the on-device cards (Downloads, Local music, a downloaded
    /// playlist); nil for anything else.
    func localSongs(_ browseId: String) -> [Song]?
    /// The playlists downloaded whole — cards on the Library's On device shelf.
    var downloadedPlaylists: [SavedCollection] { get }
    /// Replay's headline cards for this year, and the "member since" date on them.
    func replayCards() async -> (cards: [ReplayHeroCard], memberSince: String?)
    /// The looping clip a label publishes for a release, for an album page's header; nil — the usual
    /// answer — leaves the still sleeve (DetailScreen.kt's `CanvasRepository.canvasForAlbum`).
    func albumCanvas(_ album: String, artist: String, spotifyFirst: Bool) async -> CanvasArtwork?

    // Downloads (the song menu's Download row, the release menu's "Download all").
    func downloadState(_ videoId: String) -> DownloadState?
    func isDownloaded(_ videoId: String) -> Bool
    func cancelDownload(_ videoId: String)
    func deleteDownload(_ videoId: String)
    func dismissDownloadFailure(_ videoId: String)
    /// Whether the queue is holding for Wi-Fi (Wi-Fi only on, connection metered) — the held row's
    /// "why it isn't moving" label.
    var isWaitingForWiFi: Bool { get }
    /// The download record a release was saved whole under, if it was (MainActivity's
    /// `downloadIdFor`).
    func downloadRecordId(for browseId: String) -> String?
    func deleteDownloadedCollection(_ recordId: String)
    /// Whether any track this release asked the queue for is still queued or running.
    func releaseIsDownloading(_ browseId: String) -> Bool
}

/// The app's service: the shared repository, the account manager and the download library.
@MainActor
final class LiveCollectionsService: CollectionsService {
    private let repository: YTMusicRepository
    private let accounts: YouTubeAccountManager
    private let downloadLibrary: () -> DownloadLibrary
    private let replayStats: () -> ReplayListeningStats
    private let downloads: () -> DownloadManager
    private let canvas: () -> CanvasRepository

    init(
        repository: YTMusicRepository,
        accounts: YouTubeAccountManager,
        downloadLibrary: @escaping () -> DownloadLibrary,
        downloads: @escaping () -> DownloadManager,
        replayStats: @escaping () -> ReplayListeningStats,
        canvas: @escaping () -> CanvasRepository
    ) {
        self.canvas = canvas
        self.repository = repository
        self.accounts = accounts
        self.downloadLibrary = downloadLibrary
        self.downloads = downloads
        self.replayStats = replayStats
    }

    var isSignedIn: Bool { accounts.isSignedIn }
    var accountName: String { accounts.account?.name ?? "" }

    var listenerKey: String? {
        guard accounts.isSignedIn else { return nil }
        return [accounts.activeAccountId, accounts.activeProfileId, accounts.selectedChannelKey]
            .map { $0 ?? "" }
            .joined(separator: "|")
    }

    func library() async throws -> LibraryPage { try await repository.library() }
    func syncLikedMusic(from token: String) async { await repository.syncLikedMusic(from: token) }
    func userPlaylists() async throws -> [UserPlaylist] { try await repository.userPlaylists() }
    func history() async throws -> [Song] { try await repository.history() }
    func browseSongs(_ browseId: String) async throws -> YTMusicRepository.SongPage { try await repository.browseSongs(browseId: browseId) }
    func moreSongs(_ token: String) async throws -> YTMusicRepository.SongPage { try await repository.moreSongs(token: token) }
    func artistPage(_ browseId: String) async throws -> ArtistPage { try await repository.artistPage(browseId: browseId) }
    func allSongs(_ browseId: String) async throws -> [Song] { try await repository.allSongs(browseId: browseId) }
    func shelfItems(_ browseId: String) async throws -> [ShelfItem] { try await repository.shelfItems(browseId: browseId) }
    func playlistOwned(_ browseId: String) async throws -> Bool? { try await repository.playlistOwned(browseId: browseId) }
    func setSaved(playlistId: String, saved: Bool) async throws { try await repository.setSaved(playlistId: playlistId, saved: saved) }
    func setSubscribed(channelId: String, subscribed: Bool) async throws {
        try await repository.setSubscribed(channelId: channelId, subscribed: subscribed)
    }
    func createPlaylist(title: String, privacy: PlaylistPrivacy, videoIds: [String]) async throws -> String {
        try await repository.createPlaylist(title: title, privacy: privacy, videoIds: videoIds)
    }
    func addToPlaylist(playlistId: String, videoIds: [String]) async throws -> [String: String] {
        try await repository.addToPlaylist(playlistId: playlistId, videoIds: videoIds)
    }
    func removeFromPlaylist(playlistId: String, entries: [PlaylistEntryRef]) async throws {
        try await repository.removeFromPlaylist(playlistId: playlistId, entries: entries)
    }
    func renamePlaylist(playlistId: String, title: String) async throws { try await repository.renamePlaylist(playlistId: playlistId, title: title) }
    func deletePlaylist(playlistId: String) async throws { try await repository.deletePlaylist(playlistId: playlistId) }
    func songMenu(videoId: String) async throws -> SongMenu { try await repository.songMenu(videoId: videoId) }
    func setLibraryStatus(token: String) async throws { try await repository.setLibraryStatus(token: token) }

    func downloadedPlaylistSongs(_ browseId: String) -> [Song]? {
        guard let id = DownloadLibrary.recordId(of: browseId) else { return nil }
        return downloadLibrary().collectionSongs(id)
    }

    func downloadState(_ videoId: String) -> DownloadState? { downloads().active[videoId] }
    func isDownloaded(_ videoId: String) -> Bool { downloadLibrary().isDownloaded(videoId) }
    func cancelDownload(_ videoId: String) { downloads().cancel(videoId) }
    func deleteDownload(_ videoId: String) { _ = downloadLibrary().delete(videoId) }
    func dismissDownloadFailure(_ videoId: String) { downloads().dismissFailure(videoId) }
    var isWaitingForWiFi: Bool { downloads().isWaitingForWiFi }

    func downloadRecordId(for browseId: String) -> String? {
        let library = downloadLibrary()
        let id = DownloadLibrary.recordId(of: browseId) ?? browseId
        return library.collections[id] == nil ? nil : id
    }

    func deleteDownloadedCollection(_ recordId: String) { _ = downloadLibrary().deleteCollection(recordId) }

    func releaseIsDownloading(_ browseId: String) -> Bool {
        let active = downloads().active
        return (downloadLibrary().requested[browseId] ?? []).contains { active[$0]?.isInFlight == true }
    }

    func localSongs(_ browseId: String) -> [Song]? {
        switch browseId {
        case LocalBrowseID.downloads: return downloadLibrary().songs(includeImported: false)
        case LocalBrowseID.all: return downloadLibrary().songs(includeImported: true)
        default: return downloadedPlaylistSongs(browseId)
        }
    }

    var downloadedPlaylists: [SavedCollection] { downloadLibrary().savedPlaylists() }

    func albumCanvas(_ album: String, artist: String, spotifyFirst: Bool) async -> CanvasArtwork? {
        await canvas().canvasForAlbum(album, artist: artist, spotifyFirst: spotifyFirst)
    }

    func replayCards() async -> (cards: [ReplayHeroCard], memberSince: String?) {
        let stats = replayStats()
        let labels = ReplayHeroCardLabels(minutesListened: L10n.minutesListened, topSong: L10n.topSong,
                                          topArtist: L10n.topArtist, topAlbum: L10n.topAlbum)
        // Merging the month files is disk work; kept off the main thread.
        return await Task.detached(priority: .utility) {
            let summary = stats.summary(for: .thisYear)
            let cards = summary.isEmpty ? [] : replayHeroCards(for: summary, labels: labels)
            return (cards, stats.months().first?.memberSince)
        }.value
    }
}
