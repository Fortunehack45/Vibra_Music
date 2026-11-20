import Foundation

// MARK: - Lenient decoding helpers

/// The party server is the only other writer of these payloads, and it may gain fields
/// (or predate ones this build knows). Every model below therefore decodes missing keys
/// as its default and skips unknown keys, mirroring Kotlin's `ignoreUnknownKeys = true`.
extension KeyedDecodingContainer {
    func decodePresent(_ type: String.Type, forKey key: Key) -> String {
        (try? decodeIfPresent(String.self, forKey: key)) ?? ""
    }

    func decodePresent(_ type: Int.Type, forKey key: Key) -> Int {
        Int(decodePresent(Int64.self, forKey: key))
    }

    func decodePresent(_ type: Int64.Type, forKey key: Key) -> Int64 {
        if let v = try? decodeIfPresent(Int64.self, forKey: key) { return partyClamped(v) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return partyClamped(d) }
        return 0
    }

    func decodePresent(_ type: Bool.Type, forKey key: Key) -> Bool {
        (try? decodeIfPresent(Bool.self, forKey: key)) ?? false
    }

    func decodePresent<T: Decodable>(_ type: [T].Type, forKey key: Key) -> [T] {
        (try? decodeIfPresent([T].self, forKey: key)) ?? []
    }
}

/// The largest integer a party frame carries exactly: the server and the other clients treat JSON
/// numbers as doubles. Every number another device can set is clamped into ±this on decoding, so
/// nothing past Int64 traps converting and the sums and differences of positions, anchors and
/// clock readings can't overflow (a member's seek to near Int64.max crashed every client).
let partyMaxExactInteger: Int64 = 9_007_199_254_740_991

func partyClamped(_ value: Int64) -> Int64 {
    min(max(value, -partyMaxExactInteger), partyMaxExactInteger)
}

func partyClamped(_ value: Double) -> Int64 {
    guard !value.isNaN else { return 0 }
    return Int64(min(max(value, -Double(partyMaxExactInteger)), Double(partyMaxExactInteger)))
}

// MARK: - PartyTrack

/// A song as the party knows it.
///
/// Deliberately *not* a `Song`: what a party shares is which track is playing and where
/// the playhead is; how each device gets the audio — which source answered, at what
/// quality, from the network or from a download — stays that device's own business.
/// Two people in a party can be on entirely different sources and still be in the same
/// place in the same song, and keeping this type small is what guarantees that.
/// (Ports `PartyTrack` in `data/listentogether/PartyModels.kt`.)
public struct PartyTrack: Codable, Hashable, Sendable {
    public var videoId: String
    public var title: String
    public var artist: String
    public var thumbnailUrl: String?
    public var durationMs: Int64?
    /// Preserves the queue's shared manual/AutoPlay section boundary.
    public var fromAutoplay: Bool

    public init(
        videoId: String,
        title: String = "",
        artist: String = "",
        thumbnailUrl: String? = nil,
        durationMs: Int64? = nil,
        fromAutoplay: Bool = false
    ) {
        self.videoId = videoId
        self.title = title
        self.artist = artist
        self.thumbnailUrl = thumbnailUrl
        self.durationMs = durationMs
        self.fromAutoplay = fromAutoplay
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        videoId = c.decodePresent(String.self, forKey: .videoId)
        title = c.decodePresent(String.self, forKey: .title)
        artist = c.decodePresent(String.self, forKey: .artist)
        thumbnailUrl = try? c.decodeIfPresent(String.self, forKey: .thumbnailUrl)
        durationMs = (try? c.decodeIfPresent(Int64.self, forKey: .durationMs)).map { partyClamped($0) }
        fromAutoplay = c.decodePresent(Bool.self, forKey: .fromAutoplay)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(videoId, forKey: .videoId)
        try c.encode(title, forKey: .title)
        try c.encode(artist, forKey: .artist)
        try c.encodeIfPresent(thumbnailUrl, forKey: .thumbnailUrl)
        try c.encodeIfPresent(durationMs, forKey: .durationMs)
        try c.encode(fromAutoplay, forKey: .fromAutoplay)
    }

    private enum CodingKeys: String, CodingKey {
        case videoId, title, artist, thumbnailUrl, durationMs, fromAutoplay
    }
}

// MARK: - PartyMember

