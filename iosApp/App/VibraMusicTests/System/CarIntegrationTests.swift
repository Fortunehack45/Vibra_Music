import VibraMusicCore
import CarPlay
import XCTest
@testable import VibraMusic

/// Canned folders for the car's tree, counting what was asked.
@MainActor
final class FakeCarSource: CarLibrarySource {
    var signedIn = true
    var accountKey: String? = "account:a"
    var recentSongs: [Song] = []
    var quickPickSongs: [Song] = []
    var homeFeedSongs: [Song] = []
    var liked: [Song] = []
    var playlists: [ShelfItem] = []
    var pages: [String: [Song]] = [:]
    var results: [SearchResult] = []
    var downloads: [Song] = []
    var local: [Song] = []

    private(set) var calls: [String] = []
    private(set) var quickPickExclusions: [Set<String>] = []

    func isSignedIn() async -> Bool { signedIn }
    func recents() async throws -> [Song] { calls.append("recents"); return recentSongs }
    func quickPicks(excluding: Set<String>) async throws -> [Song] {
        calls.append("quickPicks")
        quickPickExclusions.append(excluding)
        return quickPickSongs.filter { !excluding.contains($0.videoId) }
    }
    func homeSongs() async -> [Song] { calls.append("home"); return homeFeedSongs }
    func likedSongs() async throws -> [Song] { calls.append("liked"); return liked }
    func libraryPlaylists() async throws -> [ShelfItem] { calls.append("playlists"); return playlists }
    func songs(browseId: String) async throws -> [Song] { calls.append("page:\(browseId)"); return pages[browseId] ?? [] }
    func search(_ query: String) async throws -> [SearchResult] { calls.append("search:\(query)"); return results }
    func downloadedSongs() -> [Song] { downloads }
    func localSongs() -> [Song] { local }
}

private func song(_ id: String) -> Song { Song(videoId: id, title: "Song \(id)", artist: "Artist \(id)") }

/// PORTING.md "Car integration": the Android Auto browse tree (PlaybackService.kt,
/// AndroidAutoMediaLibraryTest.kt), CarPlay's templates for it, and the Now Playing buttons.
@MainActor
final class CarIntegrationTests: XCTestCase {
    func testTheRootHasTheAndroidAutoFoldersInOrder() async {
        let library = CarLibrary(source: FakeCarSource())
        let root = await library.children(of: CarNodeID.root)
        XCTAssertEqual(root.map(\.id), ["quick_picks", "recents", "playlists", "liked", "more"])
        XCTAssertEqual(root.map(\.title), [L10n.autoQuickPicks, L10n.autoRecents, L10n.playlists, L10n.autoLiked, L10n.more])
        let more = await library.children(of: CarNodeID.more)
        XCTAssertEqual(more.map(\.id), ["downloads", "local_music"])
    }

    func testSignedOutLikedAndPlaylistsAskToSignInOnThePhone() async {
        let source = FakeCarSource()
        source.signedIn = false
        let library = CarLibrary(source: source)
        let liked = await library.children(of: CarNodeID.liked)
        XCTAssertEqual(liked, [.info(id: CarNodeID.loginRequired, title: L10n.autoLoginTitle, subtitle: L10n.autoLoginSubtitle)])
        let playlists = await library.children(of: CarNodeID.playlists)
        XCTAssertEqual(playlists.map(\.id), [CarNodeID.loginRequired])
        XCTAssertFalse(source.calls.contains("liked"), "nothing is fetched for a signed-out account")
    }

    func testEmptyFoldersSayWhy() async {
        let library = CarLibrary(source: FakeCarSource())
        let recents = await library.children(of: CarNodeID.recents)
        XCTAssertEqual(recents, [.info(id: "msg:empty_recents", title: L10n.autoEmptyRecentsTitle, subtitle: L10n.autoEmptyRecentsSubtitle)])
        let downloads = await library.children(of: CarNodeID.downloads)
        XCTAssertEqual(downloads.first?.title, L10n.autoEmptyOfflineTitle)
    }

