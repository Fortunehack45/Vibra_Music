import Foundation

// Ports data/sources/module/{ModuleIndex,SpineModule,ModuleResults}.kt. Legacy (PORTING Q4): an
// index configured before addons existed keeps working; new ones can't be added.

/// One plugin descriptor as published in a module index. `download` is an absolute URL or a
/// filename relative to the index's own base.
public struct SpineModule: Decodable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var author: String
    public var version: String
    public var description: String
    /// Some indexes publish capabilities under `labels` instead of `tags`; whichever is present.
    public var tags: [String]
    public var download: String
    public var trusted: Bool

    public init(id: String, name: String, download: String, tags: [String] = []) {
        self.id = id
        self.name = name
        self.download = download
        self.tags = tags
        author = ""
        version = ""
        description = ""
        trusted = false
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        // id and name are required, as in the Kotlin data class: a descriptor without them is not
        // a module and fails its own decode (the list decode drops it).
        guard let id = c.lenientString("id"), let name = c.lenientString("name") else {
            throw DecodingError.keyNotFound(AnyCodingKey("id"), .init(codingPath: c.codingPath, debugDescription: "module without id/name"))
        }
        self.id = id
        self.name = name
        author = c.lenientString("author") ?? ""
        version = c.lenientString("version") ?? ""
        description = c.lenientString("description") ?? ""
        let declaredTags = c.lenientStrings("tags")
        tags = declaredTags.isEmpty ? c.lenientStrings("labels") : declaredTags
        download = c.lenientString("download") ?? ""
        trusted = c.lenientBool("trusted") ?? false
    }

    public var isLossless: Bool {
        tags.contains { tag in ["LOSSLESS", "HI-RES", "FLAC"].contains(where: tag.uppercased().contains) }
    }

    public var isDolbyAtmos: Bool {
        tags.contains { tag in ["ATMOS", "DOLBY"].contains(where: tag.uppercased().contains) }
    }
}

/// Parses a module-index body into a flat list of modules.
///
/// Index servers file modules under arbitrary `category:<key>` keys; a fixed-field model would
/// drop every module under an unrecognised key, so every key starting `category:` is read.
public enum ModuleIndex {
    private static let excludedCategories: Set<String> = ["category:artworks", "category:testing"]

    public static func parseModules(_ body: Data) throws -> [SpineModule] {
        guard let root = JSONValue.parse(body), let object = root.objectValue else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "module index is not a JSON object"))
        }
        var seen = Set<String>()
        var modules: [SpineModule] = []
        for key in SourceFormats.orderedKeys(body) where key.hasPrefix("category:") && !excludedCategories.contains(key) {
            guard let list = object[key]?.arrayValue else { continue }
            // A category that fails to decode as a whole is skipped (Kotlin's getOrElse { empty }).
            guard let data = try? JSONSerialization.data(withJSONObject: list.map(\.foundationValue)),
                  let decoded = try? JSONDecoder().decode([SpineModule].self, from: data) else { continue }
            for module in decoded where seen.insert(module.id).inserted {
                modules.append(module)
            }
        }
        return modules
    }
}

/// One track from a module's `searchTracks()`.
struct ModuleSearchResult: Decodable, Hashable, Sendable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var albumCover: String?
    var duration: Int
    /// Free text, spelt differently by every module: `LOSSLESS`, `FLAC 16-bit / 44.1kHz`, `128kbps`.
    var audioQuality: String
    var format: String
    /// Tiers the row can be fetched at, for modules that enumerate them.
    var availableQualities: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        id = c.lenientString("id") ?? ""
        title = c.lenientString("title") ?? ""
        artist = c.lenientString("artist") ?? ""
        album = c.lenientString("album") ?? ""
        albumCover = c.lenientString("albumCover")
        duration = c.lenientInt("duration") ?? 0
        audioQuality = c.lenientString("audioQuality") ?? ""
        format = c.lenientString("format") ?? ""
        availableQualities = c.lenientStrings("availableQualities")
    }
}

struct ModuleSearchResponse: Decodable, Sendable {
    var tracks: [ModuleSearchResult]
    var total: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        tracks = c.lenientArray("tracks", of: ModuleSearchResult.self)
        total = c.lenientInt("total") ?? 0
    }
}

/// `getTrackStreamUrl()`'s answer. `streamUrl: null` is an unavailable rendition, not a parse
/// failure that burns the resolution budget.
struct ModuleStreamResponse: Decodable, Sendable {
    var streamUrl: String?
    var track: ModuleStreamTrack?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        streamUrl = c.lenientString("streamUrl")
        track = c.lenientObject("track", as: ModuleStreamTrack.self)
    }
}

struct ModuleStreamTrack: Decodable, Sendable {
    var audioQuality: String
    var mimeType: String?
    var bitDepth: Int?
    var sampleRate: Double?
    var bitrate: Int?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        audioQuality = c.lenientString("audioQuality") ?? ""
        mimeType = c.lenientString("mimeType")
        bitDepth = c.lenientInt("bitDepth")
        sampleRate = c.lenientDouble("sampleRate")
        bitrate = c.lenientInt("bitrate")
    }
}
