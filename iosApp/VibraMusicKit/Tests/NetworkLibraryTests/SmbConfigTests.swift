import XCTest
@testable import NetworkLibrary

/// Ports SmbTest.kt (config, ids, auth mapping) against SmbConfig and
/// SmbCredentials.
final class SmbConfigTests: XCTestCase {
    func testNormalizesHost() {
        XCTAssertEqual(SmbConfig.normalizeHost("nas.local"), "nas.local")
        XCTAssertEqual(SmbConfig.normalizeHost("smb://nas.local/Music"), "nas.local")
        XCTAssertEqual(SmbConfig.normalizeHost("\\\\NAS\\Music"), "nas")
        XCTAssertEqual(SmbConfig.normalizeHost("192.168.1.10:445"), "192.168.1.10")
        XCTAssertEqual(SmbConfig.normalizeHost("  "), "")
    }

    func testSplitsHostPort() {
        XCTAssertEqual(SmbConfig.splitHostPort("nas.local").port, 445)
        XCTAssertEqual(SmbConfig.splitHostPort("nas.local").host, "nas.local")
        let custom = SmbConfig.splitHostPort("nas.local:4445")
        XCTAssertEqual(custom.host, "nas.local")
        XCTAssertEqual(custom.port, 4445)
        let prefixed = SmbConfig.splitHostPort("smb://h:1445/x")
        XCTAssertEqual(prefixed.host, "h")
        XCTAssertEqual(prefixed.port, 1445)
        let v6 = SmbConfig.splitHostPort("[::1]:1445")
        XCTAssertEqual(v6.host, "::1")
        XCTAssertEqual(v6.port, 1445)
        XCTAssertEqual(SmbConfig.splitHostPort("[::1]").port, 445)
        // Out-of-range and non-numeric ports fall back to 445.
        XCTAssertEqual(SmbConfig.splitHostPort("nas:99999").port, 445)
        XCTAssertEqual(SmbConfig.splitHostPort("nas:abc").port, 445)
    }

    func testDetectsConfiguration() {
        XCTAssertTrue(SmbConfig.isConfigured(host: "nas.local", share: "Music"))
        XCTAssertFalse(SmbConfig.isConfigured(host: "", share: "Music"))
        XCTAssertFalse(SmbConfig.isConfigured(host: "nas.local", share: ""))
        XCTAssertFalse(SmbConfig.isConfigured(host: "  ", share: "  "))
    }

    func testDetectsMediaFiles() {
        XCTAssertTrue(SmbConfig.isAudioFile("song.flac"))
        XCTAssertTrue(SmbConfig.isAudioFile("Song.MP3"))
        XCTAssertFalse(SmbConfig.isAudioFile("cover.jpg"))
        XCTAssertTrue(SmbConfig.isImageFile("cover.jpg"))
        XCTAssertTrue(SmbConfig.isImageFile("folder.PNG"))
        XCTAssertFalse(SmbConfig.isImageFile("song.mp3"))
    }

    func testBuildsStableIdsAndUrls() {
        let song = SmbConfig.songFor(host: "NAS.local", share: "Music", path: "Artist/Album/Artist - Title.flac", albumName: "Album")
        XCTAssertEqual(song.videoId, "smb:nas.local/Music/Artist/Album/Artist - Title.flac")
        XCTAssertEqual(song.localUri, "smb://nas.local/Music/Artist/Album/Artist - Title.flac")
        XCTAssertEqual(song.title, "Title")
        XCTAssertEqual(song.artist, "Artist")
        XCTAssertEqual(song.albumName, "Album")
        XCTAssertTrue(SmbConfig.isSmbId(song.videoId))
        XCTAssertFalse(SmbConfig.isSmbId("abc123"))
    }

    func testRelativePathStripsHostAndShare() {
        XCTAssertEqual(
            SmbConfig.relativePath("smb://nas/Music/Album/song.mp3", share: "Music"),
            "Album/song.mp3"
        )
        // A URL baked under another share fails loudly instead of opening a
        // same-named stranger.
        XCTAssertNil(SmbConfig.relativePath("smb://nas/Other/song.mp3", share: "Music"))
        XCTAssertNil(SmbConfig.relativePath("smb://nas/Music", share: "Music"))
        XCTAssertNil(SmbConfig.relativePath("not a url", share: "Music"))
    }

    func testSmbPathConvertsDisplayToWire() {
        XCTAssertEqual(SmbClient.smbPath("Album/song.mp3"), "Album\\song.mp3")
        XCTAssertEqual(SmbClient.smbPath(""), "")
    }

    func testBlankCredentialsMeanGuest() {
        XCTAssertTrue(SmbCredentials(host: "nas", share: "Music").isGuest)
        XCTAssertTrue(SmbCredentials(host: "nas", share: "Music", username: "  ", password: "").isGuest)
        XCTAssertFalse(SmbCredentials(host: "nas", share: "Music", username: "user", password: "secret").isGuest)
    }

    func testGuestMapsToNilCredential() {
        XCTAssertNil(AmSmbSessionFactory.urlCredential(for: SmbCredentials(host: "nas", share: "Music")))
        let credential = AmSmbSessionFactory.urlCredential(
            for: SmbCredentials(host: "nas", share: "Music", username: "rairulyle", password: "secret")
        )
        XCTAssertEqual(credential?.user, "rairulyle")
        XCTAssertEqual(credential?.password, "secret")
    }

    func testCredentialsParseHostPortAndTrim() {
        let credentials = SmbCredentials(host: "smb://NAS.local:4445/x", share: "/Music/", basePath: "\\Album\\", username: " user ")
        XCTAssertEqual(credentials.host, "nas.local")
        XCTAssertEqual(credentials.port, 4445)
        XCTAssertEqual(credentials.share, "Music")
        XCTAssertEqual(credentials.basePath, "/Album/")
        XCTAssertEqual(credentials.username, "user")
        XCTAssertTrue(credentials.isConfigured)
    }

    func testArtworkPrefersConventionalCovers() {
        XCTAssertEqual(
            RemoteArtwork.pick([
                "smb://nas/Music/Album/IMG_1.jpg",
                "smb://nas/Music/Album/folder.png",
            ]),
            "smb://nas/Music/Album/folder.png"
        )
        XCTAssertNil(RemoteArtwork.pick([]))
    }
}
