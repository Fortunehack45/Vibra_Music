import VibraMusicCore
import Foundation
import WebKit

/// Mints BotGuard PoTokens in a hidden `WKWebView`. Port of `PoTokenGenerator` +
/// `PoTokenWebView` (PORTING.md §4: "Hidden WKWebView with evaluateJavaScript").
///
/// One web view is kept and reused: BotGuard runs once per visitor id (the streaming token is
/// minted exactly once, right after), and each track then only mints a video-bound token. The
/// web view is rebuilt when the visitor id changes, when its integrity token nears expiry, when
/// its content process dies, or after a mint fails on an instance that was not fresh.
///
/// iOS caveats, unverified on a device (the live test runs on macOS): WebKit may suspend a web
/// view's content process while the app is in the background, and may throttle timers in a web
/// view that is in no window (BotGuard polls with `setInterval`). A mint then times out, the
/// instance is marked dead, and the next call rebuilds it; callers get `nil` and walk on without
/// a token, which is what the timeout exists for. If throttling shows up, `attachWebView` lets
/// the app put the (1×1, transparent) web view into its window.
@MainActor
public final class WebViewPoTokenProvider: StreamPoTokenProvider {
    private let session: URLSession
    private let timeout: TimeInterval
    private let attachWebView: (@MainActor @Sendable (WKWebView) -> Void)?
    private var web: PoTokenWebSession?
    private var webSessionId: String?
    private var streamingToken: String?
    private var creating: Task<PoTokenWebSession, Error>?
    /// A web engine that cannot run our static page at all; nothing will change that this run.
    private var webViewBroken = false
    /// Bumped by `close()`. A call a timeout gave up on keeps running; it must not commit the
    /// instance it finishes building after the provider was closed.
    private var closes = 0

    /// - Parameters:
    ///   - timeout: the whole budget for one call, web view creation included. Healthy cold start
    ///     (web view + BotGuard + mint) is 2–5 s; past 8 s the walk is better off moving on
    ///     without a token than waiting.
    ///   - attachWebView: called with each new web view before its page loads, for an app that
    ///     needs it in a view hierarchy. The web view is removed from its superview when closed.
    public nonisolated init(
        session: URLSession = VibraMusicHTTP.session, timeout: TimeInterval = 8,
        attachWebView: (@MainActor @Sendable (WKWebView) -> Void)? = nil
    ) {
        self.session = session
        self.timeout = timeout
        self.attachWebView = attachWebView
    }

    public func poToken(videoId: String, visitorData: String) async throws -> StreamPoToken? {
        if webViewBroken { return nil }
        do {
            return try await withStreamTimeout(timeout) { @MainActor in
                try await self.mint(videoId: videoId, sessionId: visitorData, forceRecreate: false)
            }
        } catch is StreamTimeoutError {
            // The content process can be culled by the OS, leaving a call hung for good.
            streamLog.warning("PoToken generation timed out after \(self.timeout, privacy: .public)s")
            await close()
            return nil
        } catch let error as StreamPoTokenError {
            if case .badWebView = error {
                streamLog.error("PoToken web view unusable: \(error.localizedDescription, privacy: .public)")
                webViewBroken = true
                return nil
            }
            throw error
        }
    }

    /// Loads BotGuard and mints the session's streaming token now, so the first track only
    /// pays for its own video-bound token.
    public func prewarm(visitorData: String) async {
        if webViewBroken { return }
        do {
            _ = try await withStreamTimeout(max(timeout, 20)) { @MainActor in
                try await self.instance(for: visitorData, forceRecreate: false)
            }
        } catch {
            streamLog.warning("PoToken warm-up failed: \(error.localizedDescription, privacy: .public)")
            if case StreamPoTokenError.badWebView = error { webViewBroken = true }
        }
    }

    public func close() async {
        closes += 1
        creating?.cancel()
        creating = nil
        web?.close()
        web = nil
        webSessionId = nil
        streamingToken = nil
    }

    private func mint(videoId: String, sessionId: String, forceRecreate: Bool) async throws -> StreamPoToken {
        let closesAtStart = closes
        let (instance, streaming, recreated) = try await instance(for: sessionId, forceRecreate: forceRecreate)
        let videoToken: String
        do {
            videoToken = try await instance.mint(identifier: videoId)
        } catch {
            // A fresh instance failing is the answer; an old one may just have lost its page
            // (backgrounding), so it gets exactly one rebuild.
            // A rebuild after `close()` would commit a web view nothing owns any more.
            if recreated || closes != closesAtStart { throw error }
            streamLog.warning("PoToken mint failed; recreating the web view")
            return try await mint(videoId: videoId, sessionId: sessionId, forceRecreate: true)
        }
        // The binding mirrors Android's `PoTokenGenerator` exactly: the session-bound token
        // (minted against the visitor id) goes in the player request, the video-bound token on
        // the media URL as `pot`. (NewPipe/yt-dlp document it the other way round; measured
        // 2026-09-26 googlevideo served WEB_REMIX URLs in full with either token, no token, or
        // a garbage one, so the measurement cannot settle it and consistency with the shipped
        // Android app wins.)
        return StreamPoToken(playerRequestToken: streaming, streamingDataToken: videoToken)
    }

