import Foundation

/// The result of one resolve walk, awaited by every caller that asked for the same track.
///
/// Waiting is cancellable per caller while the walk itself is not: a caller that gives up on
/// its own timeout (playback does) stops waiting, and the walk carries on for whoever else is
/// waiting — read-ahead, typically. That is the property Android got from parenting the walk to
/// its own scope, and the reason this is not simply `await task.value`, which ignores the
/// awaiting task's cancellation.
final class SharedWalk<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<Value, Error>?
    private var waiters: [Int: CheckedContinuation<Value, Error>] = [:]
    private var nextWaiter = 0

    func fulfil(_ result: Result<Value, Error>) {
        let pending: [CheckedContinuation<Value, Error>] = lock.withLock {
            guard outcome == nil else { return [] }
            outcome = result
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        for continuation in pending { continuation.resume(with: result) }
    }

    func value() async throws -> Value {
        let id: Int = lock.withLock {
            defer { nextWaiter += 1 }
            return nextWaiter
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                // nil: registered, the walk will resume it; non-nil: resume now.
                let immediate: Result<Value, Error>? = lock.withLock {
                    if let outcome { return outcome }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    waiters[id] = continuation
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let continuation = lock.withLock { waiters.removeValue(forKey: id) }
            continuation?.resume(throwing: CancellationError())
        }
    }
}
