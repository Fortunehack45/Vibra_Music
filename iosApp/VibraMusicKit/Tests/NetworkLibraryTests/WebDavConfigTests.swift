import XCTest
@testable import NetworkLibrary

/// Ports the WebDavTest.kt configuration cases against WebDavConfig and
/// WebDavCredentials.
final class WebDavConfigTests: XCTestCase {
    func testNormalizesUrl() {
        XCTAssertEqual(WebDavConfig.normalizeUrl("  "), "")
        XCTAssertEqual(
            WebDavConfig.normalizeUrl("cloud.example.com/remote.php/dav/files/user/Music/"),
            "https://cloud.example.com/remote.php/dav/files/user/Music"
        )
        XCTAssertEqual(
            WebDavConfig.normalizeUrl("http://192.168.1.10:8080/music"),
            "http://192.168.1.10:8080/music"
        )
    }

    func testDetectsConfiguration() {
        XCTAssertFalse(WebDavConfig.isConfigured(""))
        XCTAssertFalse(WebDavConfig.isConfigured("not a url"))
        XCTAssertTrue(WebDavConfig.isConfigured("https://cloud.example.com/music"))
    }

    func testBuildsBasicAuthHeader() {
        XCTAssertNil(WebDavConfig.basicAuthHeader(username: "", password: ""))
        XCTAssertEqual(WebDavConfig.basicAuthHeader(username: "user", password: "pass"), "Basic dXNlcjpwYXNz")
    }

    func testDetectsAudioFiles() {
        XCTAssertTrue(WebDavConfig.isAudioFile("song.mp3"))
        XCTAssertTrue(WebDavConfig.isAudioFile("Song.FLAC"))
        XCTAssertTrue(WebDavConfig.isAudioFile("take.opus"))
        XCTAssertFalse(WebDavConfig.isAudioFile("cover.jpg"))
        XCTAssertFalse(WebDavConfig.isAudioFile("notes.txt"))
    }

    func testDetectsImageFiles() {
        XCTAssertTrue(WebDavClient.isImageFile("cover.jpg"))
        XCTAssertTrue(WebDavClient.isImageFile("Folder.PNG"))
        XCTAssertTrue(WebDavClient.isImageFile("art.webp"))
        XCTAssertFalse(WebDavClient.isImageFile("song.mp3"))
        XCTAssertFalse(WebDavClient.isImageFile("notes.txt"))
    }

    func testMapsFileToSong() {
        let song = WebDavConfig.songFor(fileUrl: "https://cloud.example.com/Music/Artist%20-%20Title.mp3", albumName: "Album")
        XCTAssertTrue(song.videoId.hasPrefix("webdav:"))
        XCTAssertEqual(song.localUri, "https://cloud.example.com/Music/Artist%20-%20Title.mp3")
        XCTAssertEqual(song.title, "Title")
        XCTAssertEqual(song.artist, "Artist")
        XCTAssertEqual(song.albumName, "Album")
        XCTAssertEqual(song.playbackSourceId, WebDavConfig.browseID)
    }

    func testIdRoundTrip() {
        let url = "https://cloud.example.com/Music/song.mp3"
        let id = WebDavConfig.idFor(fileUrl: url)
        XCTAssertTrue(WebDavConfig.isWebDavId(id))
        XCTAssertFalse(WebDavConfig.isWebDavId("abc123"))
        XCTAssertEqual(WebDavConfig.fileUrlOf(id), url)
        XCTAssertNil(WebDavConfig.fileUrlOf("abc123"))
    }

    func testCredentialsAuthorizeOnlyConfiguredHost() {
        let credentials = WebDavCredentials(url: "https://cloud.example.com/music", username: "user", password: "pass")
        XCTAssertTrue(credentials.shouldAuthorize(requestHost: "cloud.example.com"))
        XCTAssertTrue(credentials.shouldAuthorize(requestHost: "CLOUD.EXAMPLE.COM"))
        XCTAssertFalse(credentials.shouldAuthorize(requestHost: "other.example.com"))
        XCTAssertNotNil(credentials.authHeader)
        let blank = WebDavCredentials(url: "", username: "", password: "")
        XCTAssertFalse(blank.shouldAuthorize(requestHost: "cloud.example.com"))
        XCTAssertFalse(blank.isConfigured)
    }

    func testUploadFileName() {
        XCTAssertEqual(
            WebDavClient.uploadFileName(title: "Title", artist: "Artist", fileExtension: "mp3"),
            "Artist - Title.mp3"
        )
        XCTAssertEqual(
            WebDavClient.uploadFileName(title: "Title / Live", artist: "Unknown Artist", fileExtension: "FLAC"),
            "Title _ Live.flac"
        )
        XCTAssertEqual(WebDavClient.uploadFileName(title: "  ", artist: "", fileExtension: ""), "track.mp3")
    }

    func testResolveNumberedName() {
        XCTAssertEqual(
            WebDavClient.resolveNumberedName(base: "Title", fileExtension: "mp3", taken: []),
            "Title.mp3"
        )
        XCTAssertEqual(
            WebDavClient.resolveNumberedName(base: "Title", fileExtension: "mp3", taken: ["title.MP3", "Title (1).mp3"]),
            "Title (2).mp3"
        )
    }

    func testJoinUrlEncodesSegments() {
        XCTAssertEqual(
            WebDavClient.joinUrl(root: "https://cloud.example.com/Music/", segment: "Artist - Title.mp3"),
            "https://cloud.example.com/Music/Artist%20-%20Title.mp3"
        )
        // A segment never smuggles a sub-path through.
        XCTAssertEqual(
            WebDavClient.joinUrl(root: "https://cloud.example.com/Music", segment: "a/b.mp3"),
            "https://cloud.example.com/Music/a%2Fb.mp3"
        )
    }

    func testResolvesRelativeHrefs() {
        XCTAssertEqual(
            WebDavClient.resolveHref(
                baseUrl: "https://cloud.example.com/remote.php/dav/files/user/Music",
                href: "/remote.php/dav/files/user/Music/a.mp3"
            ),
            "https://cloud.example.com/remote.php/dav/files/user/Music/a.mp3"
        )
        XCTAssertEqual(
            WebDavClient.resolveHref(
                baseUrl: "https://cloud.example.com/music",
                href: "https://other.example.com/a.mp3"
            ),
            "https://other.example.com/a.mp3"
        )
    }
}
