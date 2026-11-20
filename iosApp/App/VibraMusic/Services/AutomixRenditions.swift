import AudioCache
import Automix
import VibraMusicCore
import CryptoKit
import Foundation

// Ports the Automix half of playback/AudioCache.kt (`renditionsOf`, `cacheKeyOf`,
// `requestAnalysisHead`, `discardBadRendition`): the analyzer and the version aligner read the
// playback cache's copies of a recording straight off disk.

/// The playback cache as Automix's ``AutomixRenditionProvider``.
///
/// AudioCache keeps each rendition as a sparse `<hash>.audio` file that only its resource loader
/// serves, and AVAssetReader picks a parser from the file extension, so each rendition on disk is
/// exposed as a hard link named with an audio extension (`<hash>.m4a`, `.mp3`, `.flac`…) in a
/// directory of its own. A hard link costs no space and always shows the cache's latest bytes (it
/// is the same inode), and it lives outside the cache directory so clearing the cache never has to
/// know about it.
///
/// The protocol is synchronous (the analyzer asks four times a second), the cache is an actor: the
/// answer is a snapshot per track, refreshed in the background whenever it is asked for and more
/// than ``refreshInterval`` old, so a rendition that grows is seen within a tick or two.
///
/// Eviction: a link whose cache file is gone has a link count of 1 (only the link names the
/// inode), and one whose entry was re-created points at a different inode than the cache's file.
/// Both are deleted on the next refresh and by ``sweep()``, which also runs once at start, so an
/// evicted track never keeps its bytes alive through the link.
final class AudioCacheRenditions: AutomixRenditionProvider, @unchecked Sendable {
    /// How stale a track's snapshot may get before a read schedules a refresh.
    static let refreshInterval: TimeInterval = 0.75
    /// Bound on the per-track session maps, the same cap the other session maps use.
    static let maxRemembered = 64
    /// How often a refresh also sweeps the whole link directory. A link keeps its cache file's bytes
    /// on disk after the cache evicts it; a track's own refresh drops its dead links at once, and
    /// this catches tracks nobody refreshes again, without listing the directory every
    /// ``refreshInterval``.
    // ponytail: such a link keeps its bytes for up to this long; an eviction callback from the
    // cache would free them at once if that ever matters.
    static let sweepInterval: TimeInterval = 60

    let cache: AudioStreamCache
    let linkDirectory: URL
    /// A byte source for YouTube's own copy of a video id, for fetching an analysis head. Nil
    /// leaves ``requestAnalysisHead(for:)`` a no-op.
    private let headSource: (@Sendable (String) -> (any AudioRangeDataSource)?)?
    /// The cache key the player's own copy of a video id resolves to right now, if the app knows.
    private let playingKey: (@Sendable (String) -> String?)?
    private let now: @Sendable () -> Date

    private struct Snapshot {
        var renditions: [AutomixRendition]
        var takenAt: Date
        /// Insertion order, for evicting the oldest (two snapshots can share a `takenAt`).
        var order = 0
    }

    private let lock = NSLock()
    private var snapshots: [String: Snapshot] = [:]
    private var refreshing: Set<String> = []
    private var headsAsked: Set<String> = []
    /// Link extension per cache file base: the index is read once per rendition, not per refresh.
    private var extensions: [String: String] = [:]
    /// The link file names each track currently owns, so pruning never lists the directory.
    private var linksByTrack: [String: Set<String>] = [:]
    private var snapshotOrder = 0
    private var lastSweep = Date.distantPast

    init(
        cache: AudioStreamCache,
        linkDirectory: URL = AudioCacheRenditions.defaultLinkDirectory,
        headSource: (@Sendable (String) -> (any AudioRangeDataSource)?)? = nil,
        playingKey: (@Sendable (String) -> String?)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.cache = cache
        self.linkDirectory = linkDirectory
        self.headSource = headSource
        self.playingKey = playingKey
        self.now = now
        try? FileManager.default.createDirectory(at: linkDirectory, withIntermediateDirectories: true)
        Task.detached(priority: .utility) { [self] in sweep() }
    }

