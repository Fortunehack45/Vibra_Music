import XCTest
@testable import Automix

/// Port of AutomixAnalysisSourceTest.kt. (Its third case, about `QualityUpgrade.upgradedUri`,
/// belongs to the Playback module's port.)
final class AutomixAnalysisSourceTests: XCTestCase {

    func testYouTubeAnalysisAcceptsOnlyItsCanonicalCacheKey() {
        XCTAssertTrue(AutomixAnalysisSource.isCanonicalYouTubeRendition(videoId: "video", cacheKey: "video"))
        XCTAssertFalse(AutomixAnalysisSource.isCanonicalYouTubeRendition(videoId: "video", cacheKey: "video#alt"))
        XCTAssertFalse(AutomixAnalysisSource.isCanonicalYouTubeRendition(videoId: "video", cacheKey: "video#hifi"))
    }

    func testAnyRenditionIsCanonicalWhenTheURIHasNoVideoId() {
        XCTAssertTrue(AutomixAnalysisSource.isCanonicalYouTubeRendition(videoId: nil, cacheKey: "file:///song.m4a"))
    }

    func testAnalysisURIAsksTheResolverToBypassPlaybackSubstitutions() {
        XCTAssertTrue(AutomixAnalysisSource.opusURI(videoId: "video").contains("v=video&automix_opus=1"))
        XCTAssertTrue(AutomixAnalysisSource.requestsYouTubeOpus("1"))
        XCTAssertFalse(AutomixAnalysisSource.requestsYouTubeOpus(nil))
        XCTAssertFalse(AutomixAnalysisSource.requestsYouTubeOpus("0"))
    }

    func testAnalysisURIRoundTripsThroughURLComponents() throws {
        let url = try XCTUnwrap(URL(string: AutomixAnalysisSource.opusURI(videoId: "dQw4w9WgXcQ")))
        XCTAssertEqual(url.automixQueryParameter("v"), "dQw4w9WgXcQ")
        XCTAssertTrue(AutomixAnalysisSource.requestsYouTubeOpus(url.automixQueryParameter(AutomixAnalysisSource.opusQueryParameter)))
        XCTAssertNil(URL(fileURLWithPath: "/tmp/a.m4a").automixQueryParameter("v"))
    }

    func testLocalSourcesAreFilesAndMediaLibraryAssets() throws {
        XCTAssertTrue(AutomixLocalAudioSource.isLocal(URL(fileURLWithPath: "/tmp/song.m4a")))
        XCTAssertTrue(AutomixLocalAudioSource.isLocal(try XCTUnwrap(URL(string: "ipod-library://item/item.m4a?id=123"))))
        XCTAssertFalse(AutomixLocalAudioSource.isLocal(try XCTUnwrap(URL(string: "vibramusic://watch?v=abc"))))
        XCTAssertFalse(AutomixLocalAudioSource.isLocal(try XCTUnwrap(URL(string: "https://example.com/a.mp3"))))
    }

    func testLocalFilesThatAreMissingEmptyOrDirectoriesAreNotReadable() throws {
        let directory = try SyntheticAudio.temporaryDirectory(for: self)
        let empty = directory.appendingPathComponent("empty.m4a")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        let full = directory.appendingPathComponent("full.caf")
        try SyntheticAudio.write(mono: [Float](repeating: 0.1, count: 4410), sampleRate: 44100, to: full)

        XCTAssertFalse(AutomixLocalAudioSource.isReadable(directory.appendingPathComponent("missing.m4a")))
        XCTAssertFalse(AutomixLocalAudioSource.isReadable(empty))
        XCTAssertFalse(AutomixLocalAudioSource.isReadable(directory))
        XCTAssertTrue(AutomixLocalAudioSource.isReadable(full))
    }

    func testRenditionIsCompleteOnlyWithAKnownLengthFullyCached() {
        let file = URL(fileURLWithPath: "/tmp/x")
        XCTAssertTrue(AutomixRendition(key: "a", contentLength: 100, cachedPrefix: 100, fileURL: file).isComplete)
        XCTAssertFalse(AutomixRendition(key: "a", contentLength: 100, cachedPrefix: 99, fileURL: file).isComplete)
        XCTAssertFalse(AutomixRendition(key: "a", contentLength: 0, cachedPrefix: 500, fileURL: file).isComplete)
    }
}
