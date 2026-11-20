import Foundation

/// Why the current item changed.
public enum ItemChangeReason: Hashable, Sendable {
    /// The app asked for it (``AudioPlayerEngine/load(_:startingAt:playWhenReady:)``).
    case requested
    /// The previous item played to its end and the next one followed gaplessly.
    case ended
    /// The previous item crossfaded into this one. Reported as the incoming track becomes audible,
    /// not when the blend finishes, so metadata and the queue flip with the sound.
    case crossfade
    /// The same item started over (the app returned it as its own successor: repeat-one).
    case repeated
    /// The previous item could not be played and the engine moved past it.
    case skippedUnplayable(reason: String)

    /// Whether the item being replaced ran to its end — the only case that counts as a listen for
    /// scrobbling and history. A skip is not a listen.
    public var previousEnded: Bool {
        switch self {
        case .ended, .crossfade, .repeated: return true
        case .requested, .skippedUnplayable: return false
        }
    }
}

/// A snapshot for position persistence, delivered at the moments the Android service saved its
/// playback state: when playing starts or stops, when the item changes, after a seek, and every five
/// seconds while playing.
public struct PlaybackCheckpoint: Hashable, Sendable {
    public var itemID: String
    public var position: TimeInterval
    public var isPlaying: Bool

    public init(itemID: String, position: TimeInterval, isPlaying: Bool) {
        self.itemID = itemID
        self.position = position
        self.isPlaying = isPlaying
    }
}

/// A command from the lock screen, Control Center, headphones, CarPlay or a watch.
public enum RemoteCommand: Hashable, Sendable {
    case play
    case pause
    case togglePlayPause
    case stop
    case nextTrack
    case previousTrack
    /// Scrubbing on the lock screen: go to this position, in seconds.
    case changePlaybackPosition(TimeInterval)
    case skipForward(TimeInterval)
    case skipBackward(TimeInterval)
    case changePlaybackRate(Float)
    /// The heart. `isActive` is what the surface showed before the tap.
    case like(wasActive: Bool)
    case dislike(wasActive: Bool)
}

/// How a remote command was handled; mirrors `MPRemoteCommandHandlerStatus`.
public enum RemoteCommandResult: Hashable, Sendable {
    case success
    case noSuchContent
    case noActionableNowPlayingItem
    case commandFailed
}

/// What the app implements to drive the queue and hear about the engine. Every method has a
/// default, so implement only what you need.
///
/// The engine plays one item at a time plus the one it preloads; the queue (order, shuffle, repeat,
/// AutoPlay) is the app's. The engine asks for the next item whenever it needs one, and says when
/// the current item changes so the app can move its queue index.
@MainActor
public protocol AudioPlayerEngineDelegate: AnyObject {
    /// What plays after `item`, or nil when nothing does. Asked after every item change and after
    /// ``AudioPlayerEngine/upcomingItemDidChange()``; answer from memory, it is called on the main
    /// actor. Return an item with the *same* id to loop the current one (repeat-one).
    func audioPlayerEngine(_ engine: AudioPlayerEngine, itemAfter item: PlayableItem) -> PlayableItem?

    /// The current item changed. For every reason but ``ItemChangeReason/requested`` the engine
    /// moved on by itself, and the app should advance its queue to match.
    func audioPlayerEngine(_ engine: AudioPlayerEngine, didChangeItemTo item: PlayableItem, reason: ItemChangeReason)

    /// The last item finished and nothing follows. Playback has stopped on it (play restarts it).
    func audioPlayerEngine(_ engine: AudioPlayerEngine, didFinishQueueAfter item: PlayableItem)

    /// An item failed. `willRetry` is false once the engine has given up on it.
    func audioPlayerEngine(_ engine: AudioPlayerEngine, didFail error: PlaybackError, willRetry: Bool)

    /// A remote command arrived. The default performs the obvious action on the engine (see
    /// ``AudioPlayerEngine/performDefault(_:)``); override to route next/previous through the queue,
    /// to rate tracks on like/dislike, or to hold transport while a Listen Together host has control.
    func audioPlayerEngine(_ engine: AudioPlayerEngine, handle command: RemoteCommand) -> RemoteCommandResult

    /// Persist this for a cold-start resume.
    func audioPlayerEngine(_ engine: AudioPlayerEngine, checkpoint: PlaybackCheckpoint)
}

extension AudioPlayerEngineDelegate {
    public func audioPlayerEngine(_ engine: AudioPlayerEngine, itemAfter item: PlayableItem) -> PlayableItem? { nil }
    public func audioPlayerEngine(_ engine: AudioPlayerEngine, didChangeItemTo item: PlayableItem, reason: ItemChangeReason) {}
    public func audioPlayerEngine(_ engine: AudioPlayerEngine, didFinishQueueAfter item: PlayableItem) {}
    public func audioPlayerEngine(_ engine: AudioPlayerEngine, didFail error: PlaybackError, willRetry: Bool) {}
    public func audioPlayerEngine(_ engine: AudioPlayerEngine, handle command: RemoteCommand) -> RemoteCommandResult {
        engine.performDefault(command)
    }
    public func audioPlayerEngine(_ engine: AudioPlayerEngine, checkpoint: PlaybackCheckpoint) {}
}
