import XCTest
@testable import StreamResolution

/// Walking the client catalog (Android's `InnerTubeXResolver`), offline.
final class ClientCatalogWalkTests: XCTestCase {
    private let video = "dQw4w9WgXcQ"

    private func found(_ outcome: ExtractionOutcome, file: StaticString = #filePath, line: UInt = #line) throws -> ExtractedStream {
        guard case .found(let stream) = outcome else {
            XCTFail("expected a stream, got \(outcome)", file: file, line: line)
            throw XCTSkip("no stream")
        }
        return stream
    }

    func testVisionOSAnswersFirstWithDirectAAC() async throws {
        let youtube = FakeYouTube()
        let stream = try found(await youtube.extractor().extract(videoId: video, selection: .playback(maxKbps: .max), skip: []))
        XCTAssertEqual(stream.profileId, "visionos")
        XCTAssertEqual(stream.itag, 140)
        XCTAssertEqual(stream.kbps, 129)
        XCTAssertEqual(stream.contentLength, 3_449_447)
        XCTAssertEqual(stream.loudnessDb ?? 0, 0.99, accuracy: 0.01)
        XCTAssertEqual(stream.headers["User-Agent"], StreamPlayerClient.visionOSUserAgent)
        XCTAssertEqual(stream.expiresAt, Date(timeIntervalSince1970: 1_790_421_304))
        XCTAssertEqual(youtube.playerRequests.map(\.client), ["VISIONOS"], "nothing else is asked once one answers")
    }

    /// NewPipe's shape for visionOS: googleapis host, `t` and `id`, format version header.
    func testVisionOSRequestIsShapedLikeNewPipes() async throws {
        let youtube = FakeYouTube()
        _ = await youtube.extractor().extract(videoId: video, selection: .playback(maxKbps: .max), skip: [])
        let request = try XCTUnwrap(youtube.playerRequests("VISIONOS").first)
        XCTAssertEqual(request.url.host, "youtubei.googleapis.com")
        XCTAssertEqual(request.url.streamQueryValue("id"), video)
        XCTAssertEqual(request.url.streamQueryValue("t")?.count, 12)
        XCTAssertEqual(request.url.streamQueryValue("prettyPrint"), "false")
        XCTAssertEqual(request.header("X-Goog-Api-Format-Version"), "2")
        XCTAssertEqual(request.header("User-Agent"), StreamPlayerClient.visionOSUserAgent)
        XCTAssertNil(request.header("Origin"))
        let body = try XCTUnwrap(request.jsonBody)
        let client = try XCTUnwrap((body["context"] as? [String: Any])?["client"] as? [String: Any])
        XCTAssertEqual(client["deviceModel"] as? String, "RealityDevice14,1")
        XCTAssertEqual(client["osName"] as? String, "visionOS")
        XCTAssertEqual(client["gl"] as? String, "US")
        XCTAssertNotNil(client["visitorData"] as? String)
        XCTAssertEqual(request.header("X-Goog-Visitor-Id"), client["visitorData"] as? String)
        XCTAssertEqual(body["videoId"] as? String, video)
        XCTAssertEqual((body["cpn"] as? String)?.count, 16)
        XCTAssertEqual(body["contentCheckOk"] as? Bool, true)
        XCTAssertNil(body["playbackContext"], "app clients quote no signature timestamp")
    }

    func testAndroidVRRequestCarriesItsDevice() throws {
        let request = try InnerTubeStreamExtractor.playerRequest(
            profile: .androidVR, clientVersion: "1.65.10", videoId: video, visitorData: "CgVISITOR", signatureTimestamp: nil,
            auth: nil, poToken: nil, language: "en", cpn: "c", now: Date()
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let client = try XCTUnwrap((body["context"] as? [String: Any])?["client"] as? [String: Any])
        XCTAssertEqual(client["androidSdkVersion"] as? Int, 32)
        XCTAssertEqual(client["osVersion"] as? String, "12L")
        XCTAssertEqual(client["userAgent"] as? String, StreamPlayerClient.androidVR.userAgent)
        XCTAssertEqual(request.url?.host, "www.youtube.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-YouTube-Client-Name"), "28")
    }

