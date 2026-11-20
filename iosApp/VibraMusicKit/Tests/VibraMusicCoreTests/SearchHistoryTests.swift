import XCTest
import VibraMusicTestSupport
@testable import VibraMusicCore

@MainActor
final class SearchHistoryTests: XCTestCase {
    private func entity(_ id: String, _ type: SearchHistoryEntity.EntityType = .track, at timestamp: Int64 = 1) -> SearchHistoryEntity {
        SearchHistoryEntity(id: id, title: "Title \(id)", subtitle: "Song • Artist", artworkUrl: nil, entityType: type, timestamp: timestamp)
    }

    func testMostRecentFirst() {
        let history = SearchHistory(defaults: makeEphemeralDefaults())
        history.record(entity("a"))
        history.record(entity("b"))
        XCTAssertEqual(history.recent.map(\.id), ["b", "a"])
    }

    func testReTappingMovesAnEntryToTheTopInsteadOfDuplicatingIt() {
        let history = SearchHistory(defaults: makeEphemeralDefaults())
        history.record(entity("a", at: 1))
        history.record(entity("b", at: 2))
        history.record(entity("A", at: 3))
        XCTAssertEqual(history.recent.map(\.id), ["A", "b"], "matched case-insensitively, newest copy kept")
        XCTAssertEqual(history.recent.first?.timestamp, 3)
    }

    func testKeepsAtMostTwentyEntries() {
        let history = SearchHistory(defaults: makeEphemeralDefaults())
        for index in 0..<25 { history.record(entity("id\(index)")) }
        XCTAssertEqual(history.recent.count, SearchHistory.maxEntries)
        XCTAssertEqual(SearchHistory.maxEntries, 20)
        XCTAssertEqual(history.recent.first?.id, "id24")
        XCTAssertEqual(history.recent.last?.id, "id5")
    }

    func testRemoveAndClear() {
        let history = SearchHistory(defaults: makeEphemeralDefaults())
        history.record(entity("a"))
        history.record(entity("b", .album))
        history.remove(id: "A")
        XCTAssertEqual(history.recent.map(\.id), ["b"])
        history.clear()
        XCTAssertTrue(history.recent.isEmpty)
    }

    func testPersistsAcrossInstances() {
        let defaults = makeEphemeralDefaults()
        let first = SearchHistory(defaults: defaults)
        first.record(entity("MPREb_1", .album, at: 42))
        let second = SearchHistory(defaults: defaults)
        XCTAssertEqual(second.recent, first.recent)
    }

    func testReadsAndroidsStoredShape() {
        let defaults = makeEphemeralDefaults()
        defaults.set(#"[{"id":"UC1","title":"Daft Punk","subtitle":"Artist","artworkUrl":null,"entityType":"ARTIST","timestamp":1700000000000}]"#,
                     forKey: "search_history")
        let history = SearchHistory(defaults: defaults)
        XCTAssertEqual(history.recent.first?.entityType, .artist)
        XCTAssertEqual(history.recent.first?.timestamp, 1_700_000_000_000)
        XCTAssertNil(history.recent.first?.artworkUrl)
    }

    func testAnUnreadableListReadsAsEmpty() {
        let defaults = makeEphemeralDefaults()
        defaults.set("not json", forKey: "search_history")
        XCTAssertTrue(SearchHistory(defaults: defaults).recent.isEmpty)
    }

    func testReloadPicksUpAnImportedList() {
        let defaults = makeEphemeralDefaults()
        let history = SearchHistory(defaults: defaults)
        let settings = AppSettings(defaults: defaults, credentials: InMemoryCredentialStore())
        let incoming = SearchHistory(defaults: makeEphemeralDefaults())
        incoming.record(entity("x"))
        settings.importPrefs(["search_history": .string(String(decoding: try! JSONEncoder().encode(incoming.recent), as: UTF8.self))])
        history.reload()
        XCTAssertEqual(history.recent.map(\.id), ["x"])
    }
}

@MainActor
final class LikeStateTests: XCTestCase {
    func testExplicitRatingsOverride() {
        let state = LikeState()
        state.set(.like, for: "a")
        state.set(.dislike, for: "a")
        XCTAssertEqual(state.status(for: "a"), .dislike)
    }

    func testAStatedRatingIsRememberedOnlyWhenItSaysSomething() {
        let state = LikeState()
        state.rememberStated(nil, for: "a")
        state.rememberStated(.indifferent, for: "a")
        XCTAssertNil(state.status(for: "a"), "silence and 'neither' must not become a rating")
        state.rememberStated(.like, for: "a")
        XCTAssertEqual(state.status(for: "a"), .like)
    }

    func testAnExplicitOverrideBeatsAStatedRating() {
        let state = LikeState()
        state.set(.dislike, for: "a")
        state.rememberStated(.like, for: "a")
        XCTAssertEqual(state.status(for: "a"), .dislike)
    }

    func testSeedingLikesDoesNotOverwriteThisSessionsChoices() {
        let state = LikeState()
        state.set(.indifferent, for: "a")
        state.seedLiked(["a", "b"])
        XCTAssertEqual(state.overrides, ["a": .indifferent, "b": .like])
        state.clear()
        XCTAssertTrue(state.overrides.isEmpty)
    }
}
