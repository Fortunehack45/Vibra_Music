import Foundation

// Ports playback/QueueHistory.kt.

/// How much of the queue behind the playing track is kept.
public enum QueueHistory {
    /// Number of completed queue entries retained behind the current song.
    ///
    /// A real, bounded history in the queue rather than old rows merely hidden in the UI: the queue
    /// is persisted, mirrored to the lock screen and CarPlay, and walked on every edit, so letting
    /// completed entries accumulate made every one of those paths progressively more expensive.
    public static let maxEntries = 25

    /// How many entries at the head of the live queue are older than its history window.
    public static func trimCount(currentIndex: Int) -> Int {
        max(currentIndex - maxEntries, 0)
    }

    /// Entries bypassed when a listener chooses a later row directly from the queue.
    ///
    /// The current song is deliberately not included: it has actually been current, while the rows
    /// between it and `targetIndex` have never played. Backward jumps remove nothing, so revisiting
    /// history leaves the songs after it in the queue.
    public static func skippedByJump(currentIndex: Int, targetIndex: Int) -> Range<Int>? {
        targetIndex > currentIndex + 1 ? (currentIndex + 1)..<targetIndex : nil
    }

    /// Starts a new queue at the row the listener selected.
    ///
    /// Rows before it have not played in this session, so putting them behind the current item
    /// would make the player present them as history. They can still be reached by starting a new
    /// queue from one of those rows later.
    public static func startingAt<T>(_ items: [T], _ startIndex: Int) -> [T] {
        guard !items.isEmpty else { return [] }
        return Array(items.dropFirst(min(max(startIndex, 0), items.count - 1)))
    }
}
