import VibraMusicTestSupport
import XCTest
@testable import NetworkLibrary

/// WebDavClient over stubbed HTTP: exists/PUT/MKCOL/listLibrary and the
/// auth header, mirroring the MockWebServer cases in WebDavTest.kt.
final class WebDavClientNetworkTests: XCTestCase {
    private var stub: URLProtocolStub!
    private var client: WebDavClient!
    private let credentials = WebDavCredentials(url: "https://cloud.example.com", username: "user", password: "pass")

    override func setUp() {
        super.setUp()
        stub = URLProtocolStub()
        client = WebDavClient(session: stub.makeSession())
    }

    override func tearDown() {
        stub = nil
        client = nil
        super.tearDown()
    }

    func testExistsMaps200And404() async throws {
        stub.register(host: "cloud.example.com", method: "HEAD") { _ in .status(404) }
        let missing = try await client.exists(fileUrl: "https://cloud.example.com/Music/song.mp3", credentials: credentials)
        XCTAssertFalse(missing)
        stub.reset()
        stub.register(host: "cloud.example.com", method: "HEAD") { _ in .status(200) }
        let present = try await client.exists(fileUrl: "https://cloud.example.com/Music/song.mp3", credentials: credentials)
        XCTAssertTrue(present)
    }

    func testExistsFailsLoudlyOtherwise() async {
        stub.register(host: "cloud.example.com", method: "HEAD") { _ in .status(500) }
        do {
            _ = try await client.exists(fileUrl: "https://cloud.example.com/Music/song.mp3", credentials: credentials)
            XCTFail("expected failure")
        } catch {
            XCTAssertNotNil(error as? WebDavError)
        }
    }

    func testPutHonorsIfNoneMatch() async throws {
        stub.register(host: "cloud.example.com", method: "PUT") { _ in .status(201) }
        final class Progress: @unchecked Sendable { var values: [Int64] = [] }
        let progress = Progress()
        let result = try await client.putFile(
            fileUrl: "https://cloud.example.com/Music/Artist%20-%20Title.mp3",
            data: Data("hello".utf8),
            mimeType: "audio/mpeg",
            credentials: credentials,
            overwrite: false,
            onProgress: { progress.values.append($0) }
        )
        XCTAssertEqual(result, .uploaded)
        XCTAssertEqual(progress.values.last, 5)
        let put = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(put.httpMethod, "PUT")
        XCTAssertEqual(put.value(forHTTPHeaderField: "If-None-Match"), "*")
        XCTAssertEqual(put.value(forHTTPHeaderField: "Authorization"), "Basic dXNlcjpwYXNz")
        XCTAssertEqual(put.httpBody, Data("hello".utf8))
    }

    func testPutConflictReadsAsAlreadyExists() async throws {
        stub.register(host: "cloud.example.com", method: "PUT") { _ in .status(412) }
        let result = try await client.putFile(
            fileUrl: "https://cloud.example.com/Music/song.mp3",
            data: Data("hello".utf8),
            mimeType: "audio/mpeg",
            credentials: credentials,
            overwrite: false
        )
        XCTAssertEqual(result, .alreadyExists)
    }

    func testPutOverwriteOmitsIfNoneMatch() async throws {
        stub.register(host: "cloud.example.com", method: "PUT") { _ in .status(204) }
        _ = try await client.putFile(
            fileUrl: "https://cloud.example.com/Music/song.mp3",
            data: Data("hello".utf8),
            mimeType: "audio/mpeg",
            credentials: credentials,
            overwrite: true
        )
        XCTAssertNil(stub.requests.first?.value(forHTTPHeaderField: "If-None-Match"))
    }

    func testPutFailureThrows() async {
        stub.register(host: "cloud.example.com", method: "PUT") { _ in .status(500) }
        do {
            _ = try await client.putFile(
                fileUrl: "https://cloud.example.com/Music/song.mp3",
                data: Data("hello".utf8),
                mimeType: "audio/mpeg",
                credentials: credentials,
                overwrite: true
            )
            XCTFail("expected failure")
        } catch {
            XCTAssertNotNil(error as? WebDavError)
        }
    }

    func testEnsureCollectionToleratesExistingFolder() async throws {
        stub.register(host: "cloud.example.com", method: "MKCOL") { _ in .status(405) }
        try await client.ensureCollection(dirUrl: "https://cloud.example.com/Music", credentials: credentials)
        XCTAssertEqual(stub.requests.first?.httpMethod, "MKCOL")
    }

