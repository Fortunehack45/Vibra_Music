import VibraMusicCore
import Canvas
import Playback
import XCTest
@testable import VibraMusic

/// Records every request the service's session sends and answers none: these tests only need to
/// know whether a download was started. Kept here rather than VibraMusicTestSupport's stub, whose
/// import would leak its XCTestCase helpers across the whole app test target.
private final class RecordingURLProtocol: URLProtocol {
    // Written from URLSession's queue, read on the main actor: behind a lock.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [URL] = []
    static var requests: [URL] { lock.withLock { recorded } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let url = request.url { Self.lock.withLock { Self.recorded.append(url) } }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        lock.withLock { recorded = [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// The lock screen's animated cover resolution: ``CanvasPolicy`` in, publish out.
/// The key choice itself is ``NowPlayingInfoBuilder``'s (tested in the Playback package); this
/// side has to fetch nothing it is not allowed to, publish nothing without a local file, and
/// give each clip its own `artworkID`.
@MainActor
final class CurrentTrackCanvasTests: XCTestCase {
    /// What the service published to the engine, in order.
    private final class Sink: @unchecked Sendable {
        var seen: [[NowPlayingAnimatedArtwork]] = []
        /// Every publish that carried a clip.
        var clips: [[NowPlayingAnimatedArtwork]] { seen.filter { !$0.isEmpty } }
    }

    /// Per-file video sizes, filled once the cache has named the files; anything else reads as
    /// the service's default size.
    private final class Sizes: @unchecked Sendable {
        var byFile: [URL: CGSize] = [:]
    }

    private struct FakeLookup: PlayerCanvasLookup {
        let clip: CanvasArtwork?
        func cachedCanvas(for song: Song, spotifyFirst: Bool) async -> CanvasArtwork? { nil }
        func lookUpCanvas(for song: Song, spotifyFirst: Bool) async -> CanvasArtwork? { clip }
    }

    /// Counts the network lookups, to prove the gate stops before any request.
    private final class CountingLookup: PlayerCanvasLookup, @unchecked Sendable {
        let clip: CanvasArtwork?
        var lookups = 0
        init(clip: CanvasArtwork?) { self.clip = clip }
        func cachedCanvas(for song: Song, spotifyFirst: Bool) async -> CanvasArtwork? { nil }
        func lookUpCanvas(for song: Song, spotifyFirst: Bool) async -> CanvasArtwork? {
            lookups += 1
            return clip
        }
    }

    private var song: Song {
        Song(videoId: "canvas-a", title: "Blinding Lights", artist: "The Weeknd",
             thumbnailUrl: "https://img.test/cover", albumName: "After Hours")
    }

    /// The resolution runs for iOS 26+ only: below that nothing is asked for (no lookup, no
    /// download), so a test expecting a publish can only run where the system takes the clips.
    private var carriesAnAnimatedCover: Bool {
        #if os(iOS)
        guard #available(iOS 26.0, *) else { return false }
        return true
        #else
        return false
        #endif
    }

    private func makeService(
        lookup: PlayerCanvasLookup = FakeLookup(clip: nil),
        videoSize: CGSize = CGSize(width: 1280, height: 1280),
        sizes: Sizes = Sizes(),
        tallSkip: String? = "not offered"
    ) -> (service: CurrentTrackCanvas, sink: Sink, cache: CanvasClipCache) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("np-canvas-\(UUID().uuidString)", isDirectory: true)
        let cache = CanvasClipCache(directory: directory)
        let sink = Sink()
        let service = CurrentTrackCanvas(
            lookup: lookup,
            cache: cache,
            session: RecordingURLProtocol.session(),
            videoSize: { [sizes] url in sizes.byFile[url] ?? videoSize },
            tallSkip: { tallSkip }
        ) { [sink] in sink.seen.append($0) }
        return (service, sink, cache)
    }

    /// The switch off, or Wi-Fi-only on a metered network: no lookup, no download, nothing
    /// published — the still cover stands.
    func testADisallowedCanvasReachesNeitherTheLookupNorTheDownload() async throws {
        let clip = CanvasArtwork(url: "https://clips.test/blinding.mp4", title: "Blinding Lights", artist: "The Weeknd")
        let lookup = CountingLookup(clip: clip)
        let (service, sink, _) = makeService(lookup: lookup)
        await service.update(song: song, allowed: false, spotifyFirst: false)
        XCTAssertTrue(sink.clips.isEmpty, "nothing is published")
        XCTAssertEqual(lookup.lookups, 0, "the lookup never started")
        XCTAssertTrue(RecordingURLProtocol.requests.isEmpty, "no download was started")
    }

    /// A local song carries its own audio and no catalogue canvas; the rule the player screen
    /// follows applies to the lock screen too. A lookup miss publishes nothing but a nil.
    func testALocalSongNeverAsksForAClip() async throws {
        let (service, sink, _) = makeService()
        var local = song
        local.localUri = "file:///music/a.m4a"
        await service.update(song: local, allowed: true, spotifyFirst: false)
        XCTAssertEqual(sink.seen, [[]], "only the drop, never a clip")
    }

    /// A square clip already on disk goes straight out: the published file is the cache's local
    /// file, so the system's video handler will answer with it without a download.
    func testASquareClipIsPublishedFromItsLocalFile() async throws {
        try XCTSkipUnless(carriesAnAnimatedCover, "this runtime takes no animated artwork")
        let clip = CanvasArtwork(url: "https://clips.test/blinding.mp4", title: "Blinding Lights", artist: "The Weeknd")
        let (service, sink, cache) = makeService(lookup: FakeLookup(clip: clip))
        let stored = try XCTUnwrap(cache.store(Data([1, 2, 3]), for: try XCTUnwrap(URL(string: clip.url))))
        await service.update(song: song, allowed: true, spotifyFirst: false)
        let published = try XCTUnwrap(sink.seen.last).first
        XCTAssertNotNil(published, "the square clip is published")
        XCTAssertTrue(RecordingURLProtocol.requests.isEmpty, "the clip was already local; no download")
        XCTAssertEqual(published?.fileURL, stored)
        XCTAssertEqual(published?.pixels, CGSize(width: 1280, height: 1280), "the injected reader's true pixel size")
        XCTAssertEqual(
            published?.artworkID,
            CurrentTrackCanvas.artworkID(for: stored, still: song.thumbnailUrl))
        XCTAssertTrue(published?.artworkID.hasSuffix("/\(song.thumbnailUrl ?? "")") == true)
    }

    func testAChangedClipChangesArtworkID() {
        let first = CurrentTrackCanvas.artworkID(for: URL(fileURLWithPath: "/c/1111.mp4"), still: "cover")
        let second = CurrentTrackCanvas.artworkID(for: URL(fileURLWithPath: "/c/2222.mp4"), still: "cover")
        XCTAssertNotEqual(first, second, "a changed clip is a changed id")
        XCTAssertEqual(first, CurrentTrackCanvas.artworkID(for: URL(fileURLWithPath: "/c/1111.mp4"), still: "cover"), "the same clip keeps its id")
        XCTAssertNotEqual(first, CurrentTrackCanvas.artworkID(for: URL(fileURLWithPath: "/c/1111.mp4"), still: "other"), "the preview counts in the id too")
    }

    /// Apple's motion artwork is HLS, which the video handler can't return: the playlist is
    /// fetched to be joined into a local file, and when that fails nothing is published — never
    /// the remote stream in its place. (The join itself is tested in the Canvas package.)
    func testAnHLSClipThatCannotBeJoinedPublishesNothing() async throws {
        try XCTSkipUnless(carriesAnAnimatedCover, "this runtime takes no animated artwork")
        let clip = CanvasArtwork(url: "https://clips.test/motion.m3u8", title: "A Song", artist: "An Artist")
        let (service, sink, cache) = makeService(lookup: FakeLookup(clip: clip))
        await service.update(song: song, allowed: true, spotifyFirst: false)
        XCTAssertTrue(sink.clips.isEmpty, "a stream is not publishable artwork")
        XCTAssertEqual(RecordingURLProtocol.requests, [try XCTUnwrap(URL(string: clip.url))], "the playlist was asked for; nothing after it failed")
        XCTAssertEqual(cache.currentBytes, 0)
    }

    /// A track change re-keys first, so the last track's clip stands in for nothing: the service
    /// publishes nil while the new resolution runs.
    func testAChangedSongDropsTheLastClipsArtwork() async throws {
        try XCTSkipUnless(carriesAnAnimatedCover, "this runtime takes no animated artwork")
        let first = CanvasArtwork(url: "https://clips.test/first.mp4", title: "First", artist: "An Artist")
        let (service, sink, cache) = makeService(lookup: FakeLookup(clip: first))
        _ = cache.store(Data([1]), for: try XCTUnwrap(URL(string: first.url)))
        let next = Song(videoId: "canvas-b", title: "Next", artist: "Other")
        await service.update(song: song, allowed: true, spotifyFirst: false)
        await service.update(song: next, allowed: true, spotifyFirst: false)
        XCTAssertEqual(sink.seen.count, 4, "drop, clip, then the new key's drop, at most")
        XCTAssertEqual(sink.seen.suffix(2).first, [], "the last track's clip was dropped")
    }

    /// The same song under a new engine item (a quality upgrade's rendition, or another queue
    /// slot) re-resolves: the engine drops its clip on every item change, so the clip has to be
    /// published again for the new item rather than lost for the rest of the track.
    func testTheSameSongUnderANewItemIsResolvedAgain() async throws {
        try XCTSkipUnless(carriesAnAnimatedCover, "this runtime takes no animated artwork")
        let clip = CanvasArtwork(url: "https://clips.test/same.mp4", title: "Same", artist: "An Artist")
        let (service, sink, cache) = makeService(lookup: FakeLookup(clip: clip))
        _ = cache.store(Data([1]), for: try XCTUnwrap(URL(string: clip.url)))
        await service.update(itemID: "slot-1", song: song, allowed: true, spotifyFirst: false)
        await service.update(itemID: "slot-1#hi-res", song: song, allowed: true, spotifyFirst: false)
        XCTAssertEqual(sink.seen.count, 4, "drop, clip, drop, clip")
        XCTAssertEqual(sink.seen[2], [], "the item change drops the first item's clip first")
        XCTAssertEqual(sink.seen.last?.count, 1, "the new item ends with the clip, not the still alone")
    }

    /// A missed lookup on a second turn of the same key: silence, not a re-fetched nil.
    func testRepeatingTheSameKeyPublishesNothingNew() async throws {
        let (service, sink, _) = makeService()
        await service.update(song: song, allowed: true, spotifyFirst: false)
        await service.update(song: song, allowed: true, spotifyFirst: false)
        XCTAssertEqual(sink.seen, [[]], "the second turn changed nothing")
    }

    /// The tall clip is for an iPhone whose system lists the 3x4 key; an iPad, or a system
    /// without that key, keeps the square alone.
    func testTheTallClipIsForAPhoneThatOffersThe3x4Key() {
        XCTAssertNil(CurrentTrackCanvas.tallSkip(isPhone: true, offers3x4: true))
        XCTAssertEqual(CurrentTrackCanvas.tallSkip(isPhone: false, offers3x4: true), "iPad")
        XCTAssertEqual(CurrentTrackCanvas.tallSkip(isPhone: false, offers3x4: false), "iPad")
        XCTAssertEqual(CurrentTrackCanvas.tallSkip(isPhone: true, offers3x4: false), "not offered")
    }

    /// Where the tall clip is wanted it goes out beside the square, each with its own size, and
    /// the square does not wait for it; where it isn't (iPad, no 3x4 key) the square goes alone
    /// and the line says why.
    func testTheTallClipJoinsTheSquareOnlyWhereItIsWanted() async throws {
        try XCTSkipUnless(carriesAnAnimatedCover, "this runtime takes no animated artwork")
        let clip = CanvasArtwork(url: "https://clips.test/square.mp4", tallUrl: "https://clips.test/tall.mp4")
        for skip in [nil, "iPad", "not offered"] as [String?] {
            let sizes = Sizes()
            let (service, sink, cache) = makeService(lookup: FakeLookup(clip: clip), sizes: sizes, tallSkip: skip)
            let square = try XCTUnwrap(cache.store(Data([1]), for: try XCTUnwrap(URL(string: clip.url))))
            let tall = try XCTUnwrap(cache.store(Data([2]), for: try XCTUnwrap(URL(string: clip.tallUrl ?? ""))))
            sizes.byFile[tall] = CGSize(width: 1080, height: 1440)
            await service.update(song: song, allowed: true, spotifyFirst: false)
            let label = "skip: \(skip ?? "none")"
            let files = sink.clips.map { $0.map(\.fileURL) }
            XCTAssertEqual(files, skip == nil ? [[square], [square, tall]] : [[square]], label)
            XCTAssertEqual(sink.clips.last?.last?.pixels, skip == nil ? CGSize(width: 1080, height: 1440) : CGSize(width: 1280, height: 1280),
                           "each clip carries its own size; \(label)")
            XCTAssertTrue(service.diagnostic.decision.contains("3x4: \(skip ?? "1080x1440")"), "\(label): \(service.diagnostic.decision)")
        }
    }

    /// A clip whose read size answers nothing (corrupt file, audio only): nothing published.
    func testAClipWithoutAReadableSizePublishesNothing() async throws {
        let clip = CanvasArtwork(url: "https://clips.test/broken.mp4", title: "Blinding Lights", artist: "The Weeknd")
        let (service, sink, cache) = makeService(lookup: FakeLookup(clip: clip), videoSize: .zero)
        _ = cache.store(Data([1]), for: try XCTUnwrap(URL(string: clip.url)))
        await service.update(song: song, allowed: true, spotifyFirst: false)
        XCTAssertTrue(sink.clips.isEmpty, "no size, no key, no publish")
    }
}
