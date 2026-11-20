import Foundation
import VibraMusicCore

// Ports data/innertube/Innertube.kt: the session and request plumbing. Endpoints live in
// InnerTubeClient+Endpoints.swift.

/// Minimal Innertube (youtubei) client.
///
/// WEB_REMIX against music.youtube.com for browse, search, library and account calls. It returns
/// the full YouTube Music shelf layout and honours the signed-in session. Stream URLs are not
/// fetched here (StreamResolution owns `player` for playback); ``requestIdentity(origin:)`` hands
/// that module the headers and context it needs to make its requests as the same listener.
///
/// Authenticated requests are signed with Google's SAPISIDHASH scheme derived from the stored
/// cookie; no long-lived token is ever minted or stored.
///
/// An actor rather than Android's process-wide `object`: the session (cookie, visitor id, scope,
/// chosen channel) is mutable state that screens, playback and the account manager all touch. The
/// app keeps one instance (``shared``); tests make their own with a stubbed `URLSession`.
public actor InnerTubeClient {
    /// The app's instance.
    public static let shared = InnerTubeClient()

    public static let musicOrigin = "https://music.youtube.com"
    static let musicBase = "https://music.youtube.com/youtubei/v1"
    static let youtubeOrigin = "https://www.youtube.com"
    /// `gl`. Android pins it; the catalogue answers are the US ones regardless of the device region.
    public static let region = "US"

    /// Fallback WEB_REMIX version, used until the session scope reads the live one out of the
    /// music.youtube.com shell. Only a starting point: the real version moves every few days, and
    /// the one that matters is the one ``webRemixVersion`` reports.
    static let fallbackClientVersion = "1.20250101.01.00"
    static let webRemixClientId = "67"
    static let log = "InnerTube"

    let session: URLSession
    private let languageProvider: @Sendable () -> String
    private let clock: @Sendable () -> Date
    private let retryBaseDelay: Duration

    /// Session cookie captured by the login web view; nil = browse as guest. Set with
    /// ``setCookie(_:)``.
    public private(set) var cookie: String?

    /// Google's per-session visitor id.
    ///
    /// Far more load-bearing than "an id for stats". A `player` request that carries no visitor id
    /// is treated as a client with no session at all, and Google answers it either with
    /// `LOGIN_REQUIRED` or — the quiet way — with stream URLs that serve a byte and then refuse every
    /// real read with 403. So it is fetched deliberately by ``ensureVisitorData(refresh:)`` rather
    /// than hoped for.
    private(set) var visitorData: String?

    /// Whether ``visitorData`` came from the signed-in shell rather than being minted anonymously.
    /// A session-bound id outranks an anonymous one and must not be replaced by it; both are fetched
    /// near startup and nothing orders them.
    private(set) var visitorDataIsSessionBound = false

    private(set) var scope: InnerTubeSessionScope?

    /// The channel to act as, when the listener has said which. Once chosen it outranks the shell
    /// completely, including when what it chose is the account's own channel and the shell is the
    /// one offering a brand page.
    private(set) var channelOverride: InnerTubeChannelSelection?

    /// The shell fetch in flight, keyed by the cookie it was started for, so concurrent requests
    /// share one fetch (Android's scope mutex).
    private var scopeFetch: (cookie: String, task: Task<InnerTubeSessionScope?, Never>)?

    /// - Parameters:
    ///   - session: the HTTP session (tests pass a `URLProtocolStub` session).
    ///   - language: the `hl` to ask in; defaults to the app's language.
    ///   - clock: the time SAPISIDHASH timestamps are taken from.
    ///   - retryBaseDelay: first backoff for transport retries (doubles each time).
    public init(
        session: URLSession = VibraMusicHTTP.session,
        language: @escaping @Sendable () -> String = { InnerTubeLocale.currentLanguage() },
        clock: @escaping @Sendable () -> Date = { Date() },
        retryBaseDelay: Duration = .milliseconds(500)
    ) {
        self.session = session
        self.languageProvider = language
        self.clock = clock
        self.retryBaseDelay = retryBaseDelay
    }

    // MARK: - Session state

    public var isSignedIn: Bool { cookie != nil }

    /// The `hl` requests are made in.
    public var currentLanguage: String { languageProvider() }

    /// Replaces the session cookie (nil signs out of requests).
    ///
    /// A different cookie drops everything that belonged to the session that just left: a scope
    /// kept across a sign-in would credit the new account's plays to the old one, a visitor id
    /// minted under the old session is not bound to the new one, and a `dataSyncId` from one login
    /// sent under another's cookie is answered with 401 on every request.
    public func setCookie(_ newValue: String?) {
        if cookie != newValue {
            scope = nil
            visitorData = nil
            visitorDataIsSessionBound = false
            channelOverride = nil
            scopeFetch = nil
        }
        cookie = newValue
    }

    /// Act as this channel from now on; both nil goes back to the shell's default. Takes effect on
    /// the next request — nothing is cached from it.
    public func selectChannel(pageId: String?, dataSyncId: String?, authUser: String? = nil) {
        channelOverride = (pageId == nil && dataSyncId == nil)
            ? nil
            : InnerTubeChannelSelection(pageId: pageId, dataSyncId: dataSyncId, authUser: authUser)
        DebugLog.d(Self.log, "acting as channel pageId=\(pageId ?? "none") authUser=\(authUser ?? "as-is") (override=\(channelOverride != nil))")
    }

    /// Takes the session scope from a page the listener was actually looking at, rather than working
    /// it out later from a fetch of our own.
    ///
    /// The shell fetch can only ever report the channel music.youtube.com serves this app by
    /// default, and the in-app browser exists because the listener has just told it, by hand, that
    /// they want a different one. That answer is written into the page's own `ytcfg`, so it is read
    /// from there and adopted whole. Adopting also settles ``ensureSessionScope()`` — a scope in hand
    /// is not refetched — so the shell cannot quietly overwrite the choice on the next request.
    ///
    /// A page that reported itself signed out is ignored apart from its client version: its
    /// `DATASYNC_ID` belongs to no account.
    public func adoptSessionScope(
        pageId: String?,
        dataSyncId: String?,
        authUser: String?,
        visitorData: String?,
        clientVersion: String?,
        loggedIn: Bool
    ) {
        let version = clientVersion ?? scope?.clientVersion
        guard loggedIn else {
            DebugLog.w(Self.log, "captured page was signed out; not scoping requests to it")
            scope = version.map { InnerTubeSessionScope(dataSyncId: nil, pageId: nil, authUser: "0", clientVersion: $0) }
            return
        }
        scope = InnerTubeSessionScope(
            dataSyncId: dataSyncId.nonBlank,
            pageId: pageId.nonBlank,
            authUser: authUser.nonBlank ?? "0",
            clientVersion: version
        )
        // The page's own visitor id, bound to this session — strictly better than the anonymous one
        // sw.js_data mints.
        if let bound = visitorData.nonBlank {
            self.visitorData = bound
            visitorDataIsSessionBound = true
        }
        DebugLog.d(Self.log, "adopted page scope: pageId=\(pageId ?? "none") authUser=\(authUser ?? "0")")
    }

    /// Installs a session captured from the login web view in one step: the cookie, the identity the
    /// page reported, and that identity as the chosen channel. One actor call so no request can slip
    /// in between the cookie changing and the scope being adopted and start a shell fetch that would
    /// overwrite the listener's choice.
    public func adoptWebSession(_ captured: CapturedSession) {
        setCookie(captured.cookie)
        adoptSessionScope(
            pageId: captured.pageId,
            dataSyncId: captured.dataSyncId,
            authUser: captured.authUser,
            visitorData: captured.visitorData,
            clientVersion: captured.clientVersion,
            loggedIn: captured.loggedIn
        )
        selectChannel(pageId: captured.pageId, dataSyncId: captured.dataSyncId, authUser: captured.authUser)
    }

    /// Installs a stored account profile: its cookie, then its channel. In that order, never the
    /// other: setting the cookie clears any chosen channel, so restoring the choice first would
    /// restore it into the value about to be wiped.
    public func activate(cookie: String?, profile: YouTubeProfile?) {
        setCookie(cookie)
        selectChannel(pageId: profile?.pageId, dataSyncId: profile?.dataSyncId, authUser: profile?.authUser)
    }

    /// The brand channel to send, chosen one first.
    func pageId(for session: InnerTubeSessionScope?) -> String? {
        guard let channelOverride else { return session?.pageId }
        return channelOverride.pageId
    }

    /// The account to send as `onBehalfOfUser`, chosen one first. No falling back to the shell's
    /// value once a channel has been chosen: the shell's id names the default identity, and pairing
    /// it with another channel's page id describes an account/page combination that doesn't exist.
    func dataSyncId(for session: InnerTubeSessionScope?) -> String? {
        guard let channelOverride else { return session?.dataSyncId }
        return channelOverride.dataSyncId
    }

    /// Which account in the cookie jar, chosen channel's first.
    func authUser(for session: InnerTubeSessionScope?) -> String {
        channelOverride?.authUser ?? session?.authUser ?? "0"
    }

    /// The WEB_REMIX version to claim, live if the shell has been read. Worth taking from the shell
    /// rather than pinning: the stats pings carry it as `cver`, and a version Google has never
    /// shipped invites being treated as something other than a music client.
    var webRemixVersion: String { scope?.clientVersion ?? Self.fallbackClientVersion }

    /// Reads the session scope, once per cookie, before anything that depends on being the right
    /// account.
    ///
    /// Cheap to be wrong about and expensive to skip, so it fails open: a shell that cannot be
    /// fetched or parsed leaves the scope nil and every request behaves as it would have without it.
    /// What it must never do is invent a `dataSyncId`.
    public func ensureSessionScope() async {
        guard let session = cookie, scope == nil else { return }
        let task: Task<InnerTubeSessionScope?, Never>
        if let running = scopeFetch, running.cookie == session {
            task = running.task
        } else {
            task = Task { [weak self] in
                guard let self else { return nil }
                do {
                    return try await self.fetchSessionScope(session)
                } catch {
                    DebugLog.w(Self.log, "could not read the session scope: \(error.localizedDescription)")
                    return nil
                }
            }
            scopeFetch = (session, task)
        }
        let fresh = await task.value
        if let running = scopeFetch, running.task == task { scopeFetch = nil }
        // A login/profile switch can happen while the shell is in flight. Never install the old
        // cookie's answer under the new one: that is a guaranteed 401 and can credit a play to the
        // profile that just left. Nor over a scope adopted from the page meanwhile.
        guard let fresh else { return }
        guard cookie == session else {
            DebugLog.d(Self.log, "discarding a session scope from an account that is no longer active")
            return
        }
        guard scope == nil else { return }
        scope = fresh
        if let selected = channelOverride, selected.pageId != fresh.pageId || selected.dataSyncId != fresh.dataSyncId {
            DebugLog.w(Self.log, "server shell identity differs from selected profile; retaining override")
        }
        DebugLog.d(
            Self.log,
            "session scope: authUser=\(fresh.authUser) pageId=\(fresh.pageId ?? "none") "
                + "dataSyncId=\(fresh.dataSyncId != nil ? "present" : "none") cver=\(fresh.clientVersion ?? Self.fallbackClientVersion)"
        )
    }

    /// Re-reads the request context once after an authenticated rejection.
    public func refreshSessionScope() async {
        guard cookie != nil else { return }
        scope = nil
        scopeFetch = nil
        await ensureSessionScope()
    }

    /// The music.youtube.com shell, fetched with the session, for its `ytcfg`.
    ///
    /// Read by regex rather than by evaluating the config blob: it is one script assignment among
    /// hundreds of kilobytes of JavaScript, and the values wanted are flat strings in it. A key that
    /// moves reads as absent, which is the same as not having asked.
    private func fetchSessionScope(_ sessionCookie: String) async throws -> InnerTubeSessionScope? {
        var request = URLRequest(url: URL(string: "\(Self.musicOrigin)/")!)
        request.setValue(VibraMusicHTTP.UserAgent.chromeDesktop, forHTTPHeaderField: "User-Agent")
        request.setValue(InnerTubeLocale.acceptLanguage(for: languageProvider()), forHTTPHeaderField: "Accept-Language")
        request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")
        if let sapisid = SAPISIDAuth.sapisid(fromCookieHeader: sessionCookie) {
            request.setValue(authorization(sapisid, origin: Self.musicOrigin), forHTTPHeaderField: "Authorization")
        }
        let html = String(decoding: try await send(request, label: "music shell").0, as: UTF8.self)
        let parsed = Self.sessionScope(fromShell: html)
        if parsed?.signedIn != true {
            DebugLog.w(Self.log, "music.youtube.com served a signed-out shell; not scoping requests")
        }
        guard let parsed else { return nil }
        // Only while the cookie it was fetched with is still the session's own.
        if cookie == sessionCookie, let bound = parsed.visitorData {
            // The shell's own visitor id, bound to this session. Strictly better than the anonymous
            // one: the stats pings are attributed against the visitor the player response was
            // issued to, so a signed-in play reported under an anonymous id is reported about nobody.
            visitorData = bound
            visitorDataIsSessionBound = true
        }
        return parsed.scope
    }

    /// What a music.youtube.com shell says about the session it was served to. Nil when it doesn't
    /// say it is signed in and names no client version either.
    static func sessionScope(fromShell html: String) -> (scope: InnerTubeSessionScope, visitorData: String?, signedIn: Bool)? {
        // The one value that must not be guessed. A shell that says it is signed out either has a
        // dead cookie or was served to nobody in particular; its DATASYNC_ID belongs to no account.
        let signedIn = ShellConfig.loggedIn.firstGroup(in: html) == "true"
        let clientVersion = ShellConfig.clientVersion.firstGroup(in: html)
        guard signedIn else {
            // Still worth the client version — that part is true either way.
            return clientVersion.map {
                (InnerTubeSessionScope(dataSyncId: nil, pageId: nil, authUser: "0", clientVersion: $0), nil, false)
            }
        }
        let pageId = ShellConfig.pageId.firstGroup(in: html).nonBlank
        let dataSyncId = pageId ?? YouTubeWebLogin.normalizeDataSyncId(ShellConfig.dataSyncId.firstGroup(in: html))
        let authUser = ShellConfig.sessionIndex.firstGroup(in: html).nonBlank
        let visitor = ShellConfig.visitorData.firstGroup(in: html).nonBlank
        return (InnerTubeSessionScope(dataSyncId: dataSyncId, pageId: pageId, authUser: authUser ?? "0", clientVersion: clientVersion), visitor, true)
    }

    enum ShellConfig {
        static let loggedIn = TextPattern(#""LOGGED_IN"\s*:\s*(true|false)"#)
        static let dataSyncId = TextPattern(#""DATASYNC_ID"\s*:\s*"([^"]+)""#)
        static let pageId = TextPattern(#""DELEGATED_SESSION_ID"\s*:\s*"([^"]+)""#)
        static let sessionIndex = TextPattern(#""SESSION_INDEX"\s*:\s*"?(\d+)"#)
        static let visitorData = TextPattern(#""VISITOR_DATA"\s*:\s*"([^"]+)""#)
        static let clientVersion = TextPattern(#""INNERTUBE_CLIENT_VERSION"\s*:\s*"([^"]+)""#)
    }

    // MARK: - Visitor id

    /// A visitor id for this session, minting one if there isn't one yet.
    ///
    /// - Parameter refresh: discard the current id and take a fresh one — worth doing exactly once
    ///   when a request comes back accusing us of being a bot, since an id can be burned while the
    ///   session around it is fine.
    public func ensureVisitorData(refresh: Bool = false) async -> String? {
        if !refresh, let visitorData { return visitorData }
        do {
            if let minted = try await fetchVisitorData(), refresh || !visitorDataIsSessionBound {
                visitorData = minted
                visitorDataIsSessionBound = false
            }
        } catch {
            DebugLog.w(Self.log, "could not mint a visitor id: \(error.localizedDescription)")
        }
        return visitorData
    }

    /// The service worker bootstrap the web player loads before anything else, which is where a
    /// fresh visitor id comes from without needing a page. It answers with an anti-hijacking prefix
    /// and then plain nested arrays, so the id is found by shape rather than by a path that would rot.
    private func fetchVisitorData() async throws -> String? {
        var request = URLRequest(url: URL(string: "\(Self.youtubeOrigin)/sw.js_data")!)
        request.setValue(VibraMusicHTTP.UserAgent.chromeDesktop, forHTTPHeaderField: "User-Agent")
        let body = String(decoding: try await send(request, label: "sw.js_data").0, as: UTF8.self)
        return try Self.visitorData(fromServiceWorkerData: body)
    }

    static func visitorData(fromServiceWorkerData body: String) throws -> String? {
        let payload = body.substring(after: "\n", missing: String(body.dropFirst(5)))
        return findVisitorData(try InnerTubeJSON.parse(payload))
    }

    private static func findVisitorData(_ element: InnerTubeJSON) -> String? {
        switch element {
        case .array(let array): return array.lazy.compactMap(findVisitorData).first
        case .string, .number, .bool:
            guard let text = element.primitiveContent, visitorDataShape.matches(text) else { return nil }
            return text
        default: return nil
        }
    }

    /// Protobuf-in-base64; always this shape, and nothing else in there is.
    static let visitorDataShape = TextPattern(#"Cg[A-Za-z0-9_%-]{40,}"#)

    // MARK: - Identity for other modules

    /// The headers and context that make a request act as the current listener, for requests this
    /// client doesn't make itself — StreamResolution's `player` calls, above all. Reads the session
    /// scope first when signed in, so the answer names the right account.
    ///
    /// - Parameter origin: the origin the SAPISIDHASH is computed for (`https://music.youtube.com`
    ///   for WEB_REMIX, `https://www.youtube.com` for the youtube.com clients).
    public func requestIdentity(origin: String = InnerTubeClient.musicOrigin) async -> InnerTubeRequestIdentity {
        if cookie != nil { await ensureSessionScope() }
        let session = scope
        return InnerTubeRequestIdentity(
            headers: signedHeaders(origin: origin, session: session, includePageId: true, includeAuthUser: true),
            cookie: cookie,
            authUser: authUser(for: session),
            pageId: cookie == nil ? nil : pageId(for: session),
            onBehalfOfUser: cookie == nil ? nil : dataSyncId(for: session),
            visitorData: visitorData,
            visitorDataIsSessionBound: visitorDataIsSessionBound,
            language: languageProvider(),
            region: Self.region,
            webRemixClientVersion: webRemixVersion,
            liveClientVersion: scope?.clientVersion
        )
    }

    /// Just the auth headers of ``requestIdentity(origin:)`` — `Cookie`, `Authorization`,
    /// `X-Goog-AuthUser`, `X-Goog-PageId` — or empty when signed out.
    public func authHeaders(origin: String = InnerTubeClient.musicOrigin) async -> [String: String] {
        await requestIdentity(origin: origin).headers
    }

    // MARK: - Request plumbing

    /// `Cookie`, `X-Goog-AuthUser`, `X-Goog-PageId` and a SAPISIDHASH `Authorization` for the current
    /// cookie; empty when signed out.
    func signedHeaders(
        origin: String,
        session: InnerTubeSessionScope?,
        includePageId: Bool,
        includeAuthUser: Bool
    ) -> [String: String] {
        guard let cookie else { return [:] }
        var headers = ["Cookie": cookie]
        // Which account in the jar, and which brand channel of it. Both were fixed at "the first
        // one" before the session scope existed, which is the same guess by another name.
        if includeAuthUser { headers["X-Goog-AuthUser"] = authUser(for: session) }
        if includePageId, let pageId = pageId(for: session) { headers["X-Goog-PageId"] = pageId }
        if let sapisid = SAPISIDAuth.sapisid(fromCookieHeader: cookie) {
            headers["Authorization"] = authorization(sapisid, origin: origin)
        }
        return headers
    }

    func authorization(_ sapisid: String, origin: String) -> String {
        SAPISIDAuth.authorization(sapisid: sapisid, origin: origin, timestamp: Int64(clock().timeIntervalSince1970))
    }

    /// Sends a request, failing on any non-2xx status (Ktor's `expectSuccess`).
    func send(_ request: URLRequest, label: String) async throws -> (Data, HTTPURLResponse) {
        var request = request
        if request.timeoutInterval > VibraMusicHTTP.requestTimeout { request.timeoutInterval = VibraMusicHTTP.requestTimeout }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw InnerTubeError.invalidResponse("\(label): not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw InnerTubeError.httpStatus(http.statusCode, endpoint: label)
        }
        return (data, http)
    }

    /// Runs `block`, giving transport failures another go before letting them reach the caller.
    ///
    /// A connection reset on mobile data is weather, not information: the request was fine and
    /// asking again generally answers. Only transport failures, though — an HTTP error status is an
    /// answer, and a timeout is this app's own decision that the request had long enough (retrying
    /// it multiplies the ceiling instead of sharing it). Cancellation isn't caught at all: the sleep
    /// throws when the task is cancelled, so a search the user has typed past stops here.
    func withRetry<T>(attempts: Int = 3, _ block: () async throws -> T) async throws -> T {
        var backoff = retryBaseDelay
        for _ in 0..<(attempts - 1) {
            do {
                return try await block()
            } catch let error as URLError where error.code == .timedOut || error.code == .cancelled {
                DebugLog.d(Self.log, "not retrying: \(error.localizedDescription)")
                throw error
            } catch let error as URLError {
                DebugLog.d(Self.log, "retrying: \(error.localizedDescription)")
            }
            try await Task.sleep(for: backoff)
            backoff *= 2
        }
        return try await block()
    }

    /// A POST to `youtubei/v1/<endpoint>` as the current listener.
    ///
    /// This is the common authenticated request path: Home, Library, likes, playlists, account menus
    /// and all their continuations pass through it. Waiting for the session scope here makes the
    /// right identity process-wide rather than a special case implemented by whichever screen
    /// happened to open first.
    func postMusic(
        _ endpoint: String,
        query: [URLQueryItem] = [],
        body extras: InnerTubeJSONObject = InnerTubeJSONObject()
    ) async throws -> InnerTubeJSON {
        if cookie != nil { await ensureSessionScope() }
        let session = scope
        let clientVersion = webRemixVersion
        let language = languageProvider()
        let response = try await withRetry { () async throws -> InnerTubeJSON in
            var components = URLComponents(string: "\(Self.musicBase)/\(endpoint)")!
            components.queryItems = [URLQueryItem(name: "prettyPrint", value: "false"), URLQueryItem(name: "hl", value: language)] + query
            var request = URLRequest(url: components.url!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(InnerTubeLocale.acceptLanguage(for: language), forHTTPHeaderField: "Accept-Language")
            request.setValue(VibraMusicHTTP.UserAgent.chromeDesktop, forHTTPHeaderField: "User-Agent")
            request.setValue(Self.musicOrigin, forHTTPHeaderField: "X-Origin")
            request.setValue(Self.musicOrigin, forHTTPHeaderField: "Origin")
            request.setValue("\(Self.musicOrigin)/", forHTTPHeaderField: "Referer")
            // Stats pings are only honoured for a session Google recognises as a real client, so
            // identify as one here too.
            request.setValue(Self.webRemixClientId, forHTTPHeaderField: "X-YouTube-Client-Name")
            request.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
            if let visitorData { request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id") }
            for (name, value) in signedHeaders(origin: Self.musicOrigin, session: session, includePageId: true, includeAuthUser: true) {
                request.setValue(value, forHTTPHeaderField: name)
            }
            request.httpBody = requestBody(
                clientVersion: clientVersion,
                language: language,
                // Only ever a value read back from a shell that said it was signed in (or a channel
                // the listener picked): Google answers an `onBehalfOfUser` it cannot tie to the
                // cookie with 401, so a guess here would take the whole app down.
                onBehalfOfUser: cookie == nil ? nil : dataSyncId(for: session),
                extras: extras
            ).serialized()
            return try Self.jsonObject(from: try await send(request, label: endpoint).0, label: endpoint)
        }
        if visitorData == nil, let fresh = response.o("responseContext").s("visitorData") {
            visitorData = fresh
        }
        return response
    }

    /// Like ``postMusic(_:query:body:)`` but deliberately without the session, so YouTube Music does
    /// not record the call against any account — for typeahead lookups whose intermediate keystrokes
    /// must stay anonymous.
    func postMusicAnonymous(_ endpoint: String, body extras: InnerTubeJSONObject) async throws -> InnerTubeJSON {
        let clientVersion = webRemixVersion
        return try await withRetry { () async throws -> InnerTubeJSON in
            var components = URLComponents(string: "\(Self.musicBase)/\(endpoint)")!
            components.queryItems = [URLQueryItem(name: "prettyPrint", value: "false")]
            var request = URLRequest(url: components.url!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(VibraMusicHTTP.UserAgent.chromeDesktop, forHTTPHeaderField: "User-Agent")
            request.setValue(Self.musicOrigin, forHTTPHeaderField: "X-Origin")
            request.setValue(Self.musicOrigin, forHTTPHeaderField: "Origin")
            request.setValue("\(Self.musicOrigin)/", forHTTPHeaderField: "Referer")
            request.setValue(Self.webRemixClientId, forHTTPHeaderField: "X-YouTube-Client-Name")
            request.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
            if let visitorData { request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id") }
            // No Cookie / Authorization headers, and no onBehalfOfUser — no account context.
            request.httpBody = requestBody(clientVersion: clientVersion, language: "en", onBehalfOfUser: nil, extras: extras).serialized()
            return try Self.jsonObject(from: try await send(request, label: endpoint).0, label: endpoint)
        }
    }

    private func requestBody(
        clientVersion: String,
        language: String,
        onBehalfOfUser: String?,
        extras: InnerTubeJSONObject
    ) -> InnerTubeJSON {
        var client = InnerTubeJSONObject([
            "clientName": "WEB_REMIX",
            "clientVersion": .string(clientVersion),
            "hl": .string(language),
            "gl": .string(Self.region),
        ])
        if let visitorData { client["visitorData"] = .string(visitorData) }
        var user = InnerTubeJSONObject(["lockedSafetyMode": false])
        if let onBehalfOfUser { user["onBehalfOfUser"] = .string(onBehalfOfUser) }
        var body = InnerTubeJSONObject([
            "context": .object(InnerTubeJSONObject([
                "client": .object(client),
                "user": .object(user),
                "request": ["useSsl": true],
            ])),
        ])
        for (key, value) in extras.entries { body[key] = value }
        return .object(body)
    }

    static func jsonObject(from data: Data, label: String) throws -> InnerTubeJSON {
        let parsed: InnerTubeJSON
        do {
            parsed = try InnerTubeJSON.parse(data)
        } catch {
            throw InnerTubeError.invalidResponse("\(label): \(error)")
        }
        guard case .object = parsed else { throw InnerTubeError.invalidResponse("\(label): not a JSON object") }
        return parsed
    }

    func requireSession() throws {
        if cookie == nil { throw InnerTubeError.notSignedIn }
    }

    func now() -> Date { clock() }
}

extension Optional where Wrapped == String {
    /// The value unless nil or blank (Kotlin's `?.takeIf { it.isNotBlank() }`).
    var nonBlank: String? {
        guard let self, !self.isBlankText else { return nil }
        return self
    }
}