    func testListLibraryCollectsAudioAndSiblingImages() async throws {
        let loader = FixtureLoader(bundle: .module)
        let rootXml = try loader.string("propfind-library.xml")
        let liveXml = try loader.string("propfind-live.xml")
        stub.register(host: "cloud.example.com", method: "PROPFIND") { request in
            let path = request.url?.path(percentEncoded: false) ?? ""
            return .text(path.contains("Live") ? liveXml : rootXml, status: 207)
        }
        let listing = try await client.listLibrary(WebDavCredentials(url: "https://cloud.example.com/remote.php/dav/files/user/Music"))
        XCTAssertEqual(listing.audio.count, 2)
        XCTAssertEqual(listing.images.count, 1)
        XCTAssertEqual(listing.images.first?.displayName, "cover.jpg")
        // Depth 1 per directory, manual recursion.
        XCTAssertTrue(stub.requests.allSatisfy { $0.value(forHTTPHeaderField: "Depth") == "1" })
    }

    /// A collection href comes from the server's PROPFIND answer. One that isn't a URL was
    /// force-unwrapped when the listing walked into it.
    func testAnUnparseableCollectionHrefFailsTheListingInsteadOfTrapping() async {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <multistatus xmlns="DAV:"><response><href>http://[zz/music/</href>
        <propstat><prop><resourcetype><collection/></resourcetype></prop></propstat></response></multistatus>
        """
        stub.register(host: "cloud.example.com", method: "PROPFIND") { _ in .text(xml, status: 207) }
        do {
            _ = try await client.listLibrary(credentials)
            XCTFail("expected failure")
        } catch {
            XCTAssertNotNil(error as? WebDavError)
        }
    }

    func testTestConnectionAccepts207() async throws {
        stub.register(host: "cloud.example.com", method: "PROPFIND") { _ in .status(207) }
        try await client.testConnection(credentials)
        XCTAssertEqual(stub.requests.first?.value(forHTTPHeaderField: "Depth"), "0")
    }

    func testTestConnectionRejectsUnconfigured() async {
        do {
            try await client.testConnection(WebDavCredentials(url: ""))
            XCTFail("expected failure")
        } catch {
            XCTAssertNotNil(error as? WebDavError)
        }
    }

    func testRangeReadSlices206() async throws {
        let bytes = Data((0..<100).map { UInt8($0) })
        stub.register(host: "cloud.example.com", method: "GET") { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=10-19")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic dXNlcjpwYXNz")
            return .data(bytes[10..<20], status: 206, headers: ["Content-Range": "bytes 10-19/100"])
        }
        let out = try await client.readRange(
            fileURL: "https://cloud.example.com/Music/song.mp3",
            range: 10..<20,
            credentials: credentials
        )
        XCTAssertEqual(out, bytes[10..<20])
    }

    func testRangeReadToleratesServersIgnoringRange() async throws {
        let bytes = Data((0..<100).map { UInt8($0) })
        stub.register(host: "cloud.example.com", method: "GET") { _ in .data(bytes, status: 200) }
        // The front is still reachable by slicing.
        let front = try await client.readRange(
            fileURL: "https://cloud.example.com/Music/song.mp3",
            range: 0..<10,
            credentials: credentials
        )
        XCTAssertEqual(front, bytes.prefix(10))
        // Past the front, a 200 answers nothing usable.
        let past = try await client.readRange(
            fileURL: "https://cloud.example.com/Music/song.mp3",
            range: 10..<20,
            credentials: credentials
        )
        XCTAssertEqual(past, Data())
    }

    func testContentInfoFromHead() async throws {
        stub.register(host: "cloud.example.com", method: "HEAD") { _ in
            .data(Data(), status: 200, headers: ["Content-Length": "12345", "Content-Type": "audio/flac"])
        }
        let info = try await client.audioContentInfo(
            fileURL: "https://cloud.example.com/Music/take.flac",
            credentials: credentials
        )
        XCTAssertEqual(info.contentLength, 12345)
        XCTAssertEqual(info.mimeType, "audio/flac")
    }

    func testContentInfoFallsBackToRangeProbe() async throws {
        stub.register(host: "cloud.example.com", method: "HEAD") { _ in .status(404) }
        stub.register(host: "cloud.example.com", method: "GET") { _ in
            .data(Data([0]), status: 206, headers: ["Content-Range": "bytes 0-0/999"])
        }
        let info = try await client.audioContentInfo(
            fileURL: "https://cloud.example.com/Music/take.flac",
            credentials: credentials
        )
        XCTAssertEqual(info.contentLength, 999)
    }
}
