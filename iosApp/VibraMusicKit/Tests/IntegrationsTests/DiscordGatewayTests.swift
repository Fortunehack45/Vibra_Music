import VibraMusicCore
import VibraMusicTestSupport
import Foundation
import XCTest
@testable import Integrations

/// Gateway frame vectors: hello / identify / heartbeat / presence payloads.
/// Pure codec tests; the live handshake against a fake server is below.
final class DiscordGatewayPayloadTests: XCTestCase {
    func testHelloDecodesHeartbeatInterval() throws {
        let payload = try DiscordGatewayPayload.decode(#"{"op":10,"d":{"heartbeat_interval":41250}}"#)
        XCTAssertEqual(payload.op, .hello)
        XCTAssertEqual(DiscordHello.interval(from: payload), 41_250)
    }

    func testUnknownOpcodeDecodesInsteadOfThrowing() throws {
        let payload = try DiscordGatewayPayload.decode(#"{"op":99,"d":{}}"#)
        XCTAssertEqual(payload.op, .unknown(99))
        // And it re-encodes without loss.
        XCTAssertTrue(try payload.encode().contains("\"op\":99"))
    }

    func testIdentifyPayloadShape() throws {
        let text = try DiscordGatewayFrames.identify(token: "TOKEN", os: "iOS", browser: "Discord iOS", device: "iPhone")
        let payload = try DiscordGatewayPayload.decode(text)
        XCTAssertEqual(payload.op, .identify)
        let object = try XCTUnwrap(payload.d?.objectValue)
        XCTAssertEqual(object["token"], .string("TOKEN"))
        XCTAssertEqual(object["capabilities"], .int(16_381))
        XCTAssertEqual(object["compress"], .bool(false))
        let properties = try XCTUnwrap(object["properties"]?.objectValue)
        XCTAssertEqual(properties["os"], .string("iOS"))
        XCTAssertEqual(properties["browser"], .string("Discord iOS"))
        // The token must never appear in logs verbatim here; the frame itself
        // carries it because the gateway requires it.
        XCTAssertTrue(text.contains("TOKEN"))
    }

    func testHeartbeatEncodesNullSequence() throws {
        let first = try DiscordGatewayPayload.decode(DiscordGatewayFrames.heartbeat(sequence: 0))
        XCTAssertEqual(first.op, .heartbeat)
        // JSON null decodes to nil for the Optional `d`, as it should.
        XCTAssertNil(first.d)
        XCTAssertTrue(DiscordGatewayFrames.heartbeat(sequence: 0).contains("\"d\":null"))
        let later = try DiscordGatewayPayload.decode(DiscordGatewayFrames.heartbeat(sequence: 42))
        XCTAssertEqual(later.d, .int(42))
    }

    func testPresenceUpdateRoundTrip() throws {
        let presence = DiscordPresence(
            activities: [
                DiscordActivity(
                    name: "Vibra Music",
                    state: "Anitta",
                    details: "Envolver",
                    type: DiscordActivityType.listening.rawValue,
                    statusDisplayType: DiscordStatusDisplayType.state.rawValue,
                    timestamps: DiscordTimestamps(start: 1, end: 2),
                    assets: DiscordAssets(largeImage: "mp:abc", largeText: "Lossless"),
                    buttons: ["Listen on YouTube Music"],
                    metadata: DiscordActivityMetadata(buttonUrls: ["https://music.youtube.com/watch?v=v"]),
                    applicationId: "123"
                ),
            ],
            afk: true,
            since: 1,
            status: "online"
        )
        let text = try DiscordGatewayFrames.presenceUpdate(presence)
        let payload = try DiscordGatewayPayload.decode(text)
        XCTAssertEqual(payload.op, .presenceUpdate)
        let data = try JSONSerialization.data(withJSONObject: payload.d?.jsonObject as Any)
        let decoded = try JSONDecoder().decode(DiscordPresence.self, from: data)
        XCTAssertEqual(decoded, presence)
    }

    func testPresenceClearsWithEmptyActivities() throws {
        let text = try DiscordGatewayFrames.presenceUpdate(DiscordPresence(activities: []))
        XCTAssertTrue(text.contains("\"activities\":[]"))
    }
}

private extension DiscordJSON {
    var objectValue: [String: DiscordJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var jsonObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .array(let value): return value.map(\.jsonObject)
        case .object(let value): return value.mapValues { $0.jsonObject }
        }
    }
}

/// Presence building: timestamps honour playback speed, buttons resolve
/// variables, artwork falls back when unusable.
final class DiscordPresenceBuildingTests: XCTestCase {
    private func song() -> Song {
        Song(
            videoId: "abc123", title: "Envolver", artist: "Anitta",
            thumbnailUrl: "https://i.ytimg.com/vi/abc123/hqdefault.jpg",
            durationText: "3:11", albumName: "Versions of Me"
        )
    }

