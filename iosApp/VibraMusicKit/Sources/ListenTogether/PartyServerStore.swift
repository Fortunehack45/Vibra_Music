import VibraMusicCore
import Foundation

// MARK: - URL validation

/// Why a typed party-server address was refused. (Ports `ServerUrlError`.)
public enum PartyServerURLError: Hashable, Sendable {
    case whitespace
    case invalidScheme
    case invalidHost
    case invalidPort
    case invalidPath
    case hasQuery
    case hasFragment
    case malformed
}

public enum PartyServerURLValidation: Hashable, Sendable {
    case valid(normalizedUrl: String)
    case invalid(PartyServerURLError)
}

public struct PartyProbeResult: Hashable, Sendable {
    public var isOnline: Bool
    public var latencyMs: Int64

    public init(isOnline: Bool, latencyMs: Int64 = 0) {
        self.isOnline = isOnline
        self.latencyMs = latencyMs
    }
}

public enum PartyServerConnectionState: Hashable, Sendable {
    case checking
    case defaultOnline(latencyMs: Int64)
    case customOnline(latencyMs: Int64)
    case customFallback(latencyMs: Int64)
    case offline

    public var latencyMs: Int64? {
        switch self {
        case .defaultOnline(let ms), .customOnline(let ms), .customFallback(let ms): ms
        case .checking, .offline: nil
        }
    }

    public var isFallback: Bool {
        if case .customFallback = self { return true }
        return false
    }

    public var health: PartyServerHealth {
        switch self {
        case .checking: .checking
        case .defaultOnline, .customOnline, .customFallback: .online
        case .offline: .offline
        }
    }
}

public enum PartyServerHealth: Hashable, Sendable {
    case unknown, checking, online, offline
}

public struct PartyHealthResolution: Hashable, Sendable {
    public var resolvedServer: String
    public var health: PartyServerHealth
    public var isFallback: Bool

    public init(resolvedServer: String, health: PartyServerHealth, isFallback: Bool) {
        self.resolvedServer = resolvedServer
        self.health = health
        self.isFallback = isFallback
    }
}

public enum PartyServerConfig {
    /// Parses and normalizes a user-typed server address. Blank means "the build's default".
    /// (Ports `ListenTogether.parseAndNormalizeServerUrl`.)
    public static func parseAndNormalizeServerUrl(_ raw: String) -> PartyServerURLValidation {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .valid(normalizedUrl: "") }
        if trimmed.contains(where: \.isWhitespace) { return .invalid(.whitespace) }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased()
        else {
            return invalidHostOrPort(for: candidate)
        }
        guard scheme == "http" || scheme == "https" else { return .invalid(.invalidScheme) }
        if candidate.contains("?") { return .invalid(.hasQuery) }
        if candidate.contains("#") { return .invalid(.hasFragment) }

        // Escapes stay escaped, so the normalized address parses back to itself (decoded, a
        // `%20` became a space the next parse rejects).
        let segments = url.path(percentEncoded: true).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        // Checked decoded and split again, so an escaped slash can't hide one (`..%2Fbar`).
        let decodedSegments = segments.flatMap { ($0.removingPercentEncoding ?? $0).split(separator: "/") }
        for segment in decodedSegments where segment == "." || segment == ".." {
            return .invalid(.invalidPath)
        }
        let canonicalPath = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")

        let authority = candidate
            .components(separatedBy: "://").dropFirst().joined(separator: "://")
            .components(separatedBy: CharacterSet(charactersIn: "/?#"))[0]
        if let portStr = authority.split(separator: ":").last,
           authority.contains(":"),
           portStr.allSatisfy(\.isNumber), !portStr.isEmpty,
           let port = Int(portStr), !(1 ... 65_535).contains(port)
        {
            return .invalid(.invalidPort)
        }

        guard let rawHost = url.host, !rawHost.isEmpty else { return .invalid(.invalidHost) }
        let canonicalHost: String
        if rawHost.hasPrefix("[") && rawHost.hasSuffix("]") {
            let inner = String(rawHost.dropFirst().dropLast())
            guard inner.contains(":") else { return .invalid(.invalidHost) }
            canonicalHost = "[\(inner.lowercased())]"
        } else if rawHost.contains(":") {
            canonicalHost = "[\(rawHost.lowercased())]"
        } else if rawHost.compare("localhost", options: .caseInsensitive) == .orderedSame {
            canonicalHost = "localhost"
        } else {
            guard rawHost.count <= 253, !rawHost.hasPrefix("."), !rawHost.hasSuffix(".") else {
                return .invalid(.invalidHost)
            }
            let labels = rawHost.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard labels.count >= 2 else { return .invalid(.invalidHost) }
            for label in labels {
                guard !label.isEmpty, label.count <= 63,
                      label.first?.isLetterOrNumber == true, label.last?.isLetterOrNumber == true,
                      label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
                else { return .invalid(.invalidHost) }
            }
            canonicalHost = rawHost.lowercased()
        }

