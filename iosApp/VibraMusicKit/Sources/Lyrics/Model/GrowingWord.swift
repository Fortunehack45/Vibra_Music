import Foundation

/// One word held long enough to be animated a letter at a time.
///
/// Every letter runs the same three-beat move — swell up and forward, hold, then settle
/// back to the small lift every sung word carries — but each one starts `growStagger` of
/// the word's own length after the one before it, so the movement travels along the word
/// instead of the whole thing pulsing at once.
///
/// The peaks differ letter by letter as well. Later letters of a long word, and every
/// letter of a word that is only just held long enough to qualify, move and light less:
/// without that a seven-letter word read as a wave with a tail that kept going after the
/// singer had stopped.
///
/// Peaks are precomputed here because they depend only on the word — its length and how
/// long it is held — while the frame only ever asks where in the move a given letter has
/// got to. Letters are counted in UTF-16 units, as on Android; the words that qualify
/// (see `canGrow`) are ones where that is also one unit per visible letter.
public struct GrowingWord: Sendable, Hashable {
    /// Which of the line's words this is.
    public let index: Int
    public let startMs: Int
    public let endMs: Int
    /// When the last letter has finished moving and is just sitting lifted.
    public let restsAtMs: Int
    /// How many letters (UTF-16 units) the word has.
    public let letterCount: Int

    private let scalePeak: [Float]
    private let shiftPeak: [Float]
    private let risePeak: [Float]
    private let bloomPeak: [Float]

    init(index: Int, word: LyricWord) {
        self.index = index
        startMs = word.startMs
        endMs = word.endMs
        let chars = word.text.kLength
        letterCount = chars

        let held = Float(max(endMs - startMs, 1))
        // How much of the full treatment this word has earned. Cubed, so the difference
        // between a word held for a second and one held for three is most of the range and
        // everything under a second is barely anything.
        let ramp = kClamp((held - GrowConstants.rampMinMs) / (GrowConstants.rampMaxMs - GrowConstants.rampMinMs), 0, 1)
        let earned = ramp * ramp * ramp
        let decay = growDecayRate(length: chars, heldMs: held)
        // A word barely over the line glows less than one held twice as long, and a long
        // word spreads what it has over more letters.
        let bloomPace = min(GrowConstants.bloomPaceMax, held / GrowConstants.bloomPaceMs)
        let bloomSpread: Float = chars <= 3 ? GrowConstants.bloomShort : (chars >= 6 ? GrowConstants.bloomLong : 1)
        // Short words swell a little more, having fewer letters to do it with.
        let base = chars <= 3 ? GrowConstants.baseShort : GrowConstants.baseLong
        let liftPace = kClamp(held / GrowConstants.liftPaceMs, GrowConstants.liftFloor, 1)

        var scale = [Float](repeating: 0, count: chars)
        var shift = [Float](repeating: 0, count: chars)
        var rise = [Float](repeating: 0, count: chars)
        var bloom = [Float](repeating: 0, count: chars)
        for i in 0..<chars {
            let place: Float = chars > 1 ? Float(i) / Float(chars - 1) : 0
            let reach = earned * (1 - place * decay)
            let peak = 1 + base + reach * GrowConstants.scaleRange
            scale[i] = peak * GrowConstants.scaleTrim
            bloom[i] = (GrowConstants.bloomFloor + reach * GrowConstants.bloomRange) * bloomPace * bloomSpread
            // The lift is read off the swell rather than set on its own: a letter that grows
            // more rises further, which keeps the two reading as one movement.
            rise[i] = ((peak - 1) / GrowConstants.scaleCeiling) * liftPace
            // Letters lean away from the middle of the word as it swells, so it opens
            // outwards rather than every letter sliding the same way.
            let centre = (Float(i) + 0.5) / Float(chars)
            shift[i] = (centre - 0.5) * 2 * (peak - 1) * GrowConstants.shiftEm * GrowConstants.scaleTrim
        }
        scalePeak = scale
        shiftPeak = shift
        risePeak = rise
        bloomPeak = bloom

        let last = Float(max(chars - 1, 0)) * GrowConstants.stagger + GrowConstants.span
        restsAtMs = startMs + kLong(Double(held * last))
    }

