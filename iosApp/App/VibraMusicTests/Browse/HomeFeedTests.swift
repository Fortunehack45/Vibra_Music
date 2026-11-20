import VibraMusicCore
import InnerTube
import PlaybackQueue
import SwiftUI
import XCTest
@testable import Vibra Music

/// PORTING.md "Home feed": YouTube Music's shelves, Recents first when signed in, more shelves as
/// the end nears, pull to refresh; a song card starts a one-off, a collection opens its page.
@MainActor
final class HomeFeedTests: XCTestCase {
    // MARK: - Against the real InnerTube client over recorded answers

    /// The regression for "Home stays on its skeletons forever": the model must reach .success
    /// from a real InnerTubeClient + YTMusicRepository answering FEmusic_home.
    func testHomeReachesSuccessAgainstAStubbedInnerTube() async throws {
        let repository = makeStubbedRepository()
        let feed = HomeFeedModel()

        await feed.load(repository, listener: nil, signedIn: false)

        let shelves = try XCTUnwrap(feed.state.value, "state: \(feed.state)")
        XCTAssertFalse(shelves.isEmpty)
        XCTAssertTrue(shelves.contains { $0.title.contains("biggest hits") }, shelves.map(\.title).description)
        XCTAssertNotNil(feed.continuation, "FEmusic_home's own continuation is kept for paging")
        XCTAssertFalse(feed.loadingMore, "every first-page request settled")
        XCTAssertFalse(feed.recentlyPlayedLoading)
        let requested = InnerTubeStub.requests.joined(separator: "\n")
        XCTAssertTrue(requested.contains("FEmusic_home"))
        XCTAssertTrue(requested.contains("FEmusic_new_releases"), "supplements are fetched alongside")
        XCTAssertFalse(requested.contains("FEmusic_history"), "signed out: no Recents request")
        // Titles are unique across the core feed and its supplements.
        let titles = shelves.map { $0.title.lowercased() }
        XCTAssertEqual(titles.count, Set(titles).count)
    }

    func testMoreShelvesAreAppendedFromTheContinuation() async throws {
        let repository = makeStubbedRepository()
        let feed = HomeFeedModel()
        await feed.load(repository, listener: nil, signedIn: false)
        let before = try XCTUnwrap(feed.state.value).count

        await feed.loadMore(repository)

        let after = try XCTUnwrap(feed.state.value)
        XCTAssertGreaterThan(after.count, before, "the continuation page's shelves land at the tail")
        XCTAssertTrue(InnerTubeStub.requests.contains { $0.hasSuffix("/browse ") }, "a continuation request was made")
    }

    func testAFailingHomeShowsAFriendlyErrorAndRetryRecovers() async throws {
        let offline = [InnerTubeStub.Route]() // every request fails as "no connection"
        let failing = makeStubbedRepository(routes: offline)
        let feed = HomeFeedModel()
        await feed.load(failing, listener: nil, signedIn: false)
        XCTAssertEqual(feed.state.errorMessage, L10n.noInternetConnection)

        let working = makeStubbedRepository()
        await feed.load(working, listener: nil, signedIn: false)
        XCTAssertNotNil(feed.state.value)
    }

    // MARK: - Feed rules (scripted)

    func testRecentsLeadWhenSignedInAndReplaceAStaleCopyFromTheFeed() async throws {
        let catalog = ScriptedCatalog()
        catalog.homeAnswer = { HomeFeed(shelves: [shelf("Quick picks", ["a"]), shelf("recents", ["old"])], continuation: nil) }
        catalog.recentAnswer = {
            try await Task.sleep(for: .milliseconds(50))
            return shelf("Recents", ["r1", "r2"])
        }
        let feed = HomeFeedModel(supplementIds: [])

        await feed.load(catalog, listener: "account-1", signedIn: true)

        let shelves = try XCTUnwrap(feed.state.value)
        XCTAssertEqual(shelves.map(\.title), ["Recents", "Quick picks"])
        XCTAssertEqual(shelves[0].items.compactMap(\.videoId), ["r1", "r2"])
        XCTAssertFalse(feed.recentlyPlayedLoading)
        XCTAssertTrue(feed.isLoaded(for: "account-1"))
        XCTAssertFalse(feed.isLoaded(for: nil), "signing out is a different listener and reloads")
    }

