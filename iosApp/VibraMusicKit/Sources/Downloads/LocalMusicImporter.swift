import CryptoKit
import Foundation
import VibraMusicCore

// The iOS replacement for data/LocalMediaRepository.kt (PORTING.md Q8 and §4 "MediaStore local
// music"): no device-wide scan, but files the user picks in Files are copied into the app container
// and join the same library as downloads.

/// Which audio files count as music (Android `LocalMediaRepository.isEligibleLocalMusic` and
/// `isAudioFileName`).
public enum LocalMediaFilter {
    /// Anything shorter is a notification sound, a ringtone or a voice note far more often than a
    /// song.
    public static let minimumMusicMillis: Int64 = 30_000

    /// Extensions a folder import takes as music: Android's list less the containers AVPlayer can't
    /// play (Ogg, Opus, WebM). WAV is left out as on Android — in a folder it is almost always a
    /// recording — but a WAV picked on its own is imported (see ``playableExtensions``).
    public static let musicExtensions: Set<String> = ["mp3", "m4a", "flac", "aac"]

    /// Everything AVFoundation plays that a user might pick one file at a time.
    public static let playableExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "mp4", "aac", "flac", "wav", "aif", "aiff", "aifc", "caf",
    ]

    /// Folders whose audio is not music. Android's list, plus the Voice Memos export folder name.
    static let nonMusicPathSegments = [
        "/alarms/", "/notifications/", "/ringtones/", "/podcasts/", "/audiobooks/", "/recordings/",
        "/voice recorder/", "/sound_recorder/", "/call_rec/", "/whatsapp voice notes/", "/voice memos/",
    ]

    /// Whether a file found while importing a folder is music: long enough, a music extension, and
    /// not under a folder of recordings or ringtones. The check leans on the path and the duration
    /// rather than on tags, so the same bad files stay out whatever wrote them.
    public static func isEligibleLocalMusic(durationMs: Int64, displayName: String, path: String?) -> Bool {
        guard durationMs >= minimumMusicMillis else { return false }
        let fileName = path.flatMap { path -> String? in
            let last = (path as NSString).lastPathComponent
            return last.isBlank ? nil : last
        } ?? displayName
        guard musicExtensions.contains((fileName as NSString).pathExtension.lowercased()) else { return false }
        guard let path else { return true }
        let normalized = path.replacingOccurrences(of: "\\", with: "/").lowercased()
        return !nonMusicPathSegments.contains { normalized.contains($0) }
    }

    /// Whether a picked file is one AVFoundation can play, by extension.
    public static func isPlayableAudioFileName(_ name: String) -> Bool {
        playableExtensions.contains((name as NSString).pathExtension.lowercased())
    }
}

/// What an import did with each picked item.
public struct LocalImportResult: Sendable {
    public struct Skipped: Hashable, Sendable {
        public var name: String
        public var reason: String
    }

    /// Tracks added to the library, as the library will list them.
    public var imported: [Song] = []
    /// Files left out, and why ("Already in your library", "Can't be played on this device", …).
    public var skipped: [Skipped] = []
}

/// Copies audio files picked in Files into the app container and records them in the
/// ``DownloadLibrary``, filled from their own tags.
///
/// Why copy rather than bookmark: a security-scoped bookmark into iCloud Drive or a third-party
/// provider may not be readable at play time (offline, evicted, provider not running), and a library
/// row that sometimes can't play is worse than one that costs the space. Imported files live under
/// `Imported/`, which *is* backed up — unlike downloads they can't be fetched again.
///
/// Use with SwiftUI's `.fileImporter(allowedContentTypes: [.audio, .folder], allowsMultipleSelection:
/// true)` and pass the URLs straight in; security-scoped access is handled here.
@MainActor
public final class LocalMusicImporter {
    public let library: DownloadLibrary

    public init(library: DownloadLibrary) {
        self.library = library
    }

    /// The id an imported track is filed under. Opaque and stable: the file's name or place in the
    /// container can change without the row (or anything keyed by it, like play counts) changing.
    public nonisolated static let idPrefix = "local:import:"

