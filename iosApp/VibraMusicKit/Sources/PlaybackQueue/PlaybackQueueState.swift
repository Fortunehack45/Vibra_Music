import Foundation
import VibraMusicCore

/// The queue as the UI and the playback engine see it: an immutable value, republished by
/// ``PlaybackQueueController`` after every change.
///
/// ``songs`` is the whole timeline — up to ``QueueHistory/maxEntries`` played entries, the current
/// one, then everything still to come in the order it will play. Indices into it are what the
/// controller's jump, remove and move operations take.
///
/// The playhead is deliberately not here: it moves twice a second, everything here moves on a track
/// change, and carrying both in one observed value would invalidate every view that reads the queue
/// on every tick.
public struct PlaybackQueueState: Hashable, Sendable {
    public var songs: [Song]
    /// Index of the playing entry in ``songs``; 0 when the queue is empty.
    public var currentIndex: Int
    public var repeatMode: RepeatMode
    /// Whether the queue is currently held in shuffled order.
    public var shuffleEnabled: Bool

    public init(songs: [Song] = [], currentIndex: Int = 0, repeatMode: RepeatMode = .off, shuffleEnabled: Bool = false) {
        self.songs = songs
        self.currentIndex = currentIndex
        self.repeatMode = repeatMode
        self.shuffleEnabled = shuffleEnabled
    }

    public var isEmpty: Bool { songs.isEmpty }

    /// The playing entry, or nil when the queue is empty.
    public var currentSong: Song? { songs.indices.contains(currentIndex) ? songs[currentIndex] : nil }

    /// The entries still to come, in playing order.
    public var upcoming: ArraySlice<Song> {
        songs.indices.contains(currentIndex) ? songs[(currentIndex + 1)...] : []
    }

    /// Whether "next" has somewhere to go. Repeat-all wraps, so any non-empty queue has a next; repeat-one
    /// only governs what happens when a track finishes by itself, not where a skip goes.
    public var hasNext: Bool {
        guard !songs.isEmpty else { return false }
        return repeatMode == .all || currentIndex + 1 < songs.count
    }

    /// Whether "previous" has an entry to go back to (wrapping under repeat-all).
    public var hasPrevious: Bool {
        guard !songs.isEmpty else { return false }
        return repeatMode == .all || currentIndex > 0
    }

    /// The index "next" goes to, or nil. See ``hasNext``.
    public var nextIndex: Int? {
        guard hasNext else { return nil }
        return currentIndex + 1 < songs.count ? currentIndex + 1 : 0
    }

    /// The index "previous" goes to, or nil. See ``hasPrevious``.
    public var previousIndex: Int? {
        guard hasPrevious else { return nil }
        return currentIndex > 0 ? currentIndex - 1 : songs.count - 1
    }

    /// The entry that plays when the current one finishes by itself: the same one under repeat-one,
    /// else the next, else the top of the queue under repeat-all; nil when the queue ends there.
    /// What the engine reads ahead or crossfades into, and what
    /// ``PlaybackQueueController/trackDidFinish()`` moves to.
    public var finishTargetIndex: Int? {
        guard songs.indices.contains(currentIndex) else { return nil }
        if repeatMode == .one { return currentIndex }
        if currentIndex + 1 < songs.count { return currentIndex + 1 }
        return repeatMode == .all ? 0 : nil
    }

    /// The queue panel's rows: now playing, "Next in queue", "Next from …", "AutoPlay".
    public var sections: QueueSections { QueueSections(queue: songs, currentIndex: currentIndex) }

    /// Where the AutoPlay heading goes. See ``QueueSections/autoplaySectionStart(fromAutoplay:currentIndex:)``.
    public var autoplaySectionStart: Int {
        QueueSections.autoplaySectionStart(fromAutoplay: songs.map(\.fromAutoplay), currentIndex: currentIndex)
    }

    /// How many entries after the current one — what a party's 25-track upcoming limit counts.
    public var upcomingCount: Int { max(songs.count - (currentIndex + 1), 0) }
}

/// What the playback engine should do because the playing entry changed. Delivered through
/// ``PlaybackQueueController/onCurrentItemChange``.
public struct QueueItemChange: Hashable, Sendable {
    public enum Reason: Hashable, Sendable {
        /// A new queue replaced the old one (a tap on a song, album or playlist, a station, a party).
        case newQueue
        /// The restart snapshot or a stashed personal queue was installed; load it paused.
        case restored
        /// A queue row was chosen (in the app or from a system surface).
        case jump
        case skipNext
        case skipPrevious
        /// "Previous" more than 10 s into a track: back to its start rather than the previous track.
        case restartCurrent
        /// The previous track finished and the queue moved on by itself.
        case autoAdvance
        /// The track that finished plays again (repeat-one, or repeat-all over a one-entry queue).
        case repeatCurrent
        /// The playing entry was removed or replaced by a queue edit.
        case queueEdit
    }

    /// What the engine does with play/pause.
    public enum Playback: Hashable, Sendable {
        /// Start playing.
        case play
        /// Keep playing if it was playing, stay paused if it was paused.
        case keep
        /// Load it paused: a restored queue, a queue that ran out, or the sleep timer's
        /// "end of this track".
        case pause
    }

    /// The entry to load, or nil when the queue became empty (stop playback).
    public var song: Song?
    public var index: Int
    public var startPositionMs: Int64
    public var reason: Reason
    public var playback: Playback

    public init(song: Song?, index: Int, startPositionMs: Int64, reason: Reason, playback: Playback) {
        self.song = song
        self.index = index
        self.startPositionMs = startPositionMs
        self.reason = reason
        self.playback = playback
    }
}

/// The outcome of a queue edit the user asked for, for the UI's confirmation or refusal notice.
public enum QueueEditResult: Hashable, Sendable {
    /// Applied.
    case done
    /// `count` tracks were queued ("Song added to queue", "3 songs will play next").
    case added(count: Int)
    /// A listener in a party whose host has locked control: nothing changed.
    case refusedByHost
    /// A party already has `limit` tracks lined up after its current one.
    case partyQueueFull(limit: Int)
    /// Nothing to do: an index out of range, a drag across sections, an empty list.
    case ignored
}

/// The outcome of "Start radio".
public enum RadioStartResult: Hashable, Sendable {
    /// The station replaced the queue ("%@ radio started").
    case started(name: String)
    /// The radio couldn't be loaded or came back empty ("Couldn't load tracks"); the old queue is
    /// untouched.
    case failed
    /// A later play request or a queue change won while the radio loaded; nothing changed and
    /// nothing should be shown.
    case superseded
    case refusedByHost
    /// No ``AutoplayRadioSource`` is configured, or the track has no catalogue id to seed from.
    case unavailable
}

/// What happened when the playing track finished by itself. See
/// ``PlaybackQueueController/trackDidFinish()``.
public enum TrackFinishOutcome: Hashable, Sendable {
    /// Moved on to `index` (reported through ``PlaybackQueueController/onCurrentItemChange`` too).
    case advanced(index: Int)
    /// The same entry plays again from the start.
    case repeated
    /// Nothing follows: playback stops. AutoPlay may still append tracks, and the queue moves on
    /// to them by itself if it does.
    case ended
}
