import Foundation

// Ports data/remote/EmbeddedArt.kt: cover pictures embedded in audio files,
// read through bounded ranged access instead of downloading whole tracks.
//
// Only the tag regions are ever touched: an ID3v2 tag, a FLAC metadata chain,
// an MP4 box walk or the first Ogg pages. Anything unparseable — exotic
// flags, encryption, a picture bigger than maxPictureBytes — reads as absent
// rather than as an error, because a missing cover must never fail whatever
// asked for one. WAV is deliberately unsupported: its metadata lives in RIFF
// chunks a good number of players ignore outright.

/// Cover pictures embedded in audio files.
public enum EmbeddedArt {
    /// An extracted picture and the MIME type it declared (or sniffed).
    public struct Picture: Hashable, Sendable {
        public var bytes: Data
        public var mime: String

        public init(bytes: Data, mime: String) {
            self.bytes = bytes
            self.mime = mime
        }
    }

    /// Random access into the file. Backends serve HTTP ranges or share
    /// offsets; both are just (offset, length) reads here.
    public protocol Reader: Sendable {
        var size: Int64 { get }
        func read(offset: Int64, length: Int) -> Data
        func close()
    }

    /// Largest single picture kept — phone screens don't need more.
    public static let maxPictureBytes = 8 * 1024 * 1024

    /// Largest tag region walked before giving up on a file.
    private static let maxWalkBytes = 16 * 1024 * 1024

    /// The embedded picture in the file behind `reader`, or nil when there is
    /// none (or the file is not a tagged format this reader knows).
    public static func extract(_ reader: Reader) -> Picture? {
        let magic = [UInt8](reader.read(offset: 0, length: 12))
        guard magic.count >= 12 else { return nil }
        if magic[0] == ascii("I"), magic[1] == ascii("D"), magic[2] == ascii("3") {
            return id3(reader, magic: magic)
        }
        if magic[0] == ascii("f"), magic[1] == ascii("L"), magic[2] == ascii("a"), magic[3] == ascii("C") {
            return flac(reader)
        }
        if magic[4] == ascii("f"), magic[5] == ascii("t"), magic[6] == ascii("y"), magic[7] == ascii("p") {
            return mp4(reader)
        }
        if magic[0] == ascii("O"), magic[1] == ascii("g"), magic[2] == ascii("g"), magic[3] == ascii("S") {
            return ogg(reader)
        }
        return nil
    }

    private static func ascii(_ character: Character) -> UInt8 {
        character.asciiValue ?? 0
    }

    // MARK: - Buffered cursor

    private final class Cursor {
        private let reader: Reader
        private var windowStart: Int64 = 0
        private var window: [UInt8] = []
        private(set) var position: Int64 = 0

        init(_ reader: Reader) { self.reader = reader }

        func seek(_ at: Int64) { position = at }

        func bytes(_ length: Int) -> [UInt8] {
            precondition(length >= 0)
            if position < windowStart || position + Int64(length) > windowStart + Int64(window.count) {
                let remaining = max(reader.size - position, 0)
                let fetch = min(max(Int64(length), 64 * 1024), remaining)
                windowStart = position
                window = fetch > 0 ? [UInt8](reader.read(offset: position, length: Int(fetch))) : []
            }
            let from = Int(position - windowStart)
            let to = min(from + length, window.count)
            guard from >= 0, to >= from else {
                position = windowStart + Int64(window.count)
                return []
            }
            position += Int64(to - from)
            return Array(window[from..<to])
        }

        func skip(_ length: Int64) { position += length }
    }

    // MARK: - ID3v2 (MP3)

