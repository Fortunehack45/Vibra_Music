import Foundation

// No Android counterpart: ExoPlayer plays DASH itself (`DashMediaSource`), so the Android addon
// path only had to *declare* the transport. AVPlayer has no DASH support, so an addon's `.mpd`
// (Tidal's Hi-Res FLAC and Dolby Atmos are served that way) has to become something AVFoundation
// opens — see ``DashToHLS``. This file reads just enough of an MPD to do that: the audio
// representations and their segment addressing.

/// One audio representation of a DASH presentation, with every segment's absolute URL.
public struct DashAudioTrack: Hashable, Sendable {
    public struct Segment: Hashable, Sendable {
        public var url: URL
        /// `start...end` (inclusive) inside `url`, for SegmentList `mediaRange`/`range`.
        public var byteRange: ClosedRange<Int64>?
        /// Seconds; zero for an initialization segment.
        public var duration: Double
    }

    public var representationId: String
    /// As the MPD states it: `flac`, `mp4a.40.2`, `ec-3`, `alac`.
    public var codecs: String?
    public var mimeType: String?
    public var bandwidth: Int?
    public var sampleRate: Int?
    /// Where the whole file lives when the representation is one file (SegmentBase or no segment
    /// information at all). Such a track plays progressively and needs no playlist.
    public var singleFileURL: URL?
    public var initialization: Segment?
    public var segments: [Segment]
    public var totalDuration: Double

    public var isSingleFile: Bool { singleFileURL != nil }

    /// Whether the MPD says this is the immersive E-AC-3 (JOC) mix.
    public var isDolby: Bool {
        guard let codecs = codecs?.lowercased() else { return false }
        return codecs.hasPrefix("ec-3") || codecs.hasPrefix("ac-3") || codecs.contains("eac3")
    }
}

public enum DashManifestError: LocalizedError, Equatable {
    case unreadable(String)
    case noAudio
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let detail): return "Unreadable DASH manifest: \(detail)"
        case .noAudio: return "The DASH manifest lists no audio"
        case .unsupported(let detail): return "Unsupported DASH manifest: \(detail)"
        }
    }
}

/// A parsed MPD, reduced to its first period's audio representations.
public struct DashManifest: Sendable {
    /// The most segments one manifest may describe: over two days of two-second segments, so
    /// only a hostile manifest reaches it.
    static let maxSegments = 100_000

    public var tracks: [DashAudioTrack]
    public var isDynamic: Bool

    /// Parses `data`, resolving every URL against `url` (the manifest's own address) and the
    /// `BaseURL` chain inside it.
    public static func parse(_ data: Data, url: URL) throws -> DashManifest {
        let tree = try XMLTree.parse(data)
        guard tree.name == "MPD" else { throw DashManifestError.unreadable("the root is <\(tree.name)>, not <MPD>") }
        let isDynamic = tree.attributes["type"] == "dynamic"
        let presentationDuration = tree.attributes["mediaPresentationDuration"].flatMap(Self.seconds)
        let mpdBase = resolve(baseOf: tree, against: url)

        guard let period = tree.children(named: "Period").first else { throw DashManifestError.noAudio }
        let periodBase = resolve(baseOf: period, against: mpdBase)
        let periodDuration = period.attributes["duration"].flatMap(Self.seconds) ?? presentationDuration

        var tracks: [DashAudioTrack] = []
        var segmentCount = 0
        for adaptation in period.children(named: "AdaptationSet") {
            let adaptationBase = resolve(baseOf: adaptation, against: periodBase)
            for representation in adaptation.children(named: "Representation") {
                let mimeType = representation.attributes["mimeType"] ?? adaptation.attributes["mimeType"]
                let contentType = representation.attributes["contentType"] ?? adaptation.attributes["contentType"]
                let isAudio = mimeType?.lowercased().hasPrefix("audio") == true
                    || contentType?.lowercased() == "audio"
                    || (mimeType == nil && contentType == nil && representation.attributes["audioSamplingRate"] != nil)
                guard isAudio else { continue }
                let base = resolve(baseOf: representation, against: adaptationBase)
                let track = try Self.track(
                    representation: representation,
                    adaptation: adaptation,
                    period: period,
                    base: base,
                    mimeType: mimeType,
                    periodDuration: periodDuration,
                    budget: maxSegments - segmentCount
                )
                segmentCount += track.segments.count
                tracks.append(track)
            }
        }
        guard !tracks.isEmpty else { throw DashManifestError.noAudio }
        return DashManifest(tracks: tracks, isDynamic: isDynamic)
    }

