import Foundation
import Observation
import VibraMusicCore

// Ports the record-keeping half of download/Downloads.kt (saved, savedMetadata, collections,
// requested, getDownloadedSongs, getCollectionSongs, delete, …) plus the imported-file side of
// data/LocalMediaRepository.kt.

/// What deleting some downloads freed.
public struct DownloadDeletion: Hashable, Sendable {
    /// Files removed.
    public var deletedFiles: Int
    /// Bytes those files (and any cover no longer used by anything) took.
    public var freedBytes: Int64

    public init(deletedFiles: Int = 0, freedBytes: Int64 = 0) {
        self.deletedFiles = deletedFiles
        self.freedBytes = freedBytes
    }
}

/// How much space the library takes, for the Downloads screen and Settings → Storage.
public struct DownloadStorageUsage: Hashable, Sendable {
    public var downloadedBytes: Int64
    public var downloadedCount: Int
    public var importedBytes: Int64
    public var importedCount: Int
    /// Saved covers.
    public var artworkBytes: Int64
    /// Unfinished downloads and transfers waiting to be appended.
    public var partialBytes: Int64
    /// Free space on the volume for important data (`volumeAvailableCapacityForImportantUsage`), when known.
    public var availableBytes: Int64?

    public var totalBytes: Int64 { downloadedBytes + importedBytes + artworkBytes + partialBytes }

    /// `bytes` as Files shows sizes ("35.2 MB").
    public static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// The record of what is on this device: downloads and imported files, the releases they were
/// downloaded as, and where each file is.
///
/// A claim about files, which is why every read verifies before it answers: an entry can outlive the
/// file it names (a restore without the excluded-from-backup `Tracks/` folder, a crash mid-delete,
/// the system reclaiming space), and a record that says a download exists when it doesn't makes the
/// menu offer to delete nothing and the player open a path that isn't there.
///
/// Main-actor isolated. Android guarded these maps with compare-and-set updates because four
/// download workers finish at once; here every writer is on one actor, so "read the map, add my
/// track, store it back" can't lose a track. Persisted as `library.json` in the store root after
/// every change (small, and written atomically).
@MainActor
@Observable
public final class DownloadLibrary {
    public let store: DownloadStore

    /// videoId → the file saved for it, relative to the store root. One file can answer to more
    /// than one id (see ``remember(asked:fetched:file:downloadFormat:artworkPath:)``).
    public private(set) var saved: [String: String] = [:] {
        didSet { shelfPlaylists = nil }
    }
    /// videoId → what the row said when it was saved.
    public private(set) var records: [String: SavedTrackRecord] = [:]
    /// The releases downloaded *as* releases, by the id they were asked for under.
    public private(set) var collections: [String: SavedCollection] = [:] {
        didSet { shelfPlaylists = nil }
    }
    /// ``savedPlaylists(onDisk:)`` against the record, until ``saved`` or ``collections`` change. The
    /// Library page asks on every pass of its body, and each answer is a filter, a sort and a file
    /// check per playlist.
    @ObservationIgnored private var shelfPlaylists: [SavedCollection]?
    /// Ids asked for as part of a release's own download tap, by the browseId that was tapped.
    ///
    /// ``DownloadManager/active`` is one flat map for the whole app, so a release page can't tell
    /// "one of my tracks is queued" apart from "one of my tracks is queued *because I was asked
    /// for*" by scanning it: two releases sharing a track would both read as downloading. This lets
    /// a release header ask the narrower question. In memory only, as on Android.
    public private(set) var requested: [String: Set<String>] = [:]

    private static let fileName = "library.json"

    private struct Persisted: Codable {
        var saved: [String: String] = [:]
        var records: [String: SavedTrackRecord] = [:]
        var collections: [String: SavedCollection] = [:]
    }

    /// Loads the record from `store`. A missing or unreadable file is an empty library (the
    /// unreadable one is logged and kept aside as `library.json.corrupt`).
    public init(store: DownloadStore) {
        self.store = store
        do {
            if let persisted = try store.records.load(Persisted.self, from: Self.fileName) {
                saved = persisted.saved
                records = persisted.records
                collections = persisted.collections
            }
        } catch {
            DebugLog.e("Downloads", "download library unreadable; starting empty", error: error)
            let url = store.records.url(for: Self.fileName)
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("corrupt"))
        }
    }

