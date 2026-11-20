import Foundation
import VibraMusicCore

// Ports the pure half of playback/QueueShuffle.kt and `queueStartIndex` from
// playback/PlayerConnection.kt. The stateful toggle lives on PlaybackQueueController.

/// Shuffle as an edit to the queue, not a playback mode.
///
/// A player-level shuffle leaves the queue exactly as it is and draws the next track from a hidden
/// random order, so the queue panel shows one running order while the player follows another — the
/// user sees the album listed in order and hears it jumping about. Toggling shuffle here rearranges
/// the queue itself and leaves playback strictly sequential: what the queue shows is what plays, in
/// that order. The order the queue was in beforehand is kept so the toggle can be undone.
///
/// User-queued tracks (USER_QUEUE) are never shuffled: they reflect deliberate intent and stay
/// pinned at the front. CONTEXT and AUTOPLAY tracks are shuffled among themselves.
///
/// Rearranging is worked out as a permutation of the upcoming stretch and applied to the queue in
/// one edit, which is where the size of the queue stops mattering.
public enum QueueShuffle {

    /// Shuffles `indices`, the positions of one queue section.
    public typealias Shuffler = @Sendable ([Int]) -> [Int]

    /// The system random shuffle.
    public static let randomShuffler: Shuffler = { $0.shuffled() }

    /// The order a queue should go in when it is started while shuffle is on: the track the user
    /// picked leads, the user queue follows untouched, then the context and AutoPlay sections each
    /// at random. Returns the ordered queue and the pre-shuffle order (entry ids) that turning
    /// shuffle off restores.
    public static func startingOrder(
        _ songs: [Song],
        startIndex: Int,
        shuffler: Shuffler = randomShuffler
    ) -> (queue: [Song], original: [String]) {
        guard !songs.isEmpty else { return ([], []) }
        let start = min(max(startIndex, 0), songs.count - 1)
        let original = songs.map(\.shuffleIdentity)
        let rest = songs.enumerated().filter { $0.offset != start }.map(\.element)
        let userQueue = rest.filter { $0.queueTier == .userQueue }
        let context = rest.filter { $0.queueTier == .context }
        let autoplay = rest.filter { $0.queueTier == .autoplay }
        let queue = [songs[start]]
            + userQueue
            + shuffler(Array(context.indices)).map { context[$0] }
            + shuffler(Array(autoplay.indices)).map { autoplay[$0] }
        return (queue, original)
    }

    /// Where each upcoming slot's new occupant stands now, as indices into `upcoming`, for turning
    /// shuffle on: USER_QUEUE in place at the front, then CONTEXT shuffled, then AUTOPLAY shuffled.
    public static func shuffledOrder(upcoming: [Song], shuffler: Shuffler = randomShuffler) -> [Int] {
        let user = upcoming.indices.filter { upcoming[$0].queueTier == .userQueue }
        let context = upcoming.indices.filter { upcoming[$0].queueTier == .context }
        let autoplay = upcoming.indices.filter { upcoming[$0].queueTier == .autoplay }
        return user
            + avoidIdentityShuffle(original: context, shuffled: shuffledSection(context, shuffler))
            + avoidIdentityShuffle(original: autoplay, shuffled: shuffledSection(autoplay, shuffler))
    }

    /// Randomises one section: `shuffler` permutes the section's own positions, which map back onto
    /// its queue indices.
    private static func shuffledSection(_ indices: [Int], _ shuffler: Shuffler) -> [Int] {
        shuffler(Array(indices.indices)).map { indices[$0] }
    }

    /// Never returns a section's unchanged order when at least two tracks can move. A mathematically
    /// valid identity shuffle is surprisingly common in short queues (one chance in two for two
    /// tracks), and reads exactly like the first tap was ignored.
    public static func avoidIdentityShuffle(original: [Int], shuffled: [Int]) -> [Int] {
        guard original.count > 1, shuffled == original else { return shuffled }
        return Array(shuffled.dropFirst()) + [shuffled[0]]
    }

    /// Where each of `upcoming` belongs once `original` is put back, as indices into `upcoming`.
    ///
    /// Each track still queued goes back to where it stood in the old order. Whatever is left over
    /// was queued after the shuffle and was never part of that order, so it keeps its place at the
    /// end. A track named by `original` that has since been removed is simply skipped.
    ///
    /// Written against a map of the positions each id holds rather than by searching `upcoming`
    /// once per entry, because the queues this runs on are playlists: a linear search per track is
    /// a million comparisons over a thousand-track queue, on the frame that handles the tap. A queue
    /// holding the same track twice hands its copies out in the order they stand in, which is what
    /// keeps both of them.
    public static func restoreOrder(upcoming: [String], original: [String]) -> [Int] {
        var positions: [String: [Int]] = [:]
        positions.reserveCapacity(upcoming.count)
        for (index, id) in upcoming.enumerated() {
            positions[id, default: []].append(index)
        }
        // A read cursor per id rather than removeFirst, which is linear on an Array.
        var cursors: [String: Int] = [:]
        var placed = [Bool](repeating: false, count: upcoming.count)
        var out: [Int] = []
        out.reserveCapacity(upcoming.count)
        for id in original {
            guard let slots = positions[id] else { continue }
            let cursor = cursors[id, default: 0]
            guard cursor < slots.count else { continue }
            cursors[id] = cursor + 1
            placed[slots[cursor]] = true
            out.append(slots[cursor])
        }
        for index in upcoming.indices where !placed[index] { out.append(index) }
        return out
    }

    /// `order` with the sections strictly maintained: USER_QUEUE, then CONTEXT, then AUTOPLAY.
    public static func sectioned(_ order: [Int], upcoming: [Song]) -> [Int] {
        order.filter { upcoming[$0].queueTier == .userQueue }
            + order.filter { upcoming[$0].queueTier == .context }
            + order.filter { upcoming[$0].queueTier == .autoplay }
    }

    /// Where playback starts in a newly started queue: the selected track is moved to the head
    /// when the queue is shuffled, so it starts there rather than at its unshuffled index.
    public static func queueStartIndex(requestedIndex: Int, itemCount: Int, shuffled: Bool) -> Int {
        shuffled ? 0 : min(max(requestedIndex, 0), max(itemCount - 1, 0))
    }
}
