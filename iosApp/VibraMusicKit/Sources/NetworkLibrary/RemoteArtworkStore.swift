import VibraMusicCore
import CryptoKit
import Foundation

// Ports data/remote/RemoteArtworkStore.kt: embedded covers for remote
// tracks, extracted lazily and cached.
//
// Listings never touch audio bytes, so a track whose art lives inside the
// file arrives with no thumbnail. The first surface that wants to draw it —
// a row, an album card, the player — asks here instead: memory first, then
// a disk cache of extracted pictures, and only then the bounded ranged
// reads that pull the picture out of the file. Concurrent asks for one
// track share a single extraction.
//
// Disk names are content-blind hashes of the track id: ids embed full URLs
// with slashes and escapes that must never reach the filesystem. A
// server-side overwrite keeps serving the stale copy — accepted, since
// revalidating would cost a request per row per list.

/// Lazily extracted embedded covers for remote tracks, with memory and disk
/// caches.
public actor RemoteArtworkStore {
    static let maxDirectoryBytes: Int64 = 100 * 1024 * 1024

    /// How the store reaches the file behind a song.
    public struct Source: Sendable {
        public var httpSession: URLSession
        public var smbClient: SmbClient?
        public var smbShare: String
        public var webdavCredentials: WebDavCredentials?

        public init(
            httpSession: URLSession = VibraMusicHTTP.session,
            smbClient: SmbClient? = nil,
            smbShare: String = "",
            webdavCredentials: WebDavCredentials? = nil
        ) {
            self.httpSession = httpSession
            self.smbClient = smbClient
            self.smbShare = smbShare
            self.webdavCredentials = webdavCredentials
        }
    }

    private let cacheDirectory: URL
    private let fileManager: FileManager
    private var memory: [String: URL] = [:]
    private var inFlight: [String: Task<URL?, Never>] = [:]

    /// - Parameter cacheDirectory: where extracted pictures live (the app
    ///   passes a `remote_art` folder under its caches directory).
    public init(cacheDirectory: URL, fileManager: FileManager = .default) {
        self.cacheDirectory = cacheDirectory
        self.fileManager = fileManager
    }

    /// A drawable art URL for `song`: its own thumbnail when it has one,
    /// else the extracted embedded picture, else nil. Never throws.
    public func resolveArt(_ song: Song, source: Source) async -> URL? {
        if let thumbnail = song.thumbnailUrl, let url = URL(string: thumbnail) { return url }
        let key = song.videoId
        // Eviction deletes files behind the memory map's back.
        if let cached = memory[key], fileManager.fileExists(atPath: cached.path) { return cached }
        if let hit = diskHit(key: key) {
            memory[key] = hit
            return hit
        }
        if let running = inFlight[key] { return await running.value }
        let cacheDirectory = cacheDirectory
        let fileManager = fileManager
        let task = Task<URL?, Never>.detached {
            await Self.extractAndStore(song: song, key: key, source: source, cacheDirectory: cacheDirectory, fileManager: fileManager)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result { memory[key] = result }
        return result
    }

    /// Forgets every cached picture, in memory and on disk.
    public func clear() {
        memory.removeAll()
        try? fileManager.removeItem(at: cacheDirectory)
    }

    private static func extractAndStore(
        song: Song,
        key: String,
        source: Source,
        cacheDirectory: URL,
        fileManager: FileManager
    ) async -> URL? {
        guard let localUri = song.localUri,
              localUri.hasPrefix("http") || localUri.hasPrefix("smb://")
        else { return nil }
        let isSmb = localUri.hasPrefix("smb://")
        let picture = await RemoteArtReader.picture(
            url: localUri,
            isSmb: isSmb,
            session: source.httpSession,
            smbClient: source.smbClient,
            smbShare: source.smbShare,
            webdavCredentials: source.webdavCredentials
        )
        guard let picture else { return nil }
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let file = cacheDirectory.appendingPathComponent("\(cacheKey(key)).\(extensionFor(picture.mime))", isDirectory: false)
        do {
            try picture.bytes.write(to: file, options: .atomic)
            evict(directory: cacheDirectory, fileManager: fileManager)
        } catch {
            return nil
        }
        return file
    }

    private func diskHit(key: String) -> URL? {
        // The extension depends on the sniffed mime, so each one the store writes is tried. Asking
        // for those few names, rather than listing the folder, keeps a first pass down a long remote
        // list from reading the whole cache once per row.
        let stem = Self.cacheKey(key)
        return Self.extensions
            .compactMap { ext -> (url: URL, modified: Date)? in
                let file = cacheDirectory.appendingPathComponent("\(stem).\(ext)", isDirectory: false)
                guard let attributes = try? fileManager.attributesOfItem(atPath: file.path),
                      (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else { return nil }
                return (file, attributes[.modificationDate] as? Date ?? .distantPast)
            }
            .max { $0.modified < $1.modified }?
            .url
    }

    /// Every extension ``extensionFor(_:)`` names.
    static let extensions = ["jpg", "png", "webp", "gif", "bmp", "bin"]

    static func extensionFor(_ mime: String) -> String {
        switch mime.lowercased() {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        case "image/bmp": return "bmp"
        default: return "bin"
        }
    }

    static func cacheKey(_ videoId: String) -> String {
        Insecure.SHA1.hash(data: Data(videoId.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func evict(directory: URL, fileManager: FileManager) {
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return
        }
        var total: Int64 = files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        guard total > maxDirectoryBytes else { return }
        let oldest = files.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
        for file in oldest {
            guard total > maxDirectoryBytes else { return }
            total -= Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            try? fileManager.removeItem(at: file)
        }
    }
}
