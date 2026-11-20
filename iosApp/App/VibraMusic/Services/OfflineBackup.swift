import AudioCache
import VibraMusicCore
import Foundation
import PlaybackPolicy
import Sources

/// Offline backup: the songs already whole on this device, most recent first — what still plays
/// with no connection (Spotify's "Offline Backup").
///
/// Nothing is fetched for it. The audio cache keeps every track that played and reads the next one
/// ahead in full; this remembers who those tracks are (the cache knows bytes, not titles) and lists
/// the ones whose bytes are all there. A track leaves the list when the cache evicts it, and comes
/// back when it plays again. Downloads have their own page and aren't repeated here.
@MainActor
final class OfflineBackup {
    private struct Entry: Codable, Sendable {
        var song: Song
        var seenAt: Date
    }

    /// How many tracks are remembered: far more than a cache at its default limit holds whole.
    static let limit = 2_000
    static var defaultFile: URL {
        URL.applicationSupportDirectory.appending(path: "offline-backup.json")
    }

    /// Whether the listener reverted a track to YouTube's own upload: such a row never plays a
    /// substitute or an upgrade's copy, so one whose only whole copies are those isn't offered.
    var isPinned: (String) -> Bool = { OriginalVersion.shared.isPinned($0) }
    /// The player's Atmos switch: with it off, an upgrade's copy doesn't play off the disk
    /// (``PlaybackSourceFactory/playsOffDisk(_:pinned:atmosAllowed:)``), so it isn't offered either.
    var atmosAllowed: () -> Bool = { true }
    /// Saved downloads (listed on the Downloads page instead). Asked once per list.
    var savedSongs: () -> [Song] = { [] }

    private let cache: AudioStreamCache?
    private let file: URL?
    private var entries: [String: Entry]
    private var saveTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?

