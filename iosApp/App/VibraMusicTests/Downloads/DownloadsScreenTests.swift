import VibraMusicCore
import Downloads
import SwiftUI
import XCTest
@testable import Vibra Music

/// PORTING §2.6 "Downloads screen": Songs / Artists / Albums tabs, search, sort, and multi-select
/// delete that frees the storage.
@MainActor
final class DownloadsScreenTests: XCTestCase {
    /// The done criterion: select three downloads, delete them, and the storage is freed.
    func testSelectingThreeDownloadsAndDeletingThemFreesTheirStorage() async throws {
        let library = makeTestDownloadLibrary(self)
        let songs = try await importTones(4, into: library, test: self)
        let service = FakeDownloadsService(library: library)
        let before = library.storageUsage()
        let files = songs.compactMap { $0.localUri.flatMap(URL.init(string:)) }
        XCTAssertEqual(files.count, 4)
        XCTAssertTrue(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        let state = LocalMusicState(isDownloads: true)
        let listed = service.songs(in: .downloads)
        // Hold the first row to start selecting, then tap two more.
        XCTAssertTrue(state.hold(listed[0], fromDrillDown: false))
        XCTAssertTrue(state.tap(listed[1]))
        XCTAssertTrue(state.tap(listed[2]))
        XCTAssertTrue(state.isSelecting)
        let chosen = state.takeSelection(from: listed)
        XCTAssertEqual(chosen.count, 3)
        XCTAssertFalse(state.isSelecting, "Delete clears the selection bar")

        let deletion = service.delete(chosen.map(\.videoId))
        XCTAssertEqual(deletion.deletedFiles, 3)
        XCTAssertGreaterThan(deletion.freedBytes, 0)
        let after = library.storageUsage()
        XCTAssertEqual(before.totalBytes - after.totalBytes, deletion.freedBytes, "the space reported is the space freed")
        XCTAssertEqual(service.songs(in: .downloads).map(\.videoId), listed.filter { !chosen.contains($0) }.map(\.videoId))
        for song in chosen {
            let file = try XCTUnwrap(song.localUri.flatMap(URL.init(string:)))
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent) is gone")
        }
    }

    func testTheTabsGroupSortAndFilterTheFolder() {
        let songs = [
            DownloadsFixtures.song("a", "Instant Crush", album: "Random Access Memories", added: 30),
            DownloadsFixtures.song("b", "Get Lucky", album: "Random Access Memories", added: 10),
            DownloadsFixtures.song("c", "Blinding Lights", artist: "The Weeknd", album: "After Hours", added: 20),
            DownloadsFixtures.song("d", "Loose single", artist: "The Weeknd", added: 5),
        ]
        let byTitle = LocalMusicListing(songs: songs, collections: [], sort: .titleAsc, query: "")
        XCTAssertEqual(byTitle.songs.map(\.title), ["Blinding Lights", "Get Lucky", "Instant Crush", "Loose single"])
        XCTAssertEqual(byTitle.artists.map(\.name), ["Daft Punk", "The Weeknd"])
        // A track with no album tag belongs to the Songs tab alone.
        XCTAssertEqual(byTitle.albums.map(\.title), ["After Hours", "Random Access Memories"])

        let newest = LocalMusicListing(songs: songs, collections: [], sort: .dateAdded, query: "")
        XCTAssertEqual(newest.songs.map(\.videoId), ["a", "c", "b", "d"])

        let filtered = LocalMusicListing(songs: songs, collections: [], sort: .titleAsc, query: "weeknd")
        XCTAssertEqual(filtered.songs.map(\.videoId), ["c", "d"], "songs match on the artist too")
        XCTAssertEqual(filtered.artists.map(\.name), ["The Weeknd"])
        XCTAssertEqual(filtered.albums.map(\.title), ["After Hours"], "albums match on their artist")

        // A release downloaded whole leads, and claims its tag grouping.
        let ram = DownloadedCollection(id: "MPREb_1", title: "Random Access Memories", subtitle: "Daft Punk",
                                       thumbnailUrl: "https://example.com/ram.jpg", playlist: false, songs: [songs[1], songs[0]])
        let withRelease = LocalMusicListing(songs: songs, collections: [ram], sort: .titleAsc, query: "")
        XCTAssertEqual(withRelease.albums.map(\.key), ["asked:MPREb_1", "tagged:After Hours"])
        XCTAssertEqual(albumCredit(withRelease.albums[0]), "Daft Punk · " + L10n.songCountPlural(2))
    }

