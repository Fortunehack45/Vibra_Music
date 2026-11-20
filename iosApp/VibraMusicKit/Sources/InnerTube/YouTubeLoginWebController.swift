#if canImport(WebKit)
import Foundation
import WebKit
import VibraMusicCore

// The WebKit half of auth/YtMusicLoginScreen.kt and auth/WebSession.kt (BrowserSession). The app's
// sign-in screen hosts `webView` (a UIViewRepresentable) and a Confirm button wired to `capture()`.

/// The in-app browser's own Google login, which is not the app's.
///
/// These are separate stores and the difference is invisible until it bites: signing out forgets the
/// cookie the app makes requests with and leaves the browser's copy untouched, so the next sign-in
/// is waved straight through as the account just signed out of. Hence clearing on sign-out and
/// before every fresh sign-in.
@MainActor
public enum YouTubeBrowserCookies {
    /// Forgets the Google login the browser holds — Google's and YouTube's cookies only, never the
    /// Discord or Last.fm logins sharing the jar. Deleting is local: Google's logout endpoint is never
    /// visited, because that would invalidate previously saved accounts on Google's side.
    public static func clearGoogleCookies(in store: WKHTTPCookieStore) async {
        let cookies = await store.allCookies()
        var cleared = 0
        for cookie in cookies where YouTubeWebLogin.isGoogleCookie(cookie) {
            await store.deleteCookie(cookie)
            cleared += 1
        }
        DebugLog.d("InnerTube", "cleared \(cleared) browser cookies for Google")
    }

    /// Makes the in-app YouTube page use a saved account, without asking Google to sign any account
    /// out: the jar's Google cookies are replaced by that account's snapshot. The browser has one jar,
    /// so opening the channel picker after selecting an older account would otherwise show whichever
    /// account happened to sign in most recently.
    public static func installGoogleCookies(_ cookieHeader: String, in store: WKHTTPCookieStore) async {
        await clearGoogleCookies(in: store)
        let cookies = YouTubeWebLogin.browserCookies(fromHeader: cookieHeader)
        for cookie in cookies { await store.setCookie(cookie) }
        DebugLog.d("InnerTube", "restored \(cookies.count) browser cookies for the selected account")
    }

    /// The default data store's jar (the one the login screen uses).
    public static var defaultStore: WKHTTPCookieStore { WKWebsiteDataStore.default().httpCookieStore }
}

/// Drives the sign-in / channel-switch web view: what to load, when confirmation becomes possible,
/// and how the session is taken from the page. The credential itself never passes through app code
/// other than to be stored.
@MainActor
public final class YouTubeLoginWebController: NSObject, WKNavigationDelegate {
    public let mode: WebSessionMode
    public let webView: WKWebView
    private let initialCookie: String?

    /// True once a YouTube Music page has finished loading and confirmation can be offered.
    public private(set) var isPageReady = false {
        didSet { if oldValue != isPageReady { onPageReadyChange?(isPageReady) } }
    }

    /// True between ``tearDown()`` and ``resume()``: the page is not loading and its media is suspended.
    public private(set) var isTornDown = false
    private var loadWasInterrupted = false
    /// Where the interrupted load was heading, so ``resume()`` can open it as a plain GET.
    private var interruptedURL: URL?
    /// The top-level GET navigation in flight, or nil when none is (a form POST is never recorded).
    private var inFlightURL: URL?

    /// Told whenever ``isPageReady`` changes.
    public var onPageReadyChange: ((Bool) -> Void)?

    /// - Parameters:
    ///   - mode: sign in fresh, or switch the channel of an existing account.
    ///   - initialCookie: for ``WebSessionMode/switchChannel``, the saved account's cookie snapshot to
    ///     install before opening YouTube Music.
    ///   - dataStore: the website data store; nil for the default one, which the app uses.
    public init(mode: WebSessionMode, initialCookie: String? = nil, dataStore: WKWebsiteDataStore? = nil) {
        self.mode = mode
        self.initialCookie = initialCookie
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore ?? .default()
        configuration.applicationNameForUserAgent = YouTubeWebLogin.safariApplicationName
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    /// Prepares the cookie jar and loads the start page. Clearing the local jar is enough to show a
    /// fresh Google login; switching channel installs the saved account's cookies first.
    public func start() async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        switch mode {
        case .signIn:
            await YouTubeBrowserCookies.clearGoogleCookies(in: store)
        case .switchChannel:
            if let initialCookie { await YouTubeBrowserCookies.installGoogleCookies(initialCookie, in: store) }
        }
        webView.load(URLRequest(url: YouTubeWebLogin.startURL(for: mode)))
    }

    /// Takes the session from the page as it stands — call when the listener confirms. A failure
    /// means "leave the screen open".
    public func capture() async -> Result<CapturedSession, WebSessionCaptureFailure> {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let header = YouTubeWebLogin.cookieHeader(from: cookies, for: YouTubeWebLogin.musicURL)
        guard let header, SAPISIDAuth.hasSigningSecret(header) else { return .failure(.noSigningCookie) }
        // The completion-handler form, because a page without ytcfg answers null, which the async
        // overload reports as an error rather than as the fine answer it is.
        let probe: [String: String]? = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(YouTubeWebLogin.ytcfgProbeScript) { result, _ in
                continuation.resume(returning: YouTubeWebLogin.probeValues(result))
            }
        }
        let outcome = YouTubeWebLogin.captureSession(cookieHeader: header, probeResult: probe)
        if case .failure = outcome {
            DebugLog.w("InnerTube", "confirmation requested before the page exposed a signed-in identity")
        }
        return outcome
    }

    // MARK: WKNavigationDelegate

    /// Stops any media a page started, so a track played inside the sign-in web view cannot outlive
    /// the screen, and stops the page loading. Called when the screen goes away; ``resume()``
    /// undoes it if the screen comes back mid sign-in.
    public func tearDown() {
        if !isTornDown {
            loadWasInterrupted = webView.isLoading
            interruptedURL = inFlightURL ?? webView.url
        }
        isTornDown = true
        webView.pauseAllMediaPlayback()
        webView.setAllMediaPlaybackSuspended(true)
        webView.stopLoading()
    }

    /// Undoes ``tearDown()`` when the screen comes back: media may play again, and a page that was
    /// still loading is opened again, so a multi-step sign-in carries on instead of stalling. It is
    /// opened as a GET of the URL it was heading for, never `reload()`, which would replay the last
    /// committed request (a form POST Google already received).
    public func resume() {
        guard isTornDown else { return }
        isTornDown = false
        webView.setAllMediaPlaybackSuspended(false)
        guard loadWasInterrupted else { return }
        loadWasInterrupted = false
        webView.load(URLRequest(url: interruptedURL ?? YouTubeWebLogin.startURL(for: mode)))
    }

    // The completion-handler form, not `async`: the async one answers from a main-actor task, so the
    // navigation waits until the main queue is free to run it.
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame?.isMainFrame == true {
            inFlightURL = navigationAction.request.httpMethod == "GET" ? navigationAction.request.url : nil
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        inFlightURL = nil
        // Reaching the Music origin only enables confirmation. A multi-channel login can still be
        // waiting for the listener to choose an identity on this very page.
        isPageReady = YouTubeWebLogin.isReadyForConfirmation(webView.url)
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isPageReady = false
    }
}
#endif
