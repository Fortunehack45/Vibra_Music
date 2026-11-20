import XCTest
@testable import StreamResolution

/// `StreamResolver`: probe gating, the caches and verdict memory, coalescing, refusal feedback
/// and the download path — offline against `FakeYouTube`.
final class StreamResolverTests: XCTestCase {
    private let video = "dQw4w9WgXcQ"

    func testResolvesToAProbedAACStreamWithItsHeaders() async throws {
        let youtube = FakeYouTube()
        let stream = try await youtube.resolver().resolve(video)
        XCTAssertEqual(stream.profileId, "visionos")
        XCTAssertEqual(stream.itag, 140)
        XCTAssertTrue(stream.isAVPlayerCompatible)
        XCTAssertEqual(stream.mediaHeaders["User-Agent"], StreamPlayerClient.visionOSUserAgent)
        let probe = try XCTUnwrap(youtube.mediaRequests.first)
        XCTAssertEqual(probe.header("Range"), "bytes=1048576-2097151", "probed past the first megabyte")
        XCTAssertEqual(probe.header("User-Agent"), StreamPlayerClient.visionOSUserAgent)
    }

    func testLowCeilingResolvesTheSmallAACRung() async throws {
        let stream = try await FakeYouTube().resolver(ceiling: StreamAudioQuality.low.maxKbps).resolve(video)
        XCTAssertEqual(stream.itag, 139)
    }

    func testInvalidIdsAreRejectedWithoutARequest() async {
        let youtube = FakeYouTube()
        for id in ["content://media/1", "short", "dQw4w9WgXcQ!"] {
            do {
                _ = try await youtube.resolver().resolve(id)
                XCTFail(id)
            } catch let error as StreamResolutionError {
                XCTAssertEqual(error, .invalidVideoId(id))
            } catch {
                XCTFail("\(error)")
            }
        }
        XCTAssertTrue(youtube.server.requests.isEmpty)
    }

    // MARK: Probe gating

    /// A URL that 403s past the first megabyte (ANDROID_VR today) is never handed out.
    func testRefusedURLMovesTheWalkToTheNextClient() async throws {
        let youtube = FakeYouTube()
        youtube.media("VISIONOS", StreamStubResponse(status: 403, headers: ["Content-Type": "text/plain"]))
        let stream = try await youtube.resolver().resolve(video)
        XCTAssertEqual(stream.profileId, "android_vr")
    }

    /// The embedded player's fresh URLs answer 403 for their first seconds. While another client can
    /// play the track, the walk doesn't sleep through that on the play path: it moves on at
    /// once. (The embedded player's id on a client the fake models; its URL keeps refusing.)
    func testAWarmingUpURLDoesNotHoldTheWalk() async throws {
        let youtube = FakeYouTube()
        let embedded = StreamClientProfile(
            id: StreamClientProfile.webEmbedded.id, clientName: "ANDROID_VR", clientVersion: "1.65.10", clientNameId: "28",
            userAgent: StreamPlayerClient.androidVR.userAgent, endpointHost: "www.youtube.com", requiresVisitorData: true
        )
        youtube.media("ANDROID_VR", StreamStubResponse(status: 403, headers: ["Content-Type": "text/plain"]))
        let started = Date()
        let stream = try await youtube.resolver(catalog: [embedded, .visionOS]).resolve(video)
        XCTAssertEqual(stream.profileId, "visionos")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the walk slept through the embedded player's warm-up")
    }

    /// A probe that never got an answer (here a 500) says nothing about the client, so it never
    /// benches it, however many tracks in a row hit it.
    func testUnreachableProbesDoNotBenchAClient() async throws {
        let youtube = FakeYouTube()
        youtube.media("VISIONOS", StreamStubResponse(status: 500))
        let resolver = youtube.resolver(catalog: [.visionOS, .androidVR])
        for id in ["aaaaaaaaaa1", "aaaaaaaaaa2", "aaaaaaaaaa3"] {
            let stream = try await resolver.resolve(id)
            XCTAssertEqual(stream.profileId, "android_vr")
        }
        youtube.media("VISIONOS", .audio(bytes: 64 * 1024))
        let stream = try await resolver.resolve("aaaaaaaaaa4")
        XCTAssertEqual(stream.profileId, "visionos", "VISIONOS was benched for timeouts")
    }