/// One signed-in device in the party, as every other device sees it.
/// (Ports `PartyMember` in `data/listentogether/PartyModels.kt`.)
public struct PartyMember: Codable, Hashable, Sendable {
    public var memberId: String
    public var userId: String
    public var displayName: String
    public var avatarUrl: String?
    public var isHost: Bool
    /// Whether they are currently holding a socket — not whether they are still in.
    public var connected: Bool
    public var joinedAtMs: Int64
    public var lastSeenMs: Int64

    public init(
        memberId: String,
        userId: String = "",
        displayName: String = "",
        avatarUrl: String? = nil,
        isHost: Bool = false,
        connected: Bool = false,
        joinedAtMs: Int64 = 0,
        lastSeenMs: Int64 = 0
    ) {
        self.memberId = memberId
        self.userId = userId
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.isHost = isHost
        self.connected = connected
        self.joinedAtMs = joinedAtMs
        self.lastSeenMs = lastSeenMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        memberId = c.decodePresent(String.self, forKey: .memberId)
        userId = c.decodePresent(String.self, forKey: .userId)
        displayName = c.decodePresent(String.self, forKey: .displayName)
        avatarUrl = try? c.decodeIfPresent(String.self, forKey: .avatarUrl)
        isHost = c.decodePresent(Bool.self, forKey: .isHost)
        connected = c.decodePresent(Bool.self, forKey: .connected)
        joinedAtMs = c.decodePresent(Int64.self, forKey: .joinedAtMs)
        lastSeenMs = c.decodePresent(Int64.self, forKey: .lastSeenMs)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(memberId, forKey: .memberId)
        try c.encode(userId, forKey: .userId)
        try c.encode(displayName, forKey: .displayName)
        try c.encodeIfPresent(avatarUrl, forKey: .avatarUrl)
        try c.encode(isHost, forKey: .isHost)
        try c.encode(connected, forKey: .connected)
        try c.encode(joinedAtMs, forKey: .joinedAtMs)
        try c.encode(lastSeenMs, forKey: .lastSeenMs)
    }

    private enum CodingKeys: String, CodingKey {
        case memberId, userId, displayName, avatarUrl, isHost, connected, joinedAtMs, lastSeenMs
    }
}

// MARK: - PartyPlayback

/// Where the party is, as of a server timestamp.
///
/// `positionMs` is not a current position. It is the position at `anchorMs`, and it only
/// becomes a current position once the reader adds the time since — see
/// `PartySessionState.positionMs(serverNowMs:)`. That indirection is the entire sync
/// mechanism: a frame delayed by 300 ms carries an anchor 300 ms older and still lands
/// this device in exactly the right place.
/// (Ports `PartyPlayback` in `data/listentogether/PartyModels.kt`.)
public struct PartyPlayback: Codable, Hashable, Sendable {
    /// Bumped by the server on every change. A state whose `seq` is not greater than the one
    /// already applied is dropped unread — which is what makes two people hitting pause at the
    /// same moment settle rather than oscillate.
    public var seq: Int64
    public var track: PartyTrack?
    /// Bumped only when the queue's *contents* change, and deliberately the only thing about
    /// the queue that rides along with the state. The queue itself travels separately and
    /// rarely; a queue inside the heartbeat frame would be large, near-constant, and paid for
    /// continuously on somebody's mobile data.
    public var queueSeq: Int64
    public var queueLength: Int
    public var queueIndex: Int
    public var isPlaying: Bool
    public var positionMs: Int64
    public var anchorMs: Int64
    /// The server's own reading of `positionMs` at the instant it sent the frame.
    public var effectivePositionMs: Int64
    public var updatedBy: String?
    /// Member who selected this track; stable across pause, play, and seek controls.
    public var startedBy: String?
    /// Snapshot of their name so attribution survives that member leaving.
    public var startedByName: String?
    /// Party-wide setting so a connected listener can refill AutoPlay on host loss.
    public var autoplayEnabled: Bool
    public var updatedAtMs: Int64

