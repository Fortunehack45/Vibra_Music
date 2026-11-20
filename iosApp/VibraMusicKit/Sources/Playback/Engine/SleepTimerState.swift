import Foundation

/// A sleep timer the listener asks for.
public enum SleepTimerRequest: Hashable, Sendable {
    /// Pause after this many minutes (the picker offers ``presetMinutes``).
    case minutes(Int)
    /// Pause after an arbitrary interval, in seconds.
    case duration(TimeInterval)
    /// Pause when the track playing now finishes.
    ///
    /// Deliberately not a deadline of "duration minus position": seeking, a crossfade and a queue
    /// that reorders itself would all leave that number wrong, whereas the track ending is an event
    /// the engine sees.
    case endOfTrack

    /// Durations offered in the picker, as on Android.
    public static let presetMinutes = [15, 30, 45, 60]
}

/// The sleep timer that is armed, if any.
///
/// A deadline rather than a countdown: nothing has to tick for the timer to stay accurate, so it
/// survives the player UI being dismissed, and any observer can work out how long is left.
public struct SleepTimerState: Hashable, Sendable {
    /// The preset that was chosen, so the picker can tick it. Nil for ``SleepTimerRequest/duration(_:)``
    /// and ``SleepTimerRequest/endOfTrack``.
    public var presetMinutes: Int?
    /// When playback pauses, on the engine's monotonic clock (see
    /// ``AudioPlayerEngine/sleepTimerRemaining``). Nil for end-of-track.
    public var deadline: TimeInterval?
    /// Pause when the current track ends.
    public var afterTrack: Bool

    public init(presetMinutes: Int? = nil, deadline: TimeInterval? = nil, afterTrack: Bool = false) {
        self.presetMinutes = presetMinutes
        self.deadline = deadline
        self.afterTrack = afterTrack
    }

    /// How long is left at `now`, never negative; nil for end-of-track.
    public func remaining(at now: TimeInterval) -> TimeInterval? {
        deadline.map { max($0 - now, 0) }
    }
}