    func testEveryURLRefusedIsARetryableFailure() async {
        let youtube = FakeYouTube()
        for client in ["VISIONOS", "ANDROID_VR"] { youtube.media(client, StreamStubResponse(status: 403)) }
        let resolver = youtube.resolver(catalog: [.visionOS, .androidVR])
        do {
            _ = try await resolver.resolve(video)
            XCTFail("expected a failure")
        } catch let error as StreamResolutionError {
            XCTAssertFalse(error.isPermanent)
        } catch {
            XCTFail("\(error)")
        }
        // Not remembered as a verdict: the next call walks again.
        let before = youtube.playerRequests.count
        _ = try? await resolver.resolve(video)
        XCTAssertGreaterThan(youtube.playerRequests.count, before)
    }

    // MARK: Caches

    func testResolvedURLIsReusedWithoutTheNetwork() async throws {
        let youtube = FakeYouTube()
        let resolver = youtube.resolver()
        let first = try await resolver.resolve(video)
        let count = youtube.server.requests.count
        let second = try await resolver.resolve(video)
        XCTAssertEqual(first, second)
        XCTAssertEqual(youtube.server.requests.count, count)
    }

    func testCachedURLLapsesAfterTwentyMinutes() async throws {
        let youtube = FakeYouTube()
        let clock = StreamTestClock()
        let resolver = youtube.resolver(clock: clock)
        _ = try await resolver.resolve(video)
        clock.advance(19 * 60)
        _ = try await resolver.resolve(video)
        XCTAssertEqual(youtube.playerRequests.count, 1)
        clock.advance(2 * 60)
        _ = try await resolver.resolve(video)
        XCTAssertEqual(youtube.playerRequests.count, 2)
    }

    /// googlevideo's own `expire` bounds the cache too, with a margin.
    func testCachedURLIsNotHandedOutNearItsExpiry() async throws {
        let youtube = FakeYouTube()
        // The recorded URL expires at 1790421304.
        let clock = StreamTestClock(Date(timeIntervalSince1970: 1_790_421_304 - 10 * 60))
        let resolver = youtube.resolver(clock: clock)
        _ = try await resolver.resolve(video)
        clock.advance(4 * 60)
        _ = try await resolver.resolve(video)
        XCTAssertEqual(youtube.playerRequests.count, 1)
        clock.advance(2 * 60)
        _ = try await resolver.resolve(video)
        XCTAssertEqual(youtube.playerRequests.count, 2)
    }

    func testContentLengthIsExposed() async throws {
        let resolver = FakeYouTube().resolver()
        let length = try await resolver.contentLength(for: video)
        XCTAssertEqual(length, 3_449_447)
    }

    // MARK: Permanent verdicts

    private func ageGated() -> FakeYouTube {
        let youtube = FakeYouTube()
        youtube.answer("VISIONOS", fixture: "player_visionos_age_restricted.json")
        youtube.answer("ANDROID_VR", status: "LOGIN_REQUIRED", reason: "Sign in to confirm your age")
        return youtube
    }

