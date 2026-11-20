import Foundation

// Ports StreamFormat from data/sources/MusicSource.kt. Shared by Sources, StreamResolution,
// Playback (stats for nerds), Downloads and Integrations.

/// What a source is about to hand the decoder, as far as the source will say.
///
/// Every field is optional because most are genuinely unknown until the bytes arrive: a server that
/// reports "flac" rarely reports the bit depth, and one that reports a bitrate is usually describing
/// a transcode it hasn't made yet. Nothing here is inferred — nil means "not stated", and the player
/// reports the decoder's own numbers once it has them. Compare the two rather than merging them: a
/// source claiming 24/192 and an output running at 16/48 is exactly what stats for nerds must show.
public struct StreamFormat: Codable, Hashable, Sendable {
    /// Container/codec as the source names it, lowercased: `flac`, `aac`, `opus`, `mp3`, `eac3-joc`.
    public var codec: String?
    public var kbps: Int?
    public var sampleRateHz: Int?
    public var bitDepth: Int?
    public var channels: Int?

    public init(codec: String? = nil, kbps: Int? = nil, sampleRateHz: Int? = nil, bitDepth: Int? = nil, channels: Int? = nil) {
        self.codec = codec?.lowercased()
        self.kbps = kbps
        self.sampleRateHz = sampleRateHz
        self.bitDepth = bitDepth
        self.channels = channels
    }

    /// Whether this is a bit-exact copy of the master, decided on the codec alone. A lossless codec
    /// at any bitrate is lossless; a lossy one never is, whatever its sample rate. Unknown codec is
    /// nil, not false, so callers that care must say what they want done about it.
    public var isLossless: Bool? {
        guard let codec else { return nil }
        return Self.losslessCodecs.contains(codec)
    }

    /// Dolby Atmos carried in E-AC-3 JOC. Immersive, but not lossless.
    public var isDolbyAtmos: Bool {
        guard let codec else { return false }
        return Self.dolbyAtmosCodecs.contains(codec)
    }

    /// Hi-Res: lossless above CD resolution (more than 16 bits or more than 48 kHz).
    public var isHiRes: Bool {
        guard isLossless == true else { return false }
        return (bitDepth ?? 0) > 16 || (sampleRateHz ?? 0) > 48_000
    }

    /// "FLAC · 24-bit · 192 kHz", "MP3 · 44.1 kHz · 320 kbps", "Dolby Atmos" — whichever parts are
    /// known; bitrate is dropped for lossless streams. "Unknown format" when nothing is.
    public var summary: String {
        if isDolbyAtmos { return "Dolby Atmos" }
        var parts: [String] = []
        if let codec { parts.append(codec.uppercased()) }
        if let bitDepth { parts.append("\(bitDepth)-bit") }
        if let sampleRateHz { parts.append("\(Self.kilohertz(sampleRateHz)) kHz") }
        if let kbps, isLossless != true { parts.append("\(kbps) kbps") }
        return parts.isEmpty ? "Unknown format" : parts.joined(separator: " · ")
    }

    static func kilohertz(_ hz: Int) -> String {
        let text = String(format: "%.1f", Double(hz) / 1_000)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    public static let losslessCodecs: Set<String> = ["flac", "alac", "wav", "aiff", "ape", "wv", "dsf", "dff"]
    public static let dolbyAtmosCodecs: Set<String> = ["eac3-joc", "ec3-joc", "dolby-atmos"]
}