    func testWhileRecentsLoadsItsSkeletonOwnsTheHeadOfThePage() async throws {
        let catalog = ScriptedCatalog()
        let gate = AsyncGate()
        catalog.homeAnswer = { HomeFeed(shelves: [shelf("Quick picks", ["a"])], continuation: nil) }
        catalog.recentAnswer = {
            await gate.wait()
            return nil
        }
        let feed = HomeFeedModel(supplementIds: [])
        let load = Task { await feed.load(catalog, listener: "k", signedIn: true) }
        await waitUntil("core feed published") { feed.state.value != nil }
        XCTAssertTrue(feed.recentlyPlayedLoading)
        await gate.open()
        await load.value
        XCTAssertFalse(feed.recentlyPlayedLoading)
        XCTAssertEqual(feed.state.value?.map(\.title), ["Quick picks"], "no history: no Recents shelf")
    }

    func testSupplementsJoinTheFeedWithoutRepeatingATitle() async throws {
        let catalog = ScriptedCatalog()
        catalog.homeAnswer = { HomeFeed(shelves: [shelf("Quick picks", ["a"]), shelf("New releases", ["b"])], continuation: "t1") }
        catalog.supplementAnswers["FEmusic_new_releases"] = {
            try await Task.sleep(for: .milliseconds(30))
            return [shelf("new releases", ["c"]), shelf("Albums & singles", ["d"])]
        }
        let feed = HomeFeedModel(supplementIds: ["FEmusic_new_releases"])
        await feed.load(catalog, listener: nil, signedIn: false)
        XCTAssertEqual(feed.state.value?.map(\.title), ["Quick picks", "New releases", "Albums & singles"])
    }

    func testTheCoreFeedFailingIsOnlyAnErrorWhenNothingElseArrived() async throws {
        let catalog = ScriptedCatalog()
        catalog.homeAnswer = { throw InnerTubeError.httpStatus(403, endpoint: "browse") }
        let feed = HomeFeedModel(supplementIds: [])
        await feed.load(catalog, listener: nil, signedIn: false)
        XCTAssertEqual(feed.state.errorMessage, L10n.youtubeRequestRejected)

        catalog.supplementAnswers["FEmusic_explore"] = { [shelf("Charts", ["x"])] }
        let withSupplement = HomeFeedModel(supplementIds: ["FEmusic_explore"])
        catalog.homeAnswer = {
            try await Task.sleep(for: .milliseconds(50))
            throw URLError(.timedOut)
        }
        await withSupplement.load(catalog, listener: nil, signedIn: false)
        XCTAssertEqual(withSupplement.state.value?.map(\.title), ["Charts"], "a supplement already on screen stays")
    }

    func testPagingStopsWhenAPageAddsNothingNew() async throws {
        let catalog = ScriptedCatalog()
        catalog.homeAnswer = { HomeFeed(shelves: [shelf("Quick picks", ["a"])], continuation: "t1") }
        catalog.moreAnswer = { token in
            token == "t1"
                ? HomeFeed(shelves: [shelf("Mixed for you", ["m"])], continuation: "t2")
                : HomeFeed(shelves: [shelf("Quick picks", ["a"])], continuation: "t3")
        }
        let feed = HomeFeedModel(supplementIds: [])
        await feed.load(catalog, listener: nil, signedIn: false)

        await feed.loadMore(catalog)
        XCTAssertEqual(feed.state.value?.map(\.title), ["Quick picks", "Mixed for you"])
        XCTAssertEqual(feed.continuation, "t2")

        await feed.loadMore(catalog)
        XCTAssertNil(feed.continuation, "a page of repeats means the feed looped: stop, don't spin")
        await feed.loadMore(catalog)
        XCTAssertEqual(catalog.calls.filter { $0.hasPrefix("more:") }, ["more:t1", "more:t2"])
    }