    private static func id3(_ reader: Reader, magic: [UInt8]) -> Picture? {
        let version = Int(magic[3])
        guard (2...4).contains(version) else { return nil }
        let unsync = magic[5] & 0x80 != 0
        let tagSize = syncsafe(magic, at: 6)
        guard tagSize > 0, tagSize <= maxWalkBytes else { return nil }
        let tag = [UInt8](reader.read(offset: 10, length: tagSize))
        guard tag.count >= tagSize else { return nil }
        var pos = 0
        // Extended header: the declared size counts itself on v2.4 and not on
        // v2.3, and both conventions ship in the wild. Try the spec's offset
        // first, then the other convention and the two fixed sizes. Zeros there
        // are the header's own padding fields, never a frame to start from.
        if magic[5] & 0x40 != 0, tag.count >= 4 {
            let declared = version == 4 ? syncsafe(tag, at: 0) : u32(tag, at: 0)
            let spec = version == 4 ? declared : declared + 4
            guard let start = [spec, version == 4 ? declared + 4 : declared, declared - 4, 6, 10].first(where: { offset in
                offset >= 0 && offset <= tag.count
                    && !tag[offset..<min(offset + 4, tag.count)].allSatisfy { $0 == 0 }
                    && framesStart(tag, at: offset, version: version)
            }) else { return nil }
            pos = start
        }
        while pos + 10 <= tag.count {
            let idLen = version == 2 ? 3 : 4
            guard pos + idLen + 3 <= tag.count else { break }
            let id = decode(tag, pos..<(pos + idLen))
            if id.allSatisfy({ $0 == "\0" }) { break }
            let isPicture = (version == 2 && id == "PIC") || (version != 2 && id == "APIC")
            let size: Int
            if version == 2 {
                size = u24(tag, at: pos + 3)
            } else if version == 4 {
                size = syncsafe(tag, at: pos + 4)
            } else {
                size = u32(tag, at: pos + 4)
            }
            let headLen = version == 2 ? 6 : 10
            if size <= 0 || pos + headLen + size > tag.count + 1 || !id.allSatisfy({ $0.isLetter || $0.isNumber }) {
                // Padding, or a frame this walk can't trust — either way the
                // tag has nothing more to say from here.
                if !isPicture { break }
            }
            if isPicture, size > 0, pos + headLen + size <= tag.count {
                let raw = Array(tag[(pos + headLen)..<(pos + headLen + size)])
                // Sizes count stored bytes, so frame boundaries stay exact and
                // only the payload is de-unsynchronised — the other order
                // drifts every frame after the first stuffed byte.
                let payload = unsync ? deunsync(raw) : raw
                if let picture = pictureFromApic(payload, version: version) { return picture }
                return nil
            }
            pos += headLen + size
        }
        return nil
    }

    private static func framesStart(_ tag: [UInt8], at: Int, version: Int) -> Bool {
        guard at + 4 <= tag.count else { return false }
        if tag[at..<min(at + 4, tag.count)].allSatisfy({ $0 == 0 }) { return true }
        let idLen = version == 2 ? 3 : 4
        guard at + idLen <= tag.count else { return false }
        return decode(tag, at..<(at + idLen)).allSatisfy { $0.isLetter || $0.isNumber }
    }

    private static func deunsync(_ tag: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(tag.count)
        var index = 0
        while index < tag.count {
            out.append(tag[index])
            if tag[index] == 0xFF, index + 1 < tag.count, tag[index + 1] == 0x00 { index += 1 }
            index += 1
        }
        return out
    }

    private static func pictureFromApic(_ payload: [UInt8], version: Int) -> Picture? {
        guard !payload.isEmpty else { return nil }
        if version == 2 {
            // encoding(1) + format(3) + type(1) + description + data
            guard payload.count >= 6 else { return nil }
            let format = decode(payload, 1..<4).uppercased()
            let mime = format == "PNG" ? "image/png" : "image/jpeg"
            var at = 5
            guard let next = skipNull(payload, at: at, width: 1) else { return nil }
            at = next
            return picture(Data(payload[at...]), mime: mime)
        }
        var at = 1
        var mimeEnd = -1
        for index in at..<payload.count where payload[index] == 0 {
            mimeEnd = index
            break
        }
        guard mimeEnd >= 0 else { return nil }
        let mime = decode(payload, at..<mimeEnd)
        at = mimeEnd + 1
        guard at < payload.count else { return nil }
        at += 1 // picture type
        let encoding = Int(payload[0])
        guard let next = skipNull(payload, at: at, width: (encoding == 1 || encoding == 2) ? 2 : 1) else { return nil }
        at = next
        return picture(Data(payload[at...]), mime: mime.isEmpty ? nil : mime)
    }

