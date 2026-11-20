import VibraMusicCore
import XCTest
@testable import Vibra Music

/// The decoded-artwork budget is a share of device RAM under an absolute ceiling, and
/// a disk cache already over its budget is trimmed when the cache is created — not only after the
/// next network load.
final class ArtworkImageCacheTests: XCTestCase {
    /// Whatever the device ships with, the memory budget stays under the ceiling; below the
    /// ceiling the 20% share of RAM still applies.
    func testTheMemoryBudgetNeverExceedsTheCeilingWhateverTheRAM() {
        let ceiling = 150 * 1024 * 1024
        let table: [(ram: UInt64, budget: Int)] = [
            (500_000_000, 100_000_000), // small RAM: the 20% share, uncapped
            (2 * 1_073_741_824, ceiling), // 2 GB
            (3 * 1_073_741_824, ceiling), // 3 GB
            (6 * 1_073_741_824, ceiling), // 6 GB
            (8 * 1_073_741_824, ceiling), // 8 GB
            (16 * 1_073_741_824, ceiling), // 16 GB
        ]
        for row in table {
            let budget = ArtworkImageCache.memoryBudgetBytes(physicalMemory: row.ram)
            XCTAssertLessThanOrEqual(budget, ceiling, "RAM \(row.ram) bytes")
            XCTAssertEqual(budget, row.budget, "RAM \(row.ram) bytes")
        }
    }

    /// The cache applies a budget under the ceiling, not a fresh share of device RAM.
    func testTheCacheAppliesABudgetUnderTheCeiling() {
        let directory = makeTemporaryDirectory(self)
        let cache = ArtworkImageCache(directory: directory)
        XCTAssertLessThanOrEqual(cache.memoryBudgetBytes, 150 * 1024 * 1024)
    }

    /// A cache seeded over its disk budget is trimmed back under it once the cache is created,
    /// with no network load to trigger one, and the eviction runs least-recently-used first.
    func testAnOverBudgetDiskCacheIsTrimmedWhenTheCacheIsCreated() async throws {
        let directory = makeTemporaryDirectory(self).appending(path: "Artwork", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        for (index, name) in ["oldest", "middle", "newest"].enumerated() {
            let file = directory.appending(path: name)
            XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))
            // Sparse: the trim counts file sizes, so the seed costs no disk writes.
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: 40 * 1024 * 1024)
            try handle.close()
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(TimeInterval(-3600 * (3 - index)))],
                                                  ofItemAtPath: file.path)
        }

        let cache = ArtworkImageCache(directory: directory)

        await waitUntil("the launch trim brings the disk back under budget", timeout: 30) {
            cache.diskUsage() <= ArtworkImageCache.diskLimitBytes
        }
        XCTAssertLessThanOrEqual(cache.diskUsage(), ArtworkImageCache.diskLimitBytes)
        XCTAssertEqual(cache.diskUsage(), 80 * 1024 * 1024, "one 40 MB file goes; the budget is 100 MB")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "oldest").path),
                       "the least recently used file is the one evicted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: "newest").path),
                      "recent files survive the trim")
    }

    /// A video's thumbnail (1280×720, with no size hint to ask the host for less) drawn in a list
    /// row is decoded for the row: its short side at the row's pixels, not the download's 720, so
    /// the decode is cheap and the bitmap kept in memory is the row's (Coil decodes to the view).
    func testACoverIsDecodedAtTheSizeItIsDrawn() async throws {
        let url = URL(string: "https://covers.test/\(UUID().uuidString)/1280x720.jpg")!
        let cache = ArtworkImageCache(directory: makeTemporaryDirectory(self), session: CoverServer.session())

        let loaded = await cache.image(for: url, pixels: ArtworkSize.row)

        let image = try XCTUnwrap(loaded)
        XCTAssertEqual(Double(image.size.height * image.scale), Double(ArtworkSize.row), accuracy: 1,
                       "the short side is the row's")
        XCTAssertEqual(Double(image.size.width * image.scale), 285, accuracy: 2,
                       "the picture keeps its shape, so the square box still crops it")
    }

    /// A download that looks like a picture but doesn't decode isn't kept: the next request goes
    /// back to the network rather than reading the same broken file from disk for good.
    func testACoverThatDoesNotDecodeIsDownloadedAgain() async {
        let url = URL(string: "https://covers.test/\(UUID().uuidString)/broken.jpg")!
        let cache = ArtworkImageCache(directory: makeTemporaryDirectory(self), session: CoverServer.session())

        let first = await cache.image(for: url, pixels: ArtworkSize.row)
        let second = await cache.image(for: url, pixels: ArtworkSize.row)

        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(CoverServer.requests(for: url), 2, "the second request downloads again")
    }

    /// The same cover drawn at two sizes at once (a video's thumbnail in the mini player and in the
    /// player, on a track change) is downloaded once, and each size is decoded for its own box.
    func testOneCoverDrawnAtTwoSizesIsDownloadedOnce() async throws {
        let url = URL(string: "https://covers.test/\(UUID().uuidString)/1280x720.jpg")!
        let cache = ArtworkImageCache(directory: makeTemporaryDirectory(self), session: CoverServer.session())

        async let row = cache.image(for: url, pixels: ArtworkSize.row)
        async let whole = cache.image(for: url)
        let (small, large) = await (row, whole)

        XCTAssertEqual(CoverServer.requests(for: url), 1, "both sizes share one download")
        let rowHeight = try XCTUnwrap(small).size.height
        let wholeHeight = try XCTUnwrap(large).size.height
        XCTAssertEqual(Double(rowHeight), Double(ArtworkSize.row), accuracy: 1)
        XCTAssertEqual(Double(wholeHeight), 720, accuracy: 1)
    }
}