        let portSuffix: String
        if url.port != nil, let port = url.port, (1 ... 65_535).contains(port) {
            portSuffix = ":\(port)"
        } else {
            portSuffix = ""
        }
        return .valid(normalizedUrl: "\(scheme)://\(canonicalHost)\(portSuffix)\(canonicalPath)")
    }

    private static func invalidHostOrPort(for candidate: String) -> PartyServerURLValidation {
        let authority = candidate
            .components(separatedBy: "://").dropFirst().joined(separator: "://")
            .components(separatedBy: CharacterSet(charactersIn: "/?#"))[0]
        if authority.contains(":"),
           let portStr = authority.split(separator: ":").last.map(String.init),
           !portStr.isEmpty, portStr.allSatisfy(\.isNumber),
           let port = Int(portStr), !(1 ... 65_535).contains(port)
        {
            return .invalid(.invalidPort)
        }
        return .invalid(.invalidHost)
    }

    /// Pure probe-order policy, extracted so it is testable without a network: a healthy
    /// custom server wins without ever probing the default; a dead one falls back to the
    /// default; a custom equal to the default probes once. The persisted preference is
    /// never rewritten by a fallback — recovery regains priority on the next check.
    /// (Ports `ListenTogether.resolveServerConnection`.)
    public static func resolveServerConnection(
        customServer: String,
        defaultServer: String,
        probeCustom: () async -> PartyProbeResult,
        probeDefault: () async -> PartyProbeResult
    ) async -> (effective: String, state: PartyServerConnectionState) {
        let normCustom: String = {
            if case .valid(let url) = parseAndNormalizeServerUrl(customServer) { return url }
            return ""
        }()
        let hasCustom = !normCustom.isEmpty && normCustom != defaultServer
        if hasCustom {
            let custom = await probeCustom()
            if custom.isOnline {
                return (normCustom, .customOnline(latencyMs: custom.latencyMs))
            }
            let fallback = await probeDefault()
            if fallback.isOnline {
                // Invariant: CustomFallback latency is strictly the default server's latency.
                return (defaultServer, .customFallback(latencyMs: fallback.latencyMs))
            }
            return (defaultServer, .offline)
        }
        let probe = await probeDefault()
        if probe.isOnline {
            return (defaultServer, .defaultOnline(latencyMs: probe.latencyMs))
        }
        return (defaultServer, .offline)
    }

    /// Boolean twin of `resolveServerConnection` for the coarse health line.
    /// (Ports `ListenTogether.computeHealthResolution`.)
    public static func computeHealthResolution(
        customServer: String,
        defaultServer: String,
        probeCustom: () async -> Bool,
        probeDefault: () async -> Bool
    ) async -> PartyHealthResolution {
        let custom = normalizeServerBase(customServer)
        let hasCustom = !custom.isEmpty && custom != defaultServer
        if hasCustom {
            if await probeCustom() {
                return PartyHealthResolution(resolvedServer: custom, health: .online, isFallback: false)
            } else if await probeDefault() {
                return PartyHealthResolution(resolvedServer: defaultServer, health: .online, isFallback: true)
            } else {
                return PartyHealthResolution(resolvedServer: defaultServer, health: .offline, isFallback: false)
            }
        }
        if await probeDefault() {
            return PartyHealthResolution(resolvedServer: defaultServer, health: .online, isFallback: false)
        }
        return PartyHealthResolution(resolvedServer: defaultServer, health: .offline, isFallback: false)
    }

    /// The server a party switch should target when the invite itself does not name one.
    /// `customServer` is `""` when nobody configured one — not the default's address — so a
    /// switch with no explicit target (a typed code, entered while already live) falls back
    /// to whichever server idle joins resolve to instead of being refused as invalid.
    /// (Ports `ListenTogether.resolveSwitchTarget`.)
    public static func resolveSwitchTarget(
        inviteServer: String?,
        customServer: String,
        idleServer: String
    ) -> String {
        inviteServer ?? (customServer.isEmpty ? idleServer : customServer)
    }

    /// Whether a failure may be retried against the default server: transport outages and
    /// 5xx. Client/protocol/4xx errors must not fall back — joining the wrong server's
    /// "party full" is not a connection problem. (Ports `ListenTogether.isEligibleForFallback`.)
    public static func isEligibleForFallback(statusCode: Int?, transportError: Error? = nil) -> Bool {
        if let code = statusCode, (500 ... 599).contains(code) { return true }
        guard let error = transportError else { return false }
        let ns = error as NSError
        if ns.domain == (kCFErrorDomainCFNetwork as String) { return true }
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed,
                 NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut,
                 NSURLErrorInternationalRoamingOff, NSURLErrorCallIsActive,
                 NSURLErrorDataNotAllowed, NSURLErrorSecureConnectionFailed:
                return true
            default:
                break
            }
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error, (underlying as NSError) !== ns {
            return isEligibleForFallback(statusCode: nil, transportError: underlying)
        }
        return false
    }

    public static func normalizeServerBase(_ value: String) -> String {
        var out = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }

    /// A fully qualified HTTP base: blank resolves to the default, and a bare host gains `https://`.
    public static func resolveHttpBase(_ server: String, defaultServer: String) -> String {
        let raw = normalizeServerBase(server).isEmpty ? defaultServer : normalizeServerBase(server)
        if raw.isEmpty { return "" }
        let lower = raw.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return raw }
        return "https://\(raw)"
    }

    public static func wsBase(httpBase: String) -> String {
        var out = httpBase
        if out.lowercased().hasPrefix("https://") {
            out = "wss://" + out.dropFirst("https://".count)
        } else if out.lowercased().hasPrefix("http://") {
            out = "ws://" + out.dropFirst("http://".count)
        }
        return out
    }
}