    private static func skipNull(_ payload: [UInt8], at: Int, width: Int) -> Int? {
        var index = at
        while index + width <= payload.count {
            var zero = true
            for k in 0..<width where payload[index + k] != 0 { zero = false; break }
            if zero { return index + width }
            index += (width == 2 && payload[index] != 0) ? 2 : 1
        }
        return nil
    }

    // MARK: - FLAC

    private static func flac(_ reader: Reader) -> Picture? {
        let cursor = Cursor(reader)
        cursor.seek(4)
        var walked: Int64 = 0
        while true {
            let head = cursor.bytes(4)
            guard head.count >= 4 else { return nil }
            let last = head[0] & 0x80 != 0
            let type = head[0] & 0x7F
            let length = Int64(u24(head, at: 1))
            guard length >= 0, length <= Int64(maxPictureBytes) + 1024 else { return nil }
            walked += 4
            guard walked <= Int64(maxWalkBytes) else { return nil }
            if type == 6 {
                return flacPicture(reader, at: cursor.position, length: Int(length))
            }
            cursor.skip(length)
            if last { return nil }
        }
    }

    /// A PICTURE block body: metadata, then the image at a known extent.
    static func flacPicture(_ reader: Reader, at: Int64, length: Int) -> Picture? {
        let head = [UInt8](reader.read(offset: at, length: min(length, 64)))
        guard head.count >= 8 else { return nil }
        var pos = 0
        func u32at() -> Int {
            guard pos + 4 <= head.count else { return -1 }
            defer { pos += 4 }
            return u32(head, at: pos)
        }
        _ = u32at() // picture type
        let mimeLen = u32at()
        guard mimeLen >= 0, pos + mimeLen <= head.count else { return nil }
        let mime = decode(head, pos..<(pos + mimeLen))
        pos += mimeLen
        let descLen = u32at()
        guard descLen >= 0, pos + descLen + 20 <= head.count else { return nil }
        pos += descLen + 16 // description, width, height, depth, colors
        let dataLen = u32at()
        guard dataLen > 0, dataLen <= maxPictureBytes else { return nil }
        let data = reader.read(offset: at + Int64(pos), length: dataLen)
        guard data.count == dataLen else { return nil }
        return picture(data, mime: mime.isEmpty ? nil : mime)
    }

    // MARK: - MP4/M4A

    private static func mp4(_ reader: Reader) -> Picture? {
        let cursor = Cursor(reader)
        guard let moov = findBox(cursor, from: 0, until: reader.size, want: ["moov"], depth: 0),
              let udta = findBox(cursor, from: moov.start, until: moov.end, want: ["udta"], depth: 1),
              let meta = findBox(cursor, from: udta.start, until: udta.end, want: ["meta"], depth: 2),
              // meta is a full box: 4 version/flags bytes before its children.
              let ilst = findBox(cursor, from: meta.start + 4, until: meta.end, want: ["ilst"], depth: 3)
        else { return nil }
        return covrData(cursor, from: ilst.start, until: ilst.end)
    }

    private struct Box {
        var start: Int64
        var end: Int64
    }

    private static func boxHeader(_ cursor: Cursor, at: Int64) -> (type: String, start: Int64, end: Int64)? {
        cursor.seek(at)
        let head = cursor.bytes(8)
        guard head.count >= 8 else { return nil }
        var size = Int64(u32(head, at: 0))
        let type = decode(head, 4..<8)
        var headerLen: Int64 = 8
        if size == 1 {
            let ext = cursor.bytes(8)
            guard ext.count >= 8 else { return nil }
            size = u64(ext, at: 0)
            headerLen = 16
            guard size >= headerLen else { return nil }
        } else if size == 0 {
            // To the end of the file — bounded like any other walk.
            size = Int64(maxWalkBytes)
        }
        guard size >= headerLen, size <= Int64(maxWalkBytes) * 4 else { return nil }
        return (type, at + headerLen, at + size)
    }

