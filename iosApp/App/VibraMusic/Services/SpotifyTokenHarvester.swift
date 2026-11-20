import Canvas
import Foundation
import WebKit

/// Loads open.spotify.com offscreen with the listener's `sp_dc` cookie and reads the token the
/// web player mints for itself (Android: `SpotifyToken.harvestViaWebView`).
struct SpotifyTokenHarvester: CanvasSpotifyTokenHarvester {
    static let timeout: Duration = .seconds(20)

    func harvest(spDcCookie: String) async -> CanvasHarvestedToken? {
        await Self.harvest(cookie: spDcCookie)
    }

    @MainActor private static func harvest(cookie: String) async -> CanvasHarvestedToken? {
        guard let url = URL(string: "https://open.spotify.com/"),
              let session = HTTPCookie(properties: [
                  .name: "sp_dc", .value: cookie, .domain: ".spotify.com", .path: "/", .secure: "TRUE",
              ])
        else { return nil }
        let bridge = Bridge()
        let configuration = WKWebViewConfiguration()
        // Fresh storage every time: the player skips /api/token when it already holds a live token,
        // and the hook would have nothing to see.
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(bridge, name: Bridge.name)
        configuration.userContentController.addUserScript(WKUserScript(
            source: CanvasSpotifyTokenStore.harvestHookScript(bridge: Bridge.name),
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        await configuration.websiteDataStore.httpCookieStore.setCookie(session)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = CanvasSpotifyTokenStore.webPlayerUserAgent
        defer {
            webView.stopLoading()
            configuration.userContentController.removeScriptMessageHandler(forName: Bridge.name)
        }
        webView.load(URLRequest(url: url))
        return await bridge.token(within: timeout)
    }

    /// Receives the raw `/api/token` bodies the hook script posts.
    @MainActor private final class Bridge: NSObject, WKScriptMessageHandler {
        static let name = "Vibra MusicSpotifyTokenBridge"
        private var waiter: CheckedContinuation<CanvasHarvestedToken?, Never>?

        func token(within timeout: Duration) async -> CanvasHarvestedToken? {
            await withCheckedContinuation { continuation in
                waiter = continuation
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.finish(nil)
                }
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? String,
                  let token = CanvasSpotifyTokenStore.harvestedToken(in: body) else { return }
            finish(token)
        }

        private func finish(_ token: CanvasHarvestedToken?) {
            waiter?.resume(returning: token)
            waiter = nil
        }
    }
}
