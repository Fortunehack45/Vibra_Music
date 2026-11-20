import Foundation

/// Seconds on a monotonic clock that keeps counting while the device sleeps.
///
/// The sleep timer's deadline and the crossfade's bail ramp are measured on it. Monotonic for the
/// same reason the Android `SleepTimer` used `elapsedRealtime` rather than the wall clock: changing
/// the system time must not be able to cut a timer short.
protocol PlaybackClock: Sendable {
    var now: TimeInterval { get }
}

struct ContinuousPlaybackClock: PlaybackClock {
    private static let origin = ContinuousClock.now

    var now: TimeInterval {
        let elapsed = ContinuousClock.now - Self.origin
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}
