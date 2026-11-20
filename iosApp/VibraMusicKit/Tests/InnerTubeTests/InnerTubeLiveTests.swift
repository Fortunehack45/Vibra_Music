import XCTest
import VibraMusicCore
@testable import InnerTube

/// Against the real YouTube Music, signed out. Skipped unless VIBRAMUSIC_LIVE_TESTS=1.
///
/// These prove the endpoints still answer in the shapes the parser reads. They assert on structure
/// and on catalogue entries that don't change (Daft Punk's channel, *Discovery*, *Instant Crush*),
/// never on what today's charts happen to hold.
@MainActor
final class InnerTubeLiveTests: XCTestCase {
    private var client: InnerTubeClient!
    private var repository: YTMusicRepository!

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["VIBRAMUSIC_LIVE_TESTS"] == "1" else {
            throw XCTSkip("live test; set VIBRAMUSIC_LIVE_TESTS=1 to run against the real service")
        }
        client = InnerTubeClient(language: { "en" })
        repository = YTMusicRepository(client: client, likeState: LikeState())
    }

    func testVisitorIdAndTheShellsClientVersionAreReadableToday() async throws {
        let minted = await client.ensureVisitorData()
        let visitor = try XCTUnwrap(minted)
        XCTAssertTrue(InnerTubeClient.visitorDataShape.matches(visitor), visitor)

        var request = URLRequest(url: YouTubeWebLogin.musicURL)
        request.setValue(VibraMusicHTTP.UserAgent.chromeDesktop, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await VibraMusicHTTP.session.data(for: request)
        let shell = try XCTUnwrap(InnerTubeClient.sessionScope(fromShell: String(decoding: data, as: UTF8.self)))
        XCTAssertFalse(shell.signedIn)
        let version = try XCTUnwrap(shell.scope.clientVersion)
        XCTAssertTrue(version.hasPrefix("1."), version)
    }

    func testHomeAndItsSupplements() async throws {
        let home = try await repository.home()
        XCTAssertFalse(home.shelves.isEmpty)
        XCTAssertTrue(home.shelves.allSatisfy { !$0.items.isEmpty && !$0.title.isEmpty })
        if let token = home.continuation {
            _ = try await repository.moreHome(token: token)
        }
        for browseId in YTMusicRepository.homeSupplementBrowseIds {
            let shelves = try await repository.homeSupplement(browseId: browseId)
            XCTAssertFalse(shelves.isEmpty, browseId)
        }
        let visitor = await client.requestIdentity().visitorData
        XCTAssertNotNil(visitor, "the first response mints a visitor id for the session")
    }

    func testMoodsAndGenresAndACategory() async throws {
        let sections = try await repository.moodAndGenres()
        XCTAssertGreaterThanOrEqual(sections.count, 2)
        let mood = try XCTUnwrap(sections.first?.items.first)
        XCTAssertNotNil(mood.params)
        let shelves = try await repository.moodGenreShelves(browseId: mood.browseId, params: mood.params)
        XCTAssertFalse(shelves.isEmpty)
        XCTAssertTrue(shelves.flatMap(\.items).contains { $0.browseId?.hasPrefix("VL") == true })
        let artwork = try await repository.moodGenreArtwork(browseId: mood.browseId, params: mood.params)
        XCTAssertNotNil(artwork)
    }

    func testSearchInEveryFilter() async throws {
        let all = try await repository.searchPage(query: "daft punk", filter: .all)
        XCTAssertEqual(all.rows.first?.browseItem?.browseId, "UCRr1xG_2WIDs18a6cIiCxeA", "the promoted artist leads")
        XCTAssertTrue(all.rows.compactMap(\.song).allSatisfy { !$0.isVideo })

        let songs = try await repository.searchPage(query: "daft punk", filter: .songs)
        XCTAssertGreaterThanOrEqual(songs.rows.count, 10)
        XCTAssertTrue(songs.rows.allSatisfy { $0.trackSong.map { !$0.isVideo && $0.durationText != nil } ?? false })
        let next = try await repository.searchContinuation(token: try XCTUnwrap(songs.continuation), filter: .songs)
        XCTAssertFalse(next.rows.isEmpty)
        XCTAssertTrue(Set(next.rows.map(\.id)).isDisjoint(with: songs.rows.map(\.id)))

        let videos = try await repository.searchPage(query: "daft punk", filter: .videos)
        XCTAssertFalse(videos.rows.isEmpty)
        XCTAssertTrue(videos.rows.allSatisfy { $0.trackSong?.isVideo == true })

        for (filter, type) in [(SearchFilter.albums, BrowseType.album), (.artists, .artist), (.playlists, .playlist)] {
            let page = try await repository.searchPage(query: "daft punk", filter: filter)
            XCTAssertFalse(page.rows.isEmpty, filter.label)
            XCTAssertTrue(page.rows.allSatisfy { $0.browseItem?.type == type }, filter.label)
        }
    }

    func testSuggestionsAndTypeahead() async throws {
        let suggestions = try await repository.searchSuggestions(input: "daft p")
        XCTAssertTrue(suggestions.contains { $0.lowercased().hasPrefix("daft punk") }, "\(suggestions)")
        let typeahead = try await repository.searchTypeahead(input: "daft punk")
        XCTAssertFalse(typeahead.rows.isEmpty)
    }

    func testAlbumJoinsItsBackingPlaylist() async throws {
        let page = try await repository.browseSongs(browseId: "MPREb_7ltM34kr0mH")
        XCTAssertEqual(page.header?.title, "Discovery")
        XCTAssertGreaterThanOrEqual(page.songs.count, 14)
        XCTAssertTrue(page.songs.allSatisfy { $0.artist.contains("Daft Punk") })
        XCTAssertTrue(page.songs.allSatisfy { $0.durationText != nil })
        XCTAssertTrue(try XCTUnwrap(page.library?.playlistId).hasPrefix("OLAK5uy_"))
        XCTAssertNotNil(page.description)
    }

    func testALongPlaylistPagesThroughItsContinuations() async throws {
        let first = try await repository.browseSongs(browseId: "VLPLciALUPf8sIJlvH350O8PWh4UbSbOffSJ")
        XCTAssertGreaterThanOrEqual(first.songs.count, 50)
        XCTAssertEqual(first.owned, false)
        let token = try XCTUnwrap(first.continuation)
        let second = try await repository.moreSongs(token: token)
        XCTAssertFalse(second.songs.isEmpty)
        XCTAssertTrue(Set(first.songs.map(\.videoId)).isDisjoint(with: second.songs.map(\.videoId)))
        let all = try await repository.allSongs(browseId: "VLPLciALUPf8sIJlvH350O8PWh4UbSbOffSJ")
        XCTAssertGreaterThan(all.count, first.songs.count)
    }

    func testArtistPageFillsItsTopSongsAndReleases() async throws {
        let page = try await repository.artistPage(browseId: "UCRr1xG_2WIDs18a6cIiCxeA")
        XCTAssertEqual(page.name, "Daft Punk")
        XCTAssertGreaterThan(page.songs.count, 5, "the Top songs playlist replaces the preview")
        XCTAssertNotNil(page.subscriberCountText)
        XCTAssertNotNil(page.description)
        XCTAssertNotNil(page.thumbnailUrl)
        XCTAssertTrue(page.sections.contains { $0.title == "Albums" && !$0.items.isEmpty })
        XCTAssertTrue(page.sections.contains { $0.title.contains("Singles") && $0.items.count > 8 }, "the more link was followed")
    }

    func testRadioQueueAndTrackLinks() async throws {
        let radio = try await repository.radio(videoId: "5NV6Rdv1a3I")
        XCTAssertGreaterThanOrEqual(radio.count, 10)
        XCTAssertEqual(radio.first?.videoId, "5NV6Rdv1a3I")
        let links = try await repository.trackLinks(videoId: "khnokW3Mw24")
        XCTAssertEqual(links.artistId, "UCRr1xG_2WIDs18a6cIiCxeA")
        let menu = try await repository.songMenu(videoId: "khnokW3Mw24")
        XCTAssertNil(menu.likeStatus, "signed out, nothing states a rating")
    }

    func testLyricsOfATrackThatHasThem() async throws {
        let found = await repository.lyrics(videoId: "khnokW3Mw24")
        let lyrics = try XCTUnwrap(found)
        XCTAssertGreaterThan(lyrics.lines.count, 10)
        XCTAssertNotNil(lyrics.source)
    }

    /// `get_transcript` with the params Android sends answers 400 INVALID_ARGUMENT today (checked
    /// 2026-09-26, same as the Lyrics module found), so this proves the degrade path rather than cues:
    /// a failed transcript is "no lyrics", never an error that reaches the lyrics chain.
    func testTranscriptLyricsAnswerNoneRatherThanFailing() async throws {
        let cues = await repository.transcriptLyrics(videoId: "khnokW3Mw24")
        if let cues {
            XCTAssertFalse(cues.isEmpty)
            XCTAssertEqual(cues.map(\.startMs), cues.map(\.startMs).sorted())
        }
    }
}
