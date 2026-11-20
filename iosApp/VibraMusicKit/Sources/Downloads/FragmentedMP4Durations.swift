import Foundation

/// Stops AVFoundation reporting a downloaded YouTube track at twice its length. No Android
/// counterpart: ExoPlayer reads these files correctly.
///
/// YouTube's audio renditions (itag 139/140) are fragmented MP4: `ftyp`, a `moov` whose `mvex`
/// says the samples live in fragments, a `sidx`, then `moof`/`mdat` pairs. The `moov` still
/// declares the whole track's duration in `mvhd`, `tkhd` and `mdhd`, and AVFoundation adds the
/// fragments on top of that declaration — 426.13 s for a 213.04 s track, from a local file as much
/// as over HTTP — so the seek bar runs to twice the song and a downloaded track "ends" halfway.
/// Zeroing those three fields makes it take the duration from the fragments alone. Only header
/// fields change, in place and at the same width, so no offset anywhere in the file moves.
///
/// The same fix as StreamResolution's `YouTubeMP4InitSegment` (and AudioCache's copy of it),
/// repeated here because this module can't depend on either. Like AudioCache's, it only touches a
/// `moov` that has an `mvex`: an ordinary MP4 (a source's ALAC, an AAC file AVAudioFile wrote)
/// declares its real duration there, and zeroing it would break that file instead. Flattened
/// HLS/DASH packages are fragmented too, so they get the same treatment whatever their init
/// segment declared.
enum FragmentedMP4Durations {
    /// How much of the file's opening is read looking for the `moov`. A fragmented `moov` carries
    /// no sample tables and is well under a kilobyte for YouTube; a `moov` that isn't inside this
    /// is not one this applies to.
    static let maxInitSegmentBytes = 1_024 * 1_024

    /// Boxes that may sit between `ftyp` and `moov` without meaning the `moov` isn't up front.
    private static let skippable: Set<String> = ["free", "skip", "wide", "pdin", "uuid"]

    /// Zeroes the declared durations of a fragmented `moov` at the start of `bytes`.
    /// - Returns: how many duration fields changed (0 for an unfragmented file, one whose `moov`
    ///   isn't up front, or one already patched).
    @discardableResult
    static func patch(_ bytes: inout [UInt8]) -> Int {
        guard let moov = leadingMoov(bytes),
              Mp4Tagger.parseBoxes(bytes, moov.contentOffset, moov.end).contains(where: { $0.type == "mvex" })
        else { return 0 }
        return zeroDurations(in: &bytes, container: moov)
    }

    /// Patches the file at `url` in place (see ``patch(_:)``).
    /// - Returns: how many duration fields changed.
    @discardableResult
    static func patchFile(at url: URL) throws -> Int {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        guard let head = try handle.read(upToCount: maxInitSegmentBytes), !head.isEmpty else { return 0 }
        var bytes = [UInt8](head)
        guard let moov = leadingMoov(bytes) else { return 0 }
        // Only the `ftyp` … `moov` opening is rewritten, at its own length.
        bytes = Array(bytes[0..<moov.end])
        let changed = patch(&bytes)
        guard changed > 0 else { return 0 }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(bytes))
        try handle.synchronize()
        return changed
    }

    /// The `moov` of a file that opens `ftyp` … `moov`, wholly inside `bytes`.
    private static func leadingMoov(_ bytes: [UInt8]) -> Mp4Tagger.BoxRef? {
        var first = true
        var offset = 0
        while offset + 8 <= bytes.count {
            let size32 = readU32(bytes, offset)
            // A box that runs to the end of the file (0) or claims more than is here can't be
            // walked past; a 64-bit size this early is not a layout this is for.
            guard size32 >= 8, Int(size32) <= bytes.count - offset else { return nil }
            let type = fourCC(bytes, offset + 4)
            let end = offset + Int(size32)
            if first {
                guard type == "ftyp" else { return nil }
                first = false
            } else if type == "moov" {
                return Mp4Tagger.BoxRef(offset: offset, headerLen: 8, size: Int(size32), rawSize32: size32, type: type)
            } else if !skippable.contains(type) {
                // `mdat`, `sidx`, `moof`: the `moov` isn't up front (and a fragmented file always
                // has it up front).
                return nil
            }
            offset = end
        }
        return nil
    }

    private static func zeroDurations(in bytes: inout [UInt8], container: Mp4Tagger.BoxRef) -> Int {
        var patched = 0
        for box in Mp4Tagger.parseBoxes(bytes, container.contentOffset, container.end) {
            switch box.type {
            case "trak", "mdia":
                patched += zeroDurations(in: &bytes, container: box)
            case "mvhd", "mdhd":
                // version, flags, then created/modified, timescale, duration.
                patched += zeroField(in: &bytes, box, versionZeroOffset: 16, versionOneOffset: 24)
            case "tkhd":
                // version, flags, created/modified, track id, reserved, duration.
                patched += zeroField(in: &bytes, box, versionZeroOffset: 20, versionOneOffset: 28)
            default:
                break
            }
        }
        return patched
    }

    private static func zeroField(in bytes: inout [UInt8], _ box: Mp4Tagger.BoxRef, versionZeroOffset: Int, versionOneOffset: Int) -> Int {
        guard box.contentOffset < box.end else { return 0 }
        let versionOne = bytes[box.contentOffset] == 1
        let offset = box.contentOffset + (versionOne ? versionOneOffset : versionZeroOffset)
        let width = versionOne ? 8 : 4
        guard offset + width <= box.end else { return 0 }
        var changed = false
        for index in offset..<(offset + width) where bytes[index] != 0 {
            bytes[index] = 0
            changed = true
        }
        return changed ? 1 : 0
    }
}
