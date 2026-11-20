import Foundation
import Observation

/// Re-runs `apply` whenever what `read` observes changes, for wiring one `@Observable` object's
/// state into another (settings into the engine, the queue into the engine's look-ahead).
///
/// `withObservationTracking` fires once per registration; this re-arms after every change and
/// drops repeated values, so `apply` runs only for real changes. Changes are applied on the next
/// main-actor turn, coalescing a burst of writes (a preset writing seven bands) into one call.
@MainActor
final class ChangeTracker {
    private var cancelled = false

    /// Starts tracking. `apply` runs once now with the current value unless `initial` is false.
    @discardableResult
    static func track<Value: Equatable>(
        _ read: @escaping @MainActor () -> Value,
        initial: Bool = true,
        apply: @escaping @MainActor (Value) -> Void
    ) -> ChangeTracker {
        let tracker = ChangeTracker()
        let first = read()
        if initial { apply(first) }
        tracker.arm(read: read, last: first, apply: apply)
        return tracker
    }

    func cancel() { cancelled = true }

    private func arm<Value: Equatable>(read: @escaping @MainActor () -> Value, last: Value, apply: @escaping @MainActor (Value) -> Void) {
        guard !cancelled else { return }
        withObservationTracking {
            _ = read()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.cancelled else { return }
                let now = read()
                if now != last { apply(now) }
                self.arm(read: read, last: now, apply: apply)
            }
        }
    }
}
