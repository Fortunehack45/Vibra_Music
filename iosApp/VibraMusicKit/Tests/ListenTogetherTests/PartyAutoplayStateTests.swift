import XCTest
@testable import ListenTogether

/// Ports the party-state halves of `PartyAutoplayTest`: the inputs AutoPlay's election
/// reads — the party's own switch, the host's liveness, the lock — survive the trip from
/// wire to state. The election itself (`AutoplayPolicy`) lives in PlaybackQueue and is
/// tested there; this pins that this module hands it the truth.
final class PartyAutoplayStateTests: XCTestCase {
    private func member(_ id: String, host: Bool = false, connected: Bool = true) -> PartyMember {
        PartyMember(memberId: id, displayName: id, isHost: host, connected: connected)
    }

    func testMembersFrameCarriesHostLivenessForElection() async throws {
        let (store, _) = try PartyTestFixtures.makeStore()
        let client = PartyTestFixtures.makeClient(store: store)
        await client.commitMembershipForTesting(
            serverBase: "https://default.example.com",
            membership: PartyTestFixtures.membership(you: member("aa")))
        await client.receiveForTesting(
            #"{"type":"members","members":[{"memberId":"zz","displayName":"zz","isHost":true,"connected":false},{"memberId":"mm","displayName":"mm","isHost":false,"connected":true},{"memberId":"aa","displayName":"aa","isHost":false,"connected":true}],"maxMembers":5}"#)
        let state = await client.state
        XCTAssertEqual("zz", state.members.first(where: \.isHost)?.memberId)
        let hostConnected = state.members.first(where: \.isHost)?.connected ?? true
        XCTAssertFalse(hostConnected)
        let connectedIds = state.members.filter(\.connected).map(\.memberId).sorted()
        XCTAssertEqual(["aa", "mm"], connectedIds)
    }

    func testLockedPartyStillNamesItsHost() async throws {
        let (store, _) = try PartyTestFixtures.makeStore()
        let client = PartyTestFixtures.makeClient(store: store)
        await client.commitMembershipForTesting(
            serverBase: "https://default.example.com",
            membership: PartyTestFixtures.membership(you: member("aa")))
        await client.receiveForTesting(
            #"{"type":"members","members":[{"memberId":"zz","displayName":"zz","isHost":true,"connected":true},{"memberId":"aa","displayName":"aa","isHost":false,"connected":true}],"maxMembers":5,"hostOnlyControl":true}"#)
        let state = await client.state
        XCTAssertTrue(state.controlsLocked)
        XCTAssertEqual("zz", state.members.first(where: \.isHost)?.memberId)
    }

    func testAutoplaySurvivesAStateFrame() async throws {
        // The heartbeat re-states the party's switch; the client must apply it, not keep
        // whatever the phone believed.
        let (store, _) = try PartyTestFixtures.makeStore()
        let client = PartyTestFixtures.makeClient(store: store)
        await client.commitMembershipForTesting(
            serverBase: "https://default.example.com",
            membership: PartyTestFixtures.membership(
                playback: PartyPlayback(seq: 1, autoplayEnabled: false)))
        let autoplayBefore = await client.state.playback.autoplayEnabled
        XCTAssertFalse(autoplayBefore)
        await client.receiveForTesting(
            #"{"type":"state","playback":{"seq":2,"queueSeq":0,"queueIndex":-1,"isPlaying":false,"positionMs":0,"anchorMs":0,"autoplayEnabled":true}}"#)
        let autoplayAfter = await client.state.playback.autoplayEnabled
        XCTAssertTrue(autoplayAfter)
    }

    func testHostOnlySurvivesAMembersFrame() async throws {
        let (store, _) = try PartyTestFixtures.makeStore()
        let client = PartyTestFixtures.makeClient(store: store)
        await client.commitMembershipForTesting(
            serverBase: "https://default.example.com",
            membership: PartyTestFixtures.membership())
        let lockBefore = await client.state.hostOnlyControl
        XCTAssertFalse(lockBefore)
        await client.receiveForTesting(
            #"{"type":"members","members":[{"memberId":"m-1","displayName":"Host","isHost":true,"connected":true}],"maxMembers":5,"hostOnlyControl":true}"#)
        let lockAfter = await client.state.hostOnlyControl
        XCTAssertTrue(lockAfter)
    }
}
