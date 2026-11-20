import Foundation

// Ports download/Mp4Tagger.kt.

/// The name this app files word-timed lyrics under, in every container: an MP4 `----` item named
/// this (owner ``Mp4Tagger/freeformMean``) and a FLAC Vorbis field of the same name. Android's
/// `WORD_LYRICS_FIELD` (data/lyrics/LrcWriter.kt); the Lyrics module reads it back.
public let wordLyricsField = "VIBRAMUSIC_LYRICS"

/// Writes iTunes-style metadata atoms — title, artist, album, lyrics, cover — into an M4A/MP4 file.
///
/// There is no public API that does this in place: `AVAssetExportSession` can write metadata, but
/// only by re-muxing into a new file, which is a full copy through the media pipeline, refuses some
/// codecs (FLAC-in-MP4 from lossless sources), and drops the `iTunSMPB` gapless data. So this reads
/// and rewrites the handful of boxes involved directly, as Android does.
///
/// The rewrite is a single splice: `moov/udta` is replaced (or, when there is none, appended as
/// `moov`'s last child) by one carrying a fresh `meta/ilst`. Growing `moov` shifts every byte after
/// it, which matters only because `stco`/`co64` record *absolute* file offsets into `mdat` — so every
/// entry at or past the splice is bumped by the change in length. A fragmented file (YouTube's
/// adaptive audio, and every flattened HLS/DASH package) addresses its samples relative to each
/// `moof` instead, so the only other absolute offsets to fix are an explicit `tfhd`
/// base-data-offset and the `tfra` random-access table, both rare.
///
/// **iOS difference.** Android appends a *second* `udta` and leaves any existing one alone. That is
/// invisible to AVFoundation, which reads only the first `udta` — and both the files AVAudioFile
/// writes and YouTube's itag-140 audio already carry one (verified on macOS 27: the tags in a second
/// `udta` don't appear in `AVAsset.metadata`). So the existing `udta` is merged instead: its other
/// children are kept, its `ilst` items are kept unless this rewrite sets them (the encoder's
/// `iTunSMPB` gapless info survives), and the whole box is replaced in place.
///
/// Any layout this doesn't recognise — no `moov`, a box that doesn't fit its parent — returns nil,
/// meaning "leave the file alone": a download that plays untagged is a smaller loss than one a bad
/// rewrite has corrupted.
public enum Mp4Tagger {
    /// The reverse-DNS owner of the freeform lyrics item, which is what keeps the name ours.
    public static let freeformMean = "com.fortune.vibramusic.ios"

    /// Box types whose payload is itself a run of child boxes, on the path down to `stco`/`co64`.
    private static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl"]

    /// iTunes item types this rewrite owns; an existing item of one of these types is replaced.
    private static let ownedItems: Set<String> = ["\u{A9}nam", "\u{A9}ART", "\u{A9}alb", "\u{A9}lyr", "covr"]

    /// The tagged file, or nil when there is nothing to write or the layout isn't one this
    /// recognises (in both cases the file is to be left exactly as it is).
    ///
    /// - Parameter wordLyrics: the A2 form, kept beside `lyrics` rather than instead of it — see
    ///   ``wordLyricsField``.
    public static func tag(
        _ data: Data,
        title: String,
        artist: String,
        album: String?,
        lyrics: String?,
        cover: Data?,
        coverIsPng: Bool,
        wordLyrics: String? = nil
    ) -> Data? {
        var items: [[UInt8]] = []
        // © is iTunes's own "copyright" prefix for the text atoms below — not a copyright mark here,
        // just the byte their readers key on.
        if !title.isBlank { items.append(textItem("\u{A9}nam", title)) }
        if !artist.isBlank { items.append(textItem("\u{A9}ART", artist)) }
        if let album, !album.isBlank { items.append(textItem("\u{A9}alb", album)) }
        // `©lyr` is a UTF-8 text atom with no length limit and no objection to newlines, so LRC
        // goes in as-is: `©lyr` holding LRC is what players that show synced lyrics for an M4A read.
        if let lyrics, !lyrics.isBlank { items.append(textItem("\u{A9}lyr", lyrics)) }
        if let wordLyrics, !wordLyrics.isBlank { items.append(freeformItem(name: wordLyricsField, text: wordLyrics)) }
        if let cover, !cover.isEmpty { items.append(coverItem([UInt8](cover), isPng: coverIsPng)) }
        guard !items.isEmpty else { return nil }

        let bytes = [UInt8](data)
        guard let moov = parseBoxes(bytes, 0, bytes.count).first(where: { $0.type == "moov" }) else { return nil }
        guard let output = rewrite(bytes, moov: moov, items: items) else { return nil }
        return Data(output)
    }

