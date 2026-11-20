import Foundation
#if os(iOS)
import AVFoundation
#endif

// Ports playback/AudioRouting.kt and the naming half of ui/player/AudioOutput.kt.

/// Which output the music is coming out of.
///
/// ### What changes on iOS
///
/// Android lists every connected sink and lets the listener pick one, because its player can be
/// pointed at any of them (`setPreferredAudioDevice`). iOS gives an app neither half: the only
/// outputs it can see are the ones in the *current* route (`AVAudioSession.currentRoute.outputs`),
/// and choosing another is the system's job — the picker is `AVRoutePickerView` (PORTING.md §4). So
/// the selection state (`selectedId`/`select`/`forget`) is not ported, and every device described
/// here is active. What survives is the description: kinds worth telling apart on screen, a name
/// that is not the phone's model number, one row per physical device.
///
/// Android's reason for reading the device list rather than MediaRouter — the router's answer
/// flickered while a Bluetooth profile connected — has an iOS counterpart: re-read on
/// `AVAudioSession.routeChangeNotification` (``routeChanges()``) rather than caching a route.
public enum AudioRouting {
    /// Output kinds worth telling apart on screen, in the order they are listed.
    ///
    /// `airPlay` and `car` are iOS additions: Android has no AirPlay, and its car is a separate app.
    public enum Kind: Int, Hashable, Sendable, CaseIterable, Comparable {
        case phone, wired, usb, bluetooth, hdmi, airPlay, car, other

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }

