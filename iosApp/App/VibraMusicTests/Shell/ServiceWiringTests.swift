import AudioCache
import VibraMusicCore
import InnerTube
import Integrations
import NetworkLibrary
import XCTest
@testable import VibraMusic

// The app's own wiring between the player, the settings and the services behind them. Each test
// drives the real call a screen makes and reads what arrives on the other side: a request on the
// wire, or a source the player can read. (PORTING.md "Likes and dislikes", "SMB network library",
// "WebDAV network library" and "Scrobbling".)

/// An app container that never restores a queue, integrates with the system or reaches the network
/// by itself: `innerTube` and `settings` are what a test answers for.
@MainActor
func makeAppModel(_ test: XCTestCase, settings: AppSettings? = nil, innerTube: InnerTubeClient? = nil) -> AppModel {
    var launch = AppLaunchOptions()
    launch.restoresQueue = false
    launch.integratesWithSystem = false
    launch.isUITest = true
    let model = AppModel(
        settings: settings ?? makeTestSettings(),
        likeState: LikeState(),
        searchHistory: SearchHistory(defaults: UserDefaults(suiteName: "vibramusic.wiring.\(UUID().uuidString)")!),
        network: NetworkMonitor(),
        innerTube: innerTube ?? InnerTubeClient(session: makeAccountOfflineSession()),
        audioCache: nil,
        launch: launch
    )
    let engine = model.engine
    test.addTeardownBlock { @MainActor in engine.shutdown() }
    return model
}

/// "Likes and dislikes": the heart and the thumbs-down on a song reach the signed-in account.
@MainActor
final class RatingsReachTheAccountTests: XCTestCase {
    private let likeAnswer = #"{"responseContext":{},"actions":[{"addToToastAction":{"item":{"notificationTextRenderer":{"successResponseText":{"runs":[{"text":"Saved to liked music"}]}}}}}]}"#

    func testLikingAndDislikingASongSendsTheRatingToYouTubeMusic() async throws {
        let answer = likeAnswer
        let http = HTTPRecordingStub { request in
            request.path.hasPrefix("/youtubei/v1/like/")
                ? .json(answer)
                : StubbedHTTPResponse(headers: ["Content-Type": "text/html"], body: Data("<html></html>".utf8))
        }
        let client = InnerTubeClient(session: http.session, retryBaseDelay: .milliseconds(1))
        await client.setCookie("SID=1; SAPISID=secret")
        let app = makeAppModel(self, innerTube: client)
        let song = Song(videoId: "rateMe00001", title: "Rated", artist: "Artist")

        app.player.toggleLike(song)
        await waitUntil("the like reaches the account") { !http.requests(toPath: "/youtubei/v1/like/like").isEmpty }
        let target = http.requests(toPath: "/youtubei/v1/like/like").last?.json["target"] as? [String: Any]
        XCTAssertEqual(target?["videoId"] as? String, song.videoId)

        app.player.toggleDislike(song)
        await waitUntil("the dislike reaches the account") { !http.requests(toPath: "/youtubei/v1/like/dislike").isEmpty }
        let disliked = http.requests(toPath: "/youtubei/v1/like/dislike").last?.json["target"] as? [String: Any]
        XCTAssertEqual(disliked?["videoId"] as? String, song.videoId)
    }
}