// MARK: - Persistence

/// Party server configs live here — not in `AppSettings`, which holds only audio/playback/
/// appearance preferences on both platforms. (Ports the `SharedPreferences` half of
/// `ListenTogether`: server URL, nickname, device id, live membership token, kick ledger.)
public final class PartyServerStore: @unchecked Sendable {
    private struct Record: Codable {
        var customServer: String = ""
        var nickname: String = ""
        var deviceId: String?
        var partyCode: String?
        var partyToken: String?
        var kickedUntil: [String: Int64] = [:]
    }

    private let files: JSONFileStore
    private let fileName = "party-server.json"
    private let lock = NSLock()
    private var record: Record
    public let defaultServer: String
    private let wallNowMs: () -> Int64

    public init(
        files: JSONFileStore,
        defaultServer: String,
        wallNowMs: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    ) {
        self.files = files
        self.defaultServer = defaultServer
        self.wallNowMs = wallNowMs
        self.record = (try? files.load(Record.self, from: fileName)) ?? Record()
        // Normalize a saved address once, so an upgrade that tightens validation
        // cannot wedge the install on its own stored preference.
        if case .valid(let url) = PartyServerConfig.parseAndNormalizeServerUrl(record.customServer) {
            record.customServer = url
        } else {
            record.customServer = ""
        }
    }

    public static func standard(defaultServer: String) -> PartyServerStore {
        PartyServerStore(files: .applicationSupport("ListenTogether"), defaultServer: defaultServer)
    }

    public var customServer: String {
        lock.withLock { record.customServer }
    }

    public func setCustomServer(_ normalizedUrl: String) {
        lock.withLock {
            record.customServer = normalizedUrl
            saveLocked()
        }
    }

    public var nickname: String {
        lock.withLock { record.nickname }
    }

    public func setNickname(_ value: String) {
        lock.withLock {
            record.nickname = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            saveLocked()
        }
    }

    /// This install's identity to the party, independent of who is signed in: it has to
    /// survive sign-outs, account switches and process death (so a rejoin reclaims a slot
    /// instead of taking a sixth), and must not survive an uninstall.
    public var deviceId: String {
        lock.withLock {
            if let id = record.deviceId { return id }
            let id = UUID().uuidString
            record.deviceId = id
            saveLocked()
            return id
        }
    }

    public func saveMembership(code: String, token: String) {
        lock.withLock {
            record.partyCode = code
            record.partyToken = token
            saveLocked()
        }
    }

    public func clearMembership() {
        lock.withLock {
            record.partyCode = nil
            record.partyToken = nil
            saveLocked()
        }
    }

    public func savedMembership() -> (code: String, token: String)? {
        lock.withLock {
            guard let code = record.partyCode, !code.isEmpty,
                  let token = record.partyToken, !token.isEmpty
            else { return nil }
            return (code, token)
        }
    }

    /// Parties this device was removed from, as code → lapse epoch ms, pruned on every read.
    /// Held here rather than on the server, which forgets a party minutes after it empties.
    public func recentKicks() -> [String: Int64] {
        lock.withLock {
            let now = wallNowMs()
            let live = record.kickedUntil.filter { $0.value > now }
            if live.count != record.kickedUntil.count {
                record.kickedUntil = live
                saveLocked()
            }
            return live
        }
    }

    public func recordKick(code: String) {
        let normalized = PartyCode.normalize(code)
        guard !normalized.isEmpty else { return }
        lock.withLock {
            // Read without re-locking: NSLock is not re-entrant.
            let now = wallNowMs()
            let live = record.kickedUntil.filter { $0.value > now }
            record.kickedUntil = live.merging(
                [normalized: now + PartyLimits.kickBlockMs], uniquingKeysWith: { _, new in new })
            saveLocked()
        }
    }

    public func isKickedOut(of code: String) -> Bool {
        recentKicks()[PartyCode.normalize(code)] != nil
    }

    private func saveLocked() {
        try? files.save(record, to: fileName)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
