import Foundation

/// The filter ride the Android `CrossfadeController.rideFilters` rendered for each Automix
/// transition style, ported number for number. The gain curve is the same equal-power pair for
/// every style; this is what makes them sound different from each other.
///
/// Everything here is a pure function of fade progress, so the ride stays locked to the gains: a
/// pause parks the filters exactly where it parks the fade.
public struct TransitionFilterRide: Hashable, Sendable {
    public enum Style: String, Hashable, Sendable, CaseIterable {
        /// A constant-power fade. Filtered only to pull two colliding vocals apart.
        case equalPower
        /// Album siblings played through: never filtered, since any filtering would be an edit the
        /// record didn't ask for.
        case gapless
        /// Beat-aligned blend, optionally handing the low end over at one beat (bass swap).
        case djBlend
        /// Filtered handoff for tempi too far apart to blend flat.
        case djFilter
    }

    public var style: Style
    public var bassSwap: Bool
    /// Where in the fade the low end changes hands (clamped to 0.05…0.95).
    public var bassSwapFraction: Double
    /// How far a filter ride goes, 0…1.
    public var filterSweep: Double
    /// How strongly the two tracks are expected to sing over each other, 0…1.
    public var vocalOverlap: Double

    public init(
        style: Style,
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

    public func cutoffs(at progress: Float) -> (incoming: TransitionFilterCutoffs, outgoing: TransitionFilterCutoffs) {
        switch style {
        case .djFilter: return rideFilterSweep(progress)
        case .djBlend: return bassSwap ? rideBassSwap(progress) : rideVocalSeparation(progress)
        case .gapless: return (.open, .open)
        // The bottom tier by tempo evidence can still carry a perfectly good vocal mask saying the
        // two tracks collide; the weak half of the evidence must not silence the strong half.
        case .equalPower: return rideVocalSeparation(progress)
        }
    }

    // MARK: - Styles

    /// Damage control on a pair that was going to be crossfaded plainly: the outgoing track loses
    /// its top while the incoming one enters with its body lifted, over a short distance, and only
    /// as far as the measured collision justifies. Zero overlap leaves both sides open.
    private func rideVocalSeparation(_ progress: Float) -> (incoming: TransitionFilterCutoffs, outgoing: TransitionFilterCutoffs) {
        let amount = Self.clamp(vocalOverlap)
        guard amount > 0 else { return (.open, .open) }
        let open = Double(TransitionFilterCutoffs.openHz)
        let floor = Self.glide(open, Self.vocalSeparationFloorHz, amount)
        let outgoing = TransitionFilterCutoffs(
            lowPassHz: Float(Self.glide(open, floor, pow(Double(progress), Self.filterSweepShape))),
            highPassHz: TransitionFilterCutoffs.offHz
        )
        let incoming = TransitionFilterCutoffs(
            lowPassHz: TransitionFilterCutoffs.openHz,
            highPassHz: Self.entryHighPass(progress, amount, Self.vocalSeparationHighPassHz, Self.entryOpenBy)
        )
        return (incoming, outgoing)
    }

    /// Pulls the outgoing track behind a closing low-pass while the incoming one arrives
    /// high-passed — hats and presence, no vocal body — so the two hold complementary bands
    /// through the middle of the blend instead of doubling the midrange. Front-loaded
    /// (``filterSweepShape`` below 1), settling onto a 300 Hz bed rather than silence.
    private func rideFilterSweep(_ progress: Float) -> (incoming: TransitionFilterCutoffs, outgoing: TransitionFilterCutoffs) {
        let sweep = Self.clamp(filterSweep)
        guard sweep > 0 else { return (.open, .open) }
        let open = Double(TransitionFilterCutoffs.openHz)
        let entry = Self.glide(open, Self.filterEntryHz, sweep)
        let floor = Self.glide(open, Self.filterFloorHz, sweep)
        let cutoff = Self.glide(entry, floor, pow(Double(progress), Self.filterSweepShape))
        return (
            TransitionFilterCutoffs(
                lowPassHz: TransitionFilterCutoffs.openHz,
                highPassHz: Self.entryHighPass(progress, sweep, Self.entryHighPassHz, Self.entryOpenBy)
            ),
            TransitionFilterCutoffs(lowPassHz: Float(cutoff), highPassHz: TransitionFilterCutoffs.offHz)
        )
    }

    /// Hands the low end from one track to the other at the planner's beat, ramped over
    /// ``bassSwapWidth`` of the fade because a 24 dB/octave filter appearing in one buffer is a
    /// transient of its own. The midrange is handled lightly: the incoming track enters with its
    /// body lifted, the outgoing one loses its top late in the blend.
    private func rideBassSwap(_ progress: Float) -> (incoming: TransitionFilterCutoffs, outgoing: TransitionFilterCutoffs) {
        let swapAt = min(max(bassSwapFraction, 0.05), 0.95)
        // 0 before the swap window, 1 after it: how much of the low end has changed hands.
        let handover = Self.clamp((Double(progress) - swapAt) / Self.bassSwapWidth * 0.5 + 0.5)
        let clash = Self.clamp(vocalOverlap)
        let entry = max(
            Self.bassCutoff(1 - handover),
            Self.entryHighPass(
                progress,
                1,
                Self.glide(Self.blendEntryHighPassHz, Self.blendEntryClashHighPassHz, clash),
                Self.blendEntryOpenBy + (Self.blendEntryClashOpenBy - Self.blendEntryOpenBy) * clash
            )
        )
        return (
            TransitionFilterCutoffs(lowPassHz: TransitionFilterCutoffs.openHz, highPassHz: entry),
            TransitionFilterCutoffs(lowPassHz: Self.blendExitLowPass(progress, clash), highPassHz: Self.bassCutoff(handover))
        )
    }

    // MARK: - Shapes

    /// The outgoing low-pass through a beat-matched blend: open until ``blendExitFrom``, then
    /// closing to ``blendExitLowPassHz`` by the end. A vocal clash starts it earlier and takes it
    /// further.
    static func blendExitLowPass(_ progress: Float, _ clash: Double) -> Float {
        let from = blendExitFrom + (blendExitClashFrom - blendExitFrom) * clash
        let amount = clamp((Double(progress) - from) / (1 - from))
        let floor = glide(blendExitLowPassHz, blendExitClashLowPassHz, clash)
        return Float(glide(Double(TransitionFilterCutoffs.openHz), floor, amount))
    }

    /// The incoming high-pass: from `topHz` down to nothing by `openBy` of the fade, shaped by
    /// ``entryShape`` so the corner lingers in the range a voice occupies instead of dropping
    /// straight into sub-bass, where a high-pass is inaudible.
    static func entryHighPass(_ progress: Float, _ amount: Double, _ topHz: Double, _ openBy: Double) -> Float {
        let remaining = clamp(1 - Double(progress) / openBy)
        return Float(glide(Double(TransitionFilterCutoffs.offHz), topHz, amount * pow(remaining, entryShape)))
    }

    /// 0 leaves the low end alone; 1 lifts it out entirely.
    static func bassCutoff(_ amount: Double) -> Float {
        Float(glide(Double(TransitionFilterCutoffs.offHz), bassSwapHz, amount))
    }

    /// Geometric interpolation between two cutoffs: `amount` 0 gives `from`, 1 gives `to`.
    static func glide(_ from: Double, _ to: Double, _ amount: Double) -> Double {
        from * pow(to / from, clamp(amount))
    }

    static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }

    // MARK: - Constants (the Android CrossfadeController's, with its reasoning)

    /// Where the outgoing low-pass sits the instant a filter ride begins: inside the presence
    /// range, so the gesture is audible on the voice from the first instant.
    static let filterEntryHz = 7_000.0
    /// The bottom of a filter ride; below a few hundred hertz a track reads as broken, not distant.
    static let filterFloorHz = 300.0
    /// Where the low end ends: clears the kick and the sub, leaves the body of the vocal alone.
    static let bassSwapHz = 200.0
    /// How much of the fade the low end takes to change hands.
    static let bassSwapWidth = 0.10
    /// Below 1 so the outgoing ride is front-loaded: a hand moves a filter knob fast, then eases.
    static let filterSweepShape = 0.75
    /// The incoming high-pass on a filter ride: presence and percussion first, no lead vocal.
    static let entryHighPassHz = 1_200.0
    /// How far into the fade the incoming track is fully open again.
    static let entryOpenBy = 0.6
    /// Shape of the incoming high-pass's descent.
    static let entryShape = 0.35
    /// How far vocal separation closes the outgoing top at a full collision.
    static let vocalSeparationFloorHz = 1_600.0
    /// Where the incoming high-pass starts in vocal separation.
    static let vocalSeparationHighPassHz = 700.0
    /// The incoming entry corner on a beat-matched blend, and at a full vocal collision.
    static let blendEntryHighPassHz = 520.0
    static let blendEntryOpenBy = 0.45
    static let blendEntryClashHighPassHz = 950.0
    static let blendEntryClashOpenBy = 0.7
    /// Where the outgoing top starts closing on a blend, and where it lands.
    static let blendExitFrom = 0.3
    static let blendExitLowPassHz = 2_200.0
    static let blendExitClashFrom = 0.12
    static let blendExitClashLowPassHz = 1_100.0
}