/// "SMB network library" and "WebDAV network library": a row from a server becomes a source the
/// player reads (`AppModel.networkSource(for:)`, handed to the stream factory at launch).
@MainActor
final class NetworkSourceWiringTests: XCTestCase {
    /// WebDAV, against a real server on the loopback: the row's file is measured and read in
    /// ranges, and every request carries the login saved in Settings.
    func testAWebDavRowIsReadFromItsServerWithTheSavedLogin() async throws {
        let audio = Data((0..<250).map { UInt8($0) })
        let server = try LoopbackHTTPServer { request in
            guard request.path == "/dav/Music/Song.flac" else { return .status(404) }
            let headers = ["Content-Type": "audio/flac", "Accept-Ranges": "bytes"]
            let bounds = request.headers["range"].map { $0.dropFirst("bytes=".count).split(separator: "-").compactMap { Int($0) } } ?? []
            guard bounds.count == 2 else { return StubbedHTTPResponse(headers: headers, body: audio) }
            let end = min(bounds[1], audio.count - 1)
            return StubbedHTTPResponse(status: 206, headers: headers.merging(["Content-Range": "bytes \(bounds[0])-\(end)/\(audio.count)"]) { $1 },
                                       body: audio.subdata(in: bounds[0]..<(end + 1)))
        }
        try await server.start(for: self)
        let settings = makeTestSettings()
        let app = makeAppModel(self, settings: settings)
        let row = WebDavConfig.songFor(fileUrl: server.baseURL.appending(path: "dav/Music/Song.flac").absoluteString, albumName: "Music")
        XCTAssertNil(app.player.sources.networkSource(row), "no server saved yet")

        settings.configureWebDAV(url: server.baseURL.appending(path: "dav").absoluteString, username: "nas-user", password: "nas-pass")
        let source = try XCTUnwrap(app.player.sources.networkSource(row), "the row has no source to read")

        let info = try await source.contentInfo()
        XCTAssertEqual(info.contentLength, Int64(audio.count))
        let bytes = try await source.read(16..<48)
        XCTAssertEqual(bytes, audio.subdata(in: 16..<48))
        let login = "Basic " + Data("nas-user:nas-pass".utf8).base64EncodedString()
        XCTAssertFalse(server.requests.isEmpty)
        XCTAssertTrue(server.requests.allSatisfy { $0.headers["authorization"] == login }, "\(server.requests.map(\.headers))")
    }

    /// An `smb://` row has a source while a share is saved and no other row gets one, and the
    /// source reads the file its own row names, off the saved share.
    func testAnSmbRowGetsASourceOnlyWhileAShareIsSavedAndReadsItsOwnFile() async throws {
        let settings = makeTestSettings()
        let app = makeAppModel(self, settings: settings)
        let first = Data((0..<200).map { UInt8($0) })
        let second = Data((0..<120).map { UInt8(255 - $0) })
        app.smbSessionFactory = MemorySmbFactory(share: MemorySmbShare(files: [
            "Daft Punk/Discovery/01 One More Time.flac": first,
            "Daft Punk/Discovery/02 Aerodynamic.flac": second,
        ]))
        let row = SmbConfig.songFor(host: "nas.local", share: "music", path: "Daft Punk/Discovery/01 One More Time.flac", albumName: "Discovery")
        let other = SmbConfig.songFor(host: "nas.local", share: "music", path: "Daft Punk/Discovery/02 Aerodynamic.flac", albumName: "Discovery")
        XCTAssertNil(app.player.sources.networkSource(row), "no share saved yet")

        settings.configureSMB(host: "nas.local", share: "music", basePath: "", username: "me", password: "pw")
        let source = try XCTUnwrap(app.player.sources.networkSource(row), "the row has no source to read")
        let otherSource = try XCTUnwrap(app.player.sources.networkSource(other))
        let sourceInfo = try await source.contentInfo()
        let otherInfo = try await otherSource.contentInfo()
        XCTAssertEqual(sourceInfo.contentLength, Int64(first.count))
        XCTAssertEqual(otherInfo.contentLength, Int64(second.count))
        let sourceBytes = try await source.read(10..<40)
        let otherBytes = try await otherSource.read(10..<40)
        XCTAssertEqual(sourceBytes, first.subdata(in: 10..<40))
        XCTAssertEqual(otherBytes, second.subdata(in: 10..<40))
        XCTAssertNil(app.player.sources.networkSource(Song(videoId: "dQw4w9WgXcQ", title: "Song", artist: "Artist")), "a YouTube row is not a share's")
    }

    func testEachSmbCredentialsSetKeepsItsOwnPoolWhenAnotherIsUsed() {
        let app = makeAppModel(self)
        let nas = SmbCredentials(host: "nas.local", share: "music", username: "me", password: "pw")
        let office = SmbCredentials(host: "office.local", share: "audio", username: "me", password: "pw")
        let nasPool = app.smbPool(for: nas)
        _ = app.smbPool(for: office)
        XCTAssertTrue(app.smbPool(for: nas) === nasPool, "coming back to the first share must find its warm pool")
    }
}
