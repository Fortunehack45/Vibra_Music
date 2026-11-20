import Foundation
import VibraMusicCore

// Ports the queue-panel model from ui/player/PlayerQueue.kt (splitQueue, QueueTrack, QueueSection,
// the "Next from …" heading and the drag rules), `autoplaySectionStart` from
// playback/PlayerConnection.kt and `edgeScrollSpeed` from PlayerQueue.kt. The SwiftUI view that
// draws them belongs to the app.

/// The groups a queue row can be dragged within; a drag never leaves its own.
public enum QueueSection: String, Hashable, Sendable, CaseIterable {
    /// "Next in queue": tracks the user queued by hand.
    case user
    /// "Next from <album>": the rest of the album, playlist or station.
    case context
    /// "AutoPlay": suggestions.
    case autoplay

    public init(tier: QueueTier) {
        switch tier {
        case .userQueue: self = .user
        case .context: self = .context
        case .autoplay: self = .autoplay
        }
    }
}

/// One row of the queue panel, and where it sits in the timeline.
public struct QueueRow: Hashable, Sendable, Identifiable {
    /// Index in ``PlaybackQueueState/songs`` — what jump, remove and move take.
    public var timelineIndex: Int
    public var song: Song
    /// Stable identity for `ForEach`: the entry's own id, so a row keeps it through a reorder.
    /// Entries without one (a party's tracks, a queue restored from before ids existed) fall back to
    /// the song plus how many times it has come up so far — never its position, which changes on
    /// every swap and would end the drag.
    public var key: String
    public var id: String { key }
}

/// The queue as the panel lists it: what's playing, then each section in running order.
public struct QueueSections: Hashable, Sendable {
    public var nowPlaying: QueueRow?
    public var user: [QueueRow]
    public var context: [QueueRow]
    public var autoplay: [QueueRow]
    public var history: [QueueRow] = []
    public var showHistory: Bool = false

    public static let empty = QueueSections(nowPlaying: nil, user: [], context: [], autoplay: [], history: [], showHistory: false)

    public init(nowPlaying: QueueRow?, user: [QueueRow], context: [QueueRow], autoplay: [QueueRow], history: [QueueRow] = [], showHistory: Bool = false) {
        self.nowPlaying = nowPlaying
        self.user = user
        self.context = context
        self.autoplay = autoplay
        self.history = history
        self.showHistory = showHistory
    }

    /// Splits `queue` around the entry at `currentIndex`. History (the rows before it) is listed only when
    /// `showHistory` is true.
    public init(queue: [Song], currentIndex: Int, showHistory: Bool = false) {
        guard queue.indices.contains(currentIndex) else {
            self = QueueSections(nowPlaying: nil, user: [], context: [], autoplay: [], history: [], showHistory: showHistory)
            return
        }
        var seen: [String: Int] = [:]
        let occurrence: [Int] = queue.map { song in
            let count = seen[song.videoId, default: 0]
            seen[song.videoId] = count + 1
            return count
        }
        var usedKeys: Set<String> = []
        func row(_ index: Int, _ prefix: String) -> QueueRow {
            let song = queue[index]
            let identity = song.queueEntryId ?? "\(song.videoId)#\(occurrence[index])"
            let base = "\(prefix)_\(identity)"
            var key = base
            var repeatCount = 1
            while !usedKeys.insert(key).inserted {
                key = "\(base)~\(repeatCount)"
                repeatCount += 1
            }
            return QueueRow(timelineIndex: index, song: song, key: key)
        }
        var user: [QueueRow] = []
        var context: [QueueRow] = []
        var autoplay: [QueueRow] = []
        for index in (currentIndex + 1)..<queue.count {
            switch queue[index].queueTier {
            case .userQueue: user.append(row(index, "user"))
            case .context: context.append(row(index, "context"))
            case .autoplay: autoplay.append(row(index, "autoplay"))
            }
        }
        let history: [QueueRow] = showHistory ? (0..<currentIndex).map { row($0, "history") } : []
        self.init(nowPlaying: row(currentIndex, "np"), user: user, context: context, autoplay: autoplay, history: history, showHistory: showHistory)
    }

    public subscript(section: QueueSection) -> [QueueRow] {
        switch section {
        case .user: return user
        case .context: return context
        case .autoplay: return autoplay
        }
    }

