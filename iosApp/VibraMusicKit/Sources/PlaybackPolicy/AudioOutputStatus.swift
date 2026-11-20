import Foundation
import Observation
#if os(iOS)
import AVFoundation
#endif

// Ports playback/AudioOutputStatus.kt — the output half of the audio pipeline — as far as iOS has an
// equivalent.
//
// Not ported, per PORTING.md §3: the AudioTrack transport and its direct/offload verdicts
// (`evaluateActualPath`), requested PCM mode and float fallback, the USB endpoint probe, Bluetooth
// codec telemetry, the AudioFlinger mixer/HAL figures and `encodingLabel`. iOS mixes every app in
// Core Audio's float mixer and exposes none of those choices. What it does expose — the route, the
// hardware sample rate and channel count, the IO buffer and output latency, whether the system's
// Spatial Audio is on — takes their place.

/// Live facts about the output route and the app's side of the audio pipeline, kept separate from
/// the source-format statistics in ``NerdStats``.
///
/// Written by the Playback module (decoder, DSP and render format as it configures its engine or
/// tap) and by ``refreshFromAudioSession()`` (route and hardware figures) on iOS. Observable
/// (``current``) and safe to write from any thread.
public final class AudioOutputStatus: Observable, @unchecked Sendable {
    public static let shared = AudioOutputStatus()

    public struct Snapshot: Hashable, Sendable {
        /// What renders the app's audio ("AVPlayer", "AVAudioEngine"): the pipeline's Output API row.
        public var sink: String = "AVPlayer"
        public var deviceName: String = "System default"
        /// The port uid of the device ``deviceName`` names — the one the picker and the caption both
        /// mark active, rather than each working out their own answer.
        public var activeDeviceId: String?
        public var routeKind: AudioRouting.Kind = .phone
        /// "A2DP" / "LE Audio" / "Hands-free" when the route is Bluetooth.
        public var bluetoothProfile: String?
        /// Every device in the current route, ordered as ``AudioRouting/devices(from:)`` orders them.
        public var outputs: [AudioRouting.Device] = []
        /// The rate the output hardware (and so the system mixer) runs at: `AVAudioSession.sampleRate`.
        public var hardwareSampleRateHz: Int?
        public var outputChannels: Int?
        /// The most channels the route can take (`maximumOutputNumberOfChannels`); above 2 is a
        /// multichannel route, one of the checks PORTING.md §4 names for Dolby Atmos.
        public var maximumOutputChannels: Int?
        public var ioBufferDuration: TimeInterval?
        public var outputLatency: TimeInterval?
        /// Whether the system's Spatial Audio (head-tracked, on AirPods and Beats) is on for the route.
        public var systemSpatialAudioEnabled: Bool = false
        /// The rate the app's own audio is rendered at — the engine's or tap's processing format.
        /// Android's `actualSampleRateHz` (the AudioTrack's rate).
        public var renderSampleRateHz: Int?
        /// Frames per render buffer, where the engine or tap reports one.
        public var bufferFrames: Int?
        /// The sample rate `bufferFrames` was counted at. The session's I/O buffer frames come from
        /// `ioBufferDuration × hardwareSampleRateHz`; a render buffer a caller publishes supplies the
        /// render rate. The Buffers row converts frames to milliseconds with this rate, so it never
        /// mixes the two.
        public var bufferSampleRateHz: Int?
        /// Where ``bufferFrames`` came from. The Buffers row labels only the session's I/O buffer
        /// with "(I/O)"; a render buffer is not the I/O buffer.
        public enum BufferOrigin: Hashable, Sendable { case sessionIO, render }
        public var bufferOrigin: BufferOrigin?
        /// What decodes the stream ("AudioToolbox (AAC)"); iOS names no codec instance the way
        /// MediaCodec does, so the Playback module supplies a description.
        public var decoderName: String?
        /// The decoder's output format as the DSP stage receives it.
        public var decoderOutputFormat: String?
        /// The sample format the DSP chain runs in; nil until a tap has measured one. Core Audio's
        /// canonical format is Float32, but the sheet must not print a guess before the tap reports.
        public var dspFormat: String?
        /// Whether the DSP chain can run on the playing track at all. False only when the stream
        /// bypasses the app's processing (for example a stream rendered by AVPlayer without a tap,
        /// such as FairPlay or some HLS renditions), where the equaliser is genuinely inert.
        public var dspAvailable: Bool = true
        /// Gain loudness normalization is applying, in dB; nil when off or no figure was offered.
        public var loudnessGainDb: Float?
        /// YouTube's own normalization figure for the track, in dB, when known.
        public var loudnessLufs: Float?

