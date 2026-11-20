import Foundation

/// A fix for how AVFoundation reads YouTube's AAC files. No Android counterpart: ExoPlayer reads
/// these files correctly.
///
/// YouTube's audio renditions (itag 139/140) are fragmented MP4: an init segment (`ftyp`,
/// `moov`), a `sidx`, then `moof`/`mdat` fragments. Its `moov` declares the *whole* track's
/// duration in `mvhd`, `tkhd` and `mdhd`, although the samples all live in the fragments.
/// AVFoundation treats that declaration as un-fragmented media and adds the fragments on top, so
/// every track reports about twice its length — measured 2026-09-26 on dQw4w9WgXcQ itag 140:
/// `AVURLAsset.duration` 426.13 s over HTTP and from a local copy, against 213.04 s of audio
/// (afinfo agrees with the latter). The seek bar would run to 7:06 and playback stop at 3:33.
///
/// Zeroing the track's declared durations (`tkhd`, `mdhd`; `mvhd` too, for consistency) makes
/// AVFoundation take the duration from the fragments alone — measured: 213.04 s. The bytes
/// patched are header fields only; no sample data changes.
///
/// Where to apply it: whoever hands these bytes to AVPlayer — the Playback module's resource
/// loader when it serves the first range, and the Downloads module after writing a file. The
/// init segment is always inside the first kilobyte or two, so patching the first chunk read
/// from offset 0 is enough. `ResolvedYouTubeStream.approxDurationMs` is the authoritative length
/// meanwhile.
public enum YouTubeMP4InitSegment {
    /// Zeroes the declared durations in the fragmented `moov` at the start of `data` (which
    /// must begin at file offset 0). Boxes cut off by the end of `data` are left alone.
    ///
    /// Only fragmented files are patched: the `moov` must carry an `mvex` box, the marker
    /// that samples live in `moof` fragments rather than in the movie itself. Zeroing the
    /// declared durations of a progressive MP4 would destroy real duration metadata instead
    /// of fixing double-duration, so such a `moov` reads as "nothing to do" and returns 0.
    ///
    /// - Returns: how many duration fields were zeroed (0 when `data` holds no such `moov`, or
    ///   they were already zero), so a caller can tell a patched file from an untouched one.
    @discardableResult
    public static func patchDurations(in data: inout Data) -> Int {
        var patched = 0
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let buffer = UnsafeMutableBufferPointer(start: base, count: raw.count)
            for box in boxes(in: buffer, from: 0, to: buffer.count) where box.type == "moov" {
                guard containsBox(buffer, box, named: "mvex") else { continue }
                patched += patchContainer(buffer, box)
            }
        }
        return patched
    }

    /// Whether `data` (from offset 0) looks like an MP4 init segment: it starts with `ftyp`.
    public static func isMP4(_ data: Data) -> Bool {
        data.count >= 8 && data[data.startIndex + 4..<data.startIndex + 8].elementsEqual(Array("ftyp".utf8))
    }

    private struct Box {
        let type: String
        let start: Int
        let bodyStart: Int
        let end: Int
    }

    /// Whether `container`'s direct children include a box called `name`.
    private static func containsBox(
        _ buffer: UnsafeMutableBufferPointer<UInt8>, _ container: Box, named name: String
    ) -> Bool {
        boxes(in: buffer, from: container.bodyStart, to: container.end).contains { $0.type == name }
    }

    private static func patchContainer(_ buffer: UnsafeMutableBufferPointer<UInt8>, _ container: Box) -> Int {
        var patched = 0
        for box in boxes(in: buffer, from: container.bodyStart, to: container.end) {
            switch box.type {
            case "trak", "mdia":
                patched += patchContainer(buffer, box)
            case "mvhd", "mdhd":
                // version, flags, then created/modified, timescale, duration.
                patched += zeroDuration(buffer, box, v0Offset: 16, v1Offset: 24)
            case "tkhd":
                // version, flags, created/modified, track id, reserved, duration.
                patched += zeroDuration(buffer, box, v0Offset: 20, v1Offset: 28)
            default:
                break
            }
        }
        return patched
    }

    private static func zeroDuration(_ buffer: UnsafeMutableBufferPointer<UInt8>, _ box: Box, v0Offset: Int, v1Offset: Int) -> Int {
        guard box.bodyStart < box.end else { return 0 }
        let version = buffer[box.bodyStart]
        let offset = box.bodyStart + (version == 1 ? v1Offset : v0Offset)
        let width = version == 1 ? 8 : 4
        guard offset + width <= box.end else { return 0 }
        var changed = false
        for index in offset..<offset + width where buffer[index] != 0 {
            buffer[index] = 0
            changed = true
        }
        return changed ? 1 : 0
    }

    /// Boxes wholly inside `[start, end)` of `buffer`; stops at the first one that runs past it.
    private static func boxes(in buffer: UnsafeMutableBufferPointer<UInt8>, from start: Int, to end: Int) -> [Box] {
        var result: [Box] = []
        var offset = start
        while offset + 8 <= end {
            var size = Int(readUInt32(buffer, offset))
            var header = 8
            if size == 1 {
                guard offset + 16 <= end else { break }
                let large = readUInt64(buffer, offset + 8)
                guard large <= UInt64(Int.max) else { break }
                size = Int(large)
                header = 16
            } else if size == 0 {
                size = end - offset
            }
            guard size >= header, size <= end - offset else { break }
            let type = String(decoding: buffer[offset + 4..<offset + 8], as: UTF8.self)
            result.append(Box(type: type, start: offset, bodyStart: offset + header, end: offset + size))
            offset += size
        }
        return result
    }

    private static func readUInt32(_ buffer: UnsafeMutableBufferPointer<UInt8>, _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(buffer[offset + $1]) }
    }

    private static func readUInt64(_ buffer: UnsafeMutableBufferPointer<UInt8>, _ offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(buffer[offset + $1]) }
    }
}