    /// The name in the context section's heading ("Next from %@"), or nil for the plain "Queue"
    /// heading: the first context row's source or album, else the playing entry's.
    public var contextTitle: String? {
        func nonBlank(_ value: String?) -> String? {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
        let first = context.first?.song
        let playing = nowPlaying?.song
        return nonBlank(first?.playbackSource) ?? nonBlank(first?.albumName)
            ?? nonBlank(playing?.playbackSource) ?? nonBlank(playing?.albumName)
    }

    /// Whether the "Clear" button shows: only while there is a user queue to clear.
    public var canClearUserQueue: Bool { !user.isEmpty }

    /// Whether the AutoPlay heading shows: while AutoPlay is on (with its "nothing yet" message when
    /// empty), and while any of its tracks are still queued after it has been turned off.
    public func showsAutoplaySection(autoplayEnabled: Bool) -> Bool {
        autoplayEnabled || !autoplay.isEmpty
    }

    /// Whether dragging the row at `from` onto the row at `to` is allowed: both are upcoming rows
    /// of the same section. A drag never leaves its own section, and the playing row doesn't move.
    public func canMove(from: Int, to: Int) -> Bool {
        guard from != to else { return false }
        for section in QueueSection.allCases {
            let rows = self[section]
            if rows.contains(where: { $0.timelineIndex == from }) {
                return rows.contains(where: { $0.timelineIndex == to })
            }
        }
        return false
    }
}

/// Where AutoPlay's section of the queue begins, and so where a track queued by hand belongs —
/// above the mix, below everything the user picked.
///
/// Read as "the first of AutoPlay's tracks still to come", which keeps it below the playing track
/// even when the mix itself is what's playing: the tracks of it already behind you count as played,
/// and the section starts again below the needle. Tracks put in by hand there ("Play next" while the
/// mix runs) stay above it too, for the same reason. The queue panel draws its AutoPlay heading at
/// this same index.
extension QueueSections {
    public static func autoplaySectionStart(fromAutoplay: [Bool], currentIndex: Int) -> Int {
        let after = min(max(currentIndex + 1, 0), fromAutoplay.count)
        return (after..<fromAutoplay.count).first { fromAutoplay[$0] } ?? fromAutoplay.count
    }
}

/// Auto-scroll while a queue row is dragged against the top or bottom of the list, so a track can
/// be dragged across a queue longer than the screen.
public enum QueueDragAutoScroll {
    /// How far in from either end of the list a held row starts scrolling it, in points. A shade
    /// deeper than the 28 pt the list fades out over, so the list is already moving by the time the
    /// row begins to disappear into the fade.
    public static let zone: Double = 40
    /// Speed at the very edge, in points per second: about six rows a second, quick enough to cross
    /// a long queue, slow enough to read the titles going past and stop on the right one.
    public static let speed: Double = 340

    /// The pace to scroll at while a row spanning `top` to `bottom` is held in a viewport spanning
    /// `viewportStart` to `viewportEnd` — negative towards the start of the list, positive towards
    /// its end, and zero while the row is clear of both edges.
    ///
    /// Ramped by how far into `zone` the row has reached, so how fast the queue goes by stays the
    /// user's to choose — but from a fifth of `speed` rather than from nothing, since a row just
    /// inside the zone should visibly move the list. A viewport too short to hold the row clear of
    /// both edges at once scrolls neither way, rather than picking one and running away with it.
    public static func speed(
        top: Double,
        bottom: Double,
        viewportStart: Double,
        viewportEnd: Double,
        zone: Double = QueueDragAutoScroll.zone,
        speed: Double = QueueDragAutoScroll.speed
    ) -> Double {
        guard zone > 0 else { return 0 }
        let intoStart = (viewportStart + zone) - top
        let intoEnd = bottom - (viewportEnd - zone)
        let reach: Double
        if intoStart > 0, intoEnd <= 0 {
            reach = -intoStart
        } else if intoEnd > 0, intoStart <= 0 {
            reach = intoEnd
        } else {
            return 0
        }
        let ramp = speed * (0.2 + 0.8 * min(abs(reach) / zone, 1))
        return reach < 0 ? -ramp : ramp
    }
}
