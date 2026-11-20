import VibraMusicCore
import PlaybackQueue
import SwiftUI

/// What the account has been listening to, most recent first (ports ui/screens/HistoryScreen.kt).
///
/// A plain list rather than a page with a header: no single cover stands for a history. Tapping a
/// row plays it with the rest of the history behind it — the list doubles as a queue already
/// approved once. Loaded on every visit; signed out, it says so.
struct HistoryScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player

    private var store: CollectionsStore { CollectionsStore.shared(for: model) }

    var body: some View {
        let store = store
        ScrollView {
            LazyVStack(spacing: 0) {
                switch store.history {
                case .loading:
                    ForEach(0..<10, id: \.self) { _ in SongRowSkeleton() }
                case .error(let message):
                    MessageState(message: message, actionLabel: L10n.tryAgain) {
                        Task { await store.loadHistory() }
                    }
                case .success(let songs):
                    // Keyed by position as well: the feed is deduplicated, but a list keyed on
                    // something that could repeat is one bad response from a crash.
                    ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                        CollectionsSongRow(song: song) {
                            player.play(songs, startAt: index, source: QueueSource(title: L10n.history, type: .history))
                        } onMore: {
                            model.router.present(.songActions(song))
                        }
                        .prefetchingCovers(after: index, in: songs) { [$0.thumbnailUrl] }
                        if index < songs.count - 1 { RowDivider(color: Color(.separator).opacity(0.5)) }
                    }
                }
            }
        }
        .collectionsListBottomInset()
        .navigationTitle(L10n.history)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: store.service.listenerKey) { await store.loadHistory() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.history")
    }
}
