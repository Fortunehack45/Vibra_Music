import Foundation

// MARK: - Limits

/// Service-wide bounds, mirroring `backend/config/config.go` defaults and the Android client.
/// (Ports the constants in `data/listentogether/ListenTogether.kt` and `playback/PartySync.kt`.)
public enum PartyLimits {
    /// Six characters, from `codes.CodeLength`.
    public static let codeLength = 6
    /// Devices per party out of the box (`JAM_MAX_MEMBERS`).
    public static let defaultMaxMembers = 5
    /// Smallest / largest party the host may size (`party.SetMaxMembers`).
    public static let minMembers = 2
    public static let maxMembers = 10
    /// Maximum upcoming tracks in the shared queue, excluding the current one
    /// (`JAM_MAX_UPCOMING_QUEUE`). Publishing more would only be truncated.
    public static let maxUpcomingQueue = 25
    public static let maxQueueLength = 1 + maxUpcomingQueue
    /// How long a dropped socket keeps its slot (`JAM_DISCONNECT_GRACE_MS`). Reconnecting
    /// inside this window is invisible to everyone else.
    public static let disconnectGraceMs: Int64 = 45_000
    /// How often the server re-states the truth, unprompted (`JAM_STATE_HEARTBEAT_MS`).
    public static let stateHeartbeatMs: Int64 = 5_000
    /// How far ahead a resume is scheduled (`JAM_PLAY_LEAD_MS`), so every device aims at
    /// one common instant instead of starting whenever its own packet landed.
    public static let playLeadMs: Int64 = 350
    /// A removal keeps this device out of that party (client-side; the server holds no grudge).
    public static let kickBlockMs: Int64 = 24 * 60 * 60 * 1_000
    /// App-level ping/report cadence, matching the Android client.
    public static let pingIntervalMs: Int64 = 15_000
    public static let reportIntervalMs: Int64 = 10_000
    public static let healthTimeoutMs: Int64 = 45_000
    /// Consecutive socket handshakes the server may refuse as unknown (401/404) before the
    /// membership is given up on: a restarted server has forgotten the party and will refuse
    /// every attempt, and one refusal alone could be a deploy mid-flight.
    public static let handshakeRefusalLimit = 3
    /// Sync follow behaviour (ports `PartySync`'s companion constants).
    public static let tickMs: Int64 = 700
    public static let driftLimitMs: Int64 = 1_200
    public static let driftStrikes = 2
    public static let driftCooldownMs: Int64 = 6_000
    public static let pausedToleranceMs: Int64 = 400
    public static let alignToleranceMs: Int64 = 120
    public static let seekReportFloorMs: Int64 = 1_000
    public static let deferredPlayTimeoutMs: Int64 = 1_800
    public static let publishDebounceMs: Int64 = 120
    public static let intentQuietMs: Int64 = 4_500
}

// MARK: - Frame types

/// Server → client frame names (`backend/protocol.FrameWelcome` …).
public enum PartyServerFrameType: String, Codable, Hashable, Sendable {
    case welcome, state, queue, members, pong, error, bye, activity
}

/// Client → server frame names (`backend/protocol.FramePing` …).
public enum PartyClientFrameType: String, Codable, Hashable, Sendable {
    case ping, control, sync, syncQueue, report
}

// MARK: - Control actions

/// Playback and membership controls (`backend/protocol.Action*`).
public enum PartyControlAction: String, Codable, Hashable, Sendable {
    case play, pause, seek
    case setTrack, setQueue
    case queueAdd, queueRemove, queueClear, queueMove
    case next, previous
    case kick, setMaxMembers, setAutoplay, setHostOnlyControl
}

public enum PartyControlPolicy {
    /// Actions a party's `hostOnlyControl` setting restricts to the host, mirroring
    /// Go's `protocol.ControlActions`. Membership actions are not here: `kick` and
    /// `setMaxMembers` are already host-only unconditionally, and `setHostOnlyControl`
    /// has to stay reachable by the host to be turned back off.
    public static let hostOnlyRestricted: Set<PartyControlAction> = [
        .play, .pause, .seek, .setTrack, .setQueue,
        .queueAdd, .queueRemove, .queueClear, .queueMove,
        .next, .previous, .setAutoplay,
    ]