    public init(
        seq: Int64 = 0,
        track: PartyTrack? = nil,
        queueSeq: Int64 = 0,
        queueLength: Int = 0,
        queueIndex: Int = -1,
        isPlaying: Bool = false,
        positionMs: Int64 = 0,
        anchorMs: Int64 = 0,
        effectivePositionMs: Int64 = 0,
        updatedBy: String? = nil,
        startedBy: String? = nil,
        startedByName: String? = nil,
        autoplayEnabled: Bool = false,
        updatedAtMs: Int64 = 0
    ) {
        self.seq = seq
        self.track = track
        self.queueSeq = queueSeq
        self.queueLength = queueLength
        self.queueIndex = queueIndex
        self.isPlaying = isPlaying
        self.positionMs = positionMs
        self.anchorMs = anchorMs
        self.effectivePositionMs = effectivePositionMs
        self.updatedBy = updatedBy
        self.startedBy = startedBy
        self.startedByName = startedByName
        self.autoplayEnabled = autoplayEnabled
        self.updatedAtMs = updatedAtMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = c.decodePresent(Int64.self, forKey: .seq)
        track = try? c.decodeIfPresent(PartyTrack.self, forKey: .track)
        queueSeq = c.decodePresent(Int64.self, forKey: .queueSeq)
        queueLength = c.decodePresent(Int.self, forKey: .queueLength)
        queueIndex = (try? c.decodeIfPresent(Int.self, forKey: .queueIndex)) ?? -1
        isPlaying = c.decodePresent(Bool.self, forKey: .isPlaying)
        positionMs = c.decodePresent(Int64.self, forKey: .positionMs)
        anchorMs = c.decodePresent(Int64.self, forKey: .anchorMs)
        effectivePositionMs = c.decodePresent(Int64.self, forKey: .effectivePositionMs)
        updatedBy = try? c.decodeIfPresent(String.self, forKey: .updatedBy)
        startedBy = try? c.decodeIfPresent(String.self, forKey: .startedBy)
        startedByName = try? c.decodeIfPresent(String.self, forKey: .startedByName)
        autoplayEnabled = c.decodePresent(Bool.self, forKey: .autoplayEnabled)
        updatedAtMs = c.decodePresent(Int64.self, forKey: .updatedAtMs)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(seq, forKey: .seq)
        try c.encodeIfPresent(track, forKey: .track)
        try c.encode(queueSeq, forKey: .queueSeq)
        try c.encode(queueLength, forKey: .queueLength)
        try c.encode(queueIndex, forKey: .queueIndex)
        try c.encode(isPlaying, forKey: .isPlaying)
        try c.encode(positionMs, forKey: .positionMs)
        try c.encode(anchorMs, forKey: .anchorMs)
        try c.encode(effectivePositionMs, forKey: .effectivePositionMs)
        try c.encodeIfPresent(updatedBy, forKey: .updatedBy)
        try c.encodeIfPresent(startedBy, forKey: .startedBy)
        try c.encodeIfPresent(startedByName, forKey: .startedByName)
        try c.encode(autoplayEnabled, forKey: .autoplayEnabled)
        try c.encode(updatedAtMs, forKey: .updatedAtMs)
    }

    private enum CodingKeys: String, CodingKey {
        case seq, track, queueSeq, queueLength, queueIndex, isPlaying, positionMs, anchorMs,
             effectivePositionMs, updatedBy, startedBy, startedByName, autoplayEnabled, updatedAtMs
    }
}

// MARK: - PartyQueue

/// The party's running order, which travels on its own schedule: whole when a device joins,
/// and after that only when it actually changes. `seq` is how a device knows its copy is
/// stale — every state frame carries the server's current one.
/// (Ports `PartyQueue` in `data/listentogether/PartyModels.kt`.)
public struct PartyQueue: Codable, Hashable, Sendable {
    public var seq: Int64
    public var index: Int
    public var items: [PartyTrack]

    public init(seq: Int64 = 0, index: Int = -1, items: [PartyTrack] = []) {
        self.seq = seq
        self.index = index
        self.items = items
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = c.decodePresent(Int64.self, forKey: .seq)
        index = (try? c.decodeIfPresent(Int.self, forKey: .index)) ?? -1
        items = c.decodePresent([PartyTrack].self, forKey: .items)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(seq, forKey: .seq)
        try c.encode(index, forKey: .index)
        try c.encode(items, forKey: .items)
    }

    private enum CodingKeys: String, CodingKey { case seq, index, items }
}

// MARK: - PartySnapshot

