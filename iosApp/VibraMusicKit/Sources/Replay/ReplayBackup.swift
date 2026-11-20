import Foundation
import VibraMusicCore

// Ports data/stats/Backup.kt: the whole of what the app knows about you, as one JSON file you own.
//
// Every preference except credentials (see `AppSettings.exportPrefs`), and every month of
// listening. Not the audio cache, the downloads or the artwork: those are megabytes that
// re-fetch themselves, and a backup that is mostly cache is one nobody keeps.
//
// The file format is Android's, field for field — `app`, `version`, `versionName`, `exportedAt`,
// `settings` (`{"type":"bool","value":"true"}`, numbers as strings), `listening` (stored buckets)
// — so a file exported on Android restores on iOS and vice versa. Preference values ride as
// Core's `SettingValue`, which encodes exactly like Android's `Backup.PrefValue`.
//
// This module stays storage-agnostic: it encodes/decodes/validates the file, and the app moves the
// bytes (`.fileExporter`/`.fileImporter` in SwiftUI — the iOS equivalent of Android's Storage
// Access Framework picker) and applies the contents (`ReplayListeningStats.importAll`,
// `AppSettings.importPrefs`, then `SearchHistory.reload()`).

/// A backup file that failed validation, and why.
public enum ReplayBackupError: Error, Hashable, Sendable {
    /// Not JSON, or not the shape of a backup at all. A half-applied import is worse than a
    /// refused one — it leaves settings from two devices mixed together with nothing to say which
    /// came from where — so anything that isn't one of ours is refused whole.
    case notAVibra MusicBackup
    /// From another app (`app` tag mismatch). The offending tag rides along for the error line.
    case foreignBackup(app: String)
    /// Written by a newer Vibra Music whose schema this build can't read. Refused rather than
    /// partially read; a file from an *older* schema reads as-is, since every field has a default.
    case newerSchema(version: Int)
}

/// One Vibra Music backup file.
public struct ReplayBackupFile: Hashable, Sendable {
    public var versionName: String
    public var exportedAt: String
    public var settings: [String: SettingValue]
    public var listening: [ReplayStoredBucket]

    public init(
        versionName: String = "", exportedAt: String = "",
        settings: [String: SettingValue] = [:], listening: [ReplayStoredBucket] = []
    ) {
        self.versionName = versionName
        self.exportedAt = exportedAt
        self.settings = settings
        self.listening = listening
    }

    /// What an import turned out to contain, for the line shown afterwards.
    public struct Summary: Hashable, Sendable {
        public var months: Int
        public var settings: Int
        public var from: String
        public var at: String

        public init(months: Int, settings: Int, from: String, at: String) {
            self.months = months
            self.settings = settings
            self.from = from
            self.at = at
        }
    }

    public var summary: Summary {
        Summary(months: listening.count, settings: settings.count, from: versionName, at: exportedAt)
    }
}

public enum ReplayBackup {
    public static let appTag = "vibramusic"
    /// Bump when the shape below stops being readable by an older build.
    public static let schemaVersion = 1

    private struct Stored: Codable {
        var app: String = appTag
        var version: Int = schemaVersion
        var versionName: String = ""
        var exportedAt: String = ""
        var settings: [String: SettingValue] = [:]
        var listening: [ReplayStoredBucket] = []

        init(app: String = appTag, version: Int = schemaVersion, versionName: String = "",
             exportedAt: String = "", settings: [String: SettingValue] = [:],
             listening: [ReplayStoredBucket] = []) {
            self.app = app
            self.version = version
            self.versionName = versionName
            self.exportedAt = exportedAt
            self.settings = settings
            self.listening = listening
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            app = try c.decodeIfPresent(String.self, forKey: .app) ?? appTag
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? schemaVersion
            versionName = try c.decodeIfPresent(String.self, forKey: .versionName) ?? ""
            exportedAt = try c.decodeIfPresent(String.self, forKey: .exportedAt) ?? ""
            settings = try c.decodeIfPresent([String: SettingValue].self, forKey: .settings) ?? [:]
            listening = try c.decodeIfPresent([ReplayStoredBucket].self, forKey: .listening) ?? []
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// Encodes a backup: `settings` from `AppSettings.exportPrefs()`, `listening` from
    /// `ReplayListeningStats.exportAll()`. Credentials are excluded by construction — they live in
    /// the Keychain, never in the exported prefs.
    public static func encode(versionName: String, exportedAt: String = ISO8601DateFormatter().string(from: Date()), settings: [String: SettingValue], listening: [ReplayStoredBucket]) throws -> Data {
        let stored = Stored()
        var mutable = stored
        mutable.versionName = versionName
        mutable.exportedAt = exportedAt
        mutable.settings = settings
        mutable.listening = listening
        return try encoder().encode(mutable)
    }

    /// Decodes and validates a backup file. Throws `ReplayBackupError` for anything that isn't one
    /// of ours, is from another app, or is from a newer schema.
    public static func decode(_ data: Data) throws -> ReplayBackupFile {
        let stored: Stored
        do {
            stored = try JSONDecoder().decode(Stored.self, from: data)
        } catch {
            throw ReplayBackupError.notAVibra MusicBackup
        }
        guard stored.app == appTag else {
            throw ReplayBackupError.foreignBackup(app: stored.app)
        }
        guard stored.version <= schemaVersion else {
            throw ReplayBackupError.newerSchema(version: stored.version)
        }
        // `Stored` with all defaults and no content is indistinguishable from `{}`: refuse it, so
        // an empty object doesn't wipe the device on import.
        if stored.versionName.isEmpty && stored.exportedAt.isEmpty && stored.settings.isEmpty && stored.listening.isEmpty {
            // A genuinely empty backup (no settings, no listening) still carries its provenance.
            // Only refuse when there is truly nothing — which, with defaults, we cannot tell from
            // `{}`. Android has the same shape; an export always stamps versionName/exportedAt, so
            // require at least one of them.
            throw ReplayBackupError.notAVibra MusicBackup
        }
        return ReplayBackupFile(
            versionName: stored.versionName, exportedAt: stored.exportedAt,
            settings: stored.settings, listening: stored.listening
        )
    }

    /// A suggested filename, dated so successive exports don't collide.
    public static func suggestedName(on date: Date = Date(), calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "vibramusic-backup-%04d-%02d-%02d.json",
                      components.year ?? 2000, components.month ?? 1, components.day ?? 1)
    }
}
