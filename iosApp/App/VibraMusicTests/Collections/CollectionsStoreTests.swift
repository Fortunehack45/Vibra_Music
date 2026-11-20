import VibraMusicCore
import Downloads
import InnerTube
import PlaybackQueue
import SwiftUI
import XCTest
@testable import VibraMusic

// The Collections view models (CollectionsStore) against a fake YouTube Music, one class per
// PORTING.md feature.

@MainActor
final class AlbumPlaylistPageTests: XCTestCase {
    /// PORTING.md "Album and playlist pages" done criterion: the user opens an album, taps Shuffle,
    /// and the queue is that album, shuffled.
    func testOpeningAnAlbumAndTappingShuffleQueuesThatAlbumShuffled() async throws {
        await enableAccessibilityTree()
        let service = FakeCollectionsService()
        service.songPages[CollectionsFixtures.albumId] = CollectionsFixtures.albumPage
        let (model, _, _) = makeCollectionsTestModel(self, service: service)
        let harness = PlayerHarness(test: self)
        let host = await host(AlbumPlaylistScreen(browseId: CollectionsFixtures.albumId, seed: nil), model: model,
                              player: harness.player, inScene: true, settle: 0.8)

        let found = await host.view.control(identifier: "detail.shuffle", label: L10n.shuffle)
        let shuffle = try XCTUnwrap(found, "the Shuffle button is not on screen: \(host.view.renderedLabels)")
        XCTAssertTrue(shuffle.accessibilityActivate(), "the button took no tap")

        let songs = CollectionsFixtures.albumSongs
        XCTAssertTrue(harness.player.shuffleEnabled)
        XCTAssertEqual(Set(harness.player.songs.map(\.videoId)), Set(songs.map(\.videoId)))
        XCTAssertEqual(harness.player.songs.count, songs.count)
        XCTAssertEqual(harness.player.playingFromSource?.id, CollectionsFixtures.albumId)
    }

    /// The page is drawn from what the card knew, then filled in from the header: an album's
    /// header subtitle (with its year) replaces the card's, the description is kept for About.
    func testAnOpenedAlbumTakesItsHeaderAndDescription() async {
        let (store, service) = makeCollectionsStore()
        service.songPages[CollectionsFixtures.albumId] = CollectionsFixtures.albumPage
        let seed = BrowseItem(browseId: CollectionsFixtures.albumId, title: "Discovery", subtitle: "Daft Punk", thumbnailUrl: nil, type: .album)
        await store.openPage(CollectionsFixtures.albumId, seed: seed, type: .album)
        let page = store.page(CollectionsFixtures.albumId)
        XCTAssertEqual(page?.title, "Discovery")
        XCTAssertEqual(page?.subtitle, "Album • Daft Punk • 2001")
        XCTAssertEqual(page?.type, .album)
        XCTAssertNotNil(page?.description)
        XCTAssertEqual(page?.library?.saved, false)
    }

    /// A long playlist carries on behind the reader: continuations are appended, suggestions kept
    /// apart, and a page that repeats itself ends the walk.
    func testALongPlaylistIsFilledInFromItsContinuations() async {
        let (store, service) = makeCollectionsStore()
        service.songPages["VLPLlong"] = .init(songs: [CollectionsFixtures.song("a", "A")], continuation: "t1")
        service.continuations["t1"] = .init(songs: [CollectionsFixtures.song("b", "B")], continuation: "t2",
                                            suggested: [CollectionsFixtures.song("s", "Suggested")])
        service.continuations["t2"] = .init(songs: [CollectionsFixtures.song("b", "B")], continuation: "t3")
        await store.openPage("VLPLlong", seed: nil, type: .playlist)
        XCTAssertEqual(store.page("VLPLlong")?.songs.value?.map(\.videoId), ["a", "b"])
        XCTAssertEqual(store.page("VLPLlong")?.suggestedSongs.map(\.videoId), ["s"])
        XCTAssertFalse(service.calls.contains("more:t3"))
    }

    /// Saving to the library is optimistic and rolled back when YouTube refuses.
    func testSavingToTheLibraryIsOptimisticAndRolledBackOnRefusal() async {
        let (store, service) = makeCollectionsStore()
        service.songPages[CollectionsFixtures.albumId] = CollectionsFixtures.albumPage
        await store.openPage(CollectionsFixtures.albumId, seed: nil, type: .album)

        await store.toggleLibrary(CollectionsFixtures.albumId)
        XCTAssertEqual(store.page(CollectionsFixtures.albumId)?.library?.saved, true)
        XCTAssertTrue(service.calls.contains("saved:OLAK5uy_album:true"))
        XCTAssertTrue(store.libraryStale)

        service.failWrites = true
        await store.toggleLibrary(CollectionsFixtures.albumId)
        XCTAssertEqual(store.page(CollectionsFixtures.albumId)?.library?.saved, true, "a refused write is rolled back")
    }

    /// An empty page says so rather than drawing nothing; a failed one shows its error.
    func testAnEmptyOrFailedPageSaysSo() async {
        let (store, service) = makeCollectionsStore()
        service.songPages["VLPLempty"] = .init(songs: [], continuation: nil)
        await store.openPage("VLPLempty", seed: nil, type: .playlist)
        XCTAssertEqual(store.page("VLPLempty")?.songs.errorMessage, L10n.noTracksHere)
        await store.openPage("VLPLmissing", seed: nil, type: .playlist)
        XCTAssertNotNil(store.page("VLPLmissing")?.songs.errorMessage)
    }

    /// Hosted and laid out: the page asks for its tracks as it appears and draws them.
    func testTheAlbumPageRenders() async {
        let service = FakeCollectionsService()
        service.songPages[CollectionsFixtures.albumId] = CollectionsFixtures.albumPage
        let (model, store, _) = makeCollectionsTestModel(self, service: service)
        let host = await host(AlbumPlaylistScreen(browseId: CollectionsFixtures.albumId, seed: nil), model: model)
        XCTAssertTrue(service.calls.contains("browse:\(CollectionsFixtures.albumId)"))
        XCTAssertEqual(store.page(CollectionsFixtures.albumId)?.songs.value?.count, 4)
        XCTAssertGreaterThan(host.view.bounds.height, 0)
        let light = await self.host(AlbumPlaylistScreen(browseId: CollectionsFixtures.albumId, seed: nil), model: model, colorScheme: .light)
        XCTAssertGreaterThan(light.view.bounds.height, 0)
    }

    /// DetailScreen.kt's header canvas: an album asks for its looping clip by title and credit once
    /// the header has said whose it is; a playlist never does, nor does anything with the setting off.
    func testAnAlbumHeaderLooksUpItsCanvasAndAPlaylistDoesNot() async {
        let service = FakeCollectionsService()
        service.songPages[CollectionsFixtures.albumId] = CollectionsFixtures.albumPage
        service.songPages[CollectionsFixtures.playlistId] = YTMusicRepository.SongPage(
            songs: CollectionsFixtures.playlistSongs, continuation: nil, library: nil,
            header: InnerTubeParser.BrowseHeader(title: "Mine", subtitle: "Playlist • Me", thumbnailUrl: nil), description: nil)
        let (model, _, _) = makeCollectionsTestModel(self, service: service)
        model.settings.animatedCanvas = true

        _ = await host(AlbumPlaylistScreen(browseId: CollectionsFixtures.albumId, seed: nil), model: model)
        XCTAssertEqual(service.albumCanvasRequests.last, "Discovery|Daft Punk")
        XCTAssertFalse(service.albumCanvasRequests.contains { $0.hasPrefix("|") || $0.hasSuffix("|") },
                       "never asked before the title and credit are known")

        service.albumCanvasRequests = []
        _ = await host(AlbumPlaylistScreen(browseId: CollectionsFixtures.playlistId, seed: nil), model: model)
        XCTAssertEqual(service.albumCanvasRequests, [])

        // The same album, whose title and credit are known: only the setting keeps it from asking.
        model.settings.animatedCanvas = false
        _ = await host(AlbumPlaylistScreen(browseId: CollectionsFixtures.albumId, seed: nil), model: model)
        XCTAssertEqual(service.albumCanvasRequests, [])
    }
}