    private static func findBox(_ cursor: Cursor, from: Int64, until: Int64, want: Set<String>, depth: Int) -> Box? {
        guard depth <= 8, from < until else { return nil }
        var at = from
        var walked: Int64 = 0
        while at + 8 <= until, walked < Int64(maxWalkBytes) {
            guard let (type, payloadStart, payloadEnd) = boxHeader(cursor, at: at) else { return nil }
            if want.contains(type) { return Box(start: payloadStart, end: payloadEnd) }
            walked += payloadEnd - at
            at = payloadEnd
        }
        return nil
    }

    private static func covrData(_ cursor: Cursor, from: Int64, until: Int64) -> Picture? {
        guard let covr = findBox(cursor, from: from, until: until, want: ["covr"], depth: 4),
              let data = findBox(cursor, from: covr.start, until: covr.end, want: ["data"], depth: 5)
        else { return nil }
        cursor.seek(data.start)
        let head = cursor.bytes(8)
        guard head.count >= 8 else { return nil }
        let kind = u32(head, at: 0)
        let mime: String?
        switch kind {
        case 13: mime = "image/jpeg"
        case 14: mime = "image/png"
        case 27: mime = "image/bmp"
        default: mime = nil
        }
        let length = Int(data.end - data.start - 8)
        guard length > 0, length <= maxPictureBytes else { return nil }
        let bytes = cursor.bytes(length)
        guard bytes.count == length else { return nil }
        return picture(Data(bytes), mime: mime)
    }

    // MARK: - Ogg Vorbis / Opus

    private static func ogg(_ reader: Reader) -> Picture? {
        let cursor = Cursor(reader)
        var pages = 0
        var packet: [UInt8] = []
        var at: Int64 = 0
        while pages < 64 {
            pages += 1
            cursor.seek(at)
            let head = cursor.bytes(27)
            guard head.count >= 27,
                  head[0] == ascii("O"), head[1] == ascii("g"),
                  head[2] == ascii("g"), head[3] == ascii("S")
            else { return nil }
            let continued = head[5] & 0x01 != 0
            let segCount = Int(head[26])
            let table = cursor.bytes(segCount)
            guard table.count >= segCount else { return nil }
            let bodyLen = table.reduce(0) { $0 + Int($1) }
            let body = cursor.bytes(bodyLen)
            guard body.count >= bodyLen else { return nil }
            packet = continued ? packet + body : body
            at = cursor.position
            if let last = table.last, last < 255 {
                // Packet ends here: comment packets name themselves up front.
                if packet.count > 7, packet[0] == 0x03,
                   packet[1] == ascii("v"), packet[2] == ascii("o")
                {
                    guard let picture = vorbisPicture(packet, opus: false) else { return nil }
                    return picture
                }
                if packet.count > 8, decode(packet, 0..<8) == "OpusTags" {
                    guard let picture = vorbisPicture(packet, opus: true) else { return nil }
                    return picture
                }
                packet = []
                if pages > 4 { return nil }
            }
            guard cursor.position <= Int64(maxWalkBytes) else { return nil }
        }
        return nil
    }

    private static func vorbisPicture(_ packet: [UInt8], opus: Bool) -> Picture? {
        // [type/vorbis-magic][vendor len + vendor][count][len + field]...
        var pos = opus ? 8 : 7
        func u32le() -> Int64 {
            guard pos + 4 <= packet.count else { return -1 }
            let value = Int64(packet[pos]) | (Int64(packet[pos + 1]) << 8)
                | (Int64(packet[pos + 2]) << 16) | (Int64(packet[pos + 3]) << 24)
            pos += 4
            return value
        }
        let vendorLen = u32le()
        guard vendorLen >= 0, Int64(pos) + vendorLen <= Int64(packet.count) else { return nil }
        pos += Int(vendorLen)
        let count = u32le()
        guard count >= 0, count <= 10_000 else { return nil }
        for _ in 0..<Int(count) {
            let len = u32le()
            guard len >= 0, Int64(pos) + len <= Int64(packet.count) else { return nil }
            let field = decode(packet, pos..<(pos + Int(len)))
            pos += Int(len)
            let prefix = "METADATA_BLOCK_PICTURE="
            guard field.uppercased().hasPrefix(prefix) else { continue }
            guard let payload = Data(base64Encoded: String(field.dropFirst(prefix.count)),
                                     options: .ignoreUnknownCharacters)
            else { continue }
            // A FLAC PICTURE struct without the 4-byte block header.
            return flacPictureBytes([UInt8](payload))
        }
        return nil
    }