    func testQuickPicksLeaveOutRecentsAndFallBackToTheHomeFeed() async {
        let source = FakeCarSource()
        source.recentSongs = [song("a"), song("b")]
        source.quickPickSongs = [song("a"), song("c")]
        let library = CarLibrary(source: source)
        _ = await library.children(of: CarNodeID.recents)
        let picks = await library.children(of: CarNodeID.quickPicks)
        XCTAssertEqual(picks.map(\.id), ["c"])
        XCTAssertEqual(source.quickPickExclusions.last, ["a", "b"])

        let empty = FakeCarSource()
        empty.homeFeedSongs = [song("h1"), song("h1"), song("h2")]
        let fallback = await CarLibrary(source: empty).children(of: CarNodeID.quickPicks)
        XCTAssertEqual(fallback.map(\.id), ["h1", "h2"], "home shelves' songs, once each")
    }

    func testQuickPicksOpenedBeforeRecentsStillLeaveRecentsOut() async {
        let source = FakeCarSource()
        source.recentSongs = [song("a"), song("b")]
        source.quickPickSongs = [song("a"), song("c")]
        let library = CarLibrary(source: source)
        let picks = await library.children(of: CarNodeID.quickPicks)
        XCTAssertEqual(picks.map(\.id), ["c"])
        XCTAssertEqual(source.quickPickExclusions.last, ["a", "b"])
    }

    func testLikedSongsAndPlaylistsOfAnotherAccountAreNotServedFromCache() async {
        let source = FakeCarSource()
        source.liked = [song("mine")]
        let library = CarLibrary(source: source)
        let first = await library.children(of: CarNodeID.liked)
        XCTAssertEqual(first.map(\.id), ["mine"])

        source.accountKey = "account:b"
        source.liked = [song("theirs")]
        let second = await library.children(of: CarNodeID.liked)
        XCTAssertEqual(second.map(\.id), ["theirs"], "within the 60 s TTL, but another account")
    }

    func testFoldersAreServedFromCacheAndRefreshedWhenStale() async {
        let source = FakeCarSource()
        source.recentSongs = [song("a")]
        var clock = Date(timeIntervalSince1970: 1_000)
        let library = CarLibrary(source: source, now: { clock })
        var refreshed: [String] = []
        library.onFolderRefreshed = { refreshed.append($0) }

        _ = await library.children(of: CarNodeID.recents)
        _ = await library.children(of: CarNodeID.recents)
        XCTAssertEqual(source.calls.filter { $0 == "recents" }.count, 1, "opened twice in 30 s: fetched once")

        clock.addTimeInterval(CarLibrary.recentsTTL + 1)
        source.recentSongs = [song("b")]
        let stale = await library.children(of: CarNodeID.recents)
        XCTAssertEqual(stale.map(\.id), ["a"], "a stale folder shows at once")
        await waitUntil("refreshed behind it") { refreshed == [CarNodeID.recents] }
        let fresh = await library.children(of: CarNodeID.recents)
        XCTAssertEqual(fresh.map(\.id), ["b"])
    }

    func testPlaylistsOpenTheirSongsWithTheBareIdAsFallback() async {
        let source = FakeCarSource()
        source.playlists = [
            ShelfItem(title: "Road trip", subtitle: "Playlist", thumbnailUrl: nil, videoId: nil, browseId: "VLPL123"),
            ShelfItem(title: "Discovery", subtitle: "Album", thumbnailUrl: nil, videoId: nil, browseId: "MPREb_x"),
        ]
        source.pages = ["PL123": [song("p1")], "MPREb_x": [song("m1"), song("m2")]]
        let library = CarLibrary(source: source)
        let folders = await library.children(of: CarNodeID.playlists)
        XCTAssertEqual(folders.map(\.id), ["playlist:PL123", "browse:MPREb_x"])

        let playlist = await library.children(of: "playlist:PL123")
        XCTAssertEqual(playlist.map(\.id), ["p1"])
        XCTAssertEqual(source.calls.suffix(2), ["page:VLPL123", "page:PL123"], "VL first, then the bare id")
        let album = await library.children(of: "browse:MPREb_x")
        XCTAssertEqual(album.map(\.id), ["m1", "m2"])
        XCTAssertEqual(library.song(for: "m2")?.title, "Song m2")
    }

