import Foundation
import VibraMusicCore

// Ports QueueSource / ContextQueueResult from playback/QueueCoordinator.kt, the "Playing from"
// caption rule from ui/player/PlayerControls.kt (playbackOriginText) and the source fallbacks
// MainActivity.kt applies (`play`, `onOpenPlaybackSource`).

/// Where a queue or track was started from in the UI: the page, feed or search it came out of.
///
/// Stamped onto every entry of the queue it starts (``Song/playbackSource`` and friends), so Now
/// Playing can keep naming the origin after skips, edits and a restart.
public struct QueueSource: Hashable, Sendable {
    public var title: String
    public var type: PlaybackSourceType
    public var id: String?

    public init(title: String, type: PlaybackSourceType, id: String? = nil) {
        self.title = title
        self.type = type
        self.id = id
    }

    /// The source for entry points whose rows already carry their origin (MainActivity's `play`):
    /// the row's own source, else its album, else the generic queue label.
    ///
    /// The explicit sources are preferred where the caller knows one, because a track's album is
    /// not necessarily where it was played from.
    public static func inferred(from song: Song?, queueLabel: String) -> QueueSource {
        QueueSource(
            title: song?.playbackSource ?? song?.albumName ?? queueLabel,
            type: song?.playbackSourceType ?? .queue,
            id: song?.playbackSourceId
        )
    }

    /// Where tapping the "Playing from" caption goes back to (MainActivity's
    /// `onOpenPlaybackSource`): the entry's source page, else its album, else the queue.
    public static func playingFrom(_ song: Song, queueLabel: String) -> QueueSource {
        QueueSource(
            title: song.playbackSource ?? song.albumName ?? queueLabel,
            type: song.playbackSourceType ?? .queue,
            id: song.playbackSourceId
        )
    }
}

/// A context queue under construction: the timeline and the index of the track the user tapped.
public struct ContextQueueResult: Hashable, Sendable {
    public var timeline: [Song]
    public var startIndex: Int

    public init(timeline: [Song], startIndex: Int) {
        self.timeline = timeline
        self.startIndex = startIndex
    }
}

/// What the player is playing *out of*, for the caption above the artwork. The UI localises it:
/// "Played by %@", "Playing %@ Radio", "Playing from %@".
public enum PlaybackOrigin: Hashable, Sendable {
    /// A Listen Together member put this track on.
    case playedBy(String)
    /// An explicitly started station, named after its seed.
    case radio(String)
    /// The page, feed or queue the track came from.
    case playingFrom(String)

    /// The caption for `song`. A party's "played by" wins, then a station's name, then the source
    /// the entry carries, its album, and finally `queueLabel`.
    public static func of(_ song: Song, playedBy: String? = nil, queueLabel: String) -> PlaybackOrigin {
        if let playedBy { return .playedBy(playedBy) }
        if let radio = song.radioName { return .radio(radio) }
        return .playingFrom(song.playbackSource ?? song.albumName ?? queueLabel)
    }
}

extension Song {
    /// This song as an entry of the queue's `tier`.
    ///
    /// Invariant: ``Song/queueEntryId`` is assigned once, when the song first enters the queue, and
    /// never changes afterwards — across tier promotions, version swaps, persistence and restores.
    /// That is what lets shuffle restore an order and the queue UI keep a row's identity through a
    /// drag even when the same track is queued twice.
    public func asQueueEntry(_ tier: QueueTier) -> Song {
        var entry = self
        entry.queueTier = tier
        if entry.queueEntryId == nil {
            // Lowercased to match the form Android's UUID.toString() persists.
            entry.queueEntryId = UUID().uuidString.lowercased()
        }
        return entry
    }

    /// Stamps `source` onto this song as the place it was played from.
    func stamped(with source: QueueSource) -> Song {
        var song = self
        song.playbackSource = source.title
        song.playbackSourceType = source.type
        song.playbackSourceId = source.id
        return song
    }

    /// The id shuffle remembers an entry by: its queue entry, or its video id for entries from
    /// before entry ids existed.
    var shuffleIdentity: String { queueEntryId ?? videoId }

    /// A file on this device rather than a catalogue track: its whole identity is a local URI, so
    /// no other device (a party member) and no fresh session can find it by id.
    ///
    /// Android checks `content://` (MediaStore) and `file://`. `ipod-library://` is the iOS media
    /// library's equivalent of a MediaStore row (PORTING.md §4: MPMediaQuery replaces MediaStore).
    var isDeviceFile: Bool {
        videoId.hasPrefix("content://") || videoId.hasPrefix("file://") || videoId.hasPrefix("ipod-library://")
    }

    /// Whether an explicit station can be seeded from this track (PlaybackService's
    /// `canStartStation`): anything with a catalogue id, never a device file.
    var canStartStation: Bool {
        !videoId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isDeviceFile
    }
}