    /// Whether the server would refuse this action from a non-host while the party is locked.
    /// `kick` / `setMaxMembers` are refused from non-hosts regardless of the lock.
    public static func isRefusedFromListener(_ action: PartyControlAction, hostOnlyControl: Bool) -> Bool {
        switch action {
        case .kick, .setMaxMembers:
            return true
        case .setHostOnlyControl:
            // Host-only by construction, but the lock flag is what this answers about.
            return false
        default:
            return hostOnlyControl && hostOnlyRestricted.contains(action)
        }
    }
}

// MARK: - Client → server messages

/// One `{"type":"control","action":…}` frame. Every field the server reads for any action
/// lives here, optional, so exactly one struct builds every control; fields the action does
/// not use are omitted rather than sent null (the server reads them with `, ok` guards).
public struct PartyControlMessage: Encodable, Hashable, Sendable {
    public var type: String = PartyClientFrameType.control.rawValue
    public var action: PartyControlAction
    public var positionMs: Int64?
    public var track: PartyTrack?
    public var queue: [PartyTrack]?
    public var queueIndex: Int?
    public var tracks: [PartyTrack]?
    public var playNext: Bool?
    public var videoId: String?
    public var memberId: String?
    public var maxMembers: Int?
    public var enabled: Bool?
    public var isPlaying: Bool?
    public var fromIndex: Int?
    public var toIndex: Int?

    public init(action: PartyControlAction) {
        self.action = action
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(action, forKey: .action)
        try c.encodeIfPresent(positionMs, forKey: .positionMs)
        try c.encodeIfPresent(track, forKey: .track)
        try c.encodeIfPresent(queue, forKey: .queue)
        try c.encodeIfPresent(queueIndex, forKey: .queueIndex)
        try c.encodeIfPresent(tracks, forKey: .tracks)
        try c.encodeIfPresent(playNext, forKey: .playNext)
        try c.encodeIfPresent(videoId, forKey: .videoId)
        try c.encodeIfPresent(memberId, forKey: .memberId)
        try c.encodeIfPresent(maxMembers, forKey: .maxMembers)
        try c.encodeIfPresent(enabled, forKey: .enabled)
        try c.encodeIfPresent(isPlaying, forKey: .isPlaying)
        try c.encodeIfPresent(fromIndex, forKey: .fromIndex)
        try c.encodeIfPresent(toIndex, forKey: .toIndex)
    }

    private enum CodingKeys: String, CodingKey {
        case type, action, positionMs, track, queue, queueIndex, tracks, playNext,
             videoId, memberId, maxMembers, enabled, isPlaying, fromIndex, toIndex
    }

    // MARK: Builders (one per server-understood shape)

    public static func play(at positionMs: Int64? = nil) -> PartyControlMessage {
        var m = PartyControlMessage(action: .play); m.positionMs = positionMs; return m
    }

    public static func pause(at positionMs: Int64? = nil) -> PartyControlMessage {
        var m = PartyControlMessage(action: .pause); m.positionMs = positionMs; return m
    }

    public static func seek(to positionMs: Int64) -> PartyControlMessage {
        var m = PartyControlMessage(action: .seek); m.positionMs = positionMs; return m
    }

    public static func setTrack(_ track: PartyTrack, positionMs: Int64 = 0, isPlaying: Bool = true) -> PartyControlMessage {
        var m = PartyControlMessage(action: .setTrack)
        m.track = track; m.positionMs = positionMs; m.isPlaying = isPlaying
        return m
    }

    public static func setQueue(_ queue: [PartyTrack], index: Int) -> PartyControlMessage {
        var m = PartyControlMessage(action: .setQueue); m.queue = queue; m.queueIndex = index; return m
    }

    public static func queueAdd(_ tracks: [PartyTrack], playNext: Bool = false) -> PartyControlMessage {
        var m = PartyControlMessage(action: .queueAdd); m.tracks = tracks; m.playNext = playNext; return m
    }

    public static func queueRemove(videoId: String) -> PartyControlMessage {
        var m = PartyControlMessage(action: .queueRemove); m.videoId = videoId; return m
    }

    public static func queueClear() -> PartyControlMessage {
        PartyControlMessage(action: .queueClear)
    }

