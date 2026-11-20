import XCTest
@testable import InnerTube
#if canImport(WebKit)
import WebKit
#endif

/// The sign-in screen's rules: what to load, when confirming becomes possible, which cookies are the
/// session, and what a confirmation takes from the page (the logic of Android's YtMusicLoginScreen and
/// WebSession; the screen itself is the app's).
final class WebLoginTests: XCTestCase {

    func testSignInOpensGooglesOwnLoginAndSwitchingOpensYouTubeMusic() {
        let login = YouTubeWebLogin.startURL(for: .signIn)
        XCTAssertEqual(login.host(), "accounts.google.com")
        XCTAssertEqual(login.path(), "/ServiceLogin")
        let items = URLComponents(url: login, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "continue" }?.value, "https://music.youtube.com/")
        XCTAssertEqual(items.first { $0.name == "service" }?.value, "youtube")
        XCTAssertEqual(YouTubeWebLogin.startURL(for: .switchChannel), URL(string: "https://music.youtube.com/"))
    }

    func testOnlyAYouTubeMusicPageEnablesConfirmation() {
        XCTAssertTrue(YouTubeWebLogin.isReadyForConfirmation(URL(string: "https://music.youtube.com/")))
        XCTAssertTrue(YouTubeWebLogin.isReadyForConfirmation(URL(string: "https://music.youtube.com/library")))
        XCTAssertFalse(YouTubeWebLogin.isReadyForConfirmation(URL(string: "https://accounts.google.com/signin/v2")))
        XCTAssertFalse(YouTubeWebLogin.isReadyForConfirmation(URL(string: "https://www.youtube.com/")))
        XCTAssertFalse(YouTubeWebLogin.isReadyForConfirmation(nil))
    }

    // MARK: - Confirming

    func testAConfirmationTakesTheCookieAndThePagesOwnIdentity() throws {
        let probe: [String: Any] = [
            "loggedIn": "true", "pageId": "113355", "dataSyncId": "SYNC||SESSION_B", "authUser": "1",
            "visitorData": "CgtWSVNJVE9S", "clientVersion": "1.20260922.09.00",
        ]
        let session = try YouTubeWebLogin.captureSession(cookieHeader: "SID=1; SAPISID=s", probeResult: probe).get()
        // A delegated identity is the most specific answer the page can give.
        XCTAssertEqual(session, CapturedSession(cookie: "SID=1; SAPISID=s", pageId: "113355", dataSyncId: "113355", authUser: "1",
                                                visitorData: "CgtWSVNJVE9S", clientVersion: "1.20260922.09.00", loggedIn: true))
    }

    func testAPersonalPageNormalisesItsDataSyncId() throws {
        let probe = #"{"loggedIn":"true","pageId":null,"dataSyncId":"SYNC_PERSONAL||","authUser":"0","visitorData":null,"clientVersion":null}"#
        let session = try YouTubeWebLogin.captureSession(cookieHeader: "__Secure-3PAPISID=s", probeResult: probe).get()
        XCTAssertNil(session.pageId)
        XCTAssertEqual(session.dataSyncId, "SYNC_PERSONAL")
        XCTAssertEqual(session.authUser, "0")
        XCTAssertNil(session.visitorData)
    }

    func testAConfirmationTooEarlyIsRefusedAndTheScreenStaysOpen() {
        // No signing secret yet: the page is mid-login.
        XCTAssertEqual(YouTubeWebLogin.captureSession(cookieHeader: "NID=1", probeResult: ["loggedIn": "true"]), .failure(.noSigningCookie))
        XCTAssertEqual(YouTubeWebLogin.captureSession(cookieHeader: nil, probeResult: ["loggedIn": "true"]), .failure(.noSigningCookie))
        // Signed-in cookies, but the page hasn't said who it is (a channel chooser still open, or
        // no ytcfg at all).
        XCTAssertEqual(YouTubeWebLogin.captureSession(cookieHeader: "SAPISID=s", probeResult: ["loggedIn": "false"]), .failure(.notSignedIn))
        XCTAssertEqual(YouTubeWebLogin.captureSession(cookieHeader: "SAPISID=s", probeResult: nil), .failure(.notSignedIn))
        XCTAssertEqual(YouTubeWebLogin.captureSession(cookieHeader: "SAPISID=s", probeResult: "null"), .failure(.notSignedIn))
    }

    func testTheProbeAsksForExactlyTheKeysTheSessionNeeds() {
        for key in ["LOGGED_IN", "DELEGATED_SESSION_ID", "DATASYNC_ID", "SESSION_INDEX", "VISITOR_DATA", "INNERTUBE_CLIENT_VERSION"] {
            XCTAssertTrue(YouTubeWebLogin.ytcfgProbeScript.contains("'\(key)'"), key)
        }
    }

    // MARK: - Cookies

    private func cookie(_ name: String, _ value: String, domain: String, path: String = "/", secure: Bool = true, expires: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if secure { properties[.secure] = "TRUE" }
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }

    func testTheSessionHeaderIsWhatMusicYouTubeWouldBeSent() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let jar = [
            cookie("SID", "1", domain: ".youtube.com"),
            cookie("SAPISID", "s", domain: ".youtube.com"),
            cookie("LOGIN_INFO", "l", domain: ".youtube.com", path: "/watch"),
            cookie("HSID", "h", domain: "music.youtube.com"),
            cookie("__Secure-3PAPISID", "old", domain: ".youtube.com", expires: now.addingTimeInterval(-60)),
            cookie("NID", "n", domain: ".google.com"),
            cookie("OTHER", "o", domain: "www.youtube.com"),
        ]
        XCTAssertEqual(YouTubeWebLogin.cookieHeader(from: jar, now: now), "SID=1; SAPISID=s; HSID=h")
        XCTAssertNil(YouTubeWebLogin.cookieHeader(from: [cookie("NID", "n", domain: ".google.com")], now: now))
    }

    func testDomainMatching() {
        XCTAssertTrue(YouTubeWebLogin.domain(".youtube.com", matches: "music.youtube.com"))
        XCTAssertTrue(YouTubeWebLogin.domain(".youtube.com", matches: "youtube.com"))
        XCTAssertTrue(YouTubeWebLogin.domain("music.youtube.com", matches: "music.youtube.com"))
        XCTAssertFalse(YouTubeWebLogin.domain("www.youtube.com", matches: "music.youtube.com"))
        XCTAssertFalse(YouTubeWebLogin.domain(".notyoutube.com", matches: "youtube.com"))
        XCTAssertFalse(YouTubeWebLogin.domain(".youtube.com", matches: "evilyoutube.com"))
    }

    func testACookiePathOnlyMatchesOnASlashBoundary() {
        let jar = [cookie("W", "1", domain: ".youtube.com", path: "/watch")]
        let base = URL(string: "https://music.youtube.com")!
        XCTAssertEqual(YouTubeWebLogin.cookieHeader(from: jar, for: base.appendingPathComponent("watch")), "W=1")
        XCTAssertEqual(YouTubeWebLogin.cookieHeader(from: jar, for: base.appendingPathComponent("watch/abc")), "W=1")
        XCTAssertNil(YouTubeWebLogin.cookieHeader(from: jar, for: base.appendingPathComponent("watchlater")))
    }

    func testOnlyGoogleAndYouTubeCookiesAreTheGoogleLogin() {
        XCTAssertTrue(YouTubeWebLogin.isGoogleCookie(cookie("SID", "1", domain: ".google.com")))
        XCTAssertTrue(YouTubeWebLogin.isGoogleCookie(cookie("SAPISID", "1", domain: ".youtube.com")))
        XCTAssertTrue(YouTubeWebLogin.isGoogleCookie(cookie("ACCOUNT_CHOOSER", "1", domain: "accounts.google.com")))
        // The Discord and Last.fm logins share the jar and survive a YouTube sign-out.
        XCTAssertFalse(YouTubeWebLogin.isGoogleCookie(cookie("token", "1", domain: "discord.com")))
        XCTAssertFalse(YouTubeWebLogin.isGoogleCookie(cookie("sessionid", "1", domain: ".last.fm")))
    }

    func testASavedHeaderBecomesBrowserCookiesOnEachYouTubeOrigin() {
        let cookies = YouTubeWebLogin.browserCookies(fromHeader: "SID=1; SAPISID=a=b; empty=; =novalue")
        XCTAssertEqual(cookies.count, 6, "two cookies on three origins")
        XCTAssertEqual(Set(cookies.map(\.domain)), ["music.youtube.com", "www.youtube.com", "youtube.com"])
        XCTAssertTrue(cookies.allSatisfy { $0.isSecure && $0.path == "/" })
        XCTAssertEqual(cookies.first { $0.name == "SAPISID" }?.value, "a=b")
        // Installed, they read back as the same header.
        XCTAssertEqual(YouTubeWebLogin.cookieHeader(from: cookies), "SID=1; SAPISID=a=b")
    }

    #if canImport(WebKit)
    @MainActor
    func testTheLoginWebViewIdentifiesAsSafari() {
        let controller = YouTubeLoginWebController(mode: .signIn, dataStore: .nonPersistent())
        XCTAssertEqual(controller.webView.configuration.applicationNameForUserAgent, YouTubeWebLogin.safariApplicationName)
        XCTAssertTrue(YouTubeWebLogin.safariApplicationName.contains("Safari/"))
        XCTAssertFalse(controller.isPageReady)
    }

    /// The screen tears the web view down whenever it disappears (so a page can't play or keep
    /// loading behind it) and a tab switch brings it back mid sign-in: the flow must carry on, not
    /// sit on a stopped page with media suspended.
    @MainActor
    func testLeavingAndReturningMidSignInResumesTheStoppedPage() async {
        let controller = YouTubeLoginWebController(mode: .signIn, dataStore: .nonPersistent())
        await controller.start()

        controller.tearDown()
        XCTAssertTrue(controller.isTornDown)

        controller.resume()
        XCTAssertFalse(controller.isTornDown, "back on screen the page is live again")
        controller.tearDown()
    }

    @MainActor
    func testClearingTheBrowsersGoogleLoginLeavesOtherLoginsAlone() async {
        // The data store owns its cookie store; it has to outlive the test's use of it.
        let dataStore = WKWebsiteDataStore.nonPersistent()
        defer { withExtendedLifetime(dataStore) {} }
        let store = dataStore.httpCookieStore
        await store.setCookie(cookie("SAPISID", "s", domain: ".youtube.com"))
        await store.setCookie(cookie("SID", "g", domain: ".google.com"))
        await store.setCookie(cookie("token", "d", domain: "discord.com"))
        await YouTubeBrowserCookies.clearGoogleCookies(in: store)
        let left = await store.allCookies()
        XCTAssertEqual(left.map(\.name), ["token"])

        await YouTubeBrowserCookies.installGoogleCookies("SID=1; SAPISID=saved", in: store)
        let installed = await store.allCookies()
        XCTAssertEqual(YouTubeWebLogin.cookieHeader(from: installed), "SID=1; SAPISID=saved")
        XCTAssertTrue(installed.contains { $0.name == "token" })
    }
    #endif
}
