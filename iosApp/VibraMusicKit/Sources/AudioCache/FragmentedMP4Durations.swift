import Foundation
import StreamResolution

/// Holds back the opening of a stream until its MP4 init segment is complete, so YouTube's
/// duration fix is written to disk (and served) with it. No Android counterpart: ExoPlayer reads
/// these files correctly.
///
/// YouTube's audio renditions (itag 139/140) are fragmented MP4: `ftyp`, a `moov` whose `mvex`
/// says the samples live in fragments, a `sidx`, then `moof`/`mdat` pairs. The `moov` still
/// declares the whole track's duration in `mvhd`, `tkhd` and `mdhd`, and AVFoundation adds the
/// fragments on top of that declaration: dQw4w9WgXcQ reports 426.13 s against 213.04 s of audio,
/// so the seek bar runs to 7:06 and playback stops at 3:33.
///
/// The zeroing itself is StreamResolution's `YouTubeMP4InitSegment.patchDurations(in:)` — the one
/// canonical fix, shared with Downloads — applied here only to sources that opt in via
/// `AudioRangeDataSource/requiresYouTubeDurationFix` (YouTube-origin streams, and downloaded
/// YouTube files flagged as such). It additionally runs only on a `moov` that carries an `mvex`:
/// an ordinary MP4 (an addon's M4A, a file the user imported) declares its real duration there,
/// and zeroing it would break that file instead. Only header fields change; no sample data does.
///
/// The fix is written into the cached copy, so every later reader (the player, a replay offline,
/// Automix's decoder) sees the patched header. Files served straight from the device get the same
/// fix on the way out; the file itself isn't changed.
enum FragmentedMP4Durations {
    /// How much of the opening is held back looking for the `moov` before giving up on it. A
    /// fragmented `moov` carries no sample tables and is well under a kilobyte for YouTube.
    static let maxInitSegmentBytes = 1_024 * 1_024

    enum Scan: Equatable {
        /// More bytes are needed to decide.
        case needMore
        /// Not a file this applies to (not MP4, `moov` not up front, or too large to wait for).
        case notApplicable
        /// The `moov` ends at this offset; everything before it is in hand.
        case initSegment(end: Int)
    }

    /// Looks for a complete `ftyp` … `moov` opening at the start of `data` (file offset 0).
    static func scan(_ data: Data) -> Scan {
        // Read in place: this runs on every piece while the opening is held back.
        let bytes = BoxBytes(data)
        var offset = 0
        var first = true
        while true {
            guard offset + 16 <= bytes.count || (offset + 8 <= bytes.count && bytes.uint32(at: offset) != 1) else {
                return data.count >= maxInitSegmentBytes ? .notApplicable : .needMore
            }
            guard let box = header(in: bytes, at: offset) else { return .notApplicable }
            if first {
                guard box.type == "ftyp" else { return .notApplicable }
                first = false
            } else if box.type == "moov" {
                guard box.end <= maxInitSegmentBytes else { return .notApplicable }
                return box.end <= data.count ? .initSegment(end: box.end) : .needMore
            } else if !skippable.contains(box.type) {
                // `mdat`, `sidx`, `moof`: the `moov` isn't up front, so the durations it declares
                // aren't what AVFoundation reads first (and a fragmented file always has it up front).
                return .notApplicable
            }
            guard box.end > offset else { return .notApplicable }
            offset = box.end
        }
    }

    /// Whether `data` (from file offset 0) holds the init segment of a *fragmented* file: a
    /// complete `ftyp` … `moov` opening whose `moov` contains an `mvex`. Only such files get their
    /// declared durations zeroed; an ordinary file declares its real length there.
    static func isFragmented(_ data: Data) -> Bool {
        guard case .initSegment(let end) = scan(data) else { return false }
        let view = BoxBytes(data.subdata(in: data.startIndex..<(data.startIndex + end)))
        guard let moov = children(in: view, from: 0, to: end).first(where: { $0.type == "moov" }) else {
            return false
        }
        return children(in: view, from: moov.bodyStart, to: moov.end).contains(where: { $0.type == "mvex" })
    }

    /// Zeroes the declared durations of a fragmented `moov` at the start of `data` (file offset 0)
    /// using StreamResolution's canonical fix.
    ///
    /// - Returns: how many duration fields changed (0 for an unfragmented file, a non-MP4 file,
    ///   or one already patched).
    @discardableResult
    static func patchYouTubeInitSegment(_ data: inout Data) -> Int {
        guard isFragmented(data) else { return 0 }
        return YouTubeMP4InitSegment.patchDurations(in: &data)
    }

    // MARK: Boxes

    private static let skippable: Set<String> = ["free", "skip", "wide", "pdin", "uuid"]

    struct Box {
        let type: String
        let start: Int
        let bodyStart: Int
        let end: Int
    }

    /// Big-endian reads straight out of a `Data`, whatever its start index.
    struct BoxBytes {
        let data: Data
        init(_ data: Data) { self.data = data }
        var count: Int { data.count }
        func byte(at offset: Int) -> UInt8 { data[data.startIndex + offset] }
        func uint32(at offset: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(byte(at: offset + $1)) } }
        func uint64(at offset: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(byte(at: offset + $1)) } }
        func type(at offset: Int) -> String { String(decoding: (0..<4).map { byte(at: offset + $0) }, as: UTF8.self) }
    }

    private static func header(in bytes: BoxBytes, at offset: Int) -> Box? {
        guard offset + 8 <= bytes.count else { return nil }
        var size = Int(bytes.uint32(at: offset))
        var headerLength = 8
        if size == 1 {
            guard offset + 16 <= bytes.count else { return nil }
            let large = bytes.uint64(at: offset + 8)
            guard large <= UInt64(Int32.max) else { return nil }
            size = Int(large)
            headerLength = 16
        } else if size == 0 {
            // Runs to the end of the file: nothing after it to find.
            return nil
        }
        guard size >= headerLength else { return nil }
        let type = bytes.type(at: offset + 4)
        return Box(type: type, start: offset, bodyStart: offset + headerLength, end: offset + size)
    }

    /// Boxes wholly inside `[start, end)`; stops at the first one that runs past it.
    private static func children(in bytes: BoxBytes, from start: Int, to end: Int) -> [Box] {
        var result: [Box] = []
        var offset = start
        while let box = header(in: bytes, at: offset), box.end <= end {
            result.append(box)
            offset = box.end
        }
        return result
    }
}

/// Holds back the opening of a stream until its init segment can be patched (see
/// ``FragmentedMP4Durations``), then releases it, patched or not, and passes everything after it
/// straight through.
struct InitSegmentGate {
    private var buffer = Data()
    private(set) var isOpen = false

    /// The bytes ready to go on, or nil while the opening is still being held. `patch` runs on
    /// the complete init segment before it is released (use
    /// `FragmentedMP4Durations/patchYouTubeInitSegment(_:)` for a YouTube stream, or nothing for
    /// bytes that must go out byte-identical).
    mutating func feed(_ piece: Data, patch: (inout Data) -> Int = { _ in 0 }) -> Data? {
        if isOpen { return piece }
        buffer.append(piece)
        switch FragmentedMP4Durations.scan(buffer) {
        case .needMore:
            return nil
        case .notApplicable:
            break
        case .initSegment:
            _ = patch(&buffer)
        }
        return release()
    }

    /// Whatever is still held, for a stream that ended before the opening was complete.
    mutating func release() -> Data {
        isOpen = true
        defer { buffer = Data() }
        return buffer
    }
}