    /// `videoId` disambiguates under concurrent lag: if a track completion shifted the
    /// indices between the tap and the server's lock, the server resolves `fromIndex`
    /// from the track instead of dropping the row in the wrong place.
    public static func queueMove(from fromIndex: Int, to toIndex: Int, videoId: String? = nil) -> PartyControlMessage {
        var m = PartyControlMessage(action: .queueMove)
        m.fromIndex = fromIndex; m.toIndex = toIndex; m.videoId = videoId
        return m
    }

    public static func next() -> PartyControlMessage { PartyControlMessage(action: .next) }
    public static func previous() -> PartyControlMessage { PartyControlMessage(action: .previous) }

    public static func kick(memberId: String) -> PartyControlMessage {
        var m = PartyControlMessage(action: .kick); m.memberId = memberId; return m
    }

    public static func setMaxMembers(_ value: Int) -> PartyControlMessage {
        var m = PartyControlMessage(action: .setMaxMembers); m.maxMembers = value; return m
    }

    public static func setAutoplay(_ enabled: Bool) -> PartyControlMessage {
        var m = PartyControlMessage(action: .setAutoplay); m.enabled = enabled; return m
    }

    public static func setHostOnlyControl(_ enabled: Bool) -> PartyControlMessage {
        var m = PartyControlMessage(action: .setHostOnlyControl); m.enabled = enabled; return m
    }
}

// MARK: - Server → client messages

/// A number that may arrive as an integer, a float (large ints round-trip through
/// `map[string]interface{}` on some relays), or a string. The party's clocks live here,
/// so being strict about the representation would desync over a proxy's formatting.
struct PartyFlexibleInt64: Decodable {
    var value: Int64
    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let v = try? single.decode(Int64.self) { value = partyClamped(v); return }
        if let d = try? single.decode(Double.self) { value = partyClamped(d); return }
        if let s = try? single.decode(String.self), let v = Int64(s) { value = partyClamped(v); return }
        throw DecodingError.typeMismatch(Int64.self, DecodingError.Context(
            codingPath: decoder.codingPath, debugDescription: "expected int64-ish value"))
    }
}

/// Every server → client frame, decoded leniently. `clientMs` on `pong` is echoed back
/// untouched, in whatever representation this client sent — hence the flexible integers.
public struct PartyServerMessage: Decodable, Sendable {
    public var type: PartyServerFrameType?
    public var rawType: String
    public var clientMs: Int64?
    public var serverMs: Int64?
    public var party: PartySnapshot?
    public var you: PartyMember?
    public var playback: PartyPlayback?
    public var queue: PartyQueue?
    public var members: [PartyMember]?
    public var maxMembers: Int?
    public var hostOnlyControl: Bool?
    public var action: String?
    public var by: String?
    public var atMs: Int64?
    public var detail: String?
    public var error: String?
    public var message: String?
    public var reason: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rawType = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? ""
        type = PartyServerFrameType(rawValue: rawType)
        clientMs = (try? c.decodeIfPresent(PartyFlexibleInt64.self, forKey: .clientMs))?.value
        serverMs = (try? c.decodeIfPresent(PartyFlexibleInt64.self, forKey: .serverMs))?.value
        party = try? c.decodeIfPresent(PartySnapshot.self, forKey: .party)
        you = try? c.decodeIfPresent(PartyMember.self, forKey: .you)
        playback = try? c.decodeIfPresent(PartyPlayback.self, forKey: .playback)
        queue = try? c.decodeIfPresent(PartyQueue.self, forKey: .queue)
        members = try? c.decodeIfPresent([PartyMember].self, forKey: .members)
        maxMembers = try? c.decodeIfPresent(Int.self, forKey: .maxMembers)
        hostOnlyControl = try? c.decodeIfPresent(Bool.self, forKey: .hostOnlyControl)
        action = try? c.decodeIfPresent(String.self, forKey: .action)
        by = try? c.decodeIfPresent(String.self, forKey: .by)
        atMs = (try? c.decodeIfPresent(PartyFlexibleInt64.self, forKey: .atMs))?.value
        detail = try? c.decodeIfPresent(String.self, forKey: .detail)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        message = try? c.decodeIfPresent(String.self, forKey: .message)
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
    }

    private enum CodingKeys: String, CodingKey {
        case type, clientMs, serverMs, party, you, playback, queue, members, maxMembers,
             hostOnlyControl, action, by, atMs, detail, error, message, reason
    }
}
