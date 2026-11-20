import Foundation
import Observation

// Small pieces the rest of the module leans on. Nothing here is public: each is a detail of how the
// Android `object`s (ConcurrentHashMaps behind StateFlows) are carried over to instances that are
// safe to call from the player's threads and observable from SwiftUI.

/// Seconds on a clock that only moves forward and keeps counting while the device sleeps.
///
/// Android's `SystemClock.elapsedRealtime()`, which every expiry here was measured against. The
/// distinction matters for exactly the thing those expiries protect: a signed stream URL dies on
/// wall-clock time, so a clock that pauses during sleep (`ProcessInfo.systemUptime`) would let a
/// phone left in a pocket overnight wake up still trusting a URL that expired hours ago. Darwin's
/// `CLOCK_MONOTONIC` is the continuous one.
func monotonicSeconds() -> TimeInterval {
    TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
}

/// Runs `body` on the main thread: at once when already there — so a test, or a view that reads
/// straight after a write, sees the change announced — and asynchronously otherwise.
///
/// The observable state in this module is written from the player's loading threads as often as
/// from the main one (a read-ahead resolve starts a lossless race for a track nobody is looking
/// at), and SwiftUI wants its invalidations on the main thread. The value itself is readable under
/// its lock before the announcement lands; this only decides when views are told.
func onMainThread(_ body: @escaping @Sendable () -> Void) {
    if Thread.isMainThread {
        body()
    } else {
        DispatchQueue.main.async(execute: body)
    }
}

/// Waits for `task`'s value, but gives up and returns nil as soon as the *waiting* task is
/// cancelled, leaving `task` itself running.
///
/// Kotlin's `Deferred.await()` behaves like this and `Task.value` does not: awaiting a task's value
/// cannot be interrupted, so a second look that inherited a slow lookup would hold its caller for
/// as long as the lookup took even after the queue had moved on. The lookup is not cancelled here
/// on purpose — it belongs to whoever started it (see ``QualityUpgrade/forget(_:)``).
func awaitUnlessCancelled<T: Sendable>(_ task: Task<T?, Never>) async -> T? {
    if Task.isCancelled { return nil }
    let gate = ResumeOnce<T?>()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            gate.install(continuation)
            Task { gate.resume(returning: await task.value) }
        }
    } onCancel: {
        gate.resume(returning: nil)
    }
}

/// A continuation that is resumed exactly once, by whichever of its two resumers gets there first,
/// even if that happens before the continuation exists.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private enum Early { case none, value(Value) }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var early = Early.none
    private var finished = false

    func install(_ continuation: CheckedContinuation<Value, Never>) {
        lock.lock()
        if case .value(let value) = early {
            finished = true
            lock.unlock()
            continuation.resume(returning: value)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(returning value: Value) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        if let continuation {
            self.continuation = nil
            finished = true
            lock.unlock()
            continuation.resume(returning: value)
            return
        }
        if case .none = early { early = .value(value) }
        lock.unlock()
    }
}

/// The `src:<configId>::<trackId>` key a source-backed queue row carries as its video id.
///
/// Android's `SourceRegistry.trackKey`/`parseTrackKey`, which belongs to the Sources module; this
/// module cannot depend on that, and needs the parse in three places (the stats source lookup,
/// ``PlaybackFallback/hasYouTubeOriginal(_:)`` and ``PlaybackURI/forStreaming(_:pinnedToOriginal:)``).
/// Must agree with the Sources module's format character for character; see the report for the
/// request to move it into VibraMusicCore.
enum SourceTrackKey {
    static let prefix = "src:"
    static let separator = "::"

    static func make(configId: String, trackId: String) -> String {
        "\(prefix)\(configId)\(separator)\(trackId)"
    }

    /// The `(configId, trackId)` inside a key, or nil for an ordinary YouTube id.
    static func parse(_ key: String) -> (configId: String, trackId: String)? {
        guard key.hasPrefix(prefix) else { return nil }
        let body = key.dropFirst(prefix.count)
        guard let cut = body.range(of: separator), cut.lowerBound > body.startIndex else { return nil }
        return (String(body[..<cut.lowerBound]), String(body[cut.upperBound...]))
    }
}

extension StringProtocol {
    /// Kotlin's `substringBefore(delimiter)`: everything before the first occurrence, or the whole
    /// string when there is none.
    func before(_ delimiter: String) -> SubSequence {
        guard let range = range(of: delimiter) else { return self[...] }
        return self[..<range.lowerBound]
    }

    /// Kotlin's `substringAfter(delimiter, missingDelimiterValue)`.
    func after(_ delimiter: String, missing: String) -> String {
        guard let range = range(of: delimiter) else { return missing }
        return String(self[range.upperBound...])
    }
}