        /// Upper-case name, as the Android pipeline dialog's "Route" row printed the enum.
        public var routeName: String {
            switch self {
            case .phone: return "PHONE"
            case .wired: return "WIRED"
            case .usb: return "USB"
            case .bluetooth: return "BLUETOOTH"
            case .hdmi: return "HDMI"
            case .airPlay: return "AIRPLAY"
            case .car: return "CAR"
            case .other: return "OTHER"
            }
        }
    }

    /// `AVAudioSession.Port` output types, mirrored so the rules below can be tested on the Mac,
    /// where `AVAudioSession` does not exist.
    public enum PortType: Hashable, Sendable {
        case builtInSpeaker
        /// The telephony earpiece. Only ever the route during a call-style session.
        case builtInReceiver
        case headphones
        case lineOut
        case usbAudio
        case bluetoothA2DP
        case bluetoothLE
        /// The Bluetooth telephony profile (Android's SCO).
        case bluetoothHFP
        case hdmi
        case displayPort
        case airPlay
        case carAudio
        case other(String)
    }

    /// One output port of the current route.
    public struct Port: Hashable, Sendable {
        public var type: PortType
        /// What the port calls itself (`portName`): "AirPods Pro", "Speaker", "Headphones".
        public var name: String
        /// `uid`, stable for as long as the device stays connected.
        public var uid: String
        public var channelCount: Int?
        /// Whether the system's own Spatial Audio (head tracking) is on for this port.
        public var isSpatialAudioEnabled: Bool

        public init(type: PortType, name: String, uid: String, channelCount: Int? = nil, isSpatialAudioEnabled: Bool = false) {
            self.type = type
            self.name = name
            self.uid = uid
            self.channelCount = channelCount
            self.isSpatialAudioEnabled = isSpatialAudioEnabled
        }
    }

    public struct Device: Hashable, Sendable, Identifiable {
        /// The port's uid.
        public var id: String
        /// Carried rather than collapsed into ``kind`` because several entries can share a kind and
        /// a name while only one of them plays music — see ``devices(from:)``.
        public var portType: PortType
        /// What the device calls itself, and blank for the outputs that have no name of their own
        /// (the phone's speaker, wired headphones); ``label(for:accountName:)`` supplies those.
        public var name: String
        public var kind: Kind
        /// Where the audio is going right now. On iOS every device in the current route is.
        public var isActive: Bool
        /// "A2DP", "LE Audio" or "Hands-free" for a Bluetooth route; ``kind`` alone can't say which,
        /// and LE Audio earbuds are not A2DP.
        public var bluetoothProfile: String?
        public var channelCount: Int?
        public var isSpatialAudioEnabled: Bool

        public init(
            id: String,
            portType: PortType,
            name: String,
            kind: Kind,
            isActive: Bool = true,
            bluetoothProfile: String? = nil,
            channelCount: Int? = nil,
            isSpatialAudioEnabled: Bool = false
        ) {
            self.id = id
            self.portType = portType
            self.name = name
            self.kind = kind
            self.isActive = isActive
            self.bluetoothProfile = bluetoothProfile
            self.channelCount = channelCount
            self.isSpatialAudioEnabled = isSpatialAudioEnabled
        }
    }

    /// The kind of an output port, or nil for one that is not somewhere music is listened to.
    ///
    /// Android left out the telephony earpiece and SCO so they would not be *offered* — pointing the
    /// player at SCO sent the music to the phone speaker at the headset's volume. Nothing is offered
    /// here, only described, so a current route that really is the receiver or HFP (another app's
    /// call-style session) is still named: the receiver as the phone, HFP as Bluetooth.
    public static func kind(of type: PortType) -> Kind? {
        switch type {
        case .builtInSpeaker, .builtInReceiver: return .phone
        case .headphones, .lineOut: return .wired
        case .usbAudio: return .usb
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: return .bluetooth
        case .hdmi, .displayPort: return .hdmi
        case .airPlay: return .airPlay
        case .carAudio: return .car
        case .other: return .other
        }
    }

    /// The Bluetooth profile a port type names, or nil when it is not Bluetooth.
    public static func bluetoothProfile(of type: PortType) -> String? {
        switch type {
        case .bluetoothA2DP: return "A2DP"
        case .bluetoothLE: return "LE Audio"
        case .bluetoothHFP: return "Hands-free"
        default: return nil
        }
    }

    /// The devices behind `ports`: one row per physical device, in ``Kind`` order.
    ///
    /// Several ports under one name is normal (a headset's media and telephony profiles), and which
    /// one survives matters: A2DP is the Bluetooth media profile and wins any tie, then LE Audio.
    public static func devices(from ports: [Port]) -> [Device] {
        let rows = ports.compactMap { port -> Device? in
            guard let kind = kind(of: port.type) else { return nil }
            return Device(
                id: port.uid,
                portType: port.type,
                name: name(of: port, kind: kind),
                kind: kind,
                isActive: true,
                bluetoothProfile: bluetoothProfile(of: port.type),
                channelCount: port.channelCount,
                isSpatialAudioEnabled: port.isSpatialAudioEnabled
            )
        }
        var chosen: [String: Device] = [:]
        var order: [String] = []
        for row in rows {
            let key = "\(row.kind.rawValue)|\(row.name)"
            if let existing = chosen[key] {
                if preference(within: row.portType) < preference(within: existing.portType) { chosen[key] = row }
            } else {
                chosen[key] = row
                order.append(key)
            }
        }
        // Stable within a kind, like Kotlin's sortedBy.
        return order.compactMap { chosen[$0] }
            .enumerated()
            .sorted { ($0.element.kind, $0.offset) < ($1.element.kind, $1.offset) }
            .map(\.element)
    }

    /// What to call an output on screen.
    ///
    /// Devices that carry their own name keep it. The phone's speaker and wired headphones don't —
    /// on Android `productName` gave the *phone's* model for both ("SM-S911B"), and iOS's
    /// `portName` for them ("Speaker", "Headphones") says nothing a label doesn't — so those get one
    /// from here.
    public static func label(for device: Device, accountName: String?) -> String {
        if !device.name.isEmpty { return device.name }
        switch device.kind {
        case .wired: return "Wired headphones"
        case .usb: return "USB audio"
        case .hdmi: return "HDMI"
        case .airPlay: return "AirPlay"
        case .car: return "CarPlay"
        case .phone, .bluetooth, .other:
            return phoneLabel(accountName: accountName)
        }
    }

    /// The name of whatever is playing the music, for the line under the transport — derived from
    /// the same list the output sheet shows, so the two can never disagree.
    public static func outputName(of devices: [Device], accountName: String?) -> String {
        guard let active = devices.first(where: \.isActive) else { return phoneLabel(accountName: accountName) }
        return label(for: active, accountName: accountName)
    }

    /// "Kushagra’s Phone" when the account has a name, "This phone" otherwise.
    public static func phoneLabel(accountName: String?) -> String {
        let first = accountName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .first
        if let first, !first.isEmpty { return "\(first)’s Phone" }
        return "This phone"
    }

    /// Lowest first: which of several ports for one device to keep.
    private static func preference(within type: PortType) -> Int {
        switch type {
        case .bluetoothA2DP: return 0
        case .bluetoothLE: return 1
        default: return 2
        }
    }

    private static func name(of port: Port, kind: Kind) -> String {
        switch kind {
        case .phone, .wired: return ""
        default: return port.name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    #if os(iOS)
    /// The output ports of the audio session's current route.
    public static func currentPorts(session: AVAudioSession = .sharedInstance()) -> [Port] {
        session.currentRoute.outputs.map { description in
            Port(
                type: PortType(description.portType),
                name: description.portName,
                uid: description.uid,
                channelCount: description.channels?.count,
                isSpatialAudioEnabled: description.isSpatialAudioEnabled
            )
        }
    }

    /// The devices the music is reaching right now.
    public static func currentOutputs(session: AVAudioSession = .sharedInstance()) -> [Device] {
        devices(from: currentPorts(session: session))
    }

    /// The current outputs now, and again after every route change (headphones in or out,
    /// AirPods connecting, AirPlay chosen in the route picker), until the task is cancelled.
    public static func routeChanges(session: AVAudioSession = .sharedInstance()) -> AsyncStream<[Device]> {
        AsyncStream { continuation in
            continuation.yield(currentOutputs(session: session))
            let observer = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: session,
                queue: nil
            ) { _ in
                continuation.yield(currentOutputs(session: session))
            }
            continuation.onTermination = { _ in
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
    #endif
}

#if os(iOS)
extension AudioRouting.PortType {
    init(_ port: AVAudioSession.Port) {
        switch port {
        case .builtInSpeaker: self = .builtInSpeaker
        case .builtInReceiver: self = .builtInReceiver
        case .headphones: self = .headphones
        case .lineOut: self = .lineOut
        case .usbAudio: self = .usbAudio
        case .bluetoothA2DP: self = .bluetoothA2DP
        case .bluetoothLE: self = .bluetoothLE
        case .bluetoothHFP: self = .bluetoothHFP
        case .HDMI: self = .hdmi
        case .displayPort: self = .displayPort
        case .airPlay: self = .airPlay
        case .carAudio: self = .carAudio
        default: self = .other(port.rawValue)
        }
    }
}
#endif
