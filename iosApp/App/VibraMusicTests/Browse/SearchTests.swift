import VibraMusicCore
import InnerTube
import PlaybackQueue
import SwiftUI
import XCTest
@testable import Vibra Music

/// PORTING.md "Search": suggestions while typing, filters, the top result, paging, recent
/// searches; and "Swipe to queue" on its song rows.
@MainActor
final class SearchTests: XCTestCase {
    private func model(_ catalog: BrowseCatalog) -> SearchModel {
        SearchModel(catalog: catalog, suggestDelay: .milliseconds(5), typeaheadDelay: .milliseconds(10))
    }

    // MARK: - Against the real InnerTube client over recorded answers

    func testSubmittingASearchShowsTheTopResultAndGroupedSectionsFromAStubbedInnerTube() async throws {
        let search = model(makeStubbedRepository())
        search.onQueryChange("daft punk")
        search.submit()
        XCTAssertEqual(search.results, .loading)
        XCTAssertTrue(search.showsFilters, "the pills are up as soon as there's a search to narrow")

        await waitUntil("results") { search.results?.value != nil }
        let rows = try XCTUnwrap(search.results?.value)
        let sections = SearchSection.sections(rows, filter: .all)
        XCTAssertEqual(sections.first?.title, L10n.songs)
        XCTAssertTrue(sections.allSatisfy { !$0.rows.isEmpty })
        XCTAssertFalse(sections.contains { $0.rows.contains { if case .topTrack = $0 { true } else { false } } },
                       "the top result is drawn as its own card, not inside a section")
        XCTAssertTrue(InnerTubeStub.requests.contains { $0.hasSuffix("/search daft punk") })
    }

    func testTheNextPageIsFetchedAtTheEndAndMergedWithoutRepeats() async throws {
        let search = model(makeStubbedRepository())
        search.onQueryChange("daft punk")
        search.onFilterChange(.songs)
        await waitUntil("first page") { search.results?.value != nil }
        let first = try XCTUnwrap(search.results?.value).count
        XCTAssertTrue(search.canLoadMore)

        await search.loadMore()

        let merged = try XCTUnwrap(search.results?.value)
        XCTAssertGreaterThan(merged.count, first)
        XCTAssertEqual(merged.count, Set(merged.map(SearchModel.identity)).count)
        XCTAssertEqual(SearchSection.sections(merged, filter: .songs).count, 1, "a filtered search is one untitled run")
        XCTAssertNil(SearchSection.sections(merged, filter: .songs).first?.title)
    }

    /// A result row half a page from the end asks for the next page, so it lands before the reader
    /// gets there (Android waits until the last visible row is within four of the end, and a quick
    /// scroll then reaches the bottom with the page still in flight). Rows further up ask nothing.
    func testTheNextPageIsAskedForHalfAPageFromTheEnd() async throws {
        let catalog = ScriptedCatalog()
        catalog.searchAnswer = { _, _ in .init(rows: (0..<20).map { track("r\($0)") }, continuation: "page-2") }
        catalog.continuationAnswer = { _ in .init(rows: [track("r20")], continuation: nil) }
        let search = model(catalog)
        search.onQueryChange("q")
        search.submit()
        await waitUntil("the first page") { search.results?.value != nil }

        search.rowAppeared(at: 9, of: 20)
        // Asserting that nothing is asked: give a request the time it would take to go out.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(catalog.calls.contains("continuation:page-2"), "eleven rows from the end is too soon")

        search.rowAppeared(at: 10, of: 20)
        await waitUntil("the next page is asked for") { catalog.calls.contains("continuation:page-2") }
        await waitUntil("and lands") { search.results?.value?.count == 21 }
    }

