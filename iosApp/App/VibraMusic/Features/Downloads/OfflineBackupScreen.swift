import VibraMusicCore
import PlaybackQueue
import SwiftUI

/// Offline backup: every song already whole on this device. Tapping a row plays it with the rest
/// of the list behind it; all of it plays with no connection.
///
/// Read from the cache on every visit and when the player moves on, so it is whatever the cache
/// holds whole right now. Most recent first when the page opens; after that rows keep their place
/// for the visit (``OfflineBackup/ordered(_:places:)``), or playing from it would reshuffle it.
struct OfflineBackupScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player
    @State private var songs: [Song]?
    /// Where each row sits for this visit.
    @State private var places = OfflineBackup.Places()

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let songs {
                    if songs.isEmpty {
                        MessageState(message: DownloadsText.offlineBackupEmpty)
                    }
                    ForEach(Array(songs.enumerated()), id: \.element.videoId) { index, song in
                        CollectionsSongRow(song: song) {
                            player.play(songs, startAt: index, source: QueueSource(title: DownloadsText.offlineBackup, type: .browse,
                                                                                  id: LocalBrowseID.offlineBackup))
                        } onMore: {
                            model.router.present(.songActions(song))
                        }
                        if index < songs.count - 1 { RowDivider(color: Color(.separator).opacity(0.5)) }
                    }
                } else {
                    ForEach(0..<10, id: \.self) { _ in SongRowSkeleton() }
                }
            }
        }
        .collectionsListBottomInset()
        .navigationTitle(DownloadsText.offlineBackup)
        .navigationBarTitleDisplayMode(.inline)
        // Reloaded when the track changes (the one that just finished is usually whole by then),
        // without reordering what is on screen: playing from this list must not reshuffle it.
        .task(id: player.currentSong?.videoId) {
            let fresh = await model.offlineBackup.songs()
            songs = OfflineBackup.ordered(fresh, places: &places)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.offlineBackup")
    }
}
