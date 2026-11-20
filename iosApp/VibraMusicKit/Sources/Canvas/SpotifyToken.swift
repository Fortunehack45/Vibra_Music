import VibraMusicCore
import Foundation

/// A token the web player minted for itself, harvested out of a real page load.
public struct CanvasHarvestedToken: Hashable, Sendable {
    public var token: String
    public var expiresAt: Date
    public var clientId: String?

    public init(token: String, expiresAt: Date, clientId: String? = nil) {
        self.token = token
        self.expiresAt = expiresAt
        self.clientId = clientId
    }
}

/// Loads `open.spotify.com` for real with the listener's cookie applied and reads the bearer
/// token the page mints for itself, by hooking `fetch`/`XHR` before the player's own bundle
/// runs (Android: `SpotifyToken.harvestViaWebView`).
///
/// The harvester lives behind this protocol because it needs a web view: the app implements
/// it with a `WKWebView` (`WKHTTPCookieStore` for the `sp_dc` cookie, `WKUserContentController`
/// injecting `CanvasSpotifyTokenStore.harvestHookScript(bridge:)` at document start, and a
/// `WKScriptMessageHandler` parsing the `/api/token` bodies with
/// `CanvasSpotifyTokenStore.harvestedToken(in:)`). WebKit is available on macOS too, so a
/// host-side harvester is possible for the same price.
///
/// Signing the token request without a page load is not enough: Spotify's `/api/token`
/// replacement checks a TOTP the web player computes from a secret buried in its own JS
/// bundle. Forging it gets a 200 back with a token that nothing downstream honours —
/// api.spotify.com and spclient turn it away with a 429 that reads exactly like rate limiting,
/// right up until it fires on the very first request of a session.
public protocol CanvasSpotifyTokenHarvester: Sendable {
    func harvest(spDcCookie: String) async -> CanvasHarvestedToken?
}

