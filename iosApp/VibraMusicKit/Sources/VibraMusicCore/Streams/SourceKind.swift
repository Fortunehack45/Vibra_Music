import Foundation

// Ports data/sources/SourceKind.kt. Lives in Core because AudioQuality.permits(_:) and
// StreamRequest are phrased in terms of it, and Playback, Downloads, Sources and the settings UI
// all need the same list.

/// The kinds of source this build knows how to talk to.
///
/// Fixed and small on purpose. ``rank`` is the order sources are tried: the sources a user added
/// come first, then the legacy built-in module kind, then JioSaavn, then YouTube Music. What varies
/// per *instance* (which server, whose module) is the Sources module's config, not this.
///
/// Raw values are the Android names, so stored source configs and backups match.
public enum SourceKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// An addon server the user pointed at: a plain HTTP server (`/manifest.json`, `/search`,
    /// `/stream`, JSON both ways). Nothing is downloaded or run on the device.
    case addon = "ADDON"
    /// A module index the user pointed at. Legacy (PORTING Q4): no longer offered; kept so an
    /// existing config still decodes.
    case customModule = "CUSTOM_MODULE"
    /// A built-in module index. Legacy, never created any more; kept so stored configs decode.
    case module = "MODULE"
    /// Optional JioSaavn streams up to 320 kbps AAC.
    case jioSaavn = "JIOSAAVN"
    /// YouTube Music: the full catalogue, the only source of feeds, radio and related tracks.
    case youtube = "YOUTUBE"

    /// The shared rank of every source the user added. Their order among themselves is the stored
    /// list order, which a drag rewrites.
    public static let userAddedRank = 0

    public var label: String {
        switch self {
        case .addon: return "Addon"
        case .customModule: return "Custom module"
        case .module: return "Module source"
        case .jioSaavn: return "JioSaavn"
        case .youtube: return "YouTube Music"
        }
    }

    public var detail: String {
        switch self {
        case .addon:
            return "An addon server you host or were given a link to. Searched and streamed over "
                + "plain HTTP — no code is downloaded or run."
        case .customModule:
            return "Your own compatible module index. Tried before the built-in one."
        case .module:
            return "A URL to a compatible module index. Modules are JS plugins that can search and "
                + "stream from services like Tidal, Qobuz, Apple Music and more."
        case .jioSaavn:
            return "Optional JioSaavn streams up to 320kbps AAC/MP4. Catalogue matching can select the wrong song."
        case .youtube:
            return "The full catalogue, in AAC. Lossy — there is no lossless rendition to ask for."
        }
    }

    /// The chips under the name on the Sources screen.
    public var labels: [String] {
        switch self {
        case .addon: return ["FLAC", "Lossless", "Hi-Res"]
        case .customModule, .module: return ["FLAC", "Lossless", "Hi-Res", "Plugins"]
        case .jioSaavn: return ["High Quality", "320kbps"]
        case .youtube: return ["Lossy", "Full catalogue", "Radio"]
        }
    }

    /// Whether an instance needs a URL before it can do anything (and so needs an editor).
    public var needsServer: Bool {
        switch self {
        case .addon, .customModule, .module: return true
        case .jioSaavn, .youtube: return false
        }
    }

    /// Whether this kind can serve bit-exact audio when asked.
    public var canServeLossless: Bool {
        switch self {
        case .addon, .customModule, .module: return true
        case .jioSaavn, .youtube: return false
        }
    }

    /// Whether this kind answers fast enough to be worth asking *before* a track plays, so its copy
    /// can be pinned and cached ahead of time. JioSaavn answers in about 0.4 s; a module index takes
    /// 7–13 s. YouTube is false too: it is warmed through the audio cache's own read-ahead.
    public var worthPrefetching: Bool { self == .jioSaavn }

    /// Where this kind sits in the walk, low first. Addons and custom modules share
    /// ``userAddedRank`` so their relative order is the user's drag order, not the enum order.
    public var rank: Int {
        switch self {
        case .addon, .customModule: return Self.userAddedRank
        case .module: return 1
        case .jioSaavn: return 2
        case .youtube: return 3
        }
    }

    /// Whether this is a source the user configured, rather than one that ships.
    public var isUserAdded: Bool { rank == Self.userAddedRank }
}
