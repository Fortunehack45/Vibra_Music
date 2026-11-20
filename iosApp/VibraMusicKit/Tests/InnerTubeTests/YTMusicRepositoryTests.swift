import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import InnerTube

/// The repository over a stubbed network: which requests each screen's call makes, how pages are
/// joined and paged, and how a rejected session is retried.
@MainActor
final class YTMusicRepositoryTests: XCTestCase {
    private var stub: InnerTubeStub!
    private var likeState: LikeState!
    private var repository: YTMusicRepository!
    private var client: InnerTubeClient!

    override func setUp() async throws {
        stub = InnerTubeStub()
        likeState = LikeState()
        client = stub.makeClient()
        repository = YTMusicRepository(client: client, likeState: likeState)
    }

    private func signIn() async throws {
        stub.stub.register(host: "music.youtube.com", path: "/", response: .text(try Fixtures.text("signed_in/music_shell_signed_in_personal.html")))
        await client.setCookie("SID=1; SAPISID=secret")
    }

    private func browseIds() -> [String?] {
        stub.requests(to: "browse").map { InnerTubeStub.bodyField("browseId", of: $0) ?? InnerTubeStub.bodyField("continuation", of: $0) }
    }

    /// Answers `browse` for `browseId` with the given params (nil = none sent).
    private func onBrowse(_ browseId: String, params: String?, body: String) {
        stub.stub.register(matching: { request in
            request.url?.path() == "/youtubei/v1/browse"
                && InnerTubeStub.bodyField("browseId", of: request) == browseId
                && InnerTubeStub.bodyField("params", of: request) == params
        }) { _ in .json(body) }
    }

    // MARK: - Home

    func testHomeIsTheCoreFeedWithItsContinuation() async throws {
        try stub.onBrowse("FEmusic_home", fixture: "home.json")
        let feed = try await repository.home()
        XCTAssertEqual(feed.shelves.count, 2)
        XCTAssertNotNil(feed.continuation)
        try stub.onContinuation(try XCTUnwrap(feed.continuation), fixture: "home_continuation.json")
        let more = try await repository.moreHome(token: try XCTUnwrap(feed.continuation))
        XCTAssertTrue(more.shelves.isEmpty)
        XCTAssertNil(more.continuation)
    }

    func testRecentlyPlayedIsNothingSignedOutAndAsksNothing() async throws {
        let shelf = try await repository.homeRecentlyPlayed()
        XCTAssertNil(shelf)
        XCTAssertTrue(stub.stub.requests.isEmpty)
    }

    func testRecentlyPlayedIsTheHistoryFeedNewestFirst() async throws {
        try await signIn()
        try stub.onBrowse("FEmusic_history", fixture: "signed_in/history.json")
        let recent = try await repository.homeRecentlyPlayed()
        let shelf = try XCTUnwrap(recent)
        XCTAssertEqual(shelf.title, "Recents")
        XCTAssertEqual(shelf.items.count, 6)
        XCTAssertEqual(shelf.items.first?.videoId, "H9gERrxL78U")
        XCTAssertEqual(shelf.items.first?.subtitle, "Daft Punk")
        XCTAssertNil(shelf.items.first?.browseId)
        let history = try await repository.history()
        XCTAssertEqual(history.map(\.videoId), shelf.items.compactMap(\.videoId))
        let recents = try await repository.recents()
        XCTAssertEqual(recents.count, 6)
    }