    func testRefusedClientFallsThroughToTheNext() async throws {
        let youtube = FakeYouTube()
        youtube.answer("VISIONOS", status: "LOGIN_REQUIRED", reason: "Please sign in")
        let stream = try found(await youtube.extractor().extract(videoId: video, selection: .playback(maxKbps: .max), skip: []))
        XCTAssertEqual(stream.profileId, "android_vr")
        XCTAssertEqual(stream.headers, StreamPlayerClient.androidVR.mediaHeaders)
    }

    func testTransportFailureFallsThroughToTheNext() async throws {
        let youtube = FakeYouTube()
        youtube.answer("VISIONOS", StreamStubResponse(status: 500))
        let stream = try found(await youtube.extractor().extract(videoId: video, selection: .playback(maxKbps: .max), skip: []))
        XCTAssertEqual(stream.profileId, "android_vr")
    }

    /// No network, or one that stopped answering, fails every client the same way, each after a
    /// request timeout of its own (10 s): asking all of them stretched a failed resolve to a minute
    /// or more on Wi-Fi without internet. No network ends the walk at once; a timeout ends
    /// it once the next client times out too (one slow host shouldn't cost the others); an
    /// unknown host, which can be one blocked name, never does.
    func testANetworkThatIsDownEndsTheWalkEarly() async {
        let cases: [(URLError.Code, asked: Int)] = [(.notConnectedToInternet, 1), (.timedOut, 2), (.cannotFindHost, 3)]
        for (code, asked) in cases {
            let youtube = FakeYouTube()
            for client in ["VISIONOS", "ANDROID_VR", "IOS"] {
                youtube.answer(client, StreamStubResponse(error: URLError(code)))
            }
            let outcome = await youtube.extractor(catalog: [.visionOS, .androidVR, .ios])
                .extract(videoId: video, selection: .playback(maxKbps: .max), skip: [])
            guard case .exhausted(let permanent, _, _) = outcome else {
                XCTFail("\(code): expected the walk to give up, got \(outcome)")
                continue
            }
            XCTAssertNil(permanent, "\(code): a network failure says nothing about the track")
            XCTAssertEqual(youtube.playerRequests.count, asked, "\(code)")
        }
    }

    /// One slow host is not a dead network: the next client still gets asked, and a client that
    /// answers between two timeouts means the second is a separate slow host, not the second in a row.
    func testTimeoutsEndTheWalkOnlyWhenConsecutive() async throws {
        let youtube = FakeYouTube()
        youtube.answer("VISIONOS", StreamStubResponse(error: URLError(.timedOut)))
        let single = try found(await youtube.extractor(catalog: [.visionOS, .androidVR])
            .extract(videoId: video, selection: .playback(maxKbps: .max), skip: []))
        XCTAssertEqual(single.profileId, "android_vr")

        // VISIONOS times out, IOS answers (SABR only, no stream), VISIONOS times out again.
        let apart = try found(await youtube.extractor(catalog: [.visionOS, .ios, .visionOS, .androidVR])
            .extract(videoId: video, selection: .playback(maxKbps: .max), skip: []))
        XCTAssertEqual(apart.profileId, "android_vr")
    }

    /// An `OK` with only a SABR session is not a stream; the walk moves on.
    func testSABROnlyAnswerMovesOn() async throws {
        let youtube = FakeYouTube()
        let stream = try found(await youtube.extractor(catalog: [.ios, .visionOS]).extract(videoId: video, selection: .playback(maxKbps: .max), skip: []))
        XCTAssertEqual(stream.profileId, "visionos")
        XCTAssertEqual(youtube.playerRequests.map(\.client), ["IOS", "VISIONOS"])
    }

