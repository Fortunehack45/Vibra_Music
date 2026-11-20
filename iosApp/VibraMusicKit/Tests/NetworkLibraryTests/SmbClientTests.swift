import XCTest
@testable import NetworkLibrary

/// The SmbClient walk, reads and pool behaviour against the in-memory share.
final class SmbClientTests: XCTestCase {
    private func libraryShare() -> FakeSmbFactory {
        let factory = FakeSmbFactory()
        factory.share.directories = [
            "": [
                SmbDirectoryEntry(name: "Album", isDirectory: true, size: 0),
                SmbDirectoryEntry(name: "notes.txt", isDirectory: false, size: 10),
            ],
            "Album": [
                SmbDirectoryEntry(name: "Artist - Title.flac", isDirectory: true, size: 0),
                SmbDirectoryEntry(name: "Artist - Title.flac", isDirectory: false, size: 100),
                SmbDirectoryEntry(name: "cover.jpg", isDirectory: false, size: 20),
                SmbDirectoryEntry(name: "Live", isDirectory: true, size: 0),
            ],
            "Album/Live": [
                SmbDirectoryEntry(name: "take.mp3", isDirectory: false, size: 50),
            ],
        ]
        return factory
    }

    private func client(factory: FakeSmbFactory) -> (SmbClient, SmbConnectionPool) {
        let credentials = SmbCredentials(host: "nas.local", share: "Music")
        let pool = SmbConnectionPool(credentials: credentials, factory: factory)
        return (SmbClient(credentials: credentials, pool: pool), pool)
    }

    func testWalkCollectsAudioAndImagesRecursively() async throws {
        let factory = libraryShare()
        let (client, _) = self.client(factory: factory)
        let listing = try await client.listLibrary()
        XCTAssertEqual(
            Set(listing.audio.map(\.path)),
            ["Album/Artist - Title.flac", "Album/Live/take.mp3"]
        )
        XCTAssertEqual(listing.images.map(\.path), ["Album/cover.jpg"])
        // The directory entry is not mistaken for its same-named file.
        XCTAssertFalse(listing.audio.contains { $0.isDirectory })
    }

    func testWalkRespectsMaxFiles() async throws {
        let factory = libraryShare()
        let (client, _) = self.client(factory: factory)
        let listing = try await client.listLibrary(maxFiles: 1)
        XCTAssertEqual(listing.audio.count, 1)
    }

    func testWalkVisitsCaseInsensitively() async throws {
        // Two spellings of one directory: the walk takes the first and skips
        // the second, instead of listing the subtree twice.
        let factory = FakeSmbFactory()
        factory.share.directories = [
            "": [
                SmbDirectoryEntry(name: "Album", isDirectory: true, size: 0),
                SmbDirectoryEntry(name: "ALBUM", isDirectory: true, size: 0),
            ],
            "Album": [SmbDirectoryEntry(name: "a.mp3", isDirectory: false, size: 5)],
            "ALBUM": [SmbDirectoryEntry(name: "b.mp3", isDirectory: false, size: 5)],
        ]
        let (client, _) = self.client(factory: factory)
        let listing = try await client.listLibrary()
        XCTAssertEqual(listing.audio.count, 1)
    }

    func testWalkFromBasePath() async throws {
        let factory = libraryShare()
        let credentials = SmbCredentials(host: "nas.local", share: "Music", basePath: "Album")
        let pool = SmbConnectionPool(credentials: credentials, factory: factory)
        let client = SmbClient(credentials: credentials, pool: pool)
        let listing = try await client.listLibrary()
        XCTAssertTrue(listing.audio.allSatisfy { $0.path.hasPrefix("Album/") })
    }

    func testListingFailsWhenUnconfigured() async {
        let credentials = SmbCredentials(host: "", share: "")
        let pool = SmbConnectionPool(credentials: credentials, factory: FakeSmbFactory())
        let client = SmbClient(credentials: credentials, pool: pool)
        do {
            _ = try await client.listLibrary()
            XCTFail("expected failure")
        } catch {
            XCTAssertNotNil(error as? SmbError)
        }
    }

