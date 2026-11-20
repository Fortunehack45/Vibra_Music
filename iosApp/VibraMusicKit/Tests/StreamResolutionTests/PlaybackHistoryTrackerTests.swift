import XCTest
@testable import StreamResolution

/// Registering plays in the account's history (Android's `PlaybackTracker`), offline.
final class PlaybackHistoryTrackerTests: XCTestCase {
    private let video = "dQw4w9WgXcQ"
    private let signedIn = StreamAuthSession(
        cookie: "SAPISID=secret; SID=x", authUser: "1", pageId: "BRAND", dataSyncId: "SYNC",
        visitorData: "CgSESSION", webRemixClientVersion: "1.20260930.01.00"
    )

    private final class Box: @unchecked Sendable {
        var tracking: StreamStubResponse = .json(StreamFixture.data("player_web_remix_cipher.json"))
        var sts: Int? = 20717
    }

    private func makeTracker(
        auth: StreamAuthSession?, box: Box = Box(), online: Bool = true
    ) -> (PlaybackHistoryTracker, StreamStubServer) {
        let server = StreamStubServer { request in
            if request.url.host == "music.youtube.com" { return box.tracking }
            if request.url.host == "s.youtube.com" { return StreamStubResponse(status: 204) }
            return StreamStubResponse(status: 404)
        }
        let tracker = PlaybackHistoryTracker(
            session: server.session, auth: FixedAuthProvider(session: auth),
            signatureTimestamp: { box.sts }, visitorData: { "CgANONYMOUS" },
            isNetworkAvailable: { online }, openRetryDelay: 0.01
        )
        return (tracker, server)
    }

    private func pings(_ server: StreamStubServer, _ kind: String) -> [StreamStubRequest] {
        server.requests(host: "s.youtube.com").filter { $0.url.path == "/api/stats/\(kind)" }
    }