    private func presence(
        positionMs: Int64 = 64_000,
        durationMs: Int64 = 191_000,
        speed: Double = 1.0,
        options: DiscordPresenceOptions = DiscordPresenceOptions(),
        at now: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) async -> DiscordPresence {
        let client = DiscordPresenceClient(token: "T")
        await client.close()
        return await client.makePresence(
            song(), currentPositionMs: positionMs, durationMs: durationMs,
            playbackSpeed: speed, options: options, at: now
        )
    }

    func testTimestampsCountDownOnWallClock() async throws {
        let built = await presence()
        let activity = try XCTUnwrap(built.activities?.first ?? nil)
        let stamps = try XCTUnwrap(activity.timestamps)
        // now=1_700_000_000_000 ms, position 64 s → start 64 s earlier;
        // remaining 127 s → end 127 s later.
        XCTAssertEqual(stamps.start, 1_700_000_000_000 - 64_000)
        XCTAssertEqual(stamps.end, 1_700_000_000_000 + 127_000)
        XCTAssertEqual(activity.details, "Envolver")
        XCTAssertEqual(activity.state, "Anitta")
        XCTAssertEqual(activity.type, DiscordActivityType.listening.rawValue)
    }

    func testPlaybackSpeedDividesOutOfTimestamps() async throws {
        let built = await presence(positionMs: 60_000, durationMs: 180_000, speed: 1.5)
        let activity = try XCTUnwrap(built.activities?.first ?? nil)
        let stamps = try XCTUnwrap(activity.timestamps)
        XCTAssertEqual(stamps.start, 1_700_000_000_000 - 40_000)
        XCTAssertEqual(stamps.end, 1_700_000_000_000 + 80_000)
        XCTAssertEqual(activity.details, "Envolver [1.50x]")
    }

    func testButtonsResolveVariablesAndCarryURLs() async throws {
        let built = await presence(options: DiscordPresenceOptions(button1Text: "♥ {song_name}"))
        let activity = try XCTUnwrap(built.activities?.first ?? nil)
        XCTAssertEqual(activity.buttons, ["♥ Envolver", "Visit Vibra Music"])
        XCTAssertEqual(
            activity.metadata?.buttonUrls,
            ["https://music.youtube.com/watch?v=abc123", DiscordPresenceClient.projectURL]
        )
        XCTAssertEqual(activity.applicationId, DiscordPresenceClient.applicationId)
        XCTAssertEqual(activity.detailsUrl, "https://music.youtube.com/watch?v=abc123")
    }

    func testVariableResolution() {
        let song = Song(videoId: "v", title: "T", artist: "A", albumName: "AL")
        XCTAssertEqual(
            DiscordPresenceClient.resolveVariables("{song_name} / {artist_name} / {album_name}", song: song),
            "T / A / AL"
        )
        XCTAssertEqual(DiscordPresenceClient.watchURL(for: song), "https://music.youtube.com/watch?v=v")
    }

    func testUnusableArtworkFallsBack() async throws {
        let client = DiscordPresenceClient(token: "T")
        await client.close()
        var track = song()
        track.thumbnailUrl = nil
        let presence = await client.makePresence(track, currentPositionMs: 0, durationMs: 1_000)
        let assets = try XCTUnwrap(presence.activities?.first??.assets)
        // No upload credentials in tests, so the resolver returns nil and the
        // raw fallback URL is carried (the mirror happens on-device in the app).
        XCTAssertEqual(assets.largeImage, DiscordPresenceClient.fallbackArtworkURL)
    }

