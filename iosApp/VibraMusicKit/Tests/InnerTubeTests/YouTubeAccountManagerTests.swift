import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import InnerTube

/// Signing in from the web view, switching between Personal and Brand profiles and between Google
/// accounts, and signing out — the account logic of Android's MainViewModel.
@MainActor
final class YouTubeAccountManagerTests: XCTestCase {
    private var stub: InnerTubeStub!
    private var client: InnerTubeClient!
    private var store: YouTubeAuthStore!
    private var manager: YouTubeAccountManager!
    private var changes: [YouTubeIdentityChange] = []
    private var browserCleared = 0

    nonisolated private static let cookieA = "SID=a; SAPISID=secret-a"
    nonisolated private static let cookieB = "SID=b; SAPISID=secret-b"

    override func setUp() async throws {
        stub = InnerTubeStub()
        client = stub.makeClient()
        store = YouTubeAuthStore(credentials: InMemoryCredentialStore())
        makeManager()
        try stub.on("account/account_menu", fixture: "signed_in/account_menu.json")
        stub.stub.register(host: "music.youtube.com", path: "/", response: .text(try Fixtures.text("signed_in/music_shell_signed_in_personal.html")))
    }

    private func makeManager() {
        manager = YouTubeAccountManager(
            client: client,
            repository: YTMusicRepository(client: client, likeState: LikeState()),
            store: store,
            clearBrowserCookies: { [weak self] in self?.browserCleared += 1 },
            validationTimeout: .seconds(5),
            validationRetryDelay: .milliseconds(1)
        )
        manager.onIdentityChange = { [weak self] in self?.changes.append($0) }
    }

