import VibraMusicCore
import InnerTube
import SwiftUI
import WebKit

/// In-app Discord sign-in for Rich Presence (ports auth/DiscordLoginScreen.kt and its full-screen
/// host in MainActivity: a close button, "Sign in to Discord", and the page).
///
/// discord.com/login runs in a web view, so 2-step verification and passkeys work. Once the page
/// leaves the sign-in flow the token is lifted out of it — once — and stored. There is no OAuth
/// scope that lets a third party set a user's presence, so the account's own token is the only
/// credential that can; it goes to the Keychain and is only ever sent to Discord.
struct DiscordLoginScreen: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var controller: DiscordLoginWebController
    private let startsLoading: Bool

    /// - Parameters:
    ///   - startsLoading: false keeps the page from loading (tests draw the screen offline).
    ///   - controller: tests pass one they can watch; nil makes the screen's own.
    init(startsLoading: Bool = true, controller: DiscordLoginWebController? = nil) {
        self.startsLoading = startsLoading
        _controller = State(initialValue: controller ?? DiscordLoginWebController())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: AppSymbol.close)
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(.primary)
                .accessibilityLabel(L10n.close)
                Text(L10n.signInDiscord)
                    .font(AppTheme.Typeface.title)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.bar)
            DiscordLoginWebView(controller: controller)
                .ignoresSafeArea(edges: .bottom)
                // Hidden once the token is in hand, so the Discord client we're sitting on doesn't
                // flash up as the sheet goes away.
                .opacity(controller.captured ? 0 : 1)
        }
        .background(Color(.systemBackground))
        .onAppear {
            controller.resume()
            controller.onTokenCaptured = { token in
                settings.discordToken = token
                dismiss()
            }
            if startsLoading { controller.start() }
        }
        .onDisappear { controller.tearDown() }
    }
}

/// Drives the Discord login page and harvests the token when it leaves the sign-in flow.
@MainActor
@Observable
final class DiscordLoginWebController: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private(set) var captured = false
    /// True between ``tearDown()`` and ``resume()``: the page is not loading and its media is suspended.
    private(set) var isTornDown = false
    @ObservationIgnored var onTokenCaptured: ((String) -> Void)?
    @ObservationIgnored private var attempts = 0
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var loadWasInterrupted = false
    /// Where the interrupted load was heading (or the route the SPA had pushed), so ``resume()`` can open it.
    @ObservationIgnored private var interruptedURL: URL?
    /// The top-level GET navigation in flight, or nil when none is.
    @ObservationIgnored private var inFlightURL: URL?
    @ObservationIgnored private var urlObservation: NSKeyValueObservation?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // Present as Safari. A bare WKWebView's user agent has no `Version/… Safari/…`, and Discord
        // serves an unsupported-browser shell to agents it can't place (Android had the mirror-image
        // problem with its WebView tokens).
        configuration.applicationNameForUserAgent = YouTubeWebLogin.safariApplicationName
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        // The one signal that also fires for `pushState`: Discord's client routes itself from the
        // login form to the app without a real navigation.
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] view, _ in
            let url = view.url
            Task { @MainActor in self?.urlChanged(url) }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        webView.load(URLRequest(url: DiscordLogin.loginURL))
    }

    private func urlChanged(_ url: URL?) {
        if DiscordLogin.isSignedIn(url) { harvestToken() }
    }

    /// Reads the token, retrying while the client is still booting (the key isn't written yet).
    func harvestToken() {
        guard !captured, !reading else { return }
        guard attempts < DiscordLogin.maxTokenAttempts else {
            DebugLog.w("Discord", "no token in localStorage after \(attempts) tries")
            return
        }
        attempts += 1
        reading = true
        webView.evaluateJavaScript(DiscordLogin.tokenScript) { [weak self] result, _ in
            Task { @MainActor in self?.didRead(result) }
        }
    }

    private func didRead(_ result: Any?) {
        reading = false
        guard !captured else { return }
        guard let token = DiscordLogin.token(fromScriptResult: result) else {
            Task {
                try? await Task.sleep(for: DiscordLogin.tokenRetry)
                harvestToken()
            }
            return
        }
        captured = true
        DebugLog.d("Discord", "token captured after \(attempts) read(s)")
        onTokenCaptured?(token)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        inFlightURL = nil
        urlChanged(webView.url)
    }

    /// Stops any media a page started, so a track played inside the Discord login page cannot outlive
    /// the screen, and stops the page loading. Called when the screen goes away; ``resume()`` undoes
    /// it if the screen comes back mid sign-in.
    func tearDown() {
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
    /// still loading is opened again, so the login carries on instead of stalling. It is opened as a
    /// GET of the URL it was heading for (or of the route Discord's client had pushed), never
    /// `reload()`, which replays the committed document and drops that route.
    func resume() {
        guard isTornDown else { return }
        isTornDown = false
        webView.setAllMediaPlaybackSuspended(false)
        guard loadWasInterrupted else { return }
        loadWasInterrupted = false
        webView.load(URLRequest(url: interruptedURL ?? DiscordLogin.loginURL))
    }

    // The completion-handler form, not `async`: the async one answers from a main-actor task, so the
    // navigation waits until the main queue is free to run it.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame?.isMainFrame == true {
            inFlightURL = navigationAction.request.httpMethod == "GET" ? navigationAction.request.url : nil
        }
        decisionHandler(.allow)
    }
}

/// Hosts the controller's `WKWebView`. Back and forward are the edge swipes (Android's BackHandler).
struct DiscordLoginWebView: UIViewRepresentable {
    let controller: DiscordLoginWebController

    func makeUIView(context: Context) -> WKWebView {
        let webView = controller.webView
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
