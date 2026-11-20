import Foundation
import AVFoundation
import AudioToolbox
import CoreMedia

// The iOS way to fill "stats for nerds" — replaces PlaybackService.measure / Format.measure /
// flacStreamInfo, which read Media3's renderer `Format`. Here the figures come from the playing
// item's audio track: its format description's AudioStreamBasicDescription (codec, rate, channels,
// depth), the FLAC STREAMINFO in its magic cookie where the description leaves gaps, the track's
// estimated data rate, and the item's access log for HLS.

/// What one audio stream is, as measured off the stream.
public struct MeasuredAudioFormat: Hashable, Sendable {
    /// The codec as a MIME type in the vocabulary ``NerdStats`` labels by: `audio/flac`,
    /// `audio/alac`, `audio/raw` (PCM), `audio/mp4a-latm` (AAC), `audio/mpeg`, `audio/opus`,
    /// `audio/eac3`, `audio/ac3`.
    public var mimeType: String?
    public var sampleRateHz: Int?
    public var channels: Int?
    /// Only stated by lossless and PCM streams; a lossy stream has no source bit depth.
    public var bitDepth: Int?
    /// The stream's own bitrate: the track's data rate for a progressive file, the HLS rendition's
    /// for a stream. Nil when neither says.
    public var bitrateKbps: Int?
    /// Download throughput from the access log. Not an audio bitrate — a stream downloading ahead
    /// reports whatever the network gives it — so it is kept apart and never shown as one.
    public var networkThroughputKbps: Int?

    public init(
        mimeType: String? = nil,
        sampleRateHz: Int? = nil,
        channels: Int? = nil,
        bitDepth: Int? = nil,
        bitrateKbps: Int? = nil,
        networkThroughputKbps: Int? = nil
    ) {
        self.mimeType = mimeType
        self.sampleRateHz = sampleRateHz
        self.channels = channels
        self.bitDepth = bitDepth
        self.bitrateKbps = bitrateKbps
        self.networkThroughputKbps = networkThroughputKbps
    }

    /// What the samples cost per second once decoded, in kbps: 16-bit · 44.1 kHz · stereo is 1411,
    /// 24-bit · 96 kHz · stereo is 4608 — the figures Tidal, Qobuz and Apple Music put next to a
    /// lossless track, and the only bitrate that means anything for one (a FLAC's compressed rate
    /// says more about how compressible the recording was). Nil unless all three are known: two
    /// thirds of this product is not a bitrate.
    public var pcmBitrateKbps: Int? {
        guard let bitDepth, let sampleRateHz, let channels else { return nil }
        let kbps = Int(Int64(bitDepth) * Int64(sampleRateHz) * Int64(channels) / 1_000)
        return kbps > 0 ? kbps : nil
    }
}

/// Reads ``MeasuredAudioFormat`` off AVFoundation objects.
public enum AudioFormatMeasurement {
    /// The access-log figures that matter, lifted out of `AVPlayerItemAccessLogEvent` (which cannot
    /// be constructed) so the choice between them can be tested.
    public struct AccessLogFigures: Hashable, Sendable {
        /// The HLS rendition's declared bandwidth, bits/s (`indicatedBitrate`); -1 or 0 when unknown.
        public var indicatedBitrate: Double
        /// The audio track's own average bitrate, bits/s (`averageAudioBitrate`).
        public var averageAudioBitrate: Double
        /// Network throughput, bits/s (`observedBitrate`).
        public var observedBitrate: Double

        public init(indicatedBitrate: Double, averageAudioBitrate: Double = 0, observedBitrate: Double = 0) {
            self.indicatedBitrate = indicatedBitrate
            self.averageAudioBitrate = averageAudioBitrate
            self.observedBitrate = observedBitrate
        }

        /// The audio bitrate these figures state, in kbps: the audio track's own average when
        /// present, otherwise the rendition's declared bandwidth (an audio-only HLS rendition's
        /// BANDWIDTH is its audio bitrate plus a little container overhead). Throughput is never
        /// used for this.
        public var audioBitrateKbps: Int? {
            if averageAudioBitrate.isFinite, averageAudioBitrate > 0 { return Int((averageAudioBitrate / 1_000).rounded()) }
            if indicatedBitrate.isFinite, indicatedBitrate > 0 { return Int((indicatedBitrate / 1_000).rounded()) }
            return nil
        }

        public var throughputKbps: Int? {
            guard observedBitrate.isFinite, observedBitrate > 0 else { return nil }
            return Int((observedBitrate / 1_000).rounded())
        }
    }

