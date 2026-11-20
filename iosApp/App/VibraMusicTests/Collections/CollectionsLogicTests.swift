import VibraMusicCore
import InnerTube
import XCTest
@testable import Vibra Music

/// The pure rules of DetailScreen.kt and LibraryScreen.kt: sorting, filtering, the header's two
/// lines, the running-time footer, and the Library shelves' pin / sort / five-card rules.
@MainActor
final class SortOptionsTests: XCTestCase {
    private let songs = CollectionsFixtures.playlistSongs

    /// PORTING.md "Sort options" done criterion: sorting a playlist by Title A–Z reorders it.
    func testSortingAPlaylistByTitleAToZReordersIt() {
        XCTAssertEqual(songs.sortedForDetail(.titleAsc).map(\.title), ["apple", "Mango", "Zebra"])
        XCTAssertEqual(songs.sortedForDetail(.titleDesc).map(\.title), ["Zebra", "Mango", "apple"])
        XCTAssertEqual(songs.sortedForDetail(.default).map(\.title), ["Zebra", "apple", "Mango"])
    }

    /// A catalogue row has no added date: its place in the playlist stands in for one, so newest
    /// first is the running order reversed; dated rows (downloads) sort by their date.
    func testDateAddedUsesTheRunningOrderUnlessRowsAreDated() {
        XCTAssertEqual(songs.sortedForDetail(.dateAddedDesc).map(\.videoId), ["p3", "p2", "p1"])
        XCTAssertEqual(songs.sortedForDetail(.dateAddedAsc).map(\.videoId), ["p1", "p2", "p3"])

        var dated = songs
        dated[0].localDateAddedSeconds = 300
        dated[1].localDateAddedSeconds = 100
        dated[2].localDateAddedSeconds = 200
        XCTAssertEqual(dated.sortedForDetail(.dateAddedDesc).map(\.videoId), ["p1", "p3", "p2"])
        XCTAssertEqual(dated.sortedForDetail(.dateAddedAsc).map(\.videoId), ["p2", "p3", "p1"])
    }

    /// The sort is kept per page, and the date row flips direction, landing on newest first.
    func testTheSortIsRememberedPerPageAndTheDateRowFlips() {
        let settings = makeTestSettings()
        settings.setDetailSongSort(.titleAsc, for: "VLPLa")
        XCTAssertEqual(settings.detailSongSort(for: "VLPLa"), .titleAsc)
        XCTAssertEqual(settings.detailSongSort(for: "VLPLb"), .default)
        XCTAssertEqual(SongSort.titleAsc.flippedDateDirection, .dateAddedDesc)
        XCTAssertEqual(SongSort.dateAddedDesc.flippedDateDirection, .dateAddedAsc)
        XCTAssertEqual(SongSort.dateAddedAsc.flippedDateDirection, .dateAddedDesc)
    }

    /// A Library grid sorts on the card title; pinned cards lead unless an explicit sort is chosen.
    func testALibraryGridSortsByTitleAndAnExplicitSortOutranksPins() {
        let shelf = HomeShelf(title: "Playlists", items: [
            CollectionsFixtures.card("VLb", "beta"), CollectionsFixtures.card("VLa", "Alpha"), CollectionsFixtures.card("VLc", "Gamma"),
        ])
        XCTAssertEqual(shelf.pinnedFirst(["VLc"]).items.map(\.title), ["Gamma", "beta", "Alpha"])
        XCTAssertEqual(shelf.pinnedFirst(["VLc"]).sortedForLibrary(.titleAsc).items.map(\.title), ["Alpha", "beta", "Gamma"])
        XCTAssertEqual(shelf.sortedForLibrary(.titleDesc).items.map(\.title), ["Gamma", "beta", "Alpha"])
        XCTAssertEqual(shelf.sortedForLibrary(.default).items.map(\.title), ["beta", "Alpha", "Gamma"])
    }
}

