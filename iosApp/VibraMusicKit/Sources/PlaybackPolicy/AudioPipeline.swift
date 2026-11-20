import Foundation

// Ports the model behind ui/components/AudioPipelineDialog.kt: the five stages and their rows, and
// `bitExactVerdict` — whether decoded samples reach the output unaltered, and what alters them.

/// The chain from source to output, as the Audio Pipeline dialog shows it: Track Info → Decoder →
/// Resampler → DSP → Output Device, each a list of label/value rows, plus the one claim in the
/// dialog a listener might act on — whether the signal is altered on the way, and by what.
///
/// Built from the two live snapshots and the DSP settings; the UI only renders it.
public struct AudioPipeline: Hashable, Sendable {
    public enum StageKind: Int, Hashable, Sendable, CaseIterable {
        case trackInfo, decoder, resampler, dsp, outputDevice

        public var title: String {
            switch self {
            case .trackInfo: return "Track Info"
            case .decoder: return "Decoder"
            case .resampler: return "Resampler"
            case .dsp: return "DSP"
            case .outputDevice: return "Output Device"
            }
        }
    }

    public struct Row: Hashable, Sendable {
        public var label: String
        public var value: String

        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    public struct Stage: Hashable, Sendable, Identifiable {
        public var kind: StageKind
        public var rows: [Row]
        public var id: StageKind { kind }
        public var title: String { kind.title }

        /// The value of the row labelled `label`, if the stage has one.
        public func value(_ label: String) -> String? {
            rows.first { $0.label == label }?.value
        }
    }

    /// Something changing the samples between the decoder and the output, in signal-chain order.
    public enum Alteration: Hashable, Sendable {
        case loudnessNormalization(gainDb: Float)
        case equalizer
        case spatialAudio
        /// Playback at a rate other than 1×: `AVPlayer` time-stretches (pitch-preserving), which
        /// rewrites every sample. An iOS addition; Android's verdict did not name speed.
        case playbackSpeed(Float)
        /// The app renders the decoded source at a different rate (an app-side resample).
        case appResampled(fromHz: Int, toHz: Int)
        /// iOS's system mixer converts the rate the app renders at to the route's hardware rate.
        /// This is iOS's conversion, not the app's — the app can only hint at a rate.
        case resampled(fromHz: Int, toHz: Int)

        public var reason: String {
            switch self {
            case .loudnessNormalization: return "loudness normalization"
            case .equalizer: return "equalizer"
            case .spatialAudio: return "spatial audio"
            case .playbackSpeed(let rate): return "playback speed \(AudioPipeline.speedText(rate))"
            case .appResampled(let from, let to):
                return "resampled \(AudioOutputStatus.Snapshot.kilohertz(from)) → \(AudioOutputStatus.Snapshot.kilohertz(to)) kHz"
            case .resampled(let from, let to):
                return "converted by iOS \(AudioOutputStatus.Snapshot.kilohertz(from)) → \(AudioOutputStatus.Snapshot.kilohertz(to)) kHz"
            }
        }
    }

    /// The DSP settings in force (from ``VibraMusicCore/AppSettings`` and the equaliser).
    public struct DSPSettings: Hashable, Sendable {
        public var equalizerEnabled: Bool
        /// The preset or mode to show when the equaliser is on ("Bass boost", "Dynamic"); the
        /// preset list lives in AudioDSP, so the app supplies the name.
        public var equalizerDescription: String?
        public var spatialAudio: Bool
        public var loudnessNormalization: Bool
        public var playbackSpeed: Float
        /// Whether the item runs through the app's processing tap at all (the engine's
        /// ``PlaybackSignalPath/processed``). A tap-less item's DSP rows are "Bypassed" / "—".
        public var tapped: Bool