    /// The MIME type for a Core Audio format ID, in ``NerdStats``' vocabulary.
    public static func mimeType(forFormatID formatID: AudioFormatID) -> String? {
        switch formatID {
        case kAudioFormatFLAC: return "audio/flac"
        case kAudioFormatAppleLossless: return "audio/alac"
        case kAudioFormatLinearPCM: return "audio/raw"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
             kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD, kAudioFormatMPEG4AAC_ELD_SBR,
             kAudioFormatMPEG4AAC_ELD_V2, kAudioFormatMPEG4AAC_Spatial, kAudioFormatMPEGD_USAC:
            return "audio/mp4a-latm"
        case kAudioFormatMPEGLayer3: return "audio/mpeg"
        case kAudioFormatOpus: return "audio/opus"
        // Core Audio has no separate ID for Atmos-in-JOC; E-AC-3 is what carries it, and NerdStats
        // treats E-AC-3 as Dolby Atmos the way Android's decoder naming did.
        case kAudioFormatEnhancedAC3: return "audio/eac3"
        case kAudioFormatAC3: return "audio/ac3"
        case kAudioFormatAMR: return "audio/3gpp"
        default:
            return fourCC(formatID).map { "audio/\($0.trimmingCharacters(in: .whitespaces).lowercased())" }
        }
    }

    /// Measures one audio stream description.
    ///
    /// Every figure still comes from the stream: where the description leaves the sample rate or
    /// depth blank — FLAC in MP4 may write a zero rate, the escape the FLAC-in-ISOBMFF spec allows
    /// because the real figure lives in the `dfLa` box — it is read from the STREAMINFO block in the
    /// magic cookie, the one layer that always states it (a FLAC frame cannot be decoded without it).
    public static func measure(
        _ asbd: AudioStreamBasicDescription,
        magicCookie: Data? = nil,
        bitrateKbps: Int? = nil
    ) -> MeasuredAudioFormat {
        let streamInfo = asbd.mFormatID == kAudioFormatFLAC ? magicCookie.flatMap(flacStreamInfo) : nil
        let rate = asbd.mSampleRate.isFinite && asbd.mSampleRate > 0 ? Int(asbd.mSampleRate.rounded()) : nil
        let channels = asbd.mChannelsPerFrame > 0 ? Int(asbd.mChannelsPerFrame) : nil
        return MeasuredAudioFormat(
            mimeType: mimeType(forFormatID: asbd.mFormatID),
            sampleRateHz: rate ?? streamInfo?.sampleRateHz,
            channels: channels ?? streamInfo?.channels,
            bitDepth: sourceBitDepth(asbd) ?? streamInfo?.bitDepth,
            bitrateKbps: bitrateKbps
        )
    }

