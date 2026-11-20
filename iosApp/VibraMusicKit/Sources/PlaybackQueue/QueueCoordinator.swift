import Foundation
import VibraMusicCore

// Ports playback/QueueCoordinator.kt, the queue-jump rule of PlaybackService's SessionPlayer.seekTo,
// and detectSingleMove from playback/PartySync.kt.

/// What ``QueueCoordinator/buildPartyPlaybackQueue(tappedSong:source:upcomingPartyTracks:)`` needs
/// from an entry of a Listen Together party's shared queue.
///
/// Declared here because PlaybackQueue does not depend on ListenTogether. `Song` conforms (its tier
/// says whether AutoPlay queued it); the app makes ListenTogether's `PartyTrack` conform with
/// `asQueueSong()` returning its `toSong()` (manual tracks as `.userQueue`, AutoPlay's as `.autoplay`).
public protocol PartyQueueEntry {
    /// Whether AutoPlay, rather than a member, queued this track.
    var fromAutoplay: Bool { get }
    /// The entry as a queue song.
    func asQueueSong() -> Song
}

extension Song: PartyQueueEntry {
    public func asQueueSong() -> Song { self }
}

/// Headless orchestrator for the two-tier, Spotify-style queue: timeline construction, tier
/// assignment, queue-entry identity, and the user-queue pruning invariants.
///
/// Everything here is a pure function of a timeline (the whole queue, history included) and the
/// index of the playing entry. ``PlaybackQueueController`` applies the results.
public enum QueueCoordinator {

    /// Constructs an interleaved queue for starting a context (album, playlist, artist):
    ///
    /// Invariant: [preceding context] + [selected track] + [preserved USER_QUEUE] + [following context].
    /// Playback starts at `startIndex` (= the preceding context's size). Preceding tracks stay in
    /// history for backward navigation and loop around under repeat-all.
    public static func buildContextQueue(
        currentTimeline: [Song],
        currentIndex: Int,
        newContextSongs: [Song],
        selectedIndex: Int,
        contextSource: QueueSource
    ) -> ContextQueueResult {
        guard !newContextSongs.isEmpty else { return ContextQueueResult(timeline: [], startIndex: 0) }

        let upcomingUserQueue = upcomingUserQueue(currentTimeline, currentIndex)
        let contextEntries = newContextSongs.map { $0.stamped(with: contextSource).asQueueEntry(.context) }

        let safeIndex = min(max(selectedIndex, 0), contextEntries.count - 1)
        let preceding = contextEntries[..<safeIndex]
        let selected = contextEntries[safeIndex]
        let following = contextEntries[(safeIndex + 1)...]

        return ContextQueueResult(
            timeline: Array(preceding) + [selected] + upcomingUserQueue + Array(following),
            startIndex: preceding.count
        )
    }

    /// Constructs a queue for playing a one-off song (from Search, Home, Explore):
    ///
    /// Invariant: [tapped track] + [preserved USER_QUEUE].
    public static func buildOneOffQueue(
        currentTimeline: [Song],
        currentIndex: Int,
        tappedSong: Song,
        source: QueueSource
    ) -> [Song] {
        [tappedSong.stamped(with: source).asQueueEntry(.context)] + upcomingUserQueue(currentTimeline, currentIndex)
    }

    /// Constructs a single-song playback timeline for Listen Together:
    ///
    /// Invariant: [tapped track (CONTEXT)] + [upcoming canonical manual party tracks (USER_QUEUE)].
    /// The album or playlist around the tapped track is excluded from the shared queue, and stale
    /// AutoPlay recommendations from the previous track are dropped.
    public static func buildPartyPlaybackQueue<Entry: PartyQueueEntry>(
        tappedSong: Song,
        source: QueueSource,
        upcomingPartyTracks: [Entry]
    ) -> [Song] {
        let entry = tappedSong.stamped(with: source).asQueueEntry(.context)
        let manualUpcoming = upcomingPartyTracks
            .filter { !$0.fromAutoplay }
            .map { $0.asQueueSong().asQueueEntry(.userQueue) }
        return [entry] + manualUpcoming
    }

