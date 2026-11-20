import Foundation

/// The shape of one filter in `EqualizerLayout`.
///
/// Shelves rather than bells at the two ends of the manual tab: a bell centred
/// at 60 Hz leaves 40 Hz almost untouched, so "turn the bass up" doesn't turn up
/// the part of the bass people mean. A shelf lifts everything below its corner,
/// which is what the bottom slider is asked for, and the same argument upside
/// down applies to 14 kHz.
public enum EqualizerFilterKind: Sendable {
    case bell
    case lowShelf
    case highShelf
}

/// A slot's fixed identity: its shape and where on the spectrum it sits.
public struct EqualizerFilterSlot: Equatable, Sendable {
    public let kind: EqualizerFilterKind
    public let frequencyHz: Float
}

/// Every filter either equaliser tab can ask for, in one fixed list.
///
/// Both tabs drive the *same* ten slots, and a slot the current tab doesn't use
/// is held at 0 dB rather than removed. That costs nothing — a section at 0 dB
/// is skipped outright by `EqualizerProcessor` — and it buys the thing that
/// matters: the set of running filters never changes shape, so switching tab or
/// preset is a gain change like any other and glides silently. Rebuilding the
/// cascade instead would drop filter state on the floor mid-signal, which is a
/// click every time.
public enum EqualizerLayout {

    /// The seven centres the manual tab puts a slider under.
    public static let manualBandsHz: [Float] = [60, 150, 400, 1_000, 2_500, 6_000, 14_000]

    /// Wide enough to overlap its neighbours — the centres are about 1.3 octaves
    /// apart, so a Q near 1 means pushing every slider up lifts the whole band
    /// evenly instead of leaving scallops between them.
    public static let manualQ: Float = 1.0

    /// Slots 0..<7: the manual tab.
    public static let manualFirst = 0
    public static let manualCount = 7

    /// Slots 7...9: the tone pad's tilt pair and its mid contour.
    public static let toneLow = 7
    public static let toneMid = 8
    public static let toneHigh = 9

    public static let slotCount = 10

    public static let slots: [EqualizerFilterSlot] = {
        var slots = manualBandsHz.enumerated().map { index, hz in
            let kind: EqualizerFilterKind
            switch index {
            case 0: kind = .lowShelf
            case manualBandsHz.count - 1: kind = .highShelf
            default: kind = .bell
            }
            return EqualizerFilterSlot(kind: kind, frequencyHz: hz)
        }
        slots.append(EqualizerFilterSlot(kind: .lowShelf, frequencyHz: 250))
        slots.append(EqualizerFilterSlot(kind: .bell, frequencyHz: 1_000))
        slots.append(EqualizerFilterSlot(kind: .highShelf, frequencyHz: 4_000))
        return slots
    }()

    /// How far a manual slider travels either way.
    public static let manualRangeDb: Float = 12

    /// How far the tone pad travels on each axis, in whole steps.
    public static let toneSteps = 5

    /// Decibels per step of the pad, so a corner is ±6 dB.
    public static let toneDbPerStep: Float = 1.2

    /// Frequency of the tone pad's tilt pair, for the UI to describe.
    public static let toneTiltHz: [Float] = [250, 4_000]

    /// Q every slot rests at when nothing has set it.
    static let restingQ: Float = 0.707
}

/// A tuning, rendered: what every slot in `EqualizerLayout` is set to.
///
/// Gains and Qs both, because Broad/Focused moves Q while the pad stays put —
/// see `tone(x:y:focused:)`.
public struct EqualizerCurve: Equatable, Sendable {
    /// One gain per slot, in decibels.
    public let gainsDb: [Float]

    /// One Q per slot.
    public let qs: [Float]

    /// Make-up attenuation, at or below zero for every curve `of`, `manual` and
    /// `tone` build. Boosting a band raises the peak of the signal with it, and
    /// 16-bit PCM has no headroom above full scale to put that in, so the whole
    /// curve is pulled down by however much its loudest point was pushed up.
    public let preampDb: Float

    /// A curve with an explicit make-up gain. Most callers want `of(gainsDb:qs:)`,
    /// which works the make-up out.
    public init(gainsDb: [Float], qs: [Float], preampDb: Float) {
        precondition(gainsDb.count == EqualizerLayout.slotCount,
                     "gainsDb needs \(EqualizerLayout.slotCount) values, got \(gainsDb.count)")
        precondition(qs.count == EqualizerLayout.slotCount,
                     "qs needs \(EqualizerLayout.slotCount) values, got \(qs.count)")
        self.gainsDb = gainsDb
        self.qs = qs
        self.preampDb = preampDb
    }

    /// Builds a curve and works out the attenuation it needs.
    public static func of(gainsDb: [Float], qs: [Float]) -> EqualizerCurve {
        EqualizerCurve(gainsDb: gainsDb, qs: qs, preampDb: preamp(gainsDb: gainsDb, qs: qs))
    }

    public static let flat = EqualizerCurve.of(
        gainsDb: Array(repeating: 0, count: EqualizerLayout.slotCount),
        qs: Array(repeating: EqualizerLayout.restingQ, count: EqualizerLayout.slotCount)
    )