        public init() {}

        /// The rate the audio leaves the app at: what it renders at, or failing that what the
        /// hardware runs at.
        public var outputSampleRateHz: Int? { renderSampleRateHz ?? hardwareSampleRateHz }

        /// Whether the route can carry more than CD resolution to the listener.
        ///
        /// Android read this off the AudioTrack's encoding (24/32-bit or float) or a rate above
        /// 48 kHz. Core Audio's mixer is always float, so the encoding says nothing on iOS; what
        /// does is the route: a hardware rate above 48 kHz (a USB DAC running at the source rate),
        /// or a wired/USB DAC, which Apple's run at 24-bit. Bluetooth re-encodes to AAC and AirPlay
        /// to 16/44.1 ALAC, so neither carries hi-res whatever the source.
        public var routeCarriesHiRes: Bool {
            if (hardwareSampleRateHz ?? 0) > 48_000 { return true }
            return routeKind == .wired || routeKind == .usb
        }

        /// "48 kHz · 2 ch" — whichever of rate and channel count are known, for the output sheet.
        public var summary: String {
            var parts: [String] = []
            if let rate = outputSampleRateHz, rate > 0 { parts.append("\(Self.kilohertz(rate)) kHz") }
            if let outputChannels, outputChannels > 0 { parts.append("\(outputChannels) ch") }
            return parts.isEmpty ? "—" : parts.joined(separator: " · ")
        }

