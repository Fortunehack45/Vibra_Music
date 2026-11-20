import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import InnerTube

/// Which account and channel a signed-in request acts as: the music.youtube.com shell's `ytcfg`, a
/// page the listener captured, and a channel they picked — and the headers another module reads.
///
/// A cookie is not an account. Every play and every library read was credited to "the first account
/// in the jar" until requests said which identity they meant, which is what these pin.
final class SessionScopeTests: XCTestCase {
    private static let cookie = "SID=1; SAPISID=secret"
    private static let signature = "SAPISIDHASH 1700000000_d2a0deeb95ea263a68778d9e9ac8840dce59d800"
    private var stub: InnerTubeStub!

    override func setUp() {
        stub = InnerTubeStub()
        stub.on("browse", "{}")
    }

    private func serveShell(_ fixture: String) throws {
        stub.stub.register(host: "music.youtube.com", path: "/", response: .text(try Fixtures.text(fixture)))
    }

    private var shellRequests: [URLRequest] { stub.stub.requests(toPath: "/") }

    // MARK: - Reading the shell

    func testTheSignedInShellNamesTheBrandChannelTheJarEntryAndTheLiveVersion() throws {
        let parsed = try XCTUnwrap(InnerTubeClient.sessionScope(fromShell: try Fixtures.text("signed_in/music_shell_signed_in.html")))
        XCTAssertTrue(parsed.signedIn)
        // A delegated (brand) session acts on behalf of the page itself.
        XCTAssertEqual(parsed.scope, InnerTubeSessionScope(dataSyncId: "113355", pageId: "113355", authUser: "1", clientVersion: "1.20260922.09.00"))
        XCTAssertEqual(parsed.visitorData, "CgtTRVNTSU9OX0JPVU5EKICAgICAgICAgAEyCgoCVVMSBBoAIAA%3D")
    }

    func testAPersonalShellActsAsTheAccountHalfOfItsDataSyncId() throws {
        let parsed = try XCTUnwrap(InnerTubeClient.sessionScope(fromShell: try Fixtures.text("signed_in/music_shell_signed_in_personal.html")))
        // `SESSION_INDEX` unquoted, `DATASYNC_ID` with an empty delegated half.
        XCTAssertEqual(parsed.scope, InnerTubeSessionScope(dataSyncId: "SYNC_PERSONAL", pageId: nil, authUser: "0", clientVersion: "1.20260922.09.00"))
    }

    func testTheRecordedSignedOutShellYieldsOnlyItsClientVersion() throws {
        let parsed = try XCTUnwrap(InnerTubeClient.sessionScope(fromShell: try Fixtures.text("music_shell_signed_out.html")))
        XCTAssertFalse(parsed.signedIn)
        // Its DATASYNC_ID belongs to no account; sending one Google can't tie to the cookie is 401.
        XCTAssertEqual(parsed.scope, InnerTubeSessionScope(dataSyncId: nil, pageId: nil, authUser: "0", clientVersion: "1.20260922.09.00"))
        XCTAssertNil(parsed.visitorData)
        XCTAssertNil(InnerTubeClient.sessionScope(fromShell: "<html>no config here</html>"))
    }

    // MARK: - Requests as the shell's identity

