import VibraMusicTestSupport
import XCTest
@testable import Canvas

/// The on-disk clip cache: serve the loop from disk after the first play (ported from
/// `data/canvas/CanvasCache.kt`).
final class CanvasClipCacheTests: XCTestCase {
    private func cache(limitBytes: Int64 = CanvasClipCache.defaultLimitBytes) throws -> CanvasClipCache {
        CanvasClipCache(directory: try makeTemporaryDirectory(), limitBytes: limitBytes)
    }

    func testStoreAndRetrieve() throws {
        let cache = try cache()
        let remote = URL(string: "https://example.com/canvas/a.cnvs.mp4")!
        XCTAssertNil(cache.localFile(for: remote))
        XCTAssertFalse(cache.contains(remote))

        let stored = try XCTUnwrap(cache.store(Data("clip-bytes".utf8), for: remote))
        XCTAssertEqual(cache.localFile(for: remote), stored)
        XCTAssertTrue(cache.contains(remote))
        XCTAssertEqual(try Data(contentsOf: stored), Data("clip-bytes".utf8))
        XCTAssertEqual(cache.currentBytes, Int64("clip-bytes".utf8.count))
    }

    func testFileNamesAreStableAcrossInstances() throws {
        let directory = try makeTemporaryDirectory()
        let remote = URL(string: "https://example.com/canvas/a.cnvs.mp4")!
        CanvasClipCache(directory: directory).store(Data("x".utf8), for: remote)
        XCTAssertTrue(CanvasClipCache(directory: directory).contains(remote),
                      "the name derives from the URL, so a relaunch finds the same file")
    }

    func testEvictsTheOldestClipPastTheLimit() throws {
        let directory = try makeTemporaryDirectory()
        let cache = CanvasClipCache(directory: directory, limitBytes: 10)
        let first = URL(string: "https://example.com/canvas/first.mp4")!
        let second = URL(string: "https://example.com/canvas/second.mp4")!
        let firstFile = try XCTUnwrap(cache.store(Data("12345678".utf8), for: first))
        // Distinct ages however coarse the filesystem's mtimes are.
        try FileManager.default.setAttributes(
            [.modificationDate: Date.distantPast],
            ofItemAtPath: firstFile.path(percentEncoded: false))
        cache.store(Data("12345678".utf8), for: second)

        XCTAssertFalse(cache.contains(first), "oldest goes once the total passes the limit")
        XCTAssertTrue(cache.contains(second))
        XCTAssertLessThanOrEqual(cache.currentBytes, 10)
    }

