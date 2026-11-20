import XCTest
@testable import StreamResolution

/// The init-segment duration fix AVFoundation needs for YouTube's fragmented AAC. The fixture is
/// the real first 1,019 bytes of dQw4w9WgXcQ itag 140 (`ftyp`, `moov`, `sidx`; no audio samples).
final class YouTubeMP4InitSegmentTests: XCTestCase {
    private let segment = StreamFixture.data("itag140_init_segment.mp4")

    // Offsets in the recorded file: ftyp 0, moov 24, mvhd 32, mvex 140, trak 180, sidx 723.
    private func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        data[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    func testRecordedInitSegmentDeclaresTheWholeTrack() {
        XCTAssertTrue(YouTubeMP4InitSegment.isMP4(segment))
        XCTAssertEqual(uint32(segment, 32 + 8 + 12), 44_100, "mvhd timescale")
        XCTAssertEqual(uint32(segment, 32 + 8 + 16), 9_397_248, "mvhd duration: 213.09 s at 44.1 kHz")
    }

    func testPatchZeroesTheThreeDeclaredDurationsAndNothingElse() throws {
        var patched = segment
        XCTAssertEqual(YouTubeMP4InitSegment.patchDurations(in: &patched), 3)
        XCTAssertEqual(patched.count, segment.count)
        XCTAssertEqual(uint32(patched, 32 + 8 + 16), 0, "mvhd")
        XCTAssertEqual(uint32(patched, 32 + 8 + 12), 44_100, "timescale untouched")
        let differing = zip(segment, patched).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        XCTAssertLessThanOrEqual(differing.count, 12, "three 32-bit fields at most")
        XCTAssertTrue(differing.allSatisfy { $0 < 723 }, "the sidx (from byte 723) is untouched")
    }

    func testPatchIsIdempotent() {
        var patched = segment
        YouTubeMP4InitSegment.patchDurations(in: &patched)
        let once = patched
        XCTAssertEqual(YouTubeMP4InitSegment.patchDurations(in: &patched), 0)
        XCTAssertEqual(patched, once)
    }

    func testPatchWorksOnASliceOfALargerBuffer() {
        var buffer = segment + Data(repeating: 0xAB, count: 4096)
        XCTAssertEqual(YouTubeMP4InitSegment.patchDurations(in: &buffer), 3)
        XCTAssertEqual(buffer.suffix(4096), Data(repeating: 0xAB, count: 4096))
    }

    /// A chunk that stops inside the moov, or bytes that are not MP4, are left alone.
    func testTruncatedOrForeignDataIsUntouched() {
        var truncated = segment.prefix(500)
        XCTAssertEqual(YouTubeMP4InitSegment.patchDurations(in: &truncated), 0)
        XCTAssertEqual(truncated, segment.prefix(500))
        var webm = Data([0x1A, 0x45, 0xDF, 0xA3]) + Data(repeating: 0x42, count: 64)
        XCTAssertEqual(YouTubeMP4InitSegment.patchDurations(in: &webm), 0)
        XCTAssertFalse(YouTubeMP4InitSegment.isMP4(webm))
        var empty = Data()
        XCTAssertEqual(YouTubeMP4InitSegment.patchDurations(in: &empty), 0)
    }

    /// Version-1 headers carry 64-bit durations at different offsets.
    func testVersionOneHeadersArePatchedToo() {
        func box(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let size = UInt32(8 + body.count)
            return withUnsafeBytes(of: size.bigEndian, Array.init) + Array(type.utf8) + body
        }
        let duration: [UInt8] = [0, 0, 0, 0, 0, 0x8F, 0x64, 0]
        // mvhd v1: version/flags 4, created 8, modified 8, timescale 4, duration 8, then the rest.
        let mvhd = box("mvhd", [1, 0, 0, 0] + Array(repeating: 0, count: 16) + [0, 0, 0xAC, 0x44] + duration + Array(repeating: 1, count: 80))
        // tkhd v1: version/flags 4, created 8, modified 8, track id 4, reserved 4, duration 8.
        let tkhd = box("tkhd", [1, 0, 0, 3] + Array(repeating: 0, count: 16) + [0, 0, 0, 1, 0, 0, 0, 0] + duration + Array(repeating: 1, count: 60))
        let mdhd = box("mdhd", [1, 0, 0, 0] + Array(repeating: 0, count: 16) + [0, 0, 0xAC, 0x44] + duration + [0x55, 0xC4, 0, 0])
        // Fragmented marker: without it the file is progressive and must be left alone.
        let moov = box("moov", mvhd + box("mvex", [0, 0, 0, 0]) + box("trak", tkhd + box("mdia", mdhd)))
        var file = Data(box("ftyp", Array("dashiso6".utf8)) + moov)
        XCTAssertEqual(YouTubeMP4InitSegment.patchDurations(in: &file), 3)
        XCTAssertFalse(file.contains(0x8F), "every 64-bit duration zeroed")
    }

    /// A progressive MP4 — a `moov` with no `mvex` — is left alone: zeroing its declared
    /// durations would destroy real metadata instead of fixing double-duration.
    func testProgressiveMoovWithoutMvexIsUntouched() {
        func box(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let size = UInt32(8 + body.count)
            return withUnsafeBytes(of: size.bigEndian, Array.init) + Array(type.utf8) + body
        }
        let mvhd = box("mvhd", [0, 0, 0, 0] + Array(repeating: 0, count: 12) + [0, 0, 0xAC, 0x44, 0, 0, 0x8F, 0x64])
        let moov = box("moov", mvhd)
        var file = Data(box("ftyp", Array("isom".utf8)) + moov)
        let before = file
        XCTAssertEqual(YouTubeMP4InitSegment.patchDurations(in: &file), 0)
        XCTAssertEqual(file, before)
    }

    /// A 64-bit box size near `Int.max` past the first box ends the scan instead of overflowing.
    func testHugeLargeSizeBoxIsIgnored() {
        let ftyp: [UInt8] = [0, 0, 0, 12] + Array("ftypisom".utf8)
        let huge: [UInt8] = [0, 0, 0, 1] + Array("moov".utf8) + withUnsafeBytes(of: UInt64(Int.max).bigEndian, Array.init)
        var file = Data(ftyp + huge)
        XCTAssertEqual(YouTubeMP4InitSegment.patchDurations(in: &file), 0)
    }
}
