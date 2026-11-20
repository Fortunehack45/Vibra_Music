/// Everything the equaliser screen stores, as one value the DSP can render.
///
/// Mirrors the equaliser fields of Android's `AppSettings` one for one
/// (`equalizerEnabled`, `equalizerMode`, `equalizerToneX`/`Y`,
/// `equalizerFocused`, `equalizerBalance`, `equalizerBands`) so the settings
/// module can map onto it field by field. Defaults are Android's defaults.
public struct EqualizerSettings: Equatable, Sendable {

    /// Which tab is driving the curve. Raw values are Android's enum names.
    public enum Mode: String, CaseIterable, Sendable {
        /// The tone pad: tilt, contour, and how wide each is.
        case dynamic = "DYNAMIC"
        /// Seven sliders and a preset list.
        case manual = "MANUAL"
    }

    /// The master switch. Off is a flat curve and centred balance, glided to.
    public var isEnabled: Bool

    public var mode: Mode

    /// Tone pad, horizontal: warm at -5, bright at +5.
    public var toneX: Int

    /// Tone pad, vertical: scooped at -5, mid-forward at +5.
    public var toneY: Int

    /// Tone pad bandwidth: Broad when false, Focused when true.
    public var isFocused: Bool

    /// Left/right trim, -1 hard left to +1 hard right. Applies to both tabs.
    public var balance: Float

    /// The manual tab's seven gains in decibels, low to high.
    public var bandsDb: [Float]

    public init(isEnabled: Bool = false,
                mode: Mode = .dynamic,
                toneX: Int = 0,
                toneY: Int = 0,
                isFocused: Bool = false,
                balance: Float = 0,
                bandsDb: [Float] = EqualizerPreset.flat.bandsDb) {
        self.isEnabled = isEnabled
        self.mode = mode
        self.toneX = toneX
        self.toneY = toneY
        self.isFocused = isFocused
        self.balance = balance
        self.bandsDb = bandsDb
    }

    /// The curve the current tab describes. Built here, on whoever changed the
    /// setting, because working out the make-up attenuation walks the whole
    /// response and the audio thread is the one place that must not do that.
    public var curve: EqualizerCurve {
        switch mode {
        case .dynamic: return .tone(x: toneX, y: toneY, focused: isFocused)
        case .manual: return .manual(bandsDb: bandsDb)
        }
    }

    /// Which preset the manual bands currently are, or `custom`.
    public var preset: EqualizerPreset {
        .matching(Self.normalizedBands(bandsDb))
    }

    /// Exactly seven gains, each within ±`manualRangeDb`.
    ///
    /// Padded rather than rejected, as Android's settings do: a backup written
    /// by a build with a different number of bands should restore the ones it
    /// does have.
    public static func normalizedBands(_ values: [Float]) -> [Float] {
        let range = EqualizerLayout.manualRangeDb
        return (0..<EqualizerLayout.manualCount).map { index in
            let value = index < values.count && !values[index].isNaN ? values[index] : 0
            return min(max(value, -range), range)
        }
    }

    /// Tone pad steps held to ±`toneSteps`, as Android's `setEqualizerTone` does.
    public static func clampedToneStep(_ value: Int) -> Int {
        min(max(value, -EqualizerLayout.toneSteps), EqualizerLayout.toneSteps)
    }

    /// Balance held to -1...1, as Android's `setEqualizerBalance` does. NaN
    /// (a corrupt stored value) centres rather than silencing both channels.
    public static func clampedBalance(_ value: Float) -> Float {
        value.isNaN ? 0 : min(max(value, -1), 1)
    }
}
