import Foundation
import Observation
import VibraMusicCore

// Ports the per-network quality ceiling: AppSettings.effectiveAudioQuality + meteredConnection and
// SourceResolver.requestForNow, as one value the player's threads can read without the main actor.

/// The streaming ceiling in force right now: the Wi-Fi one or the cellular one, depending on the
/// connection in hand.
///
/// ``AppSettings`` owns the two settings and is main-actor isolated; the resolver, the read-ahead
/// and ``QualityUpgrade`` ask "what do I request *now*" from loading threads, on every track. This
/// holds a thread-safe copy of the two ceilings (kept in step with ``follow(_:)``) and reads the
/// connection from a ``NetworkStatusProviding`` (Core's ``NetworkMonitor`` in the app) at the moment
/// of asking — never from what was chosen an hour ago on a different network.
///
/// Metered, not literally cellular: a personal hotspot is Wi-Fi that costs money, and Low Data Mode
/// is the user saying so about any network (``NetworkStatus/isMetered``). Offline counts as Wi-Fi,
/// as it does in ``AppSettings/effectiveAudioQuality(for:)``.
///
/// With "Low" on cellular, the request is YouTube-only and capped at 64 kbps, which is what the
/// stats line then measures ("… · 48 kbps" to "… · 64 kbps" depending on the rung YouTube offers).
public final class PlaybackQualityCeiling: Observable, @unchecked Sendable {
    private let network: NetworkStatusProviding
    private let lock = NSLock()
    private var wifi: AudioQuality
    private var cellular: AudioQuality
    private var directSource: DirectSourceStream
    private var inParty = false
    private let registrar = ObservationRegistrar()

    /// - Parameters:
    ///   - network: the live connection.
    ///   - wifi, cellular: the starting ceilings; ``follow(_:)`` keeps them in step with settings.
    ///   - directSource: the starting "Direct source stream" choice, likewise followed.
    public init(network: NetworkStatusProviding, wifi: AudioQuality = .lossless, cellular: AudioQuality = .lossless,
                directSource: DirectSourceStream = .off) {
        self.network = network
        self.wifi = wifi
        self.cellular = cellular
        self.directSource = directSource
    }

    /// A ceiling that tracks `settings` for as long as it lives.
    @MainActor
    public convenience init(settings: AppSettings, network: NetworkStatusProviding) {
        self.init(network: network, wifi: settings.audioQualityWifi, cellular: settings.audioQualityCellular,
                  directSource: settings.directSourceStream)
        follow(settings)
    }

    /// The connection as it stands.
    public var networkStatus: NetworkStatus { network.status }

    /// The connection now, then every change to it: the half of ``effectiveQuality`` its
    /// observation doesn't cover for every provider.
    public func networkUpdates() -> AsyncStream<NetworkStatus> { network.statusUpdates() }

    /// The ceiling for a stream started now. Observable for the two settings; the connection half
    /// is read live (observe the monitor itself for connection changes).
    public var effectiveQuality: AudioQuality {
        registrar.access(self, keyPath: \.effectiveQuality)
        return Self.quality(on: network.status, wifi: lock.withLock { wifi }, cellular: lock.withLock { cellular })
    }

    /// Whether the cellular ceiling is the one in force.
    public var isCellularCeilingActive: Bool { network.status.isMetered == true }

    /// What to ask the resolver for, for a stream started now (Android `SourceResolver.requestForNow`):
    /// Lossless → the lossless tier from every source; High → best lossy, addons skipped; Medium →
    /// YouTube's best; Low → YouTube capped at 64 kbps.
    ///
    /// "Direct source stream" rides along: Always waits for the ranked sources
    /// (``StreamRequest/waitsForSources``), Queue only reads ahead from them
    /// (``StreamRequest/readsAheadFromSources``). Neither during a Listen Together party (Android's
    /// `DirectSourceGate.isActive`): a party seeks every member to the host's position and expects
    /// the track to be there, and a start held for the sources would leave this phone behind.
    public var currentRequest: StreamRequest {
        let (directSource, inParty): (DirectSourceStream, Bool) = lock.withLock { (self.directSource, self.inParty) }
        return .playback(effectiveQuality, directSource: inParty ? .off : directSource)
    }

    /// Whether this device is in a Listen Together party; the app keeps it in step.
    public func setInParty(_ inParty: Bool) {
        lock.withLock { self.inParty = inParty }
    }

    /// The ceiling on `status` given the two settings — the rule itself, for callers holding their
    /// own values.
    public static func quality(on status: NetworkStatus, wifi: AudioQuality, cellular: AudioQuality) -> AudioQuality {
        status.isMetered == true ? cellular : wifi
    }

    /// Replaces both ceilings.
    public func setCeilings(wifi: AudioQuality, cellular: AudioQuality) {
        let changed: Bool = lock.withLock {
            guard self.wifi != wifi || self.cellular != cellular else { return false }
            self.wifi = wifi
            self.cellular = cellular
            return true
        }
        if changed {
            onMainThread { [self] in registrar.withMutation(of: self, keyPath: \.effectiveQuality) {} }
        }
    }

    /// Keeps the ceilings and the direct-source choice in step with `settings` from now on
    /// (re-reading after every change to any of them). Holds the ceiling weakly.
    @MainActor
    public func follow(_ settings: AppSettings) {
        withObservationTracking {
            setCeilings(wifi: settings.audioQualityWifi, cellular: settings.audioQualityCellular)
            lock.withLock { directSource = settings.directSourceStream }
        } onChange: { [weak self, weak settings] in
            // onChange fires before the new value is stored; read it once the write has landed.
            Task { @MainActor in
                guard let self, let settings else { return }
                self.follow(settings)
            }
        }
    }
}
