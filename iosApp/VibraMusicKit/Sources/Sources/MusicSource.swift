import Foundation
import VibraMusicCore

// Ports data/sources/MusicSource.kt (the source interface and SourceHealth) and SourceConfig from
// data/sources/SourceRegistry.kt. StreamFormat, StreamRequest and SourceKind live in Core; a
// source's answer is Core's ResolvedStream (Android's SourceStream).

/// One configured source: which protocol, which server.
///
/// `baseUrl` can carry a user's private token in its path (an addon URL), which is why the registry
/// keeps these out of `UserDefaults` and out of iCloud backups — see ``SourceConfigStore``.
public struct SourceConfig: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: SourceKind
    /// What the user called it. Blank falls back to the server's host, or the kind's own label.
    public var label: String
    public var baseUrl: String
    /// JioSaavn is opt-in because catalogue matches can select the wrong recording.
    public var enabled: Bool

    public init(
        id: String = UUID().uuidString.lowercased(),
        kind: SourceKind,
        label: String = "",
        baseUrl: String = "",
        enabled: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.baseUrl = baseUrl
        self.enabled = enabled ?? (kind != .jioSaavn)
    }

    /// What the Sources screen and the player show. Never blank.
    public var displayName: String {
        if let label = label.nonBlank { return label }
        if baseUrl.nonBlank != nil, let host = URL(string: baseUrl.trimmingCharacters(in: .whitespaces))?.host(),
           !host.isEmpty {
            return host
        }
        return kind.label
    }

    /// Whether this has enough filled in to be worth contacting at all.
    public var isComplete: Bool {
        !kind.needsServer || baseUrl.nonBlank != nil
    }

    private enum CodingKeys: String, CodingKey { case id, kind, label, baseUrl, enabled }

    /// Android's `SourceConfig` defaults, so a stored entry missing a field still loads. A kind this
    /// build doesn't know is a decode failure; ``SourceConfigStore`` drops that one entry only.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(SourceKind.self, forKey: .kind)
        self.init(
            id: try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased(),
            kind: kind,
            label: try c.decodeIfPresent(String.self, forKey: .label) ?? "",
            baseUrl: try c.decodeIfPresent(String.self, forKey: .baseUrl) ?? "",
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled)
        )
    }
}

/// Whether a source is reachable and usable, asked before it is trusted with a track.
///
/// The distinction between ``unreachable(_:)`` and ``rejected(_:)`` is the point: a server that is
/// down is worth retrying and worth leaving enabled; one that refused the URL or credentials is
/// neither. A Sources screen that renders them alike sends people to re-type a URL that was never
/// wrong.
public enum SourceHealth: Hashable, Sendable {
    case ok(detail: String? = nil)
    case unreachable(String)
    case rejected(String)

    public var isOk: Bool {
        if case .ok = self { return true }
        return false
    }

    /// The line a Sources row shows under the name.
    public var message: String? {
        switch self {
        case .ok(let detail): return detail
        case .unreachable(let reason), .rejected(let reason): return reason
        }
    }
}

/// One place tracks can come from.
///
/// Deliberately small: a source searches its own catalogue and turns one of its own track ids into
/// something openable. Home feeds, radio and related tracks stay with YouTube, the only source that
/// has them.
///
/// Implementations are built by ``SourceRegistry`` from a stored ``SourceConfig`` and are cheap to
/// build and safe to hold: nothing is opened until something is asked for. Every method may throw;
/// ``SourceResolver`` and the Sources screen treat a throw as "this one didn't work", never as a
/// crash.
public protocol MusicSource: AnyObject, Sendable {
    /// The configured instance this was built from — unique across the registry.
    var configId: String { get }
    var kind: SourceKind { get }
    /// What the user named it, falling back to the server's own hostname.
    var displayName: String { get }
    /// The config this instance was built from, so the registry can tell a real edit from a no-op
    /// and keep a warm instance across unrelated edits. Nil for sources built outside the registry.
    var config: SourceConfig? { get }

    /// Reachability and credentials, for the Sources screen and for skipping dead sources.
    func health() async -> SourceHealth

    /// Tracks matching `query`, as ``Song``s already tagged with this source's id (see
    /// ``SourceRegistry/trackKey(configId:trackId:)``) so playing one comes back here.
    ///
    /// - Parameters:
    ///   - waitForAll: whether every backend this source fans out to is worth waiting for. False
    ///     while someone stares at a paused player; true for the background pass during playback,
    ///     which can afford the slow catalogue that turns out to hold the FLAC.
    ///   - tier: the stream this search is on behalf of. A catalogue that describes rows per tier
    ///     answers a different question at each one. Nil is the search box: the best the catalogue
    ///     has is exactly what should be shown.
    func search(_ query: String, limit: Int, waitForAll: Bool, tier: StreamRequest.Tier?) async throws -> [Song]

    /// An openable stream for one of this source's own track ids, or nil when this source turns
    /// out not to have it after all — a miss, not an error.
    func stream(trackId: String, tier: StreamRequest.Tier) async throws -> ResolvedStream?

    /// Drops everything cached about the server this used to point at (edited or removed).
    func release()

    /// Makes the next completed track lookups real requests again, for an explicit "Upgrade quality".
    func clearCompletedTrackCalls() async
}

extension MusicSource {
    public var config: SourceConfig? { nil }
    public func release() {}
    public func clearCompletedTrackCalls() async {}

    public func search(_ query: String, limit: Int = 25) async throws -> [Song] {
        try await search(query, limit: limit, waitForAll: false, tier: nil)
    }
}

extension SourceKind {
    /// Which ``StreamOrigin`` a stream from this kind of source reports.
    var streamOrigin: StreamOrigin {
        switch self {
        case .addon: return .addon
        case .customModule, .module: return .module
        case .jioSaavn: return .jioSaavn
        case .youtube: return .youtube
        }
    }
}

enum SourcesLog {
    static let category = "Sources"
    static func d(_ message: String) { TrackLog.d(category, message) }
    static func w(_ message: String, error: Error? = nil) { TrackLog.w(category, message, error: error) }
    static func e(_ message: String, error: Error? = nil) { TrackLog.e(category, message, error: error) }
}
