import AVFoundation
import VibraMusicCore

/// The coded format of an item's audio track, read off the asset before it plays.
struct AudioTrackFormat: Hashable, Sendable {
    var formatID: AudioFormatID?
    var sampleRate: Double?
    var channels: Int?

    static func load(_ track: AVAssetTrack) async -> AudioTrackFormat {
        guard let description = try? await track.load(.formatDescriptions).first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
            return AudioTrackFormat()
        }
        return AudioTrackFormat(
            formatID: asbd.mFormatID,
            sampleRate: asbd.mSampleRate > 0 ? asbd.mSampleRate : nil,
            channels: asbd.mChannelsPerFrame > 0 ? Int(asbd.mChannelsPerFrame) : nil
        )
    }
}

/// What kind of audio an item carries, which decides whether a processing tap may touch it.
enum AudioContentKind: Hashable, Sendable {
    /// Dolby Atmos in E-AC-3 JOC.
    case dolbyAtmos
    /// FLAC, ALAC or PCM: bit-exact once decoded.
    case lossless
    case lossy

    /// The decoder's format decides when it is known; the source's claim only fills in when it is
    /// not. A stream that promised FLAC and turned out AAC is lossy — the rule the Android stats
    /// line followed (a claim alone never earns the Lossless badge). Any E-AC-3 counts as Atmos,
    /// as Android's `isDolbyAtmosMime` did: the music services only ship E-AC-3 as JOC, and the
    /// JOC flag itself is not in the format description.
    static func classify(_ format: AudioTrackFormat, declared: StreamFormat?) -> AudioContentKind {
        if declared?.isDolbyAtmos == true { return .dolbyAtmos }
        switch format.formatID {
        case kAudioFormatEnhancedAC3?:
            return .dolbyAtmos
        case kAudioFormatFLAC?, kAudioFormatAppleLossless?, kAudioFormatLinearPCM?:
            return .lossless
        case nil:
            return declared?.isLossless == true ? .lossless : .lossy
        default:
            return .lossy
        }
    }

    /// A description of the decoder that decodes `formatID`, in the Audio Pipeline sheet's
    /// "AudioToolbox · FLAC" style. iOS names no codec instance the way Android's MediaCodec does,
    /// so this is derived from the coded format and labelled as AudioToolbox's — honest about being
    /// a description, not a measurement of the decoder AVFoundation instantiates. nil when the
    /// format is unknown, so the Decoder Name row reads "—" rather than a guess.
    static func decoderDescription(for formatID: AudioFormatID) -> String? {
        let name: String
        switch formatID {
        case kAudioFormatFLAC: name = "FLAC"
        case kAudioFormatAppleLossless: name = "ALAC"
        case kAudioFormatLinearPCM: name = "PCM"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
             kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD: name = "AAC"
        case kAudioFormatMPEGLayer3: name = "MP3"
        case kAudioFormatOpus: name = "Opus"
        case kAudioFormatAC3: name = "AC-3"
        case kAudioFormatEnhancedAC3: name = "E-AC-3"
        default: return nil
        }
        return "AudioToolbox · \(name)"
    }
}
