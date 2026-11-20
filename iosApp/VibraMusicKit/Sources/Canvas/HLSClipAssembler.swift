import Foundation

/// Turns Apple Music's motion artwork, served as HLS, into one local video file: the
/// lock screen's `MPMediaItemAnimatedArtwork` takes only a local file, never a stream.
///
/// What Apple serves (checked against the catalogue's `editorialVideo` playlists): a master with
/// video-only variants (`…_Anull_…`) in H.264 and HEVC at several square or 3:4 sizes, each a
/// CMAF media playlist whose init map and segments are byte ranges of one `.mp4`. Init plus
/// segments, in order, is a playable fragmented MP4, so no remuxing is needed: the bytes are
/// fetched as they are. TS segments (no init map) or encrypted playlists can't be joined into a
/// file this way and are left alone, as is any playlist this does not understand.
public enum HLSClipAssembler {
    /// One `#EXT-X-STREAM-INF` entry of a master playlist.
    public struct Variant: Equatable, Sendable {
        public var url: URL
        public var width: Int
        public var height: Int
        public var codecs: String
    }

    /// One download: a whole file, or a byte range of it.
    public struct Part: Equatable, Sendable {
        public var url: URL
        /// Byte offsets in `url`; nil for the whole file.
        public var range: Range<Int>?
    }

    /// The shortest side worth taking: sharp on a lock screen, without paying for 1080.
    public static let preferredMinimumSide = 720
    /// Larger plans are refused: a looping clip, not a film.
    public static let maximumBytes = 40 * 1024 * 1024

    // MARK: - Master playlist