    func testAudioQualityRidesAsLargeText() async throws {
        let options = DiscordPresenceOptions(audioQuality: "Hi-Res Lossless · FLAC")
        let built = await presence(options: options)
        let activity = try XCTUnwrap(built.activities?.first ?? nil)
        XCTAssertEqual(activity.assets?.largeText, "Hi-Res Lossless · FLAC")
    }
}

/// Token validation + external artwork upload, stubbed at the HTTP layer.
/// No live Discord account is available here; everything runs offline.
final class DiscordAccountTests: XCTestCase {
    func testFetchUserInfo() async throws {
        let stub = URLProtocolStub()
        stub.register(host: "discord.com", path: "/api/v9/users/@me", response: .json(
            #"{"id":"123","username":"user","global_name":"User Name","avatar":"abc"}"#
        ))
        let fetched = await DiscordAccountService.fetchUserInfo(session: stub.makeSession(), token: "TOKEN")
        let info = try XCTUnwrap(fetched)
        XCTAssertEqual(info.id, "123")
        XCTAssertEqual(info.username, "user")
        XCTAssertEqual(info.name, "User Name")
        XCTAssertEqual(info.avatar, "https://cdn.discordapp.com/avatars/123/abc.png")
        let valid = await DiscordAccountService.validateToken(session: stub.makeSession(), token: "TOKEN")
        XCTAssertTrue(valid)
    }

    func testRejectedTokenReturnsNil() async {
        let stub = URLProtocolStub()
        stub.register(host: "discord.com", path: "/api/v9/users/@me", response: .status(401))
        let bad = await DiscordAccountService.fetchUserInfo(session: stub.makeSession(), token: "BAD")
        XCTAssertNil(bad)
        let badValid = await DiscordAccountService.validateToken(session: stub.makeSession(), token: "BAD")
        XCTAssertFalse(badValid)
        let empty = await DiscordAccountService.fetchUserInfo(session: stub.makeSession(), token: "")
        XCTAssertNil(empty)
    }

    func testExternalAssetUpload() async throws {
        let stub = URLProtocolStub()
        stub.register(host: "discord.com", path: "/api/v9/applications/123/external-assets", response: .json(
            #"[{"url":"https://x","external_asset_path":"123/abc"}]"#
        ))
        let uploaded = await fetchDiscordExternalAsset(
            session: stub.makeSession(), applicationId: "123", token: "T",
            imageUrl: "https://artwork/x.jpg",
            userAgent: DiscordSuperProperties.userAgent,
            superPropertiesBase64: "U1VQRVI="
        )
        let asset = try XCTUnwrap(uploaded)
        XCTAssertEqual(asset, "mp:123/abc")
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "T")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Super-Properties"), "U1VQRVI=")
    }

    func testExternalAssetPassesThroughMpPaths() async {
        let stub = URLProtocolStub()
        let asset = await fetchDiscordExternalAsset(
            session: stub.makeSession(), applicationId: "123", token: "T", imageUrl: "mp:cached/path"
        )
        XCTAssertEqual(asset, "mp:cached/path")
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testRpcImageResolutionAndCache() async {
        let cache = DiscordArtworkCache()
        var fetches = 0
        let resolve: @Sendable (String) async -> String? = { _ in
            fetches += 1
            return "mp:up/1"
        }
        let image = DiscordRpcImage.external("https://artwork/x.jpg")
        let first = await image.resolve(cache: cache, resolveExternal: resolve)
        XCTAssertEqual(first, "mp:up/1")
        let second = await image.resolve(cache: cache, resolveExternal: resolve)
        XCTAssertEqual(second, "mp:up/1")
        XCTAssertEqual(fetches, 1, "second resolve must hit the cache, not the network")
        let discord = await DiscordRpcImage.discord("up/2").resolve(cache: cache, resolveExternal: resolve)
        XCTAssertEqual(discord, "mp:up/2")
    }

    func testSuperPropertiesHeader() {
        let headers = DiscordSuperProperties.headers(token: "T")
        XCTAssertEqual(headers["Authorization"], "T")
        XCTAssertFalse(headers["User-Agent"]?.isEmpty ?? true)
        let base64 = DiscordSuperProperties.base64()
        XCTAssertNotNil(base64)
        let data = Data(base64Encoded: base64 ?? "")
        XCTAssertNotNil(data)
        let json = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any]
        XCTAssertEqual(json?["os"] as? String, "iOS")
    }
}

