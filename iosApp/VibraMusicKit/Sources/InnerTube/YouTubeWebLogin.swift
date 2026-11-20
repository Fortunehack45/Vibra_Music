import Foundation

// Ports auth/WebSession.kt and the logic of auth/YtMusicLoginScreen.kt (the screen itself is a
// WKWebView built by the app; see YouTubeLoginWebController for the WebKit half).

/// What the in-app browser is being opened for.
public enum WebSessionMode: String, Hashable, Sendable {
    /// No usable session yet: sign in to Google.
    case signIn = "SIGN_IN"
    /// Already signed in, but on the wrong channel. Opens YouTube Music itself so its own Accounts
    /// switcher can be used, and takes the session from whatever page the listener ends up on.
    case switchChannel = "SWITCH_CHANNEL"
}

/// A session lifted out of the in-app browser: the cookie, plus who the page being looked at says it
/// is.
///
/// The identity fields come from the live page's `ytcfg` rather than from a later server-side fetch
/// of the shell, and that is the entire point: which channel YouTube Music serves by default is not
/// this app's to answer, but which channel the page in front of the listener is *currently* showing
/// is written down in the page. Individual fields are optional because a personal viewer need not
/// have a channel.
public struct CapturedSession: Hashable, Sendable {
    public var cookie: String
    /// `DELEGATED_SESSION_ID` — set only while a brand channel is selected.
    public var pageId: String?
    /// Active identity used as `context.user.onBehalfOfUser`.
    public var dataSyncId: String?
    /// `SESSION_INDEX` — which Google account in the cookie jar.
    public var authUser: String?
    public var visitorData: String?
    public var clientVersion: String?
    /// Whether the page reported itself signed in at all.
    public var loggedIn: Bool

    public init(
        cookie: String,
        pageId: String?,
        dataSyncId: String?,
        authUser: String?,
        visitorData: String?,
        clientVersion: String?,
        loggedIn: Bool
    ) {
        self.cookie = cookie
        self.pageId = pageId
        self.dataSyncId = dataSyncId
        self.authUser = authUser
        self.visitorData = visitorData
        self.clientVersion = clientVersion
        self.loggedIn = loggedIn
    }
}

/// Why a capture was refused. The login screen stays open in every case.
public enum WebSessionCaptureFailure: Error, Hashable, Sendable {
    /// The cookie jar has no signing secret yet — the page is mid-login, or is not a YouTube page.
    case noSigningCookie
    /// The page hasn't exposed a signed-in identity (no `ytcfg`, or `LOGGED_IN` false). Confirmation
    /// was requested too early — typically while a multi-channel account is still choosing.
    case notSignedIn
}

/// The sign-in flow's rules, independent of any web view.
///
/// ``WebSessionMode/signIn`` loads the standard Google web login with `continue=music.youtube.com`.
/// The user authenticates on the real accounts.google.com page (2FA and passkeys work). When Google
/// redirects back to music.youtube.com the listener confirms the profile the live page shows; nothing
/// is captured automatically, because a multi-channel login can still be choosing its Personal or
/// Brand identity on that very page (capturing on page load is the race that used to create a fake
/// "Personal" profile and close too soon). The browser's local Google cookies are cleared on the way
/// in *without* visiting Google's logout endpoint, so adding an account cannot invalidate a
/// previously saved one.
///
/// ``WebSessionMode/switchChannel`` keeps the saved account's cookies and opens YouTube Music itself,
/// so the listener can use the avatar menu's own Accounts list, then confirm.
public enum YouTubeWebLogin {
    public static let musicOrigin = "https://music.youtube.com"

    /// Google's own sign-in page, sending the listener to YouTube Music afterwards.
    public static let loginURL = URL(string:
        "https://accounts.google.com/ServiceLogin?ltmpl=music&service=youtube&passive=true&continue=https%3A%2F%2Fmusic.youtube.com%2F"
    )!

    public static let musicURL = URL(string: "https://music.youtube.com/")!

