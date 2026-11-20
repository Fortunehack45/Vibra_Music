import AVFoundation
import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import Downloads

// The live test resolves through the real StreamResolution module, which DownloadsTests only gets
// as a test dependency (`extraTestDependencies` in Package.swift, which also defines the flag
// below). Guarded so the test target still builds on a manifest without it; the test then says
// why it can't run.
#if TEST_DEPENDENCY_STREAMRESOLUTION
import StreamResolution

/// The app's wiring of StreamResolution into the queue, reduced to what the test needs: the
/// download resolve (AAC only, since AVPlayer can't play WebM) handed over as Core's
/// `ResolvedStream`, media headers included.
private final class YouTubeDownloadResolver: StreamResolving, @unchecked Sendable {
    let resolver: StreamResolver
    private let lock = NSLock()
    private var resolved: [ResolvedYouTubeStream] = []
    private var asked: [Int?] = []

    init(resolver: StreamResolver) {
        self.resolver = resolver
    }

    var streams: [ResolvedYouTubeStream] { lock.withLock { resolved } }

    /// The bitrate ceiling each resolve was asked for, nil meaning whichever rung is best.
    var requestedCeilings: [Int?] { lock.withLock { asked } }

    func resolveStream(for song: Song, request: StreamRequest) async throws -> ResolvedStream {
        lock.withLock { asked.append(request.maxKbps) }
        let stream = try await resolver.resolveForDownload(song.videoId, maxKbps: request.maxKbps ?? Int.max, requireM4a: true)
        lock.withLock { resolved.append(stream) }
        return ResolvedStream(
            url: stream.url, origin: .youtube, mimeType: stream.mimeType,
            format: StreamFormat(codec: "aac", kbps: stream.kbps), headers: stream.mediaHeaders,
            loudnessDb: stream.loudnessDb, contentLength: stream.contentLength, expiresAt: stream.expiresAt,
            durationSeconds: stream.approxDurationMs.map { Int($0 / 1_000) }
        )
    }
}