    /// A new download landing at the top of "newest first" leaves every other row's identity alone,
    /// so those rows keep their state rather than being rebuilt. A track listed twice still
    /// makes two rows.
    func testANewDownloadAtTheTopLeavesTheOtherRowsIdentitiesAlone() {
        let a = DownloadsFixtures.song("a", "A"), b = DownloadsFixtures.song("b", "B")
        let before = IndexedSong.list([a, b])
        let after = IndexedSong.list([DownloadsFixtures.song("new", "New"), a, b])
        XCTAssertEqual(after.dropFirst().map(\.id), before.map(\.id))
        XCTAssertEqual(after.map(\.index), [0, 1, 2], "each row still knows its place, for the tap that plays from it")

        let twice = IndexedSong.list([a, b, a])
        XCTAssertEqual(Set(twice.map(\.id)).count, 3)
    }

    func testHoldingSelectsOnlyInTheDownloadsFolderAndBackUndoesInOrder() {
        let song = DownloadsFixtures.song("a", "A", album: "X")
        let album = LocalLibraryListing.albums(in: [song], collections: [])[0]

        let localMusic = LocalMusicState(isDownloads: false)
        XCTAssertFalse(localMusic.hold(song, fromDrillDown: false), "elsewhere a hold opens the song menu")
        XCTAssertFalse(localMusic.hold(album))
        XCTAssertFalse(localMusic.tap(song), "a tap plays")

        let downloads = LocalMusicState(isDownloads: true)
        downloads.select(.albums)
        downloads.tap(album)
        XCTAssertEqual(downloads.drillDown?.label, "X")
        // Holding a row from the drill-down keeps the drill-down; Back first clears the selection.
        XCTAssertTrue(downloads.hold(song, fromDrillDown: true))
        XCTAssertTrue(downloads.inDrillDown)
        XCTAssertTrue(downloads.back())
        XCTAssertFalse(downloads.isSelecting)
        XCTAssertTrue(downloads.inDrillDown)
        XCTAssertTrue(downloads.back())
        XCTAssertFalse(downloads.inDrillDown)
        XCTAssertFalse(downloads.back(), "nothing left to undo: Back leaves the page")

        // Holding a song on the Songs tab puts the page back on Songs.
        downloads.select(.artists)
        XCTAssertTrue(downloads.hold(song, fromDrillDown: false))
        XCTAssertEqual(downloads.tab, .songs)
    }

    func testAlbumSelectionIsKeptApartFromTheTracksItShares() throws {
        let shared = DownloadsFixtures.song("s", "Shared")
        let other = DownloadsFixtures.song("o", "Other")
        let groups = LocalLibraryListing.albums(in: [shared, other], collections: [
            DownloadedCollection(id: "1", title: "Album", subtitle: "", thumbnailUrl: nil, playlist: false, songs: [shared]),
            DownloadedCollection(id: "2", title: "Mix", subtitle: "", thumbnailUrl: nil, playlist: true, songs: [shared, other]),
        ])
        let album = try XCTUnwrap(groups.first { $0.key == "asked:1" })
        let playlist = try XCTUnwrap(groups.first { $0.key == "asked:2" })
        let state = LocalMusicState(isDownloads: true)

        XCTAssertTrue(state.hold(playlist))
        XCTAssertTrue(state.isSelected(playlist))
        XCTAssertFalse(state.isSelected(album), "holding a playlist doesn't appear to select an album sharing a track")
        state.tap(playlist)
        XCTAssertFalse(state.isSelecting)

        state.selectAll([shared, other])
        XCTAssertTrue(state.allSelected(of: [shared, other]))
        XCTAssertEqual(state.takeSelection(from: [other, shared]).map(\.videoId), ["o", "s"], "in list order")
    }