@MainActor
final class ArtistPageTests: XCTestCase {
    /// PORTING.md "Artist pages" done criterion: the user sees top songs, and subscribing survives
    /// a refresh.
    func testSubscribingToAnArtistSurvivesARefresh() async {
        let (store, service) = makeCollectionsStore()
        service.artistPages[CollectionsFixtures.artistId] = CollectionsFixtures.artistPage
        await store.openPage(CollectionsFixtures.artistId, seed: nil, type: .artist)
        XCTAssertEqual(store.page(CollectionsFixtures.artistId)?.songs.value?.count, 25)
        XCTAssertEqual(store.page(CollectionsFixtures.artistId)?.title, "Daft Punk")
        XCTAssertEqual(store.page(CollectionsFixtures.artistId)?.subscription?.subscribed, false)

        await store.toggleSubscription(CollectionsFixtures.artistId)
        XCTAssertEqual(store.page(CollectionsFixtures.artistId)?.subscription?.subscribed, true)

        // Refresh: the page is read again from YouTube.
        await store.openPage(CollectionsFixtures.artistId, seed: nil, type: .artist)
        XCTAssertEqual(store.page(CollectionsFixtures.artistId)?.subscription?.subscribed, true)
        XCTAssertTrue(service.calls.contains("subscribed:UCartist:true"))
    }

    /// Top songs stop at twenty, four to a column; a release shelf shows five cards and "Show all".
    func testTopSongsAndReleaseShelvesAreCapped() {
        let page = CollectionsFixtures.artistPage
        XCTAssertEqual(page.songs.count, 25)
        let columns = CollectionsLimits.columns(of: CollectionsLimits.topSongs(of: page.songs))
        XCTAssertEqual(columns.map(\.count), [4, 4, 4, 4, 4])
        XCTAssertEqual(columns.first?.first?.videoId, "a1")
        XCTAssertEqual(columns.last?.last?.videoId, "a20")

        let releases = page.sections[0].items
        XCTAssertEqual(releases.count, 7)
        let capped = CollectionsLimits.releaseRow(releases)
        XCTAssertEqual(capped.shown.map(\.title), (1...5).map { "Album \($0)" })
        XCTAssertTrue(capped.canShowAll)
        let short = CollectionsLimits.releaseRow(Array(releases.prefix(5)))
        XCTAssertEqual(short.shown.count, 5)
        XCTAssertFalse(short.canShowAll, "a shelf of exactly five has nothing more to show")
    }

    /// A card on an artist page opens as an album unless its id says otherwise (MainActivity's
    /// `onSectionItemClick` → `openDetail` → `browseTypeOf`): a related artist opens an artist page,
    /// a "Featured on" playlist a playlist.
    func testACardOnAnArtistPageOpensAsWhatItsIdSays() {
        func route(_ id: String) -> AppRoute? {
            ArtistScreen.route(for: ShelfItem(title: "x", subtitle: "", thumbnailUrl: nil, videoId: nil, browseId: id))
        }
        guard case .album(let album, _)? = route("MPREb_1") else { return XCTFail("album card") }
        XCTAssertEqual(album, "MPREb_1")
        guard case .artist(let artist, _)? = route("UCother") else { return XCTFail("artist card") }
        XCTAssertEqual(artist, "UCother")
        guard case .playlist(let playlist, _)? = route("VLPLfeatured") else { return XCTFail("playlist card") }
        XCTAssertEqual(playlist, "VLPLfeatured")
        XCTAssertNil(route(""))
    }

    func testAFailedSubscribeIsRolledBack() async {
        let (store, service) = makeCollectionsStore()
        service.artistPages[CollectionsFixtures.artistId] = CollectionsFixtures.artistPage
        await store.openPage(CollectionsFixtures.artistId, seed: nil, type: .artist)
        service.failWrites = true
        await store.toggleSubscription(CollectionsFixtures.artistId)
        XCTAssertEqual(store.page(CollectionsFixtures.artistId)?.subscription?.subscribed, false)
    }

    func testTheArtistPageRenders() async {
        let service = FakeCollectionsService()
        service.artistPages[CollectionsFixtures.artistId] = CollectionsFixtures.artistPage
        let (model, store, _) = makeCollectionsTestModel(self, service: service)
        let host = await host(ArtistScreen(browseId: CollectionsFixtures.artistId, seed: nil), model: model)
        XCTAssertTrue(service.calls.contains("artist:\(CollectionsFixtures.artistId)"))
        XCTAssertEqual(store.page(CollectionsFixtures.artistId)?.sections.count, 1)
        XCTAssertGreaterThan(host.view.bounds.height, 0)
    }
}

@MainActor
final class LibraryTests: XCTestCase {
    private func libraryPage() -> LibraryPage {
        LibraryPage(
            likedSongs: [CollectionsFixtures.song("liked1", "Liked")],
            librarySongs: [],
            shelves: [
                HomeShelf(title: "Playlists", items: [CollectionsFixtures.card("VLLM", "Liked Music"), CollectionsFixtures.card("VLPLmine", "Mine")]),
                HomeShelf(title: "Albums", items: [CollectionsFixtures.card("MPREb_1", "Discovery")]),
                HomeShelf(title: "Subscriptions", items: [CollectionsFixtures.card("UCartist", "Daft Punk")]),
            ],
            likedContinuation: "liked-more"
        )
    }

    /// PORTING.md "Library": the signed-in library's shelves, Liked Music among the playlists, and
    /// the rest of Liked Music synced into the ratings behind it.
    func testASignedInListenerSeesTheirShelvesWithLikedMusicAsAPlaylist() async throws {
        let (store, service) = makeCollectionsStore()
        service.libraryPage = libraryPage()
        await store.loadLibraryIfNeeded()
        let page = try XCTUnwrap(store.library.value)
        XCTAssertEqual(page.shelves.map(\.title), ["Playlists", "Albums", "Subscriptions"])
        // YouTube lists Liked Music among the playlist cards; the Library opens it as a playlist.
        let liked = try XCTUnwrap(page.shelves[0].items.first { $0.title == "Liked Music" })
        XCTAssertEqual(liked.shelfBrowseItem?.type, .playlist)
        XCTAssertNil(page.likedContinuation, "the continuation is consumed, never kept as page state")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(service.calls.contains("syncLiked:liked-more"))

        // Shown again with nothing changed: no second fetch.
        await store.loadLibraryIfNeeded()
        XCTAssertEqual(service.calls.filter { $0 == "library" }.count, 1)
    }

    /// Signed out, nothing is fetched: the page shows the sign-in prompt instead.
    func testSignedOutTheLibraryIsNotFetched() async {
        let service = FakeCollectionsService()
        service.isSignedIn = false
        let (store, _) = makeCollectionsStore(service)
        await store.loadLibraryIfNeeded()
        XCTAssertTrue(store.library.isLoading)
        XCTAssertFalse(service.calls.contains("library"))
    }

