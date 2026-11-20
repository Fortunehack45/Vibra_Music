/// The manual tab's starting points, one gain per centre in
/// `EqualizerLayout.manualBandsHz`.
///
/// Written for this equaliser rather than copied from anyone else's: the seven
/// centres here are not the ten a desktop EQ uses, and the two ends are shelves
/// rather than bells (`EqualizerFilterKind`), so a borrowed table would not
/// describe the same curve even with the numbers transcribed correctly. They are
/// deliberately modest — nothing reaches the ±12 dB the sliders allow, because a
/// preset is a place to start from and every decibel of boost is a decibel of
/// headroom `EqualizerCurve.preampDb` has to take back.
///
/// `custom` carries no gains. It is what the tab reports once a slider has been
/// moved, so the row stops naming a preset the bands no longer match.
///
/// Raw values are the Android enum names, so a stored or backed-up preset name
/// means the same thing on both platforms. Case order is Android's list order.
public enum EqualizerPreset: String, CaseIterable, Sendable {
    case flat = "FLAT"
    case acoustic = "ACOUSTIC"
    case bassBoost = "BASS_BOOST"
    case bassCut = "BASS_CUT"
    case vocal = "VOCAL"
    case trebleBoost = "TREBLE_BOOST"
    case trebleCut = "TREBLE_CUT"
    case loudness = "LOUDNESS"
    case spokenWord = "SPOKEN_WORD"
    case electronic = "ELECTRONIC"
    case rock = "ROCK"
    case hipHop = "HIP_HOP"
    case jazz = "JAZZ"
    case classical = "CLASSICAL"
    case smallSpeakers = "SMALL_SPEAKERS"
    case lateNight = "LATE_NIGHT"
    case custom = "CUSTOM"

    /// The seven band gains in decibels, low to high. Empty for `custom`.
    public var bandsDb: [Float] {
        switch self {
        case .flat: return [0, 0, 0, 0, 0, 0, 0]
        case .acoustic: return [3, 1.5, 0, 1.5, 2.5, 2, 1]
        case .bassBoost: return [6, 4, 1.5, 0, 0, 0, 0]
        case .bassCut: return [-6, -4, -1.5, 0, 0, 0, 0]
        case .vocal: return [-3, -1.5, 1, 3.5, 3, 1, -1]
        case .trebleBoost: return [0, 0, 0, 0, 1.5, 3.5, 5]
        case .trebleCut: return [0, 0, 0, 0, -1.5, -3.5, -5]
        case .loudness: return [6, 3.5, 0, -1.5, -1, 2, 5]
        case .spokenWord: return [-5, -2.5, 1.5, 4, 3.5, 1.5, -2]
        case .electronic: return [5, 3, -1, 0, 1, 3, 4]
        case .rock: return [4, 2.5, -1, -1.5, 1, 3, 3.5]
        case .hipHop: return [6, 4, 0.5, -1, 0.5, 2, 2.5]
        case .jazz: return [3, 1.5, 0, 1, 1.5, 2, 2.5]
        case .classical: return [3, 2, 0, 0, 1, 2.5, 3]
        case .smallSpeakers: return [5, 4, 2, 0.5, 0, -1, -2]
        case .lateNight: return [3, 1, 0, 1.5, 1, -1, -3]
        case .custom: return []
        }
    }

    /// The presets a user can pick, in list order (everything but `custom`).
    public static var selectable: [EqualizerPreset] {
        allCases.filter { $0 != .custom }
    }

    /// The preset whose curve these bands are, or `custom` if they are nobody's.
    /// Lets a restored backup name what it restored, and lets a slider dragged
    /// back to where it started stop saying "Custom".
    public static func matching(_ bandsDb: [Float]) -> EqualizerPreset {
        allCases.first { preset in
            let bands = preset.bandsDb
            return preset != .custom && bands.count == bandsDb.count &&
                bands.indices.allSatisfy { abs(bands[$0] - bandsDb[$0]) < 0.05 }
        } ?? .custom
    }
}
