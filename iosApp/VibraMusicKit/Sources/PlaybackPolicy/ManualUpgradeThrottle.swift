import Foundation

// Ports ManualUpgradeThrottle from playback/PlaybackService.kt.

/// App-side gate for explicit quality retries (the player menu's "Upgrade quality").
///
/// Automatic upgrades never pass through this. Returning the remaining wait rather than a Bool gives
/// the log enough to tell a deliberate throttle from a search that failed to start. Time before the
/// first request does not count against it: however long the app has been playing, the first
/// explicit request is accepted.
public final class ManualUpgradeThrottle: @unchecked Sendable {
    private let cooldownMs: Int64
    private let lock = NSLock()
    private var lastAcceptedAtMs: Int64?

    public init(cooldownMs: Int64) {
        self.cooldownMs = cooldownMs
    }

    /// 0 when the request is accepted (and the cooldown starts), otherwise the milliseconds left.
    ///
    /// - Parameter nowMs: a monotonic clock in milliseconds.
    public func tryAcquire(nowMs: Int64) -> Int64 {
        lock.withLock {
            if let previous = lastAcceptedAtMs {
                let remaining = cooldownMs - (nowMs - previous)
                if remaining > 0 { return remaining }
            }
            lastAcceptedAtMs = nowMs
            return 0
        }
    }
}
