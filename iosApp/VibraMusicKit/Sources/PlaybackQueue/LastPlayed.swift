import Foundation
import VibraMusicCore

// Ports playback/LastPlayed.kt onto Core's JSONFileStore.

/// The queue as it was when the app last ran: what restores playback after the process dies.
public struct LastPlayedSnapshot: Hashable, Sendable {
    public var songs: [Song]
    /// Index of the current entry in ``songs``; always valid.
    public var index: Int
    public var positionMs: Int64

    public init(songs: [Song], index: Int, positionMs: Int64) {
        self.songs = songs
        self.index = index
        self.positionMs = positionMs
    }
}

/// A bounded queue snapshot for restoring playback after the app is killed.
///
/// Queue contents are serialized only when the queue itself changes. The frequently changing index
/// and position are stored separately, in a file of their own, so progress sampling never walks or
/// serializes the song list. At most 25 previous entries, the current one and 50 upcoming ones are
/// kept, whatever the size of the live queue.
///
/// Writes mirror SharedPreferences' `apply`/`commit`: the ordinary saves are encoded on the caller
/// and written in order on a background queue; the `…Immediately` ones return once the data is on
/// disk. Reads wait for pending writes, so a load always sees the last save.
///
/// The write queue belongs to the directory, not to the instance: every store opened on the same
/// directory shares one, so a second store (a relaunched controller, the party stash's fallback
/// read) never reads the files while an earlier store's write to them is still pending, and two
/// stores' writes never interleave.
public final class LastPlayedStore: @unchecked Sendable {
    /// Upcoming entries kept after the current one.
    public static let keepAhead = 50

    static let queueFile = "last_played_queue.json"
    static let stateFile = "last_played_state.json"

    private let store: JSONFileStore
    private let writer: DispatchQueue
    private let lock = NSLock()
    /// Whether a queue is saved (or about to be). `savePlaybackState` needs this answered without
    /// touching the disk, from the progress loop.
    private var hasQueue: Bool

    public init(store: JSONFileStore) {
        self.store = store
        writer = Self.writeQueue(for: store.directory)
        hasQueue = writer.sync { store.exists(Self.queueFile) }
    }

    private static let writeQueuesLock = NSLock()
    nonisolated(unsafe) private static var writeQueues: [String: DispatchQueue] = [:]

    private static func writeQueue(for directory: URL) -> DispatchQueue {
        let key = directory.standardizedFileURL.resolvingSymlinksInPath().path
        return writeQueuesLock.withLock {
            if let queue = writeQueues[key] { return queue }
            let queue = DispatchQueue(label: "com.fortune.vibramusic.ios.PlaybackQueue.LastPlayed")
            writeQueues[key] = queue
            return queue
        }
    }

    /// The store the app uses: `Application Support/Vibra Music/Playback`.
    public static func standard() -> LastPlayedStore {
        LastPlayedStore(store: .applicationSupport("Playback"))
    }

    /// The slice of a queue of `size` entries, playing `index`, that is persisted: at most
    /// ``QueueHistory/maxEntries`` before the current entry and ``keepAhead`` after it.
    public static func window(size: Int, index: Int) -> Range<Int> {
        guard size > 0 else { return 0..<0 }
        let safe = min(max(index, 0), size - 1)
        let start = max(safe - QueueHistory.maxEntries, 0)
        return start..<min(safe + 1 + keepAhead, size)
    }

    /// Persists the bounded window of `songs` around `index`. An empty queue clears the snapshot.
    public func saveQueue(_ songs: [Song], index: Int) {
        guard let (queue, windowIndex) = encodeWindow(songs, index: index) else {
            if songs.isEmpty { clear() }
            return
        }
        setHasQueue(true)
        writer.async { [store] in
            self.write(queue, name: Self.queueFile, store: store)
            self.write(StoredState(index: windowIndex, positionMs: nil), name: Self.stateFile, store: store, merge: true)
        }
    }

