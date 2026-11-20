import Foundation

/// The lyrics already sitting inside a local audio file (Android: `EmbeddedLyrics.kt`).
///
/// A downloaded or imported track can carry its lyrics in its own metadata; asking the
/// network for them again every time it is played is a round trip to arrive at a string
/// that is already on disk, and it is the reason a downloaded song showed nothing at all
/// with the connection off.
///
/// Two fields are read, in this order:
///  - `VIBRAMUSIC_LYRICS` (`LRCFormat.wordLyricsField`), this app's own, holding the
///    "enhanced" A2 form with the word timings intact;
///  - the container's standard lyrics field (`©lyr`, Vorbis `LYRICS`, Matroska `LYRICS`),
///    holding plain `[mm:ss.xx]` LRC — what every other player reads.
///
/// Never throws. A file that isn't MP4/M4A, FLAC or Matroska/WebM, or is one and has no
/// lyrics in it, is nil — the caller falls back to the network.
///
/// An HLS/DASH offline package (a playlist over a directory of segments) has no container
/// to read, so its lyrics sit beside the playlist as `lyrics.lrc`; `sidecar(path:)` is tried
/// first for those.
public enum EmbeddedLyrics {

    /// Most bytes worth pulling to find a tag. A cap rather than a size: the length of the
    /// metadata region is stated *by the file*, so a corrupt or hostile one could claim any
    /// number at all, and the writer caps what it stores at 64k.
    static let maxTagBytes = 8 * 1024 * 1024

    /// The lyrics inside the file at `url`, or nil when it has none worth showing. Reads on
    /// a background executor.
    public static func lyrics(forFileAt url: URL) async -> [LyricLine]? {
        await Task.detached(priority: .utility) {
            guard let raw = read(url) else { return nil }
            // The same last pass the network sources get, so a downloaded track and a
            // streamed one draw their backing vocals the same way.
            let lines = LRCFormat.parse(raw)
            return lines.contains(where: { !$0.text.kIsBlank }) ? lines.withBackgroundVocals() : nil
        }.value
    }

