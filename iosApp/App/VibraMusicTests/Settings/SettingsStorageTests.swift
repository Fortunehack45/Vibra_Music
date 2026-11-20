import AudioCache
import XCTest
@testable import Vibra Music

/// PORTING.md "Storage controls" — Done: "Clear song cache" frees the space it reports.
final class SettingsStorageTests: XCTestCase {
    func testClearSongCacheFreesTheSpaceItReports() async throws {
        let directory = makeTemporaryDirectory(self)
        let cache = try AudioStreamCache(configuration: .init(directory: directory.appending(path: "cache"),
                                                              minimumFreeBytes: 0, availableCapacity: { _ in nil }))
        let bytes = Data((0..<(512 * 1_024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let filled = await cache.cacheCompletely(.youtube(videoId: "storageTest1"),
                                                 source: InMemoryAudioSource(data: bytes, mimeType: "audio/mp4"))
        XCTAssertTrue(filled)
        let before = await cache.usage()
        XCTAssertGreaterThanOrEqual(before.cachedBytes, Int64(bytes.count))

        let freed = await SettingsStorage.clearSongCache(cache)

        let after = await cache.usage()
        XCTAssertEqual(after.cachedBytes, 0)
        XCTAssertEqual(after.entryCount, 0)
        XCTAssertEqual(freed, before.diskBytes - after.diskBytes, "reports exactly what left the disk")
        XCTAssertGreaterThanOrEqual(freed, Int64(bytes.count))
    }

    func testClearSongCacheWithNoCacheIsANoOp() async {
        let freed = await SettingsStorage.clearSongCache(nil)
        XCTAssertEqual(freed, 0)
    }

    func testClearImageCacheEmptiesTheDiskCache() async throws {
        let directory = makeTemporaryDirectory(self)
        let cache = ArtworkImageCache(directory: directory)
        try Data(count: 64 * 1_024).write(to: directory.appending(path: "cover"))
        XCTAssertEqual(cache.diskUsage(), 64 * 1_024)

        let freed = await SettingsStorage.clearImageCache(cache)

        XCTAssertEqual(freed, 64 * 1_024, "reports what left the disk")
        XCTAssertEqual(cache.diskUsage(), 0)
    }
}
