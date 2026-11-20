import VibraMusicCore
import Foundation
import InnerTube

/// Search's state (ports the search half of ui/MainViewModel.kt: `onQueryChange`, `submitSearch`,
/// `searchFor`, `onFilterChange`, the search / suggestion / typeahead pipelines and
/// `loadMoreSearchResults`).
///
/// Typing never runs a search: it asks for text completions (after 180 ms) and a handful of live
/// results (after 350 ms), shown while the field is mid-edit. A search runs only on a deliberate
/// act — the keyboard's Search key, a suggestion, a filter pill — and shows at once whatever an
/// earlier search already knows (the exact query, or the longest earlier query it extends), so the
/// spinner is only for something genuinely new. Every request carries an id; an answer to anything
/// but the newest is dropped, whether it succeeded or failed.
@MainActor
@Observable
final class SearchModel {
    /// What is in the field.
    private(set) var query = ""
    private(set) var filter: SearchFilter = .all
    /// Nil until something has been searched (the page then shows recent searches).
    private(set) var results: LoadState<[SearchResult]>?
    /// Whether `results` answer the query in the field. False while an earlier, shorter query's
    /// rows stand in for it until the real answer lands.
    private(set) var resultsAreFinal = false
    private(set) var loadingMore = false
    /// The typed text first, then YouTube's completions; non-empty only while the field is mid-edit.
    private(set) var suggestions: [String] = []
    /// Live media rows under the completions while typing.
    private(set) var typeahead: [SearchResult] = []
    /// Bumped for every new request, so the list returns to the top.
    private(set) var scrollResetTrigger = 0

    @ObservationIgnored var catalog: BrowseCatalog?
    @ObservationIgnored private var searchSubmitted = false
    @ObservationIgnored private var newestRequestId = 0
    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var cache = SearchCache(capacity: SearchModel.cacheEntries)
    @ObservationIgnored private var suggestTask: Task<Void, Never>?
    @ObservationIgnored private var typeaheadTask: Task<Void, Never>?
    @ObservationIgnored private let suggestDelay: Duration
    @ObservationIgnored private let typeaheadDelay: Duration

    /// `SUGGEST_DEBOUNCE_MS`: long enough that "cold" isn't four lookups, short enough that the
    /// list is up before the next letter.
    nonisolated static let suggestDebounce: Duration = .milliseconds(180)
    /// `TYPEAHEAD_MEDIA_DEBOUNCE_MS`: a media lookup is heavier than a completion.
    nonisolated static let typeaheadDebounce: Duration = .milliseconds(350)
    /// `TYPEAHEAD_MAX_RESULTS`.
    static let typeaheadMaxResults = 8
    /// `SEARCH_CACHE_ENTRIES`.
    static let cacheEntries = 100
    /// How many completions show under the field (the typed text itself is left out; it's in the field).
    static let visibleSuggestions = 3

    private struct Session: Equatable {
        let key: String
        let requestId: Int
        let filter: SearchFilter
        var continuation: String?
    }

    init(catalog: BrowseCatalog? = nil, suggestDelay: Duration = SearchModel.suggestDebounce,
         typeaheadDelay: Duration = SearchModel.typeaheadDebounce) {
        self.catalog = catalog
        self.suggestDelay = suggestDelay
        self.typeaheadDelay = typeaheadDelay
    }

    /// The field is mid-edit: completions replace the results, and the filter pills hide.
    var isSuggesting: Bool { !suggestions.isEmpty }
    /// The completions to draw (the echo of the typed text dropped, at most three).
    var visibleSuggestions: [String] { Array(suggestions.dropFirst().prefix(Self.visibleSuggestions)) }
    /// Live rows show only alongside completions, never under committed results.
    var showsTypeahead: Bool { isSuggesting && !typeahead.isEmpty }
    /// The filter pills: once there's a result set to narrow (an empty or failed one included, so
    /// the control to leave it stays), and not while typing.
    var showsFilters: Bool { results != nil && !isSuggesting }

    // MARK: - Input

