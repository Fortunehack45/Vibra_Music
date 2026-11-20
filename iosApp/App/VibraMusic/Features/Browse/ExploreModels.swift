import VibraMusicCore
import Foundation

/// Explore's categories (ports `loadExplore` / `fetchExplore` / `loadMoodGenreArtwork` from
/// ui/MainViewModel.kt).
@MainActor
@Observable
final class ExploreModel {
    private(set) var state: LoadState<[MoodGenreSection]> = .loading
    private(set) var hasLoaded = false
    private var generation = 0
    private var artworkTask: Task<Void, Never>?

    /// How many category covers are looked up at once — enough to fill the grid quickly without
    /// saturating the browse client or holding up the category list.
    static let artworkConcurrency = 4

    func load(_ catalog: BrowseCatalog) async {
        hasLoaded = true
        state = .loading
        await fetch(catalog)
    }

    /// Pull to refresh: the grid stays up until the answer lands.
    func refresh(_ catalog: BrowseCatalog) async {
        await fetch(catalog)
    }

    private func fetch(_ catalog: BrowseCatalog) async {
        generation += 1
        let mine = generation
        let next: LoadState<[MoodGenreSection]>
        do {
            let sections = try await catalog.moodAndGenres()
            next = sections.isEmpty ? .error(L10n.nothingToExplore) : .success(sections)
        } catch {
            next = .error(BrowseErrorText.friendly(error))
        }
        guard mine == generation else { return }
        state = next
        if let sections = next.value { loadArtwork(for: sections, catalog: catalog) }
    }

    /// Category buttons carry no picture of their own: each borrows the first cover from the
    /// playlists it opens, a few at a time, filled in as they arrive.
    private func loadArtwork(for sections: [MoodGenreSection], catalog: BrowseCatalog) {
        artworkTask?.cancel()
        let items = sections.flatMap(\.items)
        let mine = generation
        artworkTask = Task { [weak self] in
            await withTaskGroup(of: (MoodGenre, String?).self) { group in
                var next = 0
                func enqueue() {
                    guard next < items.count else { return }
                    let item = items[next]
                    next += 1
                    group.addTask { (item, try? await catalog.moodGenreArtwork(browseId: item.browseId, params: item.params)) }
                }
                for _ in 0..<Self.artworkConcurrency { enqueue() }
                while let (item, artwork) = await group.next() {
                    if Task.isCancelled { break }
                    if let artwork { self?.apply(artwork, to: item, generation: mine) }
                    enqueue()
                }
            }
        }
    }

    private func apply(_ artwork: String, to item: MoodGenre, generation mine: Int) {
        guard mine == generation, let sections = state.value else { return }
        state = .success(sections.map { section in
            var section = section
            section.items = section.items.map { current in
                guard current.browseId == item.browseId, current.params == item.params else { return current }
                var updated = current
                updated.thumbnailUrl = artwork
                return updated
            }
            return section
        })
    }
}

/// One category's playlists (ports `openMoodGenre` from ui/MainViewModel.kt).
@MainActor
@Observable
final class MoodGenreModel {
    private(set) var state: LoadState<[HomeShelf]> = .loading
    private(set) var hasLoaded = false

    func load(_ category: MoodGenre, catalog: BrowseCatalog) async {
        hasLoaded = true
        state = .loading
        do {
            let shelves = try await catalog.moodGenreShelves(browseId: category.browseId, params: category.params)
            state = shelves.isEmpty ? .error(L10n.nothingToExplore) : .success(shelves)
        } catch {
            state = .error(BrowseErrorText.friendly(error))
        }
    }
}