    /// A write marks the library stale; the next visit fetches it again. A different listener's
    /// library is never shown to the next.
    func testAStaleOrSomeoneElsesLibraryIsFetchedAgain() async {
        let (store, service) = makeCollectionsStore()
        service.libraryPage = libraryPage()
        await store.loadLibraryIfNeeded()
        store.libraryStale = true
        await store.libraryShown()
        XCTAssertEqual(service.calls.filter { $0 == "library" }.count, 2)
        XCTAssertFalse(store.libraryStale)

        service.listenerKey = "listener-2"
        await store.loadLibraryIfNeeded()
        XCTAssertEqual(service.calls.filter { $0 == "library" }.count, 3)
    }

    /// A → B → A paints A's page from the snapshot while A's second fetch is still
    /// open, and the snapshot is never seeded from B — the identity guard stays the owner of
    /// whose data is whose.
    func testSwitchingBackPaintsFromTheSnapshotWhileTheRefreshRuns() async throws {
        let (store, service) = makeCollectionsStore()
        service.libraryPage = libraryPage()
        await store.loadLibraryIfNeeded()
        XCTAssertEqual(service.calls.filter { $0 == "library" }.count, 1)

        // A → B: A's page is snapshotted on the way out; B fetches its own.
        service.listenerKey = "listener-2"
        service.libraryPage = LibraryPage(likedSongs: [], librarySongs: [], shelves: [
            HomeShelf(title: "B's shelf", items: [CollectionsFixtures.card("Bcard", "B only")]),
        ])
        await store.loadLibraryIfNeeded()
        XCTAssertEqual(service.calls.filter { $0 == "library" }.count, 2)
        XCTAssertEqual(store.library.value?.shelves.map(\.title), ["B's shelf"])

        // B → A with A's second fetch held open: the snapshot paints before it returns.
        service.listenerKey = "listener-1"
        service.libraryPage = libraryPage()
        service.holdLibrary = true
        let entered = expectation(description: "A's refresh fetch entered")
        service.libraryEntered = entered
        let switchBack = Task { await store.loadLibraryIfNeeded() }
        await fulfillment(of: [entered], timeout: 5)
        // A failed assertion still lets the held fetch finish, so the fake is never left suspended.
        defer { service.releaseLibrary() }

        let painted = try XCTUnwrap(store.library.value, "A's page is up from the snapshot")
        XCTAssertEqual(painted.shelves.map(\.title), ["Playlists", "Albums", "Subscriptions"],
                       "A's snapshot holds A's data, never B's")
        XCTAssertEqual(service.calls.filter { $0 == "library" }.count, 3)

        // Distinct refresh data: the assertions below only pass if the fetch behind the snapshot
        // is applied, not dropped (e.g. by a regressed listener-identity guard).
        service.libraryPage = LibraryPage(likedSongs: [], librarySongs: [], shelves: [
            HomeShelf(title: "Refreshed Albums", items: [CollectionsFixtures.card("MPREb_2", "Homework")]),
        ])
        service.releaseLibrary()
        await switchBack.value
        XCTAssertEqual(service.calls.filter { $0 == "library" }.count, 3, "one refresh behind the snapshot, no extra fetch")
        XCTAssertEqual(store.library.value?.shelves.map(\.title), ["Refreshed Albums"],
                       "the refresh that ran behind the snapshot was applied")
    }

    /// Back to A while B's first fetch is still out. The page on screen is B's spinner,
    /// not A's, so A's snapshot paints at once instead of a second spinner.
    func testSwitchingBackWhileTheOtherListenersFetchIsOutStillPaintsTheSnapshot() async throws {
        let (store, service) = makeCollectionsStore()
        service.libraryPage = libraryPage()
        await store.loadLibraryIfNeeded()                       // A

        // A → B, with B's first fetch held open.
        service.listenerKey = "listener-2"
        service.holdLibrary = true
        let bEntered = expectation(description: "B's fetch entered")
        service.libraryEntered = bEntered
        let toB = Task { await store.loadLibraryIfNeeded() }
        await fulfillment(of: [bEntered], timeout: 5)
        defer { service.releaseLibrary() }
        XCTAssertTrue(store.library.isLoading, "B's page is loading")

        // Back to A before B answers.
        service.listenerKey = "listener-1"
        let aEntered = expectation(description: "A's refresh fetch entered")
        service.libraryEntered = aEntered
        let backToA = Task { await store.loadLibraryIfNeeded() }
        await fulfillment(of: [aEntered], timeout: 5)

        let painted = try XCTUnwrap(store.library.value, "A's page is up from the snapshot, not a spinner")
        XCTAssertEqual(painted.shelves.map(\.title), ["Playlists", "Albums", "Subscriptions"])

        service.releaseLibrary()
        await toB.value
        await backToA.value
        XCTAssertEqual(store.library.value?.shelves.map(\.title), ["Playlists", "Albums", "Subscriptions"])
        XCTAssertEqual(service.calls.filter { $0 == "library" }.count, 3, "A, B, and A's refresh")
    }

    /// Signing out drops the snapshots. The listener who signs back in fetches fresh
    /// instead of painting what was on screen before the sign-out.
    func testSigningOutClearsTheSnapshots() async throws {
        let (store, service) = makeCollectionsStore()
        service.libraryPage = libraryPage()
        await store.loadLibraryIfNeeded()                       // A
        service.listenerKey = "listener-2"
        service.libraryPage = LibraryPage(likedSongs: [], librarySongs: [], shelves: [
            HomeShelf(title: "B's shelf", items: [CollectionsFixtures.card("Bcard", "B only")]),
        ])
        await store.loadLibraryIfNeeded()                       // B
        service.listenerKey = "listener-1"
        service.libraryPage = libraryPage()
        await store.loadLibraryIfNeeded()                       // back to A: painted from the snapshot
        XCTAssertEqual(service.calls.filter { $0 == "library" }.count, 3)
        XCTAssertEqual(store.library.value?.shelves.map(\.title), ["Playlists", "Albums", "Subscriptions"])

        // Sign out: the Library screen's task runs against the nil listener.
        service.isSignedIn = false
        service.listenerKey = nil
        await store.loadLibraryIfNeeded()

        // Sign back in as the same listener: no snapshot is left, so the page loads from the fetch.
        service.isSignedIn = true
        service.listenerKey = "listener-1"
        service.holdLibrary = true
        let entered = expectation(description: "the post-sign-out fetch entered")
        service.libraryEntered = entered
        let reload = Task { await store.loadLibraryIfNeeded() }
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertTrue(store.library.isLoading, "the snapshot died with the sign-out")
        service.releaseLibrary()
        await reload.value
        XCTAssertEqual(service.calls.filter { $0 == "library" }.count, 4)
        XCTAssertEqual(store.library.value?.shelves.map(\.title), ["Playlists", "Albums", "Subscriptions"])
    }

    func testAnEmptyLibrarySaysSo() async {
        let (store, _) = makeCollectionsStore()
        await store.loadLibrary()
        XCTAssertEqual(store.library.errorMessage, L10n.libraryEmpty)
    }

    func testTheLibraryRendersSignedInAndSignedOut() async {
        let service = FakeCollectionsService()
        service.libraryPage = libraryPage()
        let (model, store, _) = makeCollectionsTestModel(self, service: service)
        let host = await host(LibraryScreen(), model: model)
        XCTAssertNotNil(store.library.value)
        XCTAssertGreaterThan(host.view.bounds.height, 0)

        let signedOut = FakeCollectionsService()
        signedOut.isSignedIn = false
        let (outModel, outStore, _) = makeCollectionsTestModel(self, service: signedOut)
        _ = await self.host(LibraryScreen(), model: outModel, colorScheme: .light)
        XCTAssertTrue(outStore.library.isLoading)
        XCTAssertFalse(signedOut.calls.contains("library"))
    }