    private static func flacPictureBytes(_ payload: [UInt8]) -> Picture? {
        guard payload.count >= 32 else { return nil }
        var pos = 0
        func u32be() -> Int {
            guard pos + 4 <= payload.count else { return -1 }
            defer { pos += 4 }
            return u32(payload, at: pos)
        }
        _ = u32be()
        let mimeLen = u32be()
        guard mimeLen >= 0, pos + mimeLen <= payload.count else { return nil }
        let mime = decode(payload, pos..<(pos + mimeLen))
        pos += mimeLen
        let descLen = u32be()
        guard descLen >= 0, pos + descLen + 20 <= payload.count else { return nil }
        pos += descLen + 16
        let dataLen = u32be()
        guard dataLen > 0, dataLen <= maxPictureBytes, pos + dataLen <= payload.count else { return nil }
        return picture(Data(payload[pos..<(pos + dataLen)]), mime: mime.isEmpty ? nil : mime)
    }

    // MARK: - Small byte readers

    private static func syncsafe(_ bytes: [UInt8], at: Int) -> Int {
        guard at + 4 <= bytes.count else { return -1 }
        return (Int(bytes[at]) & 0x7F) << 21 | (Int(bytes[at + 1]) & 0x7F) << 14
            | (Int(bytes[at + 2]) & 0x7F) << 7 | (Int(bytes[at + 3]) & 0x7F)
    }

    /// Unsigned 32-bit big-endian, saturated: every caller needs an array
    /// index or a length out of it, and a value past 2GB fails every range
    /// check below rather than overflowing into one that passes.
    private static func u32(_ bytes: [UInt8], at: Int) -> Int {
        guard at + 4 <= bytes.count else { return -1 }
        let value = (UInt32(bytes[at]) << 24) | (UInt32(bytes[at + 1]) << 16)
            | (UInt32(bytes[at + 2]) << 8) | UInt32(bytes[at + 3])
        return Int(value)
    }

    private static func u24(_ bytes: [UInt8], at: Int) -> Int {
        guard at + 3 <= bytes.count else { return -1 }
        return (Int(bytes[at]) << 16) | (Int(bytes[at + 1]) << 8) | Int(bytes[at + 2])
    }

    private static func u64(_ bytes: [UInt8], at: Int) -> Int64 {
        guard at + 8 <= bytes.count else { return -1 }
        var value: Int64 = 0
        for k in 0..<8 { value = (value << 8) | Int64(bytes[at + k]) }
        return value
    }

    private static func decode(_ bytes: [UInt8], _ range: Range<Int>) -> String {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count, range.lowerBound <= range.upperBound else { return "" }
        return String(bytes: bytes[range.lowerBound..<range.upperBound], encoding: .utf8) ?? ""
    }

    private static func picture(_ bytes: Data, mime: String?) -> Picture? {
        guard !bytes.isEmpty, bytes.count <= maxPictureBytes else { return nil }
        return Picture(bytes: bytes, mime: (mime?.isEmpty == false ? mime! : sniffMime(bytes)) ?? "image/jpeg")
    }

    private static func sniffMime(_ bytes: Data) -> String? {
        guard bytes.count >= 4 else { return nil }
        switch (bytes[bytes.startIndex], bytes[bytes.startIndex + 1]) {
        case (0xFF, 0xD8): return "image/jpeg"
        case (0x89, 0x50): return "image/png"
        case (0x47, 0x49): return "image/gif" // "GI"
        case (0x42, 0x4D): return "image/bmp" // "BM"
        default: break
        }
        if bytes.count >= 12, bytes[bytes.startIndex + 8] == 0x57, bytes[bytes.startIndex + 9] == 0x45 {
            return "image/webp" // "WE" in "WEBP"
        }
        return nil
    }
}
