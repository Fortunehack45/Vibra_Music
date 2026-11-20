import Foundation
import SwiftUI

/// Easing curves the Android colour transitions run on.
public enum ThemingMotion {
    /// Compose's `FastOutSlowInEasing`, `cubic-bezier(0.4, 0, 0.2, 1)` — the
    /// default for every `tween` in this code (tint fades, mesh colour fades, the
    /// mesh backdrop's crossfade, the blobs settling).
    public static func fastOutSlowIn(_ fraction: Double) -> Double {
        cubicBezier(x1: 0.4, y1: 0, x2: 0.2, y2: 1, at: fraction)
    }

    /// The same curve as a SwiftUI animation, for views that let SwiftUI
    /// interpolate rather than sampling ``ThemingTransition``.
    public static func fastOutSlowInAnimation(duration: TimeInterval) -> Animation {
        .timingCurve(0.4, 0, 0.2, 1, duration: duration)
    }

    /// Evaluates a CSS-style cubic Bézier easing (endpoints (0,0) and (1,1)) at
    /// `fraction`, solving x(t) = fraction by Newton's method with a bisection
    /// fallback. Outside `0<…<1` the fraction is returned as is, as Compose does.
    static func cubicBezier(x1: Double, y1: Double, x2: Double, y2: Double, at fraction: Double) -> Double {
        guard fraction > 0, fraction < 1 else { return fraction }
        func sample(_ a1: Double, _ a2: Double, _ t: Double) -> Double {
            // Bernstein form with P0 = 0, P3 = 1.
            let u = 1 - t
            return 3 * u * u * t * a1 + 3 * u * t * t * a2 + t * t * t
        }
        func slope(_ a1: Double, _ a2: Double, _ t: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * a1 + 6 * u * t * (a2 - a1) + 3 * t * t * (1 - a2)
        }
        var t = fraction
        for _ in 0..<8 {
            let error = sample(x1, x2, t) - fraction
            if abs(error) < 1e-7 { return sample(y1, y2, t) }
            let d = slope(x1, x2, t)
            if abs(d) < 1e-6 { break }
            t -= error / d
        }
        var low = 0.0
        var high = 1.0
        t = fraction
        for _ in 0..<60 {
            let x = sample(x1, x2, t)
            if abs(x - fraction) < 1e-9 { break }
            if x < fraction { low = t } else { high = t }
            t = (low + high) / 2
        }
        return sample(y1, y2, t)
    }
}

/// A value that can be crossfaded the way the Android code animates it.
public protocol ThemingInterpolatable: Equatable, Sendable {
    static func interpolate(from: Self, to: Self, fraction: Double) -> Self
}

extension ThemeColor: ThemingInterpolatable {
    /// Oklab, as Compose's `animateColorAsState`.
    public static func interpolate(from: ThemeColor, to: ThemeColor, fraction: Double) -> ThemeColor {
        interpolateOklab(from: from, to: to, fraction: fraction)
    }
}

/// `animate*AsState` without Compose: a value easing towards a target over a
/// fixed duration, retargetable mid-flight.
///
/// A new target starts a fresh tween *from wherever the value is right now*,
/// for the full duration, which is what a Compose tween does when its target
/// changes under it — so a skip during a crossfade never jumps. A nil duration
/// is a snap (Compose's `snap()`), used for "reduce animation" and for colours
/// that were known on the first frame.
///
/// Times are any monotonic seconds, e.g. `TimelineView`'s
/// `context.date.timeIntervalSinceReferenceDate`.
public struct ThemingTransition<Value: ThemingInterpolatable>: Sendable {
    public private(set) var from: Value
    public private(set) var target: Value
    public private(set) var startTime: TimeInterval
    public private(set) var duration: TimeInterval

    public init(value: Value) {
        from = value
        target = value
        startTime = 0
        duration = 0
    }

    /// The eased value at `time`.
    public func value(at time: TimeInterval) -> Value {
        guard duration > 0 else { return target }
        let linear = (time - startTime) / duration
        if linear >= 1 { return target }
        if linear <= 0 { return from }
        return Value.interpolate(from: from, to: target, fraction: ThemingMotion.fastOutSlowIn(linear))
    }

    /// Whether the value has arrived — nothing left to redraw.
    public func isSettled(at time: TimeInterval) -> Bool {
        duration <= 0 || time - startTime >= duration
    }

    /// Heads for `newTarget`, starting from the current value at `time`. A
    /// target equal to the current one leaves a running animation alone.
    public mutating func retarget(to newTarget: Value, at time: TimeInterval, duration newDuration: TimeInterval?) {
        if newTarget == target { return }
        guard let newDuration, newDuration > 0 else {
            from = newTarget
            target = newTarget
            startTime = time
            duration = 0
            return
        }
        from = value(at: time)
        target = newTarget
        startTime = time
        duration = newDuration
    }
}