    private func captured(_ cookie: String = cookieA, pageId: String? = "113355", dataSyncId: String? = "113355", authUser: String? = "1") -> CapturedSession {
        CapturedSession(cookie: cookie, pageId: pageId, dataSyncId: dataSyncId, authUser: authUser,
                        visitorData: nil, clientVersion: "1.20260922.09.00", loggedIn: true)
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    // MARK: - Signing in

    func testAValidatedSignInIsStoredAndActsAsTheCapturedIdentity() async throws {
        try stub.on("account/accounts_list", fixture: "signed_in/accounts_list.json")
        let accepted = await manager.handleWebSession(captured(), mode: .signIn)
        XCTAssertTrue(accepted)

        let accountId = YouTubeAccounts.sessionId(cookie: Self.cookieA, dataSyncId: nil)
        XCTAssertEqual(manager.activeAccountId, accountId)
        XCTAssertEqual(manager.activeProfileId, "113355")
        XCTAssertTrue(manager.isSignedIn)
        XCTAssertEqual(manager.account?.name, "Analytical Engine Radio")
        XCTAssertEqual(manager.selectedChannelName, "Analytical Engine Radio")
        XCTAssertEqual(changes, [.signedIn(YouTubeProfileRef(accountId: accountId, profileId: "113355"), replacedListener: false)])

        let stored = try XCTUnwrap(store.activeSession)
        XCTAssertEqual(stored.cookie, Self.cookieA)
        XCTAssertEqual(stored.email, "@engine-radio")
        let profile = try XCTUnwrap(stored.activeProfile)
        XCTAssertEqual(profile, YouTubeProfile(profileId: "113355", name: "Analytical Engine Radio", handle: "@engine-radio",
                                               avatar: "https://yt3.ggpht.com/brand=s88", pageId: "113355", dataSyncId: "113355",
                                               authUser: "1", isBrandAccount: true))

        // The page's identity was adopted; the shell was never asked to overrule it.
        let identity = await client.requestIdentity()
        XCTAssertEqual(identity.pageId, "113355")
        XCTAssertEqual(identity.authUser, "1")
        XCTAssertTrue(stub.stub.requests(toPath: "/").isEmpty)
        // Validated as the candidate: the account menu went out signed with the captured cookie.
        XCTAssertEqual(stub.requests(to: "account/account_menu").first?.value(forHTTPHeaderField: "Cookie"), Self.cookieA)

        // The channel list follows on its own and is folded into the stored profiles.
        await waitUntil { !self.manager.channels.isEmpty }
        XCTAssertEqual(manager.channels.count, 2)
        await waitUntil { self.store.activeSession?.profiles.count == 2 }
        // Merged in place: the captured brand profile keeps its spot and its jar entry.
        XCTAssertEqual(store.activeSession?.profiles.map(\.profileId), ["113355", "SESSION_A"])
        XCTAssertEqual(store.activeSession?.profiles.first?.authUser, "1")
        XCTAssertEqual(store.activeSession?.activeProfileId, "113355")
    }

    func testARejectedCandidateLeavesTheOldSessionSigningRequests() async throws {
        let first = await manager.handleWebSession(captured(), mode: .signIn)
        XCTAssertTrue(first)
        stub.on("account/account_menu", #"{"actions":[]}"#)
        let rejected = await manager.handleWebSession(captured(Self.cookieB, pageId: nil, dataSyncId: "OTHER", authUser: "0"), mode: .signIn)
        XCTAssertFalse(rejected)
        // Two tries at validating (a retry after a short pause), then back to exactly the old identity.
        XCTAssertEqual(stub.requests(to: "account/account_menu").count, 3)
        XCTAssertEqual(store.sessions.count, 1)
        let identity = await client.requestIdentity()
        XCTAssertEqual(identity.cookie, Self.cookieA)
        XCTAssertEqual(identity.pageId, "113355")
        XCTAssertEqual(identity.authUser, "1")
    }

    func testARejectedFirstSignInLeavesEveryoneSignedOut() async {
        stub.on("account/account_menu", "{}", status: 401)
        let accepted = await manager.handleWebSession(captured(), mode: .signIn)
        XCTAssertFalse(accepted)
        XCTAssertFalse(manager.isSignedIn)
        XCTAssertTrue(store.sessions.isEmpty)
        let identity = await client.requestIdentity()
        XCTAssertFalse(identity.isSignedIn)
        XCTAssertTrue(changes.isEmpty)
    }

    func testASignedOutPageIsNotACapture() async {
        var session = captured()
        session.loggedIn = false
        let accepted = await manager.handleWebSession(session, mode: .signIn)
        XCTAssertFalse(accepted)
        XCTAssertTrue(stub.stub.requests.isEmpty)
    }

    func testSigningInAgainAsTheSameAccountUpgradesItInsteadOfAddingOne() async {
        _ = await manager.handleWebSession(captured(), mode: .signIn)
        // Cookies rotated: a different jar, the same email.
        let again = await manager.handleWebSession(captured(Self.cookieB), mode: .signIn)
        XCTAssertTrue(again)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.first?.cookie, Self.cookieB)
        XCTAssertEqual(changes.last, .signedIn(YouTubeProfileRef(accountId: YouTubeAccounts.sessionId(cookie: Self.cookieA, dataSyncId: nil), profileId: "113355"), replacedListener: true))
    }

    // MARK: - Switching channel

    func testSwitchingChannelAddsAProfileToTheSameLoginAndDropsAPlaceholder() async throws {
        _ = await manager.handleWebSession(captured(pageId: nil, dataSyncId: nil, authUser: nil), mode: .signIn)
        let accountId = try XCTUnwrap(manager.activeAccountId)
        // No channel identity yet: the profile has a provisional name-hash id.
        XCTAssertTrue(try XCTUnwrap(manager.activeProfile).isPlaceholder)

        let switched = await manager.handleWebSession(captured(pageId: "224466", dataSyncId: "224466", authUser: "0"), mode: .switchChannel)
        XCTAssertTrue(switched)
        XCTAssertEqual(manager.activeAccountId, accountId, "a channel switch is never a new Google account")
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.activeSession?.profiles.map(\.profileId), ["224466"])
    }