    /// The raw LRC text for the file, preferring this app's word-timed field.
    static func read(_ url: URL) -> String? {
        guard url.isFileURL else { return nil }
        if let sidecar = sidecar(path: url.path) { return sidecar }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: maxTagBytes) else { return nil }
        if let found = fromBytes(head) { return found }
        // A file longer than the window can keep its tags past it: an m4a written without the
        // faststart pass has `moov` after `mdat`, and Matroska appends tags after the audio.
        guard head.count == maxTagBytes, let found = fromBeyondHead(handle, head: head), !found.kIsBlank else { return nil }
        return found
    }

    /// The lyrics when the container's tags lie past the first `maxTagBytes`: `moov` found by
    /// stepping box to box through the file, or the last `maxTagBytes` of a Matroska file.
    /// FLAC is not tried: its comment block is part of the metadata that opens the file.
    private static func fromBeyondHead(_ handle: FileHandle, head: Data) -> String? {
        let start = [UInt8](head.prefix(16))
        do {
            let fileSize = try handle.seekToEnd()
            if start.starts(with: matroskaMagic) {
                let window = UInt64(maxTagBytes)
                guard fileSize >= window else { return nil }
                try handle.seek(toOffset: fileSize - window)
                return try handle.read(upToCount: maxTagBytes).flatMap { matroska([UInt8]($0)) }
            }
            return try isMP4(start) ? moovBeyondHead(handle, fileSize: fileSize) : nil
        } catch {
            return nil
        }
    }

    /// Walks the top-level boxes by their headers alone (the audio is never read) to `moov`,
    /// then reads that one box.
    private static func moovBeyondHead(_ handle: FileHandle, fileSize: UInt64) throws -> String? {
        var position: UInt64 = 0
        // A real file has a handful of top-level boxes; the cap keeps a hostile one from
        // turning this into a long walk.
        for _ in 0..<1_024 {
            let remaining = fileSize - position
            guard remaining >= 8 else { return nil }
            try handle.seek(toOffset: position)
            guard let header = try handle.read(upToCount: 16), header.count >= 8 else { return nil }
            let bytes = [UInt8](header)
            var size = readU32(bytes, 0)
            var headerLength: UInt64 = 8
            if size == 1 {
                guard bytes.count == 16 else { return nil }
                size = readU64(bytes, 8)
                headerLength = 16
            } else if size == 0 {
                size = remaining
            }
            if size < headerLength { return nil }
            if Array(bytes[4..<8]) == moovAtom {
                let length = min(size, remaining)
                guard length <= UInt64(maxTagBytes) else { return nil }
                try handle.seek(toOffset: position)
                return try handle.read(upToCount: Int(length)).flatMap { mp4([UInt8]($0)) }
            }
            if size >= remaining { return nil }
            position += size
        }
        return nil
    }

    /// The `lyrics.lrc` written next to an offline package playlist at `path`. Recognised by
    /// the playlist rather than by the directory it sits in: a local `.m3u8` is only ever one
    /// of these packages.
    public static func sidecar(path: String?) -> String? {
        guard let path, path.lowercased().hasSuffix(".m3u8") else { return nil }
        let file = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("lyrics.lrc")
        // Bounded for the same reason `maxTagBytes` is: the size on disk is the only thing
        // that says how big a string this becomes.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue, (1...maxTagBytes).contains(size),
              let data = try? Data(contentsOf: file)
        else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.kIsBlank ? nil : text
    }

    /// The raw LRC text in `head`, whichever of the three containers it is. Split out so the
    /// parsing can be tested against bytes a tagger just produced.
    public static func fromBytes(_ head: Data) -> String? {
        let bytes = [UInt8](head)
        let found: String?
        if bytes.starts(with: flacMagic) {
            found = flac(bytes)
        } else if bytes.starts(with: matroskaMagic) {
            found = matroska(bytes)
        } else if isMP4(bytes) {
            found = mp4(bytes)
        } else {
            found = nil
        }
        guard let found, !found.kIsBlank else { return nil }
        return found
    }

    // MARK: MP4 / M4A

    /// The `©lyr` atom's text, or this app's freeform one where present. The search is scoped
    /// to `moov` rather than the whole file: a four-byte pattern turns up in audio data often
    /// enough that scanning everything would eventually read a frame as a tag.
    private static func mp4(_ bytes: [UInt8]) -> String? {
        guard let moov = topLevelBox(bytes, type: "moov") else { return nil }
        // Exclusive, and deliberately so: the lyrics are the last item written into `ilst`,
        // so their value ends exactly on `moov`'s own end.
        return ilstText(bytes, from: moov.lowerBound, endExclusive: moov.upperBound, freeform: true)
            ?? ilstText(bytes, from: moov.lowerBound, endExclusive: moov.upperBound, freeform: false)
    }

    /// The bounds of a top-level box. `moov` may come after `mdat` in a file written without
    /// the faststart pass, so this steps box to box rather than assuming a position.
    private static func topLevelBox(_ bytes: [UInt8], type: String) -> Range<Int>? {
        var position = 0
        while position + 8 <= bytes.count {
            let declared = readU32(bytes, position)
            var headerLength = 8
            var size = declared
            if declared == 1 {
                if position + 16 > bytes.count { return nil }
                size = readU64(bytes, position + 8)
                headerLength = 16
            } else if declared == 0 {
                size = UInt64(bytes.count - position)
            }
            if size < UInt64(headerLength) || size > UInt64(Int32.max) { return nil }
            let end = min(position + Int(size), bytes.count)
            if String(decoding: bytes[(position + 4)..<(position + 8)], as: UTF8.self) == type { return position..<end }
            position += Int(size)
        }
        return nil
    }

    /// The text of the lyrics item inside the range: this app's `----` item (named by a
    /// `name` box beside the value) or the standard `©lyr`, whose four-byte type *is* the name.
    private static func ilstText(_ bytes: [UInt8], from: Int, endExclusive: Int, freeform: Bool) -> String? {
        let marker = freeform ? Array(LRCFormat.wordLyricsField.utf8) : lyrAtom
        var at = from
        while true {
            guard let found = indexOf(bytes, marker, from: at, until: endExclusive) else { return nil }
            // The value is the first `data` box after the name, in both layouts.
            guard let data = indexOf(bytes, dataAtom, from: found, until: endExclusive) else { return nil }
            if let text = dataText(bytes, dataAt: data, endExclusive: endExclusive) { return text }
            at = found + marker.count
        }
    }

    /// An iTunes `data` box's payload as text: version/flags(4) + locale(4) + the value, with
    /// the box length saying where the value stops.
    private static func dataText(_ bytes: [UInt8], dataAt: Int, endExclusive: Int) -> String? {
        let start = dataAt - 4
        if start < 0 || dataAt + 12 > endExclusive { return nil }
        let size = Int(readU32(bytes, start))
        if size <= 16 || start + size > endExclusive { return nil }
        // Type indicator 1 is UTF-8 text; a cover's 13/14 is the other thing a `data` box
        // holds, and decoding a JPEG as a string is not a lyric.
        if readU32(bytes, dataAt + 4) != 1 { return nil }
        return String(decoding: bytes[(dataAt + 12)..<(start + size)], as: UTF8.self)
    }

    // MARK: FLAC

    /// The `LYRICS` (or word-lyrics) comment out of the `VORBIS_COMMENT` block. Every length
    /// in that block is **little-endian** — it reuses Ogg Vorbis' layout, the one part of
    /// FLAC that isn't big-endian.
    private static func flac(_ bytes: [UInt8]) -> String? {
        var position = flacMagic.count
        while position + 4 <= bytes.count {
            let flags = Int(bytes[position])
            let length = Int(bytes[position + 1]) << 16 | Int(bytes[position + 2]) << 8 | Int(bytes[position + 3])
            let start = position + 4
            if start + length > bytes.count { return nil }
            if flags & 0x7F == flacVorbisComment { return vorbisComment(bytes, start: start, end: start + length) }
            if flags & 0x80 != 0 { return nil }
            position = start + length
        }
        return nil
    }

    private static func vorbisComment(_ bytes: [UInt8], start: Int, end: Int) -> String? {
        var position = start
        func u32() -> Int? {
            if position + 4 > end { return nil }
            let value = Int32(bitPattern: UInt32(bytes[position]) | UInt32(bytes[position + 1]) << 8
                | UInt32(bytes[position + 2]) << 16 | UInt32(bytes[position + 3]) << 24)
            position += 4
            return Int(value)
        }
        guard let vendor = u32(), vendor >= 0 else { return nil }
        position += vendor
        guard let count = u32() else { return nil }
        var plain: String?
        for _ in 0..<max(0, min(count, 4_096)) {
            guard let length = u32(), length >= 0, position + length <= end else { return plain }
            let entry = String(decoding: bytes[position..<(position + length)], as: UTF8.self)
            position += length
            let name = entry.kSubstringBefore("=").uppercased()
            let value = entry.kSubstringAfter("=", missing: "")
            // This app's own field wins outright; the standard one is held in case it turns
            // out to be the only one there.
            if name == LRCFormat.wordLyricsField && !value.kIsBlank { return value }
            if name == "LYRICS" && plain == nil && !value.kIsBlank { plain = value }
        }
        return plain
    }

    // MARK: Matroska / WebM

    /// The `LYRICS` SimpleTag's string. Scanned for rather than walked down to: the tags a
    /// download writes are appended after everything else, so reaching them properly would
    /// mean parsing every cluster of audio. The name is matched inside a `TagName` element
    /// and the value read out of the `TagString` that follows, so this is reading tag
    /// structure rather than guessing at loose bytes.
    private static func matroska(_ bytes: [UInt8]) -> String? {
        var plain: String?
        for name in [LRCFormat.wordLyricsField, "LYRICS"] {
            let needle = Array(name.utf8)
            var from = 0
            while let at = indexOf(bytes, needle, from: from, until: bytes.count) {
                from = at + needle.count
                // The name element's own header sits immediately in front of it: id(2) + a
                // one-byte length for a name this short.
                if at < 3 || bytes[at - 3] != idTagName[0] || bytes[at - 2] != idTagName[1] { continue }
                if Int(bytes[at - 1] & 0x7F) != needle.count { continue }
                guard let string = indexOf(bytes, idTagString, from: from, until: bytes.count),
                      let size = readVint(bytes, string + 2)
                else { continue }
                let valueAt = string + 2 + size.width
                if size.value <= 0 || valueAt + size.value > bytes.count { continue }
                let value = String(decoding: bytes[valueAt..<(valueAt + size.value)], as: UTF8.self)
                if value.kIsBlank { continue }
                if name == LRCFormat.wordLyricsField { return value }
                if plain == nil { plain = value }
            }
        }
        return plain
    }

    /// An EBML variable-length integer: the highest set bit of the first byte gives the
    /// width, and the bits after it are the value.
    private static func readVint(_ bytes: [UInt8], _ offset: Int) -> (value: Int, width: Int)? {
        guard offset < bytes.count else { return nil }
        let first = Int(bytes[offset])
        if first == 0 { return nil }
        var width = 1
        var mask = 0x80
        while first & mask == 0 {
            mask >>= 1
            width += 1
        }
        if offset + width > bytes.count { return nil }
        var value = first & ~mask & 0xFF
        for i in 1..<width { value = (value << 8) | Int(bytes[offset + i]) }
        return (value, width)
    }

    // MARK: Bytes

    private static func isMP4(_ bytes: [UInt8]) -> Bool {
        bytes.count > 12 && bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70
    }

    private static func indexOf(_ bytes: [UInt8], _ needle: [UInt8], from: Int, until: Int) -> Int? {
        if needle.isEmpty { return nil }
        let last = min(until, bytes.count) - needle.count
        var i = max(from, 0)
        while i <= last {
            if bytes[i] == needle[0] {
                var matched = true
                for j in 1..<needle.count where bytes[i + j] != needle[j] {
                    matched = false
                    break
                }
                if matched { return i }
            }
            i += 1
        }
        return nil
    }

    private static func readU32(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        UInt64(bytes[offset]) << 24 | UInt64(bytes[offset + 1]) << 16 | UInt64(bytes[offset + 2]) << 8 | UInt64(bytes[offset + 3])
    }

    private static func readU64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { ($0 << 8) | UInt64(bytes[offset + $1]) }
    }

    private static let flacVorbisComment = 4
    private static let flacMagic = Array("fLaC".utf8)
    private static let matroskaMagic: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3]
    private static let moovAtom = Array("moov".utf8)
    private static let dataAtom = Array("data".utf8)
    private static let lyrAtom: [UInt8] = [0xA9] + Array("lyr".utf8)
    private static let idTagName: [UInt8] = [0x45, 0xA3]
    private static let idTagString: [UInt8] = [0x44, 0x87]
}
