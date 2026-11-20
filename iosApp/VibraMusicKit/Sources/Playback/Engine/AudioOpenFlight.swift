import Foundation

/// One open of an item's audio that more than one caller may be waiting on: the gapless preload
/// and the crossfade's arming both want the next item's asset, and each used to start its own
/// open (its own stream resolve, its own race) while the other was still running.
///
/// The open is cancelled when its last waiter leaves, so a preload nobody wants any more stops
/// resolving, as it did when it was the only one asking. Waiters come and go from any thread
/// (cancellation handlers are not isolated), hence the lock.
final class AudioOpenFlight: @unchecked Sendable {
    let task: Task<OpenedAudio, Error>
    private let lock = NSLock()
    private var waiters = 1
    private var abandoned = false

    /// Starts opening; the caller is the first waiter.
    init(_ open: @escaping @Sendable () async throws -> OpenedAudio) {
        task = Task { try await open() }
    }

    /// Adds a waiter. False when everyone has already left and the open is being cancelled: the
    /// caller starts its own.
    func join() -> Bool {
        lock.withLock {
            guard !abandoned else { return false }
            waiters += 1
            return true
        }
    }

    /// A waiter no longer needs the result; the last one out stops the open.
    func leave() {
        let last = lock.withLock {
            waiters -= 1
            guard waiters == 0, !abandoned else { return false }
            abandoned = true
            return true
        }
        if last { task.cancel() }
    }
}
