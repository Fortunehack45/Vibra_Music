import Foundation
import Network
import Observation

// Replaces AppSettings.watchConnection / meteredConnection (ConnectivityManager callbacks) with
// NWPathMonitor (PORTING §4: "Network type").

/// The connection in hand, as the quality ceilings, the Wi-Fi-only download gate and the canvas
/// switch need it.
public struct NetworkStatus: Hashable, Sendable {
    public enum Interface: String, Hashable, Sendable {
        case wifi, cellular, wired, other
    }

    /// The interface the default route uses; nil when offline.
    public var interface: Interface?
    /// Cellular, or Wi-Fi through a personal hotspot.
    public var isExpensive: Bool
    /// Low Data Mode is on for this network.
    public var isConstrained: Bool

    public init(interface: Interface?, isExpensive: Bool = false, isConstrained: Bool = false) {
        self.interface = interface
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    public var isOnline: Bool { interface != nil }

    /// Whether the connection charges for data, or nil while offline — Android's nullable
    /// `meteredConnection`. Metered rather than literally-cellular: a tethered hotspot is Wi-Fi
    /// that costs money, and Low Data Mode is the user saying so about any network.
    public var isMetered: Bool? {
        guard isOnline else { return nil }
        return isExpensive || isConstrained
    }

    public static let offline = NetworkStatus(interface: nil)
    public static let wifi = NetworkStatus(interface: .wifi)
    public static let cellular = NetworkStatus(interface: .cellular, isExpensive: true)
}

/// Something that knows the current ``NetworkStatus``. ``NetworkMonitor`` in the app; tests use
/// `FakeNetworkMonitor` from VibraMusicTestSupport.
public protocol NetworkStatusProviding: AnyObject, Sendable {
    /// The latest known status. Safe to read from any thread.
    var status: NetworkStatus { get }
    /// Yields the current status immediately, then every change, until the task is cancelled.
    func statusUpdates() -> AsyncStream<NetworkStatus>
}

/// Watches the default route with `NWPathMonitor`.
///
/// Observable: SwiftUI views reading ``status`` update when it changes (notifications are delivered
/// on the main thread). Non-UI code reads ``status`` directly or iterates ``statusUpdates()``.
/// Starts monitoring on init; status is ``NetworkStatus/offline`` until the first path arrives
/// (typically within milliseconds).
public final class NetworkMonitor: NetworkStatusProviding, Observable, @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.fortune.vibramusic.ios.network-monitor")
    private let lock = NSLock()
    private var current = NetworkStatus.offline
    private var continuations: [UUID: AsyncStream<NetworkStatus>.Continuation] = [:]
    private let registrar = ObservationRegistrar()

    public init() {
        monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.publish(Self.status(of: path))
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
        lock.withLock { continuations.values.forEach { $0.finish() } }
    }

    public var status: NetworkStatus {
        registrar.access(self, keyPath: \.status)
        return lock.withLock { current }
    }

    public func statusUpdates() -> AsyncStream<NetworkStatus> {
        AsyncStream { continuation in
            let id = UUID()
            // The initial value goes out under the lock: `publish` yields after taking it, so a path
            // update landing in between can't be delivered ahead of the older value it replaces.
            lock.withLock {
                continuations[id] = continuation
                continuation.yield(current)
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                _ = self.lock.withLock { self.continuations.removeValue(forKey: id) }
            }
        }
    }

    /// Stops watching. The last status stays readable.
    public func cancel() {
        monitor.cancel()
    }

    private func publish(_ status: NetworkStatus) {
        let listeners: [AsyncStream<NetworkStatus>.Continuation]? = lock.withLock {
            guard current != status else { return nil }
            current = status
            return Array(continuations.values)
        }
        guard let listeners else { return }
        listeners.forEach { $0.yield(status) }
        // SwiftUI expects observation changes on the main thread; the value itself is already
        // readable (under the lock) by the time views re-read it.
        DispatchQueue.main.async { [self] in
            registrar.withMutation(of: self, keyPath: \.status) {}
        }
    }

    /// The mapping from a path to a status, separated so it can be reasoned about on its own.
    static func status(of path: NWPath) -> NetworkStatus {
        guard path.status == .satisfied else { return .offline }
        let interface: NetworkStatus.Interface
        if path.usesInterfaceType(.wifi) {
            interface = .wifi
        } else if path.usesInterfaceType(.cellular) {
            interface = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            interface = .wired
        } else {
            interface = .other
        }
        return NetworkStatus(interface: interface, isExpensive: path.isExpensive, isConstrained: path.isConstrained)
    }
}
