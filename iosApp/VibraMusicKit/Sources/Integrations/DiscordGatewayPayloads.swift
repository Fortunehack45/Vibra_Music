import Foundation

/// Gateway opcodes (ports `OpCode.kt`). Unknown opcodes decode as `.unknown`
/// rather than throwing: Discord's user gateway carries opcodes this app has
/// no interest in and the set grows over time, so refusing one would drop the
/// connection until the app is updated.
public enum DiscordOpCode: Hashable, Sendable {
    case dispatch
    case heartbeat
    case identify
    case presenceUpdate
    case voiceState
    case resume
    case reconnect
    case requestGuildMembers
    case invalidSession
    case hello
    case heartbeatAck
    case unknown(Int)

    public init(rawValue: Int) {
        switch rawValue {
        case 0: self = .dispatch
        case 1: self = .heartbeat
        case 2: self = .identify
        case 3: self = .presenceUpdate
        case 4: self = .voiceState
        case 6: self = .resume
        case 7: self = .reconnect
        case 8: self = .requestGuildMembers
        case 9: self = .invalidSession
        case 10: self = .hello
        case 11: self = .heartbeatAck
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: Int {
        switch self {
        case .dispatch: return 0
        case .heartbeat: return 1
        case .identify: return 2
        case .presenceUpdate: return 3
        case .voiceState: return 4
        case .resume: return 6
        case .reconnect: return 7
        case .requestGuildMembers: return 8
        case .invalidSession: return 9
        case .hello: return 10
        case .heartbeatAck: return 11
        case .unknown(let value): return value
        }
    }
}

extension DiscordOpCode: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(Int.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A JSON value of any shape, for the gateway envelope's polymorphic `d`.
public enum DiscordJSON: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([DiscordJSON])
    case object([String: DiscordJSON])

    /// The sequence number for heartbeats: `"null"` when nothing seen yet.
    public var heartbeatDescription: String {
        if case .int(let value) = self { return String(value) }
        return "null"
    }
}

extension DiscordJSON: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int.self) { self = .int(value); return }
        if let value = try? container.decode(Double.self) { self = .double(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([DiscordJSON].self) { self = .array(value); return }
        self = .object(try container.decode([String: DiscordJSON].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// The gateway envelope (ports `Payload.kt`).
public struct DiscordGatewayPayload: Hashable, Sendable, Codable {
    public var t: String?
    public var s: Int?
    public var op: DiscordOpCode?
    public var d: DiscordJSON?

    public init(t: String? = nil, s: Int? = nil, op: DiscordOpCode? = nil, d: DiscordJSON? = nil) {
        self.t = t
        self.s = s
        self.op = op
        self.d = d
    }
}

extension DiscordGatewayPayload {
    static let coder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public static func decode(_ text: String) throws -> DiscordGatewayPayload {
        try coder.decode(DiscordGatewayPayload.self, from: Data(text.utf8))
    }

    public func encode() throws -> String {
        String(data: try Self.encoder.encode(self), encoding: .utf8) ?? ""
    }
}

/// `HELLO` data: the heartbeat interval to use.
public struct DiscordHello: Hashable, Sendable, Codable {
    public var heartbeatInterval: Int64
    public init(heartbeatInterval: Int64) { self.heartbeatInterval = heartbeatInterval }

    enum CodingKeys: String, CodingKey { case heartbeatInterval = "heartbeat_interval" }

    public static func interval(from payload: DiscordGatewayPayload) -> Int64? {
        guard let data = try? DiscordGatewayPayload.encoder.encode(payload.d),
              let hello = try? JSONDecoder().decode(DiscordHello.self, from: data)
        else { return nil }
        return hello.heartbeatInterval
    }
}

/// Presence timestamps: absolute instants Discord counts down on its own clock.
public struct DiscordTimestamps: Hashable, Sendable, Codable {
    public var start: Int64?
    public var end: Int64?
    public init(start: Int64? = nil, end: Int64? = nil) {
        self.start = start
        self.end = end
    }
}

/// Artwork + text on the presence card.
public struct DiscordAssets: Hashable, Sendable, Codable {
    public var largeImage: String?
    public var smallImage: String?
    public var largeText: String?
    public var smallText: String?

    public init(largeImage: String? = nil, smallImage: String? = nil, largeText: String? = nil, smallText: String? = nil) {
        self.largeImage = largeImage
        self.smallImage = smallImage
        self.largeText = largeText
        self.smallText = smallText
    }

    enum CodingKeys: String, CodingKey {
        case largeImage = "large_image"
        case smallImage = "small_image"
        case largeText = "large_text"
        case smallText = "small_text"
    }
}

/// Button URLs carried alongside button labels.
public struct DiscordActivityMetadata: Hashable, Sendable, Codable {
    public var buttonUrls: [String?]?
    public init(buttonUrls: [String?]? = nil) { self.buttonUrls = buttonUrls }

    enum CodingKeys: String, CodingKey { case buttonUrls = "button_urls" }
}

/// One rich-presence activity (ports `Activity.kt`).
public struct DiscordActivity: Hashable, Sendable, Codable {
    public var name: String?
    public var state: String?
    public var stateUrl: String?
    public var details: String?
    public var detailsUrl: String?
    public var type: Int?
    public var statusDisplayType: Int?
    public var timestamps: DiscordTimestamps?
    public var assets: DiscordAssets?
    public var buttons: [String?]?
    public var metadata: DiscordActivityMetadata?
    public var applicationId: String?
    public var url: String?

    public init(
        name: String? = nil,
        state: String? = nil,
        stateUrl: String? = nil,
        details: String? = nil,
        detailsUrl: String? = nil,
        type: Int? = 0,
        statusDisplayType: Int? = 0,
        timestamps: DiscordTimestamps? = nil,
        assets: DiscordAssets? = nil,
        buttons: [String?]? = nil,
        metadata: DiscordActivityMetadata? = nil,
        applicationId: String? = nil,
        url: String? = nil
    ) {
        self.name = name
        self.state = state
        self.stateUrl = stateUrl
        self.details = details
        self.detailsUrl = detailsUrl
        self.type = type
        self.statusDisplayType = statusDisplayType
        self.timestamps = timestamps
        self.assets = assets
        self.buttons = buttons
        self.metadata = metadata
        self.applicationId = applicationId
        self.url = url
    }

    enum CodingKeys: String, CodingKey {
        case name, state
        case stateUrl = "state_url"
        case details
        case detailsUrl = "details_url"
        case type
        case statusDisplayType = "status_display_type"
        case timestamps, assets, buttons, metadata
        case applicationId = "application_id"
        case url
    }
}

/// Presence update body for op 3 (ports `Presence.kt`).
public struct DiscordPresence: Hashable, Sendable, Codable {
    public var activities: [DiscordActivity?]?
    public var afk: Bool?
    public var since: Int64?
    public var status: String?

    public init(activities: [DiscordActivity?]? = nil, afk: Bool? = true, since: Int64? = 0, status: String? = "online") {
        self.activities = activities
        self.afk = afk
        self.since = since
        self.status = status
    }
}

/// Activity type for `setActivity` (ports `KizzyRPC.Type`).
public enum DiscordActivityType: Int, Hashable, Sendable {
    case playing = 0
    case streaming = 1
    case listening = 2
    case watching = 3
    case competing = 5

    public init(name: String) {
        switch name {
        case "playing": self = .playing
        case "watching": self = .watching
        case "competing": self = .competing
        default: self = .listening
        }
    }
}

/// Where the activity name renders (ports `KizzyRPC.StatusDisplayType`).
public enum DiscordStatusDisplayType: Int, Hashable, Sendable {
    case name = 0
    case state = 1
    case details = 2
}

/// `READY` data (ports `Ready.kt`).
public struct DiscordReady: Hashable, Sendable, Codable {
    public var resumeGatewayUrl: String?
    public var sessionId: String?
    public init(resumeGatewayUrl: String? = nil, sessionId: String? = nil) {
        self.resumeGatewayUrl = resumeGatewayUrl
        self.sessionId = sessionId
    }

    enum CodingKeys: String, CodingKey {
        case resumeGatewayUrl = "resume_gateway_url"
        case sessionId = "session_id"
    }
}

/// `RESUME` data (ports `Resume.kt`).
public struct DiscordResume: Hashable, Sendable, Codable {
    public var seq: Int
    public var sessionId: String?
    public var token: String
    public init(seq: Int, sessionId: String?, token: String) {
        self.seq = seq
        self.sessionId = sessionId
        self.token = token
    }

    enum CodingKeys: String, CodingKey {
        case seq
        case sessionId = "session_id"
        case token
    }
}

/// Identify properties (ports `Properties` in `Identify.kt`).
public struct DiscordIdentifyProperties: Hashable, Sendable, Codable {
    public var browser: String
    public var device: String
    public var os: String
    public init(os: String, browser: String, device: String) {
        self.os = os
        self.browser = browser
        self.device = device
    }
}

/// Identify client state (ports `ClientState` in `Identify.kt`).
public struct DiscordClientState: Hashable, Sendable, Codable {
    public var guildVersions: [String: String]
    public var highestLastMessageId: String
    public var readStateVersion: Int
    public var userGuildSettingsVersion: Int
    public var userSettingsVersion: Int
    public var privateChannelsVersion: String
    public var apiCodeVersion: Int

    public init() {
        guildVersions = [:]
        highestLastMessageId = "0"
        readStateVersion = 0
        userGuildSettingsVersion = -1
        userSettingsVersion = -1
        privateChannelsVersion = "0"
        apiCodeVersion = 0
    }

    enum CodingKeys: String, CodingKey {
        case guildVersions = "guild_versions"
        case highestLastMessageId = "highest_last_message_id"
        case readStateVersion = "read_state_version"
        case userGuildSettingsVersion = "user_guild_settings_version"
        case userSettingsVersion = "user_settings_version"
        case privateChannelsVersion = "private_channels_version"
        case apiCodeVersion = "api_code_version"
    }
}

/// Identify data for op 2 (ports `Identify.kt`).
public struct DiscordIdentify: Hashable, Sendable, Codable {
    public var capabilities: Int
    public var compress: Bool
    public var largeThreshold: Int
    public var properties: DiscordIdentifyProperties
    public var clientState: DiscordClientState
    public var presence: DiscordPresence?
    public var shard: [Int]
    public var token: String

    public init(token: String, os: String, browser: String, device: String) {
        capabilities = 16_381
        compress = false
        largeThreshold = 100
        properties = DiscordIdentifyProperties(os: os, browser: browser, device: device)
        clientState = DiscordClientState()
        presence = DiscordPresence(activities: [], afk: false, since: 0, status: "online")
        shard = [0, 1]
        self.token = token
    }

    enum CodingKeys: String, CodingKey {
        case capabilities, compress
        case largeThreshold = "largeThreshold"
        case properties
        case clientState = "client_state"
        case presence, shard, token
    }
}

// MARK: - Frame builders (used by the socket and asserted by tests)

public enum DiscordGatewayFrames {
    public static func identify(token: String, os: String, browser: String, device: String) throws -> String {
        let identify = DiscordIdentify(token: token, os: os, browser: browser, device: device)
        let data = try DiscordGatewayPayload.encoder.encode(identify)
        let json = try JSONSerialization.jsonObject(with: data)
        let payload = DiscordGatewayPayload(op: .identify, d: discordJSON(json))
        return try payload.encode()
    }

    public static func resume(seq: Int, sessionId: String?, token: String) throws -> String {
        let resume = DiscordResume(seq: seq, sessionId: sessionId, token: token)
        let data = try DiscordGatewayPayload.encoder.encode(resume)
        let json = try JSONSerialization.jsonObject(with: data)
        let payload = DiscordGatewayPayload(op: .resume, d: discordJSON(json))
        return try payload.encode()
    }

    public static func heartbeat(sequence: Int) -> String {
        let d: DiscordJSON = sequence == 0 ? .null : .int(sequence)
        let payload = DiscordGatewayPayload(op: .heartbeat, d: d)
        return (try? payload.encode()) ?? "{\"op\":1,\"d\":null}"
    }

    public static func presenceUpdate(_ presence: DiscordPresence) throws -> String {
        let data = try DiscordGatewayPayload.encoder.encode(presence)
        let json = try JSONSerialization.jsonObject(with: data)
        let payload = DiscordGatewayPayload(op: .presenceUpdate, d: discordJSON(json))
        return try payload.encode()
    }

    static func discordJSON(_ value: Any) -> DiscordJSON? {
        switch value {
        case is NSNull: return .null
        case let number as NSNumber:
            // NSNumber boxes bools as well; distinguish via objCType.
            if String(cString: number.objCType) == "c" {
                return .bool(number.boolValue)
            }
            let double = number.doubleValue
            if double.truncatingRemainder(dividingBy: 1) == 0, let int = Int(exactly: double) {
                return .int(int)
            }
            return .double(double)
        case let string as String: return .string(string)
        case let array as [Any]: return .array(array.compactMap { discordJSON($0) })
        case let object as [String: Any]:
            var out: [String: DiscordJSON] = [:]
            for (key, val) in object { out[key] = discordJSON(val) ?? .null }
            return .object(out)
        default: return nil
        }
    }
}
