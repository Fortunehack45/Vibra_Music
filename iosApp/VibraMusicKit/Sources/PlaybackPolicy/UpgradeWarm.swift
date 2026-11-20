import Foundation

// Better than PlaybackService.kt's fixed opening (`UPGRADE_HEADER_BYTES`, warmed from byte zero
// ahead of `auditionUpgrade`): see ``UpgradeWarm``.

/// What a quality upgrade's copy needs on disk for the swap to start from the cache: the header
/// its container declares, and a window at the byte the swap position maps to.
///
/// Android warms a fixed megabyte from byte zero, whatever the format. That's about 52 seconds of
/// Opus at 160 kbps, nearly all of it audio the swap never plays. And it never covers the swap
/// point, where the first audio read after the cut lands: the copy replaces one that is already
/// playing, so it's read from the playhead onward, not from its start. So this warms:
///
/// - **The header**, as long as the container says it is: an MP4's boxes up to its `mdat`, a
///   FLAC's metadata blocks, a WAV's or CAF's chunks up to the audio. It's capped at Android's
///   megabyte, which is also what a container this can't read gets.
/// - **A window at the swap point**, ``windowBefore`` to ``windowAfter`` seconds around the
///   playhead. It's mapped to bytes through the points the container pins (an MP4's chunk offsets,
///   a FLAC's seek table) and interpolated between them. A FLAC's window runs from its first frame:
///   a precisely timed player walks the frames up to the swap point (see
///   ``Layout/isWalkedFromTheStart``).
public enum UpgradeWarm {
    /// The most header warmed (Android's `UPGRADE_HEADER_BYTES`), and the opening a container this
    /// can't read gets instead.
    public static let headerCapBytes: Int64 = 1_024 * 1_024
    /// Seconds before the playhead the window starts: room for a mapping that lands a little late.
    public static let windowBefore: TimeInterval = 1
    /// Seconds after the playhead the window runs to (Android `UPGRADE_PREBUFFER_MS`): the swap
    /// waits until this much is on disk, so it is read from disk while the network catches up. Four
    /// seconds capped at a megabyte held under two of hi-res FLAC, and the crossover then cut over
    /// mid-song onto a copy that wasn't there.
    public static let windowAfter: TimeInterval = 12
    /// The most a window warms, whatever the bitrate: Android's audition buffer, well past twelve
    /// seconds of 24-bit/192 kHz FLAC, so it only binds on a mapping gone wrong.
    public static let windowCapBytes: Int64 = 24 * 1_024 * 1_024

    /// A time whose byte offset the container states.
    public struct Anchor: Hashable, Sendable {
        public var seconds: Double
        public var offset: Int64

        public init(seconds: Double, offset: Int64) {
            self.seconds = seconds
            self.offset = offset
        }
    }

    /// Where a file's audio is, read off its opening.
    public struct Layout: Hashable, Sendable {
        /// Where the header ends: everything before it is read before any audio is.
        public var headerEnd: Int64
        /// The bytes holding the audio.
        public var audio: Range<Int64>
        /// Times pinned to bytes. Between them, and with none, offsets are interpolated over `audio`.
        public var anchors: [Anchor]
        /// The player reads every frame before the one a seek lands on, so a swap needs all of them
        /// on disk, however far in it lands, or it would stall on the network after the cut.
        public var isWalkedFromTheStart: Bool

        public init(headerEnd: Int64, audio: Range<Int64>, anchors: [Anchor] = [], isWalkedFromTheStart: Bool = false) {
            self.headerEnd = headerEnd
            self.audio = audio
            self.anchors = anchors
            self.isWalkedFromTheStart = isWalkedFromTheStart
        }

        /// The header as warmed: never past ``UpgradeWarm/headerCapBytes``.
        public var headerRange: Range<Int64> { 0..<min(headerEnd, UpgradeWarm.headerCapBytes) }
    }

    /// What the bytes in hand say.
    public enum Scan: Hashable, Sendable {
        case found(Layout)
        /// The header runs past the bytes in hand: read through `through` and look again.
        case needMore(through: Int64)
        /// Not a container this reads.
        case unknown
    }

    /// Reads the layout off `prefix`, the first bytes of a file `length` bytes long.
    public static func scan(_ prefix: Data, length: Int64) -> Scan {
        let bytes = Bytes(raw: [UInt8](prefix), length: length)
        if bytes.ascii(4, "ftyp") { return mp4(bytes) }
        if bytes.ascii(0, "fLaC") { return flac(bytes) }
        if bytes.ascii(0, "RIFF"), bytes.ascii(8, "WAVE") { return wav(bytes) }
        if bytes.ascii(0, "caff") { return caf(bytes) }
        return .unknown
    }