    func testTypingShowsTheTypedTextThenCompletions() async throws {
        let search = model(makeStubbedRepository())
        search.onQueryChange("daft pu")
        XCTAssertNil(search.results, "typing alone never runs a search")
        await waitUntil("suggestions") { search.isSuggesting }
        XCTAssertEqual(search.suggestions.first, "daft pu", "the first row is the text as typed")
        XCTAssertLessThanOrEqual(search.visibleSuggestions.count, SearchModel.visibleSuggestions)
        XCTAssertFalse(search.visibleSuggestions.contains("daft pu"), "the echo is left out; it's in the field")
        XCTAssertFalse(search.showsFilters, "the pills hide while typing")
    }

    /// PORTING.md's done criterion: filter by Albums, open one, and it's in recent searches.
    func testFilteringByAlbumsOpeningOneAndFindingItInRecentSearches() async throws {
        let app = makeBrowseTestApp()
        let search = SearchModel(catalog: app.repository)
        search.onQueryChange("daft punk")
        search.submit()
        search.onFilterChange(.albums)
        await waitUntil("album results") { search.results?.value != nil && search.filter == .albums }
        let rows = try XCTUnwrap(search.results?.value)
        let album = try XCTUnwrap(rows.lazy.compactMap { row -> BrowseItem? in
            if case .browse(let item) = row, item.type == .album { return item } else { return nil }
        }.first, "albums: \(rows)")

        BrowseNavigator(app: app).openSearchHit(album)

        guard case .album(let browseId, _)? = app.router.path(for: app.router.selectedTab).last else {
            return XCTFail("the album page opens")
        }
        XCTAssertEqual(browseId, album.browseId)
        search.onQueryChange("")
        XCTAssertNil(search.results, "back on the empty field…")
        XCTAssertEqual(app.searchHistory.recent.first?.id, album.browseId, "…the album leads the recent searches")
        XCTAssertEqual(app.searchHistory.recent.first?.entityType, .album)

        // Opening it again from the recents doesn't re-record it.
        let stamp = try XCTUnwrap(app.searchHistory.recent.first?.timestamp)
        BrowseNavigator(app: app).openRecent(try XCTUnwrap(app.searchHistory.recent.first))
        XCTAssertEqual(app.searchHistory.recent.first?.timestamp, stamp)
    }

    // MARK: - Rules (scripted)

    func testTypeaheadIsCappedAndGoesAwayOnSubmit() async throws {
        let catalog = ScriptedCatalog()
        catalog.suggestionsAnswer = { input in ["\(input) one", "\(input) two"] }
        catalog.typeaheadAnswer = { _ in .init(rows: (0..<12).map { track("t\($0)") }, continuation: nil) }
        catalog.searchAnswer = { _, _ in .init(rows: [track("r1")], continuation: nil) }
        let search = model(catalog)

        search.onQueryChange("blur")
        await waitUntil("typeahead") { search.showsTypeahead }
        XCTAssertEqual(search.typeahead.count, SearchModel.typeaheadMaxResults)

        search.submit()
        XCTAssertFalse(search.isSuggesting)
        XCTAssertFalse(search.showsTypeahead)
        await waitUntil("results") { search.results?.value != nil }
    }

    func testCompletionsForTextThatWasTypedPastAreDropped() async throws {
        let catalog = ScriptedCatalog()
        catalog.suggestionsAnswer = { input in
            if input == "bl" { try await Task.sleep(for: .milliseconds(80)) }
            return ["\(input)!"]
        }
        let search = model(catalog)
        search.onQueryChange("bl")
        try await Task.sleep(for: .milliseconds(20))
        search.onQueryChange("blu")
        await waitUntil("suggestions for blu") { search.suggestions.first == "blu" }
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(search.suggestions, ["blu", "blu!"])
    }

    func testPickingASuggestionSearchesIt() async throws {
        let catalog = ScriptedCatalog()
        catalog.searchAnswer = { query, _ in .init(rows: [track(query)], continuation: nil) }
        let search = model(catalog)
        search.onQueryChange("daf")
        search.searchFor("daft punk")
        XCTAssertEqual(search.query, "daft punk")
        await waitUntil("results") { search.results?.value != nil }
        XCTAssertEqual(catalog.calls.filter { $0.hasPrefix("search:") }, ["search:ALL:daft punk"])
    }

