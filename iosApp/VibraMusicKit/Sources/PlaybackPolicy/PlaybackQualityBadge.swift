import Foundation
import VibraMusicCore

// Ports the decision half of ui/player/PlayerControls.kt: `LosslessOrStats` (the badge between the
// timestamps) and the hi-res shine on the output caption.

/// The quality badge under the seek bar — "Lossless", "Hi-Res Lossless", "Upgrading quality"… — or
/// nothing.
///
/// Decided on the measured stream (``NerdStats/Snapshot``), never on what a source offered: every
/// label except "Upgrading quality" states a result, and only confirmed results shimmer.
public enum PlaybackQualityBadge: Hashable, Sendable {
    /// A better copy is still being looked for. `alreadyHighQuality` names the floor first when the
    /// track is already at the top of lossy (JioSaavn's 320 while a FLAC is chased), so the label
    /// describes a track rather than a wait: "High quality, upgrading".
    case upgrading(alreadyHighQuality: Bool)
    case lossless
    case hiResLossless
    case dolbyAtmos
    /// Lossy at ≥ 256 kbps.
    case highQuality
    /// Low ceiling in force and a ≤ 80 kbps stream playing.
    case dataSaver
    /// Medium ceiling in force and an 81–255 kbps stream playing.
    case mediumQuality

    public var label: String {
        switch self {
        case .upgrading(let alreadyHighQuality):
            return alreadyHighQuality ? "High quality, upgrading" : "Upgrading quality"
        case .lossless: return "Lossless"
        case .hiResLossless: return "Hi-Res Lossless"
        case .dolbyAtmos: return "Dolby Atmos"
        case .highQuality: return "High quality"
        case .dataSaver: return "Data-Saver"
        case .mediumQuality: return "Medium Quality"
        }
    }

    /// Whether the badge shimmers. Reserved for the thing that was asked for and confirmed — it is
    /// what makes the badge read as an achievement rather than a label.
    public var shimmers: Bool {
        switch self {
        case .lossless, .hiResLossless, .dolbyAtmos: return true
        case .upgrading, .highQuality, .dataSaver, .mediumQuality: return false
        }
    }

    /// Whether to draw the Dolby Atmos glyph instead of the headphones one.
    public var usesDolbyAtmosGlyph: Bool { self == .dolbyAtmos }

    /// The badge for the playing track, or nil for none.
    ///
    /// - Parameters:
    ///   - isLoading: the player is buffering.
    ///   - stillRacing: a better copy of *this* track is still being looked for
    ///     (``NerdStats/isRacing(_:)``). Not gated on the ceiling: a source outranks YouTube on the
    ///     strength of the source order alone, so the lookup runs — and can come back lossless —
    ///     whatever the setting. Gating it left the badge blank through the wait and then jumped
    ///     straight to "Hi-Res Lossless".
    ///   - effectiveQuality: the ceiling in force (``PlaybackQualityCeiling/effectiveQuality``).
    ///   - stats: the measured stream, nil until measured.
    ///
    /// The `isLoading` half is gated on `stats == nil`, not on "not lossless": buffering is also
    /// what a seek trips for a track whose quality question was settled long ago, and gating on
    /// "not lossless" flashed "Upgrading quality" over a track already known to have no lossless
    /// copy anywhere.
    public static func resolve(
        isLoading: Bool,
        stillRacing: Bool,
        effectiveQuality: AudioQuality,
        stats: NerdStats.Snapshot?
    ) -> PlaybackQualityBadge? {
        let losslessRequested = effectiveQuality == .lossless
        // Dolby Atmos is final, like lossless: nothing is looked for past it.
        let settled = stats?.isLossless == true || stats?.isDolbyAtmos == true
        if (stillRacing && !settled) || (isLoading && losslessRequested && stats == nil) {
            return .upgrading(alreadyHighQuality: stats?.isHiQuality == true)
        }
        guard let stats else { return nil }
        if stats.isLossless { return stats.isHiRes ? .hiResLossless : .lossless }
        if stats.isDolbyAtmos { return .dolbyAtmos }
        if stats.isHiQuality { return .highQuality }
        if effectiveQuality == .low && stats.isLowQuality { return .dataSaver }
        if effectiveQuality == .medium && stats.isMediumQuality { return .mediumQuality }
        return nil
    }

    /// Whether the output caption under the transport ("AirPods Pro", "This phone") should wear the
    /// hi-res shine: the stream is Hi-Res Lossless *and* the route can carry it.
    ///
    /// Both halves, because either alone says something the shine does not mean: a hi-res file on
    /// a route that re-encodes to 16-bit AAC is not arriving hi-res, and a lossy stream stays lossy
    /// however wide the route. Never shown in a Listen Together party, whose caption names the jam.
    public static func outputCaptionShines(
        stats: NerdStats.Snapshot?,
        output: AudioOutputStatus.Snapshot,
        inParty: Bool
    ) -> Bool {
        !inParty && stats?.isHiRes == true && output.routeCarriesHiRes
    }
}
