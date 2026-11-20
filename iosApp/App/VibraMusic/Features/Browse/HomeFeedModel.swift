import VibraMusicCore
import Foundation

/// Home's feed (ports the home half of ui/MainViewModel.kt: `loadHome`, `refreshHome`,
/// `loadMoreHome`, `publishHomeShelves`).
///
/// The first page is a fan-out, each part published as it lands: YouTube Music's core feed, one
/// browse per supplement (New releases, Explore), and — signed in — "Recently played", which owns
/// the head of the page and has its own skeleton there. Shelves are de-duplicated by title across
/// all of them, and a newer load (or a different listener) makes every older answer harmless.
@MainActor
@Observable
final class HomeFeedModel {
    private(set) var state: LoadState<[HomeShelf]> = .loading
    /// Signed in and the history request is still out: Recents' skeleton leads the page.
    private(set) var recentlyPlayedLoading = false
    /// Pull to refresh in flight (the content stays up).
    private(set) var refreshing = false
    /// Whether the tail should show a loading shelf: a continuation page, or a first-page request
    /// still on its way (Android's `homeLoadingMore`).
    var loadingMore: Bool { pagingMore || pendingShelves > 0 }
    /// The listener the current feed belongs to; a change reloads.
    private(set) var loadedFor: String??
    /// The page each listener had when we left them, keyed by `listenerKey`, so switching back
    /// paints at once while the first page is fetched behind it (beyond Android, whose
    /// `ListenerSnapshot` has no home). The key is `loadedFor`, whose page is on screen, so one
    /// listener's shelves are never filed under another's. Signing out drops them all.
    private var snapshots: [String: [HomeShelf]] = [:]

    private(set) var continuation: String?
    private var pagingMore = false
    private var pendingShelves = 0
    private var seenTitles: Set<String> = []
    private var generation = 0
    private let supplementIds: [String]

    init(supplementIds: [String] = BrowseCatalogDefaults.homeSupplementBrowseIds) {
        self.supplementIds = supplementIds
    }

    /// Whether the feed was loaded for `listener` (nil = signed out).
    func isLoaded(for listener: String?) -> Bool { loadedFor == .some(listener) }