    /// "Show all" reads the shelf live, pins first; the Playlists grid keeps its New playlist tile.
    func testShowAllRendersTheWholeShelf() async {
        await enableAccessibilityTree()
        let service = FakeCollectionsService()
        service.libraryPage = libraryPage()
        let (model, store, _) = makeCollectionsTestModel(self, service: service)
        await store.loadLibrary()
        // "Mine" sits behind "Liked Music" on the shelf; pinned, it leads.
        XCTAssertTrue(model.settings.togglePinnedPlaylist("VLPLmine"))
        let host = await host(LibraryShowAllScreen(browseId: LibraryShelves.keyPrefix + "Playlists", title: "Playlists"), model: model,
                              inScene: true, settle: 0.8)
        await waitUntil("the shelf's cards are on screen") { host.view.renderedLabels.contains { $0.contains("Mine") } }
        let labels = host.view.renderedLabels
        let create = labels.firstIndex { $0.contains(L10n.newPlaylist) }
        let mine = labels.firstIndex { $0.contains("Mine") }
        let liked = labels.firstIndex { $0.contains("Liked Music") }
        XCTAssertNotNil(create, "the New playlist tile is kept: \(labels)")
        XCTAssertNotNil(mine, "\(labels)")
        XCTAssertNotNil(liked, "\(labels)")
        if let create, let mine, let liked {
            XCTAssertLessThan(create, mine, "the New playlist tile leads the grid")
            XCTAssertLessThan(mine, liked, "the pinned playlist comes first")
        }
    }
}

@MainActor
final class LikesAndDislikesTests: XCTestCase {
    /// PORTING.md "Likes and dislikes": clearing the heart takes the song out of Liked Music at
    /// once — the library's list and the open Liked Music page — and out of the library too, since
    /// liking and saving are two flags on YouTube's side.
    func testUnlikingDropsTheSongFromLikedMusicAndTheLibrary() async {
        let (store, service) = makeCollectionsStore()
        let song = CollectionsFixtures.song("liked1", "Liked")
        service.libraryPage = LibraryPage(likedSongs: [song], librarySongs: [], shelves: [HomeShelf(title: "Playlists", items: [])])
        service.songPages[YTMusicRepository.likedMusicBrowseId] = .init(songs: [song, CollectionsFixtures.song("liked2", "Other")], continuation: nil)
        service.menus["liked1"] = SongMenu(likeStatus: .like, inLibrary: true, addToLibraryToken: "add", removeFromLibraryToken: "remove-token")
        await store.loadLibrary()
        await store.openPage(YTMusicRepository.likedMusicBrowseId, seed: nil, type: .playlist)

        await store.ratingChanged("liked1", from: .like, to: .indifferent)
        XCTAssertEqual(store.library.value?.likedSongs.count, 0)
        XCTAssertEqual(store.page(YTMusicRepository.likedMusicBrowseId)?.songs.value?.map(\.videoId), ["liked2"])
        XCTAssertEqual(service.libraryTokens, ["remove-token"])
        XCTAssertTrue(store.libraryStale)
    }

    /// Disliking a song also drops it from Liked Music, but doesn't touch the library save.
    func testDislikingDropsFromLikedMusicOnly() async {
        let (store, service) = makeCollectionsStore()
        let song = CollectionsFixtures.song("liked1", "Liked")
        service.libraryPage = LibraryPage(likedSongs: [song], librarySongs: [], shelves: [HomeShelf(title: "Playlists", items: [])])
        await store.loadLibrary()
        await store.ratingChanged("liked1", from: .like, to: .dislike)
        XCTAssertEqual(store.library.value?.likedSongs.count, 0)
        XCTAssertTrue(service.libraryTokens.isEmpty)
    }

    /// The menu's lookup states a rating the library couldn't know (a dislike); it is remembered.
    /// A watch queue's silence is not read as "not liked".
    func testTheSongMenuRemembersAStatedRatingButNotSilence() async {
        let (store, service) = makeCollectionsStore()
        service.menus["d"] = SongMenu(likeStatus: .dislike, inLibrary: false, addToLibraryToken: nil, removeFromLibraryToken: nil)
        await store.loadSongMenu("d")
        XCTAssertEqual(store.likeState.status(for: "d"), .dislike)

        store.likeState.set(.like, for: "l")
        service.menus["l"] = SongMenu(likeStatus: nil, inLibrary: true, addToLibraryToken: nil, removeFromLibraryToken: nil)
        await store.loadSongMenu("l")
        XCTAssertEqual(store.likeState.status(for: "l"), .like)
    }

    /// Disliking the playing song skips it (the player's rule, reached from the song menu).
    func testDislikingThePlayingSongFromTheMenuSkipsIt() async throws {
        let harness = PlayerHarness(test: self)
        let songs = try ["x1", "x2"].map { try harness.song($0) }
        harness.player.play(songs, startAt: 0)
        await waitUntil("first song current") { harness.player.currentSong?.videoId == "x1" }
        harness.player.toggleDislike(songs[0])
        await waitUntil("skipped to the next") { harness.player.currentSong?.videoId == "x2" }
        XCTAssertEqual(harness.player.likeStatus(of: songs[0]), .dislike)
    }
}

@MainActor
final class PlaylistManagementTests: XCTestCase {
    /// PORTING.md "Playlist management" done criterion: create a playlist, add two songs, rename it;
    /// each step shows on the library card, the picker and the open page.
    func testCreatingAddingTwoSongsAndRenamingShowsEverywhere() async throws {
        let (store, service) = makeCollectionsStore()
        service.libraryPage = LibraryPage(likedSongs: [], librarySongs: [], shelves: [HomeShelf(title: "Albums", items: [CollectionsFixtures.card("MPREb_1", "A")])])
        await store.loadLibrary()

        let first = CollectionsFixtures.song("n1", "First")
        await store.createPlaylist(title: " Road trip ", privacy: .unlisted, songs: [first])
        XCTAssertEqual(service.createdPlaylists.first?.title, "Road trip")
        XCTAssertEqual(service.createdPlaylists.first?.privacy, .unlisted)
        XCTAssertEqual(service.createdPlaylists.first?.videoIds, ["n1"])
        let created = try XCTUnwrap(store.playlists.first)
        XCTAssertEqual(created.browseId, "VLPLnew1")
        XCTAssertNotNil(store.editablePlaylist(created.browseId), "the creator owns it at once")
        // A first playlist: the shelf appears, leading the page.
        XCTAssertEqual(store.library.value?.shelves.first?.title, YTMusicRepository.playlistsShelfTitle)
        XCTAssertEqual(store.library.value?.shelves.first?.items.first?.browseId, "VLPLnew1")

        // Open it, then add two songs (the first is already there and isn't sent again).
        service.songPages["VLPLnew1"] = .init(songs: [first], continuation: nil, owned: true)
        await store.openPage("VLPLnew1", seed: nil, type: .playlist)
        let already = await store.addToPlaylist(created, songs: [first])
        XCTAssertEqual(already, true)
        let result = await store.addToPlaylist(created, songs: [CollectionsFixtures.song("n2", "Second"), CollectionsFixtures.song("n3", "Third")])
        XCTAssertEqual(result, false)
        XCTAssertEqual(service.added.last?.videoIds, ["n2", "n3"])
        XCTAssertEqual(store.page("VLPLnew1")?.songs.value?.map(\.videoId), ["n1", "n2", "n3"])
        XCTAssertEqual(store.page("VLPLnew1")?.songs.value?.last?.setVideoId, "set-n3", "a new row can be removed at once")

        await store.renamePlaylist(created, to: "Summer")
        XCTAssertEqual(service.renamed.last?.title, "Summer")
        XCTAssertEqual(store.playlists.first?.title, "Summer")
        XCTAssertEqual(store.library.value?.shelves.first?.items.first?.title, "Summer")
        XCTAssertEqual(store.page("VLPLnew1")?.title, "Summer")
    }

