import AudioDSP
import VibraMusicCore
import CoreGraphics
import Foundation

// The arithmetic behind ui/screens/EqualizerScreen.kt's controls: where a touch lands on the tone
// pad, how a fader snaps, and how the numbers are printed. Kept apart from the views so it can be
// tested without a touch.

enum EqualizerMath {
    /// Whole steps either way on each axis of the tone pad.
    static let toneSteps = AppSettings.equalizerToneSteps
    /// How far a manual band travels either way, in dB.
    static let rangeDb = AppSettings.equalizerBandRangeDb
    /// The seven manual band centres, low to high.
    static let bandsHz = EqualizerLayout.manualBandsHz

    /// How close to flat a band has to be dragged before it snaps there.
    static let zeroDetentDb: Float = 0.6
    /// The same, for the balance trim's centre.
    static let balanceDetent: Float = 0.04

    /// Which step of the pad `point` is over, clamped to the grid. `inset` is the puck radius: the
    /// puck's centre never leaves the pad. Screen y grows downwards and the control does not: up
    /// is more contour.
    static func toneStep(at point: CGPoint, in size: CGSize, inset: CGFloat, steps: Int = toneSteps) -> (x: Int, y: Int) {
        let usableWidth = max(size.width - inset * 2, 1)
        let usableHeight = max(size.height - inset * 2, 1)
        let fx = min(max((point.x - inset) / usableWidth, 0), 1)
        let fy = min(max((point.y - inset) / usableHeight, 0), 1)
        let x = Int((fx * CGFloat(steps * 2)).rounded()) - steps
        let y = steps - Int((fy * CGFloat(steps * 2)).rounded())
        return (x, y)
    }

    /// The gain a fader reports for a touch `fraction` of the way down its travel (0 = top).
    static func gain(atFraction fraction: CGFloat, range: Float = rangeDb) -> Float {
        let f = Float(min(max(fraction, 0), 1))
        return snapGain((1 - f * 2) * range, range: range)
    }

    /// Half-decibel steps, with a wider one at zero: flat is the value a band gets dragged back to
    /// more than any other, and the one a finger can't hit on a short travel.
    static func snapGain(_ raw: Float, range: Float = rangeDb) -> Float {
        if abs(raw) < zeroDetentDb { return 0 }
        return min(max((raw * 2).rounded() / 2, -range), range)
    }

    /// Balance from a touch `fraction` of the way across (0 = full left), with a detent at centre.
    static func balance(atFraction fraction: CGFloat) -> Float {
        let raw = Float(min(max(fraction, 0), 1)) * 2 - 1
        return abs(raw) < balanceDetent ? 0 : raw
    }

    /// "0", "+6", "-3.5".
    static func formatGain(_ value: Float) -> String {
        if abs(value) < 0.05 { return "0" }
        return (value > 0 ? "+" : "") + trimGain(value)
    }

    /// "+6" rather than "+6.0", but "+6.5" when the half matters.
    private static func trimGain(_ value: Float) -> String {
        if abs(value - value.rounded()) < 0.05 { return String(Int(value.rounded())) }
        return String(format: "%.1f", locale: LanguageBundle.locale, value)
    }

    /// "60", "2.5k", "14k" — the labels a hardware equaliser prints.
    static func formatFrequency(_ hz: Float) -> String {
        if hz < 1_000 { return String(Int(hz.rounded())) }
        if hz.truncatingRemainder(dividingBy: 1_000) == 0 { return "\(Int((hz / 1_000).rounded()))k" }
        return String(format: "%.1fk", locale: LanguageBundle.locale, hz / 1_000)
    }

    /// Zero has no sign; anything else wears one, so the direction reads at a glance.
    static func signed(_ value: Int) -> String { value > 0 ? "+\(value)" : "\(value)" }

    /// The balance readout, two decimals as Android prints it.
    static func formatBalance(_ value: Float) -> String {
        String(format: "%.2f", locale: LanguageBundle.locale, value)
    }

    /// Which preset the bands are, `custom` when they are nobody's.
    static func preset(of bands: [Float]) -> EqualizerPreset { EqualizerPreset.matching(bands) }
}

extension EqualizerPreset {
    var settingsLabel: String {
        switch self {
        case .flat: return L10n.eqPresetFlat
        case .acoustic: return L10n.eqPresetAcoustic
        case .bassBoost: return L10n.eqPresetBassBoost
        case .bassCut: return L10n.eqPresetBassCut
        case .vocal: return L10n.eqPresetVocal
        case .trebleBoost: return L10n.eqPresetTrebleBoost
        case .trebleCut: return L10n.eqPresetTrebleCut
        case .loudness: return L10n.eqPresetLoudness
        case .spokenWord: return L10n.eqPresetSpokenWord
        case .electronic: return L10n.eqPresetElectronic
        case .rock: return L10n.eqPresetRock
        case .hipHop: return L10n.eqPresetHipHop
        case .jazz: return L10n.eqPresetJazz
        case .classical: return L10n.eqPresetClassical
        case .smallSpeakers: return L10n.eqPresetSmallSpeakers
        case .lateNight: return L10n.eqPresetLateNight
        case .custom: return L10n.eqPresetCustom
        }
    }
}

extension EqualizerMode {
    var settingsLabel: String {
        switch self {
        case .dynamic: return L10n.equalizerDynamic
        case .manual: return L10n.equalizerManual
        }
    }
}