    func testFiltersRerunTheSearchAndAnAnswerAlreadyKnownShowsAtOnce() async throws {
        let catalog = ScriptedCatalog()
        catalog.searchAnswer = { query, filter in .init(rows: [track("\(filter.rawValue)-\(query)")], continuation: nil) }
        let search = model(catalog)
        search.onQueryChange("air")
        search.submit()
        await waitUntil("all") { search.results?.value != nil }

        search.onFilterChange(.albums)
        XCTAssertEqual(search.filter, .albums)
        await waitUntil("albums") { search.results?.value?.first?.song?.videoId == "ALBUMS-air" }

        search.onFilterChange(.all)
        XCTAssertEqual(search.results?.value?.first?.song?.videoId, "ALL-air", "cached: no skeleton, no request")
        XCTAssertEqual(catalog.calls.filter { $0.hasPrefix("search:") }.count, 2)

        search.onFilterChange(.all)
        XCTAssertEqual(catalog.calls.filter { $0.hasPrefix("search:") }.count, 2, "re-picking the same filter is a no-op")
    }

    func testANarrowerQueryShowsTheBroaderAnswerWhileItLoads() async throws {
        let catalog = ScriptedCatalog()
        let gate = AsyncGate()
        catalog.searchAnswer = { query, _ in
            if query == "daft punk" { await gate.wait() }
            return .init(rows: [track(query)], continuation: nil)
        }
        let search = model(catalog)
        search.onQueryChange("daft")
        search.submit()
        await waitUntil("daft") { search.results?.value != nil }

        search.onQueryChange("daft punk")
        search.submit()
        XCTAssertEqual(search.results?.value?.first?.song?.videoId, "daft", "the earlier answer stays up")
        await gate.open()
        await waitUntil("daft punk") { search.results?.value?.first?.song?.videoId == "daft punk" }
    }

    func testAnEarlierQuerysRowsStandInUntilTheRealAnswerLands() async throws {
        let catalog = ScriptedCatalog()
        let gate = AsyncGate()
        catalog.searchAnswer = { query, _ in
            if query == "daft punk" { await gate.wait() }
            return .init(rows: [track(query)], continuation: nil)
        }
        let search = model(catalog)
        search.onQueryChange("daft")
        search.submit()
        await waitUntil("daft") { search.results?.value != nil }
        XCTAssertTrue(search.resultsAreFinal)

        search.onQueryChange("daft punk")
        search.submit()
        XCTAssertNotNil(search.results?.value, "the earlier answer is up")
        XCTAssertFalse(search.resultsAreFinal, "but it is not the answer to what was asked")
        await gate.open()
        await waitUntil("the real answer") { search.resultsAreFinal }
        XCTAssertEqual(search.results?.value?.first?.song?.videoId, "daft punk")
    }

    func testASearchHandedOverFromOutsideIgnoresThePillChosenEarlier() async throws {
        let catalog = ScriptedCatalog()
        catalog.searchAnswer = { query, filter in .init(rows: [track("\(filter.rawValue)-\(query)")], continuation: nil) }
        let search = model(catalog)
        search.onQueryChange("air")
        search.onFilterChange(.albums)
        await waitUntil("albums") { search.results?.value != nil }

        search.searchFromOutside("daft punk")

        XCTAssertEqual(search.filter, .all)
        await waitUntil("the unfiltered answer") { search.results?.value?.first?.song?.videoId == "ALL-daft punk" }
        XCTAssertEqual(catalog.calls.filter { $0.hasPrefix("search:") }, ["search:ALBUMS:air", "search:ALL:daft punk"],
                       "one request, not a throwaway for the old filter")
    }

    func testOnlyTheNewestSearchLands() async throws {
        let catalog = ScriptedCatalog()
        catalog.searchAnswer = { query, _ in
            if query == "slow" { try await Task.sleep(for: .milliseconds(120)) }
            return .init(rows: [track(query)], continuation: nil)
        }
        let search = model(catalog)
        search.onQueryChange("slow")
        search.submit()
        search.onQueryChange("quick")
        search.submit()
        await waitUntil("quick") { search.results?.value?.first?.song?.videoId == "quick" }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(search.results?.value?.first?.song?.videoId, "quick")
    }