    func testPullToRefreshKeepsTheFeedOnScreenAndSwapsItInPlace() async throws {
        let catalog = ScriptedCatalog()
        var round = 0
        catalog.homeAnswer = {
            round += 1
            return HomeFeed(shelves: [shelf("Round \(round)", ["a"])], continuation: nil)
        }
        let feed = HomeFeedModel(supplementIds: [])
        await feed.load(catalog, listener: nil, signedIn: false)
        XCTAssertEqual(feed.state.value?.map(\.title), ["Round 1"])

        catalog.homeAnswer = {
            try await Task.sleep(for: .milliseconds(50))
            return HomeFeed(shelves: [shelf("Round 2", ["b"])], continuation: nil)
        }
        let refresh = Task { await feed.refresh(catalog, listener: nil, signedIn: false) }
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(feed.refreshing)
        XCTAssertEqual(feed.state.value?.map(\.title), ["Round 1"], "no skeleton during a refresh")
        await refresh.value
        XCTAssertEqual(feed.state.value?.map(\.title), ["Round 2"])
        XCTAssertFalse(feed.refreshing)
    }

    func testARefreshFinishesWhenTheTaskThatAskedForItIsCancelled() async throws {
        let catalog = ScriptedCatalog()
        catalog.homeAnswer = { HomeFeed(shelves: [shelf("Round 1", ["a"])], continuation: nil) }
        let feed = HomeFeedModel(supplementIds: [])
        await feed.load(catalog, listener: nil, signedIn: false)

        catalog.homeAnswer = {
            try await Task.sleep(for: .milliseconds(50))
            return HomeFeed(shelves: [shelf("Round 2", ["b"])], continuation: nil)
        }
        let pull = Task { await feed.refresh(catalog, listener: nil, signedIn: false) }
        try await Task.sleep(for: .milliseconds(10))
        pull.cancel()
        await pull.value
        XCTAssertEqual(feed.state.value?.map(\.title), ["Round 2"])
        XCTAssertFalse(feed.refreshing)
    }

    func testAnOlderLoadCannotOverwriteANewerOne() async throws {
        let catalog = ScriptedCatalog()
        catalog.homeAnswer = {
            try await Task.sleep(for: .milliseconds(150))
            return HomeFeed(shelves: [shelf("Old account", ["a"])], continuation: nil)
        }
        let feed = HomeFeedModel(supplementIds: [])
        let first = Task { await feed.load(catalog, listener: "old", signedIn: false) }
        try await Task.sleep(for: .milliseconds(20))
        catalog.homeAnswer = { HomeFeed(shelves: [shelf("New account", ["b"])], continuation: nil) }
        await feed.load(catalog, listener: "new", signedIn: false)
        await first.value
        XCTAssertEqual(feed.state.value?.map(\.title), ["New account"])
    }

    // MARK: - Switching back to a listener (beyond Android)

    func testSwitchingBackPaintsTheListenersHomeFromTheirSnapshot() async throws {
        let catalog = ScriptedCatalog()
        let feed = await feedThatLeftA(catalog)
        let gate = AsyncGate()
        answerAsAAgain(catalog, core: gate, others: gate)

        let switchBack = Task { await feed.load(catalog, listener: "acct:A", signedIn: true) }
        await waitUntil("A's core feed is asked for") { catalog.calls.filter { $0 == "home" }.count == 3 }
        let painted = feed.state.value ?? []
        let recentsSkeleton = feed.recentlyPlayedLoading
        await gate.open()
        await switchBack.value

        XCTAssertEqual(painted.flatMap { $0.items.compactMap(\.videoId) }.sorted(), ["a", "n", "o", "r"],
                       "A's own shelves are up before A's core feed returns, and none of B's")
        XCTAssertFalse(recentsSkeleton, "the snapshot's Recents stands in for the skeleton")
        assertTheFreshPageOfA(feed)
    }

