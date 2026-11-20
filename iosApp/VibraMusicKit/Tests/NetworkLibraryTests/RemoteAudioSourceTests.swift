import VibraMusicTestSupport
import XCTest
@testable import NetworkLibrary

/// The streaming surface AudioCache will plug into: lengths, types and
/// ranged reads for both protocols.
final class RemoteAudioSourceTests: XCTestCase {
    func testSmbSourceReadsRanges() async throws {
        let bytes = Data((0..<300_000).map { UInt8($0 & 0xFF) })
        let (client, share, _) = makeSmbStack()
        share.files = ["Album/song.flac": bytes]
        let source = SmbAudioSource(streamURL: "smb://nas.local/Music/Album/song.flac", client: client)
        let info = try await source.contentInfo()
        XCTAssertEqual(info.contentLength, 300_000)
        XCTAssertEqual(info.mimeType, "audio/flac")
        let head = try await source.read(0..<10)
        XCTAssertEqual(head, bytes.prefix(10))
        let tail = try await source.read(299_990..<300_000)
        XCTAssertEqual(tail, bytes.suffix(10))
        // Streaming yields the whole range in pieces.
        var collected = Data()
        for try await piece in source.stream(0..<300_000) {
            collected.append(piece)
        }
        XCTAssertEqual(collected, bytes)
    }

    func testSmbSourceRejectsForeignShare() async {
        let (client, _, _) = makeSmbStack()
        let source = SmbAudioSource(streamURL: "smb://nas.local/Other/song.flac", client: client)
        do {
            _ = try await source.contentInfo()
            XCTFail("expected failure")
        } catch {
            XCTAssertNotNil(error as? SmbError)
        }
    }

    func testWebDavSourceReadsRanges() async throws {
        let bytes = Data((0..<5000).map { UInt8($0 & 0xFF) })
        let stub = URLProtocolStub()
        stub.register(host: "cloud.example.com", method: "HEAD") { _ in
            .data(Data(), status: 200, headers: ["Content-Length": "5000", "Content-Type": "audio/mpeg"])
        }
        stub.register(host: "cloud.example.com", method: "GET") { request in
            let range = request.value(forHTTPHeaderField: "Range") ?? ""
            let numbers = range.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            let slice = bytes[numbers[0]...numbers[1]]
            return .data(slice, status: 206, headers: ["Content-Range": "bytes \(numbers[0])-\(numbers[1])/5000"])
        }
        let credentials = WebDavCredentials(url: "https://cloud.example.com/Music")
        let client = WebDavClient(session: stub.makeSession())
        let source = WebDavAudioSource(fileURL: "https://cloud.example.com/Music/song.mp3", client: client, credentials: credentials)
        let info = try await source.contentInfo()
        XCTAssertEqual(info.contentLength, 5000)
        XCTAssertEqual(info.mimeType, "audio/mpeg")
        let slice = try await source.read(100..<200)
        XCTAssertEqual(slice, bytes[100..<200])
        var collected = Data()
        for try await piece in source.stream(0..<5000) {
            collected.append(piece)
        }
        XCTAssertEqual(collected, bytes)
    }

    func testMimeTypes() {
        XCTAssertEqual(RemoteMimeTypes.mimeType(forExtension: "flac"), "audio/flac")
        XCTAssertEqual(RemoteMimeTypes.mimeType(forExtension: ".MP3"), "audio/mpeg")
        XCTAssertEqual(RemoteMimeTypes.mimeType(forExtension: "opus"), "audio/ogg")
        XCTAssertEqual(RemoteMimeTypes.mimeType(forFileName: "https://h/a/take.m4a"), "audio/mp4")
        XCTAssertEqual(RemoteMimeTypes.mimeType(forExtension: "xyz"), "application/octet-stream")
    }
}
