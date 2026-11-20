import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import Downloads

/// Ports DownloadSessionTest's first half: whether the user has been told how a batch went. A
/// visibility rule that is off by one visit is either an indicator that can't be dismissed or one
/// that was never seen, and neither is visible from the code.
@MainActor
final class DownloadSessionIndicatorTests: XCTestCase {
    private var session: DownloadSession!

    override func setUp() async throws {
        session = DownloadSession()
    }

    func testNothingAskedForMeansNoIndicatorAtAll() {
        XCTAssertFalse(session.state.visible)
    }

    func testAnIndicatorSurvivesTheBatchFinishingAndGoesOnBeingSeen() {
        session.queued(song("a"))
        XCTAssertTrue(session.state.visible)

        session.done("a")
        // A download is started and walked away from, so the moment it finishes is the moment
        // nobody is watching.
        XCTAssertTrue(session.state.visible)
        XCTAssertFalse(session.state.busy)

        session.markSeen()
        XCTAssertFalse(session.state.visible)
    }

    func testLookingInHalfwayThroughDoesNotSignTheBatchOff() {
        session.queued(song("a"))
        session.queued(song("b"))
        session.done("a")

        // Opened while "b" is still going: checking in, not confirming an outcome.
        session.markSeen()
        XCTAssertTrue(session.state.visible)

        session.done("b")
        XCTAssertTrue(session.state.visible)

        session.markSeen()
        XCTAssertFalse(session.state.visible)
    }

    func testANewBatchAfterASeenOneBringsTheIndicatorBack() {
        session.queued(song("a"))
        session.done("a")
        session.markSeen()
        XCTAssertFalse(session.state.visible)

        session.queued(song("b"))
        XCTAssertTrue(session.state.visible)
    }

    func testAFailureIsSomethingToBeToldAboutNotSomethingToHide() {
        session.queued(song("a"))
        session.failed("a", reason: "Download failed — check your connection")

        XCTAssertTrue(session.state.visible)
        XCTAssertFalse(session.state.busy)
        XCTAssertEqual(session.state.failed, 1)
    }

    func testCancellingTheOnlyDownloadLeavesNothingToReport() {
        session.queued(song("a"))
        session.forget("a")
        XCTAssertFalse(session.state.visible)
    }

    /// A retry is the same errand, not a second one.
    func testReAskingForAFailedTrackReplacesItsRowRatherThanAddingOne() {
        session.queued(song("a"), from: "Motion")
        session.failed("a", reason: "nope")
        session.queued(song("a"))

        XCTAssertEqual(session.state.items.count, 1)
        XCTAssertEqual(session.state.items.first?.progress, .queued)
        XCTAssertEqual(session.state.items.first?.from, "Motion", "a retry keeps the release it came from")
        XCTAssertEqual(session.state.failed, 0)
    }

    func testProgressCountsSettledTracksWholeHoweverTheySettled() {
        for id in ["a", "b", "c", "d"] { session.queued(song(id)) }
        XCTAssertEqual(session.state.fraction, 0, accuracy: 0.001)

        session.done("a")
        // A failure is not progress, but it is finished — a bar that can never fill because one
        // track died reads as a download still going.
        session.failed("b", reason: "nope")
        session.running("c", fraction: 0.5)
        XCTAssertEqual(session.state.fraction, 0.625, accuracy: 0.001)
    }

    func testTheCatalogueSwapCorrectsTheRowRatherThanAddingAnother() {
        session.queued(song("vid", title: "Kesariya (Official Video)"))
        session.retitle("vid", song: song("audio", title: "Kesariya"))

        let item = try! XCTUnwrap(session.state.items.first)
        XCTAssertEqual(session.state.items.count, 1)
        // Keyed by what was tapped, titled by what is being fetched.
        XCTAssertEqual(item.videoId, "vid")
        XCTAssertEqual(item.song.title, "Kesariya")
    }

    func testRowsKeepTheOrderTheyWereAskedIn() {
        for id in ["c", "a", "b"] { session.queued(song(id)) }
        session.queued(song("a"))
        XCTAssertEqual(session.state.items.map(\.videoId), ["c", "a", "b"])
        session.clear()
        XCTAssertTrue(session.state.items.isEmpty)
    }
}