    /// The app's library, in `Application Support/Vibra Music/Downloads`.
    public static func live() -> DownloadLibrary {
        DownloadLibrary(store: .applicationSupport())
    }

    // MARK: Asking

    /// Whether the record says `videoId` is on the device. Unverified and cheap — for badges on
    /// rows. Use ``savedFileURL(for:)`` before playing.
    public func isDownloaded(_ videoId: String) -> Bool { saved[videoId] != nil }

    /// The file saved for `videoId`, or nil — pruning the record if the file has been deleted from
    /// under it. What Playback should open instead of resolving a stream.
    public func savedFileURL(for videoId: String) -> URL? {
        guard let path = saved[videoId] else { return nil }
        if store.exists(relativePath: path) { return store.url(forRelativePath: path) }
        DebugLog.d("Downloads", "\(videoId) was downloaded but the file is gone; forgetting it")
        forgetPath(path)
        return nil
    }

    /// True when `uriString` names a `file://` path that is not there. False for anything else,
    /// which keeps "I could not tell" out of "the file is missing". Cheap enough (a `stat`) to call
    /// per item while building a queue.
    public nonisolated static func isMissingLocalFile(_ uriString: String) -> Bool {
        guard uriString.hasPrefix("file://"), let url = URL(string: uriString) else { return false }
        return !FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// Drop the record for `videoId` because a read of the file it names has just failed. For
    /// Playback's recovery path, which has already done better than a check: it opened the file and
    /// got ENOENT. Named for what it asserts, so a caller that hasn't established that has no
    /// business calling it.
    public func forgetMissing(_ videoId: String) {
        guard let path = saved[videoId] else { return }
        DebugLog.d("Downloads", "\(videoId) could not be opened; forgetting the download")
        forgetPath(path)
    }

    /// Every file in the library that is still on disk, downloads and imports alike (PORTING.md Q8:
    /// Files imports feed the same library as downloads).
    ///
    /// A downloaded track answering to two ids is one file, verified and listed once. Records whose
    /// file is gone are pruned — every alias of them.
    public func songs(includeImported: Bool = true) -> [Song] {
        listing(Self.inspect(listedRecords(includeImported: includeImported), store: store))
    }

    /// ``songs(includeImported:)`` with the file checks done off the main actor. A big library is a
    /// stat per track and per cover, and the Downloads page lists itself again each time a download
    /// in a batch lands; on the main actor that was a stall in the middle of a scroll.
    public func listSongs(includeImported: Bool = true) async -> [Song] {
        let records = listedRecords(includeImported: includeImported)
        let store = store
        let files = await Task.detached(priority: .userInitiated) { Self.inspect(records, store: store) }.value
        return listing(files)
    }

    /// What a listing found on disk for one record.
    private struct ListedFile: Sendable {
        var record: SavedTrackRecord
        var url: URL
        var exists = false
        var modifiedMillis: Int64?
        var artwork: URL?
    }

    /// The records a listing checks: one per file, in a stable order.
    private func listedRecords(includeImported: Bool) -> [SavedTrackRecord] {
        var seenPaths = Set<String>()
        return records.values.sorted(by: { $0.videoId < $1.videoId }).filter { record in
            (includeImported || record.origin != .imported) && seenPaths.insert(record.path).inserted
        }
    }

    /// The disk half of a listing: whether each file is there, when it changed, and its cover.
    private nonisolated static func inspect(_ records: [SavedTrackRecord], store: DownloadStore) -> [ListedFile] {
        records.map { record in
            let url = store.url(forRelativePath: record.path)
            guard store.exists(relativePath: record.path) else { return ListedFile(record: record, url: url) }
            let artwork = record.artworkPath.flatMap { store.exists(relativePath: $0) ? store.url(forRelativePath: $0) : nil }
            return ListedFile(record: record, url: url, exists: true, modifiedMillis: DownloadStore.modificationMillis(url),
                              artwork: artwork)
        }
    }

    /// The record half: the rows for the files that are there, the record pruned of those that
    /// aren't, and added dates filled in from the files for records saved before they were kept.
    private func listing(_ files: [ListedFile]) -> [Song] {
        var result: [Song] = []
        var missing = Set<String>()
        var migratedAdded: [String: Int64] = [:]

        for file in files {
            let record = file.record
            guard file.exists else {
                missing.insert(record.path)
                continue
            }
            let dates = resolvedDownloadDates(persistedAddedSeconds: record.dateAddedSeconds, fileModifiedMillis: file.modifiedMillis)
            if record.dateAddedSeconds == nil, let added = dates.added { migratedAdded[record.path] = added }
            result.append(song(for: record, url: file.url, dates: dates, artwork: file.artwork))
        }
        // Looked at again before the record goes: ``listSongs(includeImported:)`` saw the disk a
        // moment ago, and a track saved again to the same path since then keeps its record.
        missing.filter { !store.exists(relativePath: $0) }.forEach(forgetPath)
        if !migratedAdded.isEmpty {
            for (id, record) in records where record.dateAddedSeconds == nil {
                records[id]?.dateAddedSeconds = migratedAdded[record.path]
            }
            persist()
        }
        return result
    }

    /// The library row for one id, if its file is there.
    public func song(for videoId: String) -> Song? {
        guard let record = records[videoId], store.exists(relativePath: record.path) else { return nil }
        let url = store.url(forRelativePath: record.path)
        let dates = resolvedDownloadDates(persistedAddedSeconds: record.dateAddedSeconds,
                                          fileModifiedMillis: DownloadStore.modificationMillis(url))
        return song(for: record, url: url, dates: dates, artwork: artworkURL(forRelativePath: record.artworkPath))
    }

    /// Only the files that came from Files import.
    public func importedSongs() -> [Song] {
        songs().filter { records[$0.videoId]?.origin == .imported }
    }

    /// The available files for one downloaded collection, in its saved running order. Only the files
    /// the record names are verified, so opening a ten-track playlist doesn't cost a pass over the
    /// whole library.
    public func collectionSongs(_ collectionId: String) -> [Song] {
        guard let record = collections[collectionId] else { return [] }
        var seen = Set<String>()
        let byPath = Dictionary(records.values.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return record.videoIds.compactMap { videoId in
            guard let path = saved[videoId] ?? records[videoId]?.path, seen.insert(path).inserted else { return nil }
            guard store.exists(relativePath: path) else {
                // Every alias can name this file; prune them all now the one check has shown it gone.
                forgetPath(path)
                return nil
            }
            guard var meta = records[videoId] ?? byPath[path] else { return nil }
            meta.videoId = videoId
            let url = store.url(forRelativePath: path)
            let dates = resolvedDownloadDates(persistedAddedSeconds: meta.dateAddedSeconds,
                                              fileModifiedMillis: DownloadStore.modificationMillis(url))
            return song(for: meta, url: url, dates: dates, artwork: artworkURL(forRelativePath: meta.artworkPath))
        }
    }

    /// `artwork` is the saved cover's file when it is there.
    private func song(for record: SavedTrackRecord, url: URL, dates: (added: Int64?, modified: Int64?), artwork: URL?) -> Song {
        Song(
            videoId: record.videoId,
            title: record.title,
            artist: record.artist,
            thumbnailUrl: artwork?.absoluteString ?? record.thumbnailUrl,
            durationText: record.durationText,
            albumName: record.albumName,
            localUri: url.absoluteString,
            downloadFormat: record.downloadFormat,
            localPath: url.path(percentEncoded: false),
            localDateAddedSeconds: dates.added,
            localDateModifiedSeconds: dates.modified
        )
    }

    /// A saved cover's file URL, when the path is set and the file is there.
    public func artworkURL(forRelativePath path: String?) -> URL? {
        guard let path, store.exists(relativePath: path) else { return nil }
        return store.url(forRelativePath: path)
    }

    // MARK: Recording

    /// Record one file under every id it could be asked about.
    ///
    /// `asked` is the row the user tapped and `fetched` is what was actually downloaded. On Android
    /// those differ for a music video swapped for its catalogue track; on iOS the queue saves the
    /// exact row asked for (as Android now does too), but the two-id shape is kept so a resolver
    /// that does swap still files under both.
    func remember(asked: Song, fetched: Song, file: URL, downloadFormat: String? = nil, artworkPath: String? = nil) {
        guard let path = store.relativePath(of: file) else {
            DebugLog.e("Downloads", "refusing to record \(file.lastPathComponent): outside the download folder")
            return
        }
        let ids = [asked.videoId, fetched.videoId]
        let existingAdded = ids.lazy.compactMap { self.records[$0]?.dateAddedSeconds }.first
        let added = resolvedDownloadDates(persistedAddedSeconds: existingAdded,
                                          fileModifiedMillis: DownloadStore.modificationMillis(file)).added
            ?? Int64(Date().timeIntervalSince1970)
        // Either row may be the one that knew the release.
        let album = [fetched.albumName, asked.albumName].compactMap { $0 }.first { !$0.isBlank }
        for song in [asked, fetched] {
            saved[song.videoId] = path
            records[song.videoId] = SavedTrackRecord(
                videoId: song.videoId,
                title: song.title,
                artist: song.artist,
                thumbnailUrl: song.thumbnailUrl,
                artworkPath: artworkPath ?? records[song.videoId]?.artworkPath,
                durationText: song.durationText,
                albumName: album,
                path: path,
                downloadFormat: downloadFormat,
                dateAddedSeconds: added,
                origin: .download
            )
        }
        persist()
    }

    /// Record a file copied in from Files.
    func rememberImported(_ record: SavedTrackRecord) {
        saved[record.videoId] = record.path
        records[record.videoId] = record
        persist()
    }

    /// The imported record whose file has these bytes, if any (dedupe on re-import).
    func importedRecord(where matches: (SavedTrackRecord) -> Bool) -> SavedTrackRecord? {
        records.values.first { $0.origin == .imported && matches($0) }
    }

    // MARK: Deleting

    /// Delete the file saved for `videoId` and forget it (and every other id naming that file).
    @discardableResult
    public func delete(_ videoId: String) -> Bool {
        delete([videoId]).deletedFiles > 0
    }

    /// Delete the files saved for `videoIds` — the Downloads page's multi-select delete — and
    /// report the space freed, covers included once nothing else uses them.
    @discardableResult
    public func delete(_ videoIds: [String]) -> DownloadDeletion {
        var result = DownloadDeletion()
        var paths = Set<String>()
        for id in videoIds {
            if let path = saved[id] ?? records[id]?.path { paths.insert(path) }
        }
        for path in paths {
            let freed = store.delete(relativePath: path)
            // A file that could not be removed keeps its record, so it stays listed and deletable.
            guard freed > 0 || !store.exists(relativePath: path) else { continue }
            result.deletedFiles += freed > 0 ? 1 : 0
            result.freedBytes += freed
            forgetPath(path, persisting: false)
        }
        result.freedBytes += collectUnusedArtwork()
        persist()
        return result
    }

    /// Removes saved covers nothing refers to any more, returning the bytes freed.
    private func collectUnusedArtwork() -> Int64 {
        let used = Set(records.values.compactMap(\.artworkPath) + collections.values.compactMap(\.artworkPath))
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: store.artworkDirectory.path(percentEncoded: false)) else { return 0 }
        var freed: Int64 = 0
        for name in names where !name.hasPrefix(".") {
            let path = "\(DownloadStore.artworkFolder)/\(name)"
            if !used.contains(path) { freed += store.delete(relativePath: path) }
        }
        return freed
    }

    /// Forget every id recorded for the file at `path`.
    private func forgetPath(_ path: String) {
        forgetPath(path, persisting: true)
    }

    private func forgetPath(_ path: String, persisting: Bool) {
        let ids = Set(saved.filter { $0.value == path }.map(\.key) + records.filter { $0.value.path == path }.map(\.key))
        guard !ids.isEmpty else { return }
        for id in ids {
            saved.removeValue(forKey: id)
            records.removeValue(forKey: id)
        }
        if persisting { persist() }
    }

    // MARK: Releases

    /// Record that `browseId` asked for `videoIds` as its own release.
    public func markRequested(_ browseId: String, videoIds: some Collection<String>) {
        guard !videoIds.isEmpty else { return }
        requested[browseId, default: []].formUnion(videoIds)
    }

    /// Remember that `songs` were asked for as one release rather than one at a time.
    ///
    /// A batch download used to be indistinguishable from forty separate ones the moment it
    /// finished: an album page's rows don't carry the album (it is billed once, in the header) and a
    /// playlist's tracks are off forty different releases. So the thing the user tapped was the one
    /// thing not written down anywhere. Recorded at the tap and keyed by the id tapped, so
    /// re-downloading updates one entry instead of accumulating near-duplicates. Nothing here
    /// asserts the files exist; which of these tracks is on disk is answered where it is read.
    public func rememberCollection(_ target: DownloadTarget, songs: [Song]) {
        guard !songs.isEmpty else { return }
        var seen = Set<String>()
        let ids = songs.map(\.videoId).filter { seen.insert($0).inserted }
        let existing = collections[target.id]
        var merged = Set<String>()
        collections[target.id] = SavedCollection(
            id: target.id,
            title: target.title,
            subtitle: target.subtitle,
            thumbnailUrl: target.thumbnailUrl ?? existing?.thumbnailUrl,
            // Once the cover has been cached, the same release downloaded again keeps it.
            artworkPath: existing?.artworkPath,
            playlist: target.playlist,
            // A release fetched in pages can be downloaded twice from two depths of the same page:
            // merged, with the new order leading since it is the one just seen on screen.
            videoIds: (ids + (existing?.videoIds ?? [])).filter { merged.insert($0).inserted }
        )
        persist()
    }

    /// Point a collection at its cached local cover (a path relative to the store root).
    public func rememberCollectionArtwork(id: String, artworkPath: String) {
        guard var existing = collections[id], existing.artworkPath != artworkPath else { return }
        existing.artworkPath = artworkPath
        collections[id] = existing
        persist()
    }

    /// Drop a release from the record without touching the files under it.
    public func forgetCollection(_ id: String) {
        guard collections.removeValue(forKey: id) != nil else { return }
        persist()
    }

    /// Delete every file downloaded for release `id` and drop the record of it — the "delete
    /// download" an album or playlist card offers.
    @discardableResult
    public func deleteCollection(_ id: String) -> DownloadDeletion? {
        guard let record = collections[id] else { return nil }
        collections.removeValue(forKey: id)
        let result = delete(record.videoIds)
        persist()
        return result
    }

    /// The page id a downloaded playlist opens under. Under `local:` so the rest of the app knows it
    /// is already on the device, but in a segment of its own so it isn't mistaken for one of the
    /// device folders (`local:downloads`, `local:all`), which open the tabbed view instead.
    public nonisolated static func pageId(for id: String) -> String { LocalBrowseID.playlistPrefix + id }

    /// The release ``pageId(for:)`` built `browseId` from, or nil if it didn't.
    public nonisolated static func recordId(of browseId: String) -> String? {
        guard browseId.hasPrefix(LocalBrowseID.playlistPrefix) else { return nil }
        let id = String(browseId.dropFirst(LocalBrowseID.playlistPrefix.count))
        return id.isEmpty ? nil : id
    }

    /// The playlists downloaded whole, in name order — what the Library page's On Device shelf
    /// draws. Prunes against `onDisk` (default: the record), which drops a playlist once its last
    /// file is gone and keeps it off the shelf between the tap that queues it and the first track
    /// landing. Albums aren't here: a downloaded album stamps its name on each track, so the Albums
    /// tab groups it back up without help; a playlist can't be inferred that way.
    public func savedPlaylists(onDisk: [String: String]? = nil) -> [SavedCollection] {
        // Both read on a cached answer too, so a view drawing the shelf still hears either change.
        let fromRecord = onDisk == nil
        let onDisk = onDisk ?? saved
        let collections = self.collections
        if fromRecord, let shelfPlaylists { return shelfPlaylists }
        let playlists = collections.values
            .filter { record in record.playlist && record.videoIds.contains { onDisk[$0] != nil } }
            .sorted { $0.title.lowercased() < $1.title.lowercased() }
            .map { record in
                var copy = record
                if let local = artworkURL(forRelativePath: record.artworkPath) { copy.thumbnailUrl = local.absoluteString }
                return copy
            }
        if fromRecord { shelfPlaylists = playlists }
        return playlists
    }

    /// The releases at least one of `songs` belongs to, each with its own tracks picked out of that
    /// list.
    ///
    /// Given the page's own songs rather than reading the disk itself, because the page has already
    /// done that work — every row in it is a file that was there when it was taken — and a release
    /// is only worth drawing for the tracks that survived. The lookup also goes through ``saved``,
    /// because one file can answer to two ids.
    public func collectionsAmong(_ songs: [Song]) -> [DownloadedCollection] {
        guard !songs.isEmpty, !collections.isEmpty else { return [] }
        var byId: [String: Song] = [:]
        for song in songs where byId[song.videoId] == nil { byId[song.videoId] = song }
        var byPath: [String: Song] = [:]
        for song in songs {
            guard let uri = song.localUri, let url = URL(string: uri), let path = store.relativePath(of: url) else { continue }
            if byPath[path] == nil { byPath[path] = song }
        }
        return collections.values
            .compactMap { record -> DownloadedCollection? in
                var seen = Set<String>()
                let tracks = record.videoIds
                    .compactMap { id in byId[id] ?? saved[id].flatMap { byPath[$0] } }
                    .filter { seen.insert($0.localUri ?? $0.videoId).inserted }
                guard !tracks.isEmpty else { return nil }
                return DownloadedCollection(
                    id: record.id,
                    title: record.title,
                    subtitle: record.subtitle,
                    thumbnailUrl: artworkURL(forRelativePath: record.artworkPath)?.absoluteString
                        ?? record.thumbnailUrl
                        ?? tracks.lazy.compactMap(\.thumbnailUrl).first,
                    playlist: record.playlist,
                    songs: tracks
                )
            }
            .sorted { $0.title.lowercased() < $1.title.lowercased() }
    }

    // MARK: Storage

    /// What the library takes on disk right now.
    public func storageUsage() -> DownloadStorageUsage {
        var usage = DownloadStorageUsage(downloadedBytes: 0, downloadedCount: 0, importedBytes: 0, importedCount: 0,
                                         artworkBytes: 0, partialBytes: 0, availableBytes: nil)
        var counted = Set<String>()
        for record in records.values where counted.insert(record.path).inserted {
            let size = store.size(relativePath: record.path)
            guard size > 0 else { continue }
            switch record.origin {
            case .download:
                usage.downloadedBytes += size
                usage.downloadedCount += 1
            case .imported:
                usage.importedBytes += size
                usage.importedCount += 1
            }
        }
        usage.artworkBytes = Self.directorySize(store.artworkDirectory) { _ in true }
        usage.partialBytes = Self.directorySize(store.tracksDirectory) { $0.hasSuffix(".part") }
            + Self.directorySize(store.stagingDirectory) { _ in true }
        let values = try? store.root.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        usage.availableBytes = values?.volumeAvailableCapacityForImportantUsage
        return usage
    }

    private static func directorySize(_ directory: URL, including: (String) -> Bool) -> Int64 {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) else { return 0 }
        return names.filter(including).reduce(0) { $0 + DownloadStore.fileSize(directory.appending(path: $1)) }
    }

    // MARK: Persistence

    private func persist() {
        do {
            try store.records.save(Persisted(saved: saved, records: records, collections: collections), to: Self.fileName)
        } catch {
            DebugLog.e("Downloads", "could not save the download library", error: error)
        }
    }
}