@MainActor
final class DetailPageLogicTests: XCTestCase {
    /// The filter keeps each row's place in the full list, so an album's track numbers stay the
    /// album's; it matches title, artist and album, ignoring case.
    func testFilteringKeepsTheReleasesOwnTrackNumbers() {
        let matches = CollectionsFixtures.albumSongs.matching("love")
        XCTAssertEqual(matches.map(\.offset), [2])
        XCTAssertEqual(matches.map(\.element.title), ["Digital Love"])
        XCTAssertEqual(CollectionsFixtures.albumSongs.matching("  ").count, 4)
        XCTAssertEqual(CollectionsFixtures.albumSongs.matching("DAFT").count, 4)
    }

    /// The page's track list is built once per change of its songs, sort or filter. The body
    /// runs again as the bar takes the title, as other pages fill in and as the queue moves on, and
    /// none of those may sort the release again.
    func testThePagesTrackListIsBuiltOncePerChangeOfWhatItIsBuiltFrom() {
        let memo = ViewMemo<DetailTrackList.Input, DetailTrackList>()
        var builds = 0
        func list(_ input: DetailTrackList.Input) -> DetailTrackList {
            memo.value(for: input) { input in
                builds += 1
                return DetailTrackList(input)
            }
        }
        let input = DetailTrackList.Input(songs: CollectionsFixtures.playlistSongs, suggested: [], sort: .titleAsc, query: "")
        XCTAssertEqual(list(input).rows.map(\.title), ["apple", "Mango", "Zebra"])
        XCTAssertEqual(list(input).rows.map(\.title), ["apple", "Mango", "Zebra"])
        XCTAssertEqual(builds, 1, "the same songs, sort and filter reuse the list")

        var filtered = input
        filtered.query = "an"
        let narrowed = list(filtered)
        XCTAssertEqual(narrowed.rows.map(\.title), ["Mango"])
        XCTAssertEqual(narrowed.numbers["p3"], 3, "a row keeps its place on the release through a sort and a filter")
        XCTAssertEqual(builds, 2)
    }

    /// "Album • Daft Punk • 2001" becomes the credit and "ALBUM • 2001 • 4 TRACKS", with the
    /// page's play time appended once its rows know theirs.
    func testTheSubtitleSplitsIntoTheCreditAndTheMetadataLine() {
        let lines = DetailText.headerLines(subtitle: "Album • Daft Punk • 2001", type: .album, trackCount: 4)
        XCTAssertEqual(lines.credit, "Daft Punk")
        XCTAssertTrue(lines.meta.hasPrefix("ALBUM • 2001 • "), lines.meta)
        XCTAssertTrue(lines.meta.contains("4"), lines.meta)

        let timed = DetailText.headerLines(subtitle: "Album • Daft Punk • 2001", type: .album, trackCount: 2,
                                           playtime: "41 min")
        XCTAssertEqual(timed.meta, "ALBUM • 2001 • 2 TRACKS • 41 MIN")

        let bare = DetailText.headerLines(subtitle: "Travis Scott", type: .playlist, trackCount: 0)
        XCTAssertEqual(bare.credit, "Travis Scott")
        XCTAssertEqual(bare.meta, L10n.playlist.uppercased(with: LanguageBundle.locale))
    }

    /// DetailScreen.kt's `playtime`: the rows' durations summed, "41 min" under an hour and
    /// "1h 25m" over it, and nothing at all when no row carries a duration.
    func testThePlaytimeIsTheRowsDurationsSummedOrNothing() {
        XCTAssertEqual(DetailText.seconds("3:45"), 225)
        XCTAssertEqual(DetailText.seconds("1:02:33"), 3753)
        XCTAssertEqual(DetailText.seconds("live"), 0)
        XCTAssertEqual(CollectionsFixtures.albumSongs.playtime, "17 min")

        let underAnHour = [
            CollectionsFixtures.song("a", "A", duration: "20:30"),
            CollectionsFixtures.song("b", "B", duration: "20:30"),
        ]
        XCTAssertEqual(underAnHour.playtime, "41 min")

        let overAnHour = [
            CollectionsFixtures.song("a", "A", duration: "42:30"),
            CollectionsFixtures.song("b", "B", duration: "42:30"),
        ]
        XCTAssertEqual(overAnHour.playtime, "1h 25m")

        XCTAssertNil([Song(videoId: "x", title: "x", artist: "")].playtime)
    }

