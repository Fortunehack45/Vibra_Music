import VibraMusicCore
import Integrations
import XCTest
@testable import VibraMusic

/// PORTING §2.9 "Scrobbling": the Last.fm password login, and what a played track sends to
/// Last.fm and ListenBrainz.
@MainActor
final class ScrobblingWiringTests: XCTestCase {
    /// The sign-in the Account screen runs (`AccountScrobbling.liveLastfmSignIn`), against a server
    /// standing in for Last.fm at the endpoint Settings names: a signed mobile-session request,
    /// and the session it answers with.
    func testThePasswordLoginSendsASignedMobileSessionRequestAndReturnsTheSession() async throws {
        let server = try LoopbackHTTPServer { _ in .json(#"{"session":{"name":"maya","key":"sk-live","subscriber":0}}"#) }
        try await server.start(for: self)
        let settings = makeTestSettings()
        settings.lastfmApiKey = "api-key"
        settings.lastfmSecret = "api-secret"
        settings.lastfmEndpoint = server.baseURL.appending(path: "2.0/").absoluteString

        let session = try await AccountScrobbling.liveLastfmSignIn(settings: settings)("maya", "hunter2")

        XCTAssertEqual(session, LastFMSessionInfo(username: "maya", sessionKey: "sk-live"))
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.method, "POST")
        var fields = request.form
        XCTAssertEqual(fields["method"], "auth.getMobileSession")
        XCTAssertEqual(fields["username"], "maya")
        XCTAssertEqual(fields["password"], "hunter2")
        XCTAssertEqual(fields["api_key"], "api-key")
        let signature = fields.removeValue(forKey: "api_sig")
        fields.removeValue(forKey: "format")
        XCTAssertEqual(signature, LastFMSignature.signature(params: fields, secret: "api-secret"), "signed over every field, with the secret")
    }

    /// A play, through the observer the app registers for it: Last.fm hears "now playing" at the
    /// start, then the scrobble once the track has played its share.
    func testAPlayedTrackIsSentToLastfmAsNowPlayingThenScrobbled() async throws {
        let http = scrobblerStub()
        let harness = PlayerHarness(test: self)
        let settings = harness.settings
        settings.lastfmApiKey = "api-key"
        settings.lastfmSecret = "api-secret"
        settings.lastfmSessionKey = "sk-live"
        settings.lastfmUsername = "maya"
        settings.lastfmEnabled = true
        settings.lastfmScrobbleEnabled = true
        settings.lastfmNowPlaying = true
        // A six-second track, scrobbled after a tenth of it.
        settings.scrobbleMinDuration = 1
        settings.scrobbleDelayPercent = 0.1
        harness.player.addObserver(ScrobblingObserver(settings: settings, session: http.session))
        let song = try harness.song("scrobble001", seconds: 6)

        harness.player.play([song], startAt: 0)

        let lastFM = { http.requests.filter { $0.url.host == "ws.audioscrobbler.com" } }
        await waitUntil("Last.fm hears now playing, then the scrobble") { lastFM().count >= 2 }
        let calls = lastFM().map(\.form)
        XCTAssertEqual(calls.map { $0["method"] }, ["track.updateNowPlaying", "track.scrobble"])
        guard calls.count == 2 else { return }
        XCTAssertEqual(calls[0]["artist"], song.artist)
        XCTAssertEqual(calls[0]["track"], song.title)
        XCTAssertEqual(calls[0]["sk"], "sk-live")
        XCTAssertEqual(calls[1]["artist[0]"], song.artist)
        XCTAssertEqual(calls[1]["track[0]"], song.title)
        XCTAssertEqual(calls[1]["duration[0]"], "6")
        XCTAssertTrue(http.requests.allSatisfy { $0.url.host == "ws.audioscrobbler.com" }, "nothing went to ListenBrainz, which is off")
    }

    /// ListenBrainz hears "playing now" when a track starts, and the finished listen when the next
    /// one takes over.
    func testPlayingNowAndTheFinishedListenReachListenBrainzWithTheToken() async throws {
        let http = scrobblerStub()
        let harness = PlayerHarness(test: self)
        let settings = harness.settings
        settings.listenBrainzEnabled = true
        settings.listenBrainzToken = "lb-token"
        harness.player.addObserver(ScrobblingObserver(settings: settings, session: http.session))
        let first = try harness.song("brainz00001", seconds: 6)
        let second = try harness.song("brainz00002", seconds: 6)

        harness.player.play([first, second], startAt: 0)
        await waitUntil("the first track is playing now") { http.requests.count == 1 }
        // Played to its end, not skipped: only a track that ended is a finished listen.

        await waitUntil("the finished listen and the second track's playing now arrive", timeout: 30) { http.requests.count == 3 }
        let listens = http.requests.map { request -> String in
            let metadata = ((request.json["payload"] as? [[String: Any]])?.first?["track_metadata"] as? [String: Any]) ?? [:]
            return "\(request.json["listen_type"] as? String ?? "?") \(metadata["track_name"] as? String ?? "?")"
        }
        XCTAssertEqual(listens.sorted(), ["playing_now \(first.title)", "playing_now \(second.title)", "single \(first.title)"])
        XCTAssertTrue(http.requests.allSatisfy { $0.headers["authorization"] == "Token lb-token" })
        XCTAssertTrue(http.requests.allSatisfy { $0.url.host == "api.listenbrainz.org" })
    }

    /// A row restored paused and played later: the finished listen starts when it was first heard,
    /// not when it was restored.
    func testAFinishedListenStartsWhenARestoredRowIsPlayed() async throws {
        let http = scrobblerStub()
        let settings = makeTestSettings()
        settings.listenBrainzEnabled = true
        settings.listenBrainzToken = "lb-token"
        let observer = ScrobblingObserver(settings: settings, session: http.session)
        let first = Song(videoId: "brainz00003", title: "Restored", artist: "A", durationText: "3:00")
        let second = Song(videoId: "brainz00004", title: "Next", artist: "B", durationText: "3:00")

        observer.playback(didStart: first, durationMs: 180_000, isPlaying: false, previous: nil, previousListened: false, previousPositionMs: 0)
        try await Task.sleep(for: .milliseconds(300))
        let pressedPlayMs = Int64(Date().timeIntervalSince1970 * 1_000)
        observer.playback(didChangePlaying: true, song: first, positionMs: 0, durationMs: 180_000)
        observer.playback(didStart: second, durationMs: 180_000, isPlaying: true, previous: first, previousListened: true, previousPositionMs: 180_000)

        await waitUntil("the finished listen arrives") { http.requests.contains { $0.json["listen_type"] as? String == "single" } }
        let single = try XCTUnwrap(http.requests.first { $0.json["listen_type"] as? String == "single" })
        let metadata = try XCTUnwrap((single.json["payload"] as? [[String: Any]])?.first?["track_metadata"] as? [String: Any])
        let info = try XCTUnwrap(metadata["additional_info"] as? [String: Any])
        let startMs = try XCTUnwrap((info["start_ms"] as? NSNumber)?.int64Value)
        XCTAssertGreaterThanOrEqual(startMs, pressedPlayMs, "started at the play, not 300 ms earlier at the restore")
    }

    private func scrobblerStub() -> HTTPRecordingStub {
        HTTPRecordingStub { request in
            request.url.host == "api.listenbrainz.org" ? .json(#"{"status":"ok"}"#) : .json("{}")
        }
    }
}
