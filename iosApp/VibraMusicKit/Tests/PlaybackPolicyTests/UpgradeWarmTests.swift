import XCTest
import VibraMusicTestSupport
@testable import PlaybackPolicy

/// What a quality upgrade warms before the swap: the header each container declares (and nothing
/// past a small cap), and the bytes the swap position maps to.
final class UpgradeWarmTests: XCTestCase {
    private let fixtures = FixtureLoader(bundle: .module)

    private func layout(_ name: String) throws -> UpgradeWarm.Layout {
        let data = try Data(contentsOf: fixtures.url("audio/\(name)"))
        guard case .found(let layout) = UpgradeWarm.scan(data, length: Int64(data.count)) else {
            XCTFail("no layout for \(name): \(UpgradeWarm.scan(data, length: Int64(data.count)))")
            throw XCTSkip()
        }
        XCTAssertEqual(layout.audio.upperBound, Int64(data.count), "\(name)'s audio runs to its end")
        return layout
    }

    // MARK: The header each fixture declares

    /// `ftyp`, `moov` and the encoder's `free` padding, up to the `mdat` body: the boxes a player
    /// walks before its first sample.
    func testAnMP4sHeaderIsItsBoxesUpToTheAudio() throws {
        for name in ["aac_256.m4a", "heaac_64.m4a", "alac_16_44.m4a", "flac_24_96_in_mp4.m4a"] {
            let found = try layout(name)
            XCTAssertEqual(found.headerEnd, 4_096, name)
            XCTAssertEqual(found.headerRange, 0..<4_096, name)
            XCTAssertEqual(found.audio.lowerBound, 4_096, name)
        }
    }

    func testAFLACsHeaderIsItsMetadataBlocks() throws {
        let found = try layout("flac_24_96.flac")
        // "fLaC", STREAMINFO (4 + 34), VORBIS_COMMENT (4 + 54).
        XCTAssertEqual(found.headerRange, 0..<100)
        XCTAssertEqual(found.anchors, [], "no seek table in this file")
    }

    func testAWAVsHeaderRunsToItsDataChunk() throws {
        XCTAssertEqual(try layout("pcm_16_44.wav").headerRange, 0..<44)
    }

    /// The `data` chunk's body opens with a four-byte edit count before the packets.
    func testACAFsHeaderRunsPastItsEditCount() throws {
        XCTAssertEqual(try layout("opus_160.caf").headerRange, 0..<4_096)
    }

    /// A cover far bigger than any header is still header, but the warm stops at the cap: past a
    /// megabyte, a swap that never happens has cost too much.
    func testAHeaderPastTheCapIsWarmedOnlyToTheCap() {
        var flac = Data("fLaC".utf8)
        flac += [0x00, 0x00, 0x00, 34] + Self.streamInfo(sampleRate: 44_100)
        flac += [0x86, 0x1E, 0x84, 0x80] // last block: PICTURE, 2,000,000 bytes
        // Only the block headers are in hand: a cover needn't be read to find where it ends.
        guard case .found(let found) = UpgradeWarm.scan(flac, length: 10_000_000) else {
            return XCTFail("\(UpgradeWarm.scan(flac, length: 10_000_000))")
        }
        XCTAssertEqual(found.headerEnd, 4 + 38 + 4 + 2_000_000)
        XCTAssertEqual(found.headerRange, 0..<UpgradeWarm.headerCapBytes)
    }

    /// A chain of blocks that runs past the bytes in hand asks for the next header, not for the
    /// fixed megabyte.
    func testAHeaderPastTheBytesInHandAsksForTheNextBlock() {
        var flac = Data("fLaC".utf8)
        flac += [0x00, 0x00, 0x00, 34] + Self.streamInfo(sampleRate: 44_100)
        flac += [0x06, 0x04, 0x00, 0x00] // PICTURE, 262,144 bytes, not last
        XCTAssertEqual(UpgradeWarm.scan(flac, length: 5_000_000), .needMore(through: 4 + 38 + 4 + 262_144 + 4))
    }

    func testAnUnknownContainerIsLeftToTheFixedOpening() {
        XCTAssertEqual(UpgradeWarm.scan(Data([0x1A, 0x45, 0xDF, 0xA3] + [UInt8](repeating: 0, count: 60)), length: 1_000_000), .unknown)
    }

    // MARK: The swap point

    /// PCM is constant-rate, so the window is exact: a second before the playhead to twelve after
    /// (Android's `UPGRADE_PREBUFFER_MS`).
    func testTheWindowAroundAPCMSwapIsExact() {
        let bytesPerSecond: Int64 = 176_400
        let layout = UpgradeWarm.Layout(headerEnd: 44, audio: 44..<(44 + 60 * bytesPerSecond))
        XCTAssertEqual(UpgradeWarm.window(layout, position: 30, duration: 60), (44 + 29 * bytesPerSecond)..<(44 + 42 * bytesPerSecond))
    }

    /// Hi-res lossless gets its twelve seconds too: the old megabyte cap held under two of
    /// 24-bit/96 kHz, and the swap then read the rest off the network mid-crossover.
    func testHiResLosslessGetsTheWholeWindow() {
        let bytesPerSecond: Int64 = 576_000 // 24-bit stereo at 96 kHz
        let layout = UpgradeWarm.Layout(headerEnd: 100, audio: 100..<(100 + 60 * bytesPerSecond))
        XCTAssertEqual(UpgradeWarm.window(layout, position: 30, duration: 60), (100 + 29 * bytesPerSecond)..<(100 + 42 * bytesPerSecond))
    }