    /// `Library/Caches/AutomixRenditions`: disposable, and on the same volume as the cache (a hard
    /// link can't cross volumes).
    static var defaultLinkDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "AutomixRenditions", directoryHint: .isDirectory)
    }

    // MARK: AutomixRenditionProvider

    func renditions(of uri: URL) -> [AutomixRendition] {
        guard let trackID = Self.trackID(of: uri) else { return [] }
        let (current, stale) = lock.withLock { () -> ([AutomixRendition], Bool) in
            let snapshot = snapshots[trackID]
            let stale = snapshot.map { now().timeIntervalSince($0.takenAt) > Self.refreshInterval } ?? true
            if stale, refreshing.insert(trackID).inserted { return (snapshot?.renditions ?? [], true) }
            return (snapshot?.renditions ?? [], false)
        }
        if stale {
            Task.detached(priority: .utility) { [self] in
                _ = await refresh(trackID: trackID)
            }
        }
        return current
    }

    func cacheKey(of uri: URL) -> String {
        guard let trackID = Self.trackID(of: uri) else { return uri.absoluteString }
        return playingKey?(trackID) ?? trackID
    }

    func requestAnalysisHead(for uri: URL) {
        guard let trackID = Self.trackID(of: uri), let headSource else { return }
        guard lock.withLock({ headsAsked.insert(trackID).inserted }) else { return }
        guard let source = headSource(trackID) else { return }
        let cache = self.cache
        Task.detached(priority: .utility) {
            await cache.requestAnalysisHead(for: .youtube(videoId: trackID), source: source)
        }
    }

    func discardBadRendition(for uri: URL, key: String) -> Bool {
        guard let trackID = Self.trackID(of: uri) else { return false }
        // The copy the player is reading is fine by definition: the decode that failed was of a
        // sibling. AudioCache applies the same rule; answering here keeps the protocol synchronous.
        if let playing = playingKey?(trackID), playing == key { return false }
        lock.withLock {
            snapshots[trackID]?.renditions.removeAll { $0.key == key }
            headsAsked.remove(trackID)
        }
        let cache = self.cache
        Task.detached(priority: .utility) { [self] in
            _ = await cache.discardBadRendition(AudioCacheKey(rawValue: key), playing: nil)
            _ = await refresh(trackID: trackID)
        }
        return true
    }

    // MARK: Refreshing

    /// Re-reads `trackID`'s renditions from the cache, (re)links each data file and drops links to
    /// renditions that are gone. Returns the new snapshot.
    @discardableResult
    func refresh(trackID: String) async -> [AutomixRendition] {
        let onDisk = await cache.renditions(ofTrack: trackID)
        var result: [AutomixRendition] = []
        var kept: Set<String> = []
        for rendition in onDisk {
            guard let link = link(for: rendition.key) else { continue }
            kept.insert(link.lastPathComponent)
            result.append(AutomixRendition(
                key: rendition.key.rawValue,
                contentLength: rendition.contentLength,
                cachedPrefix: rendition.cachedPrefix,
                fileURL: link
            ))
        }
        removeLinks(ofTrack: trackID, keeping: kept)
        lock.withLock {
            // Drop the oldest snapshot, never all of them: a track still being aligned keeps its own.
            if snapshots[trackID] == nil, snapshots.count >= Self.maxRemembered,
               let oldest = snapshots.min(by: { $0.value.order < $1.value.order })?.key {
                snapshots[oldest] = nil
            }
            snapshotOrder += 1
            snapshots[trackID] = Snapshot(renditions: result, takenAt: now(), order: snapshotOrder)
            refreshing.remove(trackID)
        }
        return result
    }

    /// Deletes every link whose cache file is gone or was replaced. Cheap: one directory listing.
    func sweep() {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: linkDirectory.path(percentEncoded: false))) ?? []
        for name in names {
            let url = linkDirectory.appending(path: name)
            let base = url.deletingPathExtension().lastPathComponent
            let data = cache.configuration.directory.appending(path: base + ".audio")
            if !Self.sameFile(url, data) { try? manager.removeItem(at: url) }
        }
    }

    /// The hard link for `key`'s data file, made or remade as needed; nil when the cache holds no
    /// file for it.
    private func link(for key: AudioCacheKey) -> URL? {
        let base = Self.fileBase(for: key)
        let data = cache.configuration.directory.appending(path: base + ".audio")
        let manager = FileManager.default
        guard manager.fileExists(atPath: data.path(percentEncoded: false)) else { return nil }
        let link = linkDirectory.appending(path: base + "." + fileExtension(forEntryBase: base))
        if Self.sameFile(link, data) { return link }
        try? manager.removeItem(at: link)
        do {
            try manager.linkItem(at: data, to: link)
            return link
        } catch {
            // Another refresh of the same track (the analyzer's and an alignment's) made it first.
            if Self.sameFile(link, data) { return link }
            DebugLog.w("Automix", "could not link the cached rendition \(key) for analysis", error: error)
            return nil
        }
    }

    private func removeLinks(ofTrack trackID: String, keeping kept: Set<String>) {
        // Only this track's links: the per-track ownership set costs O(track's links), not the
        // whole-directory listing the sweep does once at start.
        let stale = lock.withLock { (linksByTrack[trackID] ?? []).subtracting(kept) }
        let manager = FileManager.default
        for name in stale {
            let url = linkDirectory.appending(path: name)
            let base = url.deletingPathExtension().lastPathComponent
            let data = cache.configuration.directory.appending(path: base + ".audio")
            if !Self.sameFile(url, data) { try? manager.removeItem(at: url) }
        }
        // Not capped: forgetting a track's names would leave its links (and their bytes) behind.
        // A track with no links left drops out, so this holds only tracks that still have links.
        lock.withLock { linksByTrack[trackID] = kept.isEmpty ? nil : kept }
        sweepIfDue()
    }

    /// The whole-directory sweep, at most once per ``sweepInterval``.
    private func sweepIfDue() {
        let due = lock.withLock {
            let time = now()
            guard time.timeIntervalSince(lastSweep) >= Self.sweepInterval else { return false }
            lastSweep = time
            return true
        }
        if due { sweep() }
    }

    /// The extension AVFoundation should parse the rendition as, from the MIME type the cache's
    /// index recorded for it; m4a (YouTube's AAC) when it says nothing.
    private func fileExtension(forEntryBase base: String) -> String {
        if let known = lock.withLock({ extensions[base] }) { return known }
        let found = readExtension(forEntryBase: base)
        lock.withLock {
            if extensions.count >= Self.maxRemembered { extensions.removeAll() }
            extensions[base] = found
        }
        return found
    }

    private func readExtension(forEntryBase base: String) -> String {
        let record = cache.configuration.directory.appending(path: base + ".json")
        struct Index: Decodable { var mimeType: String? }
        let mime = (try? Data(contentsOf: record)).flatMap { try? JSONDecoder().decode(Index.self, from: $0) }?.mimeType
        return Self.fileExtension(forMimeType: mime)
    }

    static func fileExtension(forMimeType mime: String?) -> String {
        let lower = mime?.lowercased() ?? ""
        if lower.contains("flac") { return "flac" }
        if lower.contains("mpeg") || lower.contains("mp3") { return "mp3" }
        if lower.contains("wav") || lower.contains("wave") { return "wav" }
        if lower.contains("webm") { return "webm" }
        if lower.contains("ogg") || lower.contains("opus") { return "ogg" }
        if lower.contains("aiff") { return "aiff" }
        return "m4a"
    }

    // MARK: Identity

    /// The video id a playback URI (`vibramusic://watch?v=…`) names; nil for anything else.
    static func trackID(of uri: URL) -> String? {
        let value = URLComponents(url: uri, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
        return value?.isEmpty == false ? value : nil
    }

    /// AudioCache's file name for a key: the first 16 bytes of its SHA-256, in hex. Mirrors
    /// `AudioCacheStore.fileBase(for:)`, which is internal to the module (see the report's
    /// requested AudioCache change: a public `dataFileURL(for:)` would retire this copy).
    static func fileBase(for key: AudioCacheKey) -> String {
        SHA256.hash(data: Data(key.rawValue.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether two paths name the same inode (false if either is missing).
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        var first = stat()
        var second = stat()
        guard stat(a.path(percentEncoded: false), &first) == 0, stat(b.path(percentEncoded: false), &second) == 0 else { return false }
        return first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }
}