    func testSearchListsSongsThenPagesOnceEachAndIsCached() async {
        let source = FakeCarSource()
        source.results = [
            .topTrack(song("t")), .track(song("t")), .track(song("u")),
            .browse(BrowseItem(browseId: "MPREb_a", title: "Album", subtitle: "", thumbnailUrl: nil, type: .album)),
            .browse(BrowseItem(browseId: "MPREb_a", title: "Album", subtitle: "", thumbnailUrl: nil, type: .album)),
        ]
        let library = CarLibrary(source: source)
        let results = await library.search("  Daft Punk ")
        XCTAssertEqual(results.map(\.id), ["t", "u", "browse:MPREb_a"])
        _ = await library.search("Daft Punk")
        XCTAssertEqual(source.calls.filter { $0.hasPrefix("search:") }, ["search:Daft Punk"])
        let blank = await library.search("   ")
        XCTAssertTrue(blank.isEmpty)
    }

    func testASearchThatCameBackEmptyIsAskedAgain() async {
        let source = FakeCarSource()
        let library = CarLibrary(source: source)
        let timedOut = await library.search("daft punk")
        XCTAssertTrue(timedOut.isEmpty)

        source.results = [.track(song("t"))]
        let retried = await library.search("daft punk")
        XCTAssertEqual(retried.map(\.id), ["t"])
    }

    /// A car caps its lists, so a long Up Next starts at the playing song instead of the top.
    func testUpNextKeepsThePlayingSongOnScreenInALongQueue() {
        XCTAssertEqual(CarPlayCoordinator.upNextWindow(count: 5, current: 3, limit: 12), 0..<5)
        XCTAssertEqual(CarPlayCoordinator.upNextWindow(count: 200, current: 150, limit: 12), 150..<162)
        XCTAssertEqual(CarPlayCoordinator.upNextWindow(count: 200, current: 195, limit: 12), 188..<200)
        XCTAssertEqual(CarPlayCoordinator.upNextWindow(count: 0, current: 0, limit: 12), 0..<0)
    }

    func testNowPlayingCarriesFavoriteShuffleRadioAndRevert() {
        let youTube = Song(videoId: "dQw4w9WgXcQ", title: "t", artist: "a")
        XCTAssertEqual(CarNowPlayingButton.buttons(for: youTube, liked: true, shuffle: false, isPinnedToOriginal: { _ in false }),
                       [.favorite(liked: true), .shuffle(on: false), .radio, .revert])
        XCTAssertEqual(CarNowPlayingButton.buttons(for: youTube, liked: false, shuffle: true, isPinnedToOriginal: { _ in true }),
                       [.favorite(liked: false), .shuffle(on: true), .radio], "already pinned to the original: no Revert")
        let file = Song(videoId: "file:///x.m4a", title: "t", artist: "a", localUri: "file:///x.m4a")
        XCTAssertEqual(CarNowPlayingButton.buttons(for: file, liked: false, shuffle: false, isPinnedToOriginal: { _ in false }),
                       [.favorite(liked: false), .shuffle(on: false)], "a file on the phone has no station and no original")
        XCTAssertEqual(CarNowPlayingButton.buttons(for: nil, liked: false, shuffle: false, isPinnedToOriginal: { _ in false }).count, 2)
    }

