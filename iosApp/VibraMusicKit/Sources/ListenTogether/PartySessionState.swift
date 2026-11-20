import Foundation

/// Who this device is jamming as. The app builds it from the signed-in account (real names
/// and faces in the member list); the server cannot verify the claim, but it mints the
/// token that makes acting on it possible. (Ports `ListenTogether.Identity`.)
public struct PartyIdentity: Hashable, Sendable, Codable {
    public var userId: String
    public var deviceId: String
    public var displayName: String
    public var avatarUrl: String?

    public init(userId: String, deviceId: String, displayName: String, avatarUrl: String? = nil) {
        self.userId = userId
        self.deviceId = deviceId
        self.displayName = displayName
        self.avatarUrl = avatarUrl
    }
}

/// Supplies the signed-in identity. The module defines this protocol and the app wires the
/// account store in — the package must not depend on the auth layer.
/// Returns nil when the device has no account it can jam as.
public protocol PartyIdentityProvider: Sendable {
    func partyIdentity() async -> PartyIdentity?
}

/// Socket liveness, as the screen draws it. (Ports `ListenTogether.Connection`.)
public enum PartyConnection: Hashable, Sendable {
    case offline, connecting, live
}

/// Everything the UI and the sync engine read: membership, the playhead's source of truth,
/// and the last thing that went wrong. (Ports `ListenTogether.State`.)
public struct PartySessionState: Hashable, Sendable {
    public var code: String?
    public var you: PartyMember?
    public var members: [PartyMember]
    public var maxMembers: Int
    /// See `controlsLocked`.
    public var hostOnlyControl: Bool
    public var playback: PartyPlayback
    /// Held separately from `playback` because it arrives separately: the state frame
    /// carries only a sequence number for it.
    public var queue: PartyQueue
    public var connection: PartyConnection
    /// False until the first round trip; the playhead is a guess until then.
    public var clockSynced: Bool
    public var roundTripMs: Int64
    /// The last thing that went wrong, for the screen to show.
    public var error: String?

    public init(
        code: String? = nil,
        you: PartyMember? = nil,
        members: [PartyMember] = [],
        maxMembers: Int = PartyLimits.defaultMaxMembers,
        hostOnlyControl: Bool = false,
        playback: PartyPlayback = PartyPlayback(),
        queue: PartyQueue = PartyQueue(),
        connection: PartyConnection = .offline,
        clockSynced: Bool = false,
        roundTripMs: Int64 = 0,
        error: String? = nil
    ) {
        self.code = code
        self.you = you
        self.members = members
        self.maxMembers = maxMembers
        self.hostOnlyControl = hostOnlyControl
        self.playback = playback
        self.queue = queue
        self.connection = connection
        self.clockSynced = clockSynced
        self.roundTripMs = roundTripMs
        self.error = error
    }

    public var inParty: Bool { code != nil }
    public var isFull: Bool { members.count >= maxMembers }

    /// Whether this device may not drive the music: true only for a listener in a party
    /// whose host has taken control of it. The host is never locked out of their own party,
    /// and a device that is not in one is not in this feature's business at all. The server
    /// enforces the same rule, so this is what the app shows rather than what makes it
    /// true; see `backend/party.MayControl`. Host is reassigned when a host leaves, so this
    /// can go false under a listener mid-party — everything reading it has to follow.
    public var controlsLocked: Bool {
        inParty && hostOnlyControl && you?.isHost != true
    }

    /// Where this device should be in the current track, right now — the one number the
    /// player layer needs. Null when there is no party, or nothing playing in it.
    ///
    /// Before the first pong lands there is no offset to convert with, and this falls back
    /// to the server's own reading at the moment it sent the frame — right to within the age
    /// of that frame, and wrong by exactly the amount the clock sync exists to remove. So it
    /// is a starting point, not a thing to seek to: wait for `clockSynced` before acting on it.
    public func positionMs(serverNowMs: Int64?) -> Int64? {
        guard let track = playback.track else { return nil }
        if !playback.isPlaying { return playback.positionMs }
        guard let serverNow = serverNowMs else { return playback.effectivePositionMs }
        let elapsed = max(0, serverNow - playback.anchorMs)
        let position = playback.positionMs + elapsed
        if let duration = track.durationMs { return min(position, duration) }
        return position
    }

    /// How far in the future the party's next resume is scheduled, or 0 if it is already
    /// under way. The player layer waits this out rather than starting early and seeking.
    public func msUntilStart(serverNowMs: Int64?) -> Int64 {
        guard playback.isPlaying, let serverNow = serverNowMs else { return 0 }
        return max(0, playback.anchorMs - serverNow)
    }
}
