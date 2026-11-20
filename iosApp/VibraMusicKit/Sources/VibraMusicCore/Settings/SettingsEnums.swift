import Foundation

// Ports the enums and small value types declared in data/settings/AppSettings.kt.
// Raw values are the Android enum names: they are what is persisted and what a backup carries.

/// Streaming ceiling, one per kind of connection (see ``AppSettings/audioQualityWifi`` and
/// ``AppSettings/audioQualityCellular``).
///
/// On the YouTube path Medium, High and Lossless all mean "the best available format"; what tells
/// them apart is which other sources may answer *before* YouTube is asked (``permits(_:)``):
/// - Lossless: the user's addons and JioSaavn both asked.
/// - High: addons skipped, JioSaavn asked.
/// - Medium and Low: both skipped; YouTube alone, capped at ``maxKbps``.
public enum AudioQuality: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case low = "LOW"
    case medium = "MEDIUM"
    case high = "HIGH"
    case lossless = "LOSSLESS"

    public var id: String { rawValue }

    /// The bitrate ceiling on the YouTube path; nil means uncapped.
    public var maxKbps: Int? { self == .low ? 64 : nil }

    public var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .lossless: return "Lossless"
        }
    }

    public var detail: String {
        switch self {
        case .low: return "~64 kbps · smallest download"
        case .medium: return "Best available from YouTube"
        case .high: return "JioSaavn up to 320kbps, YouTube fallback"
        case .lossless: return "Your addons + JioSaavn, bit-exact where available"
        }
    }

    /// What the ceiling costs over an hour of listening: the only part a metered user cares about.
    public var hourly: String {
        switch self {
        case .low: return "29 MB/hr"
        case .medium: return "77 MB/hr"
        case .high: return "144 MB/hr"
        case .lossless: return "300+ MB/hr"
        }
    }

    /// Whether a stream started under this ceiling may be served by `kind`.
    ///
    /// Asked per stream rather than written into the Sources screen's switches: a ceiling is a
    /// property of the connection in force, the switches are the user's standing choice, and storing
    /// the first in the second loses the second (picking a mobile-data rung used to turn sources off
    /// while sitting on Wi-Fi). YouTube is permitted on every rung.
    public func permits(_ kind: SourceKind) -> Bool {
        switch self {
        case .lossless:
            return true
        case .high:
            // No lossless answer is wanted, and a source that can serve one is the slow half of the
            // list: an addon fronting several catalogues walks them all before answering.
            return !kind.canServeLossless
        case .medium, .low:
            return kind == .youtube
        }
    }
}

/// What to keep when a track is saved to the device.
///
/// Deliberately not ``AudioQuality``: that budgets a *stream*, priced per hour because the bytes are
/// spent on every replay. A download is paid for once and kept, so the figure that decides it is
/// per track, and the rung worth defaulting to is the top one.
public enum DownloadQuality: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case standard = "STANDARD"
    case high = "HIGH"
    case lossless = "LOSSLESS"

    public var id: String { rawValue }

    /// Ceiling for the YouTube ladder; nil means whichever rung is best.
    public var maxKbps: Int? { self == .standard ? 128 : nil }

    /// Whether a source's bit-exact file is worth keeping, or a transcode will do.
    public var keepsLossless: Bool { self == .lossless }

    public var label: String {
        switch self {
        case .standard: return "Standard"
        case .high: return "High"
        case .lossless: return "Lossless"
        }
    }

    public var detail: String {
        switch self {
        case .standard: return "~128 kbps AAC · fits more on the device"
        case .high: return "Best audio on offer; source quality first"
        case .lossless: return "Bit-exact if a source has it, best AAC if not"
        }
    }

    /// Roughly what one four-minute track costs at this rung.
    public var perTrack: String {
        switch self {
        case .standard: return "~4 MB"
        case .high: return "~8 MB"
        case .lossless: return "~35 MB"
        }
    }
}

public enum ThemeMode: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case system = "SYSTEM"
    case light = "LIGHT"
    case dark = "DARK"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// Which of the equaliser's two tabs drives the sound. One at a time: they are two descriptions of
/// the same curve, and summing them would let a centred tone pad still alter what the sliders said.
public enum EqualizerMode: String, Codable, Hashable, Sendable, CaseIterable {
    /// The tone pad: tilt, contour, and how wide each is.
    case dynamic = "DYNAMIC"
    /// Seven sliders and a preset list.
    case manual = "MANUAL"
}