    func testOverASnapshotTheShelvesThatLandBeforeTheCoreFeedStay() async throws {
        let catalog = ScriptedCatalog()
        let feed = await feedThatLeftA(catalog)
        let core = AsyncGate()
        answerAsAAgain(catalog, core: core, others: nil)

        let switchBack = Task { await feed.load(catalog, listener: "acct:A", signedIn: true) }
        await waitUntil("the supplement and Recents landed over the snapshot") {
            let ids = Set((feed.state.value ?? []).flatMap { $0.items.compactMap(\.videoId) })
            return ids.isSuperset(of: ["n2", "r2"])
        }
        let held = feed.state.value ?? []
        await core.open()
        await switchBack.value

        XCTAssertEqual(held.map(\.title).sorted(), ["New releases", "Old mix", "Quick picks", "Recents"],
                       "each shelf once: the fresh ones in their stand-ins' places, the snapshot's core shelves still up")
        XCTAssertTrue(held.contains { $0.items.first?.videoId == "a" }, "the core feed is held: its snapshot shelf stands in")
        assertTheFreshPageOfA(feed)
    }

    func testOverASnapshotTheCoreFeedLandingFirstLeavesRoomForTheRest() async throws {
        let catalog = ScriptedCatalog()
        let feed = await feedThatLeftA(catalog)
        let others = AsyncGate()
        answerAsAAgain(catalog, core: nil, others: others)

        let switchBack = Task { await feed.load(catalog, listener: "acct:A", signedIn: true) }
        await waitUntil("the core feed landed over the snapshot") {
            (feed.state.value ?? []).contains { $0.items.first?.videoId == "a2" }
        }
        let held = feed.state.value ?? []
        await others.open()
        await switchBack.value

        XCTAssertTrue(held.contains { $0.items.first?.videoId == "n" }, "the supplement's snapshot shelf stays until its fresh copy lands")
        XCTAssertEqual(held.map(\.title).count, Set(held.map(\.feedKey)).count, "no shelf twice: \(held.map(\.title))")
        assertTheFreshPageOfA(feed)
    }

    func testSigningOutDropsTheHomeSnapshots() async throws {
        let catalog = ScriptedCatalog()
        let feed = await feedThatLeftA(catalog)
        catalog.homeAnswer = { HomeFeed(shelves: [shelf("Guest picks", ["g"])], continuation: nil) }
        await feed.load(catalog, listener: nil, signedIn: false)
        let gate = AsyncGate()
        answerAsAAgain(catalog, core: gate, others: gate)

        let signIn = Task { await feed.load(catalog, listener: "acct:A", signedIn: true) }
        await waitUntil("A's core feed is asked for") { catalog.calls.filter { $0 == "home" }.count == 4 }
        let paintedWhileLoading = feed.state
        await gate.open()
        await signIn.value

        XCTAssertTrue(paintedWhileLoading.isLoading, "after a sign-out A starts from the skeleton: \(paintedWhileLoading)")
        assertTheFreshPageOfA(feed)
    }

    /// A's first page (Recents, two core shelves, one supplement), then B's: A has a snapshot.
    private func feedThatLeftA(_ catalog: ScriptedCatalog) async -> HomeFeedModel {
        catalog.homeAnswer = { HomeFeed(shelves: [shelf("Quick picks", ["a"]), shelf("Old mix", ["o"])], continuation: nil) }
        catalog.supplementAnswers["FEmusic_new_releases"] = { [shelf("New releases", ["n"])] }
        catalog.recentAnswer = { shelf("Recents", ["r"]) }
        let feed = HomeFeedModel(supplementIds: ["FEmusic_new_releases"])
        await feed.load(catalog, listener: "acct:A", signedIn: true)

        catalog.homeAnswer = { HomeFeed(shelves: [shelf("B picks", ["b"])], continuation: nil) }
        catalog.supplementAnswers["FEmusic_new_releases"] = { [shelf("B releases", ["bn"])] }
        catalog.recentAnswer = { shelf("Recents", ["rb"]) }
        await feed.load(catalog, listener: "acct:B", signedIn: true)
        XCTAssertEqual(Set(feed.state.value?.map(\.title) ?? []), ["Recents", "B picks", "B releases"])
        return feed
    }