    // MARK: Representations

    private static func track(
        representation: XMLTree,
        adaptation: XMLTree,
        period: XMLTree,
        base: URL,
        mimeType: String?,
        periodDuration: Double?,
        budget: Int
    ) throws -> DashAudioTrack {
        let id = representation.attributes["id"] ?? ""
        let bandwidth = representation.attributes["bandwidth"].flatMap { Int($0) }
        let codecs = representation.attributes["codecs"] ?? adaptation.attributes["codecs"]
        let sampleRate = (representation.attributes["audioSamplingRate"] ?? adaptation.attributes["audioSamplingRate"])
            .flatMap { Int($0) }
        var track = DashAudioTrack(
            representationId: id,
            codecs: codecs,
            mimeType: mimeType,
            bandwidth: bandwidth,
            sampleRate: sampleRate,
            singleFileURL: nil,
            initialization: nil,
            segments: [],
            totalDuration: periodDuration ?? 0
        )

        // Segment information inherits downwards: Period → AdaptationSet → Representation, the
        // nearest attribute winning.
        let templates = [period, adaptation, representation].compactMap { $0.children(named: "SegmentTemplate").first }
        let lists = [period, adaptation, representation].compactMap { $0.children(named: "SegmentList").first }

        if !templates.isEmpty {
            try fillFromTemplate(&track, templates: templates, base: base, periodDuration: periodDuration, budget: budget)
        } else if !lists.isEmpty {
            try fillFromList(&track, lists: lists, base: base, periodDuration: periodDuration, budget: budget)
        } else {
            // SegmentBase, or nothing at all: the representation is one file at its BaseURL.
            track.singleFileURL = base
        }
        return track
    }