    /// Measures a Core Media audio format description.
    ///
    /// The *richest decodable* format is read first, because the stream description alone describes
    /// the container's view: HE-AAC with implicit SBR signalling (YouTube's low rungs) is stored as
    /// plain AAC at half the rate — `aac ` at 24 kHz — while the decoder produces 48 kHz HE-AAC.
    public static func measure(_ description: CMFormatDescription, bitrateKbps: Int? = nil) -> MeasuredAudioFormat? {
        guard CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio,
              let asbd = CMAudioFormatDescriptionGetRichestDecodableFormat(description)?.pointee.mASBD
                ?? CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return nil }
        var cookieSize = 0
        let cookie = CMAudioFormatDescriptionGetMagicCookie(description, sizeOut: &cookieSize)
            .flatMap { cookieSize > 0 ? Data(bytes: $0, count: cookieSize) : nil }
        return measure(asbd, magicCookie: cookie, bitrateKbps: bitrateKbps)
    }

    /// Measures an asset track: its first audio format description, with the track's estimated data
    /// rate as the bitrate.
    public static func measure(track: AVAssetTrack) async throws -> MeasuredAudioFormat? {
        let (descriptions, dataRate) = try await track.load(.formatDescriptions, .estimatedDataRate)
        let kbps = dataRate.isFinite && dataRate > 0 ? Int((Double(dataRate) / 1_000).rounded()) : nil
        for description in descriptions {
            if let measured = measure(description, bitrateKbps: kbps) { return measured }
        }
        return nil
    }

    /// Measures the first audio track of `asset` (a progressive file; HLS assets expose no tracks —
    /// measure the player item instead).
    public static func measure(asset: AVAsset) async throws -> MeasuredAudioFormat? {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        return try await measure(track: track)
    }

    /// Measures what `item` is playing: the audio track it is actually rendering (which for HLS is
    /// the current rendition), falling back to the asset's first audio track, with the access log's
    /// audio bitrate filling in where the track states none. Nil until the item has a track to read.
    ///
    /// Call it when the item becomes ready to play, on `AVPlayerItemNewAccessLogEntry`, and when the
    /// item's tracks change (an HLS variant switch).
    public static func measure(playerItem item: AVPlayerItem) async -> MeasuredAudioFormat? {
        let playing = await MainActor.run { () -> AVAssetTrack? in
            item.tracks.first { $0.isEnabled && $0.assetTrack?.mediaType == .audio }?.assetTrack
        }
        var measured: MeasuredAudioFormat?
        if let playing {
            measured = try? await measure(track: playing)
        }
        if measured == nil {
            measured = try? await measure(asset: item.asset)
        }
        let log = await MainActor.run { item.accessLog()?.events.last.map(AccessLogFigures.init) }
        guard var result = measured ?? (log != nil ? MeasuredAudioFormat() : nil) else { return nil }
        if result.bitrateKbps == nil { result.bitrateKbps = log?.audioBitrateKbps }
        result.networkThroughputKbps = log?.throughputKbps
        return result
    }

    // MARK: Pieces

    /// The source bit depth a description states: PCM's bits per channel, or the source-depth flag
    /// Apple Lossless and FLAC carry (their packets have no per-sample width). Nil for lossy codecs.
    static func sourceBitDepth(_ asbd: AudioStreamBasicDescription) -> Int? {
        switch asbd.mFormatID {
        case kAudioFormatLinearPCM:
            return asbd.mBitsPerChannel > 0 ? Int(asbd.mBitsPerChannel) : nil
        case kAudioFormatAppleLossless, kAudioFormatFLAC:
            // kAppleLosslessFormatFlag_16/20/24/32BitSourceData and kFLACFormatFlag_* share values.
            switch asbd.mFormatFlags {
            case 1: return 16
            case 2: return 20
            case 3: return 24
            case 4: return 32
            default: return asbd.mBitsPerChannel > 0 ? Int(asbd.mBitsPerChannel) : nil
            }
        default:
            return nil
        }
    }

    struct FlacStreamInfo: Hashable {
        var sampleRateHz: Int
        var channels: Int
        var bitDepth: Int
    }

    /// The STREAMINFO block inside a FLAC magic cookie or `dfLa` payload.
    ///
    /// The offset is found rather than assumed: the block may arrive behind a `fLaC` marker, inside
    /// a `dfLa` box (size, type, version/flags), or bare — so the metadata block header itself is
    /// looked for (type 0 = STREAMINFO, top bit = last-block flag, 24-bit length 34) near the start.
    static func flacStreamInfo(_ data: Data) -> FlacStreamInfo? {
        let bytes = [UInt8](data)
        let streamInfoLength = 34
        func headerAt(_ i: Int) -> Bool {
            bytes.count > i + 3 && (bytes[i] & 0x7F) == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 0 &&
                Int(bytes[i + 3]) == streamInfoLength
        }
        var body: Int?
        for offset in stride(from: 0, through: min(16, bytes.count), by: 1) where headerAt(offset) {
            body = offset + 4
            break
        }
        // A bare STREAMINFO body with no header in front of it.
        if body == nil, bytes.count == streamInfoLength { body = 0 }
        guard let start = body, bytes.count >= start + streamInfoLength else { return nil }
        func at(_ i: Int) -> Int { Int(bytes[start + i]) }
        // Two 16-bit block sizes and two 24-bit frame sizes (ten bytes), then — packed without
        // alignment — a 20-bit sample rate, a 3-bit channel count and a 5-bit depth, the last two
        // stored one less than they mean.
        let sampleRate = (at(10) << 12) | (at(11) << 4) | (at(12) >> 4)
        let channels = ((at(12) >> 1) & 0x07) + 1
        let bitDepth = (((at(12) & 0x01) << 4) | (at(13) >> 4)) + 1
        guard sampleRate > 0 else { return nil }
        return FlacStreamInfo(sampleRateHz: sampleRate, channels: channels, bitDepth: bitDepth)
    }

    static func fourCC(_ id: AudioFormatID) -> String? {
        let bytes = [UInt8((id >> 24) & 0xFF), UInt8((id >> 16) & 0xFF), UInt8((id >> 8) & 0xFF), UInt8(id & 0xFF)]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }
}

extension AudioFormatMeasurement.AccessLogFigures {
    init(_ event: AVPlayerItemAccessLogEvent) {
        self.init(
            indicatedBitrate: event.indicatedBitrate,
            averageAudioBitrate: event.averageAudioBitrate,
            observedBitrate: event.observedBitrate
        )
    }
}