        public init(
            equalizerEnabled: Bool = false,
            equalizerDescription: String? = nil,
            spatialAudio: Bool = false,
            loudnessNormalization: Bool = true,
            playbackSpeed: Float = 1,
            tapped: Bool = true
        ) {
            self.equalizerEnabled = equalizerEnabled
            self.equalizerDescription = equalizerDescription
            self.spatialAudio = spatialAudio
            self.loudnessNormalization = loudnessNormalization
            self.playbackSpeed = playbackSpeed
            self.tapped = tapped
        }
    }

    public var stages: [Stage]
    /// Everything altering the samples, first in the chain first. Empty when the samples reach the
    /// output as decoded.
    public var alterations: [Alteration]
    /// The "Bit-exact" row: "Yes (…)" or "No — <the first thing altering the signal>".
    public var bitExactVerdict: String

    /// Whether the signal is changed anywhere between decoder and output.
    public var isSignalAltered: Bool { !bitExactVerdict.hasPrefix("Yes") }

    public func stage(_ kind: StageKind) -> Stage? {
        stages.first { $0.kind == kind }
    }

    /// Builds the pipeline from what is measured now.
    ///
    /// Figures the player hasn't reported read "—" rather than a guess. The verdict names the
    /// *first* stage altering the samples, which is also the first thing someone would change to
    /// get bit-exact output back:
    /// 1. a DSP stage running — loudness normalization (only when it is actually applying a gain),
    ///    the equaliser, spatial audio (the stereo widener), a playback speed other than 1×;
    /// 2. otherwise the rates: an app-side resample (the source rate against the render rate the
    ///    app hands iOS), then iOS's own conversion (the render rate against the route's hardware
    ///    rate). Unknown is not claimed as exact.
    public static func build(
        stats: NerdStats.Snapshot?,
        output: AudioOutputStatus.Snapshot,
        dsp: DSPSettings
    ) -> AudioPipeline {
        let dash = "—"

        // 1. Track info
        let channelsText: String
        switch stats?.channels {
        case nil: channelsText = dash
        case 1: channelsText = "Mono"
        case 2: channelsText = "Stereo"
        case let count?: channelsText = "\(count) (Surround)"
        }
        let trackInfo = Stage(kind: .trackInfo, rows: [
            Row("Source", stats?.sourceName ?? dash),
            Row("Format", NerdStats.codecLabel(stats?.mimeType) ?? stats?.mimeType ?? dash),
            Row("Bit Depth", (stats?.bitDepth ?? stats?.claimed?.bitDepth).map { "\($0)-bit" } ?? dash),
            Row("Sample Rate", (stats?.sampleRateHz ?? stats?.claimed?.sampleRateHz).map { "\($0) Hz" } ?? dash),
            Row("Bitrate", stats?.bitrateKbps.map { "\($0) kbps" } ?? dash),
            Row("Channels", channelsText),
        ])

        // 2. Decoder
        var decoderRows = [Row("Decoder Name", output.decoderName ?? dash)]
        if let format = output.decoderOutputFormat { decoderRows.append(Row("Format", format)) }
        let decoder = Stage(kind: .decoder, rows: decoderRows)

        // 3. Resampler. This stage is the app's: it compares the source rate with the rate the app
        // hands to iOS (the render rate). The route's own hardware rate is iOS's conversion, and it
        // shows on Output Device's "System" row instead of pretending the app resampled.
        let inRate = stats?.sampleRateHz
        let systemRate = output.hardwareSampleRateHz
        let outRate = output.renderSampleRateHz ?? inRate
        let isPassthrough = inRate != nil && outRate != nil && inRate == outRate
        let ioRateText: String
        switch (inRate, outRate) {
        case let (i?, o?): ioRateText = "\(i) Hz → \(o) Hz"
        case let (i?, nil): ioRateText = "\(i) Hz → \(dash)"
        case let (nil, o?): ioRateText = "\(dash) → \(o) Hz"
        case (nil, nil): ioRateText = dash
        }
        let bothUnknown = inRate == nil && outRate == nil
        let resampler = Stage(kind: .resampler, rows: [
            Row("I/O Rate", ioRateText),
            Row("Type", bothUnknown ? dash : (isPassthrough ? "None" : "Resampler")),
            Row("Cutoff", dash),
            Row("Quality", bothUnknown ? dash : (isPassthrough ? "Passthrough" : "Resampled")),
        ])

        // 4. DSP. Loudness reads first because that is the order the samples meet the stages in:
        // the level correction goes ahead of the filters. A tap-less item never reaches the chain,
        // so nothing there runs however the settings read: "Bypassed" / "—" rather than a format or
        // an alteration nobody measured.
        let equalizerActive = dsp.tapped && dsp.equalizerEnabled
        let spatialActive = dsp.tapped && dsp.spatialAudio
        let loudnessEnabled = dsp.tapped && dsp.loudnessNormalization
        let loudnessActive = loudnessEnabled && output.loudnessGainDb != nil
        let loudnessGainText: String
        if !loudnessEnabled {
            loudnessGainText = "Off"
        } else if let gain = output.loudnessGainDb {
            loudnessGainText = "\(signed(gain)) dB"
        } else {
            loudnessGainText = dash
        }
        let speedActive = abs(dsp.playbackSpeed - 1) > 0.001
        let dspRate = dsp.tapped ? (output.renderSampleRateHz ?? stats?.sampleRateHz) : nil
        var dspRows = [
            Row("PCM Format", dsp.tapped ? (output.dspFormat ?? dash) : "Bypassed"),
            Row("Sample Rate", dspRate.map { "\($0) Hz" } ?? dash),
            Row("Gain", loudnessGainText),
            Row("Measured", output.loudnessLufs.map { "\(signed($0)) LUFS" } ?? dash),
            Row("EQ Preset", equalizerActive ? (dsp.equalizerDescription ?? "On") : "Flat"),
            Row("Stereo Expand", spatialActive ? "250%" : "100%"),
            Row("Speed", speedActive ? "\(speedText(dsp.playbackSpeed)) (time-stretched)" : "1×"),
            Row("Buffers", buffersText(output: output) ?? dash),
            Row("Output API", output.sink.isEmpty ? "Core Audio" : output.sink),
        ]

        var alterations: [Alteration] = []
        if loudnessActive, let gain = output.loudnessGainDb { alterations.append(.loudnessNormalization(gainDb: gain)) }
        if equalizerActive { alterations.append(.equalizer) }
        if spatialActive { alterations.append(.spatialAudio) }
        if speedActive { alterations.append(.playbackSpeed(dsp.playbackSpeed)) }
        if let inRate, let render = output.renderSampleRateHz, inRate != render {
            alterations.append(.appResampled(fromHz: inRate, toHz: render))
        }
        if let rendered = outRate, let systemRate, rendered != systemRate {
            alterations.append(.resampled(fromHz: rendered, toHz: systemRate))
        }

        let verdict = bitExactVerdict(
            alterations: alterations,
            sourceRateHz: inRate,
            renderRateHz: outRate,
            routeRateHz: systemRate
        )
        dspRows.append(Row("Bit-exact", verdict))
        let dspStage = Stage(kind: .dsp, rows: dspRows)

        // 5. Output device
        var outputRows = [
            Row("Device Name", output.deviceName.isEmpty ? "System default" : output.deviceName),
            Row("Route", output.routeKind.routeName),
            Row("Sample Rate", output.hardwareSampleRateHz.map { "\($0) Hz" } ?? dash),
            Row("Channels", output.outputChannels.map(String.init) ?? dash),
        ]
        // iOS's own conversion, kept off the app's Resampler stage: the rate the route runs at, and
        // what it does to the rate the app handed it (Android's "System" row, the AudioFlinger mixer).
        if let systemRate {
            outputRows.append(Row("System", systemRowText(renderRateHz: outRate, hardwareRateHz: systemRate)))
        }
        if let latency = output.outputLatency {
            outputRows.append(Row("Latency", "\(Int((latency * 1_000).rounded())) ms"))
        }
        if output.routeKind == .bluetooth {
            if let profile = output.bluetoothProfile { outputRows.append(Row("Bluetooth", profile)) }
            // iOS does not expose the Bluetooth codec, rate or depth (PORTING.md §3).
            outputRows.append(Row("Codec", "System Managed"))
        }
        if output.systemSpatialAudioEnabled {
            outputRows.append(Row("Spatial Audio", "On (system)"))
        }
        let outputStage = Stage(kind: .outputDevice, rows: outputRows)

        return AudioPipeline(
            stages: [trackInfo, decoder, resampler, dspStage, outputStage],
            alterations: alterations,
            bitExactVerdict: verdict
        )
    }

