import Foundation
import CryptoKit
import VibraMusicCore

// Session-level vocabulary for InnerTubeClient: errors, SAPISIDHASH signing, the identity a request
// acts as, and the locale Innertube is asked in. Ports the matching parts of Innertube.kt.

/// Why an Innertube call failed, in terms a caller can act on.
public enum InnerTubeError: Error, Equatable, Sendable, LocalizedError {
    /// A write was attempted without a session; the caller has a sign-in prompt to show.
    case notSignedIn
    /// The server answered with a non-success status.
    case httpStatus(Int, endpoint: String)
    /// The body wasn't the JSON object Innertube always answers with.
    case invalidResponse(String)
    /// Innertube answered 200 but said no (an `error` object in the body, or an edit status other
    /// than `STATUS_SUCCEEDED`). A refused write still answers 200, which is why bodies are read.
    case refused(String)
    /// The call succeeded but what it was asked for isn't in the answer.
    case missingData(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in to YouTube Music to do that"
        case .httpStatus(let status, let endpoint): return "YouTube Music answered HTTP \(status) for \(endpoint)"
        case .invalidResponse(let detail): return "Unexpected response from YouTube Music: \(detail)"
        case .refused(let message): return message
        case .missingData(let message): return message
        }
    }

    /// 401 or 403: the session was rejected. Context cookies can rotate while the app is alive, so
    /// the repository refreshes the session scope once and retries (never loops, never signs out).
    public var isAuthRejection: Bool {
        if case .httpStatus(let status, _) = self { return status == 401 || status == 403 }
        return false
    }
}

/// Who the session cookie actually acts as, and which client version it acts with — read out of the
/// signed-in music.youtube.com shell (or adopted from the page the listener was looking at).
///
/// A cookie is not an account. One Google login carries every account the browser has signed into,
/// plus every brand channel hanging off them, and nothing in the cookie says which one is meant.
/// The web client resolves that from its page config and says so on every request; a client that
/// skips this step is making a request about the first account in the jar, whoever that is — which
/// is how a listener with a brand channel had every play credited to the wrong identity.
struct InnerTubeSessionScope: Hashable, Sendable {
    /// `context.user.onBehalfOfUser`. Only ever taken from a shell that reported itself signed in:
    /// Google answers an `onBehalfOfUser` it can't tie to the session with 401 on every request.
    var dataSyncId: String?
    /// The brand channel, as `X-Goog-PageId`. Absent for a plain personal account.
    var pageId: String?
    /// Which entry in the cookie jar, as `X-Goog-AuthUser`.
    var authUser: String
    /// The live WEB_REMIX version, when the shell said.
    var clientVersion: String?
}

/// A channel the listener picked, standing in for the shell's default.
struct InnerTubeChannelSelection: Hashable, Sendable {
    var pageId: String?
    var dataSyncId: String?
    /// Which Google account in the jar the channel belongs to. Nil leaves the shell's answer alone —
    /// a brand channel sits under the account that owns it, so this only differs when the listener
    /// switched to a channel of a *different* signed-in Google account.
    var authUser: String?
}

/// Everything another module needs to make a request *as* the current listener — the stream
/// resolver's `player` calls and its play-history pings above all. Android shared one process-wide
/// `Innertube` object for this; here the app reads ``InnerTubeClient/requestIdentity(origin:)`` and
/// hands the fields to StreamResolution's `StreamAuthSession`:
///
/// ```swift
/// let id = await client.requestIdentity()
/// guard let cookie = id.cookie else { return nil }
/// return StreamAuthSession(cookie: cookie, authUser: id.authUser, pageId: id.pageId,
///                          dataSyncId: id.onBehalfOfUser,
///                          visitorData: id.visitorDataIsSessionBound ? id.visitorData : nil,
///                          webRemixClientVersion: id.liveClientVersion)
/// ```
///
/// Only a session-bound visitor id is handed over: `StreamAuthSession.visitorData` outranks the
/// resolver's own anonymous id, and an anonymous one minted here is no better than that.
public struct InnerTubeRequestIdentity: Hashable, Sendable {
    /// `Cookie`, `Authorization` (SAPISIDHASH for the requested origin, computed now), `X-Goog-AuthUser`
    /// and, for a brand channel, `X-Goog-PageId`. Empty when signed out.
    public var headers: [String: String]
    /// The session cookie; nil when signed out.
    public var cookie: String?
    /// Which account in the cookie jar (`X-Goog-AuthUser`); `"0"` when nothing says otherwise.
    public var authUser: String
    /// The brand channel requests act as (`X-Goog-PageId`); nil for a personal channel or signed out.
    public var pageId: String?
    /// `context.user.onBehalfOfUser`, when the session is scoped to a known identity.
    public var onBehalfOfUser: String?
    /// The session's visitor id (`context.client.visitorData` / `X-Goog-Visitor-Id`).
    public var visitorData: String?
    /// Whether ``visitorData`` came from the signed-in page or shell (bound to this session) rather
    /// than being minted anonymously.
    public var visitorDataIsSessionBound: Bool
    /// `hl`.
    public var language: String
    /// `gl`.
    public var region: String
    /// The WEB_REMIX version this session claims (the live one when known, else the fallback).
    public var webRemixClientVersion: String
    /// The WEB_REMIX version read from the live music.youtube.com shell or page; nil until one was.
    public var liveClientVersion: String?