    private static func fillFromTemplate(
        _ track: inout DashAudioTrack,
        templates: [XMLTree],
        base: URL,
        periodDuration: Double?,
        budget: Int
    ) throws {
        func attribute(_ name: String) -> String? {
            templates.reversed().lazy.compactMap { $0.attributes[name] }.first
        }
        let timescale = attribute("timescale").flatMap { Double($0) }.flatMap { $0 > 0 ? $0 : nil } ?? 1
        // An unsigned 32-bit number, as the schema has it, so numbering on from it can't overflow.
        // One outside it is refused: numbering from 1 instead would ask for segments that don't exist.
        var startNumber = 1
        if let text = attribute("startNumber") {
            guard let number = UInt32(text) else { throw DashManifestError.unsupported("startNumber out of range") }
            startNumber = Int(number)
        }
        let presentationOffset = attribute("presentationTimeOffset").flatMap { Double($0) } ?? 0
        guard let media = attribute("media") else { throw DashManifestError.unsupported("SegmentTemplate without media") }

        if let initialization = attribute("initialization") {
            let path = try substitute(initialization, track: track, number: nil, time: nil)
            guard let url = URL(string: path, relativeTo: base)?.absoluteURL else {
                throw DashManifestError.unreadable("initialization URL \(path)")
            }
            track.initialization = .init(url: url, byteRange: nil, duration: 0)
        }

        var segments: [DashAudioTrack.Segment] = []
        // The manifest's numbers are an add-on's or a module's: a time that isn't a
        // non-negative integer is refused rather than trapped on, and so is a timeline longer
        // than the manifest's budget, which its earlier representations have already drawn on.
        func add(number: Int, time: Double, duration: Double) throws {
            guard segments.count < budget else {
                throw DashManifestError.unsupported("more than \(budget) segments left of the \(maxSegments) one manifest may describe")
            }
            guard let start = Int64(exactly: time.rounded(.towardZero)), start >= 0 else {
                throw DashManifestError.unsupported("SegmentTimeline time out of range")
            }
            let path = try substitute(media, track: track, number: number, time: start)
            guard let url = URL(string: path, relativeTo: base)?.absoluteURL else {
                throw DashManifestError.unreadable("segment URL \(path)")
            }
            segments.append(.init(url: url, byteRange: nil, duration: duration / timescale))
        }

        if let timeline = templates.reversed().lazy.compactMap({ $0.children(named: "SegmentTimeline").first }).first {
            var number = startNumber
            var time = presentationOffset
            let entries = timeline.children(named: "S")
            let end = periodDuration.map { $0 * timescale + presentationOffset }
            for (index, entry) in entries.enumerated() {
                guard let duration = entry.attributes["d"].flatMap(Double.init), duration > 0 else {
                    throw DashManifestError.unreadable("SegmentTimeline entry without a duration")
                }
                if let start = entry.attributes["t"].flatMap(Double.init) { time = start }
                var repeats = entry.attributes["r"].flatMap { Int($0) } ?? 0
                if repeats < 0 {
                    // "Until the next S@t, or the end of the period."
                    let until = entries.indices.contains(index + 1)
                        ? entries[index + 1].attributes["t"].flatMap(Double.init)
                        : end
                    guard let until else { throw DashManifestError.unsupported("open-ended SegmentTimeline") }
                    guard let span = Int(exactly: ((until - time) / duration).rounded(.up)) else {
                        throw DashManifestError.unsupported("SegmentTimeline out of range")
                    }
                    repeats = span > 0 ? span - 1 : 0
                }
                for _ in 0...repeats {
                    try add(number: number, time: time, duration: duration)
                    number += 1
                    time += duration
                }
            }
        } else if let duration = attribute("duration").flatMap(Double.init), duration > 0 {
            guard let periodDuration, periodDuration > 0 else {
                throw DashManifestError.unsupported("SegmentTemplate@duration with no presentation duration")
            }
            guard let count = Int(exactly: (periodDuration * timescale / duration).rounded(.up)) else {
                throw DashManifestError.unsupported("SegmentTemplate out of range")
            }
            var remaining = periodDuration * timescale
            for index in 0..<count {
                let length = min(duration, remaining)
                try add(number: startNumber + index, time: Double(index) * duration, duration: length)
                remaining -= length
            }
        } else {
            throw DashManifestError.unsupported("SegmentTemplate with neither a timeline nor a duration")
        }
        track.segments = segments
        track.totalDuration = segments.reduce(0) { $0 + $1.duration }
    }

