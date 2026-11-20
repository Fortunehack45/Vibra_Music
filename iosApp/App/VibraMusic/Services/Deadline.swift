import Foundation

// Kotlin's `withTimeoutOrNull`, as PlaybackService.kt used it around the version alignment and
// the upgrade audition: the caller gets its answer (or nil) when the time is up, whatever the
// work is doing.

/// `operation`'s result, or nil once `timeout` has passed (or the calling task is cancelled).
///
/// Unlike a task group racing a sleep, this returns at the deadline even when `operation` doesn't
/// check for cancellation (an AVFoundation load, a decode): the operation is cancelled and left to
/// wind down on its own, its late result dropped. A task group would wait for it at the closing
/// brace, which is how a 30 s timeout turns into however long the hung read takes.
func withDeadline<T: Sendable>(_ timeout: Duration, _ operation: @escaping @Sendable () async -> T?) async -> T? {
    let gate = DeadlineGate<T>()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            gate.arm(continuation)
            let work = Task.detached {
                let value = await operation()
                gate.finish(value)
            }
            gate.onDeadline = { work.cancel() }
            Task.detached {
                try? await Task.sleep(for: timeout)
                gate.expire()
            }
        }
    } onCancel: {
        gate.expire()
    }
}

/// Resumes its continuation exactly once: with the result, or with nil at the deadline.
private final class DeadlineGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    private var done = false
    private var cancelWork: (() -> Void)?

    var onDeadline: (() -> Void)? {
        get { lock.withLock { cancelWork } }
        set {
            let fireNow: Bool = lock.withLock {
                cancelWork = newValue
                return done
            }
            if fireNow { newValue?() }
        }
    }

    func arm(_ continuation: CheckedContinuation<T?, Never>) {
        let expiredEarly: Bool = lock.withLock {
            if done { return true }
            self.continuation = continuation
            return false
        }
        // Cancelled before the continuation existed: answer at once.
        if expiredEarly { continuation.resume(returning: nil) }
    }

    func finish(_ value: T?) {
        let waiting: CheckedContinuation<T?, Never>? = lock.withLock {
            guard !done else { return nil }
            done = true
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: value)
    }

    func expire() {
        let (waiting, cancel): (CheckedContinuation<T?, Never>?, (() -> Void)?) = lock.withLock {
            guard !done else { return (nil, nil) }
            done = true
            defer { continuation = nil }
            return (continuation, cancelWork)
        }
        cancel?()
        waiting?.resume(returning: nil)
    }
}
