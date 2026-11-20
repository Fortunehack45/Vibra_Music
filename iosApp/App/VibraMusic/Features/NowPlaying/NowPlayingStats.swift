import VibraMusicCore
import Foundation
import Playback
import PlaybackPolicy

// What the player says about the stream: stats for nerds (PlayerControls.kt's PlayerNerdStatsOverlay and
// `NerdStats.Snapshot.describe`), the quality badge between the timestamps (`LosslessOrStats`), the
// output's name under the transport (AudioOutput.kt's `outputLabel`) and the audio pipeline's rows
// in the app's language. The decisions themselves live in PlaybackPolicy; this is the wording.

// MARK: - Stats for nerds

enum PlayerNerdStatsText {
    /// The measured stream as PlaybackPolicy's snapshot, or nil until the decoder has reported on
    /// *this* item — the previous track's figures never describe the new one.
    ///
    /// - Parameters:
    ///   - stats: what the engine measured (`PlayerController.stats`).
    ///   - stream: the resolved stream behind the playing item, for what its source claimed.
    ///   - itemID: the playing item's engine id, rendition tag included (`PlayerQuality.playingItemID`).
    ///   - sourceOnDisk: who supplied a copy played off the disk with nothing resolved
    ///     (`PlayerController.sourceOnDisk`), named when there is no stream to name.
    static func snapshot(stats: PlaybackStats?, stream: ResolvedStream?, itemID: String?, sourceOnDisk: String? = nil) -> NerdStats.Snapshot? {
        guard let stats, stats.itemID == itemID else { return nil }
        return NerdStats.Snapshot(
            mimeType: mimeType(forCodec: stats.codec),
            bitrateKbps: stats.bitrateKbps,
            sampleRateHz: stats.sampleRateHz,
            channels: stats.channels,
            bitDepth: stats.bitDepth,
            claimed: stats.declared ?? stream?.format,
            sourceName: stream.map(sourceName(of:)) ?? sourceOnDisk
        )
    }

    /// The engine names codecs as the container does (`aac`, `ec-3`); PlaybackPolicy decides on
    /// MIME types, as Android's decoder reported them.
    static func mimeType(forCodec codec: String?) -> String? {
        guard let codec = codec?.lowercased(), !codec.isEmpty else { return nil }
        switch codec {
        case "aac": return "audio/mp4a-latm"
        case "flac": return "audio/flac"
        case "alac": return "audio/alac"
        case "mp3": return "audio/mpeg"
        case "opus": return "audio/opus"
        case "lpcm": return "audio/raw"
        case "ec-3", "eac3": return "audio/eac3"
        case "eac3-joc", "ec3-joc": return "audio/eac3-joc"
        case "ac-3": return "audio/ac3"
        default: return "audio/\(codec)"
        }
    }

    /// Who supplied the stream, as the pipeline's Source row names it.
    static func sourceName(of stream: ResolvedStream) -> String {
        switch stream.origin {
        case .youtube: return "YouTube"
        case .jioSaavn: return "JioSaavn"
        case .addon, .module: return stream.sourceConfigId ?? stream.origin.rawValue
        case .local: return "Local Storage"
        case .networkShare: return stream.url.host() ?? "Network"
        }
    }

