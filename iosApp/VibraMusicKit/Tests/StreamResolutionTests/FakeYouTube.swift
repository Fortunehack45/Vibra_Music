import Foundation
import XCTest
@testable import StreamResolution

/// An offline YouTube for the walk and resolver tests: recorded player answers per client, the
/// recorded shell, player script and config table, and googlevideo answering per minting client.
final class FakeYouTube: @unchecked Sendable {
    private let lock = NSLock()
    /// Player answers by clientName; each call takes the next one, the last one repeats.
    private var answers: [String: [StreamStubResponse]] = [:]
    /// googlevideo's answer by the URL's `c=`.
    private var media: [String: StreamStubResponse] = [:]
    private var playerDelay: TimeInterval = 0
    var shell: StreamStubResponse = .text(StreamFixture.string("music_shell_signed_out.html"))
    let server = StreamStubServer()

    init() {
        answer("VISIONOS", fixture: "player_visionos_ok.json")
        answer("ANDROID_VR", fixture: "player_android_vr_ok.json")
        answer("WEB_REMIX", fixture: "player_web_remix_cipher.json")
        answer("IOS", fixture: "player_ios_sabr_only.json")
        // Strong on purpose: a test may keep only the resolver it built, and the stub must outlive it.
        server.setHandler { request in self.respond(request) }
    }

    var session: URLSession { server.session }

    func answer(_ client: String, fixture: String) { answer(client, .json(StreamFixture.data(fixture))) }

    func answer(_ client: String, _ responses: StreamStubResponse...) {
        lock.withLock { answers[client] = responses }
    }

    func answer(_ client: String, status: String, reason: String) {
        let json = #"{"playabilityStatus":{"status":"\#(status)","reason":"\#(reason)"}}"#
        answer(client, .json(Data(json.utf8)))
    }

    func media(_ client: String, _ response: StreamStubResponse) { lock.withLock { media[client] = response } }

    func delayPlayerAnswers(_ seconds: TimeInterval) { lock.withLock { playerDelay = seconds } }

    /// `player` requests, with the client each claimed to be.
    var playerRequests: [(client: String, request: StreamStubRequest)] {
        server.requests.filter { $0.url.path == "/youtubei/v1/player" }.map { request in
            let context = request.jsonBody?["context"] as? [String: Any]
            let client = (context?["client"] as? [String: Any])?["clientName"] as? String ?? "?"
            return (client, request)
        }
    }

    func playerRequests(_ client: String) -> [StreamStubRequest] {
        playerRequests.filter { $0.client == client }.map(\.request)
    }

    var mediaRequests: [StreamStubRequest] { server.requests.filter { $0.url.isGoogleVideo } }

    var shellRequests: Int { server.requests.filter { $0.url.host == "music.youtube.com" && $0.url.path == "/" }.count }

    private func respond(_ request: StreamStubRequest) -> StreamStubResponse {
        let url = request.url
        if url.isGoogleVideo {
            let client = url.streamQueryValue("c") ?? ""
            return lock.withLock { media[client] } ?? .audio(bytes: 64 * 1024)
        }
        if url.path == "/youtubei/v1/player" {
            let delay = lock.withLock { playerDelay }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            let context = request.jsonBody?["context"] as? [String: Any]
            let client = (context?["client"] as? [String: Any])?["clientName"] as? String ?? ""
            return lock.withLock { () -> StreamStubResponse in
                guard var queue = answers[client], !queue.isEmpty else {
                    return .json(Data(#"{"playabilityStatus":{"status":"UNPLAYABLE","reason":"not modelled"}}"#.utf8))
                }
                let next = queue.removeFirst()
                if queue.isEmpty { queue = [next] }
                answers[client] = queue
                return next
            }
        }
        switch (url.host, url.path) {
        case ("music.youtube.com", "/"): return shell
        case ("www.youtube.com", "/sw.js_data"): return .text(StreamFixture.string("sw_js_data.txt"))
        case ("www.youtube.com", "/iframe_api"): return .text(StreamFixture.string("iframe_api.js"))
        case ("raw.githubusercontent.com", _): return .json(StreamFixture.data("zemer_player_configs.json"))
        default:
            if url.path.hasSuffix("player_ias.vflset/en_US/base.js") {
                return StreamStubResponse(status: 200, headers: ["Content-Type": "text/javascript"], body: Data(StreamFixture.playerSource.utf8))
            }
            return StreamStubResponse(status: 404)
        }
    }

    func extractor(
        catalog: [StreamClientProfile] = StreamClientProfile.defaultCatalog, cipher: Bool = false,
        poTokens: StreamPoTokenProvider? = nil, auth: StreamAuthProvider? = nil, clock: StreamTestClock = StreamTestClock()
    ) -> InnerTubeStreamExtractor {
        InnerTubeStreamExtractor(
            session: session, catalog: catalog, visitorData: StreamVisitorDataStore(session: session, now: clock.function),
            cipher: cipher ? StreamCipherSolver(session: session, cacheDirectory: nil, now: clock.function) : nil,
            poTokens: poTokens, auth: auth, language: { "en" }, now: clock.function
        )
    }

    func resolver(
        catalog: [StreamClientProfile] = StreamClientProfile.defaultCatalog, cipher: Bool = false,
        auth: StreamAuthProvider? = nil, ceiling: Int = Int.max, clock: StreamTestClock = StreamTestClock()
    ) -> StreamResolver {
        var configuration = StreamResolver.Configuration()
        configuration.catalog = catalog
        configuration.playbackCeilingKbps = { ceiling }
        configuration.probeTimeout = 2
        return StreamResolver(
            session: session, configuration: configuration,
            visitorData: StreamVisitorDataStore(session: session, now: clock.function),
            cipher: cipher ? StreamCipherSolver(session: session, cacheDirectory: nil, now: clock.function) : nil,
            auth: auth, now: clock.function
        )
    }
}

/// A PoToken provider that hands out fixed tokens, or fails.
final class FakePoTokenProvider: StreamPoTokenProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(videoId: String, visitorData: String)] = []
    let token: StreamPoToken?
    let error: Error?

    init(token: StreamPoToken? = StreamPoToken(playerRequestToken: "PLAYER_TOKEN", streamingDataToken: "STREAMING_TOKEN"), error: Error? = nil) {
        self.token = token
        self.error = error
    }

    var requested: [(videoId: String, visitorData: String)] { lock.withLock { calls } }

    func poToken(videoId: String, visitorData: String) async throws -> StreamPoToken? {
        lock.withLock { calls.append((videoId, visitorData)) }
        if let error { throw error }
        return token
    }

    func close() async {}
}
