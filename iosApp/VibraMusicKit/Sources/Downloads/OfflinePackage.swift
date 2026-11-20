import Foundation

// Ports download/OfflineDash.kt and download/OfflineHls.kt (the manifest readers). The fetching
// half lives in `Downloader.fetchPackage` (Downloader.swift) because on iOS it runs through the same
// resumable transport as every other download.

/// Why an offline package can't be saved. The messages are written for the user.
struct OfflinePackageError: Error, Equatable, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

/// An offline copy of an MPEG-DASH audio manifest.
///
/// ### Why DASH exists here at all
///
/// Because the shape of a module's stream is the backend's choice. The Tidal module served `.m3u8`
/// until September 2026 and `.mpd` afterwards — same track, same tier. Before this existed on
/// Android a `.mpd` went down the ordinary fetch-and-save path and wrote **2,738 bytes of XML into a
/// file called `Artist - Track.flac`**: a download that reported success and could never play.
///
/// ### How iOS saves it (differs from Android)
///
/// Android rewrites the manifest as an HLS playlist over the saved segments, because Media3 plays a
/// local `.m3u8`. AVPlayer only plays offline HLS from a `.movpkg` made by
/// `AVAssetDownloadURLSession`, which can't be fed a DASH manifest. But both manifests describe the
/// same thing — an fMP4 initialisation segment and a run of media segments — and the init segment
/// followed by every segment's `moof`/`mdat` pairs *is* a fragmented MP4 file, which AVPlayer plays
/// from disk and ``Mp4Tagger`` can tag. So the package is flattened into one `.m4a` (see
/// ``Downloader/fetchPackage(jobKey:part:dash:from:hooks:)``). The plan below is identical to Android's; only the output differs.
///
/// ### What is not supported
///
/// Encrypted manifests (`ContentProtection`), multi-period ones and `$Time$` templates — rejected
/// outright rather than half-saved: a package missing part of its audio is worse than a download
/// that says it could not be made, because only the second is recoverable.
enum OfflineDash {
    /// Whether `url` is a manifest this can save, judged the way the app judges every other one — on
    /// the extension.
    static func handles(_ url: URL) -> Bool {
        url.path(percentEncoded: false).lowercased().hasSuffix(".mpd")
    }

    static func handles(_ url: String) -> Bool {
        let path = url.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? url
        return path.lowercased().hasSuffix(".mpd")
    }

    /// One audio rendition's segments, resolved from the template into plain URLs.
    struct Plan: Equatable {
        let initialization: String
        let media: [String]
        let seconds: [Double]
    }

