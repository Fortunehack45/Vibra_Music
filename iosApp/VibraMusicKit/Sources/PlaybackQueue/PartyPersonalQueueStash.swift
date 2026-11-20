import Foundation
import VibraMusicCore

// Ports playback/PartyPersonalQueueStash.kt onto Core's JSONFileStore.

/// The user's own queue, index, playhead and playing state, put aside while they are in a Listen
/// Together party and given back when they leave.
///
/// On disk rather than in memory so the personal queue survives the app being killed mid-party:
/// ``PlaybackQueueController/restore()`` prefers a stash over the ordinary restart snapshot.
public final class PartyPersonalQueueStash: @unchecked Sendable {

    public struct Snapshot: Hashable, Sendable {
        public var songs: [Song]
        public var index: Int
        public var positionMs: Int64
        public var wasPlaying: Bool

        public init(songs: [Song], index: Int, positionMs: Int64, wasPlaying: Bool) {
            self.songs = songs
            self.index = index
            self.positionMs = positionMs
            self.wasPlaying = wasPlaying
        }
    }

    static let fileName = "party_queue_stash.json"

    private let store: JSONFileStore
    private let lock = NSLock()

    public init(store: JSONFileStore) {
        self.store = store
    }

    /// The stash the app uses: `Application Support/Vibra Music/Playback`.
    public static func standard() -> PartyPersonalQueueStash {
        PartyPersonalQueueStash(store: .applicationSupport("Playback"))
    }

    /// Stashes the live queue on entering a party. Returns whether anything was stashed.
    ///
    /// Files on this device are left out: the party can't play them, and they would be the wrong
    /// thing to come back to at the wrong index. An empty queue falls back to the restart snapshot
    /// in `lastPlayed`, stashed as paused, so a user who joins from a cold start still gets their
    /// queue back.
    @discardableResult
    public func stash(
        queue songs: [Song],
        currentIndex: Int,
        positionMs: Int64,
        wasPlaying: Bool,
        lastPlayed: LastPlayedStore?
    ) -> Bool {
        // The restart snapshot is filtered like a live queue: it can hold device files too.
        var songs = songs, currentIndex = currentIndex, positionMs = positionMs, wasPlaying = wasPlaying
        if songs.isEmpty {
            guard let fallback = lastPlayed?.load() else { return false }
            songs = fallback.songs
            currentIndex = fallback.index
            positionMs = fallback.positionMs
            wasPlaying = false
        }
        let kept = songs.filter { !$0.isDeviceFile }
        guard !kept.isEmpty else { return false }
        // Android clamps the live index into the filtered list, which points at the wrong song when
        // device files sat before the current one. Counting the kept entries ahead of it lands on
        // the current entry itself (or, if that was a device file, on the one that followed it).
        let keptBefore = songs.prefix(max(currentIndex, 0)).filter { !$0.isDeviceFile }.count
        stash(
            songs: kept,
            index: min(keptBefore, kept.count - 1),
            positionMs: max(positionMs, 0),
            wasPlaying: wasPlaying
        )
        return true
    }

    /// Writes `songs` as the stash, synchronously. An empty list stashes nothing.
    public func stash(songs: [Song], index: Int, positionMs: Int64, wasPlaying: Bool) {
        guard !songs.isEmpty else { return }
        let stored = StoredQueue(
            tracks: songs,
            index: min(max(index, 0), songs.count - 1),
            positionMs: max(positionMs, 0),
            wasPlaying: wasPlaying
        )
        lock.withLock {
            do {
                try store.save(stored, to: Self.fileName)
            } catch {
                DebugLog.w("PlaybackQueue", "could not stash the personal queue", error: error)
            }
        }
    }

    public func hasStash() -> Bool {
        lock.withLock { store.exists(Self.fileName) }
    }

    /// The stashed queue, or nil when there is none or it can't be read.
    public func load() -> Snapshot? {
        guard let stored = lock.withLock({ try? store.load(StoredQueue.self, from: Self.fileName) }),
              !stored.tracks.isEmpty else { return nil }
        return Snapshot(
            songs: stored.tracks,
            index: min(max(stored.index, 0), stored.tracks.count - 1),
            positionMs: max(stored.positionMs, 0),
            wasPlaying: stored.wasPlaying
        )
    }

    public func clear() {
        lock.withLock { try? store.remove(Self.fileName) }
    }

    private struct StoredQueue: Codable {
        var tracks: [Song]
        var index: Int
        var positionMs: Int64
        var wasPlaying: Bool

        init(tracks: [Song], index: Int, positionMs: Int64, wasPlaying: Bool) {
            self.tracks = tracks
            self.index = index
            self.positionMs = positionMs
            self.wasPlaying = wasPlaying
        }

        // Lenient like Android's `Json { ignoreUnknownKeys }` with defaults: only the tracks are required.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tracks = try c.decode([Song].self, forKey: .tracks)
            index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
            positionMs = try c.decodeIfPresent(Int64.self, forKey: .positionMs) ?? 0
            wasPlaying = try c.decodeIfPresent(Bool.self, forKey: .wasPlaying) ?? false
        }
    }
}