    private func instance(
        for sessionId: String, forceRecreate: Bool
    ) async throws -> (PoTokenWebSession, String, Bool) {
        let closesAtStart = closes
        if !forceRecreate, let web, let streamingToken, webSessionId == sessionId, !web.isExpired, !web.isDead {
            return (web, streamingToken, false)
        }
        // Clear the committed state before the fallible steps: a failure below must leave the
        // next call rebuilding, never pairing a new session id with a stale streaming token.
        web?.close()
        web = nil
        webSessionId = nil
        streamingToken = nil
        let task: Task<PoTokenWebSession, Error>
        if let creating {
            task = creating
        } else {
            let session = self.session
            let attach = attachWebView
            task = Task { @MainActor in try await PoTokenWebSession.create(session: session, attach: attach) }
            creating = task
        }
        let fresh: PoTokenWebSession
        do {
            fresh = try await task.value
        } catch {
            if creating == task { creating = nil }
            throw error
        }
        if creating == task { creating = nil }
        // The streaming token has to be minted exactly once, before any video token.
        let streaming: String
        do {
            streaming = try await fresh.mint(identifier: sessionId)
        } catch {
            fresh.close()
            throw error
        }
        guard closes == closesAtStart else {
            fresh.close()
            throw StreamPoTokenError.failed("the provider was closed while this instance was being built")
        }
        web = fresh
        webSessionId = sessionId
        streamingToken = streaming
        return (fresh, streaming, true)
    }
}

