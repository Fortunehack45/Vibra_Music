import XCTest
@testable import NetworkLibrary

/// RemoteSong naming and the shared artwork picker.
final class RemoteSongTests: XCTestCase {
    func testSplitsArtistTitle() {
        let split = RemoteSong.splitArtistTitle("Daft Punk - Get Lucky")
        XCTAssertEqual(split.artist, "Daft Punk")
        XCTAssertEqual(split.title, "Get Lucky")
        let bare = RemoteSong.splitArtistTitle("Get Lucky")
        XCTAssertNil(bare.artist)
        XCTAssertEqual(bare.title, "Get Lucky")
        let empty = RemoteSong.splitArtistTitle(" - ")
        XCTAssertNil(empty.artist)
        XCTAssertNil(empty.title)
    }

    func testBuildFallsBackToUnknownArtist() {
        let song = RemoteSong.build(
            videoId: "webdav:https://host/song.mp3",
            streamUrl: "https://host/song.mp3",
            fileName: "song.mp3",
            albumName: nil,
            source: "WebDAV",
            browseId: "local:webdav"
        )
        XCTAssertEqual(song.title, "song")
        XCTAssertEqual(song.artist, "Unknown Artist")
        XCTAssertNil(song.albumName)
        XCTAssertEqual(song.playbackSourceType, .browse)
    }

    func testBuildKeepsAlbum() {
        let song = RemoteSong.build(
            videoId: "x", streamUrl: "y", fileName: "A - B.flac",
            albumName: "Album", source: "SMB", browseId: "local:smb"
        )
        XCTAssertEqual(song.albumName, "Album")
    }

    func testArtworkPickOrdering() {
        XCTAssertEqual(
            RemoteArtwork.pick([
                "https://h/a/z.jpg",
                "https://h/a/cover.jpg",
                "https://h/a/back.jpg",
            ]),
            "https://h/a/cover.jpg"
        )
        // Percent-encoded names still match their stems.
        XCTAssertEqual(
            RemoteArtwork.pick(["https://h/a/b.jpg", "https://h/a/cover%20art.jpg"]),
            "https://h/a/cover%20art.jpg"
        )
        // Conventional stems win in preference order, not alphabetically.
        XCTAssertEqual(
            RemoteArtwork.pick(["https://h/a/front.png", "https://h/a/cover.png"]),
            "https://h/a/cover.png"
        )
    }
}
