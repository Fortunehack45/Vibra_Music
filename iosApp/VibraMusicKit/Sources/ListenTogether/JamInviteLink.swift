import Foundation
import Observation

/// A parsed party invite: the code, plus the server it names when it names one.
/// (Ports `ParsedJamInvite` in `data/listentogether/JamInviteLink.kt`.)
public struct ParsedPartyInvite: Hashable, Sendable {
    public var code: String
    public var serverUrl: String?

    public init(code: String, serverUrl: String? = nil) {
        self.code = code
        self.serverUrl = serverUrl
    }
}

/// Reads and builds party invite links.
///
/// Two shapes, matching Android byte-for-byte so an invite made on one platform opens
/// on the other:
/// 1. `vibramusic://party/<CODE>?server=<SERVER>`
/// 2. `https://vibramusic.kushagrasingh.in/invite/<CODE>?server=<SERVER>`
/// (Ports `JamInviteLink` in `data/listentogether/JamInviteLink.kt`. The Android
/// `consume(Intent)` entry point is `PartyInviteInbox/consume(url:)` here — iOS delivers
/// deep links as `URL`, not intents.)
public enum JamInviteLink {
    public static let origin = "https://vibramusic.kushagrasingh.in"

    private static let host = "vibramusic.kushagrasingh.in"
    private static let customScheme = "vibramusic"
    private static let customHost = "party"

    /// Returns the normalized party code only for the public invite URL shape.
    public static func parse(_ value: String?) -> String? {
        parseInvite(value)?.code
    }

    public static func parseInvite(_ value: String?) -> ParsedPartyInvite? {
        guard let value, let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased()
        else { return nil }
        let server = queryParam(url, "server").flatMap(sanitizeServerUrl)

        // 1. Custom scheme: vibramusic://party/<CODE> or vibramusic://party?code=<CODE>
        if scheme == customScheme && host == customHost {
            let pathPart = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .nilIfEmpty
            let candidate = pathPart ?? queryParam(url, "code") ?? ""
            guard let code = PartyCode.cleanInviteCode(candidate) else { return nil }
            return ParsedPartyInvite(code: code, serverUrl: server)
        }

        // 2. Official web domain: https://vibramusic.kushagrasingh.in/invite/<CODE>
        // Matched entire against the raw string, like the Kotlin regex: Foundation's
        // `URL.path` normalizes a trailing slash away, so the raw path is what decides
        // whether "/invite/ABC123/" or "/invite/ABC123/extra" is an invite (it is not).
        if scheme == "https" && host == Self.host {
            guard let path = Self.rawPath(of: value),
                  path.count == "/invite/".count + PartyLimits.codeLength,
                  path.hasPrefix("/invite/"),
                  let code = PartyCode.cleanInviteCode(String(path.suffix(PartyLimits.codeLength)))
            else { return nil }
            return ParsedPartyInvite(code: code, serverUrl: server)
        }

        return nil
    }

    public static func url(code: String, customServer: String? = nil) -> String {
        let base = customServer?.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let base, !base.isEmpty, base.caseInsensitiveCompare(origin) != .orderedSame {
            return "\(base)/invite/\(code.uppercased())"
        }
        return "\(origin)/invite/\(code.uppercased())"
    }

    public static func schemeUrl(code: String, customServer: String? = nil) -> String {
        let normalized = code.uppercased()
        let base = customServer?.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let base, !base.isEmpty {
            // Form-encoding, like Kotlin's URLEncoder: every reserved character goes,
            // so the server parameter survives as one query value.
            let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            let encoded = base.addingPercentEncoding(withAllowedCharacters: unreserved) ?? base
            return "vibramusic://party/\(normalized)?server=\(encoded)"
        }
        return "vibramusic://party/\(normalized)"
    }

    // MARK: - Internals

    /// The path exactly as written, before `URL` normalizes it: query and fragment cut,
    /// nothing else touched.
    static func rawPath(of value: String) -> String? {
        guard let schemeRange = value.range(of: "://") else { return nil }
        let afterScheme = value[schemeRange.upperBound...]
        guard let slash = afterScheme.firstIndex(of: "/") else { return nil }
        var path = String(afterScheme[slash...])
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        if let fragment = path.firstIndex(of: "#") { path = String(path[..<fragment]) }
        return path
    }

    static func queryParam(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame })?
            .value
    }

    /// Adds `https://` when no scheme is present and refuses anything without a host.
    static func sanitizeServerUrl(_ raw: String?) -> String? {
        guard var trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            trimmed = "https://\(trimmed)"
        }
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else { return nil }
        return trimmed
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Relays a party invite from the app's deep-link entry point to the UI.
///
/// The Android original is a `StateFlow` fed from `MainActivity`; here the app calls
/// `consume(url:)` from its `onOpenURL` handler and the Listen Together screen observes
/// `pending`. (PORTING.md §4: a `vibramusic://` scheme plus Universal Links replace intent
/// filters; see also open question Q13.)
@MainActor
@Observable
public final class PartyInviteInbox {
    public var pending: ParsedPartyInvite?

    public init() {}

    /// Records an incoming invite URL. Returns whether it was a party invite.
    @discardableResult
    public func consume(url: URL) -> Bool {
        guard let invite = JamInviteLink.parseInvite(url.absoluteString) else { return false }
        pending = invite
        return true
    }

    public func handled() {
        pending = nil
    }
}
