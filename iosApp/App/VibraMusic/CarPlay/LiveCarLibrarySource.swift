import VibraMusicCore
import Foundation
import InnerTube

/// The car's folders from the running app: YouTube Music through the repository, downloads and
/// imported files from the download library.
@MainActor
final class LiveCarLibrarySource: CarLibrarySource {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func isSignedIn() async -> Bool {
        await model.innerTube.isSignedIn
    }

    var accountKey: String? { model.accounts.listenerKey }

    func recents() async throws -> [Song] {
        try await model.repository.recents()
    }

    func quickPicks(excluding: Set<String>) async throws -> [Song] {
        try await model.repository.quickPicks(excluding: excluding)
    }

    func homeSongs() async -> [Song] {
        let repository = model.repository
        let feed = await withDeadline(.seconds(2.5)) { try? await repository.home() }
        return (feed?.shelves ?? []).flatMap(\.items).compactMap { item in
            guard let videoId = item.videoId else { return nil }
            return Song(videoId: videoId, title: item.title, artist: InnerTubeParser.artistFromSubtitle(item.subtitle), thumbnailUrl: item.thumbnailUrl)
        }
    }

    /// Liked Music, trying the ids PlaybackService does in turn: the liked playlist, its bare id,
    /// the library's "liked" card, then liked videos. Whatever loads seeds the like state.
    func likedSongs() async throws -> [Song] {
        let repository = model.repository
        var songs = (try? await repository.browseSongs(browseId: YTMusicRepository.likedMusicBrowseId).songs) ?? []
        if songs.isEmpty { songs = (try? await repository.browseSongs(browseId: "LM").songs) ?? [] }
        if songs.isEmpty,
           let card = try? await repository.libraryPlaylists().first(where: { $0.browseId == "VLLM" || $0.title.localizedCaseInsensitiveContains("liked") }),
           let browseId = card.browseId {
            songs = (try? await repository.browseSongs(browseId: browseId).songs) ?? []
        }
        if songs.isEmpty { songs = (try? await repository.browseSongs(browseId: "FEmusic_liked_videos").songs) ?? [] }
        if !songs.isEmpty { model.likeState.seedLiked(Set(songs.map(\.videoId))) }
        return songs
    }

    /// The library's playlists, or the account's own ones when the library shelf can't be read.
    func libraryPlaylists() async throws -> [ShelfItem] {
        let repository = model.repository
        if let cards = try? await repository.libraryPlaylists(), !cards.isEmpty { return cards }
        return try await repository.userPlaylists().map {
            ShelfItem(title: $0.title, subtitle: $0.subtitle, thumbnailUrl: $0.thumbnailUrl, videoId: nil, browseId: $0.browseId)
        }
    }

    func songs(browseId: String) async throws -> [Song] {
        try await model.repository.browseSongs(browseId: browseId).songs
    }

    func search(_ query: String) async throws -> [SearchResult] {
        try await model.repository.search(query: query, filter: .all)
    }

    func downloadedSongs() -> [Song] {
        model.downloadLibrary.songs(includeImported: false)
    }

    /// iOS has no shared music folder for an app to scan; "Local Music" is what was imported from
    /// Files, the same library the app's Local Music screen lists.
    func localSongs() -> [Song] {
        model.downloadLibrary.importedSongs()
    }
}