    /// Appended to WebKit's user agent so the login page sees the same browser Safari is.
    ///
    /// No Android counterpart (its WebView kept the stock user agent). A bare `WKWebView` identifies
    /// as WebKit without Safari's `Version/… Safari/…` suffix, which is how Google tells an embedded
    /// browser from Safari and may refuse the sign-in as "not secure". The suffix is Safari's own for
    /// the platform, so the page, its 2FA and passkey flows are the ones Safari gets.
    public static var safariApplicationName: String {
        #if os(iOS)
        "Version/17.0 Mobile/15E148 Safari/604.1"
        #else
        "Version/17.0 Safari/605.1.15"
        #endif
    }

    /// What to load for `mode`.
    public static func startURL(for mode: WebSessionMode) -> URL {
        mode == .signIn ? loginURL : musicURL
    }

    /// Whether a finished page load enables the confirm button: the browser is back on YouTube
    /// Music. Reaching it only *enables* confirmation — see the type's discussion.
    public static func isReadyForConfirmation(_ url: URL?) -> Bool {
        url?.absoluteString.hasPrefix(musicOrigin) == true
    }

    /// Origins whose cookies make up "the Google login" in the browser's jar. Only these are cleared
    /// on sign-in and sign-out: the same jar holds the Discord and Last.fm logins from their own
    /// in-app browsers, and signing out of YouTube Music is no reason to sign out of those.
    public static let googleOrigins = [
        "https://music.youtube.com", "https://www.youtube.com", "https://youtube.com",
        "https://accounts.google.com", "https://www.google.com", "https://google.com",
    ]

    /// Origins a saved account's cookie snapshot is installed on before opening the channel picker.
    public static let youtubeOrigins = ["https://music.youtube.com", "https://www.youtube.com", "https://youtube.com"]

    /// The identity of the page as the page itself has it, evaluated in the page.
    ///
    /// Returns an object rather than a string so WebKit hands back a dictionary — a probe that
    /// stringified its own result would come back double-encoded. A page without `ytcfg` (an error
    /// page, a redirect that hasn't landed) returns null, which is a fine answer and not an error.
    public static let ytcfgProbeScript = """
    (function () {
      try {
        if (!window.ytcfg || !window.ytcfg.get) return null;
        var get = function (key) {
          var value = window.ytcfg.get(key);
          return (value === undefined || value === null || value === '') ? null : String(value);
        };
        return {
          loggedIn: String(!!window.ytcfg.get('LOGGED_IN')),
          pageId: get('DELEGATED_SESSION_ID'),
          dataSyncId: get('DATASYNC_ID'),
          authUser: get('SESSION_INDEX'),
          visitorData: get('VISITOR_DATA'),
          clientVersion: get('INNERTUBE_CLIENT_VERSION')
        };
      } catch (e) {
        return null;
      }
    })()
    """

    /// Decides a confirmation request: the music.youtube.com cookie header and the probe's result
    /// (a dictionary from WebKit, or its JSON text).
    ///
    /// Refuses a jar with no signing secret (saving it would store something that cannot sign a
    /// request — see ``SAPISIDAuth/hasSigningSecret(_:)``) and a page that doesn't say it is signed
    /// in. A delegated identity (`DELEGATED_SESSION_ID`) is the most specific answer the page can
    /// give; otherwise its `DATASYNC_ID` is normalised.
    public static func captureSession(
        cookieHeader: String?,
        probeResult: Any?
    ) -> Result<CapturedSession, WebSessionCaptureFailure> {
        guard let cookieHeader, SAPISIDAuth.hasSigningSecret(cookieHeader) else { return .failure(.noSigningCookie) }
        guard let config = probeValues(probeResult), config["loggedIn"] == "true" else { return .failure(.notSignedIn) }
        let pageId = config["pageId"].nonBlank
        return .success(CapturedSession(
            cookie: cookieHeader,
            pageId: pageId,
            dataSyncId: pageId ?? normalizeDataSyncId(config["dataSyncId"]),
            authUser: config["authUser"].nonBlank,
            visitorData: config["visitorData"].nonBlank,
            clientVersion: config["clientVersion"].nonBlank,
            loggedIn: true
        ))
    }