    /// Render smoke test: the Downloads folder hosted in a navigation stack, with its search field,
    /// tabs and every row drawn; the Albums tab and grid view draw too.
    func testTheDownloadsScreenRendersItsTabsAndRows() async throws {
        let library = makeTestDownloadLibrary(self)
        _ = try await importTones(3, into: library, test: self)
        let service = FakeDownloadsService(library: library)
        let (model, _) = makeDownloadsTestModel(self, service: service)

        let controller = await host(DownloadsScreen(), model: model, settle: 0.8)
        assertDrew(controller)
        XCTAssertEqual(service.folderReads.first, .downloads, "the page read its folder when it appeared")
        let listing = LocalMusicListing(songs: service.songs(in: .downloads), collections: [], sort: model.settings.downloadedMusicSort, query: "")
        XCTAssertEqual(listing.songs.map(\.title), ["Tone 1", "Tone 2", "Tone 3"])

        model.settings.downloadedMusicViewType = .grid
        let grid = await host(DownloadsScreen(), model: model, colorScheme: .light, settle: 0.8)
        assertDrew(grid)
        let local = await host(DownloadsScreen(folder: .localMusic), model: model, settle: 0.6)
        assertDrew(local)
        XCTAssertTrue(service.folderReads.contains(.localMusic))
    }

    /// The shell's `.localMusic` route reaches the Local Music folder, not Downloads:
    /// the destination — not just the browse-id mapping — reads `local:all`'s folder.
    func testTheLocalMusicRouteReadsTheLocalMusicFolder() async throws {
        let library = makeTestDownloadLibrary(self)
        // One track, so the folder isn't empty: an empty Local Music page opens the Files picker,
        // which this test isn't about and shouldn't present.
        _ = try await importTones(1, into: library, test: self)
        let service = FakeDownloadsService(library: library)
        let (model, _) = makeDownloadsTestModel(self, service: service)

        let controller = await host(RouteDestination(route: .localMusic), model: model, settle: 0.6)
        assertDrew(controller)
        XCTAssertTrue(service.folderReads.contains(.localMusic), "the Local music route read the Local Music folder")
        XCTAssertFalse(service.folderReads.contains(.downloads), "and never the Downloads folder")
    }

    func testAnEmptyDownloadsFolderSaysSo() async {
        let service = FakeDownloadsService(library: makeTestDownloadLibrary(self))
        let (model, _) = makeDownloadsTestModel(self, service: service)
        let controller = await host(DownloadsScreen(), model: model, settle: 0.6)
        assertDrew(controller)
        XCTAssertTrue(service.songs(in: .downloads).isEmpty)
        XCTAssertEqual(LocalFolder.downloads.emptyMessage, DownloadsText.noDownloadedTracks)
        XCTAssertNotEqual(DownloadsText.noDownloadedTracks, "no_downloaded_tracks", "the string table is bundled")
    }

    func testFilesImportFeedsTheSameLibrary() async throws {
        let library = makeTestDownloadLibrary(self)
        let service = FakeDownloadsService(library: library)
        let directory = makeTemporaryDirectory(self)
        let file = try TestAudio.tone(seconds: 2, format: .m4a, in: directory, name: "Picked in Files")
        let result = await service.importFiles(at: [file])
        XCTAssertEqual(result.imported.count, 1)
        XCTAssertEqual(service.songs(in: .localMusic).map(\.title), ["Picked in Files"])
        XCTAssertTrue(LocalMusicImporter.isImportedID(result.imported[0].videoId))
    }
}
