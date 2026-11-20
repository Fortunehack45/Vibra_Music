import VibraMusicCore
import Downloads
import NetworkLibrary
import SwiftUI
import XCTest
@testable import Vibra Music

/// PORTING §2.7 "SMB network library" and "WebDAV network library": browse the server as a library,
/// say why a listing failed, and upload downloads to WebDAV (answering name clashes).
@MainActor
final class NetworkLibraryScreenTests: XCTestCase {
    private let nas = SmbCredentials(host: "nas.local", share: "music", username: "me", password: "pw")

    /// SMB, through the real repository over an in-memory share: folders become albums, the FLAC is
    /// a row with its sidecar cover, and it is a track the player streams from the share.
    func testAnSmbShareListsItsFlacFilesAsAlbums() async throws {
        let share = MemorySmbShare(files: [
            "Daft Punk/Discovery/01 One More Time.flac": Data(repeating: 1, count: 64),
            "Daft Punk/Discovery/cover.jpg": Data(repeating: 2, count: 16),
            "Daft Punk/Discovery/notes.txt": Data(repeating: 3, count: 8),
        ])
        let pool = SmbConnectionPool(credentials: nas, factory: MemorySmbFactory(share: share))
        let repository = SmbRepository(credentials: nas, client: SmbClient(credentials: nas, pool: pool))
        let state = await NetworkListing.state(isConfigured: repository.isConfigured, emptyMessage: L10n.smbEmpty,
                                               songs: { await repository.getSongs() },
                                               probe: { try await repository.testConnection() })
        let songs = try XCTUnwrap(state.value, "\(state)")
        XCTAssertEqual(songs.count, 1, "only audio files are rows")
        let flac = songs[0]
        XCTAssertTrue(SmbConfig.isSmbId(flac.videoId))
        XCTAssertEqual(flac.albumName, "Discovery")
        XCTAssertTrue(flac.thumbnailUrl?.hasSuffix("cover.jpg") == true, flac.thumbnailUrl ?? "nil")
        XCTAssertTrue(flac.localUri.map(SmbConfig.isSmbUrl) == true, "the row streams from the share")

        let listing = LocalMusicListing(songs: songs, collections: [], sort: .titleAsc, query: "")
        XCTAssertEqual(listing.albums.map(\.title), ["Discovery"])
    }

    /// A share that refuses the login isn't an empty share: the page names the cause.
    func testAnSmbLoginFailureIsReportedRatherThanAnEmptyShare() async {
        let pool = SmbConnectionPool(credentials: nas, factory: MemorySmbFactory(failure: SmbError.transport("Access denied")))
        let repository = SmbRepository(credentials: nas, client: SmbClient(credentials: nas, pool: pool))
        let state = await NetworkListing.state(isConfigured: true, emptyMessage: L10n.smbEmpty,
                                               songs: { await repository.getSongs() },
                                               probe: { try await repository.testConnection() })
        guard case .error(let message) = state else { return XCTFail("\(state)") }
        XCTAssertNotEqual(message, L10n.smbEmpty)
        XCTAssertTrue(message.contains("Access denied"), message)

        let unconfigured = await NetworkListing.state(isConfigured: false, emptyMessage: L10n.webdavEmpty,
                                                      songs: { XCTFail("not listed"); return [] }, probe: {})
        guard case .error(let empty) = unconfigured else { return XCTFail("\(unconfigured)") }
        XCTAssertEqual(empty, L10n.webdavEmpty)

        let reachableButEmpty = await NetworkListing.state(isConfigured: true, emptyMessage: L10n.webdavEmpty,
                                                           songs: { [] }, probe: {})
        guard case .error(let emptyServer) = reachableButEmpty else { return XCTFail("\(reachableButEmpty)") }
        XCTAssertEqual(emptyServer, L10n.webdavEmpty)
    }