    /// The probe's string fields, from WebKit's dictionary or from JSON text; nil for anything that
    /// isn't the object it promises.
    static func probeValues(_ result: Any?) -> [String: String]? {
        if let dictionary = result as? [String: Any] {
            var values: [String: String] = [:]
            for (key, value) in dictionary {
                if let text = value as? String {
                    values[key] = text
                } else if let number = value as? NSNumber {
                    values[key] = number.stringValue
                }
            }
            return values
        }
        if let text = result as? String, let parsed = try? InnerTubeJSON.parse(text), let object = parsed.objectValue {
            var values: [String: String] = [:]
            for (key, value) in object.entries {
                if let content = value.primitiveContent { values[key] = content }
            }
            return values
        }
        return nil
    }

    /// Value accepted by Innertube as `context.user.onBehalfOfUser`. YouTube commonly exposes
    /// `DATASYNC_ID` as `account||delegated`; the second half is the active identity, while plain
    /// accounts leave it empty.
    public static func normalizeDataSyncId(_ raw: String?) -> String? {
        guard let value = raw.nonBlank else { return nil }
        guard value.contains("||") else { return value }
        return value.substring(after: "||", missing: "").nonBlankString
            ?? value.substring(before: "||").nonBlankString
    }

    // MARK: Cookies

    /// The `Cookie` header a request to `url` would carry from `cookies` (WebKit's jar): domain and
    /// path matched, secure cookies only over https, expired ones skipped. Nil when none apply.
    public static func cookieHeader(from cookies: [HTTPCookie], for url: URL = musicURL, now: Date = Date()) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        let path = url.path(percentEncoded: true).isEmpty ? "/" : url.path(percentEncoded: true)
        let isSecure = url.scheme?.lowercased() == "https"
        let matching = cookies.filter { cookie in
            if let expires = cookie.expiresDate, expires <= now { return false }
            if cookie.isSecure && !isSecure { return false }
            if !domain(cookie.domain, matches: host) { return false }
            let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
            // RFC 6265 §5.1.4: a prefix only matches on a "/" boundary, so a cookie for
            // /watch is never sent to /watchlater.
            if path == cookiePath { return true }
            guard path.hasPrefix(cookiePath) else { return false }
            return cookiePath.hasSuffix("/") || path.dropFirst(cookiePath.count).hasPrefix("/")
        }
        guard !matching.isEmpty else { return nil }
        // Longer paths first, as browsers order them; names are otherwise kept in jar order.
        let ordered = matching.enumerated().sorted { lhs, rhs in
            lhs.element.path.count != rhs.element.path.count ? lhs.element.path.count > rhs.element.path.count : lhs.offset < rhs.offset
        }.map(\.element)
        return ordered.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// Whether a cookie set for `cookieDomain` is sent to `host`.
    static func domain(_ cookieDomain: String, matches host: String) -> Bool {
        let domain = cookieDomain.lowercased()
        if domain.hasPrefix(".") {
            let bare = String(domain.dropFirst())
            return host == bare || host.hasSuffix(domain)
        }
        return host == domain
    }

    /// Whether a cookie belongs to the Google login (any Google or YouTube host in
    /// ``googleOrigins``).
    public static func isGoogleCookie(_ cookie: HTTPCookie) -> Bool {
        googleOrigins.contains { origin in
            guard let host = URL(string: origin)?.host() else { return false }
            return domain(cookie.domain, matches: host)
                || cookie.domain.lowercased().removingPrefix(".") == host
        }
    }

    /// A saved account's cookie header as browser cookies for each of ``youtubeOrigins``: host-only,
    /// path `/`, secure — so the channel picker opens as that account, not whichever one signed in
    /// most recently.
    public static func browserCookies(fromHeader cookieHeader: String) -> [HTTPCookie] {
        let entries: [(String, String)] = cookieHeader.split(separator: ";", omittingEmptySubsequences: false).compactMap { entry in
            let text = String(entry)
            let name = text.substring(before: "=").trimmedText
            let value = text.substring(after: "=", missing: "").trimmedText
            return (name.isEmpty || value.isEmpty) ? nil : (name, value)
        }
        return youtubeOrigins.flatMap { origin -> [HTTPCookie] in
            guard let host = URL(string: origin)?.host() else { return [] }
            return entries.compactMap { name, value in
                HTTPCookie(properties: [
                    .name: name,
                    .value: value,
                    .domain: host,
                    .path: "/",
                    .secure: "TRUE",
                ])
            }
        }
    }
}

extension String {
    var nonBlankString: String? { isBlankText ? nil : self }
}
