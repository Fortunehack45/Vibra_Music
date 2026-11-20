import XCTest
import VibraMusicCore
@testable import InnerTube

/// Home, Explore and moods, recorded live signed out (see Fixtures/README.txt), plus the signed-in
/// Home continuation built from the same renderers.
final class FeedFixtureParsingTests: XCTestCase {

    func testSignedOutHomeReadsItsCarouselsAndSkipsTheTasteBuilder() throws {
        let home = try Fixtures.json("home.json")
        let shelves = InnerTubeParser.parseHome(home)
        XCTAssertEqual(shelves.map(\.title), ["India’s biggest hits", "Trending community playlists"])
        XCTAssertEqual(shelves[0].subtitle, "MUSIC THAT'S HOT AND HAPPENING!", "the strapline rides along")
        XCTAssertEqual(shelves.map(\.items.count), [10, 10])
        let first = shelves[0].items[0]
        XCTAssertEqual(first.title, "Hits of 2026 (So Far)")
        XCTAssertEqual(first.browseId, "VLRDCLAK5uy_kCicKSTh7ylcZSwvrN0vV4dI3eqEpXR4A")
        XCTAssertNil(first.videoId)
        XCTAssertNotNil(first.thumbnailUrl)
        XCTAssertTrue(try XCTUnwrap(InnerTubeParser.continuationToken(home)).hasPrefix("4qmFsgKhAhIMRkVtdXNpY19ob21l"))
    }

    func testSignedOutHomeContinuationIsEmpty() throws {
        let page = try Fixtures.json("home_continuation.json")
        XCTAssertTrue(InnerTubeParser.parseHomeContinuation(page).isEmpty)
        XCTAssertNil(InnerTubeParser.continuationToken(page))
    }

    func testSignedInHomeContinuationShelvesAreFoundWhereverTheyLand() throws {
        let page = try Fixtures.json("signed_in/home_continuation_signed_in.json")
        let shelves = InnerTubeParser.parseHomeContinuation(page)
        XCTAssertEqual(shelves.map(\.title), ["Coffee shop blends", "Unwind + explore"])
        XCTAssertEqual(shelves.first?.items.count, 6)
        XCTAssertEqual(InnerTubeParser.continuationToken(page), "HOME_PAGE_3")
    }

    func testNewReleasesAndExploreSupplements() throws {
        let releases = InnerTubeParser.parseHome(try Fixtures.json("new_releases.json"))
        XCTAssertEqual(releases.map(\.title), ["Albums & singles"])
        XCTAssertEqual(releases[0].items.first?.title, "Tera Mera Rishta (Sad Version)")
        XCTAssertEqual(releases[0].items.first?.subtitle, "Single • Jibon Krishna Das")
        XCTAssertEqual(releases[0].items.first?.browseId, "MPREb_X5MTLlSTUmJ")

        let explore = InnerTubeParser.parseHome(try Fixtures.json("explore.json"))
        XCTAssertEqual(explore.map(\.title), ["New albums & singles"], "the music-video shelves are dropped")
        XCTAssertEqual(explore[0].items.first?.title, "PRIMA")
        XCTAssertTrue(explore[0].items.allSatisfy { $0.browseId?.hasPrefix("MPREb") == true })
    }

    func testMoodsAndGenresKeepEveryButtonsParams() throws {
        let sections = InnerTubeParser.parseMoodAndGenres(try Fixtures.json("moods_and_genres.json"))
        XCTAssertEqual(sections.map(\.title), ["Moods & moments", "Genres"])
        XCTAssertEqual(sections.map(\.items.count), [11, 38])
        let chill = sections[0].items[0]
        XCTAssertEqual(chill, MoodGenre(title: "Chill", browseId: "FEmusic_moods_and_genres_category", params: "ggMPOg1uX1JOQWZFeDByc2Jm"))
        XCTAssertEqual(sections[1].items.first?.title, "African")
        // Every button opens the same browse id; only its params tell them apart.
        let all = sections.flatMap(\.items)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
    }

