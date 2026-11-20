import VibraMusicCore
import Foundation
import InnerTube
import PlaybackQueue

/// "Play X": Android's `MEDIA_PLAY_FROM_SEARCH` as MainActivity serves it (MusicLink.consume and the
/// `LinkRequest.Search(play = true)` / `LinkRequest.Resume` branches).
@MainActor
enum VoicePlayback {
    typealias SongSearch = @MainActor (String) async -> [Song]

    /// A spoken request is an instruction, so the best match starts playing (and AutoPlay carries
    /// on from it) rather than a list waiting on a phone in a pocket. If nothing matches, the
    /// results are a better answer than silence, so the app opens its search on the words. With
    /// nothing named ("play music"), what was playing carries on.
    static func play(request: String?, player: PlayerController, router: AppRouter, search: SongSearch) async -> SystemPlayOutcome {
        let query = request?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if query.isEmpty {
            // A cold start has already restored last session's queue (SystemAppAccess); this
            // covers a player that was emptied since.
            if player.currentSong == nil { _ = player.restore() }
            guard player.currentSong != nil else { return .nothingToPlay }
            player.play()
            return .resumed
        }
        if let top = await search(query).first {
            player.playSong(top, source: QueueSource(title: L10n.search, type: .search))
            return .playing
        }
        router.handle(.search(query: query, play: false), player: player) { _ in nil }
        return .showedSearch
    }

    /// Songs only, the way MainActivity searches for a spoken request (`SearchFilter.SONGS`).
    static func searchSongs(_ repository: YTMusicRepository) -> SongSearch {
        { query in
            let results = (try? await repository.search(query: query, filter: .songs)) ?? []
            return results.compactMap { result in
                if case .track(let song) = result { return song }
                return nil
            }
        }
    }
}
