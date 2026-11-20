import Foundation

// Ports data/sources/module/SharedCalls.kt.

/// One in-flight-or-recent answer per key, shared by everyone who asks for it.
///
/// A track passes through this layer several times over — the live resolve, the second look under
/// the music, the lossless pass after a lossy swap, a re-resolve when the player reopens — and
/// every one used to start from nothing: on Android one track was searched twice and asked twice
/// for its stream URL inside ninety seconds, against one module's server.
///
/// Two things are shared, and they are not the same:
/// - **In flight**, always, whatever `ttl` says. Two callers asking the same question at the same
///   moment is the ordinary case here.
/// - **Completed**, for `ttl`. Zero means in-flight only.
///
/// ### Why the work runs in its own task
///
/// This layer's callers are designed to give up: ``SourceResolver`` cancels every source still
/// running once one answers. Run inside the caller's task, each cancellation tore down a request
/// that had already reached somebody's server — which from the far end looks like a client
/// hammering it and hanging up. The work runs in an unstructured `Task`, so a cancelled caller
/// drops its wait and nothing else; the answer lands here, where it is usually wanted again moments
/// later.
///
/// A failure is never kept (a server briefly down is asked again next track). An empty answer is
/// kept: "this catalogue does not have that recording" is a real answer.
actor SharedCalls<Value: Sendable> {
    private struct Entry {
        let id: UInt64
        let task: Task<Result<Value, Error>, Never>
        let startedAt: TimeInterval
        var finished: Bool
        /// Whether this answer's first reuse was already logged: a hit is a once-per-answer
        /// diagnostic, not a per-request line.
        var hitLogged: Bool = false
    }

    private let ttl: TimeInterval
    private let log: @Sendable (String) -> Void
    private let now: @Sendable () -> TimeInterval
    private var entries: [String: Entry] = [:]
    private var nextId: UInt64 = 0

    /// How many answers to hold: a queue's worth of tracks at two queries and a stream call each,
    /// several times over. The point is a bound, not a budget.
    static var maxEntries: Int { 128 }

    init(
        ttl: TimeInterval,
        log: @escaping @Sendable (String) -> Void = { _ in },
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.ttl = ttl
        self.log = log
        self.now = now
    }

    func get(
        _ key: String,
        describe: @Sendable () -> String = { "" },
        produce: @escaping @Sendable () async -> Result<Value, Error>
    ) async -> Result<Value, Error> {
        let entry: Entry
        if var live = entries[key], !live.finished || now() - live.startedAt < ttl {
            if live.finished {
                if !live.hitLogged {
                    log(describe() + " — CACHE HIT")
                    live.hitLogged = true
                    entries[key] = live
                }
            } else {
                log(describe() + " — ALREADY RUNNING")
            }
            entry = live
        } else {
            if entries.count >= Self.maxEntries { prune() }
            nextId += 1
            let id = nextId
            let task = Task<Result<Value, Error>, Never> { await produce() }
            entry = Entry(id: id, task: task, startedAt: now(), finished: false)
            entries[key] = entry
            Task { [weak self] in
                let result = await task.value
                await self?.settle(key, id: id, failed: result.isFailure)
            }
        }
        // Waiting is cancellable; the work is not. A caller that gives up gets a CancellationError
        // back at once and the request carries on into the cache.
        let result = await Self.wait(for: entry.task)
        if case .failure(let error) = result, error is CancellationError, Task.isCancelled {
            return result
        }
        settle(key, id: entry.id, failed: result.isFailure)
        return result
    }

    /// Marks an entry done, or drops it when it failed. By identity, so a retry that already
    /// replaced this entry isn't thrown away with the failure it replaced.
    private func settle(_ key: String, id: UInt64, failed: Bool) {
        guard var entry = entries[key], entry.id == id else { return }
        if failed {
            entries[key] = nil
        } else {
            entry.finished = true
            entries[key] = entry
        }
    }

    private static func wait(for task: Task<Result<Value, Error>, Never>) async -> Result<Value, Error> {
        let gate = ResumeOnce<Result<Value, Error>>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                Task { gate.resume(with: await task.value) }
            }
        } onCancel: {
            gate.resume(with: .failure(CancellationError()))
        }
    }

    /// Everything held, dropped — the configuration it was all about is gone.
    func clear() {
        entries.removeAll()
    }

    /// Drops completed answers while keeping work still in flight: an explicit refresh should ask
    /// the server again, but not detach from a request already on the wire.
    func clearCompleted() {
        entries = entries.filter { !$0.value.finished }
    }

    /// For tests and diagnostics: how many answers are held.
    var size: Int { entries.count }

    private func prune() {
        let at = now()
        // Never an entry still running: dropping it would only hide it from the next caller, who
        // would start a second copy — the one thing this exists to prevent.
        entries = entries.filter { !$0.value.finished || at - $0.value.startedAt < ttl }
        if entries.count >= Self.maxEntries,
           let oldest = entries.filter({ $0.value.finished }).min(by: { $0.value.startedAt < $1.value.startedAt }) {
            entries[oldest.key] = nil
        }
    }
}

/// A cache key from its parts, each length-prefixed, so no byte a part may contain can act as a
/// delimiter. A collision would not fail — it would serve one track's stream URL for another.
func sharedCallKey(_ parts: String...) -> String {
    parts.map { "\($0.count):\($0)" }.joined(separator: "|")
}

extension Result {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}

/// A continuation resumed exactly once, whichever of a result or a cancellation arrives first —
/// including a cancellation that arrives before the continuation is installed.
final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var pending: Value?
    private var done = false

    func install(_ continuation: CheckedContinuation<Value, Never>) {
        lock.lock()
        if let pending, !done {
            done = true
            lock.unlock()
            continuation.resume(returning: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(with value: Value) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        guard let continuation else {
            if pending == nil { pending = value }
            lock.unlock()
            return
        }
        done = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
    }
}