    func testSwitchingChannelWithNobodySignedInIsRefused() async {
        let switched = await manager.handleWebSession(captured(), mode: .switchChannel)
        XCTAssertFalse(switched)
        XCTAssertTrue(store.sessions.isEmpty)
        let identity = await client.requestIdentity()
        XCTAssertFalse(identity.isSignedIn)
    }

    // MARK: - Profiles

    private func seedTwoAccounts() async {
        store.replaceSessions([
            GoogleAccountSession(accountId: "a", cookie: Self.cookieA, name: "Ada", email: "ada@x", profiles: [
                YouTubeProfile(profileId: "SESSION_A", name: "Ada", dataSyncId: "SESSION_A", authUser: "0"),
                YouTubeProfile(profileId: "113355", name: "Radio", pageId: "113355", dataSyncId: "113355", authUser: "0", isBrandAccount: true),
            ], activeProfileId: "SESSION_A"),
            GoogleAccountSession(accountId: "b", cookie: Self.cookieB, name: "Bea", email: "bea@x", profiles: [
                YouTubeProfile(profileId: "SESSION_C", name: "Bea", dataSyncId: "SESSION_C", authUser: "1"),
            ], activeProfileId: "SESSION_C"),
        ])
        store.select(accountId: "a", profileId: "SESSION_A")
        await manager.restore()
    }

    func testRestoreInstallsTheStoredProfile() async {
        await seedTwoAccounts()
        XCTAssertTrue(manager.isSignedIn)
        XCTAssertEqual(manager.accounts.count, 2)
        XCTAssertEqual(manager.listenerKey, "a:SESSION_A")
        XCTAssertEqual(manager.profileRefs.count, 3)
        let identity = await client.requestIdentity()
        XCTAssertEqual(identity.cookie, Self.cookieA)
        XCTAssertEqual(identity.onBehalfOfUser, "SESSION_A")
        XCTAssertNil(identity.pageId)
    }

    func testRestoreWithNothingStoredStaysSignedOut() async {
        await manager.restore()
        XCTAssertFalse(manager.isSignedIn)
        XCTAssertNil(manager.listenerKey)
        let identity = await client.requestIdentity()
        XCTAssertFalse(identity.isSignedIn)
    }

    func testSelectingAProfileSwitchesRequestsAndReportsIt() async {
        await seedTwoAccounts()
        await manager.selectProfile(accountId: "a", profileId: "113355")
        XCTAssertEqual(manager.activeProfileId, "113355")
        XCTAssertEqual(store.activeProfileId, "113355")
        XCTAssertEqual(store.activeSession?.activeProfileId, "113355")
        XCTAssertEqual(changes, [.profileSelected(YouTubeProfileRef(accountId: "a", profileId: "113355"))])
        var identity = await client.requestIdentity()
        XCTAssertEqual(identity.pageId, "113355")

        // Into the other Google account: its own cookie and jar entry.
        await manager.selectProfile(accountId: "b", profileId: "SESSION_C")
        identity = await client.requestIdentity()
        XCTAssertEqual(identity.cookie, Self.cookieB)
        XCTAssertEqual(identity.authUser, "1")
        XCTAssertEqual(identity.onBehalfOfUser, "SESSION_C")

        // Selecting what is already active is nothing.
        await manager.selectProfile(accountId: "b", profileId: "SESSION_C")
        XCTAssertEqual(changes.count, 2)
    }

    func testSteppingThroughProfilesStopsAtTheEdges() async {
        await seedTwoAccounts()
        let back = await manager.stepProfile(forward: false)
        XCTAssertFalse(back)
        var moved = await manager.stepProfile(forward: true)
        XCTAssertTrue(moved)
        XCTAssertEqual(manager.listenerKey, "a:113355")
        moved = await manager.stepProfile(forward: true)
        XCTAssertTrue(moved)
        XCTAssertEqual(manager.listenerKey, "b:SESSION_C")
        moved = await manager.stepProfile(forward: true)
        XCTAssertFalse(moved)
    }

