import Foundation

// Ports data/sources/addon/AddonModels.kt: the wire shapes of the addon protocol.
//
// An addon is an ordinary HTTP server, not code: it answers `/manifest.json`, `/search?q=` and
// `/stream/{id}` with JSON, and nothing is ever executed on this side. Every field the app does not
// read is absent; the decoding is lenient and ignores unknown keys, so an addon that publishes more
// (video renditions, chapters, ISRCs) is not a parse failure.

// MARK: Manifest

/// What an addon says it is and what it can do.
public struct AddonManifest: Decodable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var version: String
    public var resources: [String]
    /// The settings schema the addon declares. Read for its *defaults*, not to build a UI: the
    /// protocol has the host send what the user picked as query parameters, and with no form the
    /// declared defaults are what the reference host sends. That is what reaches an addon that
    /// gates its lossless tier behind a `quality` setting.
    var settings: [AddonSetting]

    public init(id: String = "", name: String = "", version: String = "", resources: [String] = []) {
        self.id = id
        self.name = name
        self.version = version
        self.resources = resources
        settings = []
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        id = c.lenientString("id") ?? ""
        name = c.lenientString("name") ?? ""
        version = c.lenientString("version") ?? ""
        resources = c.lenientStrings("resources")
        settings = c.lenientArray("settings", of: AddonSetting.self)
    }

    public func declares(_ resource: String) -> Bool {
        resources.contains { $0.caseInsensitiveCompare(resource) == .orderedSame }
    }

    /// Whether this addon is worth asking anything. Only `search` is required, and only when the
    /// addon said what it does at all: a row may carry its own `streamURL`, so an addon without
    /// `stream` can still play, and an empty `resources` is silence rather than a claim.
    public var isPlayable: Bool { resources.isEmpty || declares("search") }

    /// What to show when the user did not name the addon themselves.
    public var displayName: String { name.nonBlank ?? id }
}

/// One declared setting, reduced to what the app uses: its default (sent) and its options (what a
/// `quality` request is matched against).
struct AddonSetting: Decodable, Hashable, Sendable {
    var key: String
    var defaultValue: String?
    var options: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        key = c.lenientString("key") ?? ""
        defaultValue = c.json("default")?.queryValue
        options = c.lenientArray("options", of: JSONValue.self).compactMap { option in
            option.objectValue?["value"]?.queryValue
        }
    }
}

// MARK: Search

/// A search answer. Only `tracks` is read: a source is asked for tracks and nothing else.
struct AddonSearchResponse: Decodable, Sendable {
    var tracks: [AddonTrack]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        tracks = c.lenientArray("tracks", of: AddonTrack.self)
    }
}

struct AddonTrack: Decodable, Hashable, Sendable {
    var id: String
    var title: String
    var artist: String
    var album: String
    /// Seconds, read as a double so `240.0` is not a parse failure.
    var duration: Double?
    var artworkURL: String?
    var albumArtworkURL: String?
    /// `mp3`, `flac`, `aac`, `m4a` — what the row is, when the addon says.
    var format: String
    /// Not in the spec, but several addons send it and it says the same thing.
    var audioQuality: String
    /// `STEREO`, `DOLBY_ATMOS`, `SONY_360RA`: for at least one backend the only thing that tells an
    /// immersive row apart.
    var audioMode: String?
    var audioModes: [String]
    var atmos: Bool?
    /// A stream URL for the row itself; the fallback when `/stream` has nothing.
    var streamURL: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        id = c.lenientString("id") ?? ""
        title = c.lenientString("title") ?? ""
        artist = c.lenientString("artist") ?? ""
        album = c.lenientString("album") ?? ""
        duration = c.lenientDouble("duration")
        artworkURL = c.lenientString("artworkURL")
        albumArtworkURL = c.lenientString("albumArtworkURL")
        format = c.lenientString("format") ?? ""
        audioQuality = c.lenientString("audioQuality") ?? ""
        audioMode = c.lenientString("audioMode")
        audioModes = c.lenientStrings("audioModes")
        atmos = c.lenientBool("atmos")
        streamURL = c.lenientString("streamURL")
    }

    var durationSec: Int? {
        guard let duration, duration > 0, duration.isFinite else { return nil }
        return Int(duration)
    }

    /// Whichever artwork the addon filled in.
    var artwork: String? { artworkURL?.nonBlank ?? albumArtworkURL?.nonBlank }

    /// Whether this row is the immersive mix rather than a stereo one.
    ///
    /// Read on the *row*, because a catalogue may publish the Atmos mix as its own track — Tidal
    /// does, through an addon:
    /// ```
    /// tidal:479222720  Gehra Hua  audioQuality=LOSSLESS  audioModes=[STEREO]
    /// tidal:527739156  Gehra Hua  audioQuality=LOW       audioModes=[DOLBY_ATMOS]
    /// ```
    /// Same recording, different ids, and the immersive row filed under `LOW` — read on
    /// `audioQuality` alone it is the worst thing on offer rather than the best.
    var isDolbyAtmos: Bool {
        atmos == true || addonAtmosHint.contains(
            in: "\(audioQuality) \(audioMode ?? "") \(audioModes.joined(separator: " ")) \(format)"
        )
    }
}