    func testAgeGateAcrossTheCatalogIsAPermanentVerdict() async {
        let youtube = FakeYouTube()
        youtube.answer("VISIONOS", fixture: "player_visionos_age_restricted.json")
        youtube.answer("ANDROID_VR", status: "LOGIN_REQUIRED", reason: "Sign in to confirm your age")
        youtube.answer("WEB_REMIX", fixture: "player_web_remix_age_unplayable.json")
        youtube.answer("TVHTML5_SIMPLY", status: "UNPLAYABLE", reason: "This video is unavailable")
        youtube.answer("MWEB", status: "LOGIN_REQUIRED", reason: "Sign in to confirm your age")
        let outcome = await youtube.extractor(cipher: true).extract(videoId: video, selection: .playback(maxKbps: .max), skip: [])
        guard case .exhausted(let permanent, _, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(permanent, .ageRestricted)
        XCTAssertEqual(Set(youtube.playerRequests.map(\.client)), ["VISIONOS", "ANDROID_VR", "WEB_REMIX", "TVHTML5_SIMPLY", "MWEB"])
    }

    func testRemovedVideoNeedsEveryClientToSaySo() async {
        let youtube = FakeYouTube()
        youtube.answer("VISIONOS", fixture: "player_visionos_unavailable.json")
        youtube.answer("ANDROID_VR", status: "ERROR", reason: "This video is unavailable")
        var outcome = await youtube.extractor(catalog: [.visionOS, .androidVR]).extract(videoId: video, selection: .playback(maxKbps: .max), skip: [])
        guard case .exhausted(.removed?, false, _) = outcome else { return XCTFail("\(outcome)") }

        youtube.answer("ANDROID_VR", status: "UNPLAYABLE", reason: "Something else")
        outcome = await youtube.extractor(catalog: [.visionOS, .androidVR]).extract(videoId: video, selection: .playback(maxKbps: .max), skip: [])
        guard case .exhausted(nil, _, _) = outcome else { return XCTFail("\(outcome)") }
    }

    /// Once per walk: a burned visitor id is replaced and the same client asked again.
    func testBotCheckRefreshesTheVisitorIdOnceAndRetries() async throws {
        let youtube = FakeYouTube()
        youtube.answer(
            "VISIONOS",
            .json(Data(#"{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Sign in to confirm you’re not a bot"}}"#.utf8)),
            .json(StreamFixture.data("player_visionos_ok.json"))
        )
        let stream = try found(await youtube.extractor().extract(videoId: video, selection: .playback(maxKbps: .max), skip: []))
        XCTAssertEqual(stream.profileId, "visionos")
        XCTAssertEqual(youtube.playerRequests("VISIONOS").count, 2)
        XCTAssertEqual(youtube.shellRequests, 2, "initial id, then the refresh")
    }

    func testRepeatedBotCheckMovesOnInsteadOfLooping() async throws {
        let youtube = FakeYouTube()
        youtube.answer("VISIONOS", status: "LOGIN_REQUIRED", reason: "Sign in to confirm you're not a bot")
        let stream = try found(await youtube.extractor().extract(videoId: video, selection: .playback(maxKbps: .max), skip: []))
        XCTAssertEqual(stream.profileId, "android_vr")
        XCTAssertEqual(youtube.playerRequests("VISIONOS").count, 2)
    }

    /// Without a visitor id ANDROID_VR is answered LOGIN_REQUIRED, so it is not asked at all.
    func testClientsThatNeedAVisitorIdAreNotAskedWithoutOne() async {
        let youtube = FakeYouTube()
        youtube.shell = StreamStubResponse(status: 500)
        youtube.server.setHandler { request in
            if request.url.path == "/sw.js_data" || request.url.path == "/" { return StreamStubResponse(status: 500) }
            return .json(Data(#"{"playabilityStatus":{"status":"UNPLAYABLE","reason":"x"}}"#.utf8))
        }
        _ = await youtube.extractor(catalog: [.androidVR]).extract(videoId: video, selection: .playback(maxKbps: .max), skip: [])
        XCTAssertTrue(youtube.playerRequests.isEmpty)
    }

    /// The cipher tier: WEB_REMIX quotes the player's timestamp and its format is deciphered.
    func testWebRemixFormatsAreDeciphered() async throws {
        let youtube = FakeYouTube()
        let stream = try found(await youtube.extractor(catalog: [.webRemix], cipher: true).extract(videoId: video, selection: .playback(maxKbps: .max), skip: []))
        XCTAssertEqual(stream.profileId, "web_remix")
        XCTAssertEqual(stream.url.streamQueryValue("n"), "SnTjuvmGhHvpug")
        XCTAssertNotNil(stream.url.streamQueryValue("sig"))
        XCTAssertEqual(stream.headers["Origin"], "https://music.youtube.com")
        let request = try XCTUnwrap(youtube.playerRequests("WEB_REMIX").first)
        XCTAssertEqual(request.url.host, "music.youtube.com")
        XCTAssertEqual(request.header("Origin"), "https://music.youtube.com")
        XCTAssertEqual(request.header("X-YouTube-Client-Version"), "1.20260922.09.00", "live version from the shell")
        let playback = try XCTUnwrap(((request.jsonBody?["playbackContext"] as? [String: Any])?["contentPlaybackContext"]) as? [String: Any])
        XCTAssertEqual(playback["signatureTimestamp"] as? Int, 20717)
        XCTAssertEqual(playback["referer"] as? String, "https://music.youtube.com/watch?v=\(video)")
        XCTAssertNil(request.header("Cookie"), "signed out")
    }

    /// Without the cipher tier the web identities are skipped, not asked uselessly.
    func testWebIdentitiesAreSkippedWithoutACipherSolver() async {
        let youtube = FakeYouTube()
        youtube.answer("VISIONOS", status: "UNPLAYABLE", reason: "x")
        youtube.answer("ANDROID_VR", status: "UNPLAYABLE", reason: "x")
        _ = await youtube.extractor(cipher: false).extract(videoId: video, selection: .playback(maxKbps: .max), skip: [])
        XCTAssertEqual(Set(youtube.playerRequests.map(\.client)), ["VISIONOS", "ANDROID_VR"])
    }

    /// Only web identities take the session; device clients are sent none.
    func testSignedInSessionGoesOnlyToWebIdentities() async throws {
        let youtube = FakeYouTube()
        youtube.answer("VISIONOS", status: "LOGIN_REQUIRED", reason: "Sign in to confirm your age")
        youtube.answer("ANDROID_VR", status: "LOGIN_REQUIRED", reason: "Sign in to confirm your age")
        let auth = FixedAuthProvider(session: StreamAuthSession(
            cookie: "SAPISID=secret; SID=x", authUser: "1", pageId: "PAGE", dataSyncId: "SYNC", visitorData: "CgSESSIONBOUND",
            webRemixClientVersion: "1.20260930.01.00"
        ))
        let stream = try found(await youtube.extractor(cipher: true, auth: auth).extract(videoId: video, selection: .playback(maxKbps: .max), skip: []))
        XCTAssertEqual(stream.profileId, "web_remix")
        for client in ["VISIONOS", "ANDROID_VR"] {
            let request = try XCTUnwrap(youtube.playerRequests(client).first)
            XCTAssertNil(request.header("Cookie"), client)
            XCTAssertNil(request.header("Authorization"), client)
        }
        let remix = try XCTUnwrap(youtube.playerRequests("WEB_REMIX").first)
        XCTAssertEqual(remix.header("Cookie"), "SAPISID=secret; SID=x")
        XCTAssertTrue(remix.header("Authorization")?.hasPrefix("SAPISIDHASH ") == true)
        XCTAssertEqual(remix.header("X-Goog-AuthUser"), "1")
        XCTAssertEqual(remix.header("X-Goog-PageId"), "PAGE")
        XCTAssertEqual(remix.header("X-Goog-Visitor-Id"), "CgSESSIONBOUND")
        XCTAssertEqual(remix.header("X-YouTube-Client-Version"), "1.20260930.01.00")
        let user = try XCTUnwrap((remix.jsonBody?["context"] as? [String: Any])?["user"] as? [String: Any])
        XCTAssertEqual(user["onBehalfOfUser"] as? String, "SYNC")
    }

    func testPoTokensAreAttachedToWebIdentitiesOnly() async throws {
        let youtube = FakeYouTube()
        youtube.answer("VISIONOS", status: "UNPLAYABLE", reason: "x")
        youtube.answer("ANDROID_VR", status: "UNPLAYABLE", reason: "x")
        let tokens = FakePoTokenProvider()
        let stream = try found(await youtube.extractor(cipher: true, poTokens: tokens).extract(videoId: video, selection: .playback(maxKbps: .max), skip: []))
        XCTAssertEqual(stream.url.streamQueryValue("pot"), "STREAMING_TOKEN")
        let body = try XCTUnwrap(youtube.playerRequests("WEB_REMIX").first?.jsonBody)
        XCTAssertEqual((body["serviceIntegrityDimensions"] as? [String: Any])?["poToken"] as? String, "PLAYER_TOKEN")
        XCTAssertEqual(tokens.requested.map(\.videoId), [video], "asked once, for WEB_REMIX only")
        XCTAssertNil(youtube.playerRequests("VISIONOS").first?.jsonBody?["serviceIntegrityDimensions"])
    }

    /// Walking on without a token beats blocking the play path on one.
    func testFailingPoTokenProviderDoesNotBlockTheWalk() async throws {
        let youtube = FakeYouTube()
        youtube.answer("VISIONOS", status: "UNPLAYABLE", reason: "x")
        youtube.answer("ANDROID_VR", status: "UNPLAYABLE", reason: "x")
        let tokens = FakePoTokenProvider(error: StreamPoTokenError.failed("boom"))
        let stream = try found(await youtube.extractor(cipher: true, poTokens: tokens).extract(videoId: video, selection: .playback(maxKbps: .max), skip: []))
        XCTAssertEqual(stream.profileId, "web_remix")
        XCTAssertNil(stream.url.streamQueryValue("pot"))
    }

    func testSkipSetIsHonoured() async throws {
        let youtube = FakeYouTube()
        let stream = try found(await youtube.extractor().extract(videoId: video, selection: .playback(maxKbps: .max), skip: ["visionos"]))
        XCTAssertEqual(stream.profileId, "android_vr")
        XCTAssertTrue(youtube.playerRequests("VISIONOS").isEmpty)
    }

    /// A refusal mid-play benches that client for that track, for ten minutes.
    func testRefusedURLExcludesItsClientForThatTrackOnly() async throws {
        let youtube = FakeYouTube()
        let clock = StreamTestClock()
        let extractor = youtube.extractor(clock: clock)
        let first = try found(await extractor.extract(videoId: video, selection: .playback(maxKbps: .max), skip: []))
        let refusedVideo = await extractor.onRefused(first.url)
        XCTAssertEqual(refusedVideo, video)
        let again = try found(await extractor.extract(videoId: video, selection: .playback(maxKbps: .max), skip: []))
        XCTAssertEqual(again.profileId, "android_vr")
        let other = try found(await extractor.extract(videoId: "kJQP7kiw5Fk", selection: .playback(maxKbps: .max), skip: []))
        XCTAssertEqual(other.profileId, "visionos", "other tracks are unaffected")
        clock.advance(10 * 60 + 1)
        let later = try found(await extractor.extract(videoId: video, selection: .playback(maxKbps: .max), skip: []))
        XCTAssertEqual(later.profileId, "visionos")
    }

    /// A full book gives up its oldest refusal, not every one of them: a track refused a moment ago
    /// keeps its client benched when the sixty-fifth arrives.
    func testAFullRefusalBookDropsItsOldestEntryOnly() async throws {
        let youtube = FakeYouTube()
        let clock = StreamTestClock()
        let extractor = youtube.extractor(clock: clock)
        let ids = (0...InnerTubeStreamExtractor.maxRemembered).map { "t" + String(format: "%010d", $0) }
        for id in ids {
            await extractor.exclude(videoId: id, profileId: "visionos")
            clock.advance(1)
        }
        let recent = try found(await extractor.extract(videoId: ids[ids.count - 2], selection: .playback(maxKbps: .max), skip: []))
        XCTAssertEqual(recent.profileId, "android_vr", "a recent refusal still stands")
        let oldest = try found(await extractor.extract(videoId: ids[0], selection: .playback(maxKbps: .max), skip: []))
        XCTAssertEqual(oldest.profileId, "visionos", "the oldest made room")
    }

    func testRefusalsOfURLsItDidNotMintAreNotItsBusiness() async {
        let extractor = FakeYouTube().extractor()
        let videoId = await extractor.onRefused(URL(string: "https://rr1.googlevideo.com/videoplayback?c=IOS")!)
        XCTAssertNil(videoId)
    }

    func testMintedURLsRememberTheirHeaders() async throws {
        let extractor = FakeYouTube().extractor()
        let stream = try found(await extractor.extract(videoId: video, selection: .playback(maxKbps: .max), skip: []))
        let headers = await extractor.headers(for: stream.url)
        XCTAssertEqual(headers, stream.headers)
        await extractor.onSessionChanged()
        let forgotten = await extractor.headers(for: stream.url)
        XCTAssertNil(forgotten)
    }

    /// Three refused URLs in a row on different tracks bench a client for ten minutes; one good
    /// URL clears the count.
    func testRepeatedProbeFailuresBenchAClient() async throws {
        let youtube = FakeYouTube()
        let clock = StreamTestClock()
        let extractor = youtube.extractor(clock: clock)
        for _ in 0..<2 { await extractor.noteProbe(profileId: "visionos", ok: false) }
        await extractor.noteProbe(profileId: "visionos", ok: true)
        for _ in 0..<2 { await extractor.noteProbe(profileId: "visionos", ok: false) }
        var benched = await extractor.isBenched("visionos")
        XCTAssertFalse(benched)
        await extractor.noteProbe(profileId: "visionos", ok: false)
        benched = await extractor.isBenched("visionos")
        XCTAssertTrue(benched)
        let stream = try found(await extractor.extract(videoId: video, selection: .playback(maxKbps: .max), skip: []))
        XCTAssertEqual(stream.profileId, "android_vr")
        clock.advance(10 * 60 + 1)
        benched = await extractor.isBenched("visionos")
        XCTAssertFalse(benched)
    }

    /// Better to ask a benched client than nobody.
    func testEverythingBenchedStillAsksSomeone() async throws {
        let youtube = FakeYouTube()
        let extractor = youtube.extractor(catalog: [.visionOS])
        for _ in 0..<3 { await extractor.noteProbe(profileId: "visionos", ok: false) }
        let stream = try found(await extractor.extract(videoId: video, selection: .playback(maxKbps: .max), skip: []))
        XCTAssertEqual(stream.profileId, "visionos")
    }

    func testNoncesAreSixteenURLSafeCharacters() {
        let cpn = InnerTubeStreamExtractor.newCpn()
        XCTAssertEqual(cpn.count, 16)
        XCTAssertNotNil(cpn.range(of: #"^[A-Za-z0-9_-]{16}$"#, options: .regularExpression))
        XCTAssertNotEqual(InnerTubeStreamExtractor.newCpn(), InnerTubeStreamExtractor.newCpn())
    }
}