    /// The segment list a manifest describes.
    ///
    /// Read with regexes rather than an XML parser, and narrowly: this handles the single-period,
    /// single-audio-representation, `SegmentTemplate` manifests the source modules actually serve,
    /// and refuses everything else instead of guessing.
    static func parse(_ manifest: String) throws -> Plan {
        if manifest.range(of: "<ContentProtection", options: .caseInsensitive) != nil {
            throw OfflinePackageError("Encrypted DASH cannot be saved")
        }
        if matches(#"<Period[\s>]"#, in: manifest).count > 1 {
            throw OfflinePackageError("Multi-period DASH cannot be saved")
        }
        guard let template = firstGroup(#"<SegmentTemplate([^>]*)>"#, in: manifest, options: .caseInsensitive) else {
            throw OfflinePackageError("DASH manifest has no segment template")
        }
        func attr(_ name: String) -> String? {
            firstGroup(#"\b"# + name + #"\s*=\s*"([^"]*)""#, in: template, options: .caseInsensitive)
        }

        guard let initialization = attr("initialization").map(unescape) else {
            throw OfflinePackageError("DASH manifest has no initialization segment")
        }
        guard let mediaTemplate = attr("media").map(unescape) else {
            throw OfflinePackageError("DASH manifest has no media template")
        }
        // Only `$Number$` is supported. `$Time$` would need the timeline's running offsets rather
        // than its durations, and no module serves it.
        guard mediaTemplate.contains("$Number$") else {
            throw OfflinePackageError("Unsupported DASH media template")
        }
        let timescale = attr("timescale").flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil } ?? 1
        let startNumber = attr("startNumber").flatMap { Int($0) } ?? 1

        // A SegmentTimeline states each segment's real length, including the short final one.
        var ticks: [Int64] = []
        if let timeline = firstGroup("<SegmentTimeline>(.*?)</SegmentTimeline>", in: manifest,
                                     options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            for entry in matches(#"<S\b([^>]*)/?>"#, in: timeline, options: .caseInsensitive) {
                let body = entry[1]
                func of(_ name: String) -> String? { firstGroup(#"\b"# + name + #"\s*=\s*"([^"]*)""#, in: body) }
                guard let d = of("d").flatMap({ Int64($0) }) else { continue }
                // `r` is how many times the entry *repeats*, so r="56" is 57 segments. Reading it as
                // a count drops one segment and truncates every download by a few seconds.
                let repeats = of("r").flatMap { Int($0) } ?? 0
                ticks += Array(repeating: d, count: max(repeats, 0) + 1)
            }
        }
        if ticks.isEmpty {
            // No timeline: a fixed duration repeated across the presentation, the other legal way
            // to write this.
            guard let d = attr("duration").flatMap({ Int64($0) }), d > 0 else {
                throw OfflinePackageError("DASH manifest has neither a timeline nor a segment duration")
            }
            guard let total = firstGroup(#"mediaPresentationDuration\s*=\s*"([^"]*)""#, in: manifest).flatMap(isoSeconds) else {
                throw OfflinePackageError("DASH manifest states no duration")
            }
            let count = max(1, Int((total / (Double(d) / timescale)).rounded(.up)))
            ticks = Array(repeating: d, count: count)
        }

        let media = ticks.indices.map { at in
            mediaTemplate.replacingOccurrences(of: "$Number$", with: String(startNumber + at))
        }
        guard !media.isEmpty else { throw OfflinePackageError("DASH manifest has no segments") }
        return Plan(initialization: initialization, media: media, seconds: ticks.map { Double($0) / timescale })
    }

    /// The five entities an MPD's URLs can arrive escaped with — `&amp;` being the one that always does.
    static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// `PT3M50.461S` → `230.461`. Hours, minutes and seconds, which is all a track ever needs.
    static func isoSeconds(_ value: String) -> Double? {
        guard let match = matches(#"PT(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?"#, in: value).first else {
            return nil
        }
        let h = Double(match[1]) ?? 0
        let m = Double(match[2]) ?? 0
        let s = Double(match[3]) ?? 0
        let seconds = h * 3600 + m * 60 + s
        return seconds > 0 ? seconds : nil
    }
}

/// An offline copy of an unencrypted HLS media playlist (Android `OfflineHls`).
///
/// Android keeps the fMP4 samples untouched behind a rewritten playlist. iOS flattens them into one
/// fragmented `.m4a` for the reason ``OfflineDash`` gives, which means only fMP4 renditions
/// (`#EXT-X-MAP`) can be saved: MPEG-TS segments concatenate into a `.ts` AVPlayer won't open from
/// disk, so those are refused with a sentence rather than saved unplayable.
///
/// One addition over Android: a multivariant (master) playlist is followed to its highest-bandwidth
/// variant. Android treated every non-comment line as a fragment, which on a master playlist would
/// have saved the variant playlists' text as audio.
enum OfflineHls {
    enum Parsed: Equatable {
        /// A master playlist; fetch this media playlist instead.
        case variant(URL)
        /// Every URL to fetch, the initialisation segment first.
        case segments([URL])
    }

    static func parse(_ playlist: String, base: URL) throws -> Parsed {
        guard playlist.hasPrefix("#EXTM3U") else { throw OfflinePackageError("Invalid HLS playlist") }
        if playlist.contains("#EXT-X-KEY:") && !playlist.contains("METHOD=NONE") {
            throw OfflinePackageError("Encrypted HLS cannot be saved")
        }
        let lines = playlist.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }

        if playlist.contains("#EXT-X-STREAM-INF") {
            var best: (bandwidth: Int, uri: String)?
            for (index, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF") {
                let bandwidth = firstGroup(#"[:,]BANDWIDTH=(\d+)"#, in: line).flatMap { Int($0) } ?? 0
                guard let uri = lines[(index + 1)...].first(where: { !$0.isEmpty && !$0.hasPrefix("#") }) else { continue }
                if best == nil || bandwidth > best!.bandwidth { best = (bandwidth, uri) }
            }
            guard let best, let url = URL(string: best.uri, relativeTo: base)?.absoluteURL else {
                throw OfflinePackageError("HLS playlist has no variants")
            }
            return .variant(url)
        }

        var references = lines.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard let map = firstGroup(#"#EXT-X-MAP:.*URI="([^"]+)""#, in: playlist) else {
            if references.isEmpty { throw OfflinePackageError("HLS playlist has no fragments") }
            throw OfflinePackageError("This stream's format can't be saved on this device")
        }
        references.insert(map, at: 0)
        var seen = Set<String>()
        let unique = references.filter { seen.insert($0).inserted }
        guard unique.count > 1 else { throw OfflinePackageError("HLS playlist has no fragments") }
        return .segments(try unique.map { remote in
            guard let url = URL(string: remote, relativeTo: base)?.absoluteURL else {
                throw OfflinePackageError("Invalid HLS fragment")
            }
            return url
        })
    }
}

// MARK: - Regex helpers

/// Every match of `pattern`, each as its capture groups (index 0 is the whole match; a group that
/// didn't take part is "").
func matches(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [[String]] {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: range).map { match in
        (0..<match.numberOfRanges).map { group in
            Range(match.range(at: group), in: text).map { String(text[$0]) } ?? ""
        }
    }
}

/// The first capture group of the first match, or nil.
func firstGroup(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[range])
}

/// The package saver's two pure steps, for a caller outside this module that keeps a segmented
/// stream some other way (the app's audio cache saves a played playlist stream as one file).
public enum StreamPackage {
    public enum Playlist: Equatable, Sendable {
        /// A master playlist; fetch this media playlist instead.
        case variant(URL)
        /// Every URL to fetch, the initialisation segment first.
        case segments([URL])
    }

    /// Reads an HLS playlist. Throws for one that can't be saved as a single file (encrypted,
    /// MPEG-TS, cut by byte range).
    public static func parse(playlist: String, base: URL) throws -> Playlist {
        if playlist.range(of: "BYTERANGE", options: .caseInsensitive) != nil {
            throw OfflinePackageError("Byte-range playlists cannot be saved")
        }
        switch try OfflineHls.parse(playlist, base: base) {
        case .variant(let next): return .variant(next)
        case .segments(let urls): return .segments(urls)
        }
    }

    /// The bytes of one fetched segment that belong in the single fragmented MP4.
    public static func flatten(_ segment: Data, isInitialization: Bool) throws -> Data {
        try Downloader.flatten(segment, isInitialization: isInitialization)
    }
}