/// The spellings an addon uses for an immersive mix, in any free-text field. Shared by rows and
/// streams: a row recognised as Atmos whose stream is not is the inconsistency that loses the mix.
let addonAtmosHint = Pattern(#"atmos|dolby|eac3[_-]?joc|ec-?3"#, caseInsensitive: true)

// MARK: Stream

/// What is on the end of a `/stream/{id}` call.
///
/// The routing fields — codec, container, manifest, encrypted, sample rate, bit depth — are why
/// this protocol fits better than the module one: the addon states the transport up front instead
/// of leaving the player to sniff an extensionless URL.
struct AddonStream: Decodable, Hashable, Sendable {
    var url: String
    /// Free text: `mp3`, `flac`, `dash`. Describes the audio, not the transport — mostly.
    var format: String
    var quality: String
    /// Non-standard spellings of `quality` that addons in the wild send.
    var streamQuality: String
    var audioQuality: String
    var codec: String?
    var fileCodec: String?
    var container: String?
    var containerFormat: String?
    /// `none`, `hls` or `dash` — what the URL points at.
    var manifest: String?
    /// An older spelling of `manifest`.
    var mediaType: String?
    var mimeType: String?
    /// `false`, or the name of a DRM scheme. Anything but false is refused.
    var encrypted: JSONValue?
    var sampleRate: Double?
    var bitDepth: Double?
    /// Bits per second or kbps — addons send both; see ``kbps``.
    var bitrate: Double?
    var audioMode: String?
    var audioModes: [String]
    /// Why there is no `url`, when the addon bothered to say. Not in the spec, which has failures
    /// answered by status code; a live addon answers `HTTP 200 {"error": "Deezer ARL required — set
    /// it in the setup page"}`, and that second kind is a setting the user can go and fix.
    var error: String?

    init(url: String, format: String = "") {
        self.url = url
        self.format = format
        quality = ""
        streamQuality = ""
        audioQuality = ""
        audioModes = []
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        url = c.lenientString("url") ?? ""
        format = c.lenientString("format") ?? ""
        quality = c.lenientString("quality") ?? ""
        streamQuality = c.lenientString("streamQuality") ?? ""
        audioQuality = c.lenientString("audioQuality") ?? ""
        codec = c.lenientString("codec")
        fileCodec = c.lenientString("fileCodec")
        container = c.lenientString("container")
        containerFormat = c.lenientString("containerFormat")
        manifest = c.lenientString("manifest")
        mediaType = c.lenientString("mediaType")
        mimeType = c.lenientString("mimeType")
        encrypted = c.json("encrypted")
        sampleRate = c.lenientDouble("sampleRate")
        bitDepth = c.lenientDouble("bitDepth")
        bitrate = c.lenientDouble("bitrate")
        audioMode = c.lenientString("audioMode")
        audioModes = c.lenientStrings("audioModes")
        error = c.lenientString("error")
    }

    /// Whichever codec field the addon filled in, lowercased.
    var statedCodec: String? { (codec?.nonBlank ?? fileCodec?.nonBlank)?.lowercased() }

    /// Whichever container field the addon filled in, lowercased.
    var statedContainer: String? { (container?.nonBlank ?? containerFormat?.nonBlank)?.lowercased() }

    /// Every free-text quality field at once, for the label readers to scan.
    var qualityText: String { "\(quality) \(streamQuality) \(audioQuality) \(format)" }

    /// Whether this rendition is behind a DRM scheme. The app never sends `?drm=`, so an encrypted
    /// answer is an addon ignoring the protocol, and declining beats handing the player bytes it
    /// has no key for.
    var isEncrypted: Bool {
        switch encrypted {
        case .bool(let flag)?: return flag
        case .string(let text)?:
            let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed == "true" { return true }
            return !trimmed.isEmpty && trimmed != "false" && trimmed != "none"
        case .number(let number)?: return number != 0
        default: return false
        }
    }

    /// The transport the addon declares, normalised, or nil when the URL is the audio itself (or
    /// nothing was said).
    ///
    /// `format` is consulted last and matters most in practice. A live addon answered a Tidal
    /// Hi-Res track with `{"url": "https://im-fa.manifest.tidal.com/1/manifests/…", "format":
    /// "dash", "quality": "Tidal · Hi-Res FLAC (DASH)"}` — no `manifest`, no codec, no `.mpd`. Safe
    /// because this normalises: `flac`, `mp3`, `mp4` fall through to nil and only the words that
    /// can only mean a transport are honoured.
    var transport: AddonTransport? {
        guard let stated = manifest?.nonBlank ?? mediaType?.nonBlank ?? format.nonBlank else { return nil }
        switch stated.lowercased() {
        case "hls", "m3u8", "application/x-mpegurl", "application/vnd.apple.mpegurl": return .hls
        case "dash", "mpd", "application/dash+xml": return .dash
        default: return nil
        }
    }

    /// From the field when filled in, else from the quality label ("24-bit / 96 kHz"). The live
    /// addon states neither field on a Hi-Res FLAC and puts everything in free text.
    var sampleRateHz: Int? {
        if let sampleRate, sampleRate > 0 {
            // Some publishers state kHz where the field is specified in Hz.
            return sampleRate < 1_000 ? Int(sampleRate * 1_000) : Int(sampleRate)
        }
        guard let label = Self.khzLabel.firstGroup(in: qualityText), let khz = Double(label), khz > 0 else { return nil }
        return Int(exactly: (khz * 1_000).rounded(.towardZero))
    }

    var bits: Int? {
        if let bitDepth, bitDepth > 0 { return Int(bitDepth) }
        guard let label = Self.bitDepthLabel.firstGroup(in: qualityText), let depth = Int(label),
              (8...32).contains(depth) else { return nil }
        return depth
    }

    /// kbps, whichever unit the addon used: a FLAC at `1411` and an MP3 at `320000` are the same
    /// claim. Anything over 3000 is bits per second.
    var kbps: Int? {
        if let bitrate, bitrate > 0 {
            return bitrate > 3_000 ? Int(bitrate / 1_000) : Int(bitrate)
        }
        return Self.kbpsLabel.firstGroup(in: qualityText).flatMap { Int($0) }
    }

    /// Whether the addon says this is the immersive mix.
    var isDolbyAtmos: Bool {
        addonAtmosHint.contains(
            in: "\(qualityText) \(audioMode ?? "") \(audioModes.joined(separator: " ")) \(statedCodec ?? "")"
        )
    }

    private static let kbpsLabel = Pattern(#"(\d{2,4})\s*kbps"#, caseInsensitive: true)
    private static let khzLabel = Pattern(#"([\d.]+)\s*kHz"#, caseInsensitive: true)
    private static let bitDepthLabel = Pattern(#"(\d{1,2})\s*-?\s*bit"#, caseInsensitive: true)
}

/// What an addon's stream URL points at when it is not the audio itself.
public enum AddonTransport: String, Hashable, Sendable {
    case hls
    case dash

    public var mimeType: String {
        switch self {
        case .hls: return "application/x-mpegURL"
        case .dash: return "application/dash+xml"
        }
    }
}
