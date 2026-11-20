import VibraMusicTestSupport
import Foundation
import XCTest
@testable import NetworkLibrary

/// RemoteArtworkStore caching: memory, then disk, then the ranged read.
final class RemoteArtworkStoreTests: XCTestCase {
    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4])

    private func mp3WithCover(_ art: Data) -> Data {
        let payload = Data([0]) + Data("image/jpeg\0".utf8) + Data([3]) + Data("d\0".utf8) + art
        let size = payload.count
        let frame = Data("APIC".utf8)
            + Data([UInt8((size >> 24) & 0xFF), UInt8((size >> 16) & 0xFF), UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)])
            + Data([0, 0]) + payload
        let tagSize = frame.count
        let header = Data("ID3".utf8) + Data([3, 0, 0])
            + Data([
                UInt8((tagSize >> 21) & 0x7F), UInt8((tagSize >> 14) & 0x7F),
                UInt8((tagSize >> 7) & 0x7F), UInt8(tagSize & 0x7F),
            ])
        return header + frame + Data(repeating: 0, count: 256)
    }

    func testThumbnailPassesThroughWithoutFetching() async throws {
        let stub = URLProtocolStub()
        let directory = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)?
            .appendingPathComponent(UUID().uuidString)
        let store = RemoteArtworkStore(cacheDirectory: directory!)
        let song = RemoteSong.build(
            videoId: "webdav:https://h/song.mp3", streamUrl: "https://h/song.mp3",
            fileName: "A - B.mp3", albumName: nil, source: "WebDAV", browseId: "local:webdav"
        )
        var thumbnailed = song
        thumbnailed.thumbnailUrl = "https://h/cover.jpg"
        let url = await store.resolveArt(thumbnailed, source: RemoteArtworkStore.Source(httpSession: stub.makeSession()))
        XCTAssertEqual(url?.absoluteString, "https://h/cover.jpg")
        XCTAssertEqual(stub.requests.count, 0)
    }

    func testExtractsCachesAndHitsMemory() async throws {
        let file = mp3WithCover(jpeg)
        let stub = URLProtocolStub()
        stub.register(host: "h", method: "GET") { request in
            // Answer every range from the file, honouring Range.
            let range = request.value(forHTTPHeaderField: "Range") ?? ""
            let numbers = range.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            let lower = numbers.first ?? 0
            let upper = numbers.dropFirst().first ?? (file.count - 1)
            let slice = file[lower...min(upper, file.count - 1)]
            return .data(slice, status: 206)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RemoteArtworkStore(cacheDirectory: directory)
        let song = RemoteSong.build(
            videoId: "webdav:https://h/song.mp3", streamUrl: "https://h/song.mp3",
            fileName: "A - B.mp3", albumName: nil, source: "WebDAV", browseId: "local:webdav"
        )
        let source = RemoteArtworkStore.Source(httpSession: stub.makeSession())
        let firstOpt = await store.resolveArt(song, source: source)
        let first = try XCTUnwrap(firstOpt)
        XCTAssertTrue(first.isFileURL)
        XCTAssertEqual(try Data(contentsOf: first), jpeg)
        let requestsAfterFirst = stub.requests.count
        XCTAssertGreaterThan(requestsAfterFirst, 0)
        // Memory hit: no further traffic. (Compared by resolving the
        // symlinked temporary prefix first.)
        let secondOpt = await store.resolveArt(song, source: source)
        let second = try XCTUnwrap(secondOpt)
        XCTAssertEqual(second.resolvingSymlinksInPath().path, first.resolvingSymlinksInPath().path)
        XCTAssertEqual(stub.requests.count, requestsAfterFirst)
        // Disk hit: a fresh store serves the same file without traffic.
        let fresh = RemoteArtworkStore(cacheDirectory: directory)
        let thirdOpt = await fresh.resolveArt(song, source: source)
        let third = try XCTUnwrap(thirdOpt)
        XCTAssertEqual(third.resolvingSymlinksInPath().path, first.resolvingSymlinksInPath().path)
        XCTAssertEqual(stub.requests.count, requestsAfterFirst)
        try? FileManager.default.removeItem(at: directory)
    }

    /// A picture kept by an earlier run is found by its name whatever type it was sniffed as, and an
    /// empty leftover beside it is passed over, with no traffic. Looked up per extension rather than
    /// by listing the whole cache once per row.
    func testAPictureKeptOnDiskIsFoundWhateverItsType() async throws {
        let stub = URLProtocolStub()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let song = RemoteSong.build(
            videoId: "webdav:https://h/kept.mp3", streamUrl: "https://h/kept.mp3",
            fileName: "kept.mp3", albumName: nil, source: "WebDAV", browseId: "local:webdav"
        )
        let stem = RemoteArtworkStore.cacheKey(song.videoId)
        try jpeg.write(to: directory.appendingPathComponent("\(stem).png"))
        // The newest candidate, so only the size check passes it over.
        let empty = directory.appendingPathComponent("\(stem).jpg")
        try Data().write(to: empty)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: empty.path)

        let store = RemoteArtworkStore(cacheDirectory: directory)
        let found = await store.resolveArt(song, source: RemoteArtworkStore.Source(httpSession: stub.makeSession()))
        XCTAssertEqual(found?.lastPathComponent, "\(stem).png")
        XCTAssertEqual(stub.requests.count, 0)
        try? FileManager.default.removeItem(at: directory)
    }

    func testMissingPictureResolvesNil() async throws {
        let stub = URLProtocolStub()
        stub.register(host: "h", method: "GET") { _ in .data(Data(repeating: 0, count: 64), status: 206) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RemoteArtworkStore(cacheDirectory: directory)
        let song = RemoteSong.build(
            videoId: "webdav:https://h/bare.mp3", streamUrl: "https://h/bare.mp3",
            fileName: "bare.mp3", albumName: nil, source: "WebDAV", browseId: "local:webdav"
        )
        let resolved = await store.resolveArt(song, source: RemoteArtworkStore.Source(httpSession: stub.makeSession()))
        XCTAssertNil(resolved)
        try? FileManager.default.removeItem(at: directory)
    }

    func testCacheKeyIsStableHex() {
        XCTAssertEqual(
            RemoteArtworkStore.cacheKey("webdav:https://h/song.mp3"),
            RemoteArtworkStore.cacheKey("webdav:https://h/song.mp3")
        )
        XCTAssertNotEqual(
            RemoteArtworkStore.cacheKey("a"),
            RemoteArtworkStore.cacheKey("b")
        )
    }
}