    private func query(_ request: StreamStubRequest, _ name: String) -> [String] {
        URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == name }.compactMap(\.value) ?? []
    }

    func testGuestsRegisterNothing() async {
        let (tracker, server) = makeTracker(auth: nil)
        await tracker.onPlaying(video)
        await tracker.waitUntilIdle()
        XCTAssertTrue(server.requests.isEmpty)
    }

    /// A local file's URI or an add-on's id is not a videoId; asking Google about it cannot succeed.
    func testNonYouTubeIdsAndOfflinePlaysAreSkipped() async {
        let (tracker, server) = makeTracker(auth: signedIn)
        await tracker.onPlaying("content://media/external/audio/1")
        await tracker.onPlaying("addon:123")
        let (offline, offlineServer) = makeTracker(auth: signedIn, online: false)
        await offline.onPlaying(video)
        await tracker.waitUntilIdle()
        await offline.waitUntilIdle()
        XCTAssertTrue(server.requests.isEmpty)
        XCTAssertTrue(offlineServer.requests.isEmpty)
    }

    func testPlayingRegistersAHistoryEntryWithTheSession() async throws {
        let (tracker, server) = makeTracker(auth: signedIn)
        let updates = await tracker.registeredPlayUpdates()
        await tracker.onPlaying(video)
        await tracker.waitUntilIdle()

        let trackingRequest = try XCTUnwrap(server.requests(host: "music.youtube.com").first)
        XCTAssertEqual(trackingRequest.url.path, "/youtubei/v1/player")
        XCTAssertEqual(trackingRequest.header("Cookie"), signedIn.cookie)
        XCTAssertTrue(trackingRequest.header("Authorization")?.hasPrefix("SAPISIDHASH ") == true)
        XCTAssertEqual(trackingRequest.header("X-Goog-AuthUser"), "1")
        XCTAssertEqual(trackingRequest.header("X-Goog-PageId"), "BRAND")
        XCTAssertEqual(trackingRequest.header("X-Goog-Visitor-Id"), "CgSESSION", "the session's own visitor id")
        XCTAssertEqual(trackingRequest.header("X-YouTube-Client-Name"), "67")
        let body = try XCTUnwrap(trackingRequest.jsonBody)
        let context = try XCTUnwrap(body["context"] as? [String: Any])
        XCTAssertEqual((context["user"] as? [String: Any])?["onBehalfOfUser"] as? String, "SYNC")
        XCTAssertEqual((context["client"] as? [String: Any])?["clientVersion"] as? String, "1.20260930.01.00")
        let playback = try XCTUnwrap((body["playbackContext"] as? [String: Any])?["contentPlaybackContext"] as? [String: Any])
        XCTAssertEqual(playback["signatureTimestamp"] as? Int, 20717, "the one gate on getting a tracking block")

        let ping = try XCTUnwrap(pings(server, "playback").first)
        XCTAssertEqual(query(ping, "ver"), ["2"])
        XCTAssertEqual(query(ping, "c"), ["WEB_REMIX"])
        XCTAssertEqual(query(ping, "cver"), ["1.20260930.01.00"])
        XCTAssertEqual(query(ping, "cpn").first?.count, 16)
        XCTAssertEqual(query(ping, "cplayer"), ["UNIPLAYER"])
        XCTAssertEqual(query(ping, "el"), ["detailpage"], "el comes from the base URL, not repeated")
        XCTAssertEqual(ping.header("Cookie"), signedIn.cookie)
        XCTAssertEqual(ping.header("X-Goog-PageId"), "BRAND")
        XCTAssertEqual(ping.header("Origin"), "https://music.youtube.com")

        let count = await tracker.registeredPlays
        XCTAssertEqual(count, 1)
        var iterator = updates.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, 1)
    }

    /// Pause/resume must not register a second play.
    func testTheSameTrackIsRegisteredOnce() async {
        let (tracker, server) = makeTracker(auth: signedIn)
        await tracker.onPlaying(video)
        await tracker.onPlaying(video)
        await tracker.waitUntilIdle()
        await tracker.onPlaying(video)
        await tracker.waitUntilIdle()
        XCTAssertEqual(pings(server, "playback").count, 1)
    }

    func testProgressSendsAtrThenWatchtimeEveryThirtySeconds() async throws {
        let (tracker, server) = makeTracker(auth: signedIn)
        await tracker.onPlaying(video)
        await tracker.waitUntilIdle()
        let cpn = try XCTUnwrap(query(XCTUnwrap(pings(server, "playback").first), "cpn").first)

        await tracker.onProgress(videoId: video, positionSeconds: 3)
        await tracker.waitUntilIdle()
        XCTAssertTrue(pings(server, "atr").isEmpty)
        await tracker.onProgress(videoId: video, positionSeconds: 5)
        await tracker.waitUntilIdle()
        let atr = try XCTUnwrap(pings(server, "atr").first)
        XCTAssertEqual(query(atr, "cpn"), [cpn], "one nonce ties the three pings to one play")
        XCTAssertTrue(query(atr, "cplayer").isEmpty, "atr is sent as-is")

        await tracker.onProgress(videoId: video, positionSeconds: 29)
        await tracker.waitUntilIdle()
        XCTAssertTrue(pings(server, "watchtime").isEmpty)
        await tracker.onProgress(videoId: video, positionSeconds: 30)
        await tracker.waitUntilIdle()
        await tracker.onProgress(videoId: video, positionSeconds: 45)
        await tracker.waitUntilIdle()
        await tracker.onProgress(videoId: video, positionSeconds: 61)
        await tracker.waitUntilIdle()
        let watchtime = pings(server, "watchtime")
        XCTAssertEqual(watchtime.map { query($0, "et") }, [["30"], ["61"]])
        XCTAssertEqual(query(watchtime[0], "st"), ["0"])
        XCTAssertEqual(query(watchtime[0], "cmt"), ["30"])
        XCTAssertEqual(query(watchtime[0], "state"), ["playing"])
        XCTAssertTrue(query(watchtime[0], "final").isEmpty)
        XCTAssertEqual(query(watchtime[0], "cpn"), [cpn])
        XCTAssertEqual(pings(server, "atr").count, 1)
    }

    /// Gating on the position being flushed, not the one confirmed, so a slow ping is not repeated.
    func testProgressWhileAFlushIsInFlightDoesNotRepeatIt() async {
        let (tracker, server) = makeTracker(auth: signedIn)
        await tracker.onPlaying(video)
        await tracker.waitUntilIdle()
        await tracker.onProgress(videoId: video, positionSeconds: 30)
        await tracker.onProgress(videoId: video, positionSeconds: 35)
        await tracker.onProgress(videoId: video, positionSeconds: 40)
        await tracker.waitUntilIdle()
        XCTAssertEqual(pings(server, "watchtime").count, 1)
    }

    /// A track skipped at two minutes is reported as two minutes, and closed out.
    func testTrackChangeFlushesAFinalReport() async throws {
        let (tracker, server) = makeTracker(auth: signedIn)
        await tracker.onPlaying(video)
        await tracker.waitUntilIdle()
        await tracker.onTrackChanged(positionSeconds: 95)
        await tracker.waitUntilIdle()
        let final = try XCTUnwrap(pings(server, "watchtime").last)
        XCTAssertEqual(query(final, "et"), ["95"])
        XCTAssertEqual(query(final, "final"), ["1"])
        XCTAssertEqual(query(final, "state"), ["paused"])
        // The old session is gone: progress for it does nothing.
        await tracker.onProgress(videoId: video, positionSeconds: 200)
        await tracker.waitUntilIdle()
        XCTAssertEqual(pings(server, "watchtime").count, 1)
    }

    func testPlaybackFinishedClosesThePlayEvenAtAReportedPosition() async throws {
        let (tracker, server) = makeTracker(auth: signedIn)
        await tracker.onPlaying(video)
        await tracker.waitUntilIdle()
        await tracker.onProgress(videoId: video, positionSeconds: 30)
        await tracker.waitUntilIdle()
        await tracker.onPlaybackFinished(positionSeconds: 30)
        await tracker.waitUntilIdle()
        let reports = pings(server, "watchtime")
        XCTAssertEqual(reports.count, 2, "the final=1 is what matters, not the number")
        XCTAssertEqual(query(reports[1], "final"), ["1"])
    }

    /// The queue is cleared while a session is still opening: the play must not register after the
    /// fact, since nothing would ever close it.
    func testAPlayStillOpeningWhenThePlaybackEndsIsNotRegistered() async {
        let (release, releaseNow) = AsyncStream<Void>.makeStream()
        let server = StreamStubServer { request in
            if request.url.host == "music.youtube.com" { return .json(StreamFixture.data("player_web_remix_cipher.json")) }
            return StreamStubResponse(status: 204)
        }
        let tracker = PlaybackHistoryTracker(
            session: server.session, auth: FixedAuthProvider(session: signedIn),
            signatureTimestamp: {
                for await _ in release { break }
                return 20717
            },
            visitorData: { "CgANONYMOUS" }, isNetworkAvailable: { true }, openRetryDelay: 0.01
        )
        await tracker.onPlaying(video)
        await tracker.onPlaybackFinished(positionSeconds: 0)
        releaseNow.yield()
        await tracker.waitUntilIdle()

        let registered = await tracker.registeredPlays
        XCTAssertEqual(registered, 0)
        XCTAssertEqual(pings(server, "playback").count, 0)
    }

    func testEachPlayGetsItsOwnNonce() async throws {
        let (tracker, server) = makeTracker(auth: signedIn)
        await tracker.onPlaying(video)
        await tracker.waitUntilIdle()
        await tracker.onTrackChanged(positionSeconds: 10)
        await tracker.onPlaying("kJQP7kiw5Fk")
        await tracker.waitUntilIdle()
        let nonces = pings(server, "playback").flatMap { query($0, "cpn") }
        XCTAssertEqual(nonces.count, 2)
        XCTAssertNotEqual(nonces[0], nonces[1])
        let count = await tracker.registeredPlays
        XCTAssertEqual(count, 2)
    }

    /// No timestamp yet is a failure worth retrying; three attempts, then the play is written off.
    func testMissingSignatureTimestampIsRetried() async {
        let box = Box()
        box.sts = nil
        let (tracker, server) = makeTracker(auth: signedIn, box: box)
        await tracker.onPlaying(video)
        await tracker.waitUntilIdle()
        XCTAssertTrue(server.requests.isEmpty)
        let count = await tracker.registeredPlays
        XCTAssertEqual(count, 0)
    }

    func testTransportFailuresAreRetriedThreeTimes() async {
        let box = Box()
        box.tracking = StreamStubResponse(status: 503)
        let (tracker, server) = makeTracker(auth: signedIn, box: box)
        await tracker.onPlaying(video)
        await tracker.waitUntilIdle()
        XCTAssertEqual(server.requests(host: "music.youtube.com").count, 3)
        XCTAssertTrue(pings(server, "playback").isEmpty)
    }

    /// No tracking block is a verdict: the same timestamp gets the same answer.
    func testMissingTrackingBlockIsNotRetried() async {
        let box = Box()
        box.tracking = .json(Data(#"{"playabilityStatus":{"status":"UNPLAYABLE","reason":"The page needs to be reloaded."}}"#.utf8))
        let (tracker, server) = makeTracker(auth: signedIn, box: box)
        await tracker.onPlaying(video)
        await tracker.waitUntilIdle()
        XCTAssertEqual(server.requests(host: "music.youtube.com").count, 1)
        XCTAssertTrue(pings(server, "playback").isEmpty)
    }

    func testAnonymousVisitorIdStandsInWhenTheSessionHasNone() async throws {
        let (tracker, server) = makeTracker(auth: StreamAuthSession(cookie: "SAPISID=x"))
        await tracker.onPlaying(video)
        await tracker.waitUntilIdle()
        XCTAssertEqual(server.requests(host: "music.youtube.com").first?.header("X-Goog-Visitor-Id"), "CgANONYMOUS")
        XCTAssertEqual(pings(server, "playback").first?.header("X-Goog-AuthUser"), "0")
    }

    /// A task cancelled while queued on the gate throws instead of leaking a waiter, and the
    /// gate keeps serving afterwards.
    func testCancelledGateWaiterThrowsAndTheGateKeepsWorking() async throws {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            func set() { lock.withLock { value = true } }
            func get() -> Bool { lock.withLock { value } }
        }
        let gate = SerialGate()
        let holding = Flag()
        let holder = Task<Int, Error> {
            try await gate.run {
                holding.set()
                try await Task.sleep(nanoseconds: 300_000_000)
                return 7
            }
        }
        for _ in 0..<1000 where !holding.get() {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(holding.get(), "holder never took the gate")
        let waiter = Task<Int, Error> { try await gate.run { 42 } }
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("cancelled waiter should throw")
        } catch is CancellationError {
        }
        let held = try await holder.value
        XCTAssertEqual(held, 7)
        let reopened = try await gate.run { 1 }
        XCTAssertEqual(reopened, 1, "gate serves after a cancelled waiter")
    }
}
