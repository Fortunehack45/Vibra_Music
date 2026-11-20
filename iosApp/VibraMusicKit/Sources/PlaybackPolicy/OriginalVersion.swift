import Foundation
import Observation
import VibraMusicCore

// Ports playback/OriginalVersion.kt.

/// The tracks the listener has sent back to YouTube's own upload by hand, and wants kept there.
///
/// "Revert to original" used to be a fact about one queue entry: the item was replaced with a
/// direct-YouTube one and that was the end of it. Play the same song again tomorrow, or come back
/// round to it in the queue, and the substitution and upgrade machinery started over and put the
/// listener right back on the copy they had just rejected. A revert is the listener saying this
/// catalogue match is wrong for this song, and the only useful lifetime for that is "until they say
/// otherwise".
///
/// So it is written down (`UserDefaults`), and ``PlaybackURI/forStreaming(_:pinnedToOriginal:)``
/// reads it wherever a queue entry is built — from a list, from CarPlay, from the restored queue — so
/// a pinned track is built as the direct-YouTube item it was reverted to. That covers a relaunch,
/// which an in-memory set would miss.
///
/// "Upgrade quality" in the player's menu is the way back out (``QualityUpgrade/requestByHand(_:nowMs:upgradeRunning:originalVersion:)``).
/// Nothing else clears an entry: an upgrade the app decided on by itself must not overturn one the
/// listener asked for.
///
/// Observable (``pinned``) for the menu, and safe to call from any thread.
public final class OriginalVersion: Observable, @unchecked Sendable {
    /// The app's instance, over `UserDefaults.standard`.
    public static let shared = OriginalVersion(defaults: .standard)

    /// Where the pins are stored. Android kept them in their own preferences file
    /// (`vibramusic_original_versions`, key `pinned`); they are not part of the settings backup there
    /// either.
    public static let defaultsKey = "vibramusic_original_versions.pinned"

    /// A cap only so the list doesn't grow for the life of the install; nobody reverting songs by
    /// hand reaches it. Oldest first out, because the newest entry is the one just made.
    public static let maxPinned = 500

    private let defaults: UserDefaults?
    private let key: String
    private let lock = NSLock()
    /// Insertion order is what the cap evicts by, which is why this is an array on disk rather than
    /// a set (a stored set comes back in no particular order).
    private var ordered: [String] = []
    private var members: Set<String> = []
    private let registrar = ObservationRegistrar()

    /// - Parameter defaults: where pins persist; nil keeps them in memory only, for as long as the
    ///   instance lives (tests, previews).
    public init(defaults: UserDefaults?, key: String = OriginalVersion.defaultsKey) {
        self.defaults = defaults
        self.key = key
        load()
    }

    /// Which tracks are pinned, for a menu that has to offer the right row. Observable.
    public var pinned: Set<String> {
        registrar.access(self, keyPath: \.pinned)
        return lock.withLock { members }
    }

    /// The pins oldest first.
    public var pinnedInOrder: [String] {
        registrar.access(self, keyPath: \.pinned)
        return lock.withLock { ordered }
    }

    public func isPinned(_ videoId: String?) -> Bool {
        guard let videoId else { return false }
        registrar.access(self, keyPath: \.pinned)
        return lock.withLock { members.contains(videoId) }
    }

    /// Keeps `videoId` on YouTube's own upload for every play from here on.
    public func pin(_ videoId: String) {
        guard !videoId.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let changed: Bool = lock.withLock {
            guard !members.contains(videoId) else { return false }
            var next = ordered + [videoId]
            if next.count > Self.maxPinned { next.removeFirst(next.count - Self.maxPinned) }
            store(next)
            return true
        }
        if changed { announce() }
    }

    /// Lets `videoId` be substituted and upgraded again.
    public func unpin(_ videoId: String) {
        let changed: Bool = lock.withLock {
            guard members.contains(videoId) else { return false }
            store(ordered.filter { $0 != videoId })
            return true
        }
        if changed { announce() }
    }

    /// Pins `song` to its YouTube upload if a revert applies to it, and returns the URI its queue
    /// entry should be replaced with (then seek to the same position and keep playing). Nil when
    /// there is nothing to revert: no YouTube upload behind it, a file the listener saved, or a
    /// track already pinned. Android's `PlaybackService.revertCurrentToOriginal`, minus the player.
    @discardableResult
    public func revert(_ song: Song) -> String? {
        guard PlaybackFallback.hasYouTubeOriginal(song), song.localUri == nil, !isPinned(song.videoId) else {
            return nil
        }
        pin(song.videoId)
        return PlaybackURI.directYouTube(for: song)
    }

    /// Re-reads the pins from storage (after a restore, or another process writing).
    public func reload() {
        lock.withLock { load() }
        announce()
    }

    /// Called with the lock held (or from init).
    private func load() {
        let stored = defaults?.stringArray(forKey: key) ?? []
        var seen = Set<String>()
        ordered = stored.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && seen.insert($0).inserted }
        members = seen
    }

    /// Called with the lock held. The in-memory value is updated either way, so an instance without
    /// storage still behaves for as long as it lasts.
    private func store(_ ids: [String]) {
        ordered = ids
        members = Set(ids)
        defaults?.set(ids, forKey: key)
    }

    private func announce() {
        onMainThread { [self] in registrar.withMutation(of: self, keyPath: \.pinned) {} }
    }
}
