import AVFoundation
import PlaybackPolicy

/// Audio-session events the engine reacts to. On iOS the engine observes `AVAudioSession` itself
/// and feeds them to ``AudioPlayerEngine/handleAudioSessionEvent(_:)``; the method is public so a
/// macOS host (or a test) can drive the same logic.
public enum AudioSessionEvent: Hashable, Sendable {
    /// A call, alarm or another app took the audio. The system has already stopped our output.
    case interruptionBegan
    /// The interruption is over. `shouldResume` is the system's hint that resuming is appropriate.
    case interruptionEnded(shouldResume: Bool)
    /// The output in use went away — headphones unplugged, a Bluetooth device disconnected. The
    /// iOS form of Android's "becoming noisy": pause rather than blare out of the speaker.
    case outputDeviceUnavailable
    /// The media server restarted; every player object is invalid and must be rebuilt.
    case mediaServicesReset
}

/// The hardware sample rate to ask the audio session for.
///
/// On a USB DAC the session's rate is the rate the DAC runs at, so asking for the track's own rate
/// lets a 44.1 kHz or 96 kHz file reach the converter without being resampled to the session's
/// 48 kHz — the iOS counterpart of the Android service pointing its output at the USB device.
/// Every other route (the speaker, Bluetooth, AirPlay) resamples internally whatever is asked, so
/// there the engine leaves the system's choice alone.
enum PreferredSampleRatePolicy {
    static func preferredSampleRate(outputs: [AudioRouting.Kind], trackSampleRate: Double?) -> Double? {
        guard outputs.contains(.usb), let rate = trackSampleRate, rate >= 8_000 else { return nil }
        return rate
    }
}

#if os(iOS)
/// What the engine needs of its audio session. The real one is ``AudioSessionController``; a
/// test substitutes a fake to watch the rate request it receives.
@MainActor
protocol AudioSessionControlling: AnyObject {
    var trackSampleRate: Double? { get set }
    func activate()
    func allowMultichannelContent()
    func mediaServicesWereReset()
}

extension AudioSessionController: AudioSessionControlling {}

/// Owns the app's `AVAudioSession`: `.playback` so music continues with the screen locked and the
/// ring/silent switch on (with `UIBackgroundModes` `audio` in the app's Info.plist), long-form
/// routing so AirPlay and the system route picker treat the app as a music player.
@MainActor
final class AudioSessionController {
    private let session = AVAudioSession.sharedInstance()
    private var observers: [NSObjectProtocol] = []
    private let onEvent: @MainActor (AudioSessionEvent) -> Void
    private var isActive = false
    /// What the session's preferred rate was before the engine asked for a track's rate, restored
    /// when the route stops being USB.
    private var originalPreferredSampleRate: Double?

    /// The sample rate of the track playing now. On a USB route the session is asked for it.
    var trackSampleRate: Double? {
        didSet {
            guard trackSampleRate != oldValue else { return }
            applyPreferredSampleRate()
        }
    }

    init(onEvent: @escaping @MainActor (AudioSessionEvent) -> Void) {
        self.onEvent = onEvent
        configure()
        observe()
    }

    func configure() {
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
        } catch {
            PlaybackLog.warning("audio session category refused: \(error)")
        }
    }

    /// Activated when playback starts rather than at launch, so opening the app doesn't stop what
    /// another app is playing.
    func activate() {
        guard !isActive else { return }
        do {
            try session.setActive(true)
            isActive = true
            // A USB rate asked for while inactive only lands now.
            let outputs = currentOutputs()
            if let rate = PreferredSampleRatePolicy.preferredSampleRate(outputs: outputs, trackSampleRate: trackSampleRate) {
                logSampleRateReadBack(requested: rate, on: outputs)
            }
        } catch {
            PlaybackLog.warning("audio session activation refused: \(error)")
        }
    }

    /// Declares that the app plays multichannel content, so Dolby Atmos reaches an HDMI or AirPlay
    /// receiver as multichannel and AirPods can spatialize it, instead of being folded to stereo.
    func allowMultichannelContent() {
        guard !session.supportsMultichannelContent else { return }
        do {
            try session.setSupportsMultichannelContent(true)
        } catch {
            PlaybackLog.warning("multichannel content refused: \(error)")
        }
    }

    /// What a media-services reset leaves: a session that is no longer active, with its category and
    /// preferred rate gone. Set up again here, and activated by the next ``activate()``.
    func mediaServicesWereReset() {
        isActive = false
        configure()
        applyPreferredSampleRate()
    }

    private func applyPreferredSampleRate() {
        let outputs = currentOutputs()
        if let rate = PreferredSampleRatePolicy.preferredSampleRate(outputs: outputs, trackSampleRate: trackSampleRate) {
            guard session.preferredSampleRate != rate else { return }
            if originalPreferredSampleRate == nil { originalPreferredSampleRate = session.preferredSampleRate }
            do {
                try session.setPreferredSampleRate(rate)
                logSampleRateReadBack(requested: rate, on: outputs)
            } catch {
                PlaybackLog.warning("USB route: \(Int(rate)) Hz refused: \(error)")
            }
        } else if let original = originalPreferredSampleRate {
            originalPreferredSampleRate = nil
            // 0 is the session's "no preference"; a refusal leaves the USB rate, which is harmless
            // on a route that resamples anyway.
            try? session.setPreferredSampleRate(original)
        }
    }

    /// The rate is only a preference: read back what the session runs at, so a shared log shows
    /// whether the DAC honoured it. An inactive session still reports its old rate, so
    /// ``activate()`` reads it back again.
    private func logSampleRateReadBack(requested rate: Double, on outputs: [AudioRouting.Kind]) {
        let route = outputs.map(\.routeName).joined(separator: "+")
        let pending = isActive ? "" : " (session not active yet)"
        PlaybackLog.debug("USB route: preferred \(Int(rate)) Hz; session now \(Int(session.sampleRate)) Hz on \(route)\(pending)")
    }

    private func currentOutputs() -> [AudioRouting.Kind] {
        AudioRouting.currentPorts(session: session).compactMap { AudioRouting.kind(of: $0.type) }
    }

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            guard let event = Self.interruptionEvent(note.userInfo) else { return }
            MainActor.assumeIsolated {
                if case .interruptionBegan = event { self?.isActive = false }
                self?.onEvent(event)
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated {
                // A DAC plugged in or out: follow it with the preferred rate. Not for the change our
                // own rate request causes, which would only ask again for the same thing.
                if reason != .categoryChange, reason != .routeConfigurationChange { self?.applyPreferredSampleRate() }
                if reason == .oldDeviceUnavailable { self?.onEvent(.outputDeviceUnavailable) }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent(.mediaServicesReset) }
        })
    }

    nonisolated static func interruptionEvent(_ info: [AnyHashable: Any]?) -> AudioSessionEvent? {
        guard let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return nil }
        switch type {
        case .began:
            // An interruption reported because the app was suspended is history, not a new event:
            // the audio stopped while the app wasn't running and there is nothing to pause now.
            if let reason = info?[AVAudioSessionInterruptionReasonKey] as? UInt,
               AVAudioSession.InterruptionReason(rawValue: reason) == .appWasSuspended {
                return nil
            }
            return .interruptionBegan
        case .ended:
            let options = (info?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init) ?? []
            return .interruptionEnded(shouldResume: options.contains(.shouldResume))
        @unknown default:
            return nil
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
#endif