        /// 44100 → "44.1", 48000 → "48".
        static func kilohertz(_ hz: Int) -> String {
            let text = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), Double(hz) / 1_000)
            return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
        }
    }

    private let lock = NSLock()
    private var snapshot = Snapshot()
    private let registrar = ObservationRegistrar()

    public init() {}

    /// The pipeline as it stands. Observable.
    public var current: Snapshot {
        registrar.access(self, keyPath: \.current)
        return lock.withLock { snapshot }
    }

    /// Publishes the current route and the hardware figures that come with it.
    public func publishRoute(
        ports: [AudioRouting.Port],
        hardwareSampleRateHz: Int?,
        outputChannels: Int?,
        maximumOutputChannels: Int? = nil,
        ioBufferDuration: TimeInterval? = nil,
        outputLatency: TimeInterval? = nil
    ) {
        let devices = AudioRouting.devices(from: ports)
        let active = devices.first
        update { snapshot in
            snapshot.outputs = devices
            snapshot.activeDeviceId = active?.id
            snapshot.deviceName = active.map { AudioRouting.label(for: $0, accountName: nil) } ?? "System default"
            snapshot.routeKind = active?.kind ?? .phone
            snapshot.bluetoothProfile = active?.bluetoothProfile
            snapshot.systemSpatialAudioEnabled = active?.isSpatialAudioEnabled ?? false
            snapshot.hardwareSampleRateHz = hardwareSampleRateHz.flatMap { $0 > 0 ? $0 : nil }
            snapshot.outputChannels = outputChannels.flatMap { $0 > 0 ? $0 : nil }
            snapshot.maximumOutputChannels = maximumOutputChannels.flatMap { $0 > 0 ? $0 : nil }
            snapshot.ioBufferDuration = ioBufferDuration
            snapshot.outputLatency = outputLatency
            // The I/O buffer in frames — the session's buffer duration at the route's rate, the
            // real number behind the pipeline sheet's Buffers row (Android had the AudioTrack's
            // own buffer there). `refreshFromAudioSession` supplies both when it reads the session.
            if let ioBufferDuration, ioBufferDuration > 0, let rate = snapshot.hardwareSampleRateHz, rate > 0 {
                snapshot.bufferFrames = Int((ioBufferDuration * Double(rate)).rounded())
                snapshot.bufferSampleRateHz = rate
                snapshot.bufferOrigin = .sessionIO
            }
        }
    }

    /// Names the renderer ("AVPlayer", "AVAudioEngine").
    public func publishSink(_ sink: String) {
        update { $0.sink = sink }
    }

    public func publishDecoder(_ decoderName: String?) {
        update { $0.decoderName = decoderName }
    }

    /// The measured decoder output and DSP formats, written once the engine or tap has a real format
    /// in hand. Route publishes never touch these: on Android copying predicted constants over them
    /// on every route change left both rows reading "Float32" for ever.
    public func publishDsp(decoderOutputFormat: String?, dspFormat: String? = nil, dspAvailable: Bool = true) {
        update { snapshot in
            snapshot.decoderOutputFormat = decoderOutputFormat
            snapshot.dspFormat = dspFormat
            snapshot.dspAvailable = dspAvailable
        }
    }

    /// The format the app renders at (Android's `publishAudioTrack`). A nil `bufferFrames` keeps
    /// the last one reported; when given, the frames are counted at `sampleRateHz`, and the Buffers
    /// row converts them back at that rate. Without a usable `sampleRateHz` there is no rate to
    /// convert them from, so the buffer is cleared rather than described against another rate.
    public func publishRender(sampleRateHz: Int, bufferFrames: Int? = nil) {
        update { snapshot in
            snapshot.renderSampleRateHz = sampleRateHz > 0 ? sampleRateHz : nil
            if let bufferFrames {
                let usable = sampleRateHz > 0
                snapshot.bufferFrames = usable ? bufferFrames : nil
                snapshot.bufferSampleRateHz = usable ? sampleRateHz : nil
                snapshot.bufferOrigin = usable ? .render : nil
            }
        }
    }

    /// What loudness normalization is doing to the playing track. Nils mean "nothing" — off, or no
    /// figure for this track — and read as inactive.
    public func publishLoudness(gainDb: Float?, lufs: Float?) {
        update { snapshot in
            snapshot.loudnessGainDb = gainDb
            snapshot.loudnessLufs = lufs
        }
    }

    public func reset() {
        update { $0 = Snapshot() }
    }

    #if os(iOS)
    /// Re-reads the route and hardware figures from the audio session.
    public func refreshFromAudioSession(_ session: AVAudioSession = .sharedInstance()) {
        publishRoute(
            ports: AudioRouting.currentPorts(session: session),
            hardwareSampleRateHz: Int(session.sampleRate.rounded()),
            outputChannels: session.outputNumberOfChannels,
            maximumOutputChannels: session.maximumOutputNumberOfChannels,
            ioBufferDuration: session.ioBufferDuration,
            outputLatency: session.outputLatency
        )
    }

    /// Keeps the route half current: refreshes now and after every route or media-services change,
    /// until the returned task is cancelled.
    @discardableResult
    public func followAudioSession(_ session: AVAudioSession = .sharedInstance()) -> Task<Void, Never> {
        refreshFromAudioSession(session)
        return Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AVAudioSession.routeChangeNotification, object: session) {
                guard let self else { return }
                self.refreshFromAudioSession(session)
            }
        }
    }
    #endif

    private func update(_ body: (inout Snapshot) -> Void) {
        let changed: Bool = lock.withLock {
            var next = snapshot
            body(&next)
            guard next != snapshot else { return false }
            snapshot = next
            return true
        }
        if changed {
            onMainThread { [self] in registrar.withMutation(of: self, keyPath: \.current) {} }
        }
    }
}