/// (Ports `PartySnapshot` in `data/listentogether/PartyModels.kt`.)
public struct PartySnapshot: Codable, Hashable, Sendable {
    public var code: String
    public var createdAtMs: Int64
    public var maxMembers: Int
    /// Whether only the host may drive the music. Defaulted false so a party on a server
    /// that predates the setting reads as the shared free-for-all this feature shipped as.
    public var hostOnlyControl: Bool
    public var members: [PartyMember]
    public var playback: PartyPlayback
    public var queue: PartyQueue
    public var serverMs: Int64

    public init(
        code: String = "",
        createdAtMs: Int64 = 0,
        maxMembers: Int = 5,
        hostOnlyControl: Bool = false,
        members: [PartyMember] = [],
        playback: PartyPlayback = PartyPlayback(),
        queue: PartyQueue = PartyQueue(),
        serverMs: Int64 = 0
    ) {
        self.code = code
        self.createdAtMs = createdAtMs
        self.maxMembers = maxMembers
        self.hostOnlyControl = hostOnlyControl
        self.members = members
        self.playback = playback
        self.queue = queue
        self.serverMs = serverMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = c.decodePresent(String.self, forKey: .code)
        createdAtMs = c.decodePresent(Int64.self, forKey: .createdAtMs)
        maxMembers = (try? c.decodeIfPresent(Int.self, forKey: .maxMembers)) ?? 5
        hostOnlyControl = c.decodePresent(Bool.self, forKey: .hostOnlyControl)
        members = c.decodePresent([PartyMember].self, forKey: .members)
        playback = (try? c.decodeIfPresent(PartyPlayback.self, forKey: .playback)) ?? PartyPlayback()
        queue = (try? c.decodeIfPresent(PartyQueue.self, forKey: .queue)) ?? PartyQueue()
        serverMs = c.decodePresent(Int64.self, forKey: .serverMs)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(code, forKey: .code)
        try c.encode(createdAtMs, forKey: .createdAtMs)
        try c.encode(maxMembers, forKey: .maxMembers)
        try c.encode(hostOnlyControl, forKey: .hostOnlyControl)
        try c.encode(members, forKey: .members)
        try c.encode(playback, forKey: .playback)
        try c.encode(queue, forKey: .queue)
        try c.encode(serverMs, forKey: .serverMs)
    }

    private enum CodingKeys: String, CodingKey {
        case code, createdAtMs, maxMembers, hostOnlyControl, members, playback, queue, serverMs
    }
}

// MARK: - PartyPreview

/// Who is in a party, to somebody who has not joined it: enough to show a face and a name
/// before committing a device slot, and nothing that would let the holder of a code act on
/// a party they are not in.
/// (Ports `PartyPreview` / `PartyPreviewMember` in `data/listentogether/PartyModels.kt`.)
public struct PartyPreviewMember: Codable, Hashable, Sendable {
    public var displayName: String
    public var avatarUrl: String?
    public var isHost: Bool

    public init(displayName: String = "", avatarUrl: String? = nil, isHost: Bool = false) {
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.isHost = isHost
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayName = c.decodePresent(String.self, forKey: .displayName)
        avatarUrl = try? c.decodeIfPresent(String.self, forKey: .avatarUrl)
        isHost = c.decodePresent(Bool.self, forKey: .isHost)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(displayName, forKey: .displayName)
        try c.encodeIfPresent(avatarUrl, forKey: .avatarUrl)
        try c.encode(isHost, forKey: .isHost)
    }

    private enum CodingKeys: String, CodingKey { case displayName, avatarUrl, isHost }
}

public struct PartyPreview: Codable, Hashable, Sendable {
    public var code: String
    public var hostName: String
    public var memberCount: Int
    public var maxMembers: Int
    public var isFull: Bool
    public var members: [PartyPreviewMember]

    public init(
        code: String = "",
        hostName: String = "",
        memberCount: Int = 0,
        maxMembers: Int = 5,
        isFull: Bool = false,
        members: [PartyPreviewMember] = []
    ) {
        self.code = code
        self.hostName = hostName
        self.memberCount = memberCount
        self.maxMembers = maxMembers
        self.isFull = isFull
        self.members = members
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = c.decodePresent(String.self, forKey: .code)
        hostName = c.decodePresent(String.self, forKey: .hostName)
        memberCount = c.decodePresent(Int.self, forKey: .memberCount)
        maxMembers = (try? c.decodeIfPresent(Int.self, forKey: .maxMembers)) ?? 5
        isFull = c.decodePresent(Bool.self, forKey: .isFull)
        members = c.decodePresent([PartyPreviewMember].self, forKey: .members)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(code, forKey: .code)
        try c.encode(hostName, forKey: .hostName)
        try c.encode(memberCount, forKey: .memberCount)
        try c.encode(maxMembers, forKey: .maxMembers)
        try c.encode(isFull, forKey: .isFull)
        try c.encode(members, forKey: .members)
    }

