import VibraMusicCore
import NetworkLibrary
import SwiftUI
import XCTest
@testable import Vibra Music

/// A WebDAV track's cover, which the loader fetches with the server's login and keeps on disk.
@MainActor
final class RemoteCoverLoaderTests: XCTestCase {
    /// A row's task is cancelled when the row scrolls away. The fetch it started must still finish:
    /// a cancelled request used to come back as "no cover" and be remembered as one for the rest
    /// of the run, so the track never showed its cover again.
    func testARowThatScrollsAwayLeavesTheTrackItsCover() async throws {
        let cover = "https://dav.test/\(UUID().uuidString)/cover.jpg"
        let loader = RemoteCoverLoader(directory: makeTemporaryDirectory(self), session: CoverServer.session())
        let song = Song(videoId: WebDavConfig.idFor(fileUrl: "https://dav.test/music/a.flac"), title: "A", artist: "",
                        thumbnailUrl: cover)
        let access = RemoteLibraryAccess(smbClient: nil, smbShare: "",
                                         webdav: WebDavCredentials(url: "https://dav.test", username: "me", password: "pw"),
                                         settingsKey: "dav")

        // Cancelled before it runs: the row scrolled away before its cover arrived.
        let row = Task { await loader.coverURL(for: song, access: access) }
        row.cancel()
        _ = await row.value

        let found = await loader.coverURL(for: song, access: access)
        XCTAssertNotNil(found, "the track keeps its cover")
        XCTAssertEqual(CoverServer.requests(for: URL(string: cover)!), 1, "downloaded once")
    }

    /// A cover asked for before the server's login was set up can only be the bare address, which
    /// the server refuses. Once the settings change, the track is asked about again: that answer
    /// belonged to the old settings, not to the track.
    func testACoverMissedUnderOldSettingsIsFetchedUnderNewOnes() async throws {
        let cover = "https://dav.test/\(UUID().uuidString)/later.jpg"
        let loader = RemoteCoverLoader(directory: makeTemporaryDirectory(self), session: CoverServer.session())
        let song = Song(videoId: WebDavConfig.idFor(fileUrl: "https://dav.test/music/c.flac"), title: "C", artist: "",
                        thumbnailUrl: cover)
        let unset = RemoteLibraryAccess(smbClient: nil, smbShare: "", webdav: nil, settingsKey: "")
        let unfetched = await loader.coverURL(for: song, access: unset)
        XCTAssertEqual(unfetched?.isFileURL, false, "without the login nothing is fetched")

        let configured = RemoteLibraryAccess(smbClient: nil, smbShare: "",
                                             webdav: WebDavCredentials(url: "https://dav.test", username: "me", password: "pw"),
                                             settingsKey: "dav")
        let found = await loader.coverURL(for: song, access: configured)
        XCTAssertEqual(found?.isFileURL, true, "the new settings fetch the cover")
    }

    /// A captive portal answers the cover's URL with its sign-in page. Written to disk, the
    /// page was the track's "cover" from then on, across launches, and nothing fetched it again.
    func testACaptivePortalPageIsNotKeptAsTheCover() async throws {
        let cover = "https://dav.test/\(UUID().uuidString)/portal.jpg"
        let directory = makeTemporaryDirectory(self)
        let loader = RemoteCoverLoader(directory: directory, session: CoverServer.session())
        let song = Song(videoId: WebDavConfig.idFor(fileUrl: "https://dav.test/music/b.flac"), title: "B", artist: "",
                        thumbnailUrl: cover)
        let access = RemoteLibraryAccess(smbClient: nil, smbShare: "",
                                         webdav: WebDavCredentials(url: "https://dav.test", username: "me", password: "pw"),
                                         settingsKey: "dav")
        let found = await loader.coverURL(for: song, access: access)
        XCTAssertNil(found, "a web page is no cover")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [],
                       "a refused cover leaves no file behind")
    }

    /// Signing in to a captive portal changes its reply without changing the server settings. A
    /// refused page must not become this run's remembered "no cover" answer.
    func testACaptivePortalMissIsFetchedAgainAfterSigningIn() async throws {
        let cover = "https://dav.test/\(UUID().uuidString)/portal-then-cover.jpg"
        let loader = RemoteCoverLoader(directory: makeTemporaryDirectory(self), session: CoverServer.session())
        let song = Song(videoId: WebDavConfig.idFor(fileUrl: "https://dav.test/music/d.flac"), title: "D", artist: "",
                        thumbnailUrl: cover)
        let access = RemoteLibraryAccess(smbClient: nil, smbShare: "",
                                         webdav: WebDavCredentials(url: "https://dav.test", username: "me", password: "pw"),
                                         settingsKey: "dav")

        let refused = await loader.coverURL(for: song, access: access)
        XCTAssertNil(refused, "the portal page is refused")
        let found = await loader.coverURL(for: song, access: access)
        XCTAssertEqual(found?.isFileURL, true, "the cover arrives after the portal sign-in")
        XCTAssertEqual(CoverServer.requests(for: URL(string: cover)!), 2, "the refused page is not remembered")
    }

    /// A header that passes the type check but has no picture behind it. Kept, it would be served
    /// as the cover for good; the cache deletes its own copy of such a file and downloads it again.
    func testADamagedImageIsNotKeptAsTheCover() async throws {
        let cover = "https://dav.test/\(UUID().uuidString)/broken.jpg"
        let directory = makeTemporaryDirectory(self)
        let loader = RemoteCoverLoader(directory: directory, session: CoverServer.session())
        let song = Song(videoId: WebDavConfig.idFor(fileUrl: "https://dav.test/music/e.flac"), title: "E", artist: "",
                        thumbnailUrl: cover)
        let access = RemoteLibraryAccess(smbClient: nil, smbShare: "",
                                         webdav: WebDavCredentials(url: "https://dav.test", username: "me", password: "pw"),
                                         settingsKey: "dav")
        let found = await loader.coverURL(for: song, access: access)
        XCTAssertNil(found, "a damaged picture is no cover")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [],
                       "nothing damaged is left on disk")
    }

    /// A remote track's row scrolled back into view is a new view. Its first frame draws the cover
    /// the track already resolved, rather than the placeholder while the loader is asked again.
    /// ImageRenderer draws one frame and never runs the view's task.
    func testARemoteRowDrawnAgainShowsItsResolvedCoverOnTheFirstFrame() async throws {
        let file = makeTemporaryDirectory(self).appending(path: "cover.png")
        let red = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        try XCTUnwrap(red.pngData()).write(to: file)
        let song = Song(videoId: WebDavConfig.idFor(fileUrl: "https://dav.test/music/\(UUID().uuidString).flac"), title: "A", artist: "")

        _ = hostInScene(LocalArtwork(song: song).frame(width: 52, height: 52)
            .environment(\.remoteArtworkResolver, { _ in file }), test: self)
        await waitUntil("the row resolves and draws its cover") {
            ArtworkImageCache.shared.memoryImage(for: file, pixels: ArtworkSize.row) != nil
        }

        // The row again, with no resolver to ask: only what the track resolved before can draw it.
        let again = LocalArtwork(song: song).frame(width: 52, height: 52)
        let image = try XCTUnwrap(ImageRenderer(content: again).uiImage, "render failed")
        let pixel = ArtworkCropTests.pixel(of: image, at: CGPoint(x: 26, y: 26))
        XCTAssertEqual(pixel.red, 1.0, accuracy: 0.15, "the first frame is the placeholder: \(pixel)")
        XCTAssertLessThan(pixel.green, 0.35, "the first frame is the placeholder: \(pixel)")
    }
}