    // MARK: Rewrite

    private static func rewrite(_ bytes: [UInt8], moov: BoxRef, items: [[UInt8]]) -> [UInt8]? {
        let children = parseBoxes(bytes, moov.contentOffset, moov.end)
        let existing = children.first { $0.type == "udta" }

        // What the new udta keeps from the old one.
        var keptChildren: [UInt8] = []
        var keptItems: [[UInt8]] = []
        if let existing {
            for child in parseBoxes(bytes, existing.contentOffset, existing.end) {
                if child.type == "meta" {
                    keptItems = existingItems(bytes, meta: child)
                } else {
                    keptChildren += bytes[child.offset..<child.end]
                }
            }
        }
        let udta = box("udta", keptChildren + metaAtom(ilstAtom(keptItems + items)))

        let replaceStart = existing?.offset ?? moov.end
        let replaceEnd = existing?.end ?? moov.end
        let delta = udta.count - (replaceEnd - replaceStart)

        var out = [UInt8]()
        out.reserveCapacity(bytes.count + max(delta, 0))
        out += bytes[0..<replaceStart]
        out += udta
        out += bytes[replaceEnd...]

        /// Where a byte of the original landed in `out`. Nothing addresses into the replaced udta.
        func moved(_ position: Int) -> Int { position < replaceStart ? position : position + delta }

        // rawSize32 == 0 means "this box runs to the end of its parent" — still true after the
        // splice, so the field is left alone rather than given a concrete value.
        if moov.rawSize32 != 0 {
            let newSize = Int64(moov.size) + Int64(delta)
            if moov.headerLen == 16 {
                writeU64(&out, moov.offset + 8, UInt64(newSize))
            } else {
                guard newSize <= Int64(UInt32.max) else { return nil }
                writeU32(&out, moov.offset, UInt32(newSize))
            }
        }

        // Absolute offsets at or past the end of the replaced region move with it.
        let threshold = UInt64(replaceEnd)
        func shifted(_ value: UInt64) -> UInt64 {
            value >= threshold ? UInt64(Int64(value) + Int64(delta)) : value
        }

        var offsetBoxes: [BoxRef] = []
        collectOffsetBoxes(bytes, moov, &offsetBoxes)
        for table in offsetBoxes {
            let base = table.contentOffset + 4
            guard base + 4 <= table.end else { continue }
            let count = Int(readU32(bytes, base))
            var p = base + 4
            let width = table.type == "co64" ? 8 : 4
            guard count >= 0, p + count * width <= table.end else { return nil }
            for _ in 0..<count {
                if width == 4 {
                    let value = shifted(UInt64(readU32(bytes, p)))
                    guard value <= UInt64(UInt32.max) else { return nil }
                    writeU32(&out, moved(p), UInt32(value))
                } else {
                    writeU64(&out, moved(p), shifted(readU64(bytes, p)))
                }
                p += width
            }
        }

        // Fragmented files: the few absolute offsets outside moov.
        for top in parseBoxes(bytes, 0, bytes.count) where top.offset >= moov.end {
            switch top.type {
            case "moof":
                for traf in parseBoxes(bytes, top.contentOffset, top.end) where traf.type == "traf" {
                    for tfhd in parseBoxes(bytes, traf.contentOffset, traf.end) where tfhd.type == "tfhd" {
                        let flags = readU32(bytes, tfhd.contentOffset) & 0x00FF_FFFF
                        // base-data-offset-present: a 64-bit absolute offset after track_ID.
                        let field = tfhd.contentOffset + 8
                        if flags & 0x1 != 0, field + 8 <= tfhd.end {
                            writeU64(&out, moved(field), shifted(readU64(bytes, field)))
                        }
                    }
                }
            case "mfra":
                for tfra in parseBoxes(bytes, top.contentOffset, top.end) where tfra.type == "tfra" {
                    guard patchTfra(bytes, tfra, into: &out, moved: moved, shifted: shifted) else { return nil }
                }
            default:
                break
            }
        }
        return out
    }