    func onQueryChange(_ newValue: String) {
        guard newValue != query else { return }
        query = newValue
        if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchSubmitted = false
            suggestions = []
            typeahead = []
            results = nil
            resultsAreFinal = false
            newestRequestId += 1
            session = nil
            loadingMore = false
            scrollResetTrigger += 1
            suggestTask?.cancel()
            typeaheadTask?.cancel()
            return
        }
        searchSubmitted = false
        requestCompletions(for: newValue)
    }

    /// The Search key: runs what's in the field.
    func submit() {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        searchSubmitted = true
        suggestions = []
        typeahead = []
        runSearch()
    }

    /// A term picked from a list (a suggestion): as deliberate as submitting, so it searches now.
    func searchFor(_ term: String) {
        query = term
        searchSubmitted = true
        suggestions = []
        typeahead = []
        runSearch()
    }

    /// A search handed over from outside the screen (a link, Siri): whatever pill was up before
    /// doesn't narrow it. One request, for the unfiltered query.
    func searchFromOutside(_ term: String) {
        filter = .all
        searchFor(term)
    }

    func onFilterChange(_ value: SearchFilter) {
        guard value != filter else { return }
        filter = value
        searchSubmitted = true
        runSearch()
    }

    // MARK: - Searching

    private func runSearch() {
        let query = self.query
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            newestRequestId += 1
            session = nil
            loadingMore = false
            results = nil
            resultsAreFinal = false
            return
        }
        newestRequestId += 1
        let id = newestRequestId
        scrollResetTrigger += 1
        session = nil
        loadingMore = false
        let filter = self.filter
        let key = Self.cacheKey(query, filter)
        // Something to look at immediately: the exact answer if this query ran before, else the
        // closest earlier one. Only fall back to the skeleton with neither.
        let exact = cache.get(key)
        let shown = exact?.rows ?? cache.prefixMatch(query, filter: filter)
        results = shown.map { .success($0) } ?? .loading
        resultsAreFinal = exact != nil
        if let exact {
            session = Session(key: key, requestId: id, filter: filter, continuation: exact.continuation)
            return
        }
        guard let catalog else { return }
        Task {
            let outcome: Result<InnerTubeParser.SearchPage, Error>
            do {
                outcome = .success(try await catalog.searchPage(query: query, filter: filter))
            } catch {
                outcome = .failure(error)
            }
            // A search that has been superseded doesn't land, whatever its outcome.
            guard id == newestRequestId else { return }
            switch outcome {
            case .success(let page):
                if page.rows.isEmpty {
                    results = .error(L10n.noResults)
                } else {
                    cache.put(key, SearchCache.Entry(rows: page.rows, continuation: page.continuation))
                    session = Session(key: key, requestId: id, filter: filter, continuation: page.continuation)
                    results = .success(page.rows)
                    resultsAreFinal = true
                }
            case .failure(let error):
                results = .error(BrowseErrorText.friendly(error))
            }
        }
    }

    /// The next page, only once the list reaches its end.
    func loadMore() async {
        guard let session, let token = session.continuation, !loadingMore, let catalog else { return }
        loadingMore = true
        let next = try? await catalog.searchContinuation(token: token, filter: session.filter)
        guard self.session == session, session.requestId == newestRequestId else { return }
        if let next {
            let current = results?.value ?? []
            var seen = Set<String>()
            let merged = (current + next.rows).filter { seen.insert(Self.identity($0)).inserted }
            cache.put(session.key, SearchCache.Entry(rows: merged, continuation: next.continuation))
            self.session?.continuation = next.continuation
            results = .success(merged)
        }
        loadingMore = false
    }

    /// Whether another page can be asked for.
    var canLoadMore: Bool { session?.continuation != nil && !loadingMore }

    /// How many rows from the end a row coming into view asks for the next page: half of a page of
    /// about 20, so it lands before the reader gets there. Android waits until the last visible row
    /// is within four of the end, and a quick scroll then reaches the bottom with the page in flight.
    static let pagingLead = 10

    /// The row at `index` of `total` came into view.
    func rowAppeared(at index: Int, of total: Int) {
        guard index >= total - Self.pagingLead, canLoadMore else { return }
        Task { await loadMore() }
    }

    // MARK: - Completions and typeahead

    /// Whether a list for `input` is still wanted: not once the field moved on or searched.
    private func stillWanted(_ input: String) -> Bool { query == input && !searchSubmitted }

    private func requestCompletions(for input: String) {
        suggestTask?.cancel()
        typeaheadTask?.cancel()
        guard let catalog else { return }
        let suggestDelay = self.suggestDelay
        let typeaheadDelay = self.typeaheadDelay
        suggestTask = Task {
            try? await Task.sleep(for: suggestDelay)
            guard !Task.isCancelled, stillWanted(input) else { return }
            // A failure is left on the floor: the typed text is a working first row regardless.
            guard let fetched = try? await catalog.searchSuggestions(input: input),
                  !Task.isCancelled, stillWanted(input) else { return }
            suggestions = [input] + fetched.filter { $0.caseInsensitiveCompare(input) != .orderedSame }
        }
        typeaheadTask = Task {
            try? await Task.sleep(for: typeaheadDelay)
            guard !Task.isCancelled else { return }
            if searchSubmitted {
                typeahead = []
                return
            }
            let page = try? await catalog.searchTypeahead(input: input)
            guard !Task.isCancelled else { return }
            guard query == input else {
                typeahead = []
                return
            }
            typeahead = Array((page?.rows ?? []).prefix(Self.typeaheadMaxResults))
        }
    }

    // MARK: - Helpers

    static func cacheKey(_ query: String, _ filter: SearchFilter) -> String { "\(filter.rawValue):\(query)" }

    static func identity(_ row: SearchResult) -> String {
        switch row {
        case .topTrack(let song), .track(let song): return "v:\(song.videoId)"
        case .browse(let item): return "b:\(item.browseId)"
        }
    }
}