    /// - Parameter file: where the list of tracks is kept; nil keeps it in memory (tests).
    init(cache: AudioStreamCache?, file: URL?) {
        self.cache = cache
        self.file = file
        entries = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    /// The cache's name for `song`'s recording, or nil for a file on this device (never cached).
    static func trackID(of song: Song) -> String? {
        if PlaybackSourceFactory.localFileURL(of: song) != nil { return nil }
        if let key = SourceRegistry.parseTrackKey(song.videoId) { return AudioCacheKey.source(key.configId, track: key.trackId).trackID }
        return song.videoId.isEmpty ? nil : song.videoId
    }

    /// Remembers tracks the cache is about to hold: the one that started, and the ones read ahead.
    /// The first is the most recent.
    func note(_ songs: [Song], at date: Date = Date()) {
        for (index, song) in songs.enumerated() {
            guard let id = Self.trackID(of: song) else { continue }
            // A track only read ahead doesn't outrank the last time it was actually played.
            let seenAt = date.addingTimeInterval(-TimeInterval(index))
            if index > 0, let known = entries[id], known.seenAt > seenAt { continue }
            entries[id] = Entry(song: song, seenAt: seenAt)
        }
        if entries.count > Self.limit {
            for id in entries.sorted(by: { $0.value.seenAt < $1.value.seenAt }).prefix(entries.count - Self.limit).map(\.key) {
                entries[id] = nil
            }
        }
        scheduleSave()
    }

    /// Where each row sits on the page for one visit. A row's place is its own (by video id), so
    /// two songs that share a title and credit never share one. The one exception is the fold in
    /// ``songs()``: a music video and the song it was converted to are one row, so when one
    /// replaces the other on the page it takes the place over (the old id gives it up).
    struct Places {
        fileprivate var byID: [String: Int] = [:]
        /// Per folded title and credit: the row that holds the place a fold partner may take over.
        fileprivate var byKey: [String: (id: String, isVideo: Bool)] = [:]
    }

    /// `fresh` in the order the page fixed while it is open. Every row seen during the visit keeps
    /// its place, recorded in `places` (which this extends): playing one, which makes it the most
    /// recent, doesn't move it; nor does one that leaves and comes back, or a video folded into its
    /// song. Rows never seen before go on top, newest first; on the first load that is all of them.
    static func ordered(_ fresh: [Song], places: inout Places) -> [Song] {
        let keys = fresh.map { folded($0.title) + "\u{1F}" + folded($0.artist) }
        let listed = Set(fresh.map(\.videoId))
        var unseen: [Int] = []
        for (index, song) in fresh.enumerated() where places.byID[song.videoId] == nil {
            // The fold's other half (a video for a song, a song for a video), no longer listed
            // itself: this row is that row, under its other id. A same-titled song that is not a
            // fold partner is simply new.
            if let partner = places.byKey[keys[index]], partner.isVideo != song.isVideo, !listed.contains(partner.id),
               let place = places.byID.removeValue(forKey: partner.id) {
                places.byID[song.videoId] = place
                places.byKey[keys[index]] = (song.videoId, song.isVideo)
            } else {
                unseen.append(index)
            }
        }
        let top = (places.byID.values.min() ?? 0) - unseen.count
        for (rank, index) in unseen.enumerated() {
            places.byID[fresh[index].videoId] = top + rank
            if places.byKey[keys[index]] == nil { places.byKey[keys[index]] = (fresh[index].videoId, fresh[index].isVideo) }
        }
        // Every row has a place by now (the loops above cover all of `fresh`); one that somehow
        // had none would sort last rather than jump to the top. Ties can't happen (a place has
        // one owner), and the offset keeps the sort deterministic regardless.
        return fresh.enumerated()
            .map { (song: $0.element, place: places.byID[$0.element.videoId] ?? .max, offset: $0.offset) }
            .sorted { ($0.place, $0.offset) < ($1.place, $1.offset) }
            .map(\.song)
    }

    /// The songs that play with no connection, most recent first (the page then holds its rows in
    /// place while open: ``ordered(_:places:)``).
    func songs() async -> [Song] {
        guard let cache else { return [] }
        // A download's own cache entry (`#download`) is the Downloads page's, not a played copy.
        // Per track, its whole copies; it is offered when the player would play one of them.
        var whole: [String: [AudioCacheKey]] = [:]
        for rendition in await cache.completeRenditions() where rendition.key.rendition != "download" {
            whole[rendition.key.trackID, default: []].append(rendition.key)
        }
        let downloads = savedSongs()
        let saved = Set(downloads.map(\.videoId))
        let atmos = atmosAllowed()
        let recent = entries
            .filter { id, entry in
                guard let keys = whole[id], !saved.contains(entry.song.videoId) else { return false }
                let pinned = isPinned(entry.song.videoId)
                return keys.contains { PlaybackSourceFactory.playsOffDisk($0, pinned: pinned, atmosAllowed: atmos) }
            }
            .values.sorted { $0.seenAt > $1.seenAt }
            .map(\.song)
        // A music video and its song version are both cached once one was converted to the other
        // (their lengths differ: a video runs longer). That pair is one row, the song. Only a
        // video with a non-video: two songs that share a title and credit are two rows. A video
        // whose song is downloaded is that row too, and it is the Downloads page's.
        let downloadedKeys = Set(downloads.filter { !$0.isVideo }.map(Self.foldKey))
        var listed: [Song] = []
        var firstRow: [String: Int] = [:]
        for song in recent {
            let key = Self.foldKey(song)
            if song.isVideo, downloadedKeys.contains(key) { continue }
            if let twin = firstRow[key], listed[twin].isVideo != song.isVideo {
                if listed[twin].isVideo { listed[twin] = song }
                continue
            }
            if firstRow[key] == nil { firstRow[key] = listed.count }
            listed.append(song)
        }
        return listed
    }

    private static func foldKey(_ song: Song) -> String {
        folded(song.title) + "\u{1F}" + folded(song.artist)
    }

    private static func folded(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Written a moment after the last change; a burst of skips is one write.
    private func scheduleSave() {
        guard file != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(2))) != nil else { return }
            await self?.flush()
        }
    }

    /// Writes now, off the main thread (the app going to the background, and tests). Writes are
    /// chained, each after the one before it, so an older snapshot can never land over a newer one.
    func flush() async {
        saveTask?.cancel()
        saveTask = nil
        guard let file else { return }
        let snapshot = entries
        let previous = writeTask
        let write = Task.detached(priority: .utility) {
            await previous?.value
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            // The listener's play history: unreadable until the device is first unlocked.
            try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        writeTask = write
        await write.value
    }
}

/// Feeds ``OfflineBackup`` each track that starts, with the ones the cache reads ahead behind it.
@MainActor
final class OfflineBackupObserver: PlaybackEventObserver {
    private let backup: OfflineBackup
    private let upcoming: () -> [Song]

    init(backup: OfflineBackup, upcoming: @escaping () -> [Song]) {
        self.backup = backup
        self.upcoming = upcoming
    }

    func playback(didStart song: Song, durationMs: Int64, isPlaying: Bool, previous: Song?, previousListened: Bool, previousPositionMs: Int64) {
        backup.note([song] + upcoming())
    }
}