    /// A read marks the clip recently used, so the next eviction picks an older, unread one.
    func testReadMarksClipRecentlyUsed() throws {
        let directory = try makeTemporaryDirectory()
        // Capacity for three clips; a fourth write forces one eviction.
        let cache = CanvasClipCache(directory: directory, limitBytes: 24)
        let urls = ["a", "b", "c"].map { URL(string: "https://example.com/canvas/\($0).mp4")! }
        for url in urls {
            cache.store(Data("12345678".utf8), for: url)
        }
        // Explicit, distinct ages: A oldest, B next, C newest on disk.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-172800)],
            ofItemAtPath: cache.localFile(for: urls[0])!.path(percentEncoded: false))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-86400)],
            ofItemAtPath: cache.localFile(for: urls[1])!.path(percentEncoded: false))

        // Reading A is a use — the player takes this hit every loop.
        XCTAssertNotNil(cache.localFile(for: urls[0]))

        cache.store(Data("12345678".utf8), for: URL(string: "https://example.com/canvas/d.mp4")!)

        XCTAssertTrue(cache.contains(urls[0]), "the just-read clip survives")
        XCTAssertFalse(cache.contains(urls[1]), "the older, unread clip is evicted")
        XCTAssertLessThanOrEqual(cache.currentBytes, 24)
    }

    func testFetchClipDownloadsProgressiveClipsOnce() async throws {
        let stub = URLProtocolStub()
        let bytes = Data("mp4-bytes".utf8)
        stub.register(host: "example.com", path: "/canvas/a.mp4", response: .data(bytes))
        let cache = try cache()
        let artwork = CanvasArtwork(url: "https://example.com/canvas/a.mp4")

        let first = await cache.fetchClip(for: artwork, session: stub.makeSession())
        XCTAssertEqual(try Data(contentsOf: first), bytes)

        let second = await cache.fetchClip(for: artwork, session: stub.makeSession())
        XCTAssertEqual(first, second)
        XCTAssertEqual(stub.requests.count, 1, "the loop after the first is served from disk")
    }

    func testFetchClipStreamsHLSInsteadOfCachingIt() async throws {
        let stub = URLProtocolStub()
        let cache = try cache()
        let artwork = CanvasArtwork(url: "https://example.com/apple/clip.m3u8")
        let served = await cache.fetchClip(for: artwork, session: stub.makeSession())
        XCTAssertEqual(served.absoluteString, "https://example.com/apple/clip.m3u8")
        XCTAssertTrue(stub.requests.isEmpty, "a playlist of segments is not one file; AVPlayer handles it")
    }

    /// The lock screen's path: an HLS clip is joined into a local `.mp4` once, then served from
    /// disk; a primary that fails falls to the fallback rendition, and a failed join is nil,
    /// never the stream.
    func testFetchLocalClipJoinsHLSIntoOneCachedFile() async throws {
        let stub = URLProtocolStub()
        stub.register(host: "example.com", path: "/apple/clip.m3u8", response: .text(
            "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1,CODECS=\"avc1.64001f\",RESOLUTION=768x768\nv.m3u8"))
        stub.register(host: "example.com", path: "/apple/v.m3u8", response: .text(
            "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:3.0,\nseg.m4s\n#EXT-X-ENDLIST"))
        stub.register(host: "example.com", path: "/apple/init.mp4", response: .data(Data("init".utf8)))
        stub.register(host: "example.com", path: "/apple/seg.m4s", response: .data(Data("seg".utf8)))
        let cache = try cache()
        let artwork = CanvasArtwork(url: "https://example.com/apple/clip.m3u8")

        let joined = await cache.fetchLocalClip(for: artwork, session: stub.makeSession())
        let first = try XCTUnwrap(joined)
        XCTAssertEqual(first.pathExtension, "mp4", "AVFoundation reads the file by its extension")
        XCTAssertEqual(try Data(contentsOf: first), Data("initseg".utf8))
        let second = await cache.fetchLocalClip(for: artwork, session: stub.makeSession())
        XCTAssertEqual(second, first)
        XCTAssertEqual(stub.requests.count, 4, "the second ask is served from disk")
        let withFallback = CanvasArtwork(url: "https://example.com/apple/broken.m3u8", fallbackUrl: artwork.url)
        let fallen = await cache.fetchLocalClip(for: withFallback, session: stub.makeSession())
        XCTAssertEqual(fallen, first, "a primary that can't be joined falls to the fallback rendition")

        let failing = URLProtocolStub()
        failing.register(host: "example.com", response: .status(500))
        let missing = CanvasArtwork(url: "https://example.com/apple/other.m3u8")
        let none = await cache.fetchLocalClip(for: missing, session: failing.makeSession())
        XCTAssertNil(none, "no file, no stream stand-in")
    }

    func testFetchClipFallsBackToStreamingOnFailure() async throws {
        let stub = URLProtocolStub()
        stub.register(host: "example.com", response: .status(500))
        let cache = try cache()
        let artwork = CanvasArtwork(url: "https://example.com/canvas/a.mp4")
        let served = await cache.fetchClip(for: artwork, session: stub.makeSession())
        XCTAssertEqual(served.absoluteString, "https://example.com/canvas/a.mp4")
    }

    func testClear() throws {
        let cache = try cache()
        cache.store(Data("x".utf8), for: URL(string: "https://example.com/canvas/a.mp4")!)
        cache.clear()
        XCTAssertEqual(cache.currentBytes, 0)
    }

    func testACachedLocalClipIsOnlyWhatIsAlreadyOnDisk() throws {
        let cache = try cache()
        let progressive = CanvasArtwork(url: "https://clips.test/a.mp4")
        XCTAssertNil(cache.cachedLocalClip(for: progressive))
        let stored = cache.store(Data([1]), for: try XCTUnwrap(URL(string: progressive.url)))
        XCTAssertEqual(cache.cachedLocalClip(for: progressive), stored)

        // A stream's joined copy is kept under the playlist's URL plus `.mp4`.
        let playlist = try XCTUnwrap(URL(string: "https://clips.test/b.m3u8"))
        let hls = CanvasArtwork(url: playlist.absoluteString)
        XCTAssertNil(cache.cachedLocalClip(for: hls))
        let joined = cache.store(Data([2]), for: playlist.appendingPathExtension("mp4"))
        XCTAssertEqual(cache.cachedLocalClip(for: hls), joined)
    }
}