/// An LRU of search answers (Android's `LruCache<String, SearchCacheEntry>`).
struct SearchCache {
    struct Entry: Equatable {
        var rows: [SearchResult]
        var continuation: String?
    }

    let capacity: Int
    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    init(capacity: Int) { self.capacity = capacity }

    mutating func get(_ key: String) -> Entry? {
        guard let entry = entries[key] else { return nil }
        touch(key)
        return entry
    }

    mutating func put(_ key: String, _ entry: Entry) {
        entries[key] = entry
        touch(key)
        while order.count > capacity {
            entries.removeValue(forKey: order.removeFirst())
        }
    }

    /// The rows of the longest earlier query (same filter) that `query` starts with.
    func prefixMatch(_ query: String, filter: SearchFilter) -> [SearchResult]? {
        let prefix = "\(filter.rawValue):"
        return entries
            .filter { key, _ in
                guard key.hasPrefix(prefix) else { return false }
                let earlier = String(key.dropFirst(prefix.count))
                return query.lowercased().hasPrefix(earlier.lowercased())
            }
            .max { $0.key.count < $1.key.count }?
            .value.rows
    }

    private mutating func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

/// Ports `searchSections`: the unfiltered page split by kind so its mix reads at a glance; any
/// other filter is one untitled run.
struct SearchSection: Identifiable {
    let title: String?
    let rows: [SearchResult]
    var id: String { title ?? "all" }

    static func sections(_ rows: [SearchResult], filter: SearchFilter) -> [SearchSection] {
        guard filter == .all else { return [SearchSection(title: nil, rows: rows)] }
        func browse(_ type: BrowseType) -> [SearchResult] {
            rows.filter { if case .browse(let item) = $0 { return item.type == type } else { return false } }
        }
        let tracks = rows.filter { if case .track = $0 { return true } else { return false } }
        return [
            SearchSection(title: L10n.songs, rows: tracks),
            SearchSection(title: L10n.artists, rows: browse(.artist)),
            SearchSection(title: L10n.albums, rows: browse(.album)),
            SearchSection(title: L10n.playlists, rows: browse(.playlist)),
            SearchSection(title: BrowseStrings.sectionMore, rows: browse(.other)),
        ].filter { !$0.rows.isEmpty }
    }
}