    func testSignedInRequestsActAsTheShellsIdentity() async throws {
        try serveShell("signed_in/music_shell_signed_in.html")
        let client = stub.makeClient()
        await client.setCookie(Self.cookie)
        _ = try await client.browse("FEmusic_liked_playlists")

        let shell = try XCTUnwrap(shellRequests.first)
        XCTAssertEqual(shell.value(forHTTPHeaderField: "Cookie"), Self.cookie)
        XCTAssertEqual(shell.value(forHTTPHeaderField: "Authorization"), Self.signature)

        let request = try XCTUnwrap(stub.requests(to: "browse").first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), Self.cookie)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), Self.signature)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-AuthUser"), "1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-PageId"), "113355")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-YouTube-Client-Version"), "1.20260922.09.00")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-Visitor-Id"), "CgtTRVNTSU9OX0JPVU5EKICAgICAgICAgAEyCgoCVVMSBBoAIAA%3D")
        let body = InnerTubeStub.body(of: request)
        XCTAssertEqual(body.o("context").o("user").s("onBehalfOfUser"), "113355")
        XCTAssertEqual(body.o("context").o("client").s("clientVersion"), "1.20260922.09.00")
    }

    func testTheShellIsReadOncePerCookieEvenForConcurrentRequests() async throws {
        try serveShell("signed_in/music_shell_signed_in.html")
        let client = stub.makeClient()
        await client.setCookie(Self.cookie)
        async let a = client.browse("A")
        async let b = client.browse("B")
        async let c = client.browse("C")
        _ = try await (a, b, c)
        _ = try await client.browse("D")
        XCTAssertEqual(shellRequests.count, 1)
        XCTAssertEqual(stub.requests(to: "browse").count, 4)
    }

    func testASignedOutShellScopesNothingButStillLendsItsVersion() async throws {
        try serveShell("music_shell_signed_out.html")
        let client = stub.makeClient()
        await client.setCookie(Self.cookie)
        _ = try await client.browse("X")
        let request = try XCTUnwrap(stub.requests(to: "browse").first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-AuthUser"), "0")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Goog-PageId"))
        XCTAssertNil(InnerTubeStub.body(of: request).o("context").o("user").s("onBehalfOfUser"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-YouTube-Client-Version"), "1.20260922.09.00")
    }

    func testAShellThatCannotBeReadFailsOpen() async throws {
        stub.stub.register(host: "music.youtube.com", path: "/", response: .status(500))
        let client = stub.makeClient()
        await client.setCookie(Self.cookie)
        _ = try await client.browse("X")
        let request = try XCTUnwrap(stub.requests(to: "browse").first)
        // Signed, but about no particular identity — exactly what it did before scoping existed.
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), Self.signature)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-AuthUser"), "0")
        XCTAssertNil(InnerTubeStub.body(of: request).o("context").o("user").s("onBehalfOfUser"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-YouTube-Client-Version"), "1.20250101.01.00")
    }

    func testAJarWithOnlyTheSecureFormsStillSigns() async throws {
        try serveShell("signed_in/music_shell_signed_in_personal.html")
        let client = stub.makeClient()
        await client.setCookie("SID=1; __Secure-3PAPISID=secret")
        _ = try await client.browse("X")
        XCTAssertEqual(stub.requests(to: "browse").first?.value(forHTTPHeaderField: "Authorization"), Self.signature)
    }

    // MARK: - Choosing a channel

    func testAChosenChannelOutranksTheShellCompletely() async throws {
        try serveShell("signed_in/music_shell_signed_in.html")
        let client = stub.makeClient()
        await client.setCookie(Self.cookie)
        // The account's own channel, chosen over the brand page the shell offers.
        await client.selectChannel(pageId: nil, dataSyncId: "SESSION_A", authUser: "2")
        _ = try await client.browse("X")
        let request = try XCTUnwrap(stub.requests(to: "browse").first)
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Goog-PageId"), "no mixing the shell's page with another identity")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-AuthUser"), "2")
        XCTAssertEqual(InnerTubeStub.body(of: request).o("context").o("user").s("onBehalfOfUser"), "SESSION_A")

        // Both nil goes back to whatever the shell serves.
        await client.selectChannel(pageId: nil, dataSyncId: nil)
        _ = try await client.browse("Y")
        let back = try XCTUnwrap(stub.requests(to: "browse").last)
        XCTAssertEqual(back.value(forHTTPHeaderField: "X-Goog-PageId"), "113355")
        XCTAssertEqual(back.value(forHTTPHeaderField: "X-Goog-AuthUser"), "1")
    }

    func testAChannelWithoutAnAuthUserKeepsTheShellsJarEntry() async throws {
        try serveShell("signed_in/music_shell_signed_in.html")
        let client = stub.makeClient()
        await client.setCookie(Self.cookie)
        await client.selectChannel(pageId: "224466", dataSyncId: "224466")
        _ = try await client.browse("X")
        let request = try XCTUnwrap(stub.requests(to: "browse").first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-PageId"), "224466")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-AuthUser"), "1")
    }

    func testACapturedPageIsAdoptedWholeAndNeverOverwrittenByTheShell() async throws {
        try serveShell("signed_in/music_shell_signed_in.html")
        let client = stub.makeClient()
        await client.adoptWebSession(CapturedSession(
            cookie: Self.cookie, pageId: nil, dataSyncId: "SESSION_A", authUser: "0",
            visitorData: "CgtQQUdFX1ZJU0lUT1IogICAgICAgICAAQ%3D%3D", clientVersion: "1.20260926.01.00", loggedIn: true
        ))
        _ = try await client.browse("X")
        XCTAssertTrue(shellRequests.isEmpty, "a scope in hand is not refetched")
        let request = try XCTUnwrap(stub.requests(to: "browse").first)
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Goog-PageId"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-AuthUser"), "0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-YouTube-Client-Version"), "1.20260926.01.00")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-Visitor-Id"), "CgtQQUdFX1ZJU0lUT1IogICAgICAgICAAQ%3D%3D")
        XCTAssertEqual(InnerTubeStub.body(of: request).o("context").o("user").s("onBehalfOfUser"), "SESSION_A")
    }

    func testASessionBoundVisitorIdIsNotReplacedByAnAnonymousOne() async throws {
        stub.stub.register(host: "www.youtube.com", path: "/sw.js_data", response: .text(try Fixtures.text("sw_js_data.txt")))
        let client = stub.makeClient()
        await client.adoptSessionScope(pageId: nil, dataSyncId: "S", authUser: "0", visitorData: "CgtCT1VORF9WSVNJVE9SKICAgICAgICAgAE%3D", clientVersion: nil, loggedIn: true)
        let kept = await client.ensureVisitorData()
        XCTAssertEqual(kept, "CgtCT1VORF9WSVNJVE9SKICAgICAgICAgAE%3D")
        // A refresh — the one time a bot accusation calls for it — does replace it.
        let refreshed = await client.ensureVisitorData(refresh: true)
        XCTAssertTrue(try XCTUnwrap(refreshed).hasPrefix("CgtVWmRDdjR5bmplWSj7s93VBjIK"))
    }

    func testASignedOutCapturedPageKeepsOnlyItsVersion() async throws {
        let client = stub.makeClient()
        await client.setCookie(Self.cookie)
        await client.adoptSessionScope(pageId: "113355", dataSyncId: "SESSION_B", authUser: "3", visitorData: "CgtYWFhYWFhYWFhYWCiAgICAgICAgIAB", clientVersion: "1.2", loggedIn: false)
        _ = try await client.browse("X")
        let request = try XCTUnwrap(stub.requests(to: "browse").first)
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Goog-PageId"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-AuthUser"), "0")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Goog-Visitor-Id"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-YouTube-Client-Version"), "1.2")
    }

    // MARK: - Changing session

    func testANewCookieDropsEverythingTheLastSessionOwned() async throws {
        try serveShell("signed_in/music_shell_signed_in.html")
        let client = stub.makeClient()
        await client.setCookie(Self.cookie)
        await client.selectChannel(pageId: "999", dataSyncId: "999")
        _ = try await client.browse("X")
        XCTAssertEqual(shellRequests.count, 1)

        await client.setCookie("SID=2; SAPISID=other")
        let identity = await client.requestIdentity()
        // Scope reread for the new cookie; the old channel choice and visitor id are gone.
        XCTAssertEqual(shellRequests.count, 2)
        XCTAssertEqual(identity.pageId, "113355")
        XCTAssertEqual(identity.cookie, "SID=2; SAPISID=other")

        // Setting the same cookie again changes nothing.
        await client.setCookie("SID=2; SAPISID=other")
        _ = await client.requestIdentity()
        XCTAssertEqual(shellRequests.count, 2)
    }

    func testRefreshingTheScopeRereadsTheShell() async throws {
        try serveShell("signed_in/music_shell_signed_in_personal.html")
        let client = stub.makeClient()
        await client.setCookie(Self.cookie)
        await client.ensureSessionScope()
        try serveShell("signed_in/music_shell_signed_in.html")
        await client.refreshSessionScope()
        XCTAssertEqual(shellRequests.count, 2)
        let identity = await client.requestIdentity()
        XCTAssertEqual(identity.pageId, "113355")
    }

    func testActivatingAStoredProfileSetsTheCookieThenItsChannel() async throws {
        try serveShell("signed_in/music_shell_signed_in.html")
        let client = stub.makeClient()
        await client.activate(cookie: Self.cookie, profile: YouTubeProfile(profileId: "SESSION_A", name: "Ada", dataSyncId: "SESSION_A", authUser: "0"))
        let identity = await client.requestIdentity()
        XCTAssertEqual(identity.onBehalfOfUser, "SESSION_A")
        XCTAssertNil(identity.pageId)
        XCTAssertEqual(identity.authUser, "0")
        await client.activate(cookie: nil, profile: nil)
        let signedOut = await client.requestIdentity()
        XCTAssertFalse(signedOut.isSignedIn)
    }

    // MARK: - Identity for other modules

    func testRequestIdentityCarriesEverythingTheStreamResolverSigns() async throws {
        try serveShell("signed_in/music_shell_signed_in.html")
        let client = stub.makeClient(language: "ja")
        await client.setCookie(Self.cookie)
        let identity = await client.requestIdentity()
        XCTAssertTrue(identity.isSignedIn)
        XCTAssertEqual(identity.cookie, Self.cookie)
        XCTAssertEqual(identity.authUser, "1")
        XCTAssertEqual(identity.pageId, "113355")
        XCTAssertEqual(identity.onBehalfOfUser, "113355")
        XCTAssertEqual(identity.visitorData, "CgtTRVNTSU9OX0JPVU5EKICAgICAgICAgAEyCgoCVVMSBBoAIAA%3D")
        XCTAssertTrue(identity.visitorDataIsSessionBound)
        XCTAssertEqual(identity.liveClientVersion, "1.20260922.09.00")
        XCTAssertEqual(identity.webRemixClientVersion, "1.20260922.09.00")
        XCTAssertEqual(identity.language, "ja")
        XCTAssertEqual(identity.region, "US")
        XCTAssertEqual(identity.headers, [
            "Cookie": Self.cookie,
            "Authorization": Self.signature,
            "X-Goog-AuthUser": "1",
            "X-Goog-PageId": "113355",
        ])
        // The hash is per origin: youtube.com clients get their own.
        let youtube = await client.authHeaders(origin: "https://www.youtube.com")
        XCTAssertEqual(youtube["Authorization"], "SAPISIDHASH 1700000000_8826f35e8fadc232ceb4c889bdb7a3a586eb7379")
    }

    func testSignedOutIdentityIsEmpty() async {
        let identity = await stub.makeClient().requestIdentity()
        XCTAssertFalse(identity.isSignedIn)
        XCTAssertTrue(identity.headers.isEmpty)
        XCTAssertNil(identity.cookie)
        XCTAssertNil(identity.pageId)
        XCTAssertNil(identity.onBehalfOfUser)
        XCTAssertEqual(identity.authUser, "0")
        XCTAssertNil(identity.liveClientVersion)
        XCTAssertEqual(identity.webRemixClientVersion, "1.20250101.01.00")
    }

    // MARK: - youtube.com's own switcher

    func testTheAccountSwitcherIsASignedGetToYouTubeBehindTheXSSIGuard() async throws {
        try serveShell("signed_in/music_shell_signed_in.html")
        stub.stub.register(host: "www.youtube.com", path: "/getAccountSwitcherEndpoint", response: .text(try Fixtures.text("signed_in/account_switcher.txt")))
        let client = stub.makeClient()
        do {
            _ = try await client.accountSwitcher()
            XCTFail("signed out has no switcher")
        } catch let error as InnerTubeError {
            XCTAssertEqual(error, .notSignedIn)
        }
        await client.setCookie(Self.cookie)
        let response = try await client.accountSwitcher()
        XCTAssertEqual(InnerTubeParser.parseAccountChannels(response).count, 2)

        let request = try XCTUnwrap(stub.stub.requests(toPath: "/getAccountSwitcherEndpoint").first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "SAPISIDHASH 1700000000_8826f35e8fadc232ceb4c889bdb7a3a586eb7379")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-AuthUser"), "1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Origin"), "https://www.youtube.com")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Goog-PageId"), "the switcher lists every channel, not one")
    }
}