    /// The stream variants of a master playlist, with URIs resolved against `base`.
    public static func variants(master: String, base: URL) -> [Variant] {
        var result: [Variant] = []
        var pending: [String: String]?
        for raw in master.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            } else if let attrs = pending, !line.isEmpty, !line.hasPrefix("#") {
                pending = nil
                guard let url = URL(string: line, relativeTo: base)?.absoluteURL,
                      let size = attrs["RESOLUTION"], let (width, height) = resolution(size) else { continue }
                result.append(Variant(url: url, width: width, height: height, codecs: attrs["CODECS"] ?? ""))
            }
        }
        return result
    }

    /// The variant to download: H.264 when there is one (it decodes everywhere the lock screen
    /// does), then the smallest whose shorter side reaches ``preferredMinimumSide``, else the
    /// largest there is.
    public static func pick(_ variants: [Variant], minimumSide: Int = preferredMinimumSide) -> Variant? {
        let avc = variants.filter { $0.codecs.lowercased().contains("avc1") }
        let pool = avc.isEmpty ? variants : avc
        let side: (Variant) -> Int = { min($0.width, $0.height) }
        if let enough = pool.filter({ side($0) >= minimumSide }).min(by: { side($0) < side($1) }) {
            return enough
        }
        return pool.max(by: { side($0) < side($1) })
    }

    // MARK: - Media playlist

    /// The downloads that make the clip, in order: the init map, then every segment. Nil when the
    /// playlist can't become one file this way (no init map, i.e. TS; encrypted; no segments).
    public static func parts(media: String, base: URL) -> [Part]? {
        var map: Part?
        var segments: [Part] = []
        var pendingRange: (length: Int, offset: Int?)?
        var lastEnd: [URL: Int] = [:]
        var sawSegment = false
        for raw in media.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-KEY:") {
                let method = attributes(String(line.dropFirst("#EXT-X-KEY:".count)))["METHOD"] ?? "NONE"
                if method.uppercased() != "NONE" { return nil }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attrs = attributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                guard let uri = attrs["URI"], let url = URL(string: uri, relativeTo: base)?.absoluteURL else { return nil }
                var range: Range<Int>?
                if let spec = attrs["BYTERANGE"] {
                    guard let parsed = byteRange(spec),
                          let bounds = span(parsed.offset ?? 0, parsed.length) else { return nil }
                    range = bounds
                    lastEnd[url] = bounds.upperBound
                }
                // A second, different init map (after a discontinuity) muxes the later fragments
                // against other tracks: one file can't hold both.
                let part = Part(url: url, range: range)
                guard map == nil || map == part else { return nil }
                map = part
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingRange = byteRange(String(line.dropFirst("#EXT-X-BYTERANGE:".count)))
                if pendingRange == nil { return nil }
            } else if line.hasPrefix("#EXTINF:") {
                sawSegment = true
            } else if !line.isEmpty, !line.hasPrefix("#") {
                guard sawSegment, let url = URL(string: line, relativeTo: base)?.absoluteURL else { return nil }
                var range: Range<Int>?
                if let pending = pendingRange {
                    // No offset continues where the last range of the same file ended (RFC 8216
                    // 4.3.2.2); with no earlier range there the playlist is invalid.
                    guard let start = pending.offset ?? lastEnd[url],
                          let bounds = span(start, pending.length) else { return nil }
                    range = bounds
                    lastEnd[url] = bounds.upperBound
                }
                segments.append(Part(url: url, range: range))
                pendingRange = nil
                sawSegment = false
            }
        }
        guard let map, !segments.isEmpty else { return nil }
        return [map] + segments
    }

    /// The same downloads with neighbouring ranges of one file joined, so a CMAF single-file
    /// playlist becomes one request.
    public static func coalesce(_ parts: [Part]) -> [Part] {
        var result: [Part] = []
        for part in parts {
            if let last = result.last, last.url == part.url,
               let a = last.range, let b = part.range, a.upperBound == b.lowerBound {
                result[result.count - 1].range = a.lowerBound..<b.upperBound
            } else {
                result.append(part)
            }
        }
        return result
    }

    // MARK: - Download

    /// The clip at `master` as one file's bytes, or nil when any step fails or it would be too big.
    public static func assemble(master: URL, session: URLSession) async -> Data? {
        guard let masterText = await text(master, session: session),
              let variant = pick(variants(master: masterText, base: master)),
              let mediaText = await text(variant.url, session: session),
              let plan = parts(media: mediaText, base: variant.url).map(coalesce) else { return nil }
        let sizes = plan.compactMap { $0.range?.count }
        // Each size is capped first, so their sum can't overflow on a hostile playlist.
        guard sizes.allSatisfy({ $0 <= maximumBytes }), sizes.reduce(0, +) <= maximumBytes else { return nil }
        var data = Data()
        for part in plan {
            guard !Task.isCancelled, let bytes = await fetch(part, session: session) else { return nil }
            data.append(bytes)
            guard data.count <= maximumBytes else { return nil }
        }
        return data.isEmpty ? nil : data
    }

    /// Playlists are a few kilobytes; anything near this is not one.
    private static let maximumPlaylistBytes = 1024 * 1024

    private static func text(_ url: URL, session: URLSession) async -> String? {
        guard let (status, body, size) = await download(URLRequest(url: url), session: session) else { return nil }
        defer { try? body.close() }
        guard status / 100 == 2, size <= maximumPlaylistBytes else { return nil }
        return read(body, 0..<size).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// One part's bytes.
    private static func fetch(_ part: Part, session: URLSession) async -> Data? {
        var request = URLRequest(url: part.url)
        if let range = part.range {
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        }
        guard let (status, body, size) = await download(request, session: session) else { return nil }
        defer { try? body.close() }
        switch (status, part.range) {
        case (200..<300, nil) where size <= maximumBytes:
            return read(body, 0..<size)
        case (206, let range?) where size == range.count:
            return read(body, 0..<size)
        // A server that ignores the Range header answers 200 with the whole file: the range is
        // cut out of it here.
        case (200, let range?) where size >= range.upperBound:
            return read(body, range)
        default:
            return nil
        }
    }

    /// `request`'s answer, kept on disk so a body far past the caps is never read into memory.
    private static func download(
        _ request: URLRequest, session: URLSession
    ) async -> (status: Int, body: FileHandle, size: Int)? {
        guard let (file, response) = try? await session.download(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return nil }
        // The open handle keeps reading the file after its name is gone.
        defer { try? FileManager.default.removeItem(at: file) }
        guard let body = try? FileHandle(forReadingFrom: file) else { return nil }
        guard let size = try? body.seekToEnd() else { try? body.close(); return nil }
        return (status, body, Int(size))
    }

    private static func read(_ body: FileHandle, _ range: Range<Int>) -> Data? {
        guard !range.isEmpty, (try? body.seek(toOffset: UInt64(range.lowerBound))) != nil,
              let data = try? body.read(upToCount: range.count), data.count == range.count else { return nil }
        return data
    }

    // MARK: - Attribute parsing

    /// An HLS attribute list (`KEY=value,KEY="quoted, with commas"`), quotes removed.
    static func attributes(_ list: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var inKey = true
        var quoted = false
        func flush() {
            let name = key.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { result[name] = value }
            key = ""; value = ""; inKey = true
        }
        for character in list {
            if inKey {
                if character == "=" { inKey = false } else if character != "," { key.append(character) }
            } else if character == "\"" {
                quoted.toggle()
            } else if character == ",", !quoted {
                flush()
            } else {
                value.append(character)
            }
        }
        flush()
        return result
    }

    /// `768x768` → (768, 768).
    static func resolution(_ text: String) -> (Int, Int)? {
        let sides = text.lowercased().split(separator: "x").compactMap { Int($0) }
        guard sides.count == 2, sides[0] > 0, sides[1] > 0 else { return nil }
        return (sides[0], sides[1])
    }

    /// `offset..<offset + length`, or nil when the playlist's numbers overflow.
    static func span(_ offset: Int, _ length: Int) -> Range<Int>? {
        let end = offset.addingReportingOverflow(length)
        return end.overflow ? nil : offset..<end.partialValue
    }

    /// `701515@896` → (701515, 896); `701515` → (701515, nil).
    static func byteRange(_ text: String) -> (length: Int, offset: Int?)? {
        let pieces = text.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).split(separator: "@")
        guard let length = pieces.first.flatMap({ Int($0) }), length > 0 else { return nil }
        if pieces.count == 2 {
            guard let offset = Int(pieces[1]), offset >= 0 else { return nil }
            return (length, offset)
        }
        return (length, nil)
    }
}
