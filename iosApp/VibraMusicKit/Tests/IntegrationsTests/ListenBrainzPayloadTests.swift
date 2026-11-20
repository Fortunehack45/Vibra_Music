import VibraMusicCore
import VibraMusicTestSupport
import Foundation
import XCTest
@testable import Integrations

/// ListenBrainz `playing_now` / `single` payloads, stubbed at the HTTP layer.
/// No live account is available here; everything runs offline.
final class ListenBrainzPayloadTests: XCTestCase {
    private func song() -> Song {
        Song(videoId: "v", title: "Believe", artist: "Anitta & Shakira", durationText: "3:47", albumName: "Versions")
    }

    private func json(_ data: Data?) throws -> [String: Any] {
        let data = try XCTUnwrap(data)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func metadata(from body: [String: Any]) throws -> [String: Any] {
        let payload = try XCTUnwrap(body["payload"] as? [[String: Any]])
        XCTAssertEqual(payload.count, 1)
        return try XCTUnwrap(payload.first?["track_metadata"] as? [String: Any])
    }

    func testPlayingNowPayload() throws {
        let body = try json(ListenBrainzClient.playingNowBody(song: song(), positionMs: 64_000))
        XCTAssertEqual(body["listen_type"] as? String, "playing_now")
        let meta = try metadata(from: body)
        XCTAssertEqual(meta["artist_name"] as? String, "Anitta & Shakira")
        XCTAssertEqual(meta["track_name"] as? String, "Believe")
        XCTAssertEqual(meta["release_name"] as? String, "Versions")
        let info = try XCTUnwrap(meta["additional_info"] as? [String: Any])
        XCTAssertEqual(info["position_ms"] as? Int, 64_000)
        XCTAssertEqual(info["duration_ms"] as? Int, 227_000)
        XCTAssertEqual(info["submission_client"] as? String, "Vibra Music")
    }

    func testPlayingNowPrimaryArtistOnly() throws {
        let body = try json(
            ListenBrainzClient.playingNowBody(song: song(), positionMs: 0, primaryArtistOnly: true)
        )
        let meta = try metadata(from: body)
        XCTAssertEqual(meta["artist_name"] as? String, "Anitta")
    }

    func testPlayingNowOmitsUnknownDuration() throws {
        var track = song()
        track.durationText = nil
        let body = try json(ListenBrainzClient.playingNowBody(song: track, positionMs: 0))
        let meta = try metadata(from: body)
        let info = try XCTUnwrap(meta["additional_info"] as? [String: Any])
        XCTAssertNil(info["duration_ms"])
    }

    func testPlayingNowEscapesSpecialCharacters() throws {
        let tricky = Song(videoId: "v", title: "Say \"hi\" \\ bye", artist: "A\nB", durationText: "1:00")
        let body = try json(ListenBrainzClient.playingNowBody(song: tricky, positionMs: 1))
        let meta = try metadata(from: body)
        // Encoded as real JSON, so decoding round-trips the raw characters.
        XCTAssertEqual(meta["track_name"] as? String, "Say \"hi\" \\ bye")
        XCTAssertEqual(meta["artist_name"] as? String, "A\nB")
    }

    func testFinishedPayloadClampsAncientTimestamps() throws {
        let body = try json(
            ListenBrainzClient.finishedBody(song: song(), startMs: 1_000, endMs: 227_000, nowSeconds: 1_700_000_000)
        )
        XCTAssertEqual(body["listen_type"] as? String, "single")
        let payload = try XCTUnwrap((body["payload"] as? [[String: Any]])?.first)
        XCTAssertEqual(payload["listened_at"] as? Int, 1_700_000_000)
        let meta = try XCTUnwrap(payload["track_metadata"] as? [String: Any])
        let info = try XCTUnwrap(meta["additional_info"] as? [String: Any])
        XCTAssertEqual(info["start_ms"] as? Int, 1_000)
        XCTAssertEqual(info["end_ms"] as? Int, 227_000)
    }

    func testSubmitSendsTokenHeader() async throws {
        let stub = URLProtocolStub()
        stub.register(host: "api.listenbrainz.org", path: "/1/submit-listens", method: "POST", response: .json("{}"))
        let client = ListenBrainzClient(session: stub.makeSession())
        let ok = await client.submitPlayingNow(token: "TOKEN", song: song(), positionMs: 0)
        XCTAssertTrue(ok)
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token TOKEN")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testSubmitFailsClosed() async {
        let stub = URLProtocolStub()
        stub.register(
            host: "api.listenbrainz.org", path: "/1/submit-listens", method: "POST",
            response: .status(401)
        )
        let client = ListenBrainzClient(session: stub.makeSession())
        let badPlaying = await client.submitPlayingNow(token: "BAD", song: song(), positionMs: 0)
        XCTAssertFalse(badPlaying)
        let emptyToken = await client.submitPlayingNow(token: "", song: song(), positionMs: 0)
        XCTAssertFalse(emptyToken)
        let nilSong = await client.submitPlayingNow(token: "T", song: nil, positionMs: 0)
        XCTAssertFalse(nilSong)
        let badFinished = await client.submitFinished(token: "BAD", song: song(), startMs: 0, endMs: 1)
        XCTAssertFalse(badFinished)
    }
}