    private enum CodingKeys: String, CodingKey {
        case code, hostName, memberCount, maxMembers, isFull, members
    }
}

// MARK: - PartyMembership

/// The answer to a create or a join: the code, and this device's key to it.
/// (Ports `PartyMembership` in `data/listentogether/PartyModels.kt`.)
public struct PartyMembership: Codable, Hashable, Sendable {
    public var code: String
    public var token: String
    public var you: PartyMember
    public var party: PartySnapshot
    public var serverMs: Int64

    public init(
        code: String,
        token: String,
        you: PartyMember,
        party: PartySnapshot,
        serverMs: Int64 = 0
    ) {
        self.code = code
        self.token = token
        self.you = you
        self.party = party
        self.serverMs = serverMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = c.decodePresent(String.self, forKey: .code)
        token = c.decodePresent(String.self, forKey: .token)
        you = (try? c.decodeIfPresent(PartyMember.self, forKey: .you)) ?? PartyMember(memberId: "")
        party = (try? c.decodeIfPresent(PartySnapshot.self, forKey: .party)) ?? PartySnapshot()
        serverMs = c.decodePresent(Int64.self, forKey: .serverMs)
    }

    private enum CodingKeys: String, CodingKey { case code, token, you, party, serverMs }
}

// MARK: - PartyActivity

/// A compact local-only record of a live party action.
/// (Ports `PartyActivity` in `data/listentogether/PartyModels.kt`.)
public struct PartyActivity: Codable, Hashable, Sendable {
    public var action: String
    public var by: String
    public var atMs: Int64
    public var detail: String

    public init(action: String, by: String, atMs: Int64, detail: String = "") {
        self.action = action
        self.by = by
        self.atMs = atMs
        self.detail = detail
    }
}

// MARK: - Join request / API error

/// The identity submitted when creating or joining a party (matches Go's `JoinRequest`).
public struct PartyJoinRequest: Codable, Hashable, Sendable {
    public var userId: String
    public var deviceId: String
    public var displayName: String
    public var avatarUrl: String?
    public var maxMembers: Int?
    public var autoplayEnabled: Bool?

    public init(
        userId: String,
        deviceId: String,
        displayName: String,
        avatarUrl: String? = nil,
        maxMembers: Int? = nil,
        autoplayEnabled: Bool? = nil
    ) {
        self.userId = userId
        self.deviceId = deviceId
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.maxMembers = maxMembers
        self.autoplayEnabled = autoplayEnabled
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(userId, forKey: .userId)
        try c.encode(deviceId, forKey: .deviceId)
        try c.encode(displayName, forKey: .displayName)
        try c.encodeIfPresent(avatarUrl, forKey: .avatarUrl)
        try c.encodeIfPresent(maxMembers, forKey: .maxMembers)
        try c.encodeIfPresent(autoplayEnabled, forKey: .autoplayEnabled)
    }

    private enum CodingKeys: String, CodingKey {
        case userId, deviceId, displayName, avatarUrl, maxMembers, autoplayEnabled
    }
}

/// A refusal from the server, carrying the machine-readable half.
public struct PartyApiError: Codable, Hashable, Sendable {
    public var code: String
    public var message: String

    public init(code: String = "", message: String = "") {
        self.code = code
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The server's field is `error`; accept `code` too for forward compatibility.
        let raw = ((try? c.decodeIfPresent(String.self, forKey: .error)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let alt = ((try? c.decodeIfPresent(String.self, forKey: .code)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        code = raw.isEmpty ? alt : raw
        message = (try? c.decodeIfPresent(String.self, forKey: .message)) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(code, forKey: .error)
        try c.encode(message, forKey: .message)
    }

    private enum CodingKeys: String, CodingKey { case error, code, message }
}