    func testNoHitsAndFailuresAreMessagesAndClearingTheFieldGoesBackToRecents() async throws {
        let catalog = ScriptedCatalog()
        let search = model(catalog)
        search.onQueryChange("zzzz")
        search.submit()
        await waitUntil("no results") { search.results?.errorMessage != nil }
        XCTAssertEqual(search.results?.errorMessage, L10n.noResults)
        XCTAssertTrue(search.showsFilters, "the pills stay so a filter that finds nothing can be left")

        catalog.searchAnswer = { _, _ in throw URLError(.notConnectedToInternet) }
        search.onQueryChange("offline")
        search.submit()
        await waitUntil("failure") { search.results?.errorMessage == L10n.noInternetConnection }

        search.onQueryChange("")
        XCTAssertNil(search.results, "an empty field shows recent searches again")
        XCTAssertFalse(search.showsFilters)
    }

    func testRecentSearchesKeepTwentyNewestFirstAndCanBeRemoved() {
        let suite = "vibramusic.browse.history.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let history = SearchHistory(defaults: defaults)
        for index in 0..<25 {
            history.record(SearchHistoryEntity(song: Song(videoId: "v\(index)", title: "Song \(index)", artist: "A")))
        }
        XCTAssertEqual(history.recent.count, 20)
        XCTAssertEqual(history.recent.first?.id, "v24")

        history.record(SearchHistoryEntity(item: BrowseItem(browseId: "MPREb_1", title: "Album", subtitle: "", thumbnailUrl: nil, type: .album)))
        XCTAssertEqual(history.recent.first?.entityType, .album)
        history.remove(id: "MPREb_1")
        XCTAssertFalse(history.recent.contains { $0.id == "MPREb_1" })
        history.clear()
        XCTAssertTrue(history.recent.isEmpty)
    }

    // MARK: - Swipe to queue

    func testSwipingASearchHitQueuesItNextOrLastPerTheSetting() async throws {
        let harness = PlayerHarness(test: self)
        let playing = try harness.song("p1")
        let later = try harness.song("p2")
        harness.player.play([playing, later], source: QueueSource(title: "Album", type: .browse))
        await waitUntil("playing") { harness.player.currentSong?.videoId == "p1" }

        harness.settings.swipeToPlayNext = true
        harness.player.queueFromSwipe(try harness.song("next"))
        XCTAssertEqual(Array(harness.player.songs.map(\.videoId).prefix(2)), ["p1", "next"])

        harness.settings.swipeToPlayNext = false
        harness.player.queueFromSwipe(try harness.song("last"))
        let ids = harness.player.songs.map(\.videoId)
        // Add to queue: behind what was already queued by hand, not in front of it.
        XCTAssertEqual(ids.firstIndex(of: "last"), try XCTUnwrap(ids.firstIndex(of: "next")) + 1, ids.description)
    }

    // MARK: - Rendering

    func testSearchRendersRecentsTypingAndResults() async {
        let app = makeBrowseTestApp()
        app.searchHistory.record(SearchHistoryEntity(song: Song(videoId: "v1", title: "Around the World", artist: "Daft Punk")))
        await host(SearchScreen(), app: app, timeout: 0.5)

        app.router.pendingSearch = AppRouter.PendingSearch(query: "daft punk", play: false)
        await host(SearchScreen(), app: app, timeout: 5) {
            InnerTubeStub.requests.contains { $0.hasSuffix("/search daft punk") }
        }
        XCTAssertTrue(InnerTubeStub.requests.contains { $0.hasSuffix("/search daft punk") }, "a handed-over search runs")
        XCTAssertNil(app.router.pendingSearch, "and is consumed")
        await host(SearchScreen().environment(\.dynamicTypeSize, .accessibility2), app: app, colorScheme: .light, timeout: 0.5)
    }
}