    public var isSignedIn: Bool { cookie != nil }

    public init(
        headers: [String: String],
        cookie: String? = nil,
        authUser: String = "0",
        pageId: String? = nil,
        onBehalfOfUser: String?,
        visitorData: String?,
        visitorDataIsSessionBound: Bool = false,
        language: String,
        region: String,
        webRemixClientVersion: String,
        liveClientVersion: String? = nil
    ) {
        self.headers = headers
        self.cookie = cookie
        self.authUser = authUser
        self.pageId = pageId
        self.onBehalfOfUser = onBehalfOfUser
        self.visitorData = visitorData
        self.visitorDataIsSessionBound = visitorDataIsSessionBound
        self.language = language
        self.region = region
        self.webRemixClientVersion = webRemixClientVersion
        self.liveClientVersion = liveClientVersion
    }
}

/// The stats endpoints a player response nominates for one playback.
public struct InnerTubePlaybackTracking: Hashable, Sendable {
    public var playbackUrl: String
    public var watchtimeUrl: String?
    /// The ad-tracking ping real clients fire a few seconds in.
    public var atrUrl: String?
    /// How far in `atrUrl` is due, per the response's own schedule.
    public var atrAfterSeconds: Int64

    public init(playbackUrl: String, watchtimeUrl: String?, atrUrl: String?, atrAfterSeconds: Int64) {
        self.playbackUrl = playbackUrl
        self.watchtimeUrl = watchtimeUrl
        self.atrUrl = atrUrl
        self.atrAfterSeconds = atrAfterSeconds
    }
}

/// Google's API-signing scheme for cookie sessions, and the cookie that feeds it.
public enum SAPISIDAuth {
    /// The API-signing secret out of a cookie header.
    ///
    /// Three names for one value, and all three have to be looked for. `SAPISID` is the one
    /// everybody documents, and it is also the one a cookie jar can be missing: on a
    /// third-party-cookie-partitioned or `__Host`-prefixed login Google sets only the `__Secure-`
    /// forms. Any of them signs a request. Not looking cost those users every write and every
    /// history ping, silently: the app believed it was signed in and sent no `Authorization`.
    ///
    /// Order matters: the plain form first because it is what Google's origin-scoped hash is
    /// documented against, then the third-party form, then the first-party one.
    public static func sapisid(fromCookieHeader cookieHeader: String) -> String? {
        var jar: [String: String] = [:]
        for entry in cookieHeader.split(separator: ";", omittingEmptySubsequences: false) {
            let text = String(entry)
            let name = text.substring(before: "=").trimmedText
            let value = text.substring(after: "=", missing: "").trimmedText
            if name.isEmpty || value.isEmpty { continue }
            jar[name] = value
        }
        return names.lazy.compactMap { jar[$0] }.first
    }

    /// Whether a cookie header carries a secret requests can be signed with (Android's
    /// `AuthStore.hasApiSid`).
    ///
    /// Matched on the cookie *name*, which reads as pedantry and is not. The old test was
    /// `contains("SAPISID")`, which `__Secure-3PAPISID` satisfies — and so does a value that merely
    /// mentions the text, or a name that ends in it.
    public static func hasSigningSecret(_ cookieHeader: String) -> Bool {
        cookieHeader.split(separator: ";", omittingEmptySubsequences: false).contains { entry in
            let text = String(entry)
            let name = text.substring(before: "=").trimmedText
            let value = text.substring(after: "=", missing: "").trimmedText
            return names.contains(name) && !value.isEmpty
        }
    }

    /// `SAPISIDHASH <ts>_<sha1("<ts> <sapisid> <origin>")>`.
    public static func authorization(sapisid: String, origin: String, timestamp: Int64) -> String {
        let digest = Insecure.SHA1.hash(data: Data("\(timestamp) \(sapisid) \(origin)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(timestamp)_\(hex)"
    }

    static let names = ["SAPISID", "__Secure-3PAPISID", "__Secure-1PAPISID"]
}

/// The language Innertube is asked in (`hl`), and the header that goes with it.
public enum InnerTubeLocale {
    /// The app's current language code, with Java's legacy ISO codes mapped to the ones Google
    /// expects (`iw`→`he`, `in`→`id`, `ji`→`yi`). iOS reports the per-app language chosen in
    /// Settings through `Locale.preferredLanguages`.
    public static func currentLanguage() -> String {
        let identifier = Locale.preferredLanguages.first ?? Locale.current.identifier
        let code = Locale(identifier: identifier).language.languageCode?.identifier ?? ""
        return normalize(code.isEmpty ? "en" : code)
    }

    static func normalize(_ raw: String) -> String {
        switch raw.lowercased() {
        case "iw": return "he"
        case "in": return "id"
        case "ji": return "yi"
        default: return raw
        }
    }

    /// `Accept-Language` for `language`.
    public static func acceptLanguage(for language: String) -> String {
        language == "en" ? "en-US,en;q=0.9" : "\(language),en-US;q=0.8,en;q=0.7"
    }
}