    /// The seven sliders, as a curve. Slots the tone pad owns stay flat.
    ///
    /// Missing bands (and NaN ones, from a corrupt stored value) read as 0 dB
    /// and every band is held to ±`manualRangeDb`.
    public static func manual(bandsDb: [Float]) -> EqualizerCurve {
        var gains = Array(repeating: Float(0), count: EqualizerLayout.slotCount)
        var qs = Array(repeating: EqualizerLayout.restingQ, count: EqualizerLayout.slotCount)
        let range = EqualizerLayout.manualRangeDb
        for band in 0..<EqualizerLayout.manualCount {
            let value = band < bandsDb.count && !bandsDb[band].isNaN ? bandsDb[band] : 0
            gains[EqualizerLayout.manualFirst + band] = min(max(value, -range), range)
            qs[EqualizerLayout.manualFirst + band] = EqualizerLayout.manualQ
        }
        return .of(gainsDb: gains, qs: qs)
    }

    /// The tone pad, as a curve. Slots the manual tab owns stay flat.
    ///
    /// [x] tilts: left is warm (low shelf up, high shelf down), right is bright,
    /// and the two move by the same amount in opposite directions so the middle
    /// of the spectrum — where most of a mix lives — keeps its level whichever
    /// way the puck goes. [y] is the contour: down scoops the mids into a V, up
    /// pushes them forward.
    ///
    /// [focused] narrows all three. Apple describes the two settings as wider
    /// ranges with a richer sound against specific ranges with less distraction,
    /// which is a description of bandwidth and nothing else, so that is the only
    /// thing it changes.
    public static func tone(x: Int, y: Int, focused: Bool) -> EqualizerCurve {
        var gains = Array(repeating: Float(0), count: EqualizerLayout.slotCount)
        var qs = Array(repeating: EqualizerLayout.restingQ, count: EqualizerLayout.slotCount)
        let steps = EqualizerLayout.toneSteps
        let tilt = Float(min(max(x, -steps), steps)) * EqualizerLayout.toneDbPerStep
        let contour = Float(min(max(y, -steps), steps)) * EqualizerLayout.toneDbPerStep

        gains[EqualizerLayout.toneLow] = -tilt
        gains[EqualizerLayout.toneHigh] = tilt
        gains[EqualizerLayout.toneMid] = contour

        let shelfQ: Float = focused ? 0.9 : 0.5
        let bellQ: Float = focused ? 2.2 : 0.7
        qs[EqualizerLayout.toneLow] = shelfQ
        qs[EqualizerLayout.toneHigh] = shelfQ
        qs[EqualizerLayout.toneMid] = bellQ
        return .of(gainsDb: gains, qs: qs)
    }

    /// The curve's predicted gain at [hz] in decibels, before make-up — what the
    /// equaliser screen draws. The cascade's magnitudes multiply, so the
    /// sections' decibels add.
    public func responseDb(atHz hz: Float) -> Float {
        var sum: Float = 0
        for slot in 0..<EqualizerLayout.slotCount {
            sum += Self.sectionGainDb(EqualizerLayout.slots[slot], gainDb: gainsDb[slot], q: qs[slot], hz: hz)
        }
        return sum
    }

    // ---- Make-up -----------------------------------------------------------

    /// How far down the curve has to be pulled to stop it clipping.
    ///
    /// Taking the largest single band gain would under-read it: the bands
    /// overlap, so two neighbours at +6 dB are worth more than +6 dB between
    /// them. This walks the summed response instead and takes its actual peak.
    /// Runs on whoever changed the setting, never on the audio thread.
    static func preamp(gainsDb: [Float], qs: [Float]) -> Float {
        var peak: Float = 0
        for point in 0..<responsePoints {
            let hz = responseFrequency(point)
            var sum: Float = 0
            for slot in 0..<EqualizerLayout.slotCount {
                sum += sectionGainDb(EqualizerLayout.slots[slot], gainDb: gainsDb[slot], q: qs[slot], hz: hz)
            }
            if sum > peak { peak = sum }
        }
        return -peak
    }

    /// Enough to find the peak of a curve this smooth without wasting time on it.
    static let responsePoints = 96

    /// Log-spaced across the audible band: 20 Hz to 20 kHz.
    static func responseFrequency(_ point: Int) -> Float {
        let fraction = Double(point) / Double(responsePoints - 1)
        return Float(20.0 * pow(1_000.0, fraction))
    }

    /// One section's contribution at [hz], in decibels.
    ///
    /// The analog prototypes these are the magnitudes of are exactly what
    /// `EqualizerProcessor`'s state-variable mixes realise — the bilinear
    /// transform only bends the frequency axis near Nyquist, which is nowhere
    /// near where a peak worth attenuating for lands.
    static func sectionGainDb(_ slot: EqualizerFilterSlot, gainDb: Float, q: Float, hz: Float) -> Float {
        if abs(gainDb) < 0.01 { return 0 }
        let a = pow(10.0, Double(gainDb) / 40.0)
        let a2 = a * a
        let x = Double(hz / slot.frequencyHz)
        let x2 = x * x
        let qq = Double(q * q)
        let magnitude: Double
        switch slot.kind {
        case .bell:
            let flat = (1 - x2) * (1 - x2)
            magnitude = sqrt((flat + x2 * a2 / qq) / (flat + x2 / (a2 * qq)))
        case .lowShelf:
            let common = x2 * a / qq
            magnitude = a * sqrt(((a - x2) * (a - x2) + common) / ((1 - a * x2) * (1 - a * x2) + common))
        case .highShelf:
            let common = x2 * a / qq
            magnitude = a * sqrt(((1 - a * x2) * (1 - a * x2) + common) / ((a - x2) * (a - x2) + common))
        }
        return Float(20.0 * log10(magnitude))
    }
}