    /// `tfra`: FullBox, track_ID, three 2-bit length fields, an entry count, then per entry a time
    /// and a `moof` offset (64-bit each in version 1) and three variable-width numbers.
    private static func patchTfra(
        _ bytes: [UInt8],
        _ box: BoxRef,
        into out: inout [UInt8],
        moved: (Int) -> Int,
        shifted: (UInt64) -> UInt64
    ) -> Bool {
        let start = box.contentOffset
        guard start + 16 <= box.end else { return false }
        let version = bytes[start]
        let lengths = readU32(bytes, start + 8)
        let trafBytes = Int((lengths >> 4) & 0x3) + 1
        let trunBytes = Int((lengths >> 2) & 0x3) + 1
        let sampleBytes = Int(lengths & 0x3) + 1
        let count = Int(readU32(bytes, start + 12))
        let wide = version == 1
        let entry = (wide ? 16 : 8) + trafBytes + trunBytes + sampleBytes
        var p = start + 16
        guard count >= 0, p + count * entry <= box.end else { return false }
        for _ in 0..<count {
            let offsetAt = p + (wide ? 8 : 4)
            if wide {
                writeU64(&out, moved(offsetAt), shifted(readU64(bytes, offsetAt)))
            } else {
                let value = shifted(UInt64(readU32(bytes, offsetAt)))
                guard value <= UInt64(UInt32.max) else { return false }
                writeU32(&out, moved(offsetAt), UInt32(value))
            }
            p += entry
        }
        return true
    }

    /// The items of an existing `meta/ilst` that this rewrite doesn't own.
    private static func existingItems(_ bytes: [UInt8], meta: BoxRef) -> [[UInt8]] {
        // meta is a FullBox: four bytes of version/flags before its children.
        let children = parseBoxes(bytes, meta.contentOffset + 4, meta.end)
        guard let ilst = children.first(where: { $0.type == "ilst" }) else { return [] }
        return parseBoxes(bytes, ilst.contentOffset, ilst.end).compactMap { item in
            if ownedItems.contains(item.type) { return nil }
            if item.type == "----", let name = freeformName(bytes, item), name == (freeformMean, wordLyricsField) { return nil }
            return Array(bytes[item.offset..<item.end])
        }
    }

    private static func freeformName(_ bytes: [UInt8], _ item: BoxRef) -> (String, String)? {
        var mean: String?
        var name: String?
        for child in parseBoxes(bytes, item.contentOffset, item.end) where child.contentOffset + 4 <= child.end {
            let text = String(decoding: bytes[(child.contentOffset + 4)..<child.end], as: UTF8.self)
            if child.type == "mean" { mean = text }
            if child.type == "name" { name = text }
        }
        guard let mean, let name else { return nil }
        return (mean, name)
    }

    private static func collectOffsetBoxes(_ bytes: [UInt8], _ box: BoxRef, _ out: inout [BoxRef]) {
        if box.type == "stco" || box.type == "co64" {
            out.append(box)
            return
        }
        if containers.contains(box.type) {
            for child in parseBoxes(bytes, box.contentOffset, box.end) {
                collectOffsetBoxes(bytes, child, &out)
            }
        }
    }

    // MARK: Box walking

    struct BoxRef {
        let offset: Int
        let headerLen: Int
        let size: Int
        /// The raw 32-bit size field, before size==0/1 are resolved — 0 means "to end of parent",
        /// which must be left alone rather than replaced with a real number.
        let rawSize32: UInt32
        let type: String

        var contentOffset: Int { offset + headerLen }
        var end: Int { offset + size }
    }

    static func parseBoxes(_ bytes: [UInt8], _ start: Int, _ end: Int) -> [BoxRef] {
        var out: [BoxRef] = []
        var pos = start
        while pos + 8 <= end {
            let size32 = readU32(bytes, pos)
            let type = fourCC(bytes, pos + 4)
            var headerLen = 8
            var size = UInt64(size32)
            if size32 == 1 {
                if pos + 16 > end { break }
                size = readU64(bytes, pos + 8)
                headerLen = 16
            } else if size32 == 0 {
                size = UInt64(end - pos)
            }
            if size < UInt64(headerLen) || size > UInt64(end - pos) { break }
            out.append(BoxRef(offset: pos, headerLen: headerLen, size: Int(size), rawSize32: size32, type: type))
            pos += Int(size)
        }
        return out
    }

    // MARK: Building