    /// Render smoke test: the WebDAV page lists the server's tracks under the same tabs, and an
    /// SMB page that failed shows the reason under the tab row.
    func testTheNetworkLibraryScreensRenderTheListingOrItsError() async {
        let service = FakeDownloadsService(library: makeTestDownloadLibrary(self))
        let track = Song(videoId: WebDavConfig.idFor(fileUrl: "https://dav.example/Music/Album/Song.flac"),
                         title: "Song", artist: "Artist", albumName: "Album")
        service.remote[.webDAV] = .success([track])
        service.remote[.smb] = .error("Access denied")
        let (model, _) = makeDownloadsTestModel(self, service: service)

        let webdav = await host(NetworkLibraryScreen(kind: .webDAV), model: model, settle: 0.6)
        assertDrew(webdav)
        XCTAssertEqual(service.listed, [.webDAV], "the page listed its server when it appeared")

        let smb = await host(NetworkLibraryScreen(kind: .smb), model: model, colorScheme: .light, settle: 0.6)
        assertDrew(smb)
        XCTAssertEqual(service.listed, [.webDAV, .smb])
        // Outside the Downloads folder a hold opens the song menu rather than selecting.
        XCTAssertFalse(LocalMusicState(isDownloads: false).hold(track, fromDrillDown: false))
    }

    /// The WebDAV done criterion's last step: upload a download. A name clash waits on the prompt,
    /// the answer is applied, the summary is said, and an open WebDAV page lists again.
    func testUploadingADownloadAsksAboutAClashAndReportsTheSummary() async throws {
        let service = FakeDownloadsService(library: makeTestDownloadLibrary(self))
        service.conflictOnUpload = true
        let (model, context) = makeDownloadsTestModel(self, service: service)
        let songs = [DownloadsFixtures.song("a", "One"), DownloadsFixtures.song("b", "Two")]

        let upload = Task { await context.upload(songs) }
        for _ in 0..<50 where context.conflict == nil { try await Task.sleep(for: .milliseconds(20)) }
        let conflict = try XCTUnwrap(context.conflict, "the batch waits on the clash")
        XCTAssertEqual(conflict.fileName, "One.m4a")
        XCTAssertEqual(conflict.remaining, 1, "so the prompt offers Apply to all")

        let prompt = await host(WebDavConflictPrompt(fileName: conflict.fileName, showApplyToAll: true,
                                                     applyToAll: .constant(false), onChoose: { _ in }),
                                model: model, inNavigation: false)
        assertDrew(prompt)

        context.resolveConflict(.overwrite)
        await upload.value
        XCTAssertNil(context.conflict)
        XCTAssertEqual(service.uploaded.map { $0.map(\.videoId) }, [["a", "b"]])
        XCTAssertEqual(model.player.notice?.message, L10n.webdavUploadSummary(2, 0, 0))
        XCTAssertEqual(context.webDAVRevision, 1, "an open WebDAV page lists again")
    }

    /// A second upload started while the first waits on a clash waits its turn: the first clash
    /// keeps its prompt and gets the user's answer, not a silent skip.
    func testASecondUploadWaitsForTheFirstOnesClash() async throws {
        let service = FakeDownloadsService(library: makeTestDownloadLibrary(self))
        service.conflictOnUpload = true
        let (_, context) = makeDownloadsTestModel(self, service: service)

        let first = Task { await context.upload([DownloadsFixtures.song("a", "One")]) }
        for _ in 0..<50 where context.conflict == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(context.conflict?.fileName, "One.m4a")
        let second = Task { await context.upload([DownloadsFixtures.song("b", "Two")]) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(context.conflict?.fileName, "One.m4a", "the first clash is still the one asked about")

        context.resolveConflict(.overwrite)
        await first.value
        for _ in 0..<50 where context.conflict?.fileName != "Two.m4a" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(context.conflict?.fileName, "Two.m4a")
        context.resolveConflict(.overwrite)
        await second.value
        XCTAssertEqual(service.uploaded.map { $0.map(\.videoId) }, [["a"], ["b"]])
    }
}