    /// Where letter `charIndex` has got to at `positionMs`.
    ///
    /// `CharGrowth.rise` comes back in multiples of the ordinary sung-word lift and
    /// `CharGrowth.shift` in ems, so the caller converts once with the font size it is
    /// actually drawing at. A value type, so sampling every letter every frame allocates
    /// nothing (Android wrote into a reused object for the same reason).
    public func sample(_ charIndex: Int, _ positionMs: Int) -> CharGrowth {
        guard scalePeak.indices.contains(charIndex) else { return CharGrowth() }
        let span = Float(max(endMs - startMs, 1))
        let elapsed = Float(positionMs - startMs) - Float(charIndex) * span * GrowConstants.stagger
        let phase = kClamp(elapsed / (span * GrowConstants.span), 0, 1)
        let peakScale = scalePeak[charIndex]
        if phase < GrowConstants.phaseIn {
            let t = lyricSmooth(phase / GrowConstants.phaseIn)
            return CharGrowth(
                scale: 1 + (peakScale - 1) * t,
                shift: shiftPeak[charIndex] * t,
                rise: risePeak[charIndex] * t,
                bloom: bloomPeak[charIndex] * t
            )
        }
        if phase < GrowConstants.phaseHold {
            return CharGrowth(
                scale: peakScale,
                shift: shiftPeak[charIndex],
                rise: risePeak[charIndex],
                bloom: bloomPeak[charIndex]
            )
        }
        if phase < GrowConstants.phaseOut {
            let t = lyricSmooth((phase - GrowConstants.phaseHold) / (GrowConstants.phaseOut - GrowConstants.phaseHold))
            return CharGrowth(
                scale: peakScale + (1 - peakScale) * t,
                shift: shiftPeak[charIndex] * (1 - t),
                rise: risePeak[charIndex] + (GrowConstants.rest - risePeak[charIndex]) * t,
                bloom: bloomPeak[charIndex] * (1 - t)
            )
        }
        return CharGrowth(scale: 1, shift: 0, rise: GrowConstants.rest, bloom: 0)
    }
}

/// Where one letter of a `GrowingWord` is.
public struct CharGrowth: Sendable, Hashable {
    /// Swell, about the letter's own centre. 1 is the letter as laid out.
    public var scale: Float = 1
    /// Lean away from the middle of the word, in ems.
    public var shift: Float = 0
    /// Lift, in multiples of the ordinary sung-word rise.
    public var rise: Float = 0
    /// Bloom, 0…1, at its own peak partway up rather than at the top.
    public var bloom: Float = 0

    public init(scale: Float = 1, shift: Float = 0, rise: Float = 0, bloom: Float = 0) {
        self.scale = scale
        self.shift = shift
        self.rise = rise
        self.bloom = bloom
    }
}

extension LyricWord {
    /// Whether this word is held long enough, and is short enough, to be animated a letter
    /// at a time.
    ///
    /// The thresholds are steeper for short words than the length alone suggests: a
    /// two-letter word held for a second is a held note, whereas a seven-letter one held for
    /// the same second is just being sung at an ordinary pace.
    ///
    /// Scripts whose letters are not laid out side by side independently are left alone —
    /// Han, kana and Hangul draw as blocks, and right-to-left scripts join up, so moving one
    /// letter of a word would come apart rather than swell. A hyphenated word is really two
    /// words and would break at the hyphen.
    var canGrow: Bool {
        let length = text.kLength
        if length == 0 || length > GrowConstants.maxChars { return false }
        if text.contains("-") || text.utf16.contains(where: { $0.isBlockScript || $0.isJoinedScript }) { return false }
        let held = endMs - startMs
        switch length {
        case 1: return held >= GrowConstants.minSoloMs
        case 2...3: return held >= GrowConstants.minShortMs + (length - 2) * GrowConstants.shortStepMs
        case 4: return held >= GrowConstants.minFourMs
        default: return held >= GrowConstants.minLongMs && held >= length * GrowConstants.msPerChar
        }
    }
}