    static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 8)
        writeU32(&out, 0, UInt32(8 + payload.count))
        // ISO-8859-1, not ASCII: the iTunes item names carry the 0xA9 "copyright" byte, which plain
        // ASCII can't encode — corrupting the very atom type a player looks up by.
        let typeBytes = Array(type.data(using: .isoLatin1) ?? Data(type.utf8))
        out.replaceSubrange(4..<8, with: typeBytes.prefix(4))
        return out + payload
    }

    /// iTunes's `data` atom: version(0) + a type indicator packed into 3 flag bytes, a locale, then
    /// the value.
    private static func dataAtom(_ typeIndicator: UInt32, _ payload: [UInt8]) -> [UInt8] {
        var body = [UInt8](repeating: 0, count: 8)
        writeU32(&body, 0, typeIndicator)
        return box("data", body + payload)
    }

    /// Type indicator 1 = UTF-8 text.
    private static func textItem(_ fourCC: String, _ text: String) -> [UInt8] {
        box(fourCC, dataAtom(1, Array(text.utf8)))
    }

    /// Type indicator 13 = JPEG, 14 = PNG.
    private static func coverItem(_ image: [UInt8], isPng: Bool) -> [UInt8] {
        box("covr", dataAtom(isPng ? 14 : 13, image))
    }

    /// A `----` item: iTunes' escape hatch for a field it has no four-byte code for, named by a
    /// `mean`/`name` pair in front of the value.
    ///
    /// This is where the word timings go: `©lyr` is read by every other player, and a reader without
    /// the A2 extension shows `<00:01.00>` rather than skipping it. A player that doesn't know this
    /// item ignores it whole, so the standard field stays clean and the timings still survive in the
    /// file. AVFoundation exposes it as `itlk/com.fortune.vibramusic.ios.VIBRAMUSIC_LYRICS`.
    private static func freeformItem(name: String, text: String) -> [UInt8] {
        // Both are FullBoxes: four bytes of version/flags, then the string.
        let mean = box("mean", [0, 0, 0, 0] + Array(freeformMean.utf8))
        let label = box("name", [0, 0, 0, 0] + Array(name.utf8))
        return box("----", mean + label + dataAtom(1, Array(text.utf8)))
    }

    /// A minimal handler box declaring this `meta` as iTunes-style metadata.
    private static func hdlrAtom() -> [UInt8] {
        // version/flags(4) + pre_defined(4) + handler_type(4) + reserved(12) + name(1, empty cstring)
        var body = [UInt8](repeating: 0, count: 25)
        body.replaceSubrange(8..<12, with: Array("mdir".utf8))
        return box("hdlr", body)
    }

    private static func ilstAtom(_ items: [[UInt8]]) -> [UInt8] {
        box("ilst", items.flatMap { $0 })
    }

    private static func metaAtom(_ ilst: [UInt8]) -> [UInt8] {
        box("meta", [0, 0, 0, 0] + hdlrAtom() + ilst)
    }
}

// MARK: - Byte helpers (module-internal)

func readU32(_ b: [UInt8], _ off: Int) -> UInt32 {
    UInt32(b[off]) << 24 | UInt32(b[off + 1]) << 16 | UInt32(b[off + 2]) << 8 | UInt32(b[off + 3])
}

func readU64(_ b: [UInt8], _ off: Int) -> UInt64 {
    var value: UInt64 = 0
    for i in 0..<8 { value = value << 8 | UInt64(b[off + i]) }
    return value
}

func writeU32(_ b: inout [UInt8], _ off: Int, _ value: UInt32) {
    b[off] = UInt8(truncatingIfNeeded: value >> 24)
    b[off + 1] = UInt8(truncatingIfNeeded: value >> 16)
    b[off + 2] = UInt8(truncatingIfNeeded: value >> 8)
    b[off + 3] = UInt8(truncatingIfNeeded: value)
}

func writeU64(_ b: inout [UInt8], _ off: Int, _ value: UInt64) {
    for i in 0..<8 { b[off + i] = UInt8(truncatingIfNeeded: value >> (8 * UInt64(7 - i))) }
}

func fourCC(_ b: [UInt8], _ off: Int) -> String {
    String(decoding: [UInt16](b[off..<(off + 4)].map { UInt16($0) }), as: UTF16.self)
}

extension String {
    /// Kotlin's `isBlank`: empty or only whitespace.
    var isBlank: Bool { allSatisfy(\.isWhitespace) }
}