    func testShareLinksAreYouTubeMusicsOwn() {
        XCTAssertEqual(DetailText.shareURL(browseId: "VLPLabc", type: .playlist)?.absoluteString, "https://music.youtube.com/playlist?list=PLabc")
        XCTAssertEqual(DetailText.shareURL(browseId: "MPREb_x", type: .album)?.absoluteString, "https://music.youtube.com/browse/MPREb_x")
        XCTAssertEqual(DetailText.shareURL(videoId: "abc")?.absoluteString, "https://music.youtube.com/watch?v=abc")
        XCTAssertEqual(DetailText.leadingNumber("9.8M subscribers"), "9.8M")
    }
}

@MainActor
final class LibraryShelfLogicTests: XCTestCase {
    /// A row shows five slots at most, the New playlist tile counting against the cap, and offers
    /// "Show all" only when something didn't fit.
    func testAShelfRowStopsAtFiveCardsWithShowAllBeyond() {
        let five = HomeShelf(title: "Albums", items: (1...5).map { CollectionsFixtures.card("MPREb_\($0)", "A\($0)") })
        XCTAssertEqual(five.libraryRow(hasLeadingCard: false).items.count, 5)
        XCTAssertFalse(five.libraryRow(hasLeadingCard: false).showsShowAll)
        XCTAssertEqual(five.libraryRow(hasLeadingCard: true).items.count, 4)
        XCTAssertTrue(five.libraryRow(hasLeadingCard: true).showsShowAll)
    }

    /// Pinned playlists lead the shelf in pin order; the rest keep YouTube's order behind them.
    func testPinnedPlaylistsComeFirstInPinOrder() {
        let shelf = HomeShelf(title: "Playlists", items: [
            CollectionsFixtures.card("VLLM", "Liked Music"), CollectionsFixtures.card("VL1", "One"),
            CollectionsFixtures.card("VL2", "Two"), CollectionsFixtures.card("VL3", "Three"),
        ])
        XCTAssertEqual(shelf.pinnedFirst(["VL3", "VL1"]).items.map(\.browseId), ["VL3", "VL1", "VLLM", "VL2"])
        XCTAssertEqual(shelf.pinnedFirst(["VLgone"]).items.map(\.browseId), ["VLLM", "VL1", "VL2", "VL3"])
    }

    /// The On device shelf: the two device folders, the two shares (saying whether they are set
    /// up), then each playlist downloaded whole.
    func testTheOnDeviceShelfListsTheFoldersSharesAndDownloadedPlaylists() {
        let settings = makeTestSettings()
        let shelf = LibraryShelves.onDevice(settings: settings, downloadedPlaylists: [
            .init(id: "VLPLx", title: "Road trip", subtitle: "", playlist: true, videoIds: ["a"]),
        ])
        XCTAssertEqual(shelf.items.map(\.browseId), [LocalBrowseID.downloads, LocalBrowseID.all, LocalBrowseID.offlineBackup,
                                                     LocalBrowseID.webDAV, LocalBrowseID.smb, LocalBrowseID.playlistPrefix + "VLPLx"])
        XCTAssertEqual(shelf.items[3].subtitle, L10n.webdavNotConfigured)
        XCTAssertEqual(shelf.items[5].subtitle, L10n.downloadedPlaylist)
        // Card → destination: each On device card opens its own page, and the Local music card
        // (`local:all`) opens Local music, not the Downloads folder.
        let destinations: [(browseId: String, route: AppRoute)] = [
            (shelf.items[0].browseId!, .downloads),
            (shelf.items[1].browseId!, .localMusic),
            (shelf.items[2].browseId!, .offlineBackup),
            (shelf.items[3].browseId!, .networkLibrary(.webDAV)),
            (shelf.items[4].browseId!, .networkLibrary(.smb)),
        ]
        for (browseId, route) in destinations {
            XCTAssertEqual(AppRoute.browse(browseId), route, "\(browseId) opens \(route)")
        }
    }

    func testTheGridFitsTwoToFiveColumns() {
        XCTAssertEqual(CollectionsMetrics.gridColumns(available: 361), 2)
        XCTAssertEqual(CollectionsMetrics.gridColumns(available: 700), 4)
        XCTAssertEqual(CollectionsMetrics.gridColumns(available: 2000), 5)
        XCTAssertEqual(CollectionsMetrics.gridColumns(available: 100), 2)
    }
}