/// The bearer token behind Spotify's own web player, minted from the listener's session cookie
/// (`AppSettings.spotifySpdcToken`) rather than an app credential — there is no public API for
/// a track's Canvas, so this walks the same door the web player itself uses to fetch one
/// (Android: `SpotifyToken` in `data/canvas/SpotifyToken.kt`).
///
/// Callers read `accessToken()`; without a cookie set it returns nil before any request is
/// made, so the Spotify source is a free no-op until the listener pastes theirs in Settings.
/// Tokens are cached until shortly before they expire so skipping through a queue doesn't pay
/// for a harvest per track.
public actor CanvasSpotifyTokenStore {
    public static let defaultTokenLifetime: TimeInterval = 3600
    /// The desktop browser the harvest's web view should claim to be, as Android's does.
    public static let webPlayerUserAgent = CanvasHTTP.userAgent
    static let tokenRefreshMargin: TimeInterval = 30

    private let http: CanvasHTTP
    private let cookie: @Sendable () async -> String
    private let harvester: (any CanvasSpotifyTokenHarvester)?

    private var cachedAccessToken: String?
    private var accessTokenExpiresAt: Date = .distantPast
    private var cachedClientId: String?
    private var harvesting: (task: Task<CanvasHarvestedToken?, Never>, cookie: String)?
    private var cachedCookie: String?

    private var cachedSession: SessionInfo?
    private var cachedClientToken: String?
    private var clientTokenExpiresAt: Date = .distantPast

    struct SessionInfo: Sendable {
        var clientVersion: String
        var deviceId: String
    }

    /// - Parameters:
    ///   - session: used for the plain-HTTP parts (client token, session info).
    ///   - cookie: returns the listener's `sp_dc` cookie (normally
    ///     `{ await settings.spotifySpdcToken }`); blank means no Spotify source.
    ///   - harvester: the web-view harvest; nil (the default) means `accessToken()` always
    ///     misses and the Spotify source stays off.
    public init(
        session: URLSession = VibraMusicHTTP.session,
        cookie: @escaping @Sendable () async -> String = { "" },
        harvester: (any CanvasSpotifyTokenHarvester)? = nil
    ) {
        http = CanvasHTTP(session: session)
        self.cookie = cookie
        self.harvester = harvester
    }

    public func accessToken() async -> String? {
        let spDc = await cookie()
        if spDc.isBlankForCanvas { return nil }

        let now = Date()
        // A token belongs to the account whose cookie minted it.
        if let cachedAccessToken, spDc == cachedCookie,
           now < accessTokenExpiresAt.addingTimeInterval(-Self.tokenRefreshMargin) {
            return cachedAccessToken
        }

        guard let harvester else { return nil }
        // One web-view load per cookie at a time: lookups arriving while it runs wait for the same
        // token (Android serialises these behind a mutex).
        let harvest: Task<CanvasHarvestedToken?, Never>
        if let inFlight = harvesting, inFlight.cookie == spDc {
            harvest = inFlight.task
        } else {
            harvest = Task { await harvester.harvest(spDcCookie: spDc) }
            harvesting = (harvest, spDc)
        }
        let found = await harvest.value
        if harvesting?.task == harvest { harvesting = nil }
        guard let harvested = found else { return nil }

        cachedAccessToken = harvested.token
        cachedCookie = spDc
        accessTokenExpiresAt = harvested.expiresAt
        if let clientId = harvested.clientId { cachedClientId = clientId }
        canvasLogDebug("CanvasSpotifyTokenStore: harvested access token, good until \(self.accessTokenExpiresAt)")
        return harvested.token
    }

    /// The second header these endpoints have started demanding alongside the bearer token —
    /// api.spotify.com and spclient both turn away a request carrying only the bearer with a
    /// 429. Best-effort: with no client token the caller just sends the bearer alone and takes
    /// whatever the endpoint does with that. Requires `accessToken()` to have already
    /// succeeded once, since the client id it needs comes off that response.
    public func clientToken() async -> String? {
        let now = Date()
        if let cachedClientToken, now < clientTokenExpiresAt.addingTimeInterval(-Self.tokenRefreshMargin) {
            return cachedClientToken
        }

        guard let clientId = cachedClientId else {
            canvasLogDebug("CanvasSpotifyTokenStore: no client id yet (access token not minted); skipping client token")
            return nil
        }
        guard let sessionInfo = await session() else { return nil }

        let payload = """
        {"client_data":{"client_version":"\(sessionInfo.clientVersion)","client_id":"\(clientId)",\
        "js_sdk_data":{"device_brand":"unknown","device_model":"unknown","os":"ios",\
        "os_version":"17.0","device_id":"\(sessionInfo.deviceId)","device_type":"smartphone"}}}
        """
        // NOTE: Android sends the platform as "android" from the phone it harvests on. This
        // store runs on iOS, so it says "ios"; the os_version is the floor the SDK accepts,
        // not the device's own.
        guard let url = URL(string: "https://clienttoken.spotify.com/v1/clienttoken") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(CanvasHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(payload.utf8)
        let sent = request

        let (status, body): (Int, String?) = await {
            do {
                let (data, response) = try await withCanvasDeadline(CanvasHTTP.deadline) {
                    try await self.httpSession().data(for: sent)
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                return (code, code / 100 == 2 ? CanvasHTTP.decode(data) : nil)
            } catch {
                canvasLogWarning("CanvasSpotifyTokenStore: client-token request threw: \(error.localizedDescription)")
                return (-1, nil)
            }
        }()
        guard let body else {
            canvasLogWarning("CanvasSpotifyTokenStore: client-token request failed, http \(status)")
            return nil
        }

        guard let root = CanvasJSON.parse(body)?.object else {
            canvasLogWarning("CanvasSpotifyTokenStore: client-token response wasn't JSON")
            return nil
        }
        guard root["response_type"]?.string == "RESPONSE_GRANTED_TOKEN_RESPONSE" else {
            canvasLogWarning("CanvasSpotifyTokenStore: client-token request rejected: \(root["response_type"]?.string ?? "?")")
            return nil
        }
        guard let granted = root["granted_token"]?.object,
              let token = granted["token"]?.string
        else {
            canvasLogWarning("CanvasSpotifyTokenStore: client-token response had no granted_token.token")
            return nil
        }
        // `expires_after_seconds` may decode as a number rather than a string; accept both.
        let ttlSeconds: Int64 = {
            if let number = granted["expires_after_seconds"]?.double { return Int64(number) }
            if let text = granted["expires_after_seconds"]?.string, let parsed = Int64(text) { return parsed }
            return 3600
        }()

        cachedClientToken = token
        clientTokenExpiresAt = now.addingTimeInterval(TimeInterval(ttlSeconds))
        canvasLogDebug("CanvasSpotifyTokenStore: minted client token, good for \(ttlSeconds)s")
        return token
    }

    public func reset() {
        cachedAccessToken = nil
        accessTokenExpiresAt = .distantPast
        cachedClientId = nil
        cachedClientToken = nil
        clientTokenExpiresAt = .distantPast
        cachedSession = nil
    }

    private func httpSession() -> URLSession {
        http.session
    }

    /// `SessionInfo.clientVersion` and `SessionInfo.deviceId` both come off the plain,
    /// unauthenticated web player page — the client version from a JSON blob it embeds for
    /// itself, the device id from the `sp_t` cookie it hands out to every visitor. Fetched
    /// once and held: neither changes inside a session.
    func session() async -> SessionInfo? {
        if let cachedSession { return cachedSession }

        guard let url = URL(string: "https://open.spotify.com") else { return nil }
        var request = URLRequest(url: url)
        request.setValue(CanvasHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        let sent = request
        let html: String?
        let deviceId: String?
        do {
            let (data, response) = try await withCanvasDeadline(CanvasHTTP.deadline) {
                try await self.httpSession().data(for: sent)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status / 100 == 2 else { return nil }
            html = CanvasHTTP.decode(data)
            deviceId = (response as? HTTPURLResponse)?.allHeaderFields
                .compactMap { key, value -> String? in
                    guard "\(key)".lowercased() == "set-cookie" else { return nil }
                    let header = "\(value)"
                    guard let range = header.range(of: "sp_t=") else { return nil }
                    return String(header[range.upperBound...].prefix(while: { $0 != ";" }))
                }.first
        } catch {
            canvasLogWarning("CanvasSpotifyTokenStore: couldn't load the web player page for session info")
            return nil
        }
        guard let html else {
            canvasLogWarning("CanvasSpotifyTokenStore: couldn't load the web player page for session info")
            return nil
        }

        guard let match = html.range(
            of: "<script id=\"appServerConfig\" type=\"text/plain\">([^<]+)</script>",
            options: .regularExpression),
            let capture = Self.firstCaptureGroup(in: html, match: match),
            let configData = Data(base64Encoded: capture),
            let configText = String(data: configData, encoding: .utf8),
            let clientVersion = CanvasJSON.parse(configText)?.object?["clientVersion"]?.string
        else {
            canvasLogWarning("CanvasSpotifyTokenStore: web player page had no appServerConfig block")
            return nil
        }

        let sessionInfo = SessionInfo(
            clientVersion: clientVersion, deviceId: deviceId ?? UUID().uuidString)
        cachedSession = sessionInfo
        return sessionInfo
    }

    private static func firstCaptureGroup(in string: String, match: Range<String.Index>) -> String? {
        // Re-run with NSRegularExpression to read the capture group.
        guard let regex = try? NSRegularExpression(
            pattern: "<script id=\"appServerConfig\" type=\"text/plain\">([^<]+)</script>"),
            let nsMatch = regex.firstMatch(
                in: string, range: NSRange(string.startIndex..., in: string)),
            nsMatch.numberOfRanges == 2,
            let range = Range(nsMatch.range(at: 1), in: string)
        else { return nil }
        _ = match
        return String(string[range])
    }

    // MARK: - Web-view harvest support

    /// The script the app's `WKWebView` injects at document start. It hooks `fetch` and `XHR`
    /// and reports raw `/api/token` response bodies to `bridge` (a `WKScriptMessageHandler`
    /// named `bridgeName`). Must run before the player's own bundle — inject at
    /// `.atDocumentStart`, and re-inject on navigation.
    public static func harvestHookScript(bridge bridgeName: String) -> String {
        """
        (function () {
          if (window.__vibramusicTokenHook) return;
          window.__vibramusicTokenHook = true;
          var report = function (body) {
            try { window.webkit.messageHandlers.\(bridgeName).postMessage(body); } catch (e) {}
          };
          var isToken = function (u) {
            try { return String(u).indexOf('/api/token') !== -1; } catch (e) { return false; }
          };
          var origFetch = window.fetch;
          if (origFetch) {
            window.fetch = function (input, init) {
              var url = (input && input.url) ? input.url : input;
              var result = origFetch.apply(this, arguments);
              if (isToken(url)) {
                try {
                  result.then(function (res) {
                    res.clone().text().then(report).catch(function () {});
                  }).catch(function () {});
                } catch (e) {}
              }
              return result;
            };
          }
          var origOpen = XMLHttpRequest.prototype.open;
          XMLHttpRequest.prototype.open = function (method, url) {
            this.__vibramusicUrl = url;
            return origOpen.apply(this, arguments);
          };
          var origSend = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.send = function () {
            var xhr = this;
            try {
              xhr.addEventListener('load', function () {
                if (isToken(xhr.__vibramusicUrl)) {
                  try { report(xhr.responseText); } catch (e) {}
                }
              });
            } catch (e) {}
            return origSend.apply(this, arguments);
          };
        })();
        """
    }

    /// Picks the logged-in token out of a raw `/api/token` response body, or nil when this
    /// isn't one to keep. The player also mints an anonymous token before the cookie takes
    /// effect; that one can't read canvases, so the harvester keeps waiting for the
    /// logged-in one.
    public static func harvestedToken(
        in payload: String, now: Date = Date(),
        defaultLifetime: TimeInterval = defaultTokenLifetime
    ) -> CanvasHarvestedToken? {
        guard !payload.isEmpty,
              let root = CanvasJSON.parse(payload)?.object,
              let token = root["accessToken"]?.string, !token.isEmpty
        else { return nil }
        if root["isAnonymous"]?.boolValue == true { return nil }
        // The default lifetime is for a response that doesn't say; one that says the token is
        // already expired is not a token to keep. The harvester keeps waiting for a fresh one.
        let expiresAt: Date
        if let millis = root["accessTokenExpirationTimestampMs"]?.millisValue {
            expiresAt = Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
            if expiresAt <= now { return nil }
        } else {
            expiresAt = now.addingTimeInterval(defaultLifetime)
        }
        return CanvasHarvestedToken(
            token: token, expiresAt: expiresAt, clientId: root["clientId"]?.string)
    }
}

private extension CanvasJSON {
    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        if case .string(let text) = self {
            return Bool(text.lowercased())
        }
        return nil
    }

    var millisValue: Int64? {
        if case .number(let value) = self { return Int64(value) }
        if case .string(let text) = self { return Int64(text) }
        return nil
    }
}
