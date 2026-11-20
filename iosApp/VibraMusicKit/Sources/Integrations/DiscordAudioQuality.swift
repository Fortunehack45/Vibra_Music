import Foundation

/// Measured audio figures for the Discord quality line.
///
/// `NerdStats` (PlaybackPolicy) is not a dependency of this module yet, so
/// Integrations defines the snapshot it needs: the decoder's *measured* mime
/// type, bitrate, sample rate, channels and bit depth. Only premium formats
/// earn a line; the values must be measured, never a source's advertised
/// quality, so a lossy fallback cannot call itself Lossless on Discord.
/// The app maps its measured stats onto this struct when updating presence.
public struct DiscordAudioSnapshot: Hashable, Sendable {
    public var mimeType: String?
    public var bitrateKbps: Int?
    public var sampleRateHz: Int?
    public var channels: Int?
    public var bitDepth: Int?

    public init(
        mimeType: String? = nil,
        bitrateKbps: Int? = nil,
        sampleRateHz: Int? = nil,
        channels: Int? = nil,
        bitDepth: Int? = nil
    ) {
        self.mimeType = mimeType
        self.bitrateKbps = bitrateKbps
        self.sampleRateHz = sampleRateHz
        self.channels = channels
        self.bitDepth = bitDepth
    }

    public var isLossless: Bool { Self.isLosslessMime(mimeType) }
    public var isDolbyAtmos: Bool { Self.isDolbyAtmosMime(mimeType) }
    public var isHiRes: Bool { isLossless && ((bitDepth ?? 0) > 16 || (sampleRateHz ?? 0) > 48_000) }

    static func isLosslessMime(_ mimeType: String?) -> Bool {
        guard let mimeType else { return false }
        let lower = mimeType.lowercased()
        return lower.hasSuffix("flac") || lower.hasSuffix("alac") || lower.hasSuffix("raw")
    }

    static func isDolbyAtmosMime(_ mimeType: String?) -> Bool {
        guard let mimeType else { return false }
        let lower = mimeType.lowercased()
        return lower.hasSuffix("eac3-joc") || lower.hasSuffix("eac3")
    }
}

/// Discord caps each activity text field at 128 characters.
public let discordTextLimit = 128

/// The optional audio line on Vibra Music's Discord activity card (ports
/// `discordAudioQualityLine` in `DiscordAudioQuality.kt`).
///
/// Only premium formats earn a line; ordinary lossy audio (and a nil snapshot)
/// yields `nil` so Discord shows no third line.
public func discordAudioQualityLine(_ stats: DiscordAudioSnapshot?) -> String? {
    guard let stats else { return nil }
    let quality: String
    if stats.isDolbyAtmos {
        quality = "◗◖ Dolby Atmos"
    } else if stats.isHiRes {
        quality = "Hi-Res Lossless"
    } else if stats.isLossless {
        quality = "Lossless"
    } else {
        return nil
    }
    var parts = [quality]
    if let codec = discordCodecLabel(stats.mimeType) { parts.append(codec) }
    if let kbps = stats.bitrateKbps, kbps > 0 { parts.append("\(kbps) kbps") }
    if let depth = stats.bitDepth, depth > 0 { parts.append("\(depth)-bit") }
    if let rate = stats.sampleRateHz, rate > 0 {
        let khz = String(format: "%.1f", Double(rate) / 1000.0)
        parts.append("\(khz.hasSuffix(".0") ? String(khz.dropLast(2)) : khz) kHz")
    }
    if let channels = stats.channels, channels > 0 {
        switch channels {
        case 1: parts.append("Mono")
        case 2: parts.append("Stereo")
        default: parts.append("\(channels) ch")
        }
    }
    return String(parts.joined(separator: " · ").prefix(discordTextLimit)).trimmingCharacters(in: .whitespaces)
}

/// Codec display label from a mime type (ports `NerdStats.codecLabel`).
public func discordCodecLabel(_ mimeType: String?) -> String? {
    guard let mimeType else { return nil }
    let lower = mimeType.lowercased()
    if lower.hasSuffix("flac") { return "FLAC" }
    if lower.hasSuffix("opus") { return "Opus" }
    if lower.hasSuffix("mp4a-latm") || lower.hasSuffix("aac") { return "AAC" }
    if lower.hasSuffix("mpeg") || lower.hasSuffix("mp3") { return "MP3" }
    if lower.hasSuffix("alac") { return "ALAC" }
    if lower.hasSuffix("raw") { return "PCM" }
    if lower.hasSuffix("vorbis") { return "Vorbis" }
    if lower.hasSuffix("eac3-joc") { return "E-AC-3 JOC" }
    if lower.hasSuffix("eac3") { return "E-AC-3" }
    if mimeType.contains("/") { return String(mimeType.split(separator: "/").last?.uppercased() ?? "") }
    return mimeType.uppercased()
}