    /// A's fresh first page: the core feed no longer carries "Old mix". `core` holds the core
    /// feed open and `others` the supplement and Recents.
    private func answerAsAAgain(_ catalog: ScriptedCatalog, core: AsyncGate?, others: AsyncGate?) {
        catalog.homeAnswer = {
            await core?.wait()
            return HomeFeed(shelves: [shelf("Quick picks", ["a2"]), shelf("recents", ["stale"])], continuation: nil)
        }
        catalog.supplementAnswers["FEmusic_new_releases"] = {
            await others?.wait()
            return [shelf("New releases", ["n2"])]
        }
        catalog.recentAnswer = {
            await others?.wait()
            return shelf("Recents", ["r2"])
        }
    }

    /// Recents first, then the core shelf and the supplement, each once and fresh; nothing of B's
    /// and nothing the fresh page dropped.
    private func assertTheFreshPageOfA(_ feed: HomeFeedModel, file: StaticString = #filePath, line: UInt = #line) {
        let shelves = feed.state.value ?? []
        XCTAssertEqual(shelves.first?.title, "Recents", "\(shelves.map(\.title))", file: file, line: line)
        XCTAssertEqual(shelves.map(\.title).sorted(), ["New releases", "Quick picks", "Recents"], file: file, line: line)
        XCTAssertEqual(shelves.flatMap { $0.items.compactMap(\.videoId) }.sorted(), ["a2", "n2", "r2"], file: file, line: line)
    }

    // MARK: - Cards

    func testASongCardIsCreditedToItsArtistAndACollectionOpensByItsBrowseId() {
        let song = ShelfItem(title: "Crush", subtitle: "Song • Chelsea Wolfe • 2.1M plays", thumbnailUrl: nil, videoId: "v1", browseId: nil)
        XCTAssertEqual(song.shelfSong?.artist, "Chelsea Wolfe")
        XCTAssertNil(song.shelfBrowseItem)

        let album = ShelfItem(title: "Birth of Violence", subtitle: "Album • Chelsea Wolfe", thumbnailUrl: nil, videoId: nil, browseId: "MPREb_x")
        XCTAssertNil(album.shelfSong)
        XCTAssertEqual(album.shelfBrowseItem?.type, .album)
        XCTAssertEqual(ShelfItem(title: "A", subtitle: "", thumbnailUrl: nil, videoId: nil, browseId: "UCabc").shelfBrowseItem?.type, .artist)
    }

    func testTappingASongCardStartsAOneOffFromIt() async throws {
        let harness = PlayerHarness(test: self)
        let queued = try harness.song("q1")
        harness.player.play([queued], source: QueueSource(title: "Album", type: .browse))
        let card = try harness.song("card1")
        let item = ShelfItem(title: card.title, subtitle: "Song • \(card.artist)", thumbnailUrl: nil, videoId: card.videoId, browseId: nil)

        // What HomeScreen.openItem does for a song card.
        harness.player.playSong(try XCTUnwrap(item.shelfSong), source: QueueSource(title: "Quick picks", type: .home))

        await waitUntil("the card plays") { harness.player.currentSong?.videoId == "card1" }
        XCTAssertEqual(harness.player.playingFrom?.caption.isEmpty, false)
    }