    func testRecentlyPlayedStopsAtTwentyAndAFailedHistoryIsNoShelf() async throws {
        try await signIn()
        let rows = (0..<30).map { i in
            #"{"musicResponsiveListItemRenderer":{"playlistItemData":{"videoId":"vid\#(String(format: "%08d", i))"},"flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Song \#(i)"}]}}}]}}"#
        }.joined(separator: ",")
        onBrowse("FEmusic_history", params: nil, body: #"{"contents":[\#(rows)]}"#)
        let recent = try await repository.homeRecentlyPlayed()
        let shelf = try XCTUnwrap(recent)
        XCTAssertEqual(shelf.items.count, 20)

        stub.stub.register(host: "music.youtube.com", path: "/youtubei/v1/browse", response: .status(500))
        let none = try await repository.homeRecentlyPlayed()
        XCTAssertNil(none)
    }

    func testSupplementsAreTheirOwnBrowseIds() async throws {
        XCTAssertEqual(YTMusicRepository.homeSupplementBrowseIds, ["FEmusic_new_releases", "FEmusic_explore"])
        try stub.onBrowse("FEmusic_new_releases", fixture: "new_releases.json")
        let shelves = try await repository.homeSupplement(browseId: "FEmusic_new_releases")
        XCTAssertEqual(shelves.map(\.title), ["Albums & singles"])
    }

    func testQuickPicksPreferTheQuickPicksShelfAndSkipExcludedTracks() async throws {
        onBrowse("FEmusic_home", params: nil, body: Self.home(shelves: [
            ("Listen again", ["aaaaaaaaaaa", "bbbbbbbbbbb"]),
            ("Quick picks", ["ccccccccccc", "ddddddddddd"]),
        ]))
        let picks = try await repository.quickPicks(excluding: ["ccccccccccc"])
        XCTAssertEqual(picks.map(\.videoId), ["ddddddddddd"])
        XCTAssertEqual(picks.first?.artist, "Chelsea Wolfe", "the card's 'Song • Chelsea Wolfe' line becomes a credit")
    }

    func testQuickPicksFallBackThroughHomeAndNewReleases() async throws {
        onBrowse("FEmusic_home", params: nil, body: Self.home(shelves: [
            ("Listen again", ["aaaaaaaaaaa"]),
            ("From your library", ["bbbbbbbbbbb", "aaaaaaaaaaa"]),
        ]))
        // No quick-picks shelf: every shelf but the first and anything history-flavoured.
        let picks = try await repository.quickPicks(excluding: [])
        XCTAssertEqual(picks.map(\.videoId), ["bbbbbbbbbbb", "aaaaaaaaaaa"])

        // All of it excluded: New releases, then whatever Home had.
        onBrowse("FEmusic_new_releases", params: nil, body: Self.home(shelves: [("New", ["eeeeeeeeeee"])]))
        let fromReleases = try await repository.quickPicks(excluding: ["aaaaaaaaaaa", "bbbbbbbbbbb"])
        XCTAssertEqual(fromReleases.map(\.videoId), ["eeeeeeeeeee"])
        let lastResort = try await repository.quickPicks(excluding: ["aaaaaaaaaaa", "bbbbbbbbbbb", "eeeeeeeeeee"])
        XCTAssertEqual(lastResort.map(\.videoId), ["aaaaaaaaaaa", "bbbbbbbbbbb"])
    }

    // MARK: - Explore

    func testMoodCategoryShelvesAreCachedPerBrowseIdAndParams() async throws {
        try stub.onBrowse("FEmusic_moods_and_genres", fixture: "moods_and_genres.json")
        let sections = try await repository.moodAndGenres()
        let chill = try XCTUnwrap(sections.first?.items.first)
        onBrowse(chill.browseId, params: chill.params, body: try Fixtures.text("mood_chill.json"))
        let shelves = try await repository.moodGenreShelves(browseId: chill.browseId, params: chill.params)
        XCTAssertEqual(shelves.count, 13)
        let artwork = try await repository.moodGenreArtwork(browseId: chill.browseId, params: chill.params)
        XCTAssertEqual(artwork, shelves.first?.items.first?.thumbnailUrl)
        XCTAssertEqual(stub.requests(to: "browse").count, 2, "the category was fetched once")
        XCTAssertEqual(InnerTubeStub.bodyField("params", of: stub.requests(to: "browse")[1]), "ggMPOg1uX1JOQWZFeDByc2Jm")

        // Another category under the same browse id is its own entry, not the cached one.
        onBrowse(chill.browseId, params: "OTHER_CATEGORY", body: Self.home(shelves: [("Elsewhere", ["eeeeeeeeeee"])]))
        let other = try await repository.moodGenreShelves(browseId: chill.browseId, params: "OTHER_CATEGORY")
        XCTAssertEqual(other.map(\.title), ["Elsewhere"])
        XCTAssertEqual(stub.requests(to: "browse").count, 3)
    }

    // MARK: - Search

    func testEachFilterSendsItsParamsAndVideosOnlyAppearUnderVideos() async throws {
        stub.stub.register(matching: { request in
            request.url?.path() == "/youtubei/v1/search" && InnerTubeStub.bodyField("params", of: request) == SearchFilter.videos.params
        }) { _ in .json(try Fixtures.text("search_videos.json")) }
        stub.stub.register(matching: { request in
            request.url?.path() == "/youtubei/v1/search" && InnerTubeStub.bodyField("params", of: request) == SearchFilter.songs.params
        }) { _ in .json(try Fixtures.text("search_songs.json")) }

        let songs = try await repository.searchPage(query: "daft punk", filter: .songs)
        XCTAssertEqual(songs.rows.count, 20)
        XCTAssertTrue(songs.rows.compactMap(\.trackSong).allSatisfy { !$0.isVideo }, "no video under Songs")
        let videos = try await repository.searchPage(query: "daft punk", filter: .videos)
        XCTAssertTrue(videos.rows.compactMap(\.trackSong).allSatisfy(\.isVideo))
        XCTAssertFalse(videos.rows.isEmpty)
        XCTAssertEqual(stub.requests(to: "search").map { InnerTubeStub.bodyField("query", of: $0) }, ["daft punk", "daft punk"])
    }

    func testTheAllTabSendsNoParams() async throws {
        try stub.on("search", fixture: "search_all.json")
        let page = try await repository.searchPage(query: "daft punk", filter: .all)
        XCTAssertEqual(page.rows.first?.browseItem?.title, "Daft Punk")
        XCTAssertNil(InnerTubeStub.bodyField("params", of: try XCTUnwrap(stub.requests(to: "search").first)))
        let rows = try await repository.search(query: "daft punk", filter: .all)
        XCTAssertEqual(rows, page.rows)
    }

    func testSearchContinuationPages() async throws {
        try stub.on("search", fixture: "search_songs_continuation.json")
        let page = try await repository.searchContinuation(token: "NEXT", filter: .songs)
        XCTAssertEqual(page.rows.count, 20)
        XCTAssertNotNil(page.continuation)
        XCTAssertEqual(InnerTubeStub.bodyField("continuation", of: try XCTUnwrap(stub.requests(to: "search").first)), "NEXT")
    }

    func testSuggestions() async throws {
        try stub.on("music/get_search_suggestions", fixture: "search_suggestions.json")
        let suggestions = try await repository.searchSuggestions(input: "daft p")
        XCTAssertEqual(suggestions.first, "daft punk")
        XCTAssertEqual(suggestions.count, 6)
    }

    func testTypeaheadIsAMusicOnlyAnonymousSearch() async throws {
        try await signIn()
        try stub.on("search", fixture: "search_all.json")
        let page = try await repository.searchTypeahead(input: "daft punk")
        XCTAssertFalse(page.rows.isEmpty)
        // search_all.json carries music-video uploads; the dropdown shows none of them.
        XCTAssertTrue(page.rows.compactMap(\.trackSong).allSatisfy { !$0.isVideo })
        let request = try XCTUnwrap(stub.requests(to: "search").first)
        XCTAssertEqual(InnerTubeStub.bodyField("query", of: request), "daft punk")
        XCTAssertNil(InnerTubeStub.bodyField("params", of: request), "a plain search, with no filter")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    // MARK: - Pages

    func testAnAlbumReadsItsTracksFromTheBackingPlaylistAndItsHeaderFromItself() async throws {
        try stub.onBrowse("MPREb_7ltM34kr0mH", fixture: "album.json")
        try stub.onBrowse("VLOLAK5uy_mz6eafmqdRHSaR4IwG0ll6J6rgv0_ZpGw", fixture: "album_playlist.json")
        let page = try await repository.browseSongs(browseId: "MPREb_7ltM34kr0mH")
        XCTAssertEqual(browseIds(), ["MPREb_7ltM34kr0mH", "VLOLAK5uy_mz6eafmqdRHSaR4IwG0ll6J6rgv0_ZpGw"])
        XCTAssertEqual(page.songs.count, 14)
        XCTAssertEqual(page.songs.first?.videoId, "fa5IWHDbftI")
        XCTAssertEqual(page.songs.first?.albumName, "Discovery")
        XCTAssertEqual(page.header?.title, "Discovery")
        XCTAssertEqual(page.library?.playlistId, "OLAK5uy_mz6eafmqdRHSaR4IwG0ll6J6rgv0_ZpGw")
        XCTAssertNotNil(page.description)
        XCTAssertNil(page.owned, "an album has no owner in this sense")
    }

    func testAPlaylistPageSaysWhetherTheAccountOwnsIt() async throws {
        try stub.onBrowse("VLPL8-o_KZwk58yx2eTIGcK1EvHZkMI__Th4", fixture: "playlist.json")
        let page = try await repository.browseSongs(browseId: "VLPL8-o_KZwk58yx2eTIGcK1EvHZkMI__Th4")
        XCTAssertEqual(page.songs.count, 20)
        XCTAssertEqual(page.owned, false)
        let owned = try await repository.playlistOwned(browseId: "VLPL8-o_KZwk58yx2eTIGcK1EvHZkMI__Th4")
        XCTAssertEqual(owned, false)
    }

    func testMoreSongsFollowsTheShelfContinuation() async throws {
        try stub.onBrowse("VLPLciALUPf8sIJlvH350O8PWh4UbSbOffSJ", fixture: "playlist_long.json")
        let first = try await repository.browseSongs(browseId: "VLPLciALUPf8sIJlvH350O8PWh4UbSbOffSJ")
        let token = try XCTUnwrap(first.continuation)
        try stub.onContinuation(token, fixture: "playlist_long_continuation.json")
        let second = try await repository.moreSongs(token: token)
        XCTAssertEqual(second.songs.count, 25)
        XCTAssertNil(second.library, "a continuation can't say, and mustn't overwrite what the first page did")
        XCTAssertNil(second.owned)
    }

    func testAllSongsFollowsContinuationsAndKeepsWhatItHasWhenAPageFails() async throws {
        try stub.onBrowse("VLPLciALUPf8sIJlvH350O8PWh4UbSbOffSJ", fixture: "playlist_long.json")
        let firstToken = try XCTUnwrap(InnerTubeParser.continuationToken(try Fixtures.json("playlist_long.json")))
        try stub.onContinuation(firstToken, fixture: "playlist_long_continuation.json")
        // The third page isn't served: the two already read are kept.
        let songs = try await repository.allSongs(browseId: "VLPLciALUPf8sIJlvH350O8PWh4UbSbOffSJ")
        XCTAssertEqual(songs.count, 50)
        XCTAssertEqual(Set(songs.map(\.videoId)).count, 50)
    }

    func testAllSongsStopsAfterTenPages() async throws {
        onBrowse("VLPLendless", params: nil, body: Self.playlistPage(ids: ["page0track0"], continuation: "C1"))
        stub.stub.register(matching: { request in
            request.url?.path() == "/youtubei/v1/browse" && InnerTubeStub.bodyField("continuation", of: request) != nil
        }) { request in
            let token = InnerTubeStub.bodyField("continuation", of: request) ?? ""
            let n = Int(token.dropFirst()) ?? 0
            return .json(Self.continuationPage(ids: [String(format: "page%dtrack", n).padding(toLength: 11, withPad: "x", startingAt: 0)], continuation: "C\(n + 1)"))
        }
        let songs = try await repository.allSongs(browseId: "VLPLendless")
        XCTAssertEqual(songs.count, 10)
        XCTAssertEqual(stub.requests(to: "browse").count, 10)
    }

    func testAllSongsOfAnAlbumFollowsItsBackingPlaylist() async throws {
        try stub.onBrowse("MPREb_7ltM34kr0mH", fixture: "album.json")
        try stub.onBrowse("VLOLAK5uy_mz6eafmqdRHSaR4IwG0ll6J6rgv0_ZpGw", fixture: "album_playlist.json")
        let songs = try await repository.allSongs(browseId: "MPREb_7ltM34kr0mH")
        XCTAssertEqual(songs.first?.videoId, "fa5IWHDbftI")
        stub.on("browse", "{}")
        do {
            _ = try await repository.allSongs(browseId: "VLPLnothing")
            XCTFail("an empty listing is an error for a caller acting on all of it")
        } catch let error as InnerTubeError {
            XCTAssertEqual(error, .missingData("No tracks here"))
        }
    }

    func testArtistPageFillsTopSongsAndEveryShelfWithAMoreLink() async throws {
        onBrowse("UCRr1xG_2WIDs18a6cIiCxeA", params: nil, body: try Fixtures.text("artist.json"))
        try stub.onBrowse("VLOLAK5uy_lNVBcjNtiCwq-n95uoxJ-Gd4vsfMkyZNs", fixture: "playlist.json")
        onBrowse("MPADUCRr1xG_2WIDs18a6cIiCxeA", params: "ggMIegYIAhoCAQI%3D", body: try Fixtures.text("signed_in/library_albums.json"))
        // "Playlists by Daft Punk" links back to the artist with params; that page fails here and the
        // shelf keeps its first eight.
        let page = try await repository.artistPage(browseId: "UCRr1xG_2WIDs18a6cIiCxeA")
        XCTAssertEqual(page.songs.count, 20, "the Top songs playlist replaces the five-row preview")
        XCTAssertEqual(page.songs.first?.videoId, "H9gERrxL78U")
        XCTAssertEqual(page.sections.map(\.title), ["Albums", "Singles & EPs", "Featured on", "Playlists by Daft Punk", "Fans might also like"])
        XCTAssertEqual(page.sections[1].items.map(\.browseId), ["MPREb_K8qWMWVqXGi", "MPREb_CtOaObihCXA", "MPREb_7ltM34kr0mH"])
        XCTAssertEqual(page.sections[3].items.count, 8)
        XCTAssertEqual(page.name, "Daft Punk")
        let items = try await repository.shelfItems(browseId: "MPADUCRr1xG_2WIDs18a6cIiCxeA", params: "ggMIegYIAhoCAQI%3D")
        XCTAssertEqual(items.count, 3)
    }

    // MARK: - Library

    func testLibraryAssemblesItsFeedsAndSeedsLikes() async throws {
        try await signIn()
        try stub.onBrowse("VLLM", fixture: "signed_in/liked_music.json")
        try stub.onBrowse("FEmusic_liked_videos", fixture: "signed_in/library_songs.json")
        try stub.onBrowse("FEmusic_liked_playlists", fixture: "signed_in/library_playlists.json")
        try stub.onContinuation("PLAYLISTS_PAGE_2", fixture: "signed_in/library_playlists_continuation.json")
        try stub.onBrowse("FEmusic_liked_albums", fixture: "signed_in/library_albums.json")
        for empty in ["FEmusic_library_corpus_track_artists", "FEmusic_library_corpus_artists", "FEmusic_library_non_music_audio_list"] {
            try stub.onBrowse(empty, fixture: "signed_in/library_empty.json")
        }

        let library = try await repository.library()
        XCTAssertEqual(library.likedSongs.map(\.videoId), ["H9gERrxL78U", "lKScJ4GIWyE", "KKd0eVQ5X_4", "d7woYjGWs6k"])
        XCTAssertEqual(library.likedContinuation, "LIKED_PAGE_2")
        // Library songs the liked list already covers aren't repeated.
        XCTAssertTrue(library.librarySongs.allSatisfy { !["KKd0eVQ5X_4", "d7woYjGWs6k"].contains($0.videoId) })
        XCTAssertEqual(library.librarySongs.count, 5)
        // Empty feeds are dropped; the playlists feed was paged.
        XCTAssertEqual(library.shelves.map(\.title), ["Playlists", "Albums"])
        XCTAssertEqual(library.shelves[0].items.map(\.browseId), ["VLLM", "VLPLroad123", "VLRDTMAK5uy_supermix", "VLPLfriend456", "VLPLgym789"])
        XCTAssertEqual(Set(likeState.overrides.keys), ["H9gERrxL78U", "lKScJ4GIWyE", "KKd0eVQ5X_4", "d7woYjGWs6k"])
        XCTAssertFalse(library.isEmpty)

        // The rest of Liked Music is synced in the background from the continuation.
        try stub.onContinuation("LIKED_PAGE_2", fixture: "signed_in/liked_music_continuation.json")
        await repository.syncLikedMusic(from: library.likedContinuation)
        XCTAssertEqual(Set(likeState.overrides.keys), [
            "H9gERrxL78U", "lKScJ4GIWyE", "KKd0eVQ5X_4", "d7woYjGWs6k", "ADdaooPZG50", "ep76vmKxtfI", "Jb6gcoR266U",
        ])
    }

    func testUserPlaylistsArePagedAndFiltered() async throws {
        try await signIn()
        try stub.onBrowse("FEmusic_liked_playlists", fixture: "signed_in/library_playlists.json")
        try stub.onContinuation("PLAYLISTS_PAGE_2", fixture: "signed_in/library_playlists_continuation.json")
        let playlists = try await repository.userPlaylists()
        XCTAssertEqual(playlists.map(\.playlistId), ["PLroad123", "PLfriend456", "PLgym789"])
        let firstPage = try await repository.libraryPlaylists()
        XCTAssertEqual(firstPage.count, 4)
    }

    // MARK: - Watch queue

    func testRadioTrackLinksAndTheSongMenuComeFromNext() async throws {
        try stub.on("next", fixture: "signed_in/next_signed_in.json")
        let radio = try await repository.radio(videoId: "FGBhQbmPwH8")
        XCTAssertEqual(radio.count, 3)
        let links = try await repository.trackLinks(videoId: "FGBhQbmPwH8")
        XCTAssertEqual(links.albumId, "MPREb_7ltM34kr0mH")
        let menu = try await repository.songMenu(videoId: "FGBhQbmPwH8")
        XCTAssertEqual(menu.likeStatus, .like)
        do {
            _ = try await repository.trackLinks(videoId: "notInQueue1")
            XCTFail("expected missing data")
        } catch let error as InnerTubeError {
            XCTAssertEqual(error, .missingData("no watch entry for notInQueue1"))
        }
    }

    // MARK: - Lyrics

    func testLyricsFollowNextToTheLyricsTabAndBrowseIt() async throws {
        try stub.on("next", fixture: "next.json")
        try stub.onBrowse("MPLYt_dYXkoPsE0o6", fixture: "lyrics.json")
        let found = await repository.lyrics(videoId: "5NV6Rdv1a3I")
        let lyrics = try XCTUnwrap(found)
        XCTAssertEqual(lyrics.lines.count, 2)
        XCTAssertEqual(lyrics.source, "Source: Musixmatch")
        XCTAssertEqual(InnerTubeStub.bodyField("videoId", of: try XCTUnwrap(stub.requests(to: "next").first)), "5NV6Rdv1a3I")
    }

    func testLyricsAnswerNoneRatherThanThrowing() async throws {
        let notAVideo = await repository.lyrics(videoId: "local:file")
        XCTAssertNil(notAVideo)
        XCTAssertTrue(stub.stub.requests.isEmpty)
        try stub.on("next", fixture: "next.json")
        try stub.onBrowse("MPLYt_dYXkoPsE0o6", fixture: "lyrics_unavailable.json")
        let unavailable = await repository.lyrics(videoId: "5NV6Rdv1a3I")
        XCTAssertNil(unavailable)
        stub.on("next", "{}", status: 500)
        let failed = await repository.lyrics(videoId: "5NV6Rdv1a3I")
        XCTAssertNil(failed)
    }

    func testTranscriptLyrics() async throws {
        try stub.on("get_transcript", fixture: "signed_in/transcript.json")
        let cues = await repository.transcriptLyrics(videoId: "khnokW3Mw24")
        XCTAssertEqual(cues?.map(\.text), ["first line", "second line"])
    }

    // MARK: - Session rejection

    func testARejectedSessionIsRefreshedOnceAndRetried() async throws {
        try await signIn()
        let calls = LockedCounter()
        stub.stub.register(host: "music.youtube.com", path: "/youtubei/v1/account/account_menu") { _ in
            calls.increment() == 1 ? .status(401) : .json(try Fixtures.text("signed_in/account_menu.json"))
        }
        let account = try await repository.account()
        XCTAssertEqual(account.name, "Analytical Engine Radio")
        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(stub.stub.requests(toPath: "/").count, 2, "the session scope was reread before the retry")
    }

    func testARejectionIsRetriedOnlyOnce() async throws {
        try await signIn()
        stub.on("account/account_menu", "{}", status: 403)
        do {
            _ = try await repository.account()
            XCTFail("expected a failure")
        } catch let error as InnerTubeError {
            XCTAssertEqual(error, .httpStatus(403, endpoint: "account/account_menu"))
        }
        XCTAssertEqual(stub.requests(to: "account/account_menu").count, 2)
    }

    func testARejectionSignedOutIsNotRetried() async {
        stub.on("browse", "{}", status: 401)
        do {
            _ = try await repository.home()
            XCTFail("expected a failure")
        } catch {}
        XCTAssertEqual(stub.requests(to: "browse").count, 1)
    }

    // MARK: - Accounts

    func testChannelsComeFromAccountsListFirst() async throws {
        try await signIn()
        try stub.on("account/accounts_list", fixture: "signed_in/accounts_list.json")
        let channels = try await repository.accountChannels()
        XCTAssertEqual(channels.count, 2)
        XCTAssertTrue(stub.stub.requests(toPath: "/getAccountSwitcherEndpoint").isEmpty)
    }

    func testAnEmptyOrFailedAccountsListFallsBackToTheSwitcher() async throws {
        try await signIn()
        stub.stub.register(host: "www.youtube.com", path: "/getAccountSwitcherEndpoint", response: .text(try Fixtures.text("signed_in/account_switcher.txt")))
        try stub.on("account/accounts_list", fixture: "signed_in/accounts_list_empty.json")
        let fromEmpty = try await repository.accountChannels()
        XCTAssertEqual(fromEmpty.count, 2)
        stub.on("account/accounts_list", "{}", status: 500)
        let fromFailure = try await repository.accountChannels()
        XCTAssertEqual(fromFailure.map(\.name), ["Ada Lovelace", "Analytical Engine Radio"])
        XCTAssertEqual(stub.stub.requests(toPath: "/getAccountSwitcherEndpoint").count, 2)
    }

    func testNoAccountDetailsIsAnError() async throws {
        try await signIn()
        stub.on("account/account_menu", #"{"actions":[]}"#)
        do {
            _ = try await repository.account()
            XCTFail("expected missing data")
        } catch let error as InnerTubeError {
            XCTAssertEqual(error, .missingData("No account details"))
        }
    }

    // MARK: - Writes pass through

    func testWritesGoThroughTheClient() async throws {
        try await signIn()
        try stub.on("like/like", fixture: "signed_in/like_ok.json")
        stub.on("feedback", "{}")
        try stub.on("playlist/create", fixture: "signed_in/create_playlist.json")
        try await repository.rate(videoId: "v", status: .like)
        try await repository.setLibraryStatus(token: "T")
        try await repository.setSaved(playlistId: "OLAK5uy_x", saved: true)
        let id = try await repository.createPlaylist(title: "x", privacy: .private, videoIds: ["v"])
        XCTAssertEqual(id, "PLnew0001")
        XCTAssertEqual(stub.requests(to: "like/like").count, 2)
    }

    // MARK: - Versions

    func testResolvingAVideosAudioSearchesSongsAndRemembersTheAnswer() async throws {
        try stub.on("search", fixture: "search_songs.json")
        let video = Song(videoId: "a5uQMwRMHcs", title: "Instant Crush", artist: "Daft Punk", isVideo: true)
        let matcher = TitleMatcher()
        let audio = await repository.resolveAudio(for: video, using: matcher)
        XCTAssertEqual(audio.videoId, "khnokW3Mw24")
        XCTAssertEqual(InnerTubeStub.bodyField("params", of: try XCTUnwrap(stub.requests(to: "search").first)), SearchFilter.songs.params)
        let cached = await repository.cachedAudioVersion(videoId: "a5uQMwRMHcs")
        XCTAssertEqual(cached?.videoId, "khnokW3Mw24")
        _ = await repository.resolveAudio(for: video, using: matcher)
        XCTAssertEqual(stub.requests(to: "search").count, 1)
        // A track that isn't a video is its own audio.
        let track = Song(videoId: "khnokW3Mw24", title: "x", artist: "y")
        let same = await repository.resolveAudio(for: track, using: matcher)
        XCTAssertEqual(same, track)
    }

    func testNoVideoVersionIsRememberedToo() async throws {
        try stub.on("search", fixture: "search_videos.json")
        let track = Song(videoId: "khnokW3Mw24", title: "No such video", artist: "Nobody")
        let none = await repository.resolveVideo(for: track, using: TitleMatcher())
        XCTAssertNil(none)
        _ = await repository.resolveVideo(for: track, using: TitleMatcher())
        XCTAssertEqual(stub.requests(to: "search").count, 1)
    }

    // MARK: - Samples

    nonisolated static func home(shelves: [(String, [String])]) -> String {
        let sections = shelves.map { title, ids in
            let items = ids.map { id in
                #"{"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Track \#(id)"}]},"subtitle":{"runs":[{"text":"Song • Chelsea Wolfe"}]},"navigationEndpoint":{"watchEndpoint":{"videoId":"\#(id)"}}}}"#
            }.joined(separator: ",")
            return #"{"musicCarouselShelfRenderer":{"header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":"\#(title)"}]}}},"contents":[\#(items)]}}"#
        }.joined(separator: ",")
        return #"{"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[\#(sections)]}}}}]}}}"#
    }

    nonisolated static func rows(_ ids: [String]) -> String {
        ids.map { id in
            #"{"musicResponsiveListItemRenderer":{"playlistItemData":{"videoId":"\#(id)","playlistSetVideoId":"SET\#(id)"},"flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Song \#(id)"}]}}}]}}"#
        }.joined(separator: ",")
    }

    nonisolated static func playlistPage(ids: [String], continuation: String) -> String {
        #"{"contents":{"twoColumnBrowseResultsRenderer":{"secondaryContents":{"sectionListRenderer":{"contents":[{"musicPlaylistShelfRenderer":{"contents":[\#(rows(ids)),{"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"\#(continuation)"}}}}]}}]}}}}}"#
    }

    nonisolated static func continuationPage(ids: [String], continuation: String) -> String {
        #"{"onResponseReceivedActions":[{"appendContinuationItemsAction":{"continuationItems":[\#(rows(ids)),{"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"\#(continuation)"}}}}]}}]}"#
    }
}

/// A stand-in for the Sources module's TrackMatcher: exact-ish title match.
private struct TitleMatcher: SongVersionMatching {
    func searchQueries(for song: Song) -> [String] { ["\(song.title) \(song.artist)"] }
    func bestMatch(among candidates: [Song], for song: Song) -> Song? {
        candidates.first { $0.title.localizedCaseInsensitiveContains(song.title) && $0.artist.localizedCaseInsensitiveContains(song.artist) }
    }
}
