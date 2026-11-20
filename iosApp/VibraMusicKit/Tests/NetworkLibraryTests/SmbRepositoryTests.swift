import XCTest
@testable import NetworkLibrary

/// SmbRepository rows against the in-memory share.
final class SmbRepositoryTests: XCTestCase {
    func testSongsGroupAlbumsAndCovers() async {
        let factory = FakeSmbFactory()
        factory.share.directories = [
            "": [SmbDirectoryEntry(name: "Music", isDirectory: true, size: 0)],
            "Music": [
                SmbDirectoryEntry(name: "Daft Punk", isDirectory: true, size: 0),
            ],
            "Music/Daft Punk": [
                SmbDirectoryEntry(name: "Random Access Memories", isDirectory: true, size: 0),
            ],
            "Music/Daft Punk/Random Access Memories": [
                SmbDirectoryEntry(name: "Daft Punk - Get Lucky.flac", isDirectory: false, size: 100),
                SmbDirectoryEntry(name: "Daft Punk - Lose Yourself to Dance.mp3", isDirectory: false, size: 100),
                SmbDirectoryEntry(name: "folder.jpg", isDirectory: false, size: 10),
            ],
        ]
        let credentials = SmbCredentials(host: "nas.local", share: "Music", basePath: "Music")
        let pool = SmbConnectionPool(credentials: credentials, factory: factory)
        let repository = SmbRepository(
            credentials: credentials,
            client: SmbClient(credentials: credentials, pool: pool)
        )
        XCTAssertTrue(repository.isConfigured)
        let songs = await repository.getSongs()
        XCTAssertEqual(songs.count, 2)
        let first = songs.first { $0.title == "Get Lucky" }
        XCTAssertEqual(first?.artist, "Daft Punk")
        XCTAssertEqual(first?.albumName, "Random Access Memories")
        XCTAssertEqual(first?.thumbnailUrl, "smb://nas.local/Music/Music/Daft Punk/Random Access Memories/folder.jpg")
        XCTAssertEqual(first?.playbackSource, "SMB")
        XCTAssertEqual(first?.playbackSourceId, "local:smb")
    }

    func testUnconfiguredYieldsNoSongs() async {
        let credentials = SmbCredentials(host: "", share: "")
        let pool = SmbConnectionPool(credentials: credentials, factory: FakeSmbFactory())
        let repository = SmbRepository(
            credentials: credentials,
            client: SmbClient(credentials: credentials, pool: pool)
        )
        XCTAssertFalse(repository.isConfigured)
        let songs = await repository.getSongs()
        XCTAssertEqual(songs, [])
    }

    func testServerFailureYieldsNoSongs() async {
        let factory = FakeSmbFactory()
        factory.share.listError = SmbError.transport("no route to host")
        let credentials = SmbCredentials(host: "nas.local", share: "Music")
        let pool = SmbConnectionPool(credentials: credentials, factory: factory)
        let repository = SmbRepository(
            credentials: credentials,
            client: SmbClient(credentials: credentials, pool: pool)
        )
        let songs = await repository.getSongs()
        XCTAssertEqual(songs, [])
    }

    func testDirKey() {
        XCTAssertEqual(SmbRepository.dirKey("Album/song.mp3"), "album")
        XCTAssertEqual(SmbRepository.dirKey("song.mp3"), "")
        XCTAssertEqual(SmbRepository.dirKey("A/B/song.mp3"), "a/b")
    }
}
