import CryptoKit
import VibraMusicCore
import Foundation

/// Disk cache for canvas clips — the looping video some releases publish alongside a track,
/// played over the cover art in a looping `AVPlayerLayer` (Android: `CanvasCache` in
/// `data/canvas/CanvasCache.kt`).
///
/// Why a cache at all: a five-second clip behind a four-minute track loops around fifty
/// times, and without a cache every loop re-downloads the same few seconds of video — the
/// "40MB for one song" reports trace to exactly this repeat, not to audio bitrate. Serving
/// the clip from disk after the first loop ends that.
///
/// iOS difference: Android wraps ExoPlayer's data source so the player itself reads through
/// the cache. `AVPlayer` has no such hook, so this cache sits one level up: `localFile(for:)`
/// answers the on-disk copy when there is one, and `fetchClip(from:)` downloads through
/// `URLSession` (a plain progressive MP4) before handing the local file to the player.
///
/// For the player, only progressive clips are cached. Apple serves HLS playlists, which are a
/// directory of segments rather than one file — `fetchClip` hands those straight to `AVPlayer`
/// and lets its own segment handling do the work. `fetchLocalClip` is the exception: the lock
/// screen takes only a file, so it joins the HLS clip into one.
public final class CanvasClipCache: Sendable {
    /// Small on purpose — a clip is a few seconds of video, not a song, and this only needs
    /// to outlive one player screen's worth of looping, not a library.
    public static let defaultLimitBytes: Int64 = 150 * 1024 * 1024

    private let directory: URL
    private let limitBytes: Int64
    private let lock = NSLock()

    /// - Parameters:
    ///   - directory: where clips live; created on init. The app passes a
    ///     `caches/com.fortune.vibramusic.ios/canvas` folder (excluded from backup and purged by the
    ///     system under pressure, which is exactly the semantics wanted here).
    ///   - limitBytes: eviction target; the oldest clips go once the total passes it.
    public init(directory: URL, limitBytes: Int64 = defaultLimitBytes) {
        self.directory = directory
        self.limitBytes = limitBytes
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The on-disk copy of `remoteURL`'s clip, or nil when it isn't cached yet.
    public func localFile(for remoteURL: URL) -> URL? {
        let file = fileURL(for: remoteURL)
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return nil }
        // A hit is a use: keep the clip being looped out of the next eviction.
        try? FileManager.default.setAttributes([.modificationDate: Date()],
                                               ofItemAtPath: file.path(percentEncoded: false))
        return file
    }

    /// Whether `remoteURL`'s clip is already on disk.
    public func contains(_ remoteURL: URL) -> Bool {
        localFile(for: remoteURL) != nil
    }

    /// Stores `data` as `remoteURL`'s clip. A write that fails (full disk, evicted mid-write)
    /// is swallowed: callers fall back to streaming the remote URL rather than surfacing a
    /// playback error.
    @discardableResult
    public func store(_ data: Data, for remoteURL: URL) -> URL? {
        let file = fileURL(for: remoteURL)
        do {
            try data.write(to: file, options: .atomic)
            evictIfNeeded()
            return file
        } catch {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
    }

    /// The clip for `artwork`, ready to mount: the on-disk copy for progressive MP4 (fetching
    /// it first when missing), or the remote URL itself for HLS. Never throws — on any
    /// failure the remote URL comes back and the player streams it.
    public func fetchClip(
        for artwork: CanvasArtwork, session: URLSession = VibraMusicHTTP.session
    ) async -> URL {
        let candidates = artwork.playbackURLs
        guard let primary = candidates.first else {
            return URL(string: "about:blank")!
        }
        if primary.isCanvasHLS { return primary }
        if let cached = localFile(for: primary) { return cached }
        do {
            let (data, response) = try await session.data(from: primary)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if status / 100 == 2, !data.isEmpty, let stored = store(data, for: primary) {
                return stored
            }
        } catch {
            // Fall through to streaming the remote URL.
        }
        return primary
    }

    /// The clip for `artwork` as a local file, for a caller that can't take a stream (the lock
    /// screen's animated artwork), or nil when it can't be had. Progressive MP4 goes
    /// through ``fetchClip(for:session:)``; HLS is joined into one fragmented MP4 by
    /// ``HLSClipAssembler`` and kept under the playlist URL plus `.mp4`, so it loops from disk
    /// like the rest and never collides with the stream the player screen mounts.
    public func fetchLocalClip(
        for artwork: CanvasArtwork, session: URLSession = VibraMusicHTTP.session
    ) async -> URL? {
        // The fallback rendition gets its turn when the primary can't be had, as on the player.
        for url in artwork.playbackURLs where !Task.isCancelled {
            if url.isCanvasHLS {
                let key = url.appendingPathExtension("mp4")
                if let cached = localFile(for: key) { return cached }
                if let data = await HLSClipAssembler.assemble(master: url, session: session),
                   let stored = store(data, for: key) { return stored }
            } else {
                let served = await fetchClip(for: CanvasArtwork(url: url.absoluteString), session: session)
                if served.isFileURL { return served }
            }
        }
        return nil
    }

    /// What ``fetchLocalClip(for:session:)`` would answer without asking the network: nil until the
    /// clip is on disk.
    public func cachedLocalClip(for artwork: CanvasArtwork) -> URL? {
        for url in artwork.playbackURLs {
            if let cached = localFile(for: url.isCanvasHLS ? url.appendingPathExtension("mp4") : url) { return cached }
        }
        return nil
    }

    /// Drops every cached clip.
    public func clear() {
        lock.withLock {
            for name in fileNames() {
                try? FileManager.default.removeItem(at: directory.appending(path: name))
            }
        }
    }

    /// Bytes currently on disk.
    public var currentBytes: Int64 {
        lock.withLock { totalBytes() }
    }

    // MARK: - Internals

    func fileURL(for remoteURL: URL) -> URL {
        let digest = SHA256.hash(data: Data(remoteURL.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        let suffix = remoteURL.pathExtension.lowercased() == "mp4" ? "mp4" : "clip"
        return directory.appending(path: "\(name).\(suffix)")
    }

    private func fileNames() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
    }

    private func fileSize(_ url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false)),
            let size = attributes[.size] as? NSNumber
        else { return 0 }
        return size.int64Value
    }

    private func totalBytes() -> Int64 {
        fileNames().reduce(0) { total, name in
            total + fileSize(directory.appending(path: name))
        }
    }

    private func evictIfNeeded() {
        lock.withLock {
            guard totalBytes() > limitBytes else { return }
            let files = fileNames().map { directory.appending(path: $0) }
            let byAge = files.sorted {
                modificationDate($0) ?? .distantPast < modificationDate($1) ?? .distantPast
            }
            var total = totalBytes()
            for file in byAge {
                if total <= limitBytes { break }
                let size = fileSize(file)
                if (try? FileManager.default.removeItem(at: file)) != nil { total -= size }
            }
        }
    }

    private func modificationDate(_ url: URL) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false))
        else { return nil }
        return attributes[.modificationDate] as? Date
    }
}

private extension URL {
    var isCanvasHLS: Bool {
        absoluteString.lowercased().contains(".m3u8")
    }
}