private extension UInt16 {
    /// Han, hiragana, katakana and Hangul syllables (Android: `isBlockScript`).
    var isBlockScript: Bool {
        (0x4E00...0x9FFF).contains(self) || (0x3040...0x309F).contains(self)
            || (0x30A0...0x30FF).contains(self) || (0xAC00...0xD7AF).contains(self)
    }

    /// Hebrew and Arabic, U+0590–U+08FF (Android: `isJoinedScript`).
    var isJoinedScript: Bool { (0x0590...0x08FF).contains(self) }
}

/// How much of the movement is taken back off the later letters of a word.
///
/// Two reasons to hold back. A long word is a lot of letters to run a wave through, and
/// left flat the tail of it is still swelling well after the singer has moved on. A word
/// held only just long enough to qualify has no room for a wave at all, so the whole thing
/// is damped towards a single swell.
private func growDecayRate(length: Int, heldMs: Float) -> Float {
    let long = length > GrowConstants.decayLongChars
    let quick = heldMs < GrowConstants.decayQuickMs
    if !long && !quick { return 0 }
    var strength: Float = 0
    if long {
        strength += min(Float(length - GrowConstants.decayLongChars) / 5, 1) * GrowConstants.decayLong
    }
    if quick {
        let short = max(0, 1 - (heldMs - GrowConstants.decayQuickFloorMs) / 400)
        strength += short * (length > 3 ? GrowConstants.decayQuick : GrowConstants.decayQuickTiny)
    }
    return min(strength, GrowConstants.decayMax)
}

private enum GrowConstants {
    /// Longest word worth running a wave through; past this it reads as a ripple.
    static let maxChars = 7

    /// How long a word of each length has to be held before it qualifies.
    static let minSoloMs = 1_100
    static let minShortMs = 1_360
    static let shortStepMs = 140
    static let minFourMs = 1_050
    static let minLongMs = 900
    static let msPerChar = 200

    static let decayLongChars = 5
    static let decayQuickMs: Float = 1_200
    static let decayQuickFloorMs: Float = 800
    static let decayLong: Float = 0.4
    static let decayQuick: Float = 0.3
    static let decayQuickTiny: Float = 0.1
    static let decayMax: Float = 0.7

    /// Each letter starts this far — as a share of the word's own length — after the one
    /// before it, so the swell travels rather than pulsing.
    static let stagger: Float = 0.09
    /// The whole move runs half again as long as the word is held.
    static let span: Float = 1.5
    /// Up by `phaseIn`, held to `phaseHold`, settled by `phaseOut`.
    static let phaseIn: Float = 0.25
    static let phaseHold: Float = 0.30
    static let phaseOut: Float = 0.75
    /// Where a letter comes to rest: the same small lift every sung word carries.
    static let rest: Float = 1

    /// The window over which a longer hold earns more of the treatment.
    static let rampMinMs: Float = 400
    static let rampMaxMs: Float = 3_000

    /// Swell every qualifying letter gets, and the range the hold adds on top.
    static let baseShort: Float = 0.05
    static let baseLong: Float = 0.04
    static let scaleRange: Float = 0.08
    /// The most any letter swells, which is what the lift is read off.
    static let scaleCeiling: Float = 0.1
    /// Taken back off the swell so it stops a hair short of the ceiling.
    static let scaleTrim: Float = 0.98
    /// Lean, as a share of the font size at full swell.
    static let shiftEm: Float = 25.0 / 34.0

    /// The bloom's floor, and what the hold adds to it.
    static let bloomFloor: Float = 0.35
    static let bloomRange: Float = 0.45
    static let bloomPaceMs: Float = 1_500
    static let bloomPaceMax: Float = 1.1
    static let bloomShort: Float = 0.85
    static let bloomLong: Float = 1.1

    /// A word held this long lifts as far as it is going to.
    static let liftPaceMs: Float = 2_000
    static let liftFloor: Float = 0.3
}
