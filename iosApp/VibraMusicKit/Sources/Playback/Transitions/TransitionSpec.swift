import Foundation

// The plain-data description of one transition the engine executes: when it starts, how long the
// two tracks overlap, how each deck's gain moves, and how each deck's transition filter rides.
//
// A standard crossfade is one of these (see `TransitionSpec.crossfade`); an Automix plan is another,
// built by the Automix module from its analysis and handed over through `TransitionPlanning`. The
// engine does not know which it is running — the same executor (CrossfadeController) drives both,
// which is how the Android CrossfadeController ran standard and Smart transitions through one path.

/// Low-pass and high-pass cutoffs for one side of a transition.
///
/// A low-pass at or above ``openHz`` and a high-pass at or below ``offHz`` are inaudible, so they
/// mean "not filtering" — the state both decks return to between transitions. Same limits as the
/// Android `TransitionFilterProcessor.OPEN_HZ` / `OFF_HZ`, so a DSP port reads them unchanged.
public struct TransitionFilterCutoffs: Hashable, Sendable {
    public var lowPassHz: Float
    public var highPassHz: Float

    public static let openHz: Float = 20_000
    public static let offHz: Float = 20
    public static let open = TransitionFilterCutoffs(lowPassHz: openHz, highPassHz: offHz)

    public init(lowPassHz: Float, highPassHz: Float) {
        self.lowPassHz = lowPassHz
        self.highPassHz = highPassHz
    }

    public var isOpen: Bool { lowPassHz >= Self.openHz && highPassHz <= Self.offHz }
}

/// A gain value at a point of the transition (0 = its start, 1 = its end).
public struct TransitionGainKeyframe: Hashable, Sendable {
    public var progress: Double
    public var gain: Float

    public init(progress: Double, gain: Float) {
        self.progress = progress
        self.gain = gain
    }
}

/// How one deck's gain moves across the transition, as a function of progress 0…1.
public enum TransitionGainCurve: Hashable, Sendable {
    /// `sin(p·π/2)`. With ``equalPowerFall`` on the other deck, `rise² + fall² = 1` exactly, so two
    /// tracks fading past each other hold constant power and the blend has no dip in the middle —
    /// the standard crossfade law the Android controller moved to from `sqrt`.
    case equalPowerRise
    /// `cos(p·π/2)`.
    case equalPowerFall
    case linearRise
    case linearFall
    /// Piecewise-linear through the keyframes (sorted by progress; held flat outside them).
    case keyframes([TransitionGainKeyframe])

    public func gain(at progress: Double) -> Float {
        let p = min(max(progress, 0), 1)
        switch self {
        case .equalPowerRise: return Float(sin(p * .pi / 2))
        case .equalPowerFall: return Float(cos(p * .pi / 2))
        case .linearRise: return Float(p)
        case .linearFall: return Float(1 - p)
        case .keyframes(let frames):
            guard let first = frames.first else { return 1 }
            let sorted = frames.sorted { $0.progress < $1.progress }
            if p <= sorted[0].progress { return sorted[0].gain }
            for (a, b) in zip(sorted, sorted.dropFirst()) where p <= b.progress {
                let span = b.progress - a.progress
                guard span > 0 else { return b.gain }
                return a.gain + (b.gain - a.gain) * Float((p - a.progress) / span)
            }
            return sorted.last?.gain ?? first.gain
        }
    }
}

/// Cutoffs for one deck at a point of the transition.
public struct TransitionFilterKeyframe: Hashable, Sendable {
    public var progress: Double
    public var cutoffs: TransitionFilterCutoffs

    public init(progress: Double, cutoffs: TransitionFilterCutoffs) {
        self.progress = progress
        self.cutoffs = cutoffs
    }
}

/// How the two decks' transition filters move across the transition.
public enum TransitionFilterAutomation: Hashable, Sendable {
    /// Both decks unfiltered throughout.
    case none
    /// The Android controller's style-driven ride (filter sweep, bass swap, vocal separation).
    case ride(TransitionFilterRide)
    /// Explicit automation per deck. Interpolated geometrically between keyframes, because pitch is
    /// logarithmic: a cutoff moving in equal Hz steps lurches through the bottom of its range.
    case keyframes(incoming: [TransitionFilterKeyframe], outgoing: [TransitionFilterKeyframe])

    public func cutoffs(at progress: Double) -> (incoming: TransitionFilterCutoffs, outgoing: TransitionFilterCutoffs) {
        switch self {
        case .none:
            return (.open, .open)
        case .ride(let ride):
            return ride.cutoffs(at: Float(progress))
        case .keyframes(let incoming, let outgoing):
            return (Self.interpolate(incoming, progress), Self.interpolate(outgoing, progress))
        }
    }

    /// Whether this automation ever takes a deck away from open — part of what makes a transition a
    /// "real mix" rather than a plain fade.
    var filtersAnything: Bool {
        switch self {
        case .none: return false
        case .ride(let ride): return ride.style == .djBlend || ride.style == .djFilter
        case .keyframes(let incoming, let outgoing):
            return (incoming + outgoing).contains { !$0.cutoffs.isOpen }
        }
    }