    /// Removing a row takes it off the page at once; deleting a playlist takes its card, its picker
    /// row and its page away.
    func testRemovingASongAndDeletingAPlaylist() async throws {
        var closed: [String] = []
        let (store, service) = makeCollectionsStore()
        store.closePages = { closed.append($0) }
        let mine = UserPlaylist(playlistId: "PLmine", title: "Mine", subtitle: "", thumbnailUrl: nil)
        service.playlists = [mine]
        service.owned["VLPLmine"] = true
        service.libraryPage = LibraryPage(likedSongs: [], librarySongs: [],
                                          shelves: [HomeShelf(title: "Playlists", items: [CollectionsFixtures.card("VLPLmine", "Mine")])])
        service.songPages[CollectionsFixtures.playlistId] = .init(songs: CollectionsFixtures.playlistSongs, continuation: nil, owned: true)
        await store.loadLibrary()
        await store.loadPlaylists()
        await store.openPage(CollectionsFixtures.playlistId, seed: nil, type: .playlist)
        XCTAssertNotNil(store.editablePlaylist(CollectionsFixtures.playlistId))

        await store.removeFromPlaylist(CollectionsFixtures.playlistId, song: CollectionsFixtures.playlistSongs[1])
        XCTAssertEqual(service.removed.first?.entries, [PlaylistEntryRef(setVideoId: "s2", videoId: "p2")])
        XCTAssertEqual(store.page(CollectionsFixtures.playlistId)?.songs.value?.map(\.videoId), ["p1", "p3"])

        await store.deletePlaylist(mine)
        XCTAssertEqual(service.deleted, ["PLmine"])
        XCTAssertTrue(store.playlists.isEmpty)
        XCTAssertNil(store.library.value?.shelves.first { $0.title == "Playlists" }, "an emptied shelf goes; the create tile stays")
        XCTAssertNil(store.page(CollectionsFixtures.playlistId))
        XCTAssertEqual(closed, [CollectionsFixtures.playlistId])
    }

    /// Adding a suggestion moves it from Suggested into the track list.
    func testAddingASuggestedSongMovesItIntoThePlaylist() async {
        let (store, service) = makeCollectionsStore()
        let suggestion = CollectionsFixtures.song("sg", "Suggested")
        service.songPages[CollectionsFixtures.playlistId] = .init(songs: CollectionsFixtures.playlistSongs, continuation: nil, suggested: [suggestion])
        await store.openPage(CollectionsFixtures.playlistId, seed: nil, type: .playlist)
        await store.addSuggestedSong(CollectionsFixtures.playlistId, song: suggestion)
        XCTAssertEqual(service.added.first?.playlistId, "PLmine")
        XCTAssertTrue(store.page(CollectionsFixtures.playlistId)?.suggestedSongs.isEmpty ?? false)
        XCTAssertEqual(store.page(CollectionsFixtures.playlistId)?.songs.value?.last?.videoId, "sg")
    }

    /// Only a playlist confirmed as the account's own is editable; a saved stranger's is not.
    func testOnlyTheAccountsOwnPlaylistsAreEditable() async {
        let (store, service) = makeCollectionsStore()
        service.playlists = [UserPlaylist(playlistId: "PLtheirs", title: "Theirs", subtitle: "", thumbnailUrl: nil)]
        service.owned["VLPLtheirs"] = false
        await store.loadPlaylists()
        XCTAssertNil(store.editablePlaylist("VLPLtheirs"), "unknown is not yes")
        await store.resolvePlaylistOwnership("VLPLtheirs")
        XCTAssertNil(store.editablePlaylist("VLPLtheirs"))
        XCTAssertEqual(store.playlistOwned["VLPLtheirs"], false)
        await store.resolvePlaylistOwnership("VLPLnotInLibrary")
        XCTAssertFalse(service.calls.contains("owned:VLPLnotInLibrary"))
    }

    /// The playlists and who made them belong to the listener they were fetched for: after a switch,
    /// the last listener's playlist is neither editable nor listed, and its ownership is asked again.
    func testAnotherListenersPlaylistsAreNotEditableAfterASwitch() async {
        let (store, service) = makeCollectionsStore()
        service.playlists = [UserPlaylist(playlistId: "PLmine", title: "Mine", subtitle: "", thumbnailUrl: nil)]
        service.owned["VLPLmine"] = true
        await store.loadPlaylists()
        await store.resolvePlaylistOwnership("VLPLmine")
        XCTAssertNotNil(store.editablePlaylist("VLPLmine"))

        service.listenerKey = "listener-2"
        XCTAssertNil(store.editablePlaylist("VLPLmine"), "listener 1's verdict is not listener 2's")
        service.playlists = [UserPlaylist(playlistId: "PLtheirs", title: "Theirs", subtitle: "", thumbnailUrl: nil)]
        await store.loadPlaylistsIfNeeded()
        XCTAssertEqual(store.playlists.map(\.playlistId), ["PLtheirs"], "listener 1's list is not kept as listener 2's")

        service.playlists.append(UserPlaylist(playlistId: "PLmine", title: "Mine", subtitle: "", thumbnailUrl: nil))
        service.owned["VLPLmine"] = false
        await store.loadPlaylists()
        await store.resolvePlaylistOwnership("VLPLmine")
        XCTAssertEqual(service.calls.filter { $0 == "owned:VLPLmine" }.count, 2, "asked again for the new listener")
        XCTAssertNil(store.editablePlaylist("VLPLmine"))
    }

    /// A → B → A while A's first load is still out: that older answer must not replace the newer
    /// load's playlists once it finally arrives.
    func testAnOlderPlaylistLoadDoesNotOverwriteANewerOneAfterSwitchingBack() async {
        let (store, service) = makeCollectionsStore()
        func playlist(_ id: String) -> UserPlaylist { UserPlaylist(playlistId: id, title: id, subtitle: "", thumbnailUrl: nil) }

        service.playlists = [playlist("PLold")]
        service.holdNextPlaylists = true
        let entered = expectation(description: "A's first load is out")
        service.playlistsEntered = entered
        let first = Task { await store.loadPlaylists() }
        await fulfillment(of: [entered], timeout: 5)
        defer { service.releasePlaylists() }

        service.listenerKey = "listener-2"
        service.playlists = [playlist("PLb")]
        await store.loadPlaylists()
        service.listenerKey = "listener-1"
        service.playlists = [playlist("PLnew")]
        await store.loadPlaylists()
        XCTAssertEqual(store.playlists.map(\.playlistId), ["PLnew"])

        service.releasePlaylists()
        await first.value
        XCTAssertEqual(store.playlists.map(\.playlistId), ["PLnew"], "the older load's answer is dropped")
    }

    /// Pinning is on the device only, in pin order, and refused past five rather than evicting.
    func testPinningIsCappedAtFive() {
        let settings = makeTestSettings()
        for index in 1...5 { XCTAssertTrue(settings.togglePinnedPlaylist("VL\(index)")) }
        XCTAssertFalse(settings.togglePinnedPlaylist("VL6"))
        XCTAssertEqual(settings.pinnedPlaylists, ["VL1", "VL2", "VL3", "VL4", "VL5"])
        XCTAssertFalse(settings.togglePinnedPlaylist("VL1"))
        XCTAssertEqual(settings.pinnedPlaylists.first, "VL2")
    }

