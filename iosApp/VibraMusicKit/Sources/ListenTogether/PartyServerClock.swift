import Foundation

/// This device's offset from the party server's clock.
///
/// Everything the party shares is expressed on the server's timeline — a position and the
/// server time it was true at — so a device that cannot translate that timeline into its
/// own cannot be in sync, however fast its connection is. This is the translation.
///
/// The method is NTP's, cut down to the part that matters over one WebSocket: each sample
/// is a ping stamped on the way out and a pong carrying the server's own reading:
///
/// ```
/// offset     = serverMs - (t0 + t1) / 2
/// roundTrip  = t1 - t0
/// ```
///
/// and the error on that offset is at most half the round trip, because the only thing
/// being assumed is that the two legs took the same time. Which is why the sample with
/// the *smallest* round trip wins rather than the newest or the average: on mobile data a
/// single request delayed behind a radio wake-up is wrong by hundreds of milliseconds, and
/// averaging folds that error in instead of discarding it. A short burst of pings on
/// connect therefore converges faster than a long series would.
///
/// The local half of every sample is a monotonic clock (`ProcessInfo.systemUptime`), not
/// the wall clock. The wall clock is stepped — by the network operator, by the user
/// setting the time, by a DST change — and any step lands directly in the offset and moves
/// this device's playhead relative to everyone else's. The monotonic clock counts since
/// boot through deep sleep, which is exactly the timeline a playhead should be measured
/// against. (Ports `ServerClock` in `data/listentogether/ServerClock.kt`; Android reads
/// `SystemClock.elapsedRealtime`, the same monotonic timeline.)
public final class PartyServerClock: @unchecked Sendable {
    private struct Sample {
        var offsetMs: Int64
        var roundTripMs: Int64
        var takenAtMs: Int64
    }

    private let lock = NSLock()
    private var samples: [Sample] = []
    private let monotonicMs: () -> Int64

    private var _offsetMs: Int64?
    private var _roundTripMs: Int64 = 0

    /// - Parameter monotonicMs: the local monotonic timeline samples are measured on.
    ///   Defaults to the boot-relative clock; tests inject a manual clock.
    public init(monotonicMs: @escaping () -> Int64 = PartyServerClock.systemMonotonicMs) {
        self.monotonicMs = monotonicMs
    }

    public static func systemMonotonicMs() -> Int64 {
        Int64(ProcessInfo.processInfo.systemUptime * 1_000)
    }

    public var offsetMs: Int64? {
        lock.withLock { _offsetMs }
    }

    public var roundTripMs: Int64 {
        lock.withLock { _roundTripMs }
    }

    /// True once at least one round trip has completed.
    public var isSynced: Bool { offsetMs != nil }

    public func record(sentAtLocalMs: Int64, serverMs: Int64, receivedAtLocalMs: Int64) {
        lock.withLock {
            let roundTrip = max(0, receivedAtLocalMs - sentAtLocalMs)
            let midpoint = sentAtLocalMs + roundTrip / 2
            samples.append(Sample(offsetMs: serverMs - midpoint, roundTripMs: roundTrip, takenAtMs: receivedAtLocalMs))
            while samples.count > Self.window { samples.removeFirst() }

            // Stale samples are dropped before choosing, or one lucky round trip early in a
            // session would pin the offset for the whole of it — and clocks do drift, on a
            // phone by milliseconds per minute.
            let cutoff = receivedAtLocalMs - Self.sampleTTLMs
            let usable = samples.filter { $0.takenAtMs >= cutoff }
            let pool = usable.isEmpty ? samples : usable
            let best = pool.min(by: { $0.roundTripMs < $1.roundTripMs })!
            _offsetMs = best.offsetMs
            _roundTripMs = best.roundTripMs
        }
    }

    /// The server's clock, read from here. Null until the first pong lands.
    public func serverNowMs() -> Int64? {
        lock.withLock { _offsetMs.map { monotonicMs() + $0 } }
    }

    public func reset() {
        lock.withLock {
            samples.removeAll()
            _offsetMs = nil
            _roundTripMs = 0
        }
    }

    private static let window = 12
    private static let sampleTTLMs: Int64 = 120_000
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