    func testReadFullyAssemblesChunks() async throws {
        let bytes = Data((0..<200_000).map { UInt8($0 & 0xFF) })
        let (client, share, _) = makeSmbStack()
        share.files = ["Album/song.mp3": bytes]
        let out = try await client.readFully(streamUrl: "smb://nas.local/Music/Album/song.mp3")
        XCTAssertEqual(out, bytes)
        XCTAssertGreaterThan(share.readCalls.count, 1)
    }

    func testReadFullyRejectsForeignShare() async {
        let (client, _, _) = makeSmbStack()
        do {
            _ = try await client.readFully(streamUrl: "smb://nas.local/Other/song.mp3")
            XCTFail("expected failure")
        } catch let error as SmbError {
            if case .notAFile = error {} else { XCTFail("wrong error \(error)") }
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testReadFullyRefusesOversizeCover() async {
        let (client, share, _) = makeSmbStack()
        share.files = ["Album/huge.bin": Data(repeating: 1, count: 100)]
        do {
            _ = try await client.readFully(streamUrl: "smb://nas.local/Music/Album/huge.bin", maxBytes: 10)
            XCTFail("expected failure")
        } catch let error as SmbError {
            if case .fileTooLargeForCover = error {} else { XCTFail("wrong error \(error)") }
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testPoolRetriesTransportFailureOnce() async throws {
        struct Transport: Error {}
        let factory = FakeSmbFactory()
        factory.share.directories = ["": [SmbDirectoryEntry(name: "a.mp3", isDirectory: false, size: 1)]]
        let credentials = SmbCredentials(host: "nas.local", share: "Music")
        let pool = SmbConnectionPool(credentials: credentials, factory: factory)
        // First attempt dies mid-flight with a transport failure…
        factory.share.listError = Transport()
        do {
            _ = try await pool.withSession { try await $0.listDirectory("") }
            XCTFail("expected failure")
        } catch is Transport {}
        // …after the pool dropped the dead session and dialled a second time within that one call.
        XCTAssertEqual(factory.connects, 2)
        // The next call runs on the session the retry made, with no further dial.
        factory.share.listError = nil
        let rows = try await pool.withSession { try await $0.listDirectory("") }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(factory.connects, 2)
    }

    func testPoolDoesNotRetryServerErrors() async {
        let factory = FakeSmbFactory()
        let credentials = SmbCredentials(host: "nas.local", share: "Music")
        let pool = SmbConnectionPool(credentials: credentials, factory: factory)
        factory.share.listError = SmbError.notConfigured
        do {
            _ = try await pool.withSession { try await $0.listDirectory("") }
            XCTFail("expected failure")
        } catch let error as SmbError {
            if case .notConfigured = error {} else { XCTFail("wrong error \(error)") }
        } catch {
            XCTFail("wrong error \(error)")
        }
        XCTAssertEqual(factory.connects, 1)
    }

    func testPoolDoesNotRetryAFailedConnect() async {
        struct Refused: Error {}
        let factory = FakeSmbFactory()
        factory.connectError = Refused()
        let pool = SmbConnectionPool(credentials: SmbCredentials(host: "nas.local", share: "Music"), factory: factory)
        do {
            _ = try await pool.withSession { try await $0.listDirectory("") }
            XCTFail("expected failure")
        } catch {}
        XCTAssertEqual(factory.connects, 1)
    }

    func testCredentialsUpdateDropsSession() async throws {
        let factory = FakeSmbFactory()
        let pool = SmbConnectionPool(credentials: SmbCredentials(host: "a", share: "Music"), factory: factory)
        _ = try await pool.session()
        XCTAssertEqual(factory.connects, 1)
        await pool.update(credentials: SmbCredentials(host: "b", share: "Music"))
        _ = try await pool.session()
        XCTAssertEqual(factory.connects, 2)
    }

    func testAmSmbNativePath() {
        XCTAssertEqual(AmSmbShareSession.nativePath(""), "")
        XCTAssertEqual(AmSmbShareSession.nativePath("Album/song.mp3"), "Album/song.mp3")
        XCTAssertEqual(AmSmbShareSession.nativePath("Album\\Live//take.mp3"), "Album/Live/take.mp3")
    }
}
