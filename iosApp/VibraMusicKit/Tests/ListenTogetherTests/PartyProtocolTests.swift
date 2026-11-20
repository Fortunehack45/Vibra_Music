import VibraMusicTestSupport
import XCTest
@testable import ListenTogether

/// Message encoding against the Go protocol structs: every control frame carries exactly
/// the fields `applyControl` reads (and omits the rest), and every server frame decodes
/// into the models — verified against recorded server-shaped payloads.
final class PartyProtocolTests: XCTestCase {
    private func encoded(_ message: PartyControlMessage) throws -> [String: Any] {
        let data = try JSONEncoder().encode(message)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testSeekRequiresPositionMs() throws {
        let json = try encoded(.seek(to: 90_000))
        XCTAssertEqual("control", json["type"] as? String)
        XCTAssertEqual("seek", json["action"] as? String)
        XCTAssertEqual(90_000, json["positionMs"] as? Int)
        XCTAssertNil(json["track"])
    }

    func testPlayPauseCarryOptionalPositions() throws {
        XCTAssertNil(try encoded(.play())["positionMs"])
        XCTAssertEqual(42_000, try encoded(.play(at: 42_000))["positionMs"] as? Int)
        XCTAssertEqual(42_000, try encoded(.pause(at: 42_000))["positionMs"] as? Int)
    }

    func testSetTrackShape() throws {
        let track = PartyTrack(videoId: "v", title: "T", artist: "A", durationMs: 1_000)
        let json = try encoded(.setTrack(track, positionMs: 0, isPlaying: true))
        XCTAssertEqual("setTrack", json["action"] as? String)
        XCTAssertEqual(0, json["positionMs"] as? Int)
        XCTAssertEqual(true, json["isPlaying"] as? Bool)
        let wire = json["track"] as? [String: Any]
        XCTAssertEqual("v", wire?["videoId"] as? String)
        XCTAssertEqual(false, wire?["fromAutoplay"] as? Bool)
    }

    func testSetQueueShape() throws {
        let json = try encoded(.setQueue([PartyTrack(videoId: "a"), PartyTrack(videoId: "b")], index: 0))
        XCTAssertEqual("setQueue", json["action"] as? String)
        XCTAssertEqual(0, json["queueIndex"] as? Int)
        XCTAssertEqual(2, (json["queue"] as? [[String: Any]])?.count)
    }

    func testQueueDeltaShapes() throws {
        let add = try encoded(.queueAdd([PartyTrack(videoId: "x")], playNext: true))
        XCTAssertEqual("queueAdd", add["action"] as? String)
        XCTAssertEqual(true, add["playNext"] as? Bool)
        XCTAssertEqual(1, (add["tracks"] as? [[String: Any]])?.count)

        let remove = try encoded(.queueRemove(videoId: "x"))
        XCTAssertEqual("queueRemove", remove["action"] as? String)
        XCTAssertEqual("x", remove["videoId"] as? String)

        let clear = try encoded(.queueClear())
        XCTAssertEqual("queueClear", clear["action"] as? String)
        XCTAssertEqual(2, clear.count) // type + action only

        let move = try encoded(.queueMove(from: 2, to: 5, videoId: "x"))
        XCTAssertEqual("queueMove", move["action"] as? String)
        XCTAssertEqual(2, move["fromIndex"] as? Int)
        XCTAssertEqual(5, move["toIndex"] as? Int)
        XCTAssertEqual("x", move["videoId"] as? String)

        let moveBare = try encoded(.queueMove(from: 0, to: 1))
        XCTAssertNil(moveBare["videoId"])
    }

    func testMembershipShapes() throws {
        let kick = try encoded(.kick(memberId: "m-9"))
        XCTAssertEqual("kick", kick["action"] as? String)
        XCTAssertEqual("m-9", kick["memberId"] as? String)

        let size = try encoded(.setMaxMembers(4))
        XCTAssertEqual("setMaxMembers", size["action"] as? String)
        XCTAssertEqual(4, size["maxMembers"] as? Int)

        let autoplay = try encoded(.setAutoplay(true))
        XCTAssertEqual("setAutoplay", autoplay["action"] as? String)
        XCTAssertEqual(true, autoplay["enabled"] as? Bool)

        let lock = try encoded(.setHostOnlyControl(true))
        XCTAssertEqual("setHostOnlyControl", lock["action"] as? String)
        XCTAssertEqual(true, lock["enabled"] as? Bool)
    }

    func testStateFrameDecodesAgainstRecordedPayload() throws {
        let loader = FixtureLoader(bundle: .module)
        let message = try loader.decode(PartyServerMessage.self, from: "party-state.json")
        XCTAssertEqual(.state, message.type)
        let playback = try XCTUnwrap(message.playback)
        XCTAssertEqual(7, playback.seq)
        XCTAssertEqual("dQw4w9WgXcQ", playback.track?.videoId)
        XCTAssertEqual(3, playback.queueSeq)
        XCTAssertEqual(1, playback.queueIndex)
        XCTAssertEqual(4, playback.queueLength)
        XCTAssertTrue(playback.isPlaying)
        XCTAssertEqual(42_000, playback.positionMs)
        XCTAssertEqual(1_757_630_001_234, playback.anchorMs)
        XCTAssertEqual(42_350, playback.effectivePositionMs)
        XCTAssertEqual("m-2", playback.updatedBy)
        XCTAssertEqual("m-1", playback.startedBy)
        XCTAssertEqual("Host", playback.startedByName)
        XCTAssertTrue(playback.autoplayEnabled)
        XCTAssertEqual(212_000, playback.track?.durationMs)
        XCTAssertFalse(playback.track?.fromAutoplay ?? true)
    }

    func testWelcomeFrameDecodesAgainstRecordedPayload() throws {
        let loader = FixtureLoader(bundle: .module)
        let message = try loader.decode(PartyServerMessage.self, from: "party-welcome.json")
        XCTAssertEqual(.welcome, message.type)
        XCTAssertEqual("m-2", message.you?.memberId)
        XCTAssertFalse(message.you?.isHost ?? true)
        let party = try XCTUnwrap(message.party)
        XCTAssertEqual("J4M001", party.code)
        XCTAssertEqual(5, party.maxMembers)
        XCTAssertFalse(party.hostOnlyControl)
        XCTAssertEqual(2, party.members.count)
        XCTAssertTrue(party.members[0].isHost)
        XCTAssertEqual(3, party.queue.seq)
        XCTAssertEqual(4, party.queue.items.count)
        XCTAssertEqual("dQw4w9WgXcQ", party.queue.items[1].videoId)
        XCTAssertTrue(party.queue.items[3].fromAutoplay)
    }

    func testMembersPongActivityErrorByeFrames() throws {
        let decoder = JSONDecoder()

        let members = try decoder.decode(
            PartyServerMessage.self,
            from: #"{"type":"members","members":[{"memberId":"m-1","isHost":true}],"maxMembers":4,"hostOnlyControl":true,"serverMs":1}"#.data(using: .utf8)!)
        XCTAssertEqual(.members, members.type)
        XCTAssertEqual(4, members.maxMembers)
        XCTAssertEqual(true, members.hostOnlyControl)
        XCTAssertEqual("m-1", members.members?.first?.memberId)

        // Members frames from an older server omit the lock: nil, not false.
        let legacy = try decoder.decode(
            PartyServerMessage.self,
            from: #"{"type":"members","members":[],"maxMembers":5}"#.data(using: .utf8)!)
        XCTAssertNil(legacy.hostOnlyControl)

        // Pong echoes clientMs in whatever representation the client sent.
        let pong = try decoder.decode(
            PartyServerMessage.self,
            from: #"{"type":"pong","clientMs":1757630000000,"serverMs":1757630000123}"#.data(using: .utf8)!)
        XCTAssertEqual(1_757_630_000_000, pong.clientMs)
        XCTAssertEqual(1_757_630_000_123, pong.serverMs)

        let activity = try decoder.decode(
            PartyServerMessage.self,
            from: #"{"type":"activity","action":"next","by":"Host","detail":"Skipped","atMs":99}"#.data(using: .utf8)!)
        XCTAssertEqual("next", activity.action)
        XCTAssertEqual("Host", activity.by)
        XCTAssertEqual("Skipped", activity.detail)
        XCTAssertEqual(99, activity.atMs)

        let error = try decoder.decode(
            PartyServerMessage.self,
            from: #"{"type":"error","error":"host_only","message":"Only the host can."}"#.data(using: .utf8)!)
        XCTAssertEqual("host_only", error.error)

        let bye = try decoder.decode(
            PartyServerMessage.self,
            from: #"{"type":"bye","reason":"kicked"}"#.data(using: .utf8)!)
        XCTAssertEqual("kicked", bye.reason)
    }

    func testUnknownFrameTypesAreIgnored() throws {
        let message = try JSONDecoder().decode(
            PartyServerMessage.self,
            from: #"{"type":"future","serverMs":1}"#.data(using: .utf8)!)
        XCTAssertNil(message.type)
        XCTAssertEqual("future", message.rawType)
    }

    func testJoinRequestOmitsUnsetOptionals() throws {
        let data = try JSONEncoder().encode(PartyJoinRequest(
            userId: "u", deviceId: "d", displayName: "N"))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(json["maxMembers"])
        XCTAssertNil(json["autoplayEnabled"])
        XCTAssertNil(json["avatarUrl"])
        XCTAssertEqual("N", json["displayName"] as? String)
    }

    func testApiErrorReadsServerShape() throws {
        let parsed = try JSONDecoder().decode(
            PartyApiError.self,
            from: #"{"error":"party_full","message":"This party is full (5 devices)."}"#.data(using: .utf8)!)
        XCTAssertEqual("party_full", parsed.code)
        XCTAssertEqual("This party is full (5 devices).", parsed.message)
    }
}
