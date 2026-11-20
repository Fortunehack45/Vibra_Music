import Foundation
import VibraMusicCore

// Ports download/DownloadStore.kt.

/// Where downloaded and imported files live, what they are called, and how a file gets there
/// without a half-written copy ever looking like a whole one.
///
/// **iOS difference.** Android writes into the shared `Music/Vibra Music` folder through MediaStore so
/// other players can see the files. iOS has no shared Music folder (PORTING.md §3, Q9), so
/// everything lives in the app container under ``root`` (by default
/// `Application Support/Vibra Music/Downloads`):
///
/// - `Tracks/` — finished downloads, `Artist - Title.ext`, plus hidden `.name.part` files being
///   written. Excluded from iCloud/iTunes backup: every one can be downloaded again, and a backup of
///   a lossless library is gigabytes the user never asked to upload.
/// - `Imported/` — copies of files picked in Files (PORTING.md Q8). *Not* excluded from backup: the
///   user may have deleted the original, and these can't be fetched again.
/// - `Artwork/` — covers saved beside the audio (sidecars keyed by source URL), so the Downloads
///   page draws them offline. Excluded from backup.
/// - `Staging/` — bytes the transfer session has finished but the queue hasn't appended yet
///   (``URLSessionDownloadTransport``). Excluded from backup.
/// - `library.json`, `queue.json` — the records (``DownloadLibrary``, ``DownloadManager``).
///
/// Paths are recorded relative to ``root`` because the container's absolute path changes across app
/// updates and device restores; an absolute `file://` URL saved today names nothing next month.
public struct DownloadStore: Sendable {
    public let root: URL

    /// `root` is used as given (tests pass a temporary directory).
    public init(root: URL) {
        self.root = root
    }

    /// The app's store: `Application Support/Vibra Music/Downloads`.
    public static func applicationSupport() -> DownloadStore {
        DownloadStore(root: URL.applicationSupportDirectory
            .appending(path: "Vibra Music", directoryHint: .isDirectory)
            .appending(path: "Downloads", directoryHint: .isDirectory))
    }

    public static let tracksFolder = "Tracks"
    public static let importedFolder = "Imported"
    public static let artworkFolder = "Artwork"
    public static let stagingFolder = "Staging"

    public var tracksDirectory: URL { directory(Self.tracksFolder) }
    public var importedDirectory: URL { directory(Self.importedFolder) }
    public var artworkDirectory: URL { directory(Self.artworkFolder) }
    public var stagingDirectory: URL { directory(Self.stagingFolder) }

    /// The JSON records next to the files.
    var records: JSONFileStore { JSONFileStore(directory: root) }

    private func directory(_ name: String) -> URL {
        root.appending(path: name, directoryHint: .isDirectory)
    }

    /// Creates the folders and marks the re-fetchable ones as excluded from backup. Idempotent.
    public func prepare() throws {
        let fileManager = FileManager.default
        for (name, excluded) in [(Self.tracksFolder, true), (Self.importedFolder, false),
                                 (Self.artworkFolder, true), (Self.stagingFolder, true)] {
            var url = directory(name)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = excluded
            try? url.setResourceValues(values)
        }
    }

    // MARK: Paths

    /// The absolute URL of a path recorded relative to ``root``.
    public func url(forRelativePath path: String) -> URL {
        root.appending(path: path, directoryHint: .notDirectory)
    }

    /// `url` relative to ``root``, or nil when it lies outside it.
    public func relativePath(of url: URL) -> String? {
        let base = root.standardizedFileURL.path(percentEncoded: false)
        let full = url.standardizedFileURL.path(percentEncoded: false)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard full.hasPrefix(prefix) else { return nil }
        return String(full.dropFirst(prefix.count))
    }

    // MARK: Naming

    /// What the file is called: `Artist - Title.ext`.
    ///
    /// Artist first because a folder listing is sorted by name and nothing else, so leading with the
    /// artist is what puts an album back together in Files (and in a share sheet, where these names
    /// surface).
    public static func fileName(for song: Song, extension ext: String) -> String {
        let artist = sanitise(song.artist)
        let title = sanitise(song.title)
        var stem: String
        if artist.isEmpty {
            stem = title
        } else if title.isEmpty {
            stem = artist
        } else {
            stem = "\(artist) - \(title)"
        }
        if stem.isEmpty { stem = song.videoId }
        let trimmed = String(stem.prefix(maxStemCharacters)).trimmingTrailingWhitespace()
        return "\(trimmed).\(ext)"
    }

    /// Everything a filesystem, a shell or a share target would each object to for its own reasons,
    /// plus the whitespace that survives them.
    static func sanitise(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: #"[\\/:*?"<>|\x00-\x1F]"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespaces)
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    /// Long enough for anything real, short of the 255-byte filename ceiling.
    static let maxStemCharacters = 120

    /// What a file of some codec is called and what it is declared as.
    public struct Storable: Hashable, Sendable {
        public let fileExtension: String
        public let mimeType: String
    }

    /// How to file a track of `codec`, or nil if this device won't keep one.
    ///
    /// Kept as a table rather than derived from the codec string because some are not the identity
    /// mapping they look like: ALAC and Dolby Atmos (E-AC-3 JOC) ship inside an MP4 container, so
    /// such a file is an `.m4a` as far as both the player and ``Mp4Tagger`` are concerned. Opus and
    /// WebM are absent on purpose: AVPlayer can't play them (PORTING.md §4).
    public static func storable(_ codec: String?) -> Storable? {
        switch codec?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "flac", "x-flac": return Storable(fileExtension: "flac", mimeType: "audio/flac")
        case "wav", "x-wav", "wave": return Storable(fileExtension: "wav", mimeType: "audio/x-wav")
        case "alac", "m4a", "mp4", "eac3-joc", "ec3-joc", "dolby-atmos": return Storable(fileExtension: "m4a", mimeType: "audio/mp4")
        default: return nil
        }
    }

