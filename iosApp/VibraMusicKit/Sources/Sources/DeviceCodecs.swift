import AudioToolbox
import Foundation
import VibraMusicCore

// Ports data/sources/DeviceCodecs.kt. Android asks Media3/MediaCodecList for an E-AC-3 (JOC)
// decoder because that decoder ships with the vendor image; on Apple platforms the equivalent
// question goes to AudioToolbox, which lists the decoders installed for a format ID.

/// What this device can actually decode, asked once and remembered.
///
/// One question so far, and it is the one the rest of the app is otherwise free to ignore all the
/// way to silence: **Dolby Atmos**. Asked before a URL is returned rather than left to the player,
/// because a player handed a format it cannot decode fails badly — on Android as a track that
/// skipped itself instantly; on iOS as an `AVPlayerItem` that fails after the source has already
/// been chosen, costing the fallback budget.
///
/// Every iPhone since the iPhone 7 on iOS 13+ ships an E-AC-3 decoder (Apple decodes Atmos in
/// E-AC-3 JOC for spatial rendering), so on real hardware this is expected to answer yes. The check
/// is kept rather than hard-coded because the Mac host and future simulators need not have it,
/// and a false yes is a silent skip.
///
/// Passthrough to an AV receiver is not considered, for the same reason Android leaves it out: it
/// changes with the audio route and cannot be cached.
public final class DeviceCodecs: @unchecked Sendable {
    public static let shared = DeviceCodecs()

    private let lock = NSLock()
    private var probed: Bool?
    private var forced: Bool?
    private let probe: @Sendable () -> Bool

    /// `probe` answers the decoder question; the default asks AudioToolbox.
    public init(probe: @escaping @Sendable () -> Bool = DeviceCodecs.hasEnhancedAC3Decoder) {
        self.probe = probe
    }

    /// A device that answers `playsDolbyAtmos` with `value` whatever it has (tests, and the field
    /// override of last resort).
    public static func fixed(_ value: Bool) -> DeviceCodecs {
        let codecs = DeviceCodecs(probe: { value })
        codecs.force(value)
        return codecs
    }

    /// Overrides the probe until `force(nil)`.
    public func force(_ value: Bool?) {
        lock.withLock { forced = value }
    }

    /// Whether an E-AC-3 (JOC) stream would find a decoder here. Asked once and cached: the codec
    /// list cannot change while the app runs.
    public var playsDolbyAtmos: Bool {
        lock.withLock {
            if let forced { return forced }
            if let probed { return probed }
            let answer = probe()
            probed = answer
            return answer
        }
    }

    /// Whether AudioToolbox lists a decoder for `kAudioFormatEnhancedAC3`.
    ///
    /// A decoder for plain E-AC-3 can carry a JOC stream — the height objects are dropped and the
    /// 5.1 core plays — so asking for it is enough, as it is on Android.
    ///
    /// Yes on anything that cannot be established. Guessing no on a capable device greys out the
    /// switch and silently drops a tier; guessing yes only restores the behaviour before this check
    /// existed. The costs are not symmetric.
    public static let hasEnhancedAC3Decoder: @Sendable () -> Bool = {
        var formatID = kAudioFormatEnhancedAC3
        var size: UInt32 = 0
        let infoStatus = AudioFormatGetPropertyInfo(
            kAudioFormatProperty_Decoders,
            UInt32(MemoryLayout<AudioFormatID>.size),
            &formatID,
            &size
        )
        // "fmt?" means the format is unknown to the system: no decoder at all.
        if infoStatus == kAudioFormatUnsupportedDataFormatError { return logged(false, "none") }
        guard infoStatus == noErr else {
            TrackLog.w(SourcesLog.category, "could not read the decoder list (\(infoStatus)); assuming Dolby Atmos plays")
            return true
        }
        let count = Int(size) / MemoryLayout<AudioClassDescription>.size
        guard count > 0 else { return logged(false, "none") }
        var descriptions = [AudioClassDescription](repeating: AudioClassDescription(), count: count)
        let status = AudioFormatGetProperty(
            kAudioFormatProperty_Decoders,
            UInt32(MemoryLayout<AudioFormatID>.size),
            &formatID,
            &size,
            &descriptions
        )
        guard status == noErr else {
            TrackLog.w(SourcesLog.category, "could not read the decoder list (\(status)); assuming Dolby Atmos plays")
            return true
        }
        return logged(!descriptions.isEmpty, "\(descriptions.count)")
    }

    private static func logged(_ answer: Bool, _ detail: String) -> Bool {
        TrackLog.d(SourcesLog.category, "Dolby Atmos (E-AC-3) decoders: \(detail)")
        return answer
    }
}