    /// The verdict row. DSP stages come first because they are first in the chain. "End to end" is
    /// claimed only when the source, the render rate and the route's rate are all measured and equal;
    /// an unmeasured route is not a guess (an unknown `renderRateHz` assumes the source, because the
    /// app does not resample).
    static func bitExactVerdict(alterations: [Alteration], sourceRateHz: Int?, renderRateHz: Int?, routeRateHz: Int?) -> String {
        if let first = alterations.first { return "No — \(first.reason)" }
        guard let sourceRateHz, let renderRateHz, let routeRateHz else { return "No — not measured yet" }
        // Unreachable when the rates differ (that is an alteration above); kept explicit.
        guard sourceRateHz == renderRateHz, renderRateHz == routeRateHz else { return "No — converted downstream" }
        return "Yes (\(AudioOutputStatus.Snapshot.kilohertz(routeRateHz)) kHz end to end)"
    }

    /// Output Device's "System" row (Android's mixer row): the rate the route runs at, and the
    /// conversion iOS applies to the rate the app handed it when they differ. A nil `renderRateHz`
    /// means neither the render nor the source rate is known, so no conversion is claimed.
    static func systemRowText(renderRateHz: Int?, hardwareRateHz: Int) -> String {
        guard let renderRateHz, renderRateHz != hardwareRateHz else {
            return "Core Audio \(hardwareRateHz) Hz"
        }
        return "Core Audio \(hardwareRateHz) Hz, converts \(AudioOutputStatus.Snapshot.kilohertz(renderRateHz)) → \(AudioOutputStatus.Snapshot.kilohertz(hardwareRateHz)) kHz"
    }

