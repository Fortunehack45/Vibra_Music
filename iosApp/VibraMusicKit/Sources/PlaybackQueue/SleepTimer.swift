import Foundation
import Observation

// Ports playback/SleepTimer.kt and the service's watchSleepTimer.

/// The sleep timer: pause after a preset number of minutes, or when the current track ends.
///
/// Holds a deadline rather than a countdown: nothing has to tick for the timer to stay accurate, so
/// it survives the player UI being dismissed, and any observer can work out how long is left for
/// itself. The deadline is on `ContinuousClock` (monotonic, keeps counting while the device sleeps,
/// like Android's `elapsedRealtime`), not the wall clock, so changing the system time can't cut a
/// timer short.
///
/// Whoever owns the player sets ``onExpire`` to pause it. "End of this track" is reported through
/// ``PlaybackQueueController/trackDidFinish()``, which consumes it.
@MainActor
@Observable
public final class SleepTimer {
    /// Durations offered in the picker, in minutes.
    public static let presets = [15, 30, 45, 60]

    /// When a timed preset fires, or nil when none is set.
    public private(set) var deadline: ContinuousClock.Instant?

    /// The preset that was chosen, so the picker can tick it. Nil when off or "end of track".
    public private(set) var minutes: Int?

    /// Pause when the current track ends instead of after a fixed wait.
    ///
    /// Deliberately not expressed as a deadline of "duration minus position": seeking, crossfade
    /// and a queue that reorders itself would all leave that number wrong, whereas the track ending
    /// is an event the player reports. Crossfade reads this to fade the last track out to silence
    /// instead of into the next one.
    public private(set) var afterTrack = false

    /// Called on the main actor when a timed preset runs out. The timer is already cancelled by then.
    @ObservationIgnored public var onExpire: (@MainActor () -> Void)?

    @ObservationIgnored private let now: @Sendable () -> ContinuousClock.Instant
    @ObservationIgnored private var expiry: Task<Void, Never>?

    /// - Parameter now: the clock reading; tests pass a fixed instant.
    public init(now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.now = now
    }

    /// Whether any kind of timer is armed.
    public var isRunning: Bool { deadline != nil || afterTrack }

    /// Pause after `minutes` minutes. Re-setting replaces the previous timer rather than adding a
    /// second one.
    public func start(minutes: Int) {
        arm(after: .seconds(minutes * 60), minutes: minutes)
    }

    /// Pause once the track playing right now finishes.
    public func startAfterTrack() {
        expiry?.cancel()
        expiry = nil
        minutes = nil
        deadline = nil
        afterTrack = true
    }

    public func cancel() {
        expiry?.cancel()
        expiry = nil
        minutes = nil
        deadline = nil
        afterTrack = false
    }

    /// How long is left, or nil when no timed preset is running.
    public func remaining() -> Duration? {
        guard let deadline else { return nil }
        let left = deadline - now()
        return left > .zero ? left : .zero
    }

    /// ``remaining()`` in whole milliseconds.
    public func remainingMs() -> Int64? {
        remaining().map { Int64($0.components.seconds) * 1_000 + $0.components.attoseconds / 1_000_000_000_000_000 }
    }

    /// "m:ss" until the timer fires, for the picker's subtitle and the menu row; nil when no timed
    /// preset runs.
    public func countdownText() -> String? {
        guard let ms = remainingMs() else { return nil }
        let seconds = ms / 1_000
        let secs = seconds % 60
        return "\(seconds / 60):\(secs < 10 ? "0" : "")\(secs)"
    }

    /// Called when the current track finishes by itself (including a repeat-one replay): true when
    /// an "end of this track" timer was armed, which is now spent, and the player should pause.
    public func consumeAfterTrack() -> Bool {
        guard afterTrack else { return false }
        cancel()
        return true
    }

    /// Arms a timed preset. Internal so tests can use a sub-second wait.
    func arm(after wait: Duration, minutes: Int?) {
        expiry?.cancel()
        afterTrack = false
        self.minutes = minutes
        let deadline = now() + wait
        self.deadline = deadline
        // A replacement rather than a second waiter: the previous task is cancelled above, which is
        // Android's collectLatest on the deadline.
        expiry = Task { [weak self] in
            do {
                try await Task.sleep(for: wait, clock: .continuous)
            } catch {
                return
            }
            guard let self, self.deadline == deadline else { return }
            self.cancel()
            self.onExpire?()
        }
    }
}