    /// The bytes to warm for a swap `position` seconds into a track `duration` seconds long, or nil
    /// when there's nothing to map.
    public static func window(_ layout: Layout, position: TimeInterval, duration: TimeInterval) -> Range<Int64>? {
        guard duration > 0, position >= 0, position < duration, !layout.audio.isEmpty else { return nil }
        let mappedEnd = offset(layout, at: min(duration, position + windowAfter), duration: duration)
        if layout.isWalkedFromTheStart {
            // Uncapped: a swap too deep to fetch in time is dropped by the warm's deadline.
            return layout.audio.lowerBound < mappedEnd ? layout.audio.lowerBound..<mappedEnd : nil
        }
        let start = offset(layout, at: max(0, position - windowBefore), duration: duration)
        let end = min(mappedEnd, start + windowCapBytes)
        return start < end ? start..<end : nil
    }

    /// Whether `ranges` (what the cache holds, in any order, touching or not) hold every byte of
    /// `window`.
    public static func covers(_ ranges: [Range<Int64>], _ window: Range<Int64>) -> Bool {
        var through = window.lowerBound
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where range.lowerBound <= through {
            through = max(through, range.upperBound)
        }
        return through >= window.upperBound
    }

    /// The byte `seconds` into the track maps to, interpolated between the nearest pinned points on
    /// either side. The two ends of the audio always count as pinned.
    static func offset(_ layout: Layout, at seconds: TimeInterval, duration: TimeInterval) -> Int64 {
        var before = Anchor(seconds: 0, offset: layout.audio.lowerBound)
        var after = Anchor(seconds: duration, offset: layout.audio.upperBound)
        for anchor in layout.anchors {
            if anchor.seconds <= seconds, anchor.seconds >= before.seconds { before = anchor }
            if anchor.seconds > seconds, anchor.seconds < after.seconds { after = anchor }
        }
        var mapped = before.offset
        if after.seconds > before.seconds, after.offset > before.offset {
            // Multiplied before it is divided: a fraction like 42/60 isn't exact in binary, and
            // rounded down it lost a byte off a constant-rate mapping that should land exactly.
            let span = Double(after.offset - before.offset) * (seconds - before.seconds)
            mapped += Int64((span / (after.seconds - before.seconds)).rounded(.down))
        }
        return min(max(mapped, layout.audio.lowerBound), layout.audio.upperBound)
    }

    // MARK: Containers

    /// ISO base media: the boxes before the first `mdat` (or `moof`, for a fragmented file), with
    /// the sound track's chunks as anchors. A `moov` after the audio (a file never made streamable)
    /// is read from the far end, which this doesn't warm, so it counts as unknown.
    fileprivate static func mp4(_ bytes: Bytes) -> Scan {
        var offset = 0
        var moov: Range<Int>?
        while true {
            guard bytes.has(offset, 8) else { return bytes.more(offset + 16) }
            var size = Int(bytes.be(offset, 4))
            var headerLength = 8
            if size == 1 {
                guard bytes.has(offset, 16) else { return bytes.more(offset + 16) }
                guard let large = Int(exactly: bytes.be(offset + 8, 8)) else { return .unknown }
                size = large
                headerLength = 16
            } else if size == 0 {
                size = Int(bytes.length) - offset
            }
            guard size >= headerLength, size <= Int(bytes.length) - offset else { return .unknown }
            let end = offset + size
            switch bytes.fourCC(offset + 4) {
            case "mdat":
                guard let moov else { return .unknown }
                let start = Int64(offset + headerLength)
                return .found(Layout(headerEnd: start, audio: start..<max(start, min(Int64(end), bytes.length)),
                                     anchors: soundChunks(bytes, in: moov)))
            case "moof":
                // ponytail: a fragmented file's `sidx` would pin its fragments; interpolated instead.
                guard moov != nil else { return .unknown }
                let start = Int64(offset)
                return .found(Layout(headerEnd: start, audio: start..<max(start, bytes.length)))
            case "moov":
                // Its sample tables pin times to bytes, so the whole box is wanted in hand.
                guard bytes.has(offset, size) else { return bytes.more(end + 16) }
                moov = (offset + headerLength)..<end
            default:
                break
            }
            offset = end
        }
    }