    func testThePickerRendersTheListAndTheForm() async {
        let service = FakeCollectionsService()
        service.playlists = [UserPlaylist(playlistId: "PL1", title: "One", subtitle: "3 songs", thumbnailUrl: nil)]
        let (model, store, _) = makeCollectionsTestModel(self, service: service)
        let picker = await host(PlaylistPickerSheet(songs: [CollectionsFixtures.song("x", "X")]), model: model, inNavigation: false)
        XCTAssertEqual(store.playlists.count, 1)
        XCTAssertGreaterThan(picker.view.bounds.height, 0)
        let form = await self.host(PlaylistPickerSheet(songs: []), model: model, colorScheme: .light, inNavigation: false)
        XCTAssertGreaterThan(form.view.bounds.height, 0)
    }
}

@MainActor
final class MultiPlaylistAddTests: XCTestCase {
    private func playlist(_ id: String, _ title: String) -> UserPlaylist {
        UserPlaylist(playlistId: id, title: title, subtitle: "", thumbnailUrl: nil)
    }

    /// PORTING.md "Playlist management" done criterion: one tap adds a song to every ticked
    /// playlist. Three ticked rows — one already has it, one refuses — go out one at a time, in the
    /// picker's order, and the duplicate is never sent.
    func testABatchAddsToEachTickedPlaylistInOrderSkippingADuplicate() async throws {
        let service = FakeCollectionsService()
        let (store, _) = makeCollectionsStore(service)
        let song = CollectionsFixtures.song("x", "X")
        let hasIt = playlist("PLhas", "Has it")
        let open = playlist("PLopen", "Open")
        let refuses = playlist("PLrefuses", "Refuses")
        service.allSongsById[hasIt.browseId] = [song]
        service.addFailures = [refuses.playlistId]

        let summary = await store.addToPlaylists([hasIt, open, refuses], songs: [song])
        let result = try XCTUnwrap(summary)

        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.alreadyThere, 1)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(service.calls.filter { $0.hasPrefix("add:") }, ["add:PLopen", "add:PLrefuses"],
                       "in the order they were ticked, and the playlist that already has the song is never sent")
        XCTAssertEqual(service.added.map { $0.playlistId }, ["PLopen"])
    }

    /// The batch leaves one notice, naming the outcome that matters most: what went in, else that
    /// it was all there already, else that it didn't work (MainActivity's `onAdd`).
    func testTheBatchNoticeSaysWhatHappenedToTheMostPlaylists() {
        XCTAssertEqual(PlaylistBatchNotice.text(added: 2, alreadyThere: 0, failed: 1), "Added to 2 playlists")
        XCTAssertEqual(PlaylistBatchNotice.text(added: 1, alreadyThere: 1, failed: 1), "Added to playlist")
        XCTAssertEqual(PlaylistBatchNotice.text(added: 0, alreadyThere: 2, failed: 0), "Already in playlist")
        XCTAssertEqual(PlaylistBatchNotice.text(added: 0, alreadyThere: 1, failed: 1), "Failed")
        XCTAssertEqual(PlaylistBatchNotice.text(added: 0, alreadyThere: 0, failed: 3), "Failed")
    }

    /// The sheet's button counts the ticks and stays off until there is one; the ticks are the
    /// rows' ids, so a refreshed list keeps them.
    func testThePickerButtonCountsTheTicksAndIsOffUntilOneIsTicked() {
        var selection = PlaylistPickerSelection()
        XCTAssertEqual(selection.buttonTitle, "Add to playlist")
        XCTAssertTrue(selection.isEmpty, "nothing ticked: the button is disabled")

        selection.toggle("PL1")
        selection.toggle("PL2")
        XCTAssertEqual(selection.buttonTitle, "Add to 2 playlists")
        XCTAssertFalse(selection.isEmpty)
        XCTAssertEqual(selection.picked(from: [playlist("PL2", "Two"), playlist("PL1", "One")]).map(\.playlistId),
                       ["PL2", "PL1"], "the list's order, not the ticks'")

        selection.toggle("PL1")
        XCTAssertEqual(selection.buttonTitle, "Add to 1 playlist")
        selection.toggle("PL2")
        XCTAssertEqual(selection.buttonTitle, "Add to playlist")
        XCTAssertTrue(selection.isEmpty)
    }

    /// A row toggles its tick in place: the sheet stays up, and only the button closes it.
    func testTappingAPlaylistRowTicksItWithoutClosingTheSheet() async throws {
        await enableAccessibilityTree()
        let service = FakeCollectionsService()
        service.playlists = [playlist("PL1", "One"), playlist("PL2", "Two")]
        let (model, _, _) = makeCollectionsTestModel(self, service: service)
        let songs = [CollectionsFixtures.song("x", "X")]
        model.router.present(.playlistPicker(songs))
        let host = await host(PlaylistPickerSheet(songs: songs), model: model, inNavigation: false,
                              inScene: true, settle: 0.8)
        let screen = { host.view.renderedLabels }

        let buttonControl = await host.view.control(identifier: "picker.add", label: "Add to playlist")
        let button = try XCTUnwrap(buttonControl, "the button is not on screen: \(screen())")
        XCTAssertTrue(button.accessibilityTraits.contains(.notEnabled), "nothing is ticked: the button is off")

        let rowControl = await host.view.control(identifier: "picker.playlist", label: "One")
        let row = try XCTUnwrap(rowControl, "the row is not on screen: \(screen())")
        XCTAssertTrue(row.accessibilityActivate(), "the row took no tap")
        let tickedControl = await host.view.control(identifier: "picker.playlist", label: "One")
        let ticked = try XCTUnwrap(tickedControl, "the row left the screen: \(screen())")
        XCTAssertTrue(ticked.accessibilityTraits.contains(.selected), "the row shows its tick: \(screen())")
        XCTAssertNotNil(model.router.sheet, "a tick is not a choice: the sheet has to stay up")

        let countedControl = await host.view.control(identifier: "picker.add", label: "Add to 1 playlist")
        let add = try XCTUnwrap(countedControl, "the button does not count the tick: \(screen())")
        XCTAssertFalse(add.accessibilityTraits.contains(.notEnabled), "one is ticked: the button is on")
        XCTAssertTrue(add.accessibilityActivate(), "the button took no tap")
        await waitUntil("the button closes the sheet") { model.router.sheet == nil }
        XCTAssertNil(model.router.sheet, "the button is what closes the sheet")
    }
}

private extension UIView {
    /// The controls under this view that speak `label` and carry `identifier` — what a tap from a
    /// VoiceOver user lands on, never a plain view — then those that only speak the one or only
    /// carry the other. The sheet's heading reads "Add to playlist" too, so a match is a button.
    func accessibleControls(identifier: String, label: String) -> [NSObject] {
        var both: [NSObject] = []
        var named: [NSObject] = []
        var identified: [NSObject] = []
        func walk(_ element: Any) {
            if let object = element as? NSObject {
                let isButton = object.accessibilityTraits.contains(.button)
                if !(object is UIView) {
                    let name = object.accessibilityLabel
                    let id = (object as? UIAccessibilityIdentification)?.accessibilityIdentifier
                    let speaks = name == label || name?.hasPrefix(label + ",") == true
                    if isButton && speaks && id == identifier {
                        both.append(object)
                    } else if isButton && speaks {
                        named.append(object)
                    } else if id == identifier {
                        identified.append(object)
                    }
                }
                for child in object.accessibilityElements ?? [] { walk(child) }
            }
            if let view = element as? UIView {
                for child in view.subviews { walk(child) }
            }
        }
        walk(self)
        return both + named + identified
    }