    /// Whether `videoId` names an imported file rather than a YouTube track.
    public nonisolated static func isImportedID(_ videoId: String) -> Bool { videoId.hasPrefix(idPrefix) }

    /// Imports every picked file, and every music file inside a picked folder.
    ///
    /// Files picked one by one are taken as the user's decision: any playable format, any length.
    /// Files found by walking a folder go through ``LocalMediaFilter/isEligibleLocalMusic`` first,
    /// the same gate Android put on MediaStore rows, because a folder is where voice notes and
    /// ringtones hide.
    public func importItems(at urls: [URL]) async -> LocalImportResult {
        var result = LocalImportResult()
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) else {
                result.skipped.append(.init(name: url.lastPathComponent, reason: "Couldn't be opened"))
                continue
            }
            if isDirectory.boolValue {
                for file in Self.audioFiles(in: url) {
                    await importFile(file, fromFolder: true, into: &result)
                }
            } else {
                await importFile(url, fromFolder: false, into: &result)
            }
        }
        return result
    }

    private static func audioFiles(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where LocalMediaFilter.isPlayableAudioFileName(url.lastPathComponent) {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { files.append(url) }
        }
        return files.sorted { $0.path(percentEncoded: false) < $1.path(percentEncoded: false) }
    }

    private func importFile(_ source: URL, fromFolder: Bool, into result: inout LocalImportResult) async {
        let name = source.lastPathComponent
        guard LocalMediaFilter.isPlayableAudioFileName(name) else {
            if !fromFolder { result.skipped.append(.init(name: name, reason: "Can't be played on this device")) }
            return
        }
        let size = DownloadStore.fileSize(source)
        guard size > 0 else {
            result.skipped.append(.init(name: name, reason: "The file is empty"))
            return
        }
        let fingerprint = await Task.detached { Self.fingerprint(of: source) }.value
        if let fingerprint, let existing = library.importedRecord(where: { $0.videoId == Self.idPrefix + fingerprint }),
           library.store.exists(relativePath: existing.path) {
            result.skipped.append(.init(name: name, reason: "Already in your library"))
            return
        }

        let tags = await EmbeddedTags.read(from: source)
        guard tags.isPlayable else {
            result.skipped.append(.init(name: name, reason: "Can't be played on this device"))
            return
        }
        let durationMs = Int64((tags.durationSeconds ?? 0) * 1_000)
        if fromFolder, !LocalMediaFilter.isEligibleLocalMusic(durationMs: durationMs, displayName: name, path: source.path(percentEncoded: false)) {
            return
        }

        let store = library.store
        let destination: URL
        do {
            destination = try store.importDestination(for: name)
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            DebugLog.w("Downloads", "could not import \(name)", error: error)
            result.skipped.append(.init(name: name, reason: "Couldn't be copied"))
            return
        }
        guard let path = store.relativePath(of: destination) else { return }

        var artworkPath: String?
        if let artwork = tags.artwork, let fingerprint {
            let tagger = MediaTagger(store: store, http: .shared)
            let cover = MediaTagger.normalizedCover(artwork).map { DownloadArtwork(data: $0, mime: "image/jpeg") }
            artworkPath = tagger.persistArtwork(sourceUrl: "import:\(fingerprint)", artwork: cover)
        }

        let id = Self.idPrefix + (fingerprint ?? UUID().uuidString)
        let stem = (name as NSString).deletingPathExtension
        let record = SavedTrackRecord(
            videoId: id,
            title: tags.title ?? (stem.isBlank ? name : stem),
            artist: tags.artist ?? "Unknown Artist",
            artworkPath: artworkPath,
            durationText: tags.durationSeconds.map { DurationText.format(seconds: Int($0)) },
            albumName: tags.album,
            path: path,
            dateAddedSeconds: Int64(Date().timeIntervalSince1970),
            origin: .imported
        )
        library.rememberImported(record)
        if let song = library.song(for: id) {
            result.imported.append(song)
        }
    }

    /// A content hash, so importing the same file twice (from two folders, or twice from one) is
    /// noticed. SHA-256 of the whole file, streamed; nil if it can't be read.
    nonisolated static func fingerprint(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