    private static func fillFromList(
        _ track: inout DashAudioTrack,
        lists: [XMLTree],
        base: URL,
        periodDuration: Double?,
        budget: Int
    ) throws {
        func attribute(_ name: String) -> String? {
            lists.reversed().lazy.compactMap { $0.attributes[name] }.first
        }
        let timescale = attribute("timescale").flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil } ?? 1
        let segmentDuration = attribute("duration").flatMap(Double.init).map { $0 / timescale }
        // The nearest list that actually lists segments.
        guard let list = lists.reversed().first(where: { !$0.children(named: "SegmentURL").isEmpty }) else {
            throw DashManifestError.unsupported("SegmentList with no SegmentURL")
        }
        if let initialization = lists.reversed().lazy.compactMap({ $0.children(named: "Initialization").first }).first {
            let url = initialization.attributes["sourceURL"].flatMap { URL(string: $0, relativeTo: base)?.absoluteURL } ?? base
            track.initialization = .init(url: url, byteRange: initialization.attributes["range"].flatMap(byteRange), duration: 0)
        }
        let entries = list.children(named: "SegmentURL")
        guard entries.count <= budget else {
            throw DashManifestError.unsupported("more than \(budget) segments left of the \(maxSegments) one manifest may describe")
        }
        let fallbackDuration = segmentDuration ?? (periodDuration.map { $0 / Double(entries.count) } ?? 0)
        track.segments = try entries.map { entry in
            let url: URL
            if let media = entry.attributes["media"] {
                guard let resolved = URL(string: media, relativeTo: base)?.absoluteURL else {
                    throw DashManifestError.unreadable("segment URL \(media)")
                }
                url = resolved
            } else {
                url = base
            }
            return .init(url: url, byteRange: entry.attributes["mediaRange"].flatMap(byteRange), duration: fallbackDuration)
        }
        track.totalDuration = track.segments.reduce(0) { $0 + $1.duration }
    }

    // MARK: Helpers

    /// `$RepresentationID$`, `$Number$`, `$Number%05d$`, `$Bandwidth$`, `$Time$` and `$$`.
    static func substitute(_ template: String, track: DashAudioTrack, number: Int?, time: Int64?) throws -> String {
        var output = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "$") {
            output += rest[..<open]
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "$") else {
                output += rest[open...]
                rest = ""
                break
            }
            let token = String(rest[afterOpen..<close])
            rest = rest[rest.index(after: close)...]
            if token.isEmpty {
                output += "$"
                continue
            }
            let name = token.before("%")
            let format = token.contains("%") ? "%" + token.afterLast("%") : nil
            func formatted(_ value: Int64) throws -> String {
                guard let format else { return String(value) }
                // `%05d` style widths only; anything else prints plainly. At most 20: Int64 has
                // 19 digits, and the width is the manifest's own number. A wider one is refused,
                // because clamping it would name a segment the server doesn't publish.
                let digitsOfWidth = format.dropFirst().filter(\.isNumber)
                let width = digitsOfWidth.isEmpty ? 0 : (Int(digitsOfWidth) ?? .max)
                guard width <= 20 else { throw DashManifestError.unsupported("padding width over 20") }
                let digits = String(value)
                return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
            }
            switch name {
            case "RepresentationID": output += track.representationId
            case "Number": output += try number.map { try formatted(Int64($0)) } ?? ""
            case "Time": output += try time.map(formatted) ?? ""
            case "Bandwidth": output += try track.bandwidth.map { try formatted(Int64($0)) } ?? ""
            default: output += "$\(token)$"
            }
        }
        output += rest
        return output
    }

    /// The URL an element's first `BaseURL` names, resolved against `base`; `base` when it has none.
    private static func resolve(baseOf element: XMLTree, against base: URL) -> URL {
        guard let text = element.children(named: "BaseURL").first?.text.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, let url = URL(string: text, relativeTo: base)?.absoluteURL else { return base }
        return url
    }

    private static func byteRange(_ text: String) -> ClosedRange<Int64>? {
        let parts = text.split(separator: "-")
        guard parts.count == 2, let start = Int64(parts[0]), let end = Int64(parts[1]), end >= start else { return nil }
        return start...end
    }

    /// An ISO-8601 duration (`PT3M48.577S`, `P0DT1H2M3S`) in seconds.
    static func seconds(_ text: String) -> Double? {
        let pattern = Pattern(#"^P(?:(\d+(?:\.\d+)?)D)?(?:T(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?)?$"#)
        guard let match = pattern.firstMatch(in: text.trimmingCharacters(in: .whitespaces)) else { return nil }
        let multipliers: [Double] = [86_400, 3_600, 60, 1]
        var total = 0.0
        for (offset, multiplier) in multipliers.enumerated() {
            guard let range = Range(match.range(at: offset + 1), in: text.trimmingCharacters(in: .whitespaces)),
                  let value = Double(text.trimmingCharacters(in: .whitespaces)[range]) else { continue }
            total += value * multiplier
        }
        return total
    }
}

/// A minimal DOM over `XMLParser`: names without namespace prefixes, attributes, text.
final class XMLTree {
    let name: String
    let attributes: [String: String]
    private(set) var elements: [XMLTree] = []
    fileprivate(set) var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func children(named name: String) -> [XMLTree] { elements.filter { $0.name == name } }

    static func parse(_ data: Data) throws -> XMLTree {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw DashManifestError.unreadable(parser.parserError?.localizedDescription ?? "not XML")
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLTree?
        private var stack: [XMLTree] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let local = elementName.afterLast(":")
            let node = XMLTree(name: local, attributes: attributeDict)
            if let parent = stack.last {
                parent.elements.append(node)
            } else {
                root = node
            }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }
    }
}