    func testAgeGateIsPermanentAndRememberedForTenMinutes() async throws {
        let youtube = ageGated()
        let clock = StreamTestClock()
        let resolver = youtube.resolver(catalog: [.visionOS, .androidVR], clock: clock)
        do {
            _ = try await resolver.resolve(video)
            XCTFail("expected a verdict")
        } catch let error as StreamResolutionError {
            XCTAssertEqual(error, .permanentlyUnplayable(reason: "This track is age-restricted. Sign in to YouTube to play it."))
            XCTAssertTrue(error.isPermanent)
        }
        let asked = youtube.server.requests.count
        do {
            _ = try await resolver.resolve(video)
            XCTFail("expected the remembered verdict")
        } catch let error as StreamResolutionError {
            XCTAssertTrue(error.isPermanent)
        }
        XCTAssertEqual(youtube.server.requests.count, asked, "a verdict is answered from memory")
        clock.advance(10 * 60 + 1)
        _ = try? await resolver.resolve(video)
        XCTAssertGreaterThan(youtube.server.requests.count, asked, "and asked again once it lapses")
    }

    func testSignedInListenersGetTheSignedInMessage() async {
        let youtube = ageGated()
        let auth = FixedAuthProvider(session: StreamAuthSession(cookie: "SAPISID=x"))
        do {
            _ = try await youtube.resolver(catalog: [.visionOS, .androidVR], auth: auth).resolve(video)
            XCTFail()
        } catch {
            XCTAssertEqual(error as? StreamResolutionError, .permanentlyUnplayable(reason: "YouTube will not serve this age-restricted track to this app."))
        }
    }

    /// Signing in is what can turn an age gate playable, so it clears every verdict.
    func testSessionChangeClearsVerdicts() async throws {
        let youtube = ageGated()
        let resolver = youtube.resolver(catalog: [.visionOS, .androidVR])
        _ = try? await resolver.resolve(video)
        youtube.answer("VISIONOS", fixture: "player_visionos_ok.json")
        await resolver.onSessionChanged()
        let stream = try await resolver.resolve(video)
        XCTAssertEqual(stream.profileId, "visionos")
    }

    /// The visitor id belonged to the session that left; the next walk mints a new one.
    func testSessionChangeTakesAFreshVisitorId() async throws {
        let youtube = FakeYouTube()
        let resolver = youtube.resolver()
        _ = try await resolver.resolve(video)
        XCTAssertEqual(youtube.shellRequests, 1)
        await resolver.onSessionChanged()
        _ = try await resolver.resolve("kJQP7kiw5Fk")
        XCTAssertEqual(youtube.shellRequests, 2)
    }

    /// Warm-up pays for the visitor id, the player script and BotGuard before any track.
    func testPrewarmPaysTheColdCostsUpFront() async throws {
        let youtube = FakeYouTube()
        let tokens = RecordingWarmProvider()
        var configuration = StreamResolver.Configuration()
        configuration.catalog = [.visionOS]
        let resolver = StreamResolver(
            session: youtube.session, configuration: configuration,
            visitorData: StreamVisitorDataStore(session: youtube.session),
            cipher: StreamCipherSolver(session: youtube.session, cacheDirectory: nil), poTokens: tokens
        )
        await resolver.prewarm()
        XCTAssertEqual(youtube.shellRequests, 1)
        XCTAssertEqual(youtube.server.requests.filter { $0.url.path.hasSuffix("base.js") }.count, 1)
        XCTAssertEqual(tokens.warmedFor.count, 1)
        let sts = await resolver.signatureTimestamp()
        XCTAssertEqual(sts, 20717)
        XCTAssertEqual(youtube.server.requests.filter { $0.url.path.hasSuffix("base.js") }.count, 1, "already warm")
    }

    /// Once a client offered a stream, a later "permanent" answer describes that client.
    func testVerdictIsNotRecordedAfterAStreamWasOffered() async {
        let youtube = FakeYouTube()
        youtube.media("VISIONOS", StreamStubResponse(status: 403))
        youtube.answer("ANDROID_VR", status: "LOGIN_REQUIRED", reason: "Sign in to confirm your age")
        let resolver = youtube.resolver(catalog: [.visionOS, .androidVR])
        do {
            _ = try await resolver.resolve(video)
            XCTFail()
        } catch let error as StreamResolutionError {
            XCTAssertFalse(error.isPermanent, "\(error)")
        } catch {
            XCTFail("\(error)")
        }
    }