    /// "<ms> ms, <frames> frames" with " (I/O)" appended when the frames are the session's I/O buffer
    /// — not Android's assumed "2x" (iOS does not report the buffer count). The milliseconds are
    /// computed at `bufferSampleRateHz`, the rate the frame count was counted at: the session's I/O
    /// buffer frames come from `ioBufferDuration × hardwareSampleRateHz`, while a render buffer a
    /// caller publishes is counted at the render rate. Using the render rate for the former labelled
    /// a 10 ms / 480-frame buffer as 11 ms whenever the track's rate differed from the route's.
    static func buffersText(output: AudioOutputStatus.Snapshot) -> String? {
        guard let frames = output.bufferFrames, frames > 0,
              let rate = output.bufferSampleRateHz ?? output.hardwareSampleRateHz, rate > 0 else { return nil }
        let ms = Int((Double(frames) / Double(rate) * 1_000).rounded())
        let suffix = output.bufferOrigin == .sessionIO ? " (I/O)" : ""
        return "\(ms) ms, \(frames) frames\(suffix)"
    }

    static func speedText(_ rate: Float) -> String {
        let text = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), rate)
        var trimmed = text
        while trimmed.hasSuffix("0") { trimmed.removeLast() }
        if trimmed.hasSuffix(".") { trimmed.removeLast() }
        return "\(trimmed)×"
    }

    private static func signed(_ value: Float) -> String {
        String(format: "%+.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