    /// The first accessibility element whose label contains `text`, for a row that is tapped
    /// rather than a button.
    func element(labelContaining text: String) -> NSObject? {
        func walk(_ element: Any) -> NSObject? {
            if let object = element as? NSObject {
                if !(object is UIView), let label = object.accessibilityLabel, label.contains(text) { return object }
                for child in object.accessibilityElements ?? [] { if let found = walk(child) { return found } }
            }
            if let view = element as? UIView {
                for child in view.subviews { if let found = walk(child) { return found } }
            }
            return nil
        }
        return walk(self)
    }

    /// Waits for SwiftUI's accessibility tree — it builds it after the first layout, and rebuilds
    /// it after a state change — then returns the first control for `identifier`/`label`.
    func control(identifier: String, label: String, timeout: TimeInterval = 5) async -> NSObject? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let found = accessibleControls(identifier: identifier, label: label).first { return found }
            try? await Task.sleep(for: .milliseconds(50))
        } while Date() < deadline
        return nil
    }
}

@MainActor
final class HistoryTests: XCTestCase {
    /// PORTING.md "History": the account's history, most recent first; tapping a row plays from
    /// that point with the rest of the history behind it.
    func testTheHistoryLoadsAndTappingARowPlaysFromThere() async throws {
        await enableAccessibilityTree()
        let service = FakeCollectionsService()
        let (model, store, _) = makeCollectionsTestModel(self, service: service)
        let harness = PlayerHarness(test: self)
        // The service hands back the account's order, newest first; the screen shows it as it comes.
        service.historySongs = try ["h3", "h2", "h1"].map { try harness.song($0) }
        let host = await host(HistoryScreen(), model: model, player: harness.player, inScene: true, settle: 0.8)
        let songs = try XCTUnwrap(store.history.value)
        XCTAssertEqual(songs.map(\.videoId), ["h3", "h2", "h1"])

        // The second row, tapped the way a VoiceOver user taps it.
        let title = songs[1].title
        await waitUntil("the history rows are on screen") { host.view.renderedLabels.contains { $0.contains(title) } }
        let row = try XCTUnwrap(host.view.element(labelContaining: title), "no row for \(title): \(host.view.renderedLabels)")
        XCTAssertTrue(row.accessibilityActivate(), "the row took no tap")
        XCTAssertEqual(harness.player.currentSong?.videoId, "h2")
        XCTAssertEqual(harness.player.songs.map(\.videoId), ["h3", "h2", "h1"], "the rest of the history is behind it")
        XCTAssertEqual(harness.player.playingFromSource?.type, .history)
    }

    func testSignedOutOrEmptyHistorySaysSo() async {
        let service = FakeCollectionsService()
        service.isSignedIn = false
        let (store, _) = makeCollectionsStore(service)
        await store.loadHistory()
        XCTAssertEqual(store.history.errorMessage, L10n.historySignInRequired)
        service.isSignedIn = true
        await store.loadHistory()
        XCTAssertEqual(store.history.errorMessage, L10n.historyEmpty)
    }

    func testTheHistoryRenders() async {
        let service = FakeCollectionsService()
        service.historySongs = [CollectionsFixtures.song("h1", "One")]
        let (model, store, _) = makeCollectionsTestModel(self, service: service)
        let host = await host(HistoryScreen(), model: model)
        XCTAssertEqual(store.history.value?.count, 1)
        XCTAssertGreaterThan(host.view.bounds.height, 0)
    }
}

@MainActor
final class SongActionsMenuTests: XCTestCase {
    /// PORTING.md "Song actions menu" done criterion: every row works on a song from Search. Each
    /// row is tapped the way a VoiceOver user taps it, and its action reaches the player, the
    /// queue, the downloads or the pages.
    func testEveryRowWorksOnASongFromSearch() async throws {
        await enableAccessibilityTree()
        let service = FakeCollectionsService()
        var song = CollectionsFixtures.song("search1", "Instant Crush")
        song.albumId = "MPREb_ram"
        let (model, store, _) = makeCollectionsTestModel(self, service: service)
        var enqueued: [[Song]] = []
        store.enqueueDownloads = { songs, _ in enqueued.append(songs) }

        let host = await host(SongActionsSheet(song: song), model: model, inNavigation: false, inScene: true, settle: 0.8)
        XCTAssertTrue(service.calls.contains("menu:search1"), "the menu refreshes the rating as it opens")
        func tap(_ identifier: String, _ label: String) async throws {
            let found = await host.view.control(identifier: identifier, label: label)
            let row = try XCTUnwrap(found, "the \(label) row is not on screen: \(host.view.renderedLabels)")
            XCTAssertTrue(row.accessibilityActivate(), "the \(label) row took no tap")
        }

        // Like: the player's rating, which the sheet shows in place.
        try await tap("songActions.like", L10n.like)
        await waitUntil("the song is liked") { model.player.likeStatus(of: song) == .like }
        // Download.
        try await tap("songActions.download", L10n.download)
        XCTAssertEqual(enqueued.first?.map(\.videoId), ["search1"])
        // Play next / add to queue go through the player's queue.
        try await tap("songActions.playNext", L10n.playNext)
        XCTAssertEqual(model.player.notice?.message, L10n.songWillPlayNext)
        try await tap("songActions.addToQueue", L10n.addToQueue)
        XCTAssertEqual(model.player.notice?.message, L10n.songAddedToQueue)
        // Open album / artist route to their pages.
        try await tap("songActions.openAlbum", L10n.openAlbum)
        try await tap("songActions.openArtist", L10n.openArtist)
        XCTAssertEqual(model.router.path(for: model.router.selectedTab).map(\.browseId), ["MPREb_ram", "UCartist"])
        // Share builds the track's link; the row is a ShareLink, which a test cannot tap.
        XCTAssertEqual(DetailText.shareURL(videoId: song.videoId)?.absoluteString, "https://music.youtube.com/watch?v=search1")
    }

    /// "Remove from this playlist" appears only on an editable playlist page for a row with an
    /// entry id — checked through the sheet's own rule.
    func testRemoveFromPlaylistIsOfferedOnlyOnTheAccountsOwnPlaylist() async {
        let service = FakeCollectionsService()
        service.playlists = [UserPlaylist(playlistId: "PLmine", title: "Mine", subtitle: "", thumbnailUrl: nil)]
        service.owned["VLPLmine"] = true
        let (_, store, _) = makeCollectionsTestModel(self, service: service)
        await store.loadPlaylists()
        await store.resolvePlaylistOwnership("VLPLmine")
        XCTAssertNotNil(store.editablePlaylist("VLPLmine"))
        XCTAssertNil(store.editablePlaylist("VLPLother"))
    }

    /// The sleep timer picker's rows arm and cancel the timer.
    func testTheSleepTimerPickerArmsAndCancels() async throws {
        await enableAccessibilityTree()
        let (model, _, _) = makeCollectionsTestModel(self)
        let host = await host(SleepTimerPicker(accent: .red, divider: .gray) {}, model: model, inNavigation: false,
                              inScene: true, settle: 0.8)
        func tap(_ identifier: String, _ label: String) async throws {
            let found = await host.view.control(identifier: identifier, label: label)
            let row = try XCTUnwrap(found, "the \(label) row is not on screen: \(host.view.renderedLabels)")
            XCTAssertTrue(row.accessibilityActivate(), "the \(label) row took no tap")
        }

        try await tap("sleepTimer.afterThisSong", L10n.afterThisSong)
        XCTAssertEqual(model.player.sleepTimer?.afterTrack, true)
        try await tap("sleepTimer.off", L10n.turnOffTimer)
        XCTAssertNil(model.player.sleepTimer)
    }
}

