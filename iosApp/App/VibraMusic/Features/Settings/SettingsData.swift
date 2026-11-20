import AudioCache
import VibraMusicCore
import Foundation
import Replay
import SwiftUI
import UniformTypeIdentifiers

// The Storage and Your data rows of ui/screens/SettingsSheet.kt, and data/stats/Backup.kt's
// exportTo/importFrom as the screen used them.

// MARK: - Storage

/// The song cache limit slider (SettingsSheet.kt `SliderRow` over `audioCacheLimitBytes`).
///
/// 512 MB to 10 GB in 20 positions (Android's `steps = 18`), so each notch is 512 MB.
enum SongCacheLimit {
    static let bytesPerMB: Int64 = 1_024 * 1_024
    static var minMB: Int { Int(AppSettings.defaultAudioCacheLimitBytes / bytesPerMB) }
    static var maxMB: Int { Int(AppSettings.maxAudioCacheLimitBytes / bytesPerMB) }
    /// Android's slider has 18 steps between its ends: 20 positions.
    static var stepMB: Int { (maxMB - minMB) / 19 }
    /// Above this the subtitle warns rather than reassures (Android `CACHE_WARNING_MB`).
    static let warningMB = 2_048

    static func megabytes(ofBytes bytes: Int64) -> Int { Int(bytes / bytesPerMB) }

    static func bytes(ofMegabytes mb: Int) -> Int64 {
        Int64(min(max(mb, minMB), maxMB)) * bytesPerMB
    }

    /// "512 MB", "2 GB", "2.5 GB" — whichever reads more naturally at that size.
    static func format(megabytes mb: Int) -> String {
        if mb < 1_024 { return "\(mb) MB" }
        let gb = Double(mb) / 1_024
        if gb == gb.rounded() { return "\(Int(gb)) GB" }
        return String(format: "%.1f GB", locale: Locale(identifier: "en_US_POSIX"), gb)
    }

    /// The row's subtitle: a warning once the limit is large enough to crowd a phone.
    static func subtitle(megabytes mb: Int) -> String {
        mb > warningMB ? L10n.songCacheLargeSubtitle(format(megabytes: mb)) : L10n.songCacheLimitSubtitle
    }
}

/// The two "Clear … cache" rows (Android: `AudioCache.clear`, Coil's memory and disk caches).
enum SettingsStorage {
    /// Empties the song cache. Returns the bytes freed, which is what the cache reported holding.
    @discardableResult
    static func clearSongCache(_ cache: AudioStreamCache?) async -> Int64 {
        await cache?.clear() ?? 0
    }

    /// Empties the artwork caches off the main thread: the disk half lists and deletes every file,
    /// which with a full cache is thousands of file-system calls, and the row was running it on
    /// the main thread inside the tap.
    @discardableResult
    static func clearImageCache(_ cache: ArtworkImageCache) async -> Int64 {
        await Task.detached(priority: .userInitiated) { cache.clear() }.value
    }
}

// MARK: - Backup

/// The JSON document handed to `.fileExporter` / read back from `.fileImporter`.
///
/// Both halves go through the system document picker rather than a path of the app's choosing
/// (Android: CreateDocument / OpenDocument), which puts the file somewhere the user can find it.
struct SettingsBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .plainText, .data] }
    static var writableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Export and import of settings and listening history (data/stats/Backup.kt), without the
/// credentials (`AppSettings.exportPrefs` never includes them).
@MainActor
struct SettingsBackup {
    let settings: AppSettings
    let stats: ReplayListeningStats
    let searchHistory: SearchHistory
    var versionName: String = SettingsBackup.appVersion

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    /// The file's bytes, and how many months of listening it carries.
    func export() throws -> (data: Data, months: Int) {
        let listening = stats.exportAll()
        let data = try ReplayBackup.encode(versionName: versionName, settings: settings.exportPrefs(), listening: listening)
        return (data, listening.count)
    }

    /// Replaces this device's history and settings with the file's. Validated whole before anything
    /// is touched: a refused file changes nothing.
    @discardableResult
    func restore(from data: Data) throws -> ReplayBackupFile.Summary {
        let file = try ReplayBackup.decode(data)
        try stats.importAll(file.listening)
        settings.importPrefs(file.settings)
        searchHistory.reload()
        return file.summary
    }

    // MARK: What the rows say afterwards

    /// "3 months of listening" — the unit a backup is actually measured in.
    static func countOfMonths(_ months: Int) -> String {
        months == 0 ? L10n.noListeningHistory : L10n.listeningMonthCount(months)
    }

    static func exportStatus(_ result: Result<Int, Error>) -> String {
        switch result {
        case .success(let months): return L10n.exportSucceeded(countOfMonths(months))
        case .failure(let error): return L10n.exportFailed(message(of: error))
        }
    }

    static func importStatus(_ result: Result<ReplayBackupFile.Summary, Error>) -> String {
        switch result {
        case .success(let summary): return L10n.importSucceeded(countOfMonths(summary.months), summary.from)
        case .failure(let error): return L10n.importFailed(message(of: error))
        }
    }

    /// Backup.kt's reasons, which Android never localised either (they are `error()` messages).
    private static func message(of error: Error) -> String {
        if let backup = error as? ReplayBackupError {
            switch backup {
            case .notAVibraMusicBackup: return "That doesn't look like a Vibra Music backup"
            case .foreignBackup: return "That backup is from another app"
            case .newerSchema: return "That backup was written by a newer version of Vibra Music"
            }
        }
        let text = error.localizedDescription
        return text.isEmpty ? L10n.unknownError : text
    }
}