    /// The time and byte offset of each chunk of the sound track: `stco`/`co64` for the offsets,
    /// timed through `stsc` (samples per chunk) and `stts` (sample durations).
    fileprivate static func soundChunks(_ bytes: Bytes, in moov: Range<Int>) -> [Anchor] {
        for trak in bytes.boxes(in: moov) where trak.type == "trak" {
            guard let mdia = bytes.boxes(in: trak.body).first(where: { $0.type == "mdia" }) else { continue }
            let media = bytes.boxes(in: mdia.body)
            guard let hdlr = media.first(where: { $0.type == "hdlr" }), bytes.has(hdlr.body.lowerBound + 8, 4),
                  bytes.fourCC(hdlr.body.lowerBound + 8) == "soun",
                  let mdhd = media.first(where: { $0.type == "mdhd" }), bytes.has(mdhd.body.lowerBound, 4),
                  let minf = media.first(where: { $0.type == "minf" }),
                  let stbl = bytes.boxes(in: minf.body).first(where: { $0.type == "stbl" }) else { continue }
            let timescaleAt = mdhd.body.lowerBound + (bytes.raw[mdhd.body.lowerBound] == 1 ? 20 : 12)
            guard bytes.has(timescaleAt, 4), mdhd.body.upperBound >= timescaleAt + 4 else { return [] }
            let timescale = Double(bytes.be(timescaleAt, 4))
            let tables = bytes.boxes(in: stbl.body)
            guard timescale > 0,
                  let stts = tables.first(where: { $0.type == "stts" }),
                  let stsc = tables.first(where: { $0.type == "stsc" }) else { return [] }
            let offsets: [Int64]
            if let stco = tables.first(where: { $0.type == "stco" }) {
                offsets = bytes.entries(of: stco, width: 4).map { Int64(bytes.be($0, 4)) }
            } else if let co64 = tables.first(where: { $0.type == "co64" }) {
                offsets = bytes.entries(of: co64, width: 8).compactMap { Int64(exactly: bytes.be($0, 8)) }
            } else {
                return []
            }
            let durations = bytes.entries(of: stts, width: 8).map { (count: bytes.be($0, 4), delta: bytes.be($0 + 4, 4)) }
            let runs = bytes.entries(of: stsc, width: 12).map { (firstChunk: bytes.be($0, 4), samples: bytes.be($0 + 4, 4)) }
            guard !runs.isEmpty else { return [] }

            var anchors: [Anchor] = []
            anchors.reserveCapacity(offsets.count)
            var run = 0
            var entry = 0
            var leftInEntry = durations.first?.count ?? 0
            var ticks: UInt64 = 0
            for (index, offset) in offsets.enumerated() {
                let chunk = UInt64(index + 1)
                while run + 1 < runs.count, runs[run + 1].firstChunk <= chunk { run += 1 }
                anchors.append(Anchor(seconds: Double(ticks) / timescale, offset: offset))
                var samples = runs[run].samples
                while samples > 0, entry < durations.count {
                    if leftInEntry == 0 {
                        entry += 1
                        leftInEntry = entry < durations.count ? durations[entry].count : 0
                        continue
                    }
                    let step = min(samples, leftInEntry)
                    ticks &+= step &* durations[entry].delta
                    samples -= step
                    leftInEntry -= step
                }
            }
            return anchors
        }
        return []
    }

    /// FLAC: the metadata blocks, with the seek table's points as anchors. Only a block's header is
    /// needed to step past it, so a large cover doesn't have to be in hand to find where it ends.
    fileprivate static func flac(_ bytes: Bytes) -> Scan {
        var offset = 4
        var sampleRate = 0.0
        var points: [(sample: UInt64, offset: UInt64)] = []
        while true {
            guard bytes.has(offset, 4) else { return bytes.more(offset + 4) }
            let isLast = bytes.raw[offset] & 0x80 != 0
            let type = bytes.raw[offset] & 0x7F
            let body = offset + 4
            let end = body + Int(bytes.be(offset + 1, 3))
            switch type {
            case 0:
                // STREAMINFO: a 20-bit sample rate, ten bytes in.
                guard bytes.has(body, 13) else { return bytes.more(end + 4) }
                sampleRate = Double(bytes.be(body + 10, 3) >> 4)
            case 3:
                // SEEKTABLE: 18-byte points (first sample, byte offset past the metadata, samples);
                // a placeholder point's sample is all ones.
                guard bytes.has(body, end - body) else { return bytes.more(end + 4) }
                for point in stride(from: body, through: end - 18, by: 18) where bytes.be(point, 8) != UInt64.max {
                    points.append((bytes.be(point, 8), bytes.be(point + 8, 8)))
                }
            default:
                break
            }
            if isLast {
                let start = Int64(end)
                let anchors = points.compactMap { point -> Anchor? in
                    guard sampleRate > 0, let offset = Int64(exactly: point.offset), offset <= bytes.length else { return nil }
                    return Anchor(seconds: Double(point.sample) / sampleRate, offset: start + offset)
                }
                return .found(Layout(headerEnd: start, audio: start..<max(start, bytes.length), anchors: anchors, isWalkedFromTheStart: true))
            }
            offset = end
        }
    }