    func testTappingAnAlbumCardOpensItAndHoldingItOpensItsMenu() throws {
        let app = makeBrowseTestApp()
        let navigator = BrowseNavigator(app: app)
        let album = ShelfItem(title: "Discovery", subtitle: "Album • Daft Punk", thumbnailUrl: nil, videoId: nil, browseId: "MPREb_discovery")

        navigator.openCard(album, source: QueueSource(title: "New releases", type: .home))
        guard case .album(let browseId, _)? = app.router.path(for: app.router.selectedTab).last else {
            return XCTFail("expected the album page, got \(app.router.path(for: app.router.selectedTab))")
        }
        XCTAssertEqual(browseId, "MPREb_discovery")

        navigator.openCardMenu(album)
        XCTAssertEqual(app.router.sheet, .browseActions(try XCTUnwrap(album.shelfBrowseItem)))
        app.router.dismissSheet()
        navigator.openCardMenu(ShelfItem(title: "Daft Punk", subtitle: "Artist", thumbnailUrl: nil, videoId: nil, browseId: "UCabc"))
        XCTAssertNil(app.router.sheet, "holding an artist does nothing")
        let song = ShelfItem(title: "One More Time", subtitle: "Song • Daft Punk", thumbnailUrl: nil, videoId: "v1", browseId: nil)
        navigator.openCardMenu(song)
        XCTAssertEqual(app.router.sheet, .songActions(try XCTUnwrap(song.shelfSong)))
    }

    // MARK: - Rendering

    func testHomeRendersItsShelvesFromAStubbedInnerTube() async throws {
        let app = makeBrowseTestApp()
        await host(HomeScreen(), app: app, timeout: 5) {
            InnerTubeStub.requests.contains { $0.contains("FEmusic_home") }
        }
        XCTAssertTrue(InnerTubeStub.requests.contains { $0.contains("FEmusic_home") }, "Home's .task asked for the feed")
        // Landscape, light mode and the largest accessibility text size lay out too.
        await host(HomeScreen(), app: app, size: CGSize(width: 852, height: 393), timeout: 1)
        await host(HomeScreen().environment(\.dynamicTypeSize, .accessibility3), app: app, colorScheme: .light, timeout: 1)
    }
}

extension HomeFeedTests {
    private static func continuationRequests() -> Int {
        InnerTubeStub.requests.filter { $0.hasSuffix("/browse ") }.count
    }

    /// Review fix: the screen used to ask for the next page every time a page settled, wherever
    /// the reader was, so opening Home walked the whole continuation chain with the list at the
    /// top. HomeScreen.kt only pages while one of the last three shelves is on screen.
    ///
    /// The recorded first page is short (four shelves, the tail on screen), so it legitimately
    /// asks for page two once. That page adds two shelves and pushes the tail below the fold: no
    /// further request may follow while the reader stays at the top.
    func testHomeDoesNotPageWhileTheTailIsOffScreen() async throws {
        let app = makeBrowseTestApp()
        await host(HomeScreen(), app: app, timeout: 5) { Self.continuationRequests() > 0 }
        // Let page two land and the page settle: the count must hold still for a stretch long
        // enough that a further request, if Home still walked the chain, would have shown up.
        var seen = Self.continuationRequests()
        var quietSince = Date()
        let giveUp = Date().addingTimeInterval(20)
        while Date().timeIntervalSince(quietSince) < 1.5, Date() < giveUp {
            try await Task.sleep(for: .milliseconds(100))
            let now = Self.continuationRequests()
            if now != seen { seen = now; quietSince = Date() }
        }
        XCTAssertEqual(Self.continuationRequests(), 1, InnerTubeStub.requests.joined(separator: "\n"))
    }

    /// With the whole feed on screen (a very tall window), the real shelves' rows appear — so the
    /// success branch drew its shelves rather than the skeleton — and the next page is asked for.
    func testHomePagesOnceItsLastShelvesAreOnScreen() async throws {
        let app = makeBrowseTestApp()
        await host(HomeScreen(), app: app, size: CGSize(width: 393, height: 20_000), timeout: 8) {
            Self.continuationRequests() > 0
        }
        XCTAssertGreaterThan(Self.continuationRequests(), 0, InnerTubeStub.requests.joined(separator: "\n"))
    }
}

/// A one-shot latch for ordering async test steps.
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