@MainActor
final class BrowseActionsMenuTests: XCTestCase {
    /// PORTING.md "Album and playlist actions menu" done criterion: "Download all" on an album saves
    /// every track — filed under the album, each row stamped with the album's name and cover.
    func testDownloadAllOnAnAlbumCardQueuesEveryTrack() async throws {
        let (store, service) = makeCollectionsStore()
        service.allSongsById["MPREb_card"] = CollectionsFixtures.albumSongs
        var batches: [([Song], DownloadTarget?)] = []
        store.enqueueDownloads = { batches.append(($0, $1)) }
        let card = BrowseItem(browseId: "MPREb_card", title: "Discovery", subtitle: "Daft Punk", thumbnailUrl: "https://x/cover.jpg", type: .album)

        let tracks = try await store.songs(for: card, known: []).get()
        store.downloadAll(tracks, item: card)
        let batch = try XCTUnwrap(batches.first)
        XCTAssertEqual(batch.0.map(\.videoId), CollectionsFixtures.albumSongs.map(\.videoId))
        XCTAssertTrue(batch.0.allSatisfy { $0.albumName == "Discovery" && $0.thumbnailUrl == "https://x/cover.jpg" })
        XCTAssertTrue(batch.0.allSatisfy { $0.playbackSourceType == .browse && $0.playbackSourceId == "MPREb_card" })
        XCTAssertEqual(batch.1?.id, "MPREb_card")
        XCTAssertEqual(batch.1?.playlist, false)
    }

    /// Queue rows work from a card whose page was never opened (the listing is fetched), and a card
    /// with nothing behind it says so.
    func testQueueRowsFetchTheListingForACard() async throws {
        let (store, service) = makeCollectionsStore()
        service.allSongsById["VLPLcard"] = CollectionsFixtures.playlistSongs
        let card = BrowseItem(browseId: "VLPLcard", title: "Mix", subtitle: "", thumbnailUrl: nil, type: .playlist)
        let songs = try await store.songs(for: card, known: []).get()
        XCTAssertEqual(songs.map(\.videoId), ["p1", "p2", "p3"])
        XCTAssertTrue(songs.allSatisfy { $0.albumName == nil })

        let harness = PlayerHarness(test: self)
        harness.player.addToQueue(songs)
        XCTAssertEqual(harness.player.songs.count, 3)

        let empty = await store.songs(for: BrowseItem(browseId: "VLPLnothing", title: "", subtitle: "", thumbnailUrl: nil, type: .playlist), known: [])
        if case .success = empty { XCTFail("an empty listing is an error") }
    }

    /// The page's own overflow hands the sheet its rows (no Play/Shuffle/Open); a card does not.
    func testTheSheetFromThePageUsesThePagesRows() async throws {
        await enableAccessibilityTree()
        let service = FakeCollectionsService()
        let (model, store, _) = makeCollectionsTestModel(self, service: service)
        let item = BrowseItem(browseId: CollectionsFixtures.albumId, title: "Discovery", subtitle: "", thumbnailUrl: nil, type: .album)
        store.pageMenuContext = (CollectionsFixtures.albumId, CollectionsFixtures.albumSongs)
        let page = await host(BrowseActionsSheet(item: item), model: model, inNavigation: false, inScene: true, settle: 0.8)
        let queueRow = await page.view.control(identifier: "browseActions.playNext", label: L10n.playNext)
        XCTAssertNotNil(queueRow, "the page's sheet drew no rows: \(page.view.renderedLabels)")
        func draws(_ host: UIHostingController<AnyView>, _ identifier: String, _ label: String) -> Bool {
            !host.view.accessibleControls(identifier: identifier, label: label).isEmpty
        }
        let openLabel = DetailText.openLabel(of: .album)
        XCTAssertTrue(draws(page, "browseActions.downloadAll", L10n.downloadAll), "\(page.view.renderedLabels)")
        XCTAssertFalse(draws(page, "browseActions.play", L10n.play), "the page has Play beside the menu already")
        XCTAssertFalse(draws(page, "browseActions.shuffle", L10n.shuffle), "the page has Shuffle beside the menu already")
        XCTAssertFalse(draws(page, "browseActions.open", openLabel), "the page is already open")

        let cardItem = BrowseItem(browseId: "VLPLx", title: "X", subtitle: "", thumbnailUrl: nil, type: .playlist)
        let card = await self.host(BrowseActionsSheet(item: cardItem), model: model, colorScheme: .light, inNavigation: false,
                                   inScene: true, settle: 0.8)
        let cardQueueRow = await card.view.control(identifier: "browseActions.playNext", label: L10n.playNext)
        XCTAssertNotNil(cardQueueRow, "the card's sheet drew no rows: \(card.view.renderedLabels)")
        XCTAssertTrue(draws(card, "browseActions.play", L10n.play), "\(card.view.renderedLabels)")
        XCTAssertTrue(draws(card, "browseActions.shuffle", L10n.shuffle), "\(card.view.renderedLabels)")
        XCTAssertTrue(draws(card, "browseActions.open", DetailText.openLabel(of: .playlist)), "\(card.view.renderedLabels)")
    }
}

/// The bar takes the page's title only once the header's own title has scrolled under it
/// (MainActivity's `detailScrolled`), and gives it back on the way up.
@MainActor
final class DetailScrollTitleTests: XCTestCase {
    private func all(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(all) }

    private func check(_ screen: some View, model: AppModel, title: String) async throws {
        let host = await host(screen, model: model, settle: 1)
        let scroll = try XCTUnwrap(all(host.view).compactMap { $0 as? UIScrollView }.max { $0.contentSize.height < $1.contentSize.height })
        // A root page with no title and nothing in its bar may have no bar drawn at all yet.
        func barTitle() -> String { all(host.view).compactMap { $0 as? UINavigationBar }.first?.topItem?.title ?? "" }
        XCTAssertEqual(barTitle(), "", "the header shows the title at the top of the page")
        scroll.setContentOffset(CGPoint(x: 0, y: 1500), animated: false)
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .seconds(0.6))
        XCTAssertEqual(barTitle(), title)
        scroll.setContentOffset(.zero, animated: false)
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .seconds(0.6))
        XCTAssertEqual(barTitle(), "")
    }

    func testTheAlbumBarTakesTheTitleOnceTheHeaderScrollsAway() async throws {
        let service = FakeCollectionsService()
        var page = CollectionsFixtures.albumPage
        page.songs = (1...40).map { CollectionsFixtures.song("x\($0)", "Song \($0)") }
        service.songPages[CollectionsFixtures.albumId] = page
        let (model, _, _) = makeCollectionsTestModel(self, service: service)
        try await check(AlbumPlaylistScreen(browseId: CollectionsFixtures.albumId, seed: nil), model: model, title: "Discovery")
    }

    func testTheArtistBarTakesTheNameOnceTheHeaderScrollsAway() async throws {
        let service = FakeCollectionsService()
        service.artistPages[CollectionsFixtures.artistId] = CollectionsFixtures.artistPage
        let (model, _, _) = makeCollectionsTestModel(self, service: service)
        try await check(ArtistScreen(browseId: CollectionsFixtures.artistId, seed: nil), model: model, title: "Daft Punk")
    }
}
