import VibraMusicCore
import InnerTube
import PlaybackPolicy
import StreamResolution
import XCTest
@testable import Vibra Music

/// The app's real stream wiring (AppModel's resolver configuration, the app's HTTP
/// session, the WebView PoToken provider) against YouTube, in the app process on the simulator.
/// Skipped unless VIBRAMUSIC_LIVE_TESTS=1 (pass TEST_RUNNER_VIBRAMUSIC_LIVE_TESTS=1 to xcodebuild).
@MainActor
final class LiveWiringTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        guard ProcessInfo.processInfo.environment["VIBRAMUSIC_LIVE_TESTS"] == "1" else {
            throw XCTSkip("set VIBRAMUSIC_LIVE_TESTS=1 to talk to YouTube")
        }
    }

    /// A music video and three YouTube Music songs (the "Daft Punk" search's top song and two of
    /// its radio). All four must resolve to whole, playable streams through the app's catalog.
    func testTheAppsResolverYieldsAPlayableStreamForSongsAndVideos() async throws {
        let ceiling = PlaybackQualityCeiling(network: NetworkMonitor())
        let resolver = StreamResolver.standard(
            session: VibraMusicHTTP.session,
            configuration: AppModel.streamConfiguration(ceiling: ceiling),
            poTokens: WebViewPoTokenProvider(),
            auth: InnerTubeStreamAuth(client: InnerTubeClient(session: VibraMusicHTTP.session))
        )
        var failures: [String] = []
        for id in ["dQw4w9WgXcQ", "khnokW3Mw24", "4D7u5KF7SP8", "7bBjiHl6mIQ"] {
            do {
                let stream = try await resolver.resolve(id)
                print("LIVE \(id): \(stream.profileId) itag \(stream.itag)")
            } catch {
                print("LIVE \(id): FAILED \(error)")
                failures.append(id)
            }
        }
        XCTAssertEqual(failures, [], "no playable stream for \(failures)")
    }
}