/// Against the real YouTube. Skipped unless VIBRAMUSIC_LIVE_TESTS=1.
@MainActor
final class DownloadLiveTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        guard ProcessInfo.processInfo.environment["VIBRAMUSIC_LIVE_TESTS"] == "1" else {
            throw XCTSkip("set VIBRAMUSIC_LIVE_TESTS=1 to download from YouTube")
        }
    }

    private func download(_ track: Song, quality: DownloadQuality) async throws -> (file: URL, tags: EmbeddedTags, stream: ResolvedYouTubeStream, library: DownloadLibrary) {
        let root = try makeTemporaryDirectory()
        let store = DownloadStore(root: root)
        let library = DownloadLibrary(store: store)
        let defaults = EphemeralDefaults()
        let settings = AppSettings(defaults: defaults.defaults, credentials: InMemoryCredentialStore())
        settings.downloadQuality = quality
        // StreamResolution's default walk, exactly as the app uses it.
        var configuration = StreamResolver.Configuration()
        configuration.catalog = StreamClientProfile.defaultCatalog
        let youtube = StreamResolver.standard(session: .shared, configuration: configuration, defaults: nil)
        let resolver = YouTubeDownloadResolver(resolver: youtube)
        // A foreground session: background ones need an app bundle. Same transport class.
        let transport = URLSessionDownloadTransport(configuration: .ephemeral, stagingDirectory: store.stagingDirectory)
        defer { transport.invalidate() }
        let manager = DownloadManager(
            settings: settings, resolver: resolver, network: FakeNetworkMonitor(.wifi), transport: transport,
            library: library, http: .shared,
            lyricsProvider: { song in DownloadLyrics(plain: "[00:18.50]\(song.title)\n[00:22.00]live test line") },
            refusalHandler: { url, status in await youtube.onPlaybackRefused(url: url, statusCode: status) }
        )

        manager.enqueue(track)
        let finished = await withTimeout(seconds: 240) { await manager.waitUntilIdle(); return true }
        XCTAssertEqual(finished, true, "the download didn't finish in time")
        let file = try XCTUnwrap(library.savedFileURL(for: track.videoId),
                                 "download failed: \(String(describing: manager.active[track.videoId]))")
        let tags = await EmbeddedTags.read(from: file)
        let stream = try XCTUnwrap(resolver.streams.last)
        XCTAssertFalse(resolver.requestedCeilings.isEmpty)
        XCTAssertTrue(resolver.requestedCeilings.allSatisfy { $0 == quality.maxKbps },
                      "the resolve was asked for \(resolver.requestedCeilings), not \(String(describing: quality.maxKbps))")
        return (file, tags, stream, library)
    }

    /// A whole real track through the real resolver: ranged googlevideo transfers with the
    /// client's headers, the duration patch, the tags, the cover, the lyrics, read back by AVAsset.
    func testARealYouTubeTrackDownloadsWholeAndReadsBackWithItsTags() async throws {
        let track = Song(
            videoId: "dQw4w9WgXcQ", title: "Never Gonna Give You Up", artist: "Rick Astley",
            thumbnailUrl: "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg", albumName: "Whenever You Need Somebody"
        )
        let (file, tags, stream, library) = try await download(track, quality: .high)

        XCTAssertEqual(file.pathExtension, "m4a")
        XCTAssertTrue([139, 140].contains(stream.itag), "AAC for AVPlayer, got itag \(stream.itag)")
        let size = DownloadStore.fileSize(file)
        let length = try XCTUnwrap(stream.contentLength)
        XCTAssertGreaterThan(size, length, "every byte of the stream plus the tags")

        XCTAssertTrue(tags.isPlayable)
        let duration = try XCTUnwrap(tags.durationSeconds)
        XCTAssertGreaterThan(duration, 0)
        let expected = Double(try XCTUnwrap(stream.approxDurationMs)) / 1_000
        XCTAssertEqual(duration, expected, accuracy: 1.5, "AVFoundation must read the true length, not twice it")
        print("live download: \(stream.clientName) itag \(stream.itag) \(stream.kbps) kbps, \(size) B on disk, AVAsset \(duration) s, stated \(expected) s")

        XCTAssertEqual(tags.title, "Never Gonna Give You Up")
        XCTAssertEqual(tags.artist, "Rick Astley")
        XCTAssertEqual(tags.album, "Whenever You Need Somebody")
        XCTAssertEqual(tags.lyrics, "[00:18.50]Never Gonna Give You Up\n[00:22.00]live test line")
        XCTAssertEqual(tags.artworkMime, "image/jpeg")
        XCTAssertNotNil(tags.artwork.flatMap(TestImages.size(of:)))

        let row = try XCTUnwrap(library.songs().first)
        XCTAssertEqual(row.downloadFormat, youtubeDownloadBadge(extension: "m4a", kbps: stream.kbps))
        XCTAssertTrue(try XCTUnwrap(row.thumbnailUrl).hasPrefix("file://"))

        // AVPlayer's decoder gets through the file end to end.
        let asset = AVURLAsset(url: file)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: audio[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var frames = 0
        while let buffer = output.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(buffer) }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(Double(frames) / 44_100, expected, accuracy: 1.5, "decoded audio covers the whole track")
    }

    /// Standard is YouTube's capped AAC rung, and still a whole, playable file.
    func testStandardQualityStaysUnderItsCeiling() async throws {
        let track = Song(videoId: "kJQP7kiw5Fk", title: "Despacito", artist: "Luis Fonsi")
        let (_, tags, stream, _) = try await download(track, quality: .standard)
        // The request itself carried the 128 kbps cap (checked in `download`); the rung that came
        // back may sit a hair over it when a track's cheapest AAC does.
        XCTAssertEqual(DownloadQuality.standard.maxKbps, 128)
        XCTAssertLessThanOrEqual(stream.kbps, 130)
        print("live standard download: \(stream.clientName) itag \(stream.itag) \(stream.kbps) kbps")
        XCTAssertTrue(tags.isPlayable)
        XCTAssertEqual(try XCTUnwrap(tags.durationSeconds), Double(try XCTUnwrap(stream.approxDurationMs)) / 1_000, accuracy: 1.5)
        XCTAssertEqual(tags.title, "Despacito")
    }
}
#else
final class DownloadLiveTests: XCTestCase {
    func testARealYouTubeTrackDownloadsWholeAndReadsBackWithItsTags() throws {
        throw XCTSkip("DownloadsTests needs StreamResolution as a test dependency (Package.swift extraTestDependencies)")
    }
}
#endif
