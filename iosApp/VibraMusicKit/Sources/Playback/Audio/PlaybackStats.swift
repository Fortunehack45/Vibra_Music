import AVFoundation
import VibraMusicCore

/// What is actually playing, measured off the player — the values behind stats for nerds.
///
/// Kept apart from what the source *claimed* (``declared``): a source claiming 24/192 and a decoder
/// running at 16/48 is exactly what the stats line has to be able to show.
public struct PlaybackStats: Hashable, Sendable {
    public var itemID: String
    /// Codec as the container names it, lowercased: `aac`, `flac`, `alac`, `mp3`, `opus`, `lpcm`,
    /// `ec-3`.
    public var codec: String?
    public var sampleRateHz: Int?
    public var channels: Int?
    /// Source bit depth where the format records it (PCM, and ALAC/FLAC's source-depth flags).
    public var bitDepth: Int?
    /// The track's average data rate as the container states it.
    public var estimatedBitrateKbps: Int?
    /// The bitrate the stream advertises (HTTP access log), when streaming.
    public var indicatedBitrateKbps: Int?
    /// The network throughput actually observed, when streaming.
    public var observedBitrateKbps: Int?
    public var bytesTransferred: Int64?
    public var stallCount: Int
    /// What the source promised, from the resolved stream or the item.
    public var declared: StreamFormat?

    public init(
        itemID: String,
        codec: String? = nil,
        sampleRateHz: Int? = nil,
        channels: Int? = nil,
        bitDepth: Int? = nil,
        estimatedBitrateKbps: Int? = nil,
        indicatedBitrateKbps: Int? = nil,
        observedBitrateKbps: Int? = nil,
        bytesTransferred: Int64? = nil,
        stallCount: Int = 0,
        declared: StreamFormat? = nil
    ) {
        self.itemID = itemID
        self.codec = codec
        self.sampleRateHz = sampleRateHz
        self.channels = channels
        self.bitDepth = bitDepth
        self.estimatedBitrateKbps = estimatedBitrateKbps
        self.indicatedBitrateKbps = indicatedBitrateKbps
        self.observedBitrateKbps = observedBitrateKbps
        self.bytesTransferred = bytesTransferred
        self.stallCount = stallCount
        self.declared = declared
    }

    /// The measured values as a ``StreamFormat``. The bitrate is the lossless PCM rate for a
    /// lossless codec (what the Android stats line showed for FLAC), else the stated data rate.
    public var measuredFormat: StreamFormat {
        StreamFormat(codec: codec, kbps: bitrateKbps, sampleRateHz: sampleRateHz, bitDepth: bitDepth, channels: channels)
    }

    /// The single bitrate figure to show.
    public var bitrateKbps: Int? {
        if let codec, StreamFormat.losslessCodecs.contains(codec) || codec == "lpcm",
           let sampleRateHz, let channels, let bitDepth {
            return sampleRateHz * channels * bitDepth / 1_000
        }
        return estimatedBitrateKbps ?? indicatedBitrateKbps ?? declared?.kbps
    }
}

enum PlaybackStatsSampler {
    /// Reads the format off the item's audio track and the transfer figures off its access log.
    @MainActor
    static func sample(itemID: String, playerItem: AVPlayerItem, declared: StreamFormat?) async -> PlaybackStats {
        var stats = PlaybackStats(itemID: itemID, declared: declared)
        // An HLS asset has no asset-level tracks; its variant's track shows up on the player item.
        let assetTrack = try? await playerItem.asset.loadTracks(withMediaType: .audio).first
        let itemTrack = playerItem.tracks.lazy.compactMap(\.assetTrack).first { $0.mediaType == .audio }
        if let track = assetTrack ?? itemTrack {
            if let descriptions = try? await track.load(.formatDescriptions),
               let description = descriptions.first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                stats.codec = codecName(asbd.mFormatID)
                stats.sampleRateHz = asbd.mSampleRate > 0 ? Int(asbd.mSampleRate.rounded()) : nil
                stats.channels = asbd.mChannelsPerFrame > 0 ? Int(asbd.mChannelsPerFrame) : nil
                stats.bitDepth = bitDepth(asbd)
            }
            if let rate = try? await track.load(.estimatedDataRate), rate > 0 {
                stats.estimatedBitrateKbps = Int((Double(rate) / 1_000).rounded())
            }
        }
        if let event = playerItem.accessLog()?.events.last {
            if event.indicatedBitrate > 0 { stats.indicatedBitrateKbps = Int((event.indicatedBitrate / 1_000).rounded()) }
            if event.observedBitrate > 0 { stats.observedBitrateKbps = Int((event.observedBitrate / 1_000).rounded()) }
            if event.numberOfBytesTransferred > 0 { stats.bytesTransferred = event.numberOfBytesTransferred }
            stats.stallCount = max(event.numberOfStalls, 0)
        }
        return stats
    }

    static func codecName(_ formatID: AudioFormatID) -> String {
        switch formatID {
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD:
            return "aac"
        case kAudioFormatFLAC: return "flac"
        case kAudioFormatAppleLossless: return "alac"
        case kAudioFormatMPEGLayer3: return "mp3"
        case kAudioFormatOpus: return "opus"
        case kAudioFormatLinearPCM: return "lpcm"
        case kAudioFormatAC3: return "ac-3"
        case kAudioFormatEnhancedAC3: return "ec-3"
        default:
            let bytes = withUnsafeBytes(of: formatID.bigEndian) { Array($0) }
            let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            return text.lowercased()
        }
    }

    static func bitDepth(_ asbd: AudioStreamBasicDescription) -> Int? {
        switch asbd.mFormatID {
        case kAudioFormatLinearPCM:
            return asbd.mBitsPerChannel > 0 ? Int(asbd.mBitsPerChannel) : nil
        case kAudioFormatAppleLossless, kAudioFormatFLAC:
            // Both carry the source depth in the format flags rather than mBitsPerChannel.
            switch asbd.mFormatFlags {
            case kAppleLosslessFormatFlag_16BitSourceData: return 16
            case kAppleLosslessFormatFlag_20BitSourceData: return 20
            case kAppleLosslessFormatFlag_24BitSourceData: return 24
            case kAppleLosslessFormatFlag_32BitSourceData: return 32
            default: return asbd.mBitsPerChannel > 0 ? Int(asbd.mBitsPerChannel) : nil
            }
        default:
            return nil
        }
    }
}