    /// "FLAC · 24-bit · 96.0 kHz · 4608 kbps · Stereo" — whichever of those the player has actually
    /// reported. A figure it hasn't is dropped rather than filled in, so a short line means little
    /// was known, never that something was invented. A stream that arrived worse than its source
    /// promised says so.
    static func line(_ snapshot: NerdStats.Snapshot?) -> String? {
        guard let snapshot else { return nil }
        var parts: [String] = []
        if let codec = NerdStats.codecLabel(snapshot.mimeType) { parts.append(codec) }
        if let bitDepth = snapshot.bitDepth { parts.append(L10n.bitDepth(bitDepth)) }
        if let rate = snapshot.sampleRateHz {
            parts.append(String(format: "%.1f kHz", locale: Locale(identifier: "en_US_POSIX"), Double(rate) / 1_000))
        }
        if let kbps = snapshot.bitrateKbps { parts.append("\(kbps) kbps") }
        if let channels = snapshot.channels {
            switch channels {
            case 1: parts.append(L10n.mono)
            case 2: parts.append(L10n.stereo)
            default: parts.append(L10n.channelCount(channels))
            }
        }
        if snapshot.downgraded { parts.append(L10n.downgradedFrom(snapshot.claimed?.summary ?? "")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The dimmer second line, about the app rather than the audio: why Automix isn't analysing.
    /// Only while Automix is on — otherwise it would report on analysis nothing is going to use.
    /// A party is the broader rule, so it is named ahead of the video one.
    static func automixLine(smartFadeEnabled: Bool, inParty: Bool, song: Song?) -> String? {
        guard smartFadeEnabled else { return nil }
        if inParty { return L10n.automixStoppedInParty }
        if song?.isVideoOrigin == true || song?.isVideo == true { return L10n.automixNotSupportedVideo }
        return nil
    }
}

// MARK: - Quality badge

extension PlaybackQualityBadge {
    /// The badge in the app's language. "Dolby Atmos" is a trademark and stays as it is, as on
    /// Android.
    var playerLabel: String {
        switch self {
        case .upgrading(let alreadyHighQuality): return alreadyHighQuality ? L10n.highQualityUpgrading : L10n.upgradingQuality
        case .lossless: return L10n.lossless
        case .hiResLossless: return L10n.hiResLossless
        case .dolbyAtmos: return "Dolby Atmos"
        case .highQuality: return L10n.highQuality
        case .dataSaver: return L10n.dataSaver
        case .mediumQuality: return L10n.mediumQuality
        }
    }

    /// The SF Symbol drawn ahead of the label.
    var playerSymbol: String {
        switch self {
        case .dolbyAtmos: return "dot.radiowaves.left.and.right"
        default: return "headphones"
        }
    }
}

// MARK: - Output names

enum PlayerOutputLabel {
    /// What to call an output on screen. Devices that carry their own name keep it; the phone's
    /// speaker and wired headphones get a label from here ("Kushagra's Phone", "Wired headphones").
    static func label(for device: AudioRouting.Device, accountName: String?) -> String {
        switch device.kind {
        case .phone: return phone(accountName: accountName)
        case .wired: return L10n.wiredHeadphones
        default: break
        }
        let name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        switch device.kind {
        case .usb: return L10n.usbAudio
        case .hdmi: return L10n.hdmiOutput
        case .airPlay: return "AirPlay"
        case .car: return "CarPlay"
        case .phone, .wired, .bluetooth, .other: return phone(accountName: accountName)
        }
    }

    /// The name of whatever is playing the music, for the caption under the transport — derived
    /// from the same list the output sheet shows, so the two never disagree.
    static func activeName(of devices: [AudioRouting.Device], accountName: String?) -> String {
        guard let active = devices.first(where: \.isActive) ?? devices.first else { return phone(accountName: accountName) }
        return label(for: active, accountName: accountName)
    }

    /// "Kushagra's Phone" when the account has a name, "This phone" otherwise.
    static func phone(accountName: String?) -> String {
        let first = accountName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .first
        if let first, !first.isEmpty { return L10n.personalPhone(String(first)) }
        return L10n.thisPhone
    }

    static func symbol(for kind: AudioRouting.Kind) -> String {
        switch kind {
        case .phone: return "iphone"
        case .wired: return "headphones"
        case .usb: return "cable.connector"
        case .bluetooth: return "hifispeaker"
        case .hdmi: return "tv"
        case .airPlay: return "airplayaudio"
        case .car: return "car"
        case .other: return "speaker.wave.2"
        }
    }
}

// MARK: - Pipeline wording

extension AudioPipeline.StageKind {
    var playerTitle: String {
        switch self {
        case .trackInfo: return L10n.pipelineTrackInfo
        case .decoder: return L10n.pipelineDecoder
        case .resampler: return L10n.pipelineResampler
        case .dsp: return L10n.pipelineDsp
        case .outputDevice: return L10n.pipelineOutputDevice
        }
    }

    var playerSymbol: String {
        switch self {
        case .trackInfo: return "doc"
        case .decoder: return "cpu"
        case .resampler: return "slider.horizontal.3"
        case .dsp: return "waveform"
        case .outputDevice: return "speaker.wave.2"
        }
    }
}

enum PlayerPipelineWording {
    /// PlaybackPolicy names its rows in English; these are the ones the string catalog has.
    /// Labels it doesn't have ("Route", "Latency"…) were plain English on Android too.
    static func label(_ label: String) -> String {
        switch label {
        case "Source": return L10n.pipelineSource
        case "Format": return L10n.pipelineFormat
        case "Bit Depth": return L10n.pipelineBitDepth
        case "Sample Rate": return L10n.pipelineSampleRate
        case "Bitrate": return L10n.pipelineBitrate
        case "Channels": return L10n.pipelineChannels
        case "Decoder Name": return L10n.pipelineDecoderName
        case "I/O Rate": return L10n.pipelineIoRate
        case "Type": return L10n.pipelineType
        case "Cutoff": return L10n.pipelineCutoff
        case "Quality": return L10n.pipelineQuality
        case "PCM Format": return L10n.pipelinePcmFormat
        case "Gain": return L10n.pipelineLoudnessGain
        case "Measured": return L10n.pipelineLoudnessMeasured
        case "EQ Preset": return L10n.pipelineEqPreset
        case "Stereo Expand": return L10n.pipelineStereoExpand
        case "Buffers": return L10n.pipelineBuffers
        case "Output API": return L10n.pipelineOutputApi
        case "Bit-exact": return L10n.pipelineBitExact
        case "Device Name": return L10n.pipelineDeviceName
        case "Spatial Audio": return L10n.spatialAudio
        default: return label
        }
    }

    /// The DSP settings the pipeline reads, from the app's settings. The signal path the engine
    /// chose is the other half: a bit-transparent or Atmos item has no tap at all, so nothing the
    /// equalizer is set to reaches it.
    @MainActor
    static func dspSettings(_ settings: AppSettings, signalPath: PlaybackSignalPath?) -> AudioPipeline.DSPSettings {
        let tapped = signalPath.map { $0 == .processed } ?? true
        return AudioPipeline.DSPSettings(
            equalizerEnabled: settings.equalizerEnabled && tapped,
            equalizerDescription: settings.equalizerEnabled ? L10n.equalizer : nil,
            spatialAudio: settings.spatialAudio && tapped,
            loudnessNormalization: settings.loudnessNormalization && tapped,
            playbackSpeed: settings.playbackSpeed,
            tapped: tapped
        )
    }
}
