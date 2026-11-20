import XCTest
@testable import VibraMusicCore

/// Browse ids, search types and the other feed models. The browse-type cases are ported from
/// BrowseTypeTest.kt; the primary-artist cases from PrimaryArtistTest.kt.
final class BrowseModelTests: XCTestCase {
    // MARK: BrowseType.of (BrowseTypeTest.kt)

    func testResolvesVLOLAKAndOLAKAlbumReleaseIdsAsAlbums() {
        XCTAssertEqual(BrowseType.of(browseId: "VLOLAK5uy_kX123456789"), .album)
        XCTAssertEqual(BrowseType.of(browseId: "OLAK5uy_kX123456789"), .album)
    }

    func testResolvesMPREbAlbumIdsAsAlbums() {
        XCTAssertEqual(BrowseType.of(browseId: "MPREb_987654321"), .album)
    }

    func testResolvesUCArtistIdsAsArtists() {
        XCTAssertEqual(BrowseType.of(browseId: "UC1234567890abcdef"), .artist)
    }

    func testResolvesVLPLAndPLPlaylistIdsAsPlaylists() {
        XCTAssertEqual(BrowseType.of(browseId: "VLPL1234567890"), .playlist)
        XCTAssertEqual(BrowseType.of(browseId: "PL1234567890"), .playlist)
        XCTAssertEqual(BrowseType.of(browseId: "\(LocalBrowseID.playlistPrefix)local_downloads"), .playlist)
    }

    func testPreservesTheFallbackWhenThePrefixIsUnknown() {
        XCTAssertEqual(BrowseType.of(browseId: "unknown_id", fallback: .album), .album)
        XCTAssertEqual(BrowseType.of(browseId: "custom_source", fallback: .artist), .artist)
        XCTAssertEqual(BrowseType.of(browseId: "unrecognized_prefix"), .other)
    }

    func testLocalBrowseIdsMatchAndroid() {
        XCTAssertEqual(LocalBrowseID.downloads, "local:downloads")
        XCTAssertEqual(LocalBrowseID.all, "local:all")
        XCTAssertEqual(LocalBrowseID.playlistPrefix, "local:playlist:")
        XCTAssertEqual(LocalBrowseID.webDAV, "local:webdav")
        XCTAssertEqual(LocalBrowseID.smb, "local:smb")
        XCTAssertTrue(LocalBrowseID.isLocal("local:smb"))
        XCTAssertFalse(LocalBrowseID.isLocal("VLPL1"))
    }

    // MARK: Primary artist (PrimaryArtistTest.kt)

    func testTakesTheFirstArtistFromCommonCollaborationCredits() {
        XCTAssertEqual(ArtistCredit.primary(of: "Anitta & Shakira"), "Anitta")
        XCTAssertEqual(ArtistCredit.primary(of: "Anitta, Shakira"), "Anitta")
        XCTAssertEqual(ArtistCredit.primary(of: "Anitta ＆ Shakira"), "Anitta")
    }

    func testLeavesASingleArtistUnchanged() {
        XCTAssertEqual(ArtistCredit.primary(of: "AC/DC"), "AC/DC")
        XCTAssertEqual(ArtistCredit.primary(of: "Florence and the Machine"), "Florence and the Machine")
        XCTAssertEqual(Song(videoId: "x", title: "T", artist: "Simon & Garfunkel").primaryArtist, "Simon")
    }

    func testAnAmpersandWithoutSpacesIsPartOfTheName() {
        XCTAssertEqual(ArtistCredit.primary(of: "Earth,Wind&Fire"), "Earth")
        XCTAssertEqual(ArtistCredit.primary(of: "Chase&Status"), "Chase&Status")
    }

    func testABlankFirstCreditKeepsTheOriginal() {
        XCTAssertEqual(ArtistCredit.primary(of: ", Someone"), ", Someone")
    }

    // MARK: Search

    func testSearchFilterParamsAreInnertubesOwn() {
        XCTAssertNil(SearchFilter.all.params)
        XCTAssertEqual(SearchFilter.songs.params, "EgWKAQIIAWoKEAkQChAFEAMQBA==")
        XCTAssertEqual(SearchFilter.videos.params, "EgWKAQIQAWoKEAkQChAFEAMQBA==")
        XCTAssertEqual(SearchFilter.albums.params, "EgWKAQIYAWoKEAkQChAFEAMQBA==")
        XCTAssertEqual(SearchFilter.artists.params, "EgWKAQIgAWoKEAkQChAFEAMQBA==")
        XCTAssertEqual(SearchFilter.playlists.params, "EgWKAQIoAWoKEAkQChAFEAMQBA==")
        XCTAssertEqual(SearchFilter.allCases.map(\.label), ["All", "Songs", "Videos", "Albums", "Artists", "Playlists"])
    }

