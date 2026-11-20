import VibraMusicTestSupport
import Foundation
import XCTest
@testable import NetworkLibrary

/// WebDAV uploads: naming, conflicts and batch summaries against stubbed
/// HTTP and local temp files.
final class WebDavUploadsTests: XCTestCase {
    private var stub: URLProtocolStub!
    private var directory: URL!
    private let credentials = WebDavCredentials(url: "https://cloud.example.com/Music", username: "user", password: "pass")

    override func setUp() {
        super.setUp()
        stub = URLProtocolStub()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        stub = nil
        super.tearDown()
    }

    private func localFile(named name: String, contents: String = "audio-bytes") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func item(id: String = UUID().uuidString, title: String, artist: String, file: String) throws -> WebDavUploads.UploadItem {
        WebDavUploads.UploadItem(id: id, fileURL: try localFile(named: file), title: title, artist: artist)
    }

    private func uploads(notifier: (any WebDavUploadNotifying)? = nil) -> WebDavUploads {
        WebDavUploads(client: WebDavClient(session: stub.makeSession()), credentials: credentials, notifier: notifier)
    }

    func testBatchUploadsNewFiles() async throws {
        stub.register(host: "cloud.example.com", method: "HEAD") { _ in .status(404) }
        stub.register(host: "cloud.example.com", method: "PUT") { _ in .status(201) }
        let uploader = uploads()
        let summary = await uploader.upload([
            try item(title: "Title", artist: "Artist", file: "a.mp3"),
            try item(title: "Other", artist: "Artist", file: "b.mp3"),
        ])
        XCTAssertEqual(summary.uploaded, 2)
        XCTAssertEqual(summary.skipped, 0)
        XCTAssertEqual(summary.failed, 0)
        let puts = stub.requests.filter { $0.httpMethod == "PUT" }
        XCTAssertEqual(puts.count, 2)
        XCTAssertTrue(puts.allSatisfy { $0.value(forHTTPHeaderField: "If-None-Match") == "*" })
        let finished = await uploader.states()
        XCTAssertEqual(finished.values.filter { $0.isDone }.count, 2)
    }

    func testConflictSkipAppliesToAll() async throws {
        stub.register(host: "cloud.example.com", method: "HEAD") { _ in .status(200) }
        let uploader = uploads()
        var conflicts = 0
        let summary = await uploader.upload([
            try item(title: "One", artist: "A", file: "a.mp3"),
            try item(title: "Two", artist: "A", file: "b.mp3"),
        ]) { _ in
            conflicts += 1
            return WebDavUploads.Resolution(choice: .skip, applyToAll: true)
        }
        XCTAssertEqual(conflicts, 1)
        XCTAssertEqual(summary.skipped, 2)
        XCTAssertEqual(stub.requests.filter { $0.httpMethod == "PUT" }.count, 0)
    }

    func testConflictOverwriteSendsPutWithoutGuard() async throws {
        stub.register(host: "cloud.example.com", method: "HEAD") { _ in .status(200) }
        stub.register(host: "cloud.example.com", method: "PUT") { _ in .status(200) }
        let uploader = uploads()
        let summary = await uploader.upload([try item(title: "One", artist: "A", file: "a.mp3")]) { _ in
            WebDavUploads.Resolution(choice: .overwrite, applyToAll: false)
        }
        XCTAssertEqual(summary.uploaded, 1)
        let put = try XCTUnwrap(stub.requests.first { $0.httpMethod == "PUT" })
        XCTAssertNil(put.value(forHTTPHeaderField: "If-None-Match"))
    }

    func testConflictKeepBothNumbersPastServer() async throws {
        final class Counter: @unchecked Sendable { var heads = 0 }
        let counter = Counter()
        stub.register(host: "cloud.example.com", method: "HEAD") { _ in
            counter.heads += 1
            // The base name and " (1)" both exist; " (2)" is free.
            return .status(counter.heads <= 2 ? 200 : 404)
        }
        stub.register(host: "cloud.example.com", method: "PUT") { _ in .status(201) }
        let uploader = uploads()
        let summary = await uploader.upload([try item(title: "Title", artist: "Artist", file: "a.mp3")]) { _ in
            WebDavUploads.Resolution(choice: .keepBoth, applyToAll: false)
        }
        XCTAssertEqual(summary.uploaded, 1)
        let put = try XCTUnwrap(stub.requests.first { $0.httpMethod == "PUT" })
        XCTAssertTrue(put.url?.path(percentEncoded: false).contains("Title (2).mp3") ?? false)
    }

    func testLostRaceReadsAsSkipped() async throws {
        stub.register(host: "cloud.example.com", method: "HEAD") { _ in .status(404) }
        stub.register(host: "cloud.example.com", method: "PUT") { _ in .status(412) }
        let uploader = uploads()
        let summary = await uploader.upload([try item(title: "Title", artist: "Artist", file: "a.mp3")])
        XCTAssertEqual(summary.skipped, 1)
        XCTAssertEqual(summary.uploaded, 0)
    }

    func testUploadableGating() async throws {
        let local = try item(id: "local:1", title: "T", artist: "A", file: "a.mp3")
        XCTAssertTrue(WebDavUploads.isUploadable(local))
        let remote = WebDavUploads.UploadItem(
            id: "webdav:https://cloud.example.com/Music/a.mp3",
            fileURL: try localFile(named: "b.mp3"),
            title: "T",
            artist: "A"
        )
        XCTAssertFalse(WebDavUploads.isUploadable(remote))
        let missing = WebDavUploads.UploadItem(
            id: "local:2",
            fileURL: directory.appendingPathComponent("nope.mp3"),
            title: "T",
            artist: "A"
        )
        // Cheap gate passes (it is a file URL); the batch reports the
        // unreadable file as failed.
        XCTAssertTrue(WebDavUploads.isUploadable(missing))
        let uploader = uploads()
        let summary = await uploader.upload([missing])
        XCTAssertEqual(summary.failed, 1)
    }

    func testStateUpdatesStream() async throws {
        stub.register(host: "cloud.example.com", method: "HEAD") { _ in .status(404) }
        stub.register(host: "cloud.example.com", method: "PUT") { _ in .status(201) }
        let uploader = uploads()
        let stream = await uploader.stateUpdates()
        let item = try item(title: "T", artist: "A", file: "a.mp3")
        // Run the batch alongside the consumer: AsyncStream buffers every
        // yield, but cancelling the loop right after `upload` returns could
        // still discard buffered states the loop hasn't reached yet. Waiting
        // for the terminal state inside the loop is deterministic instead.
        async let summary = uploader.upload([item])
        var sawDone = false
        for await states in stream {
            if states[item.id]?.isDone == true {
                sawDone = true
                break
            }
        }
        let finished = await summary
        XCTAssertEqual(finished.uploaded, 1)
        XCTAssertTrue(sawDone)
    }

    func testSummaryMessage() {
        XCTAssertEqual(
            WebDavUploads.Summary(uploaded: 2, skipped: 1, failed: 0).message,
            "Uploaded 2 · skipped 1 · failed 0"
        )
    }
}

private extension WebDavUploads.TrackState {
    var isDone: Bool {
        if case .done = self { return true }
        return false
    }
}
