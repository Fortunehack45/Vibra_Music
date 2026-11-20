import VibraMusicCore
import PlaybackQueue
import SwiftUI

/// What tapping or holding something on a Browse screen does (MainActivity.kt's `onItemClick`,
/// `onShelfLongPress`, and Search's `onSongClick` / `onBrowseClick` / `onHistoryClick`), kept apart
/// from the views so the rules can be tested.
@MainActor
struct BrowseNavigator {
    let player: PlayerController
    let router: AppRouter
    let history: SearchHistory

    init(app: AppModel) {
        player = app.player
        router = app.router
        history = app.searchHistory
    }

    // MARK: Cards (Home, a mood page)

    /// A song card starts a one-off from itself (`playRadio`: it plays, the listener's queue follows
    /// and AutoPlay carries on); any other card opens its page.
    func openCard(_ item: ShelfItem, source: QueueSource) {
        if let song = item.shelfSong {
            player.playSong(song, source: source)
        } else if let page = item.shelfBrowseItem {
            router.open(AppRoute.item(page))
        }
    }

    /// Holding a card: the track menu for a song, the album / playlist menu for a collection,
    /// nothing for an artist.
    func openCardMenu(_ item: ShelfItem) {
        if let song = item.shelfSong {
            Haptics.shared.play(.tap)
            router.present(.songActions(song))
        } else if let page = item.shelfBrowseItem, page.type != .artist {
            Haptics.shared.play(.tap)
            router.present(.browseActions(page))
        }
    }

    // MARK: Search

    /// A search hit: remembered as a recent search, then played as a one-off.
    func playSearchHit(_ song: Song) {
        history.record(SearchHistoryEntity(song: song))
        player.playSong(song, source: QueueSource(title: L10n.search, type: .search))
    }

    /// An album, playlist or artist hit: remembered, then opened.
    func openSearchHit(_ item: BrowseItem) {
        history.record(SearchHistoryEntity(item: item))
        router.open(AppRoute.item(item))
    }

    /// A recent search plays or opens directly, without being re-recorded (which would bump its
    /// timestamp and float it to the top).
    func openRecent(_ entity: SearchHistoryEntity) {
        switch entity.entityType {
        case .track:
            let song = Song(videoId: entity.id, title: entity.title, artist: entity.subtitle, thumbnailUrl: entity.artworkUrl)
            player.playSong(song, source: QueueSource(title: entity.title, type: .search))
        case .album, .artist, .playlist:
            let fallback: BrowseType = switch entity.entityType {
            case .album: .album
            case .artist: .artist
            default: .playlist
            }
            router.open(AppRoute.item(BrowseItem(
                browseId: entity.id, title: entity.title, subtitle: entity.subtitle, thumbnailUrl: entity.artworkUrl,
                type: BrowseType.of(browseId: entity.id, fallback: fallback)
            )))
        }
    }
}