    private static func interpolate(_ frames: [TransitionFilterKeyframe], _ progress: Double) -> TransitionFilterCutoffs {
        guard !frames.isEmpty else { return .open }
        let p = min(max(progress, 0), 1)
        let sorted = frames.sorted { $0.progress < $1.progress }
        if p <= sorted[0].progress { return sorted[0].cutoffs }
        for (a, b) in zip(sorted, sorted.dropFirst()) where p <= b.progress {
            let span = b.progress - a.progress
            guard span > 0 else { return b.cutoffs }
            let t = (p - a.progress) / span
            return TransitionFilterCutoffs(
                lowPassHz: Float(TransitionFilterRide.glide(Double(a.cutoffs.lowPassHz), Double(b.cutoffs.lowPassHz), t)),
                highPassHz: Float(TransitionFilterRide.glide(Double(a.cutoffs.highPassHz), Double(b.cutoffs.highPassHz), t))
            )
        }
        return sorted[sorted.count - 1].cutoffs
    }
}

/// One transition, in the outgoing track's own timeline.
public struct TransitionSpec: Hashable, Sendable {
    /// Where in the outgoing track the incoming one starts sounding, in seconds.
    public var startTime: TimeInterval
    /// How long both are audible, in seconds of the incoming track's content (so a pause, or a
    /// tempo stretch, moves progress with the music rather than with the wall clock).
    public var overlap: TimeInterval
    /// Where the incoming track is cued: 0 for a plain crossfade, an analysed mix-in point for
    /// Automix. The incoming deck *opens* there rather than seeking, so the cue costs nothing.
    public var incomingCueTime: TimeInterval
    /// Tempo stretch applied to the incoming track for the transition, stacked on the listener's
    /// playback speed and undone when the transition finishes. 1 is none.
    public var incomingRate: Double
    public var outgoingGain: TransitionGainCurve
    public var incomingGain: TransitionGainCurve
    public var filters: TransitionFilterAutomation
    /// Whether the UI may draw this transition's window on the scrubber. The Android controller
    /// only showed it once both tracks were analysed; the planner decides that here.
    public var markerVisible: Bool

    public init(
        startTime: TimeInterval,
        overlap: TimeInterval,
        incomingCueTime: TimeInterval = 0,
        incomingRate: Double = 1,
        outgoingGain: TransitionGainCurve = .equalPowerFall,
        incomingGain: TransitionGainCurve = .equalPowerRise,
        filters: TransitionFilterAutomation = .none,
        markerVisible: Bool = false
    ) {
        self.startTime = startTime
        self.overlap = overlap
        self.incomingCueTime = max(incomingCueTime, 0)
        self.incomingRate = incomingRate > 0 ? incomingRate : 1
        self.outgoingGain = outgoingGain
        self.incomingGain = incomingGain
        self.filters = filters
        self.markerVisible = markerVisible
    }

    /// Where the outgoing track's part of the transition ends.
    public var endTime: TimeInterval { startTime + overlap }

    /// The standard crossfade: equal-power, unfiltered, the incoming track from its first frame,
    /// timed so the fade ends exactly as the outgoing track does.
    public static func crossfade(endingAt end: TimeInterval, overlap: TimeInterval) -> TransitionSpec {
        TransitionSpec(startTime: end - overlap, overlap: overlap)
    }

    /// Whether this transition does something a plain crossfade could not — a filtering style, an
    /// incoming track cued into its arrangement, or a tempo stretch. What the Android controller
    /// lit the scrubber up for (`isRealMix`); an unanalysed pair fading equal-power from 0:00 is not.
    public var isRealMix: Bool {
        filters.filtersAnything || incomingCueTime > 0 || incomingRate != 1
    }
}

/// What a planner is asked about, every idle tick while a transition could be planned.
public struct TransitionContext: Sendable {
    public var outgoing: PlayableItem
    public var incoming: PlayableItem
    /// The outgoing track's position and length, in seconds.
    public var position: TimeInterval
    public var duration: TimeInterval
    /// The incoming track's length, when known (decoder, or the catalogue's figure).
    public var incomingDuration: TimeInterval?
    /// The overlap to use when analysis is missing or too weak for more than a plain fade: the
    /// listener's crossfade length when set, otherwise six seconds (the Android
    /// `DEFAULT_SMART_FALLBACK_SECONDS`).
    public var fallbackOverlap: TimeInterval

    public init(
        outgoing: PlayableItem,
        incoming: PlayableItem,
        position: TimeInterval,
        duration: TimeInterval,
        incomingDuration: TimeInterval?,
        fallbackOverlap: TimeInterval
    ) {
        self.outgoing = outgoing
        self.incoming = incoming
        self.position = position
        self.duration = duration
        self.incomingDuration = incomingDuration
        self.fallbackOverlap = fallbackOverlap
    }
}

/// Plans Automix transitions. The Automix module implements this; the engine asks it on every idle
/// tick (four times a second) while Automix is on and the current pair can transition, so it must
/// be cheap — the Android planner ran on the same cadence.
///
/// Returning nil means "no transition for this pair right now" (blocked, or not enough evidence to
/// place one): the tracks then change gaplessly.
@MainActor
public protocol TransitionPlanning: AnyObject {
    func transitionSpec(for context: TransitionContext) -> TransitionSpec?
}