    /// The first page, from scratch: the page drops back to its skeleton, or, for a listener we
    /// switched away from, to the shelves they had then.
    func load(_ catalog: BrowseCatalog, listener: String?, signedIn: Bool) async {
        if listener == nil {
            snapshots.removeAll()
        } else if case .some(.some(let leaving)) = loadedFor, leaving != listener, let shelves = state.value {
            snapshots[leaving] = shelves
        }
        generation += 1
        let mine = generation
        loadedFor = .some(listener)
        let snapshot = listener.flatMap { snapshots.removeValue(forKey: $0) }
        state = snapshot.map { LoadState.success($0) } ?? .loading
        continuation = nil
        // Only what this load has published: a snapshot's shelves are stand-ins, each replaced in
        // place by its fresh copy as it lands, never a reason to drop that copy.
        seenTitles.removeAll()
        pagingMore = false
        // The snapshot's own Recents (or its lack of one) stands in for the skeleton.
        recentlyPlayedLoading = signedIn && snapshot == nil
        pendingShelves = 1 + supplementIds.count

        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                defer { self.shelfRequestSettled(mine) }
                do {
                    let feed = try await catalog.home()
                    guard self.generation == mine else { return }
                    self.continuation = feed.continuation
                    self.publish(feed.shelves)
                } catch {
                    guard self.generation == mine, self.state.value == nil else { return }
                    if error is CancellationError { return }
                    self.state = .error(BrowseErrorText.friendly(error))
                }
            }
            if signedIn {
                group.addTask { @MainActor in
                    let recent = try? await catalog.homeRecentlyPlayed()
                    guard self.generation == mine else { return }
                    self.recentlyPlayedLoading = false
                    if let recent { self.publish([recent], prepend: true) }
                }
            }
            for browseId in supplementIds {
                group.addTask { @MainActor in
                    defer { self.shelfRequestSettled(mine) }
                    guard let shelves = try? await catalog.homeSupplement(browseId: browseId),
                          self.generation == mine else { return }
                    self.publish(shelves)
                }
            }
        }
        // Every request has answered: a snapshot shelf the fresh page didn't carry goes, so the
        // page ends as a load from scratch would have. If nothing was published (every request
        // failed or came back empty, which leaves a load from scratch on its skeleton or an error),
        // the listener's own shelves stay up instead.
        if snapshot != nil, generation == mine, !seenTitles.isEmpty, let shelves = state.value {
            state = .success(shelves.filter { seenTitles.contains($0.feedKey) })
        }
    }

    /// Pull to refresh: re-fetches the core feed (and Recents) without blanking the page.
    ///
    /// The fetch runs in a task of its own, as Android's runs in `viewModelScope`. SwiftUI cancels
    /// the task `refreshable` hands us while the pull is still in flight, so fetching on that one
    /// failed every time ("home failed: cancelled") and the spinner dropped with nothing refreshed.
    func refresh(_ catalog: BrowseCatalog, listener: String?, signedIn: Bool) async {
        await Task { await fetchRefresh(catalog, listener: listener, signedIn: signedIn) }.value
    }

    private func fetchRefresh(_ catalog: BrowseCatalog, listener: String?, signedIn: Bool) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let mine = generation
        async let recentFetch: HomeShelf?? = signedIn ? (try? await catalog.homeRecentlyPlayed()) : nil
        if let feed = try? await catalog.home(), generation == mine, loadedFor == .some(listener) {
            continuation = feed.continuation
            seenTitles.removeAll()
            let shelves = feed.shelves.filter { seenTitles.insert($0.title.lowercased()).inserted }
            if !shelves.isEmpty { state = .success(shelves) }
        }
        if let recentAnswer = await recentFetch, let recent = recentAnswer, generation == mine, loadedFor == .some(listener) {
            publish([recent], prepend: true)
        }
    }

    /// The next page, as the list nears its end. A no-op while a page is in flight, once the feed
    /// is exhausted, or before the first page landed — `continuation` covers all three.
    func loadMore(_ catalog: BrowseCatalog) async {
        guard let token = continuation, !pagingMore else { return }
        let mine = generation
        pagingMore = true
        defer { if generation == mine { pagingMore = false } }
        guard let feed = try? await catalog.moreHome(token: token), generation == mine else { return }
        let added = feed.shelves.filter { seenTitles.insert($0.title.lowercased()).inserted }
        // A page with nothing new means the feed has looped back on itself rather than run dry
        // with a token still attached: treat it as exhausted so scrolling can't spin here.
        continuation = added.isEmpty ? nil : feed.continuation
        if !added.isEmpty { state = .success((state.value ?? []) + added) }
    }

    private func shelfRequestSettled(_ mine: Int) {
        guard generation == mine else { return }
        pendingShelves = max(0, pendingShelves - 1)
    }

    /// `publishHomeShelves`: appends unseen shelves; a prepended shelf (Recents) replaces any shelf
    /// of the same title, since YouTube's core home can carry a stale "Recently played" of its own.
    /// An unseen shelf whose title is already on the page is a snapshot's stand-in: it is replaced
    /// where it stands, so the core feed, the supplements and Recents can land in any order over a
    /// snapshot without one of them dropping or doubling another's shelves.
    private func publish(_ shelves: [HomeShelf], prepend: Bool = false) {
        var page = state.value ?? []
        if prepend {
            let replacing = Set(shelves.map(\.feedKey))
            seenTitles.formUnion(replacing)
            state = .success(shelves + page.filter { !replacing.contains($0.feedKey) })
            return
        }
        let added = shelves.filter { seenTitles.insert($0.feedKey).inserted }
        guard !added.isEmpty else { return }
        for shelf in added {
            if let index = page.firstIndex(where: { $0.feedKey == shelf.feedKey }) {
                page[index] = shelf
            } else {
                page.append(shelf)
            }
        }
        state = .success(page)
    }
}