/// Ports DownloadSessionTest's second half: what release a batch was, and the On Device shelf.
@MainActor
final class DownloadCollectionTests: XCTestCase {
    private var library: DownloadLibrary!
    private var root: URL!

    override func setUp() async throws {
        root = try makeTemporaryDirectory()
        library = DownloadLibrary(store: DownloadStore(root: root))
    }

    /// As a downloaded track comes back off the Downloads page: with a file.
    private func onDisk(_ id: String, album: String? = nil) -> Song {
        var track = song(id, album: album)
        track.localUri = library.store.tracksDirectory.appending(path: "\(id).m4a").absoluteString
        return track
    }

    /// As the record of what's on disk reads: videoId to the file saved for it.
    private func onDiskMap(_ ids: String...) -> [String: String] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, "Tracks/\($0).m4a") })
    }

    /// A playlist's tracks are off different releases, and two of these name no release at all —
    /// which is why tag grouping could never put this back together.
    func testAPlaylistIsGroupedByWhatWasTappedNotByAnyTagOnItsTracks() throws {
        let target = DownloadTarget(id: "VLPL123", title: "Late night drive", thumbnailUrl: "https://example/cover.jpg", playlist: true)
        let tracks = [onDisk("a", album: "One"), onDisk("b"), onDisk("c")]
        library.rememberCollection(target, songs: tracks)

        let found = try XCTUnwrap(library.collectionsAmong(tracks).first)
        XCTAssertEqual(library.collectionsAmong(tracks).count, 1)
        XCTAssertEqual(found.title, "Late night drive")
        XCTAssertTrue(found.playlist)
        XCTAssertEqual(found.thumbnailUrl, "https://example/cover.jpg")
        XCTAssertEqual(found.songs.map(\.videoId), ["a", "b", "c"])
    }

    /// A release is worth exactly the tracks that came back, and one with none left is not worth a row.
    func testAReleaseIsOnlyDrawnForTheFilesThatAreStillThere() {
        library.rememberCollection(DownloadTarget(id: "MPREb1", title: "Motion", subtitle: "Calvin Harris"),
                                   songs: [onDisk("a"), onDisk("b"), onDisk("c")])
        XCTAssertEqual(library.collectionsAmong([onDisk("a"), onDisk("c")]).first?.songs.map(\.videoId), ["a", "c"])
        XCTAssertTrue(library.collectionsAmong([onDisk("z")]).isEmpty)
    }

    func testReDownloadingAReleaseMergesIntoTheEntryAlreadyThere() {
        let target = DownloadTarget(id: "MPREb1", title: "Motion")
        library.rememberCollection(target, songs: [onDisk("a"), onDisk("b")])
        // The second ask is a page that had since loaded a continuation.
        library.rememberCollection(target, songs: [onDisk("a"), onDisk("b"), onDisk("c")])

        let found = library.collectionsAmong([onDisk("a"), onDisk("b"), onDisk("c")])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.songs.map(\.videoId), ["a", "b", "c"])
    }

    func testACachedCollectionCoverIsRetainedWhenTheReleaseIsDownloadedAgain() throws {
        let target = DownloadTarget(id: "VLPL1", title: "Late night drive", thumbnailUrl: "https://example/cover.jpg", playlist: true)
        library.rememberCollection(target, songs: [onDisk("a")])
        try library.store.prepare()
        try Data([0xFF, 0xD8, 0xFF]).write(to: library.store.url(forRelativePath: "Artwork/cover.jpg"))
        library.rememberCollectionArtwork(id: "VLPL1", artworkPath: "Artwork/cover.jpg")
        library.rememberCollection(target, songs: [onDisk("a"), onDisk("b")])

        XCTAssertEqual(library.collections["VLPL1"]?.artworkPath, "Artwork/cover.jpg")
        XCTAssertEqual(library.collectionsAmong([onDisk("a")]).first?.thumbnailUrl,
                       library.store.url(forRelativePath: "Artwork/cover.jpg").absoluteString,
                       "the offline copy is what the card draws")
    }

    func testAnEmptyAskRecordsNothing() {
        library.rememberCollection(DownloadTarget(id: "MPREb1", title: "Motion"), songs: [])
        XCTAssertTrue(library.collections.isEmpty)
    }

    /// An album can be grouped back up off its tracks' own tags; a playlist can't, so it is the one
    /// that needs a card of its own.
    func testOnlyPlaylistsGetACardBecauseOnlyPlaylistsCannotBeInferred() {
        library.rememberCollection(DownloadTarget(id: "VLPL1", title: "Late night drive", playlist: true), songs: [onDisk("a"), onDisk("b")])
        library.rememberCollection(DownloadTarget(id: "MPREb1", title: "Motion", playlist: false), songs: [onDisk("c")])
        XCTAssertEqual(library.savedPlaylists(onDisk: onDiskMap("a", "b", "c")).map(\.title), ["Late night drive"])
    }

    /// The record is written at the tap, before a byte has been fetched.
    func testAPlaylistWithNothingDownloadedYetIsNotOnTheDevice() {
        library.rememberCollection(DownloadTarget(id: "VLPL1", title: "Late night drive", playlist: true), songs: [onDisk("a"), onDisk("b")])
        XCTAssertTrue(library.savedPlaylists(onDisk: [:]).isEmpty)
        // One track in is enough to be worth opening.
        XCTAssertEqual(library.savedPlaylists(onDisk: onDiskMap("b")).count, 1)
    }

    func testAPlaylistWhoseLastFileIsGoneLosesItsCard() {
        library.rememberCollection(DownloadTarget(id: "VLPL1", title: "Late night drive", playlist: true), songs: [onDisk("a"), onDisk("b")])
        XCTAssertEqual(library.savedPlaylists(onDisk: onDiskMap("a")).count, 1)
        XCTAssertTrue(library.savedPlaylists(onDisk: onDiskMap("unrelated")).isEmpty)
    }

    func testCardsAreInNameOrderWhateverOrderTheyWereDownloadedIn() {
        for title in ["Zephyr", "anthems", "Morning"] {
            library.rememberCollection(DownloadTarget(id: "VL\(title)", title: title, playlist: true), songs: [onDisk(title)])
        }
        XCTAssertEqual(library.savedPlaylists(onDisk: onDiskMap("Zephyr", "anthems", "Morning")).map(\.title), ["anthems", "Morning", "Zephyr"])
    }

    /// The id a downloaded playlist opens under has to survive the round trip, and the two device
    /// folders — which share the `local:` prefix — must not be mistaken for one.
    func testAPlaylistPageIdRoundTripsAndTheDeviceFoldersAreNotOne() {
        XCTAssertEqual(DownloadLibrary.recordId(of: DownloadLibrary.pageId(for: "VLPL1")), "VLPL1")
        XCTAssertNil(DownloadLibrary.recordId(of: LocalBrowseID.downloads))
        XCTAssertNil(DownloadLibrary.recordId(of: LocalBrowseID.all))
        XCTAssertNil(DownloadLibrary.recordId(of: "VLPL1"))
        XCTAssertNil(DownloadLibrary.recordId(of: LocalBrowseID.playlistPrefix))
    }

    func testCollectionsSurviveARelaunch() {
        library.rememberCollection(DownloadTarget(id: "VLPL1", title: "Late night drive", playlist: true), songs: [onDisk("a")])
        let reopened = DownloadLibrary(store: DownloadStore(root: root))
        XCTAssertEqual(reopened.collections["VLPL1"]?.videoIds, ["a"])
    }

    func testMarkRequestedAccumulatesPerRelease() {
        library.markRequested("MPREb1", videoIds: ["a", "b"])
        library.markRequested("MPREb1", videoIds: ["c"])
        library.markRequested("MPREb2", videoIds: [String]())
        XCTAssertEqual(library.requested["MPREb1"], ["a", "b", "c"])
        XCTAssertNil(library.requested["MPREb2"])
    }
}