    /// Where user-queued tracks go.
    ///
    /// - "Play next" (`isNext`) inserts at the head of USER_QUEUE, immediately after the current entry.
    /// - "Add to queue" inserts at the tail of USER_QUEUE, ahead of CONTEXT and AUTOPLAY: a song asked
    ///   for by name outranks whatever the album or AutoPlay lined up behind it.
    public static func findUserQueueInsertionIndex(timeline: [Song], currentIndex: Int, isNext: Bool) -> Int {
        guard !timeline.isEmpty else { return 0 }
        let start = min(max(currentIndex + 1, 0), timeline.count)
        if isNext { return start }
        for index in start..<timeline.count where timeline[index].queueTier != .userQueue {
            return index
        }
        return timeline.count
    }

    /// Indices of the upcoming USER_QUEUE entries — the ones "Clear" removes.
    ///
    /// Invariant: CONTEXT and AUTOPLAY entries are untouched.
    public static func userQueueIndicesToClear(timeline: [Song], currentIndex: Int) -> [Int] {
        guard !timeline.isEmpty, currentIndex + 1 < timeline.count else { return [] }
        return (max(currentIndex + 1, 0)..<timeline.count).filter { timeline[$0].queueTier == .userQueue }
    }

    /// Indices of played USER_QUEUE entries to prune once playback has moved into CONTEXT.
    ///
    /// Invariant: once playback leaves the USER_QUEUE block and enters CONTEXT, the consumed
    /// USER_QUEUE entries behind it go, so repeat-all only ever cycles through CONTEXT items.
    public static func playedUserQueueIndices(timeline: [Song], currentIndex: Int) -> [Int] {
        guard currentIndex > 0, currentIndex < timeline.count,
              timeline[currentIndex].queueTier == .context else { return [] }
        return (0..<currentIndex).filter { timeline[$0].queueTier == .userQueue }
    }

    /// Reconstructs the upcoming queue when a listener taps a row in the queue panel.
    ///
    /// 1. A target at or before the current entry, or either index out of bounds, returns nil: that
    ///    is a backward jump or a tap on the playing row, handled as a plain seek.
    /// 2. AUTOPLAY target: it becomes the playing entry, promoted to CONTEXT (a fresh station). Every
    ///    future USER_QUEUE entry follows it, then the AutoPlay entries after it. The old context and
    ///    the AutoPlay entries jumped over are discarded.
    /// 3. CONTEXT target: it becomes the playing entry, every future USER_QUEUE entry follows, then
    ///    the context after the target, then the AutoPlay after it. Context jumped over is discarded.
    /// 4. USER_QUEUE target: user-queued entries between the current one and the target were
    ///    bypassed within the manual queue and are consumed. Later USER_QUEUE entries and all future
    ///    CONTEXT and AUTOPLAY entries are kept.
    public static func buildJumpQueue(currentTimeline: [Song], currentIndex: Int, targetIndex: Int) -> [Song]? {
        guard currentTimeline.indices.contains(currentIndex),
              currentTimeline.indices.contains(targetIndex),
              targetIndex > currentIndex else { return nil }

        let target = currentTimeline[targetIndex]
        let future = currentTimeline[(currentIndex + 1)...]
        let afterTarget = currentTimeline[(targetIndex + 1)...]
        let allFutureUserQueue = future.filter { $0.queueTier == .userQueue }
        // Only what the jump skipped over is dropped; AutoPlay lined up past the target stays, or
        // tapping any row above it would empty the AutoPlay list.
        let remainingAutoplay = afterTarget.filter { $0.queueTier == .autoplay }

        switch target.queueTier {
        case .autoplay:
            var promoted = target
            let source = target.playbackSource.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            promoted.playbackSource = source ?? target.title
            promoted.playbackSourceType = target.playbackSourceType ?? .queue
            return [promoted.asQueueEntry(.context)] + allFutureUserQueue + remainingAutoplay
        case .context:
            let remainingContext = afterTarget.filter { $0.queueTier == .context }
            return [target] + allFutureUserQueue + remainingContext + remainingAutoplay
        case .userQueue:
            let subsequentUserQueue = afterTarget.filter { $0.queueTier == .userQueue }
            let futureContext = future.filter { $0.queueTier == .context }
            let futureAutoplay = future.filter { $0.queueTier == .autoplay }
            return [target] + subsequentUserQueue + futureContext + futureAutoplay
        }
    }

