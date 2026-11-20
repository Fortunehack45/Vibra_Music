/*
 * A plain-data model of a transition plan's gain and filter automation,
 * ported from Vibra Music's CrossfadeController (rideFilters, rideFilterSweep,
 * rideBassSwap, rideVocalSeparation, entryHighPass, blendExitLowPass,
 * riseGain/fallGain). The app does not render from this: the ride the user
 * hears is Playback's TransitionFilterRide, which carries its own copy of
 * these constants, so a change here has to be made there too.
 *
 * Copyright (C) 2026 Kushagra Singh
 *
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation, either version 3 of the License, or (at your
 * option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
 * Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation

/// One deck's filter state as plain numbers: a low-pass corner and a high-pass corner in hertz.
///
/// ``TransitionAutomation/openHz`` for the low-pass and ``TransitionAutomation/offHz`` for the
/// high-pass mean "not filtering". Values are already clamped into the range the Android
/// renderer's 24 dB/octave state-variable filter accepts (low-pass 10 Hz...20 kHz, high-pass
/// 20 Hz...2 kHz), so any biquad or `AVAudioUnitEQ` band can take them as they are.
public struct DeckFilter: Sendable, Equatable {
    public var lowPassHz: Double
    public var highPassHz: Double

    public init(lowPassHz: Double, highPassHz: Double) {
        self.lowPassHz = min(max(lowPassHz, TransitionAutomation.minLowPassHz), TransitionAutomation.openHz)
        self.highPassHz = min(max(highPassHz, TransitionAutomation.offHz), TransitionAutomation.maxHighPassHz)
    }

    public static let open = DeckFilter(lowPassHz: TransitionAutomation.openHz, highPassHz: TransitionAutomation.offHz)

    public var isOpen: Bool {
        lowPassHz >= TransitionAutomation.openHz && highPassHz <= TransitionAutomation.offHz
    }
}

/// The two decks' gains and filters at one point of a transition.
public struct TransitionAutomationFrame: Sendable, Equatable {
    /// 0 at the start of the fade, 1 at its end.
    public var progress: Double
    /// Linear gain for the track being left, `cos(progress·π/2)`.
    public var outgoingGain: Double
    /// Linear gain for the track arriving, `sin(progress·π/2)`.
    public var incomingGain: Double
    public var outgoingFilter: DeckFilter
    public var incomingFilter: DeckFilter
}

/// Per-deck gain curves and filter automation for a ``TransitionPlan``, as plain data.
///
/// The gain curve is the same equal-power pair for every style (`incoming² + outgoing² = 1`, so
/// the blend never dips); the styles differ in what the filters do over it:
///
/// - ``TransitionStyle/djFilter``: the outgoing track is pulled behind a front-loaded closing
///   low-pass (7 kHz → 300 Hz bed) while the incoming one enters high-passed from 1.2 kHz and is
///   fully open by 60% of the fade — the two hand the midrange over instead of doubling it.
/// - ``TransitionStyle/djBlend`` with a bass swap: below 200 Hz exactly one track is present at
///   any instant; the low end changes hands at ``TransitionPlan/bassSwapFraction`` over a tenth of
///   the fade. The incoming entry high-pass (520 Hz, 950 Hz at a full vocal collision) and a
///   shallow outgoing exit low-pass (to 2.2 kHz, 1.1 kHz at full collision) keep two lead vocals
///   out of one band.
/// - ``TransitionStyle/equalPower`` (and a blend without a bass swap): open, unless the plan's
///   ``TransitionPlan/vocalOverlap`` says two vocals collide, in which case a restrained version of
///   the filter ride (outgoing to 1.6 kHz, incoming from 700 Hz) scaled by the collision.
/// - ``TransitionStyle/gapless``: always open; an album played through gets no edits.
///
/// Progress is what Playback measures: the incoming track's media position minus its cue time,
/// over the fade length (see ``TransitionPlan/fadeProgress(incomingPosition:incomingDuration:)``).
/// Driving filters and gains off the same progress keeps them locked: a pause parks both.
public struct TransitionAutomation: Sendable, Equatable {
    /// A low-pass at or above this is not filtering.
    public static let openHz = 20_000.0
    /// A high-pass at or below this is not filtering.
    public static let offHz = 20.0
    /// The renderer's ceiling for a high-pass corner.
    public static let maxHighPassHz = 2_000.0
    static let minLowPassHz = 10.0

    /// Where a filter ride's low-pass starts: inside the presence range, so the gesture is
    /// audible on the voice from the first instant.
    public static let filterEntryHz = 7_000.0
    /// The bottom of a filter ride. Below a few hundred hertz a track stops reading as "further
    /// away" and starts reading as "broken".
    public static let filterFloorHz = 300.0
    /// Where the low end is considered to end: clears the kick and the sub, leaves the vocal body.
    public static let bassSwapHz = 200.0
    /// How much of the fade the low end takes to change hands.
    public static let bassSwapWidth = 0.10
    /// Below 1 so the ride is front-loaded: fast then eased in, like a hand on a filter knob.
    static let filterSweepShape = 0.75
    /// Where the incoming track's high-pass starts on a filter ride: presence and percussion
    /// first, no second lead vocal.
    static let entryHighPassHz = 1_200.0
    /// How far into the fade the incoming track is fully open again on a filter ride.
    static let entryOpenBy = 0.6
    /// Shape of the incoming high-pass's descent: lingers in the range a voice occupies instead of
    /// dropping straight into sub-bass where a high-pass is inaudible.
    static let entryShape = 0.35
    /// How far vocal separation closes the outgoing top at a full collision.
    static let vocalSeparationFloorHz = 1_600.0
    /// Where the incoming high-pass starts for vocal separation on an otherwise plain fade.
    static let vocalSeparationHighPassHz = 700.0
    static let blendEntryHighPassHz = 520.0
    static let blendEntryOpenBy = 0.45
    static let blendEntryClashHighPassHz = 950.0
    static let blendEntryClashOpenBy = 0.7
    static let blendExitClashFrom = 0.12
    static let blendExitClashLowPassHz = 1_100.0
    static let blendExitFrom = 0.3
    static let blendExitLowPassHz = 2_200.0

    public var style: TransitionStyle
    public var bassSwap: Bool
    public var bassSwapFraction: Double
    public var filterSweep: Double
    public var vocalOverlap: Double

    public init(
        style: TransitionStyle,
        bassSwap: Bool = false,
        bassSwapFraction: Double = 0.7,
        filterSweep: Double = 0,
        vocalOverlap: Double = 0
    ) {
        self.style = style
        self.bassSwap = bassSwap
        self.bassSwapFraction = bassSwapFraction
        self.filterSweep = filterSweep
        self.vocalOverlap = vocalOverlap
    }

    /// The style fields of `plan`, fixed for the life of one transition: a plan is recomputed every
    /// tick, and a bass swap that moved to a different beat halfway through the blend would be
    /// heard as the low end flapping. Capture this once when the fade starts.
    public init(plan: TransitionPlan) {
        self.init(
            style: plan.transitionStyle,
            bassSwap: plan.bassSwap,
            bassSwapFraction: plan.bassSwapFraction,
            filterSweep: plan.filterSweep,
            vocalOverlap: plan.vocalOverlap
        )
    }

    /// Gains and filters at `progress` (clamped to 0...1).
    public func frame(at progress: Double) -> TransitionAutomationFrame {
        let p = progress.isFinite ? progress.coerced(0, 1) : 0
        let (outgoing, incoming) = filters(at: p)
        return TransitionAutomationFrame(
            progress: p,
            outgoingGain: cos(p * .pi / 2),
            incomingGain: sin(p * .pi / 2),
            outgoingFilter: outgoing,
            incomingFilter: incoming
        )
    }

    /// `count` evenly spaced frames from progress 0 to 1 inclusive, for a renderer that wants
    /// keyframes to interpolate or schedule rather than calling ``frame(at:)`` per buffer.
    public func frames(count: Int) -> [TransitionAutomationFrame] {
        guard count > 1 else { return [frame(at: 0)] }
        return (0..<count).map { frame(at: Double($0) / Double(count - 1)) }
    }

    /// Whether any frame of this transition filters either deck.
    public var filtersAtAll: Bool {
        switch style {
        case .gapless: return false
        case .djFilter: return filterSweep.coerced(0, 1) > 0
        case .djBlend: return bassSwap || vocalOverlap.coerced(0, 1) > 0
        case .equalPower: return vocalOverlap.coerced(0, 1) > 0
        }
    }

    // MARK: - Styles

    private func filters(at progress: Double) -> (outgoing: DeckFilter, incoming: DeckFilter) {
        switch style {
        case .djFilter: return rideFilterSweep(progress)
        case .djBlend: return bassSwap ? rideBassSwap(progress) : rideVocalSeparation(progress)
        // An album being played through, where any filtering would be an edit the record didn't
        // ask for — so it stays open whatever the material does.
        case .gapless: return (.open, .open)
        // The tier is decided by tempo and beat confidence; whether both tracks are singing is
        // measured separately. A pair with useless tempo evidence can still have a good vocal mask
        // on both sides saying they collide, and the weak half of the evidence must not silence
        // the strong half.
        case .equalPower: return rideVocalSeparation(progress)
        }
    }

    /// The minimum intervention: pull two colliding vocals apart, otherwise leave the spectrum
    /// alone. Zero overlap leaves both sides open.
    private func rideVocalSeparation(_ progress: Double) -> (DeckFilter, DeckFilter) {
        let amount = vocalOverlap.coerced(0, 1)
        if amount <= 0 { return (.open, .open) }
        let open = Self.openHz
        // Both endpoints scaled by the collision, so a marginal clash is nudged and a full one is
        // properly separated.
        let floor = Self.glide(open, Self.vocalSeparationFloorHz, amount)
        let outgoing = DeckFilter(
            lowPassHz: Self.glide(open, floor, pow(progress, Self.filterSweepShape)),
            highPassHz: Self.offHz
        )
        let incoming = DeckFilter(
            lowPassHz: Self.openHz,
            highPassHz: Self.entryHighPass(progress, amount: amount, topHz: Self.vocalSeparationHighPassHz, openBy: Self.entryOpenBy)
        )
        return (outgoing, incoming)
    }

    /// Pulls the outgoing track behind a closing low-pass while the incoming one arrives with its
    /// body lifted out, for a pair too far apart in tempo to blend flat. Both sides are filtered
    /// so the two occupy complementary bands through the middle of the blend and never compete
    /// for the range a voice lives in.
    private func rideFilterSweep(_ progress: Double) -> (DeckFilter, DeckFilter) {
        let sweep = filterSweep.coerced(0, 1)
        if sweep <= 0 { return (.open, .open) }
        // Both ends scaled by the sweep, so a partial sweep engages less sharply *and* stops short
        // of the floor rather than crawling the same distance more slowly.
        let open = Self.openHz
        let entry = Self.glide(open, Self.filterEntryHz, sweep)
        let floor = Self.glide(open, Self.filterFloorHz, sweep)
        let cutoff = Self.glide(entry, floor, pow(progress, Self.filterSweepShape))
        return (
            DeckFilter(lowPassHz: cutoff, highPassHz: Self.offHz),
            DeckFilter(
                lowPassHz: Self.openHz,
                highPassHz: Self.entryHighPass(progress, amount: sweep, topHz: Self.entryHighPassHz, openBy: Self.entryOpenBy)
            )
        )
    }

    /// Hands the low end from one track to the other, once, at the beat the planner chose, ramped
    /// over ``bassSwapWidth`` of the fade because a 24 dB/octave filter appearing in one buffer is
    /// a transient of its own. The midrange is handled lightly: the incoming track still enters
    /// with its body lifted, the outgoing one loses its top in the second half.
    private func rideBassSwap(_ progress: Double) -> (DeckFilter, DeckFilter) {
        let swapAt = bassSwapFraction.coerced(0.05, 0.95)
        // 0 before the swap window, 1 after it: how much of the low end has changed hands.
        let handover = ((progress - swapAt) / Self.bassSwapWidth * 0.5 + 0.5).coerced(0, 1)
        // Scaled up by however much the two are actually singing over each other.
        let clash = vocalOverlap.coerced(0, 1)
        let entry = max(
            Self.bassCutoff(1 - handover),
            Self.entryHighPass(
                progress,
                amount: 1,
                topHz: Self.glide(Self.blendEntryHighPassHz, Self.blendEntryClashHighPassHz, clash),
                openBy: Self.blendEntryOpenBy + (Self.blendEntryClashOpenBy - Self.blendEntryOpenBy) * clash
            )
        )
        return (
            DeckFilter(lowPassHz: Self.blendExitLowPass(progress, clash: clash), highPassHz: Self.bassCutoff(handover)),
            DeckFilter(lowPassHz: Self.openHz, highPassHz: entry)
        )
    }

    /// The outgoing low-pass through a beat-matched blend: open until the exit point, then closing
    /// to 2.2 kHz by the end. Deliberately shallow; a collision starts it earlier and takes it further.
    private static func blendExitLowPass(_ progress: Double, clash: Double) -> Double {
        let from = blendExitFrom + (blendExitClashFrom - blendExitFrom) * clash
        let amount = ((progress - from) / (1 - from)).coerced(0, 1)
        let floor = glide(blendExitLowPassHz, blendExitClashLowPassHz, clash)
        return glide(openHz, floor, amount)
    }

    /// Where the incoming high-pass sits at `progress`: from `topHz` down to nothing by `openBy` of
    /// the fade, so the track is whole well before it is alone. `amount` scales the gesture.
    private static func entryHighPass(_ progress: Double, amount: Double, topHz: Double, openBy: Double) -> Double {
        let remaining = (1 - progress / openBy).coerced(0, 1)
        return glide(offHz, topHz, amount * pow(remaining, entryShape))
    }

    /// 0 leaves the low end alone; 1 lifts it out entirely.
    private static func bassCutoff(_ amount: Double) -> Double { glide(offHz, bassSwapHz, amount) }

    /// Geometric interpolation between two cutoffs: `amount` 0 gives `from`, 1 gives `to`.
    /// Geometric because pitch is logarithmic — equal Hz steps lurch through the bottom of the
    /// range and crawl through the top.
    static func glide(_ from: Double, _ to: Double, _ amount: Double) -> Double {
        from * pow(to / from, amount.coerced(0, 1))
    }
}

extension TransitionPlan {
    /// Fade progress, 0...1, from the incoming track's media position.
    ///
    /// Measured from where the incoming track was *cued*, not from zero: a plan can drop it in
    /// mid-arrangement, and reading its raw position as elapsed fade would finish the blend on its
    /// first tick. The span is also capped at a third of what the incoming track has left after its
    /// cue, so a long fade into a short track tightens rather than swallowing it; pass nil while
    /// its duration is still unknown.
    public func fadeProgress(incomingPosition: Double, incomingDuration: Double?) -> Double {
        var span = fadeSeconds
        if let incomingDuration, incomingDuration > 0 {
            span = min(span, max(0, incomingDuration - incomingCueTime) / 3)
        }
        span = max(span, 0.001)
        let elapsed = max(0, incomingPosition - incomingCueTime)
        return (elapsed / span).coerced(0, 1)
    }
}