    /// Atomically replaces the snapshot and returns once it is on disk.
    ///
    /// Used at an explicit queue boundary (a station just replaced the queue), where restoring the
    /// queue from before that boundary would be worse than the small cost of a synchronous write.
    public func saveQueueImmediately(_ songs: [Song], index: Int, positionMs: Int64) {
        guard let (queue, windowIndex) = encodeWindow(songs, index: index) else {
            if songs.isEmpty { clearImmediately() }
            return
        }
        setHasQueue(true)
        writer.sync {
            write(queue, name: Self.queueFile, store: store)
            write(StoredState(index: windowIndex, positionMs: max(positionMs, 0)), name: Self.stateFile, store: store)
        }
    }

    /// Updates only the index and position: no queue conversion or JSON of songs. Ignored while no
    /// queue is saved, so a stale position can't outlive the queue it belonged to.
    public func savePlaybackState(index: Int, positionMs: Int64) {
        guard currentHasQueue() else { return }
        let state = StoredState(index: max(index, 0), positionMs: max(positionMs, 0))
        writer.async { [store] in
            self.write(state, name: Self.stateFile, store: store)
        }
    }

    /// The saved snapshot, or nil when there is none or it can't be read.
    public func load() -> LastPlayedSnapshot? {
        writer.sync {
            guard let stored = try? store.load(StoredQueue.self, from: Self.queueFile),
                  !stored.tracks.isEmpty else { return nil }
            let state = try? store.load(StoredState.self, from: Self.stateFile)
            let index = state?.index ?? stored.index ?? 0
            let position = state?.positionMs ?? stored.positionMs ?? 0
            return LastPlayedSnapshot(
                songs: stored.tracks,
                index: min(max(index, 0), stored.tracks.count - 1),
                positionMs: max(position, 0)
            )
        }
    }

    public func clear() {
        setHasQueue(false)
        writer.async { [store] in
            try? store.remove(Self.queueFile)
            try? store.remove(Self.stateFile)
        }
    }

    /// Removes a stale queue before another one is installed, returning once it is gone.
    public func clearImmediately() {
        setHasQueue(false)
        writer.sync {
            try? store.remove(Self.queueFile)
            try? store.remove(Self.stateFile)
        }
    }

    /// Waits for every pending write. ``PlaybackQueueController/flushPersistence(positionMs:isPlaying:)``
    /// calls it when the app leaves the foreground; tests call it directly.
    public func flush() {
        writer.sync {}
    }

    // MARK: Encoding

    private struct StoredQueue: Codable {
        var tracks: [Song]
        /// Read only: snapshots written before the index and position moved to their own file.
        var index: Int?
        var positionMs: Int64?
    }

    private struct StoredState: Codable {
        var index: Int
        /// Nil keeps the position already on disk (a queue edit doesn't move the playhead).
        var positionMs: Int64?
    }

    private func encodeWindow(_ songs: [Song], index: Int) -> (StoredQueue, Int)? {
        guard !songs.isEmpty else { return nil }
        let safe = min(max(index, 0), songs.count - 1)
        let bounds = Self.window(size: songs.count, index: safe)
        return (StoredQueue(tracks: Array(songs[bounds])), safe - bounds.lowerBound)
    }

    private func write(_ queue: StoredQueue, name: String, store: JSONFileStore) {
        do {
            try store.save(queue, to: name)
        } catch {
            DebugLog.w("PlaybackQueue", "could not save the restart queue", error: error)
        }
    }

    private func write(_ state: StoredState, name: String, store: JSONFileStore, merge: Bool = false) {
        var state = state
        if merge, state.positionMs == nil {
            state.positionMs = (try? store.load(StoredState.self, from: name))?.positionMs
        }
        do {
            try store.save(state, to: name)
        } catch {
            DebugLog.w("PlaybackQueue", "could not save the restart position", error: error)
        }
    }

    private func setHasQueue(_ value: Bool) {
        lock.lock()
        hasQueue = value
        lock.unlock()
    }

    private func currentHasQueue() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasQueue
    }
}