    // MARK: Lookup

    /// The file already saved under this name in `Tracks/`, or nil. Asked before every download so a
    /// second tap adopts the first copy rather than writing another beside it.
    public func existing(name: String) -> URL? {
        let url = tracksDirectory.appending(path: name, directoryHint: .notDirectory)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    /// Whether a recorded relative path still names a file. The record is this app's, but a
    /// restore, a storage purge or a crash mid-delete can leave it claiming a file that isn't there.
    public func exists(relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url(forRelativePath: relativePath).path(percentEncoded: false))
    }

    /// Bytes on disk for a recorded path, or 0 when it is gone.
    public func size(relativePath: String) -> Int64 {
        Self.fileSize(url(forRelativePath: relativePath))
    }

    static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func modificationMillis(_ url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        guard let date = attributes?[.modificationDate] as? Date else { return nil }
        let millis = Int64(date.timeIntervalSince1970 * 1_000)
        return millis > 0 ? millis : nil
    }

    /// Deletes a recorded file and returns how many bytes that freed (0 when it was already gone).
    @discardableResult
    public func delete(relativePath: String) -> Int64 {
        let url = url(forRelativePath: relativePath)
        let bytes = Self.fileSize(url)
        do {
            try FileManager.default.removeItem(at: url)
            return bytes
        } catch {
            if (error as? CocoaError)?.code != .fileNoSuchFile {
                DebugLog.w("Downloads", "could not delete \(relativePath)", error: error)
            }
            return 0
        }
    }

    // MARK: Writing

    /// A destination that exists but is not yet a file anyone else can see.
    ///
    /// Every path out of here is either ``commit()`` or ``abort()``; there is no third option,
    /// because the thing being protected against is a partial file surviving a failure and looking
    /// like a whole one. The bytes build up in a hidden `.name.part` beside the final name, and the
    /// commit is a rename within one volume.
    public struct Pending: Sendable {
        public let name: String
        /// The bytes being built.
        public let partURL: URL
        /// What ``partURL`` becomes.
        public let targetURL: URL

        /// Renames the part file into place and returns the finished file's URL.
        public func commit() throws -> URL {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: targetURL.path(percentEncoded: false)) {
                try fileManager.removeItem(at: targetURL)
            }
            do {
                try fileManager.moveItem(at: partURL, to: targetURL)
            } catch {
                throw DownloadError("Could not finish writing \(name)")
            }
            return targetURL
        }

        public func abort() {
            try? FileManager.default.removeItem(at: partURL)
        }

        /// How many bytes the part file holds.
        public var partSize: Int64 { DownloadStore.fileSize(partURL) }
    }

    /// The hidden file a download of `name` is written into. `token` tells two jobs for the same
    /// name apart, so a cancelled job cleaning up can't delete the file its replacement just began.
    public static func partName(for name: String, token: String = "") -> String {
        token.isEmpty ? ".\(name).part" : ".\(name).\(token).part"
    }

    /// Reserve `name` in `Tracks/` and return somewhere to write it.
    ///
    /// - Parameter resumeAt: bytes of an earlier attempt to keep (a download resumed after a
    ///   relaunch). The part file is truncated to exactly that, so a chunk that half-landed before
    ///   the app was killed can't leave a splice behind. Nil starts from nothing.
    public func begin(name: String, token: String = "", resumeAt: Int64? = nil) throws -> Pending {
        try prepare()
        let target = tracksDirectory.appending(path: name, directoryHint: .notDirectory)
        let part = tracksDirectory.appending(path: Self.partName(for: name, token: token), directoryHint: .notDirectory)
        let fileManager = FileManager.default
        let keep = resumeAt ?? 0
        if keep > 0, fileManager.fileExists(atPath: part.path(percentEncoded: false)), Self.fileSize(part) >= keep {
            let handle = try FileHandle(forWritingTo: part)
            try handle.truncate(atOffset: UInt64(keep))
            try handle.close()
        } else {
            try? fileManager.removeItem(at: part)
            guard fileManager.createFile(atPath: part.path(percentEncoded: false), contents: nil) else {
                throw DownloadError("Could not create \(name)")
            }
        }
        return Pending(name: name, partURL: part, targetURL: target)
    }

    /// A free name in `Imported/` for a picked file: the original name, or `Name (2).ext` when
    /// taken, since two different albums both have a `01 Intro.flac`.
    func importDestination(for originalName: String) throws -> URL {
        try prepare()
        let cleaned = Self.sanitise((originalName as NSString).deletingPathExtension)
        let ext = (originalName as NSString).pathExtension.lowercased()
        let stem = cleaned.isEmpty ? "Track" : String(cleaned.prefix(Self.maxStemCharacters))
        var candidate = importedDirectory.appending(path: ext.isEmpty ? stem : "\(stem).\(ext)", directoryHint: .notDirectory)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            let name = "\(stem) (\(counter))"
            candidate = importedDirectory.appending(path: ext.isEmpty ? name : "\(name).\(ext)", directoryHint: .notDirectory)
            counter += 1
        }
        return candidate
    }
}

extension String {
    func trimmingTrailingWhitespace() -> String {
        var text = self
        while let last = text.last, last.isWhitespace { text.removeLast() }
        return text
    }
}