    func testAMoodCategoryIsAPageOfPlaylistShelves() throws {
        let shelves = InnerTubeParser.parseHome(try Fixtures.json("mood_chill.json"))
        XCTAssertEqual(shelves.count, 13)
        XCTAssertEqual(shelves.first?.title, "Coffee shop blends")
        let card = try XCTUnwrap(shelves.first?.items.first)
        XCTAssertEqual(card.title, "Coffee Shop Blend")
        XCTAssertEqual(card.subtitle, "Playlist • YouTube Music")
        XCTAssertEqual(card.browseId, "VLRDCLAK5uy_nBE4bLuBHUXWZrF59ZrkPEToKt8M_I3Vc")
        XCTAssertTrue(shelves.allSatisfy { $0.items.allSatisfy { $0.browseId?.hasPrefix("VL") == true } })
    }

    // MARK: - Shelf rules on small samples

    func testVideoShelvesAndVideoCardsAreDropped() {
        let response = json(#"""
        {"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[
          {"musicCarouselShelfRenderer":{"header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":"Music videos for you"}]}}},
            "contents":[{"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"X"}]},"navigationEndpoint":{"watchEndpoint":{"videoId":"v1"}}}}]}},
          {"musicCarouselShelfRenderer":{"header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":""}]}}},
            "contents":[
              {"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Wide"}]},"navigationEndpoint":{"watchEndpoint":{"videoId":"v2"}},
                "thumbnailRenderer":{"musicThumbnailRenderer":{"thumbnail":{"thumbnails":[{"url":"u","width":400,"height":225}]}}}}},
              {"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Video Games"}]},"navigationEndpoint":{"watchEndpoint":{"videoId":"v3"}}}},
              {"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Daily Top Music Videos"}]},"navigationEndpoint":{"browseEndpoint":{"browseId":"FEmusic_charts_videos"}}}},
              {"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Heard again"}]},"navigationEndpoint":{"browseEndpoint":{"browseId":"MPEDabcdefghijk"}}}}
            ]}}
        ]}}}}]}}}
        """#)
        let shelves = InnerTubeParser.parseHome(response)
        XCTAssertEqual(shelves.map(\.title), ["For you"], "a blank title reads as For you; the video shelf is gone")
        XCTAssertEqual(shelves[0].items.map(\.title), ["Video Games", "Heard again"])
        // An MPED "non-music audio track page" is the video id itself, not a page.
        XCTAssertEqual(shelves[0].items[1].videoId, "abcdefghijk")
        XCTAssertNil(shelves[0].items[1].browseId)
    }

    func testAChartOfArtistsIsKeptAsArtistCards() {
        let response = json(#"""
        {"contents":{"singleColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[
          {"musicCarouselShelfRenderer":{"header":{"musicCarouselShelfBasicHeaderRenderer":{"title":{"runs":[{"text":"Top artists"}]}}},
            "contents":[{"musicResponsiveListItemRenderer":{
              "navigationEndpoint":{"browseEndpoint":{"browseId":"UCartist","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ARTIST"}}}},
              "flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Arijit Singh"}]}}},
                             {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"30M subscribers"}]}}}]}}]}}
        ]}}}}]}}}
        """#)
        let shelves = InnerTubeParser.parseHome(response)
        XCTAssertEqual(shelves.first?.items, [ShelfItem(title: "Arijit Singh", subtitle: "30M subscribers", thumbnailUrl: nil, videoId: nil, browseId: "UCartist")])
    }
}

/// Album, playlist and artist pages, recorded live signed out.
final class PageFixtureParsingTests: XCTestCase {

    func testAlbumPageRowsAreCreditedByTheReleaseHeader() throws {
        let response = try Fixtures.json("album.json")
        let page = YTMusicRepository.page(of: response)
        XCTAssertEqual(page.songs.count, 14)
        let first = try XCTUnwrap(page.songs.first)
        XCTAssertEqual(first.title, "One More Time")
        XCTAssertEqual(first.artist, "Daft Punk")
        XCTAssertEqual(first.artistId, "UCRr1xG_2WIDs18a6cIiCxeA")
        // The per-track runtime sits in a fixed column on an album page.
        XCTAssertEqual(first.durationText, "5:21")
        // The cover is the header's own largest thumbnail, not another image on the page.
        XCTAssertEqual(page.header, InnerTubeParser.BrowseHeader(
            title: "Discovery",
            subtitle: "Daft Punk • Album • 2001",
            thumbnailUrl: "https://yt3.googleusercontent.com/qrY7xjdjqL0FEneZKHk845JeeFjdWOgexUa_BhsUxskJ2iflhzpbofqGJZBcPHDGU9JjoZflE4yn3P74=w544-h544-l90-rj"
        ))
        XCTAssertTrue(try XCTUnwrap(page.description).hasPrefix("Discovery is the second studio album by the French electronic music duo Daft Punk"))
        XCTAssertEqual(page.library?.playlistId, "OLAK5uy_mz6eafmqdRHSaR4IwG0ll6J6rgv0_ZpGw")
        XCTAssertEqual(InnerTubeParser.parseAlbumPlaylistId(response), "OLAK5uy_mz6eafmqdRHSaR4IwG0ll6J6rgv0_ZpGw")
        XCTAssertNil(page.continuation)
    }

    func testAnAlbumsBackingPlaylistCarriesTheAlbumOnEveryRow() throws {
        let page = YTMusicRepository.page(of: try Fixtures.json("album_playlist.json"))
        XCTAssertEqual(page.songs.count, 14)
        XCTAssertTrue(page.songs.allSatisfy { $0.albumId == "MPREb_7ltM34kr0mH" && $0.albumName == "Discovery" && $0.artist == "Daft Punk" })
        XCTAssertEqual(page.songs.first?.videoId, "fa5IWHDbftI")
        XCTAssertEqual(page.songs.first?.setVideoId, "9E9C1F2D910459BA")
    }

    func testPlaylistPageReadsItsOwnShelf() throws {
        let response = try Fixtures.json("playlist.json")
        XCTAssertNotNil(InnerTubeParser.parsePlaylistShelf(response))
        let page = YTMusicRepository.page(of: response)
        XCTAssertEqual(page.songs.count, 20)
        let first = try XCTUnwrap(page.songs.first)
        XCTAssertEqual(first.videoId, "H9gERrxL78U")
        XCTAssertEqual(first.title, "Daftendirekt")
        XCTAssertEqual(first.albumName, "Homework")
        XCTAssertEqual(first.durationText, "2:45")
        XCTAssertEqual(first.setVideoId, "56B44F6D10557CC6", "playlist rows can be removed by their entry id")
        XCTAssertEqual(page.header?.title, "the entire* daft punk discography")
        XCTAssertEqual(page.header?.subtitle, "Playlist • 2021")
        XCTAssertNil(page.description, "YouTube writes blurbs for its catalogue, not for playlists")
        XCTAssertTrue(page.suggested.isEmpty)
    }

    func testSuggestedSongsNeverReadAsTracksTheUserAdded() {
        func row(_ id: String, set: Bool) -> String {
            let setId = set ? #","playlistSetVideoId":"SET_\#(id)""# : ""
            return #"{"musicResponsiveListItemRenderer":{"playlistItemData":{"videoId":"\#(id)"\#(setId)},"flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Song \#(id)"}]}}}]}}"#
        }
        let page = json(#"""
        {"contents":{"twoColumnBrowseResultsRenderer":{"secondaryContents":{"sectionListRenderer":{"contents":[
          {"musicPlaylistShelfRenderer":{"contents":[\#(row("aaaaaaaaaaa", set: true)),\#(row("bbbbbbbbbbb", set: true))]}},
          {"musicShelfRenderer":{"title":{"runs":[{"text":"Suggestions"}]},
            "contents":[\#(row("bbbbbbbbbbb", set: false)),\#(row("ccccccccccc", set: false))],
            "continuations":[{"reloadContinuationData":{"continuation":"RELOAD"}}],
            "bottomButton":{"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"REFRESH"}}}}}}
        ]}}}}}
        """#)
        let shelf = YTMusicRepository.page(of: page)
        XCTAssertEqual(shelf.songs.map(\.videoId), ["aaaaaaaaaaa", "bbbbbbbbbbb"])
        XCTAssertEqual(shelf.suggested.map(\.videoId), ["ccccccccccc"], "a suggestion already in the playlist isn't offered")
        // The Suggestions shelf's own token reloads it; it isn't more of the playlist.
        XCTAssertNil(shelf.continuation)

        // An owned two-song playlist's continuation serves the Suggestions shelf on its own.
        let continuation = json(#"""
        {"continuationContents":{"sectionListContinuation":{"contents":[
          {"musicShelfRenderer":{"title":{"runs":[{"text":"Suggestions"}]},"contents":[\#(row("ddddddddddd", set: false))]}}
        ]}}}
        """#)
        let more = YTMusicRepository.page(of: continuation)
        XCTAssertTrue(more.songs.isEmpty)
        XCTAssertEqual(more.suggested.map(\.videoId), ["ddddddddddd"])
    }

    func testAPlaylistsSectionContinuationIsRelatedPlaylistsNotTracks() throws {
        // Following the page's section-list continuation serves "Related playlists": no rows.
        let page = YTMusicRepository.page(of: try Fixtures.json("playlist_continuation.json"))
        XCTAssertTrue(page.songs.isEmpty)
        XCTAssertNil(page.continuation)
    }

    func testALongPlaylistPagesThroughItsShelfContinuation() throws {
        let first = YTMusicRepository.page(of: try Fixtures.json("playlist_long.json"))
        XCTAssertEqual(first.songs.count, 25)
        XCTAssertTrue(try XCTUnwrap(first.continuation).hasPrefix("4qmFsgKHARIk"))
        // Video uploads in a user playlist stay (flagged), unlike on search pages.
        XCTAssertEqual(first.songs[1].videoId, "0BXjdS6u7YI")
        XCTAssertTrue(first.songs[1].isVideo)

        // The continuation arrives as onResponseReceivedActions, which the generic walk reads.
        let next = try Fixtures.json("playlist_long_continuation.json")
        XCTAssertNil(InnerTubeParser.parsePlaylistShelf(next))
        let second = YTMusicRepository.page(of: next)
        XCTAssertEqual(second.songs.count, 25)
        XCTAssertEqual(second.songs.first?.videoId, "O4_5593-skQ")
        XCTAssertTrue(second.songs.allSatisfy { $0.setVideoId != nil })
        XCTAssertTrue(try XCTUnwrap(second.continuation).hasPrefix("4qmFsgKFARIk"))
        XCTAssertNil(second.header)
        XCTAssertNil(second.library)
        XCTAssertTrue(Set(first.songs.map(\.videoId)).isDisjoint(with: second.songs.map(\.videoId)))
    }

    func testArtistPageFixture() throws {
        let page = InnerTubeParser.parseArtistPage(try Fixtures.json("artist.json"))
        XCTAssertEqual(page.name, "Daft Punk")
        XCTAssertNotNil(page.thumbnailUrl)
        XCTAssertEqual(page.subscriberCountText, "7.18M subscribers")
        XCTAssertEqual(page.monthlyListenerCount, "87M monthly audience")
        XCTAssertTrue(try XCTUnwrap(page.description).hasPrefix("Daft Punk were a French electronic music duo"))
        // The subscribe button names the channel it acts on, which here is not the page's browse id.
        XCTAssertEqual(page.subscription, SubscriptionState(channelId: "UC_kRDKYrUlrbtrSiyu5Tflg", subscribed: false))
        XCTAssertEqual(page.moreSongsBrowseId, "VLOLAK5uy_lNVBcjNtiCwq-n95uoxJ-Gd4vsfMkyZNs")

        XCTAssertEqual(page.songs.count, 5)
        XCTAssertEqual(page.songs.first?.title, "Instant Crush (feat. Julian Casablancas)")
        XCTAssertEqual(page.songs.first?.artist, "Daft Punk, Julian Casablancas")
        XCTAssertEqual(page.songs.first?.albumName, "Random Access Memories")

        // "Videos" is dropped by its title and "Live performances" because none of its cards is a page.
        XCTAssertEqual(page.sections.map(\.title), ["Albums", "Singles & EPs", "Featured on", "Playlists by Daft Punk", "Fans might also like"])
        let singles = page.sections[1]
        XCTAssertEqual(singles.moreBrowseId, "MPADUCRr1xG_2WIDs18a6cIiCxeA")
        XCTAssertEqual(singles.moreParams, "ggMIegYIAhoCAQI%3D")
        XCTAssertNil(page.sections[0].moreBrowseId)
        XCTAssertEqual(page.sections[0].items.first?.browseId, "MPREb_OgeEnoHTsCm")
        XCTAssertEqual(page.sections[4].items.first?.browseId, "UC3V5kzHK2r4rbbXlf4OpFmw")
    }

    func testTheArtistsNameAndPictureComeFromEitherHeaderShape() {
        let visual = json(#"""
        {"header":{"musicVisualHeaderRenderer":{"title":{"runs":[{"text":"Solo Artist"}]},
          "foregroundThumbnail":{"musicThumbnailRenderer":{"thumbnail":{"thumbnails":[{"url":"small"},{"url":"big"}]}}}}}}
        """#)
        let page = InnerTubeParser.parseArtistPage(visual)
        XCTAssertEqual(page.name, "Solo Artist")
        XCTAssertEqual(page.thumbnailUrl, "big")
        XCTAssertNil(page.subscription)
        XCTAssertNil(page.subscriberCountText)
    }

    func testTheOlderSubscribeButtonShapeAndItsEndpointChannelId() {
        let immersive = json(#"""
        {"header":{"musicImmersiveHeaderRenderer":{"title":{"runs":[{"text":"A"}]},
          "subscriptionButton2":{"subscribeButtonRenderer":{"subscriberCountWithSubscribeText":{"runs":[{"text":"1.2M"}]}}},
          "subscriptionButton":{"subscribeButtonRenderer":{"subscribed":true,"longSubscriberCountText":{"runs":[{"text":"1.2M subscribers"}]},
            "serviceEndpoints":[{"subscribeEndpoint":{"channelIds":["UCchannel"]}}]}}}}}
        """#)
        let page = InnerTubeParser.parseArtistPage(immersive)
        // The newer button carries only the count; the state is on the older one.
        XCTAssertEqual(page.subscription, SubscriptionState(channelId: "UCchannel", subscribed: true))
        XCTAssertEqual(page.subscriberCountText, "1.2M")
    }

    func testAStringEncodedSubscribeStateIsReadLikeKotlinsBooleanOrNull() {
        // YouTube sometimes ships "subscribed" as a string; kotlinx JsonPrimitive.booleanOrNull
        // accepts "true"/"false", so the parser must too.
        let immersive = json(#"""
        {"header":{"musicImmersiveHeaderRenderer":{"title":{"runs":[{"text":"A"}]},
          "subscriptionButton":{"subscribeButtonRenderer":{"subscribed":"True",
            "channelId":"UCstring"}}}}}
        """#)
        let page = InnerTubeParser.parseArtistPage(immersive)
        XCTAssertEqual(page.subscription, SubscriptionState(channelId: "UCstring", subscribed: true))
    }
}

/// The signed-in library feeds, built from the renderers Android's parser expects (they can't be
/// recorded without an account — see Fixtures/README.txt).
final class LibraryFixtureParsingTests: XCTestCase {

    func testLikedMusicFirstPage() throws {
        let page = YTMusicRepository.page(of: try Fixtures.json("signed_in/liked_music.json"))
        XCTAssertEqual(page.songs.map(\.videoId), ["H9gERrxL78U", "lKScJ4GIWyE", "KKd0eVQ5X_4", "d7woYjGWs6k"])
        XCTAssertEqual(page.continuation, "LIKED_PAGE_2")
        XCTAssertEqual(page.header?.title, "Liked Music")
    }

    func testLikedMusicContinuation() throws {
        let page = YTMusicRepository.page(of: try Fixtures.json("signed_in/liked_music_continuation.json"))
        XCTAssertEqual(page.songs.map(\.videoId), ["ADdaooPZG50", "ep76vmKxtfI", "Jb6gcoR266U"])
        XCTAssertNil(page.continuation)
    }

    func testHistoryIsOneRowPerTrackNewestFirst() throws {
        let songs = InnerTubeParser.collectSongsDeep(try Fixtures.json("signed_in/history.json"))
        XCTAssertEqual(songs.count, 6)
        XCTAssertEqual(songs.first?.videoId, "H9gERrxL78U")
        XCTAssertEqual(Set(songs.map(\.videoId)).count, songs.count)
    }

    func testLibrarySongsFeed() throws {
        let songs = InnerTubeParser.collectSongsDeep(try Fixtures.json("signed_in/library_songs.json"))
        XCTAssertEqual(songs.count, 7)
        XCTAssertEqual(songs.first?.videoId, "KKd0eVQ5X_4")
    }

    func testLibraryPlaylistsDropTheNewPlaylistTileAndPage() throws {
        let page = InnerTubeParser.parseLibraryItemPage(try Fixtures.json("signed_in/library_playlists.json"))
        XCTAssertEqual(page.items.map(\.title), ["Liked Music", "Road songs", "Supermix", "Friend's picks"])
        XCTAssertEqual(page.continuation, "PLAYLISTS_PAGE_2")
        let next = InnerTubeParser.parseLibraryItemPage(try Fixtures.json("signed_in/library_playlists_continuation.json"))
        XCTAssertEqual(next.items.map(\.browseId), ["VLPLgym789", "VLPLroad123"])
        XCTAssertNil(next.continuation)
    }

    func testThePlaylistPickerListsOnlyEditablePlaylists() throws {
        let playlists = InnerTubeParser.parseUserPlaylists(try Fixtures.json("signed_in/library_playlists.json"))
        // Liked Music (LM) and the generated mix (RD) take no edits; a stranger's saved playlist
        // stays, because ownership isn't stated on this feed.
        XCTAssertEqual(playlists.map(\.playlistId), ["PLroad123", "PLfriend456"])
        XCTAssertEqual(playlists.first?.browseId, "VLPLroad123")
    }

    func testLibraryAlbumsAndAnEmptyFeed() throws {
        let albums = InnerTubeParser.parseLibraryItems(try Fixtures.json("signed_in/library_albums.json"))
        XCTAssertEqual(albums.map(\.browseId), ["MPREb_K8qWMWVqXGi", "MPREb_CtOaObihCXA", "MPREb_7ltM34kr0mH"])
        XCTAssertEqual(albums.first?.subtitle, "Album • Daft Punk • 2013")
        XCTAssertTrue(InnerTubeParser.parseLibraryItems(try Fixtures.json("signed_in/library_empty.json")).isEmpty)
    }

    func testAListViewLibraryIsReadLikeTheGrid() {
        let list = json(#"""
        {"contents":[{"musicResponsiveListItemRenderer":{
          "navigationEndpoint":{"browseEndpoint":{"browseId":"VLPLlist","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_PLAYLIST"}}}},
          "flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"From the list view"}]}}},
                         {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Playlist • 3 songs"}]}}}]}}]}
        """#)
        XCTAssertEqual(InnerTubeParser.parseLibraryItems(list), [
            ShelfItem(title: "From the list view", subtitle: "Playlist • 3 songs", thumbnailUrl: nil, videoId: nil, browseId: "VLPLlist"),
        ])
    }
}
