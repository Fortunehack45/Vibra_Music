import Foundation
import Observation
import VibraMusicCore

// Ports download/DownloadSession.kt.

/// Where one track in the manager's list has got to.
public enum DownloadProgress: Hashable, Sendable {
    case queued
    /// `fraction` is 0 until the length is known, which is one request in.
    case running(fraction: Double)
    case done
    case failed(reason: String)

    /// Neither waiting nor coming back — nothing left for the user to watch.
    public var settled: Bool {
        switch self {
        case .done, .failed: return true
        case .queued, .running: return false
        }
    }
}

/// Everything downloaded since the app was opened, and whether the user has looked at it yet.
///
/// The gap this fills is between ``DownloadManager/active`` and the ``DownloadLibrary``. `active` is
/// only ever what is happening *right now* — a track leaves it the instant it finishes, which is
/// exactly the instant the user most wants to know about it — and the library is every file this
/// app has ever written, with nothing to distinguish the album from twenty minutes ago from one from
/// last March. Neither can answer "did the thing I asked for actually all arrive?", and that is the
/// only question a download manager exists to answer.
///
/// Deliberately not persisted. This is a record of one sitting: after a restart what is on disk is
/// the whole truth and the Downloads page is where to read it. (Jobs the queue resumes after a
/// relaunch re-announce themselves through ``queued(_:from:)``.)
///
/// ### Why ``State/visible`` is not just "something is downloading"
///
/// A download is the one thing in this app a user starts and walks away from, so the moment it
/// finishes is a moment nobody is watching. So the indicator stays up until it has been *seen*, and
/// "seen" is compared against when the queue last went quiet rather than being a flag that is set
/// once. Look in halfway, close the sheet, and the last track landing afterwards puts the indicator
/// back — because the thing being confirmed is the *outcome*, and the outcome hadn't happened yet.
@MainActor
@Observable
public final class DownloadSession {
    public struct Item: Hashable, Sendable, Identifiable {
        /// The id the *tap* used, which is what everything else here is keyed by.
        public var videoId: String
        public var song: Song
        public var progress: DownloadProgress
        /// What release this was part of, when it was part of one.
        public var from: String?
        /// Ask order, so the list reads the way the queue drains.
        public var sequence: Int64

        public var id: String { videoId }
    }

    public struct State: Hashable, Sendable {
        public var items: [Item] = []
        /// When the user last had the manager open, on the session's logical clock.
        public var seenAt: Int64 = 0
        /// When the last thing in the queue stopped moving, on the same clock.
        public var settledAt: Int64 = 0

        public init(items: [Item] = [], seenAt: Int64 = 0, settledAt: Int64 = 0) {
            self.items = items
            self.seenAt = seenAt
            self.settledAt = settledAt
        }

        public var waiting: Int { items.count { !$0.progress.settled } }
        public var finished: Int { items.count { $0.progress == .done } }
        public var failed: Int {
            items.count {
                if case .failed = $0.progress { return true }
                return false
            }
        }

        /// Whether anything is still queued or running.
        public var busy: Bool { waiting > 0 }

        /// How far through the whole batch this is, counting a settled track as a whole one
        /// whichever way it settled — a failure is not progress, but it is finished, and a bar that
        /// can never fill because one track died reads as a download that is still going.
        public var fraction: Double {
            guard !items.isEmpty else { return 0 }
            let total = items.reduce(0.0) { sum, item in
                switch item.progress {
                case .running(let fraction): return sum + fraction
                case .queued: return sum
                case .done, .failed: return sum + 1
                }
            }
            return min(max(total / Double(items.count), 0), 1)
        }

        /// See the class comment: not "is downloading" but "is unaccounted for".
        public var visible: Bool { !items.isEmpty && (busy || seenAt < settledAt) }
    }

    public private(set) var state = State()

    /// A logical clock, shared by the ask order and the two timestamps.
    ///
    /// Not a wall clock: these values are only ever compared with each other, and a wall clock can
    /// be set backwards by the user or an NTP correction. A counter starting at zero can't.
    /// Main-actor isolation replaces Android's atomics and compare-and-set updates: every writer is
    /// on one actor, so there is no lost update to guard against.
    @ObservationIgnored private var clock: Int64 = 0

    public init() {}

    private func tick() -> Int64 {
        clock += 1
        return clock
    }

    /// A track has been accepted into the queue — or refused before it got there, which is still
    /// something the user asked for and is owed an answer about.
    ///
    /// Re-asking for a track already in the list resets it rather than adding a second row: a
    /// failed download retried from the manager is the same errand, and two rows for one song would
    /// leave the failure on screen next to its own retry.
    public func queued(_ song: Song, from: String? = nil) {
        var items = state.items
        if let existing = items.firstIndex(where: { $0.videoId == song.videoId }) {
            items[existing] = Item(
                videoId: song.videoId,
                song: song,
                progress: .queued,
                from: from ?? items[existing].from,
                sequence: items[existing].sequence
            )
        } else {
            items.append(Item(videoId: song.videoId, song: song, progress: .queued, from: from, sequence: tick()))
        }
        // Not settledAt: nothing has settled. But a new ask does mean the batch the user last
        // signed off on is no longer the batch in hand.
        state.items = items
    }

    public func running(_ videoId: String, fraction: Double) {
        set(videoId, .running(fraction: fraction))
    }

    public func done(_ videoId: String) {
        set(videoId, .done)
    }

    public func failed(_ videoId: String, reason: String) {
        set(videoId, .failed(reason: reason))
    }

    /// Swap in the track that is actually being fetched: a correction to a row, not a new one.
    public func retitle(_ videoId: String, song: Song) {
        guard let index = state.items.firstIndex(where: { $0.videoId == videoId }) else { return }
        state.items[index].song = song
    }

    /// Drop a row entirely — a download the user called off.
    public func forget(_ videoId: String) {
        let items = state.items.filter { $0.videoId != videoId }
        guard items.count != state.items.count else { return }
        // Removing the last unsettled row is the queue going quiet, and it has to count as such or
        // the indicator would linger over a list that no longer has anything in it to report.
        let quiet = !items.contains { !$0.progress.settled }
        state = State(items: items, seenAt: state.seenAt, settledAt: quiet ? tick() : state.settledAt)
    }

    /// The user has the manager open — see ``State/visible``.
    public func markSeen() {
        state.seenAt = tick()
    }

    /// Empty the list outright, at the user's request.
    public func clear() {
        state = State()
    }

    /// The row for `videoId`, if the sitting has one.
    public func item(_ videoId: String) -> Item? {
        state.items.first { $0.videoId == videoId }
    }

    private func set(_ videoId: String, _ progress: DownloadProgress) {
        guard let index = state.items.firstIndex(where: { $0.videoId == videoId }) else { return }
        var items = state.items
        items[index].progress = progress
        // Only the *last* one settling closes the batch off. Marking each one would have a
        // forty-track album go quiet thirty-nine times.
        let quiet = !items.contains { !$0.progress.settled }
        let settledAt = progress.settled && quiet ? tick() : state.settledAt
        state = State(items: items, seenAt: state.seenAt, settledAt: settledAt)
    }
}