    func testSelectingAListedChannelActsAsIt() async {
        await seedTwoAccounts()
        await manager.selectChannel(AccountChannel(name: "New Brand", subtitle: "Brand account", thumbnailUrl: nil, pageId: "778899", dataSyncId: "SESSION_N", activeOnWeb: false))
        XCTAssertEqual(manager.activeProfileId, "778899")
        XCTAssertEqual(manager.selectedChannelName, "New Brand")
        XCTAssertEqual(store.activeSession?.profiles.last?.isBrandAccount, true)
        let identity = await client.requestIdentity()
        XCTAssertEqual(identity.pageId, "778899")
        XCTAssertEqual(identity.onBehalfOfUser, "SESSION_N")
    }

    // MARK: - Signing out

    func testSigningOutWithSeveralLoginsRemovesOnlyTheCurrentOne() async {
        await seedTwoAccounts()
        await manager.signOut()
        XCTAssertEqual(store.sessions.map(\.accountId), ["b"])
        XCTAssertEqual(manager.listenerKey, "b:SESSION_C")
        XCTAssertTrue(manager.isSignedIn)
        XCTAssertEqual(browserCleared, 0)
        let identity = await client.requestIdentity()
        XCTAssertEqual(identity.cookie, Self.cookieB)
    }

    func testSigningOutTheLastLoginSignsOutCompletely() async {
        await seedTwoAccounts()
        await manager.removeAccount("b")
        XCTAssertEqual(manager.accounts.map(\.accountId), ["a"])
        await manager.signOut()
        XCTAssertFalse(manager.isSignedIn)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(manager.listenerKey)
        XCTAssertEqual(browserCleared, 1, "the browser's own Google login goes too")
        XCTAssertEqual(changes.last, .signedOut)
        let identity = await client.requestIdentity()
        XCTAssertFalse(identity.isSignedIn)
    }

    // MARK: - Channel list and names

    func testListedChannelsReplacePlaceholdersButAnEmptyListNeverDoes() async {
        store.replaceSessions([GoogleAccountSession(accountId: "a", cookie: Self.cookieA, profiles: [
            YouTubeProfile(profileId: "profile:0123456789abcdef", name: "Personal"),
        ], activeProfileId: "profile:0123456789abcdef")])
        store.select(accountId: "a", profileId: "profile:0123456789abcdef")
        await manager.restore()

        manager.persistDetectedProfiles([])
        XCTAssertEqual(store.activeSession?.profiles.map(\.profileId), ["profile:0123456789abcdef"])

        manager.persistDetectedProfiles([AccountChannel(name: "Ada", subtitle: "@ada", thumbnailUrl: nil, pageId: nil, dataSyncId: "SESSION_A", activeOnWeb: true)])
        XCTAssertEqual(store.activeSession?.profiles.map(\.profileId), ["SESSION_A"])
        // The placeholder was active: the one identity Google reported takes its place.
        XCTAssertEqual(store.activeSession?.activeProfileId, "SESSION_A")
    }

    func testListedChannelsKeepTheActiveIdentityEvenWhenGoogleOmitsIt() async {
        await seedTwoAccounts()
        manager.persistDetectedProfiles([AccountChannel(name: "Other", subtitle: "", thumbnailUrl: nil, pageId: "555", dataSyncId: "555", activeOnWeb: false)])
        XCTAssertEqual(store.sessions.first?.profiles.map(\.profileId), ["SESSION_A", "113355", "555"])
        XCTAssertEqual(store.sessions.first?.activeProfileId, "SESSION_A")
    }

    func testRefreshingTheAccountNamesTheChosenProfile() async {
        await seedTwoAccounts()
        await manager.refreshAccount()
        XCTAssertEqual(manager.account?.name, "Analytical Engine Radio")
        XCTAssertEqual(manager.selectedChannelName, "Analytical Engine Radio")
        let profile = store.sessions.first?.profiles.first { $0.profileId == "SESSION_A" }
        XCTAssertEqual(profile?.name, "Analytical Engine Radio")
        XCTAssertEqual(profile?.handle, "@engine-radio")
        XCTAssertEqual(store.sessions.first?.email, "@engine-radio")
    }
}