/// One hidden web view with BotGuard loaded and a minter ready.
@MainActor
final class PoTokenWebSession: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private(set) var isDead = false
    private var closed = false
    private var expiresAt = Date.distantFuture

    /// The static page either loads or it does not; past this it never will.
    static let pageLoadTimeout: TimeInterval = 20

    var isExpired: Bool { Date() >= expiresAt }

    private init(webView: WKWebView) {
        self.webView = webView
        super.init()
        webView.navigationDelegate = self
    }

    /// Loads the page, runs BotGuard and creates the minter. The two BotGuard round trips are
    /// made from Swift, as Android made them from OkHttp: the page itself never needs network.
    static func create(session: URLSession, attach: (@MainActor @Sendable (WKWebView) -> Void)?) async throws -> PoTokenWebSession {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // BotGuard never needs media. Make it explicit rather than inheriting WebKit's defaults.
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        // No network isolation (Android's `blockNetworkLoads = true` has no direct equivalent
        // worth using): WebKit consults the navigation policy for the initial `loadHTMLString`
        // navigation too, so denying http(s) breaks the page load with no callback. It is not
        // needed either — the page is static with no remote subresources (verified: the HTML
        // references no remote URL) and BotGuard's two round trips go through `URLSession`
        // from Swift, so the web view itself has nothing to fetch.
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        webView.customUserAgent = PoTokenChallenge.userAgent
        attach?(webView)
        let instance = PoTokenWebSession(webView: webView)
        do {
            try await instance.loadPage()
            let challengeBody = try await botguardRequest(
                PoTokenChallenge.createURL, body: [PoTokenChallenge.requestKey], session: session
            )
            let challenge = try PoTokenChallenge.parseChallengeData(challengeBody)
            let botguardResponse = try await instance.call(
                """
                const result = await runBotGuard(data);
                window.webPoSignalOutput = result.webPoSignalOutput;
                return result.botguardResponse;
                """,
                arguments: ["data": challenge],
                initializing: true
            )
            guard let response = botguardResponse as? String, !response.isEmpty else {
                throw StreamPoTokenError.failed("BotGuard produced no response")
            }
            let integrityBody = try await botguardRequest(
                PoTokenChallenge.generateITURL, body: [PoTokenChallenge.requestKey, response], session: session
            )
            let (token, lifetime) = try PoTokenChallenge.parseIntegrityTokenData(integrityBody)
            // Ten minutes of margin, as Android leaves.
            instance.expiresAt = Date().addingTimeInterval(TimeInterval(lifetime) - 600)
            _ = try await instance.call(
                """
                await createPoTokenMinter(window.webPoSignalOutput, new Uint8Array(token));
                return true;
                """,
                arguments: ["token": token.map(Int.init)],
                initializing: true
            )
            return instance
        } catch {
            instance.close()
            throw error
        }
    }

    /// A token bound to `identifier` (a visitor id or a videoId).
    func mint(identifier: String) async throws -> String {
        if isDead || closed { throw StreamPoTokenError.failed("PoToken web view is dead; it must be recreated") }
        let result = try await call(
            """
            const token = await obtainPoToken(new Uint8Array(identifier));
            return Array.from(token);
            """,
            arguments: ["identifier": PoTokenChallenge.identifierBytes(identifier).map(Int.init)],
            initializing: false
        )
        guard let numbers = result as? [NSNumber], !numbers.isEmpty else {
            throw StreamPoTokenError.failed("obtainPoToken returned no bytes")
        }
        return PoTokenChallenge.tokenString(numbers.map { UInt8(truncatingIfNeeded: $0.intValue) })
    }

    func close() {
        guard !closed else { return }
        closed = true
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
        webView.removeFromSuperview()
        completeLoad(.failure(StreamPoTokenError.failed("closed")))
    }

    /// Resumes the page-load waiter, if any, exactly once: `close`, the navigation
    /// callbacks and the load timeout below can race, and a second resume traps.
    private func completeLoad(_ result: Result<Void, Error>) {
        guard let continuation = loadContinuation else { return }
        loadContinuation = nil
        continuation.resume(with: result)
    }

    /// The static page, with a hard deadline. `WKWebView` gives no callback when a load
    /// stalls without failing (a throttled content process, a denied initial navigation),
    /// and an unresumed continuation hangs the mint past every outer timeout that only
    /// cancels the waiting task — so a watchdog fails the wait itself here.
    private func loadPage() async throws {
        let watchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.pageLoadTimeout * 1_000_000_000))
            self.completeLoad(.failure(StreamPoTokenError.failed("BotGuard page load timed out")))
        }
        defer { watchdog.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.loadContinuation = continuation
            self.webView.loadHTMLString(PoTokenPage.html, baseURL: URL(string: "https://www.youtube.com"))
        }
    }

    /// Runs `body` as an async function in the page. Errors thrown before the minter exists
    /// may mean the engine cannot run our page (`badWebView`); after, they are Google's
    /// remotely served code failing, which is transient.
    private func call(_ body: String, arguments: [String: Any], initializing: Bool) async throws -> Any? {
        do {
            return try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
        } catch {
            let message = Self.describe(error)
            if !initializing { isDead = true }
            throw initializing ? StreamPoTokenError.fromJavaScriptError(message) : .failed(message)
        }
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        let detail = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String
        return detail ?? nsError.localizedDescription
    }

    private static func botguardRequest(_ url: URL, body: [String], session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue(PoTokenChallenge.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue(PoTokenChallenge.googleAPIKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("grpc-web-javascript/0.1", forHTTPHeaderField: "x-user-agent")
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        // An empty 200 is a failure too, or it fails later with a murkier parse error.
        guard code == 200, !data.isEmpty else {
            throw StreamPoTokenError.failed("Invalid botguard response (code=\(code), \(data.count) bytes)")
        }
        return data
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        completeLoad(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        completeLoad(.failure(StreamPoTokenError.failed(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        completeLoad(.failure(StreamPoTokenError.failed(error.localizedDescription)))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Transient (memory pressure), not a broken engine.
        streamLog.error("PoToken web content process terminated")
        isDead = true
        completeLoad(.failure(StreamPoTokenError.failed("web content process terminated")))
    }
}

// MARK: - Timeout

struct StreamTimeoutError: Error {}

/// Runs `operation`, giving up after `seconds`. The operation is cancelled, but work that does
/// not observe cancellation (a web view call) is only abandoned — callers clean up after it.
///
/// Not a task group racing a sleep: a group waits for every child at its closing brace, so the
/// timeout only arrived once the web view call it was meant to cut short came back.
func withStreamTimeout<T: Sendable>(
    _ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let gate = StreamTimeoutGate<T>()
    let work = Task {
        do {
            let value = try await operation()
            gate.finish(.success(value))
        } catch {
            gate.finish(.failure(error))
        }
    }
    let timer = Task {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        gate.finish(.failure(StreamTimeoutError()))
    }
    defer {
        work.cancel()
        timer.cancel()
    }
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            gate.wait(continuation)
        }
    } onCancel: {
        gate.finish(.failure(CancellationError()))
    }
}

/// Answers `withStreamTimeout`'s caller exactly once: with the first of the result, the timeout
/// and a cancellation, even when that comes before the caller's continuation is stored.
private final class StreamTimeoutGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var outcome: Result<T, Error>?

    func wait(_ continuation: CheckedContinuation<T, Error>) {
        let known: Result<T, Error>? = lock.withLock {
            if self.outcome == nil { self.continuation = continuation }
            return self.outcome
        }
        if let known { continuation.resume(with: known) }
    }

    func finish(_ result: Result<T, Error>) {
        let waiting: CheckedContinuation<T, Error>? = lock.withLock {
            guard self.outcome == nil else { return nil }
            self.outcome = result
            defer { self.continuation = nil }
            return self.continuation
        }
        waiting?.resume(with: result)
    }
}
