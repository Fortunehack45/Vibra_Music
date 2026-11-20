import VibraMusicTestSupport
import XCTest
@testable import ListenTogether

/// The client's frame handling without a socket: sequence guards, queue healing requests,
/// promotion tracking, the kick ledger, and terminal errors.
final class PartyClientStateTests: XCTestCase {
    private func makeClient() async throws -> PartyClient {
        let (store, _) = try PartyTestFixtures.makeStore()
        return PartyTestFixtures.makeClient(store: store)
    }

    func testCommitMembershipPublishesConnectingState() async throws {
        let client = try await makeClient()
        await client.commitMembershipForTesting(
            serverBase: "https://default.example.com",
            membership: PartyTestFixtures.membership())
        let state = await client.state
        XCTAssertEqual("J4M001", state.code)
        XCTAssertEqual("m-2", state.you?.memberId)
        XCTAssertEqual(2, state.members.count)
        XCTAssertTrue(state.inParty)
        XCTAssertEqual(.connecting, state.connection)
    }

    func testStaleStateFrameIsDropped() async throws {
        let client = try await makeClient()
        await client.commitMembershipForTesting(
            serverBase: "https://default.example.com",
            membership: PartyTestFixtures.membership(
                playback: PartyPlayback(seq: 5, track: PartyTestFixtures.track("a"))))
        await client.receiveForTesting(
            #"{"type":"state","playback":{"seq":4,"track":{"videoId":"b"},"queueSeq":0,"queueIndex":-1,"isPlaying":false,"positionMs":0,"anchorMs":0}}"#)
        let staleTrack = await client.state.playback.track?.videoId
        XCTAssertEqual("a", staleTrack)
        await client.receiveForTesting(
            #"{"type":"state","playback":{"seq":6,"track":{"videoId":"c"},"queueSeq":0,"queueIndex":-1,"isPlaying":true,"positionMs":10,"anchorMs":20}}"#)
        let freshTrack = await client.state.playback.track?.videoId
        XCTAssertEqual("c", freshTrack)
    }

    func testStaleQueueFrameIsDropped() async throws {
        let client = try await makeClient()
        await client.commitMembershipForTesting(
            serverBase: "https://default.example.com",
            membership: PartyTestFixtures.membership(
                queue: PartyQueue(seq: 3, index: 0, items: [PartyTestFixtures.track("a")])))
        await client.receiveForTesting(
            #"{"type":"queue","queue":{"seq":2,"index":0,"items":[{"videoId":"old"}]}}"#)
        let queueIdsStale = await client.state.queue.items.map(\.videoId)
        XCTAssertEqual(["a"], queueIdsStale)
        await client.receiveForTesting(
            #"{"type":"queue","queue":{"seq":4,"index":1,"items":[{"videoId":"a"},{"videoId":"b"}]}}"#)
        let queueIdsFresh = await client.state.queue.items.map(\.videoId)
        XCTAssertEqual(["a", "b"], queueIdsFresh)
    }

    func testMembersFramePromotesYou() async throws {
        let client = try await makeClient()
        await client.commitMembershipForTesting(
            serverBase: "https://default.example.com",
            membership: PartyTestFixtures.membership())
        let hostBefore = await client.state.you?.isHost ?? true
        XCTAssertFalse(hostBefore)
        // The host left; the server handed the role to this device, announced only here.
        await client.receiveForTesting(
            #"{"type":"members","members":[{"memberId":"m-2","displayName":"Guest","isHost":true,"connected":true}],"maxMembers":5,"hostOnlyControl":true}"#)
        let state = await client.state
        XCTAssertTrue(state.you?.isHost ?? false)
        // …which unlocks a party this device was locked out of.
        XCTAssertFalse(state.controlsLocked)
    }

    func testMembersFrameWithoutLockKeepsHeldValue() async throws {
        let client = try await makeClient()
        await client.commitMembershipForTesting(
            serverBase: "https://default.example.com",
            membership: PartyTestFixtures.membership(hostOnlyControl: true))
        await client.receiveForTesting(
            #"{"type":"members","members":[{"memberId":"m-2","displayName":"Guest","isHost":false,"connected":true}],"maxMembers":5}"#)
        // Absent ≠ off: an upgrade mid-party must not silently unlock it.
        let lockHeld = await client.state.hostOnlyControl
        XCTAssertTrue(lockHeld)
    }

    func testNonTerminalErrorSurfacesAndStays() async throws {
        let client = try await makeClient()
        await client.commitMembershipForTesting(
            serverBase: "https://default.example.com",
            membership: PartyTestFixtures.membership())
        await client.receiveForTesting(
            #"{"type":"error","error":"host_only","message":"Only the host can control the music in this party."}"#)
        let serverError = await client.state.error
        XCTAssertEqual(
            "Only the host can control the music in this party.",
            serverError)
        let stillIn = await client.state.inParty
        XCTAssertTrue(stillIn)
    }

    func testTerminalErrorLeavesParty() async throws {
        let client = try await makeClient()
        await client.commitMembershipForTesting(
            serverBase: "https://default.example.com",
            membership: PartyTestFixtures.membership())
        await client.receiveForTesting(
            #"{"type":"error","error":"bad_token","message":"Bad token."}"#)
        let left = await client.waitUntil(timeoutSeconds: 5) { !$0.inParty }
        XCTAssertTrue(left)
    }

    func testKickRecordsShutOutAndLeaves() async throws {
        let (store, _) = try PartyTestFixtures.makeStore()
        let client = PartyTestFixtures.makeClient(store: store)
        await client.commitMembershipForTesting(
            serverBase: "https://default.example.com",
            membership: PartyTestFixtures.membership())
        await client.receiveForTesting(#"{"type":"bye","reason":"kicked"}"#)
        let left = await client.waitUntil(timeoutSeconds: 5) { !$0.inParty }
        XCTAssertTrue(left)
        XCTAssertTrue(store.isKickedOut(of: "J4M001"))
        // A plain departure records nothing: a different party, so the kick above cannot answer for it.
        await client.commitMembershipForTesting(
            serverBase: "https://default.example.com",
            membership: PartyTestFixtures.membership(code: "M4P7Q2"))
        await client.receiveForTesting(#"{"type":"bye","reason":"left"}"#)
        let leftAgain = await client.waitUntil(timeoutSeconds: 5) { !$0.inParty }
        XCTAssertTrue(leftAgain)
        XCTAssertFalse(store.isKickedOut(of: "M4P7Q2"))
    }

    func testKickedCodeIsRefusedOnPreview() async throws {
        let (store, _) = try PartyTestFixtures.makeStore()
        store.recordKick(code: "J4M001")
        let client = PartyTestFixtures.makeClient(store: store)
        let result = await client.previewParty(code: "J4M001")
        if case .failure(let error) = result {
            XCTAssertEqual("recently_kicked", error.code)
        } else {
            XCTFail("expected refusal for a kicked code")
        }
    }

    func testPreviewRefusesACodeOutsideTheAlphabetWithoutAskingTheServer() async throws {
        let (store, _) = try PartyTestFixtures.makeStore()
        let stub = URLProtocolStub()
        let client = PartyClient(store: store, urlSession: stub.makeSession(), clock: PartyServerClock())

        // Six letters and digits to `normalize`, but not six characters a party code can hold.
        let result = await client.previewParty(code: "ａｂｃ１２３")

        if case .failure(let error) = result {
            XCTAssertEqual("bad_code", error.code)
        } else {
            XCTFail("expected the code to be refused")
        }
        XCTAssertTrue(stub.requests.isEmpty)
        XCTAssertTrue(stub.unmatchedRequests.isEmpty)
    }

    func testSwitchRefusesACodeOutsideTheAlphabetWithoutAskingTheServer() async throws {
        let (store, _) = try PartyTestFixtures.makeStore()
        let stub = URLProtocolStub()
        let client = PartyClient(
            store: store, urlSession: stub.makeSession(), clock: PartyServerClock(),
            identityProvider: FixedIdentity())

        let result = await client.switchParty(targetServer: "https://target.example.com", targetCode: "ａｂｃ１２３")

        XCTAssertEqual(
            .targetFailedNoParty(targetError: "A party code is six letters or digits."), result)
        XCTAssertTrue(stub.requests.isEmpty)
        XCTAssertTrue(stub.unmatchedRequests.isEmpty)
    }

    func testActivityIsCapped() async throws {
        let client = try await makeClient()
        await client.commitMembershipForTesting(
            serverBase: "https://default.example.com",
            membership: PartyTestFixtures.membership())
        for i in 0 ..< 120 {
            await client.receiveForTesting(
                #"{"type":"activity","action":"seek","by":"Host","detail":"x","atMs":\#(i)}"#)
        }
        let activityCount = await client.activity.count
        XCTAssertEqual(100, activityCount)
        let newestActivity = await client.activity.first?.atMs
        XCTAssertEqual(119, newestActivity)
    }

    func testPongSyncsClock() async throws {
        let manual = ManualClock(now: 10_000)
        let (store, _) = try PartyTestFixtures.makeStore()
        let clock = PartyServerClock(monotonicMs: { manual.now })
        let monotonic = { manual.now }
        let client = PartyClient(store: store, urlSession: .shared, clock: clock, monotonicMs: monotonic)
        await client.commitMembershipForTesting(
            serverBase: "https://default.example.com",
            membership: PartyTestFixtures.membership())
        let syncedBefore = await client.state.clockSynced
        XCTAssertFalse(syncedBefore)
        manual.now = 10_100
        await client.receiveForTesting(
            #"{"type":"pong","clientMs":10000,"serverMs":50000}"#)
        let state = await client.state
        XCTAssertTrue(state.clockSynced)
        XCTAssertEqual(100, state.roundTripMs)
    }

    func testWelcomeAppliesSnapshot() async throws {
        let client = try await makeClient()
        await client.commitMembershipForTesting(
            serverBase: "https://default.example.com",
            membership: PartyTestFixtures.membership())
        let text = String(
            data: try FixtureData.load("party-welcome.json"), encoding: .utf8)!
        await client.receiveForTesting(text)
        let state = await client.state
        XCTAssertEqual("J4M001", state.code)
        XCTAssertEqual("dQw4w9WgXcQ", state.playback.track?.videoId)
        XCTAssertEqual(4, state.queue.items.count)
        XCTAssertTrue(state.queue.items[3].fromAutoplay)
    }

    func testCreateFallsBackToDefaultServerWhenCustomServerIsUnreachable() async throws {
        let (store, _) = try PartyTestFixtures.makeStore()
        store.setCustomServer("https://custom.example.com")
        let created = try URLProtocolStub.Response.json(
            encoding: PartyTestFixtures.membership(code: "D3F4UL"))
        let stub = URLProtocolStub()
        stub.register(host: "custom.example.com", response: .failure(.cannotConnectToHost))
        stub.register(host: "default.example.com", path: "/api/parties", method: "POST", response: created)
        let client = PartyClient(
            store: store, urlSession: stub.makeSession(), identityProvider: FixedIdentity())

        let result = await client.createParty()
        await client.leaveParty()

        XCTAssertEqual(.success("D3F4UL"), result)
        // The custom host is tried first; a create that skipped it would still pass the line above.
        let hosts = stub.requests.compactMap { $0.url?.host }
        let custom = try XCTUnwrap(hosts.firstIndex(of: "custom.example.com"), "the custom server was never asked: \(hosts)")
        let standard = try XCTUnwrap(hosts.firstIndex(of: "default.example.com"), "the default server was never asked: \(hosts)")
        XCTAssertLessThan(custom, standard)
    }
}

private enum FixtureData {
    static func load(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)!
        return try Data(contentsOf: url)
    }
}

private struct FixedIdentity: PartyIdentityProvider {
    func partyIdentity() async -> PartyIdentity? {
        PartyIdentity(userId: "u-1", deviceId: "d-1", displayName: "Host")
    }
}