    func testSearchResultsRoundTripAndHaveDistinctIds() throws {
        let song = Song(videoId: "v1", title: "T", artist: "A")
        let results: [SearchResult] = [
            .topTrack(song),
            .track(song),
            .browse(BrowseItem(browseId: "MPREb_1", title: "Album", subtitle: "Album • A", thumbnailUrl: nil, type: .album)),
        ]
        let decoded = try JSONDecoder().decode([SearchResult].self, from: JSONEncoder().encode(results))
        XCTAssertEqual(decoded, results)
        XCTAssertEqual(Set(results.map(\.id)).count, 3)
        XCTAssertEqual(results[1].song, song)
        XCTAssertNil(results[2].song)
    }

    // MARK: Library and detail models

    func testAccountChannelKeyPrefersPageIdThenDataSyncIdThenName() {
        XCTAssertEqual(AccountChannel(name: "Brand", subtitle: "", thumbnailUrl: nil, pageId: "p", dataSyncId: "d", activeOnWeb: false).key, "p")
        XCTAssertEqual(AccountChannel(name: "Me", subtitle: "", thumbnailUrl: nil, pageId: nil, dataSyncId: "d", activeOnWeb: true).key, "d")
        XCTAssertEqual(AccountChannel(name: "Me", subtitle: "", thumbnailUrl: nil, pageId: nil, dataSyncId: nil, activeOnWeb: true).key, "Me")
    }

    func testUserPlaylistBrowseIdAddsVL() {
        XCTAssertEqual(UserPlaylist(playlistId: "PL123", title: "Mine", subtitle: "", thumbnailUrl: nil).browseId, "VLPL123")
    }

    func testPlaylistPrivacySendsYouTubesValues() {
        XCTAssertEqual(PlaylistPrivacy.allCases.map(\.apiValue), ["PRIVATE", "UNLISTED", "PUBLIC"])
        XCTAssertEqual(PlaylistPrivacy.allCases.map(\.label), ["Private", "Unlisted", "Public"])
    }

    func testLibraryPageIsEmptyOnlyWithNothingInIt() {
        XCTAssertTrue(LibraryPage(likedSongs: [], librarySongs: [], shelves: []).isEmpty)
        XCTAssertFalse(LibraryPage(likedSongs: [], librarySongs: [], shelves: [HomeShelf(title: "Albums", items: [])]).isEmpty)
    }

    func testDetailPageWithLoadStateRoundTrips() throws {
        let pages = [
            DetailPage(browseId: "MPREb_1", title: "Album", subtitle: "A", thumbnailUrl: nil, songs: .loading, type: .album),
            DetailPage(browseId: "VLPL1", title: "List", subtitle: "B", thumbnailUrl: "x", songs: .success([Song(videoId: "v", title: "T", artist: "A")]),
                       type: .playlist, library: LibraryState(playlistId: "PL1", saved: true)),
            DetailPage(browseId: "UC1", title: "Artist", subtitle: "", thumbnailUrl: nil, songs: .error("Offline"), type: .artist,
                       subscription: SubscriptionState(channelId: "UC1", subscribed: false)),
        ]
        XCTAssertEqual(try JSONDecoder().decode([DetailPage].self, from: JSONEncoder().encode(pages)), pages)
    }

    func testLoadStateAccessors() {
        let loaded: LoadState<[Int]> = .success([1, 2])
        XCTAssertEqual(loaded.value, [1, 2])
        XCTAssertEqual(loaded.map(\.count).value, 2)
        XCTAssertTrue(LoadState<Int>.loading.isLoading)
        XCTAssertEqual(LoadState<Int>.error("No").errorMessage, "No")
        XCTAssertNil(LoadState<Int>.error("No").value)
    }

    func testEnumRawValuesAreTheAndroidNames() {
        XCTAssertEqual(QueueTier.allCases.map(\.rawValue), ["USER_QUEUE", "CONTEXT", "AUTOPLAY"])
        XCTAssertEqual(BrowseType.allCases.map(\.rawValue), ["ALBUM", "ARTIST", "PLAYLIST", "OTHER"])
        XCTAssertEqual(LikeStatus.allCases.map(\.rawValue), ["LIKE", "DISLIKE", "INDIFFERENT"])
        XCTAssertEqual(PlaybackSourceType.sharedLink.rawValue, "SHARED_LINK")
    }
}