    /// The whole timeline after a tap on queue row `targetIndex` (Android's `jumpToQueueItem`), and
    /// where playback lands in it.
    ///
    /// Backward or same-row taps seek within the queue as it is. A forward tap keeps history up to
    /// and including the current entry, so backward navigation still works, and replaces everything
    /// after it with ``buildJumpQueue(currentTimeline:currentIndex:targetIndex:)``. Nil when
    /// `targetIndex` is out of range.
    public static func jumpPlan(timeline: [Song], currentIndex: Int, targetIndex: Int) -> ContextQueueResult? {
        guard timeline.indices.contains(targetIndex) else { return nil }
        if targetIndex <= currentIndex {
            return ContextQueueResult(timeline: timeline, startIndex: targetIndex)
        }
        guard let upcoming = buildJumpQueue(currentTimeline: timeline, currentIndex: currentIndex, targetIndex: targetIndex) else {
            return nil
        }
        let history = Array(timeline[...currentIndex])
        return ContextQueueResult(timeline: history + upcoming, startIndex: history.count)
    }

    /// A jump to queue row `targetIndex` requested by a system surface (the session's
    /// `seekTo(index)` on Android: the notification, a headset, Android Auto — CarPlay and the lock
    /// screen on iOS), which goes through a different rule than an in-app tap.
    ///
    /// The rows between the current entry and the target are bypassed. Jumping to a USER_QUEUE row
    /// consumes only the USER_QUEUE rows it skipped; jumping to any other tier must never delete a
    /// USER_QUEUE row, so it drops only the non-user rows skipped. Whatever was kept still sits
    /// between the playhead and the target; seeking past it would leave it behind the playhead,
    /// where ``playedUserQueueIndices(timeline:currentIndex:)`` deletes it on the next transition,
    /// so the target moves up to play next instead, with the kept rows following it — the same
    /// order an in-app tap gives.
    public static func systemSeekPlan(timeline: [Song], currentIndex: Int, targetIndex: Int) -> ContextQueueResult? {
        guard timeline.indices.contains(targetIndex) else { return nil }
        guard let skipped = QueueHistory.skippedByJump(currentIndex: currentIndex, targetIndex: targetIndex) else {
            return ContextQueueResult(timeline: timeline, startIndex: targetIndex)
        }
        let targetTier = timeline[targetIndex].queueTier
        let removable = skipped.filter { index in
            let tier = timeline[index].queueTier
            return targetTier == .userQueue ? tier == .userQueue : tier != .userQueue
        }
        var result = timeline
        for index in removable.reversed() { result.remove(at: index) }
        var newTarget = targetIndex - removable.filter { $0 < targetIndex }.count
        let next = currentIndex + 1
        if newTarget > next {
            let moved = result.remove(at: newTarget)
            result.insert(moved, at: next)
            newTarget = next
        }
        return ContextQueueResult(timeline: result, startIndex: newTarget)
    }

    /// A single row moved from `fromIndex` to `toIndex` (both offset by the `baseOffset` the lists
    /// were cut from), and which track it was.
    public struct MoveDelta: Hashable, Sendable {
        public var fromIndex: Int
        public var toIndex: Int
        public var videoId: String

        public init(fromIndex: Int, toIndex: Int, videoId: String) {
            self.fromIndex = fromIndex
            self.toIndex = toIndex
            self.videoId = videoId
        }
    }

    /// Whether `newList` is `oldList` with exactly one item moved (PartySync's `detectSingleMove`):
    /// the move, offset by `baseOffset`, or nil when the lists can't be explained by a single move.
    /// A party publishes a drag as one move rather than as a whole new queue.
    public static func detectSingleMove(oldList: [String], newList: [String], baseOffset: Int = 0) -> MoveDelta? {
        guard oldList.count == newList.count, oldList != newList, !oldList.isEmpty else { return nil }
        func counts(_ list: [String]) -> [String: Int] { list.reduce(into: [:]) { $0[$1, default: 0] += 1 } }
        guard counts(oldList) == counts(newList) else { return nil }

        for from in oldList.indices {
            let item = oldList[from]
            var without = oldList
            without.remove(at: from)
            for to in oldList.indices where to != from {
                var simulated = without
                simulated.insert(item, at: to)
                if simulated == newList {
                    return MoveDelta(fromIndex: baseOffset + from, toIndex: baseOffset + to, videoId: item)
                }
            }
        }
        return nil
    }

    // MARK: Helpers

    /// The USER_QUEUE entries still to come, which every new queue preserves.
    static func upcomingUserQueue(_ timeline: [Song], _ currentIndex: Int) -> [Song] {
        guard timeline.indices.contains(currentIndex) else { return [] }
        return timeline[(currentIndex + 1)...].filter { $0.queueTier == .userQueue }
    }
}