    /// Render smoke for the car: the tab bar, a folder's list and its rows, Now Playing's buttons
    /// and Up Next, built as CarPlay templates.
    func testTheTemplatesAreBuiltForEveryFolder() async throws {
        let harness = PlayerHarness(test: self)
        let source = FakeCarSource()
        source.recentSongs = [song("r1"), song("r2")]
        source.signedIn = false
        let coordinator = CarPlayCoordinator(library: CarLibrary(source: source), player: harness.player, isPinnedToOriginal: { _ in false })

        let root = coordinator.makeRootTemplate()
        let tabs = root.templates.compactMap { $0 as? CPListTemplate }
        XCTAssertEqual(tabs.count, min(5, max(2, CPTabBarTemplate.maximumTabCount)))
        XCTAssertEqual(tabs.first?.tabTitle, L10n.autoQuickPicks)
        XCTAssertEqual(tabs.last?.tabTitle, L10n.more)

        let recents = coordinator.makeList(for: CarNodeID.recents, title: L10n.autoRecents)
        await waitUntil("recents filled in") { recents.sections.first?.items.count == 2 }
        XCTAssertEqual((recents.sections.first?.items.first as? CPListItem)?.text, "Song r1")

        let liked = coordinator.makeList(for: CarNodeID.liked, title: L10n.autoLiked)
        await waitUntil("the sign-in row") { liked.sections.first?.items.count == 1 }
        let prompt = try XCTUnwrap(liked.sections.first?.items.first as? CPListItem)
        XCTAssertEqual(prompt.text, L10n.autoLoginTitle)
        XCTAssertFalse(prompt.isEnabled)

        XCTAssertEqual(coordinator.nowPlayingButtons(), [.favorite(liked: false), .shuffle(on: false)])
        XCTAssertTrue(coordinator.makeButton(.shuffle(on: true)) is CPNowPlayingShuffleButton)
        XCTAssertTrue(coordinator.makeButton(.radio) is CPNowPlayingImageButton)
        XCTAssertEqual(coordinator.makeUpNextTemplate().title, L10n.upNext)
    }

    /// CarPlay keeps a tab alive for the whole drive; coming back to it re-reads the folder (Android
    /// Auto re-asks on every open), and the playing marker follows the player.
    func testAFolderIsReReadWhenItComesBackAndThePlayingRowFollows() async throws {
        let harness = PlayerHarness(test: self)
        let source = FakeCarSource()
        source.signedIn = false
        source.liked = [song("l1"), song("l2")]
        let coordinator = CarPlayCoordinator(library: CarLibrary(source: source), player: harness.player, isPinnedToOriginal: { _ in false })
        let liked = coordinator.makeList(for: CarNodeID.liked, title: L10n.autoLiked)
        await waitUntil("the sign-in row") { (liked.sections.first?.items.first as? CPListItem)?.text == L10n.autoLoginTitle }

        source.signedIn = true
        coordinator.refresh(liked)
        await waitUntil("signed in on the phone: the songs") { liked.sections.first?.items.count == 2 }

        let rows = try XCTUnwrap(liked.sections.first?.items as? [CPListItem])
        coordinator.markPlaying("l2")
        XCTAssertEqual(rows.map(\.isPlaying), [false, true])
        coordinator.markPlaying("l1")
        XCTAssertEqual(rows.map(\.isPlaying), [true, false])
    }

    func testChoosingASongPlaysItAndAutoplayCarriesOn() async throws {
        let harness = PlayerHarness(test: self)
        let chosen = try harness.song("cccccccccc1")
        let coordinator = CarPlayCoordinator(library: CarLibrary(source: FakeCarSource()), player: harness.player, isPinnedToOriginal: { _ in false })
        coordinator.play(chosen, from: L10n.autoRecents, folderId: CarNodeID.recents)
        XCTAssertEqual(harness.player.currentSong?.videoId, chosen.videoId)
        await waitUntil("playing") { harness.engine.isPlaying }
        XCTAssertEqual(CarPlayCoordinator.sourceType(CarNodeID.recents), .history)
    }
}
