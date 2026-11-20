import InnerTube
import SwiftUI
import WebKit
import XCTest
@testable import Vibra Music

/// Covering a sign-in screen (a tab switch, a sheet over it) tears its web view down; uncovering it
/// must pick the flow up again without replaying the last committed request, which on Google could
/// be a form POST and on Discord would drop the route the page had pushed.
///
/// These put each screen on screen, tear its controller down mid-load and resume it, as covering
/// and uncovering the screen does, and watch the navigations the page then asks for. They read
/// each navigation at its policy check, which comes before any network: on CI's simulators the web
/// view's own network never reaches a server the test runs. (Toggling the hosted screen off and on
/// in a test did not bring its `.onAppear` back on CI, so the controller is driven directly.)
@MainActor
final class SignInResumeTests: XCTestCase {
    func testUncoveringTheDiscordLoginOpensTheInterruptedPageAsAGet() async throws {
        let controller = DiscordLoginWebController()
        let recorder = NavigationRecorder(original: controller) { controller.webView($0, decidePolicyFor: $1, decisionHandler: $2) }
        try await assertResumeOpensInterruptedPage(webView: controller.webView, recorder: recorder,
                                                   isTornDown: { controller.isTornDown }, cover: controller.tearDown, uncover: controller.resume) {
            DiscordLoginScreen(startsLoading: false, controller: controller)
        }
    }

    func testUncoveringTheGoogleSignInOpensTheInterruptedPageAsAGet() async throws {
        let controller = YouTubeLoginWebController(mode: .signIn, dataStore: .nonPersistent())
        let session = GoogleSignInModel(controller: controller)
        let recorder = NavigationRecorder(original: controller) { controller.webView($0, decidePolicyFor: $1, decisionHandler: $2) }
        try await assertResumeOpensInterruptedPage(webView: controller.webView, recorder: recorder,
                                                   isTornDown: { controller.isTornDown }, cover: controller.tearDown, uncover: controller.resume) {
            GoogleSignInScreen(startsLoading: false, session: session)
        }
    }

    /// Starts a load of `/step` that never answers, covers the screen, uncovers it, and expects
    /// the second navigation to be a fresh GET of `/step`: not a reload, not the start page.
    private func assertResumeOpensInterruptedPage<Screen: View>(
        webView: WKWebView, recorder: NavigationRecorder, isTornDown: () -> Bool,
        cover: @MainActor () -> Void, uncover: @MainActor () -> Void, screen: @escaping () -> Screen,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        // Listening but never answering, wherever the web view's network can reach it: the load
        // is still in flight when the screen is covered.
        let gate = DispatchSemaphore(value: 0)
        let server = try LoopbackHTTPServer { _ in
            _ = gate.wait(timeout: .now() + 30)
            return StubbedHTTPResponse(headers: ["Content-Type": "text/html"], body: Data("<html><body>ok</body></html>".utf8))
        }
        try await server.start(for: self)
        addTeardownBlock { gate.signal() }
        let step = server.baseURL.appendingPathComponent("step")
        webView.navigationDelegate = recorder

        let host = accountHostAndLayOut(screen().accountTestEnvironment(makeAccountTestApp()), file: file, line: line)
        webView.load(URLRequest(url: step))
        await settle { recorder.actions.count == 1 && webView.isLoading }
        XCTAssertEqual(recorder.actions.map(\.url), [Optional(step)], "the page is mid-load", file: file, line: line)
        XCTAssertTrue(webView.isLoading, file: file, line: line)

        cover()
        XCTAssertTrue(isTornDown(), "covering the screen stops the page", file: file, line: line)

        uncover()
        await settle { recorder.actions.count == 2 }
        let resumed = try XCTUnwrap(recorder.actions.dropFirst().first, "uncovering the screen opens a page", file: file, line: line)
        XCTAssertEqual(resumed.url, step, "the interrupted page, not the start page", file: file, line: line)
        XCTAssertEqual(resumed.method, "GET", "as a plain GET", file: file, line: line)
        XCTAssertNotEqual(resumed.type, .reload, "not a reload of the last committed request", file: file, line: line)
        XCTAssertFalse(isTornDown(), file: file, line: line)
        withExtendedLifetime((host, recorder)) {}
    }
}

/// Sits in front of a controller as the web view's navigation delegate: notes each main-frame
/// navigation at its policy check, then hands it, and every other delegate call, to the controller.
@MainActor
private final class NavigationRecorder: NSObject, WKNavigationDelegate {
    struct Action: Equatable {
        let url: URL?
        let method: String?
        let type: WKNavigationType
    }

    private(set) var actions: [Action] = []
    // Read from the forwarding overrides, which NSObject calls from any thread; set once in init.
    nonisolated(unsafe) private weak var original: NSObject?
    private let decide: @MainActor (WKWebView, WKNavigationAction, @escaping @MainActor (WKNavigationActionPolicy) -> Void) -> Void

    init(original: NSObject,
         decide: @escaping @MainActor (WKWebView, WKNavigationAction, @escaping @MainActor (WKNavigationActionPolicy) -> Void) -> Void) {
        self.original = original
        self.decide = decide
    }

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame?.isMainFrame == true {
            actions.append(Action(url: navigationAction.request.url, method: navigationAction.request.httpMethod,
                                  type: navigationAction.navigationType))
        }
        decide(webView, navigationAction, decisionHandler)
    }
}

/// Polls `condition` with `Task.sleep`, leaving the main actor free between looks for WebKit's
/// callbacks and SwiftUI's appearance passes.
@MainActor
private func settle(timeout: TimeInterval = 10, until condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try? await Task.sleep(for: .milliseconds(50))
    }
}