/// When a track starts on a ranked source (an add-on) rather than on YouTube with the quality
/// upgrade following (the "Direct source stream" setting).
public enum DirectSourceStream: String, Codable, Hashable, Sendable, CaseIterable {
    /// YouTube starts every track at once; the upgrade swaps a better copy in.
    case off = "OFF"
    /// Read-ahead asks the ranked sources for the tracks ahead, and a track it found a copy for
    /// starts on that copy. Any other track (a search result, an album, a link) starts on YouTube.
    case queueOnly = "QUEUE_ONLY"
    /// Every track waits for the ranked sources, up to ``StreamRequest/waitsForSources``'s cap.
    case always = "ALWAYS"
}

/// CPU budget for Automix's background analysis (not its audible mix algorithm).
public enum AutomixPerformanceMode: String, Codable, Hashable, Sendable, CaseIterable {
    case efficient = "EFFICIENT"
    case balanced = "BALANCED"
    case performance = "PERFORMANCE"

    public var inferenceThreads: Int {
        switch self {
        case .efficient: return 1
        case .balanced: return 2
        case .performance: return 4
        }
    }
}

/// Ordering for the Downloads and imported-music libraries.
public enum LocalMusicSort: String, Codable, Hashable, Sendable, CaseIterable {
    case titleAsc = "TITLE_ASC"
    case titleDesc = "TITLE_DESC"
    case dateAdded = "DATE_ADDED"
    case dateModified = "DATE_MODIFIED"
}

/// Ordering for a Library "Show all" grid (playlists or albums). A card only carries a title, so
/// there is nothing date-based to offer.
public enum LibrarySort: String, Codable, Hashable, Sendable, CaseIterable {
    /// The order the shelf arrived in: YouTube Music's own.
    case `default` = "DEFAULT"
    case titleAsc = "TITLE_ASC"
    case titleDesc = "TITLE_DESC"
}

/// Ordering for the track list on an album or playlist page. A playlist's running order is the
/// order songs were added in (YouTube appends each addition), so read backwards it *is* a date
/// order, newest first.
public enum SongSort: String, Codable, Hashable, Sendable, CaseIterable {
    case `default` = "DEFAULT"
    case titleAsc = "TITLE_ASC"
    case titleDesc = "TITLE_DESC"
    case dateAddedAsc = "DATE_ADDED_ASC"
    case dateAddedDesc = "DATE_ADDED_DESC"
}

/// Display mode for music lists: compact rows or grid cards.
public enum LibraryViewType: String, Codable, Hashable, Sendable, CaseIterable {
    case list = "LIST"
    case grid = "GRID"
}

/// The surface that was last open inside the expanded player.
public enum LastPlayerScreen: String, Codable, Hashable, Sendable, CaseIterable {
    case main = "MAIN"
    case lyrics = "LYRICS"
    case queue = "QUEUE"
}

/// Off, all or one. Raw values are Media3's `REPEAT_MODE_*` ints, which is what Android persists
/// under `repeat_mode`.
public enum RepeatMode: Int, Codable, Hashable, Sendable, CaseIterable {
    case off = 0
    case one = 1
    case all = 2
}

/// Where one track stands in Automix's analysis.
///
/// The no-result states are kept apart because they call for different reactions: `waiting`
/// resolves once bytes arrive, `analysing` in a few seconds, `failed` never.
public enum TrackAnalysisState: String, Codable, Hashable, Sendable, CaseIterable {
    /// Nothing in flight and no result, usually waiting on bytes.
    case waiting = "WAITING"
    /// Decode and inference running now.
    case analysing = "ANALYSING"
    /// Measured, with a tempo the planner can use.
    case analysed = "ANALYSED"
    /// Measured off the track's opening, with the whole-track pass running to replace the numbers.
    case refining = "REFINING"
    /// Tried and came back with nothing usable; nothing further will happen on its own.
    case failed = "FAILED"
}

/// Both sides of the next transition, for stats for nerds. A transition needs *both* tracks
/// measured before it can beat-match, so reporting them separately explains a plain crossfade.
public struct SmartAnalysis: Codable, Hashable, Sendable {
    public var current: TrackAnalysisState
    public var next: TrackAnalysisState

    public init(current: TrackAnalysisState = .waiting, next: TrackAnalysisState = .waiting) {
        self.current = current
        self.next = next
    }
}

/// A span of the playing track, in fractions of its duration, that the next transition is planned
/// to occupy.
public struct TransitionWindow: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}