/// Discord's traffic goes through the app's one HTTP stack (``VibraMusicHTTP``), not
/// `URLSession.shared`: no cookie jar to carry one service's cookies into another's requests, and
/// no URL cache for answers the app never reuses.
final class DiscordHTTPStackTests: XCTestCase {
    func testDiscordPresenceKeepsNoCookiesAndCachesNothing() {
        let presence = DiscordPresenceClient(token: "token").session.configuration
        let gateway = DiscordGatewaySocket.defaultSession.configuration
        for configuration in [presence, gateway] {
            XCTAssertFalse(configuration.httpShouldSetCookies)
            XCTAssertNil(configuration.httpCookieStorage)
            XCTAssertNil(configuration.urlCache)
        }
        XCTAssertGreaterThan(gateway.timeoutIntervalForRequest, 41.25,
                             "the socket waits out a whole heartbeat interval for its next frame")
    }
}

/// The 1.0.0 crash when Wi-Fi dropped mid-song. Offline, every connect fails and the loop
/// waits out a backoff; a track change (`retryNow`) ends that wait early. The ended wait's timer
/// still went off later, during the next wait, and resumed its own wait a second time: a
/// CheckedContinuation misuse, which aborts the app. It also dropped the newer wait, so nothing
/// could end that one.
final class DiscordGatewayBackoffTests: XCTestCase {
    func testAnEndedWaitsTimerFiringDuringTheNextWaitNeitherCrashesNorEndsIt() async throws {
        let timers = HandFiredTimers()
        let attempts = AttemptCounter()
        let socket = DiscordGatewaySocket(
            token: "TEST-TOKEN",
            makeTransport: { _ in
                attempts.record()
                throw URLError(.notConnectedToInternet)
            },
            backoffSleep: { await timers.sleep($0) }
        )
        await socket.connect()
        try await waitFor(timers.started == 1, "the failed connect starts backoff wait #1")
        await socket.retryNow()  // a track change ends wait #1 early
        try await waitFor(timers.started == 2, "the retry fails too and starts wait #2")
        XCTAssertEqual(attempts.value, 2)

        timers.fire(0)  // wait #1's timer goes off during wait #2: this crashed
        try await Task.sleep(nanoseconds: 200_000_000)  // room for a wrong resume to show
        XCTAssertEqual(attempts.value, 2, "an old wait's timer must not end the newer wait")

        await socket.retryNow()
        try await waitFor(attempts.value == 3, "wait #2 still ends on the next retry")

        await socket.close()
        timers.fireAll()
    }

    private func waitFor(
        _ condition: @autoclosure () -> Bool, _ what: String, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out: \(what)", file: file, line: line) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// Backoff timers that go off only when the test fires them, in the order the socket started them.
private final class HandFiredTimers: @unchecked Sendable {
    private let lock = NSLock()
    private var timers: [CheckedContinuation<Void, Never>?] = []

    var started: Int { lock.withLock { timers.count } }

    func sleep(_ nanoseconds: UInt64) async {
        await withCheckedContinuation { continuation in
            lock.withLock { timers.append(continuation) }
        }
    }

    func fire(_ index: Int) {
        let timer = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            let timer = timers[index]
            timers[index] = nil
            return timer
        }
        timer?.resume()
    }

    func fireAll() {
        for index in 0..<started { fire(index) }
    }
}

private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func record() { lock.withLock { count += 1 } }
}
