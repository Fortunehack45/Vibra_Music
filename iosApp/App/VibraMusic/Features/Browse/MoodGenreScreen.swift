import VibraMusicCore
import InnerTube
import PlaybackQueue
import SwiftUI

/// A mood or genre's playlists (ports `MoodGenrePlaylistsScreen` in ui/screens/ExploreScreen.kt
/// and its `onItemClick` in MainActivity.kt).
///
/// The category's name as the page title over its shelves of square cards. A card with a track
/// behind it starts a one-off from that track; any other card opens its page. The cards have no
/// long-press menu here, as on Android.
struct MoodGenreScreen: View {
    let moodGenre: MoodGenre

    @Environment(AppModel.self) private var model
    @State private var page = MoodGenreModel()

    var body: some View {
        let state = page.state
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch state {
                    case .loading:
                        FeedSkeleton(width: proxy.size.width)
                    case .error(let message):
                        BrowseMessage(message: message, actionTitle: L10n.retry) { reload() }
                    case .success(let shelves):
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(shelves.enumerated()), id: \.offset) { index, shelf in
                                HomeShelfRow(shelf: shelf, onOpen: open)
                                    .prefetchingShelfCovers(after: index, in: shelves)
                            }
                        }
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .navigationTitle(moodGenre.title)
        .navigationBarTitleDisplayMode(.large)
        .task {
            guard !page.hasLoaded else { return }
            reload()
        }
        // A container: without this the screen identifier lands on every child and hides theirs.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.moodGenre")
    }

    private func reload() {
        let catalog = model.repository
        let category = moodGenre
        Task { await page.load(category, catalog: catalog) }
    }

    private func open(_ item: ShelfItem) {
        BrowseNavigator(app: model).openCard(item, source: QueueSource(title: moodGenre.title, type: .explore, id: moodGenre.browseId))
    }
}