    /// A mapping gone wrong can't ask for a whole file: the window stops at its cap.
    func testAWindowNeverPassesItsCap() {
        let bytesPerSecond: Int64 = 4_000_000
        let layout = UpgradeWarm.Layout(headerEnd: 100, audio: 100..<(100 + 60 * bytesPerSecond))
        let window = UpgradeWarm.window(layout, position: 30, duration: 60)
        XCTAssertEqual(window?.lowerBound, 100 + 29 * bytesPerSecond)
        XCTAssertEqual(window.map { $0.upperBound - $0.lowerBound }, UpgradeWarm.windowCapBytes)
    }

    /// The swap waits for the whole window on disk, however the cache's ranges lie: out of order and
    /// touching counts, a hole anywhere in the window doesn't.
    func testAWindowIsOnDiskOnlyWithNoHoleInIt() {
        XCTAssertTrue(UpgradeWarm.covers([500..<900, 0..<200, 200..<500], 100..<900))
        XCTAssertTrue(UpgradeWarm.covers([0..<1_000], 100..<900))
        XCTAssertFalse(UpgradeWarm.covers([0..<400, 401..<1_000], 100..<900), "a byte missing at 400")
        XCTAssertFalse(UpgradeWarm.covers([0..<800], 100..<900), "the window's tail isn't in")
        XCTAssertFalse(UpgradeWarm.covers([], 100..<900))
    }

    /// An MP4's chunk offsets pin times to bytes, so a time at a chunk boundary maps to the chunk's
    /// first byte, whatever the bitrate did before it.
    func testAnMP4sChunksPinTheMapping() throws {
        let found = try layout("aac_256.m4a")
        // 22 AAC frames of 1,024 samples at 44.1 kHz in the first chunk, then the second at 20,966.
        let second = 22.0 * 1_024 / 44_100
        XCTAssertEqual(found.anchors, [UpgradeWarm.Anchor(seconds: 0, offset: 4_096), UpgradeWarm.Anchor(seconds: second, offset: 20_966)])
        XCTAssertEqual(UpgradeWarm.offset(found, at: second, duration: 24_576.0 / 44_100), 20_966)
    }

    /// A FLAC seek table pins its points, so a variable bitrate can't drag the window off the swap.
    func testAFLACSeekTablePinsTheMapping() {
        var flac = Data("fLaC".utf8)
        flac += [0x00, 0x00, 0x00, 34] + Self.streamInfo(sampleRate: 44_100)
        flac += [0x83, 0x00, 0x00, 36] // last block: SEEKTABLE, two points
        flac += Self.seekPoint(sample: 0, offset: 0) + Self.seekPoint(sample: 441_000, offset: 3_000_000)
        guard case .found(let found) = UpgradeWarm.scan(flac, length: 12_000_000) else {
            return XCTFail("\(UpgradeWarm.scan(flac, length: 12_000_000))")
        }
        let audioStart = Int64(flac.count)
        XCTAssertEqual(found.anchors, [UpgradeWarm.Anchor(seconds: 0, offset: audioStart), UpgradeWarm.Anchor(seconds: 10, offset: audioStart + 3_000_000)])
        // Without the point, 10 s of a 60 s track maps to a sixth of the file.
        XCTAssertEqual(UpgradeWarm.offset(found, at: 10, duration: 60), audioStart + 3_000_000)
    }

    /// The player walks a FLAC's frames up to the swap point, so all of them have to be on disk.
    func testAFLACsWindowRunsFromItsFirstFrame() {
        var flac = Data("fLaC".utf8)
        flac += [0x80, 0x00, 0x00, 34] + Self.streamInfo(sampleRate: 44_100)
        guard case .found(let found) = UpgradeWarm.scan(flac, length: 6_000_042) else {
            return XCTFail("\(UpgradeWarm.scan(flac, length: 6_000_042))")
        }
        XCTAssertEqual(UpgradeWarm.window(found, position: 30, duration: 60), 42..<(42 + 4_200_000))
    }

    /// However deep, it isn't cut short of the swap point: a copy too slow to get there is dropped
    /// by the warm's deadline, not swapped to and stalled on.
    func testAWalkedWindowIsNotCappedShortOfTheSwap() {
        let bytesPerSecond: Int64 = 1_000_000
        let layout = UpgradeWarm.Layout(headerEnd: 42, audio: 42..<(42 + 600 * bytesPerSecond), isWalkedFromTheStart: true)
        XCTAssertEqual(UpgradeWarm.window(layout, position: 300, duration: 600), 42..<(42 + 312 * bytesPerSecond))
    }

    // MARK: Helpers

    /// A STREAMINFO body (34 bytes) whose only meaningful field is the sample rate.
    private static func streamInfo(sampleRate: Int) -> [UInt8] {
        var body = [UInt8](repeating: 0, count: 34)
        body[10] = UInt8((sampleRate >> 12) & 0xFF)
        body[11] = UInt8((sampleRate >> 4) & 0xFF)
        body[12] = UInt8((sampleRate & 0x0F) << 4) | 0x02 // stereo
        return body
    }

    private static func seekPoint(sample: UInt64, offset: UInt64) -> [UInt8] {
        func bigEndian(_ value: UInt64) -> [UInt8] { (0..<8).map { UInt8((value >> (56 - 8 * UInt64($0))) & 0xFF) } }
        return bigEndian(sample) + bigEndian(offset) + [0x10, 0x00]
    }
}