    /// WAV: the chunks up to `data`. A streamed WAV can't know its size and says 0xFFFFFFFF, so the
    /// audio is clamped to the file.
    fileprivate static func wav(_ bytes: Bytes) -> Scan {
        var offset = 12
        while true {
            guard bytes.has(offset, 8) else { return bytes.more(offset + 8) }
            let size = Int64(bytes.le(offset + 4, 4))
            let body = Int64(offset + 8)
            if bytes.ascii(offset, "data") {
                return .found(Layout(headerEnd: body, audio: body..<max(body, min(body + size, bytes.length))))
            }
            offset = Int(body + size + (size & 1))
        }
    }

    /// Core Audio Format: the chunks up to `data`, whose body opens with a 4-byte edit count. A
    /// `data` size of -1 runs to the end of the file.
    fileprivate static func caf(_ bytes: Bytes) -> Scan {
        var offset = 8
        while true {
            guard bytes.has(offset, 12) else { return bytes.more(offset + 12) }
            let size = Int64(bitPattern: bytes.be(offset + 4, 8))
            let body = Int64(offset + 12)
            let fits = size >= 0 && size <= bytes.length - body
            if bytes.ascii(offset, "data") {
                let start = body + 4
                let end = fits ? body + size : bytes.length
                return .found(Layout(headerEnd: start, audio: start..<max(start, end)))
            }
            guard fits else { return .unknown }
            offset = Int(body + size)
        }
    }

    // MARK: Bytes

    fileprivate struct Box {
        var type: String
        var body: Range<Int>
    }

    fileprivate struct Bytes {
        let raw: [UInt8]
        /// The whole file's length, of which `raw` is the opening.
        let length: Int64

        func has(_ offset: Int, _ count: Int) -> Bool { offset >= 0 && count >= 0 && offset + count <= raw.count }

        func ascii(_ offset: Int, _ text: String) -> Bool {
            let wanted = Array(text.utf8)
            return has(offset, wanted.count) && Array(raw[offset..<(offset + wanted.count)]) == wanted
        }

        func fourCC(_ offset: Int) -> String {
            guard has(offset, 4) else { return "" }
            return String(decoding: raw[offset..<(offset + 4)], as: UTF8.self)
        }

        func be(_ offset: Int, _ count: Int) -> UInt64 {
            (0..<count).reduce(UInt64(0)) { $0 << 8 | UInt64(raw[offset + $1]) }
        }

        func le(_ offset: Int, _ count: Int) -> UInt64 {
            (0..<count).reversed().reduce(UInt64(0)) { $0 << 8 | UInt64(raw[offset + $1]) }
        }

        /// Asks for bytes through `end`, unless the whole file is already in hand.
        func more(_ end: Int) -> Scan {
            Int64(raw.count) >= length ? .unknown : .needMore(through: Int64(end))
        }

        /// The boxes wholly inside `range`, stopping at the first that isn't.
        func boxes(in range: Range<Int>) -> [Box] {
            var result: [Box] = []
            var offset = range.lowerBound
            while offset + 8 <= range.upperBound, has(offset, 8) {
                var size = Int(be(offset, 4))
                var headerLength = 8
                if size == 1 {
                    guard has(offset, 16), let large = Int(exactly: be(offset + 8, 8)) else { break }
                    size = large
                    headerLength = 16
                } else if size == 0 {
                    size = range.upperBound - offset
                }
                guard size >= headerLength, size <= range.upperBound - offset else { break }
                result.append(Box(type: fourCC(offset + 4), body: (offset + headerLength)..<(offset + size)))
                offset += size
            }
            return result
        }

        /// Where each entry of a full box's table starts (version and flags, a count, then
        /// `width`-byte entries), as many as fit in the box.
        func entries(of box: Box, width: Int) -> [Int] {
            let start = box.body.lowerBound
            guard has(start, 8), box.body.upperBound >= start + 8 else { return [] }
            let fits = (box.body.upperBound - start - 8) / width
            let count = min(Int(be(start + 4, 4)), fits)
            return (0..<max(0, count)).map { start + 8 + $0 * width }
        }
    }
}
