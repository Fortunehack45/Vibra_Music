import VibraMusicCore
import InnerTube
import SwiftUI
import WebKit

/// Signing in to YouTube Music (ports auth/YtMusicLoginScreen.kt and the full-screen host MainActivity
/// wraps it in: a close button, the title, and — once YouTube Music itself has loaded — a hint and
/// "Use this profile").
///
/// Google's real sign-in page runs in a web view, so 2-step verification and passkeys work as they
/// do in Safari. When Google hands back to music.youtube.com nothing is saved yet: a login with
/// several channels can still pick its Personal or Brand profile on that page (YouTube Music's own
/// avatar menu → Switch account). "Use this profile" takes the session from the page as it then
/// stands — the cookies from WebKit's jar and the identity from the page's `ytcfg` — and the account
/// manager checks it answers as that profile before storing anything. A refusal leaves the page
/// open with "Couldn't read this profile…" in place of the hint.
struct GoogleSignInScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var session: GoogleSignInModel
    private let startsLoading: Bool

    /// - Parameters:
    ///   - startsLoading: false keeps the page from loading (tests draw the screen offline).
    ///   - session: tests pass one over a controller they can watch; nil makes the screen's own.
    init(startsLoading: Bool = true, session: GoogleSignInModel? = nil) {
        self.startsLoading = startsLoading
        _session = State(initialValue: session ?? GoogleSignInModel())
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            GoogleSignInWebView(controller: session.controller)
                .ignoresSafeArea(edges: .bottom)
        }
        .background(Color(.systemBackground))
        .task {
            if startsLoading { await session.start() }
        }
        // Both ends of one pair: whatever takes the screen off and back on (a tab switch) must not
        // leave the page stopped.
        .onAppear { session.controller.resume() }
        .onDisappear { session.controller.tearDown() }
    }

    /// Android's row: close, the title with the hint under it, and the confirm button on the end.
    private var header: some View {
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

            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.signInYoutubeMusic)
                    .font(AppTheme.Typeface.title)
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                if session.pageReady {
                    Text(session.captureFailed ? L10n.profileUnavailable : L10n.switchProfileHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .accessibilityIdentifier("signIn.hint")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if session.pageReady {
                Button(session.confirming ? L10n.checking : L10n.useThisProfile) {
                    Task { await confirm() }
                }
                .font(.body.weight(.semibold))
                .disabled(session.confirming)
                .padding(.horizontal, 8)
                .accessibilityIdentifier("signIn.useThisProfile")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
        .animation(.easeInOut(duration: 0.2), value: session.pageReady)
    }

    private func confirm() async {
        let accepted = await session.confirm { captured in
            await model.accounts.handleWebSession(captured, mode: .signIn)
        }
        guard accepted else { return }
        Haptics.shared.play(.toggleOn)
        GoogleSignInModel.landAfterSignIn(router)
        dismiss()
    }
}

/// The sign-in screen's state: the WebKit controller, whether YouTube Music has loaded (which
/// reveals the confirm button), and a confirmation in flight or refused.
@MainActor
@Observable
final class GoogleSignInModel {
    let controller: YouTubeLoginWebController
    private(set) var pageReady = false
    private(set) var confirming = false
    private(set) var captureFailed = false
    private var started = false

    init(controller: YouTubeLoginWebController? = nil) {
        self.controller = controller ?? YouTubeLoginWebController(mode: .signIn)
        self.controller.onPageReadyChange = { [weak self] ready in self?.pageReady = ready }
    }

    /// Clears the browser's Google cookies (never visiting Google's logout, which would sign a
    /// saved account out on Google's side) and opens the sign-in page. Once only.
    func start() async {
        guard !started else { return }
        started = true
        await controller.start()
    }

    /// For tests: YouTube Music has (or hasn't) finished loading.
    func setPageReady(_ ready: Bool) { pageReady = ready }

    /// Takes the session from the page and hands it to `accept`. A page with nothing to take, or a
    /// session the account manager refuses, sets `captureFailed` and leaves the screen open.
    func confirm(capture: (() async -> Result<CapturedSession, WebSessionCaptureFailure>)? = nil,
                 accept: (CapturedSession) async -> Bool) async -> Bool {
        guard !confirming else { return false }
        captureFailed = false
        confirming = true
        defer { confirming = false }
        let outcome: Result<CapturedSession, WebSessionCaptureFailure>
        if let capture { outcome = await capture() } else { outcome = await controller.capture() }
        guard case .success(let captured) = outcome else {
            captureFailed = true
            return false
        }
        let accepted = await accept(captured)
        if !accepted { captureFailed = true }
        return accepted
    }

    /// Where a finished sign-in lands: the Library tab (MainActivity's `selectedTab = 2`).
    static func landAfterSignIn(_ router: AppRouter) {
        router.selectedTab = .library
    }

    /// Signing in from Account & integrations first closes it and Settings under it, as
    /// MainActivity's `onSignIn` does, so the finished sign-in doesn't return to them.
    static func closeAccountPages(_ router: AppRouter) {
        let tab = router.selectedTab
        let path = router.path(for: tab)
        if let first = path.firstIndex(where: { $0 == .settings || $0 == .account }) {
            router.setPath(Array(path[..<first]), for: tab)
        }
    }
}

/// Hosts the controller's `WKWebView`.
struct GoogleSignInWebView: UIViewRepresentable {
    let controller: YouTubeLoginWebController

    func makeUIView(context: Context) -> WKWebView {
        let webView = controller.webView
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