    // MARK: Coalescing

    func testConcurrentResolvesOfOneTrackShareOneWalk() async throws {
        let youtube = FakeYouTube()
        youtube.delayPlayerAnswers(0.2)
        let resolver = youtube.resolver()
        async let a = resolver.resolve(video)
        async let b = resolver.resolve(video)
        async let c = resolver.resolve(video)
        let streams = try await [a, b, c]
        XCTAssertEqual(Set(streams.map(\.url)).count, 1)
        XCTAssertEqual(youtube.playerRequests.count, 1)
    }

    /// A caller giving up cancels its own wait, never the walk another caller is waiting on.
    func testCancelledCallerDoesNotCancelTheSharedWalk() async throws {
        let youtube = FakeYouTube()
        youtube.delayPlayerAnswers(0.3)
        let resolver = youtube.resolver()
        let impatient = Task { try await resolver.resolve(self.video) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let patient = Task { try await resolver.resolve(self.video) }
        impatient.cancel()
        do {
            _ = try await impatient.value
            XCTFail("the cancelled caller should stop waiting")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let stream = try await patient.value
        XCTAssertEqual(stream.profileId, "visionos")
        XCTAssertEqual(youtube.playerRequests.count, 1)
    }

    /// Read-ahead the queue moved past still warms the cache for when the track is reached.
    func testAbandonedWalkStillWarmsTheCache() async throws {
        let youtube = FakeYouTube()
        youtube.delayPlayerAnswers(0.2)
        let resolver = youtube.resolver()
        let abandoned = Task { try await resolver.resolve(self.video) }
        try await Task.sleep(nanoseconds: 20_000_000)
        abandoned.cancel()
        _ = try? await abandoned.value
        try await Task.sleep(nanoseconds: 600_000_000)
        let requestsBefore = youtube.server.requests.count
        let stream = try await resolver.resolve(video)
        XCTAssertEqual(stream.profileId, "visionos")
        XCTAssertEqual(youtube.server.requests.count, requestsBefore, "answered from the cache the walk filled")
        XCTAssertEqual(youtube.playerRequests.count, 1)
    }

    // MARK: Refusal feedback

    func testPlaybackRefusalForgetsTheURLAndBenchesItsClientForTheTrack() async throws {
        let youtube = FakeYouTube()
        let resolver = youtube.resolver()
        let first = try await resolver.resolve(video)
        await resolver.onPlaybackRefused(url: first.url, statusCode: 403)
        let second = try await resolver.resolve(video)
        XCTAssertEqual(second.profileId, "android_vr")
        XCTAssertNotEqual(first.url, second.url)
    }

    func testOnlyGooglevideoRefusalsCount() async throws {
        let youtube = FakeYouTube()
        let resolver = youtube.resolver()
        let first = try await resolver.resolve(video)
        await resolver.onPlaybackRefused(url: first.url, statusCode: 500)
        await resolver.onPlaybackRefused(url: URL(string: "https://aac.saavncdn.com/x.mp4")!, statusCode: 404)
        let again = try await resolver.resolve(video)
        XCTAssertEqual(again, first)
        XCTAssertEqual(youtube.playerRequests.count, 1)
    }

    func testMediaHeadersPreferTheMintingClientThenTheURL() async throws {
        let resolver = FakeYouTube().resolver()
        let stream = try await resolver.resolve(video)
        let minted = await resolver.mediaHeaders(for: stream.url)
        XCTAssertEqual(minted, stream.mediaHeaders)
        let foreign = await resolver.mediaHeaders(for: URL(string: "https://rr2.googlevideo.com/videoplayback?c=WEB_REMIX")!)
        XCTAssertEqual(foreign, StreamPlayerClient.webRemix.mediaHeaders)
    }

    // MARK: Download

    func testDownloadRequiringM4aTakesAAC() async throws {
        let stream = try await FakeYouTube().resolver().resolveForDownload(video, maxKbps: StreamDownloadQuality.high.maxKbps)
        XCTAssertEqual(stream.itag, 140)
        XCTAssertEqual(stream.downloadExtension, "m4a")
    }

    /// Standard's 128 kbps ceiling is under 140's 129 kbps, so the AAC ladder's lower rung wins.
    func testDownloadCeilingAppliesToTheAACLadder() async throws {
        let stream = try await FakeYouTube().resolver().resolveForDownload(video, maxKbps: StreamDownloadQuality.standard.maxKbps)
        XCTAssertEqual(stream.itag, 139)
    }

    func testDownloadWithoutM4aKeepsOpusInWebM() async throws {
        let youtube = FakeYouTube()
        youtube.media("VISIONOS", StreamStubResponse.audio(bytes: 64 * 1024, type: "audio/webm"))
        let stream = try await youtube.resolver().resolveForDownload(video, maxKbps: .max, requireM4a: false)
        XCTAssertEqual(stream.itag, 251)
        XCTAssertEqual(stream.downloadExtension, "webm")
    }

    /// The download path never touches the playback cache, in either direction.
    func testDownloadDoesNotSeedOrReadThePlaybackCache() async throws {
        let youtube = FakeYouTube()
        let resolver = youtube.resolver()
        _ = try await resolver.resolveForDownload(video, maxKbps: .max)
        _ = try await resolver.resolve(video)
        XCTAssertEqual(youtube.playerRequests.count, 2)
        _ = try await resolver.resolveForDownload(video, maxKbps: .max)
        XCTAssertEqual(youtube.playerRequests.count, 3)
    }

    func testDownloadFailureSaysWhetherTryingAgainCanHelp() async {
        let refused = FakeYouTube()
        for client in ["VISIONOS", "ANDROID_VR"] { refused.media(client, StreamStubResponse(status: 403)) }
        do {
            _ = try await refused.resolver(catalog: [.visionOS, .androidVR]).resolveForDownload(video, maxKbps: .max)
            XCTFail()
        } catch {
            XCTAssertEqual(error as? StreamResolutionError, .downloadUnavailable(message: "Couldn't reach a downloadable copy just now — try again"))
        }
        let none = ageGated()
        do {
            _ = try await none.resolver(catalog: [.visionOS, .androidVR]).resolveForDownload(video, maxKbps: .max)
            XCTFail()
        } catch {
            XCTAssertEqual(error as? StreamResolutionError, .downloadUnavailable(message: "No downloadable audio for this track"))
        }
    }

    /// The cipher tier through the whole resolver: VISIONOS and ANDROID_VR refused, WEB_REMIX
    /// deciphered and probed.
    func testCipherTierResolvesWhenTheDirectClientsCannot() async throws {
        let youtube = FakeYouTube()
        youtube.answer("VISIONOS", status: "UNPLAYABLE", reason: "x")
        youtube.media("ANDROID_VR", StreamStubResponse(status: 403))
        let resolver = youtube.resolver(cipher: true)
        let stream = try await resolver.resolve(video)
        XCTAssertEqual(stream.profileId, "web_remix")
        XCTAssertEqual(stream.url.streamQueryValue("n"), "SnTjuvmGhHvpug")
        let sts = await resolver.signatureTimestamp()
        XCTAssertEqual(sts, 20717)
    }
}

/// Records warm-ups; mints nothing.
final class RecordingWarmProvider: StreamPoTokenProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var warmed: [String] = []
    var warmedFor: [String] { lock.withLock { warmed } }
    func poToken(videoId: String, visitorData: String) async throws -> StreamPoToken? { nil }
    func close() async {}
    func prewarm(visitorData: String) async { lock.withLock { warmed.append(visitorData) } }
}
