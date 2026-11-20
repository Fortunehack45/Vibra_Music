import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import Downloads

// Shared helpers for the Downloads tests: real audio files made on the spot, images, fake
// resolvers and a queue wired to URLProtocolStub.

enum TestAudio {
    /// A real AAC `.m4a` of `seconds` of a 440 Hz tone, written by AVAudioFile (so it carries the
    /// `udta` AVFoundation writes, which the tagger has to merge with).
    static func m4a(seconds: Double = 2, at url: URL) throws -> URL {
        try write(url, seconds: seconds, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ])
    }

    /// A real FLAC, written by Core Audio's encoder.
    static func flac(seconds: Double = 2, at url: URL) throws -> URL {
        try write(url, seconds: seconds, settings: [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
        ])
    }

    /// A 16-bit PCM WAV.
    static func wav(seconds: Double = 2, at url: URL) throws -> URL {
        try write(url, seconds: seconds, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
    }

    private static func write(_ url: URL, seconds: Double, settings: [String: Any]) throws -> URL {
        try? FileManager.default.removeItem(at: url)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            let samples = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) { samples[i] = sin(Float(i) * 2 * .pi * 440 / 44_100) * 0.3 }
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        return url
    }

    /// Cuts `source` into Apple's own HLS fMP4 segments (an initialisation segment and roughly
    /// one-second media segments) — the same shape a DASH or HLS source serves.
    static func fmp4Segments(from source: URL) async throws -> (initialization: Data, media: [Data], durations: [Double]) {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw DownloadError("no audio track") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(output)

        let collector = SegmentCollector()
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: 1, preferredTimescale: 1)
        writer.initialSegmentStartTime = .zero
        writer.delegate = collector
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else {
            throw writer.error ?? reader.error ?? DownloadError("could not start segmenting")
        }
        writer.startSession(atSourceTime: .zero)
        while let sample = output.copyNextSampleBuffer() {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            input.append(sample)
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
        return collector.result()
    }

    private final class SegmentCollector: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var initialization = Data()
        private var media: [Data] = []
        private var durations: [Double] = []

        func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
            lock.withLock {
                switch segmentType {
                case .initialization:
                    initialization = segmentData
                case .separable:
                    media.append(segmentData)
                    let duration = segmentReport?.trackReports.first?.duration.seconds ?? 1
                    durations.append(duration)
                @unknown default:
                    break
                }
            }
        }

        func result() -> (initialization: Data, media: [Data], durations: [Double]) {
            lock.withLock { (initialization, media, durations) }
        }
    }
}

enum TestImages {
    /// A `width`×`height` image of one colour, encoded as `type` (`UTType.png` / `.jpeg`).
    static func image(width: Int, height: Int, type: UTType = .png) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return out as Data
    }

    static func size(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: width, height: height)
    }
}

/// A `StreamResolving` that answers from a closure and records what it was asked.
final class FakeResolver: StreamResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: @Sendable (Song, StreamRequest) throws -> ResolvedStream
    private var asked: [(Song, StreamRequest)] = []

    init(_ handler: @escaping @Sendable (Song, StreamRequest) throws -> ResolvedStream) {
        self.handler = handler
    }

    func answer(_ handler: @escaping @Sendable (Song, StreamRequest) throws -> ResolvedStream) {
        lock.withLock { self.handler = handler }
    }

    var requests: [StreamRequest] { lock.withLock { asked.map(\.1) } }
    var songs: [Song] { lock.withLock { asked.map(\.0) } }

    func resolveStream(for song: Song, request: StreamRequest) async throws -> ResolvedStream {
        let handler = lock.withLock {
            asked.append((song, request))
            return self.handler
        }
        return try handler(song, request)
    }
}

/// A queue wired to URLProtocolStub, a fake network and a temporary folder.
@MainActor
final class DownloadHarness {
    let stub = URLProtocolStub()
    let root: URL
    let defaults: EphemeralDefaults
    let settings: AppSettings
    let network: FakeNetworkMonitor
    let resolver: FakeResolver
    private(set) var transport: URLSessionDownloadTransport
    private(set) var library: DownloadLibrary
    private(set) var manager: DownloadManager
    var lyricsProvider: DownloadLyricsProvider?
    private let configuration: DownloadManager.Configuration

    init(root: URL, network: NetworkStatus = .wifi, chunkBytes: Int64 = 2 * 1024 * 1024, workers: Int = 4,
         lyricsTimeout: Double = 30, lyrics: DownloadLyricsProvider? = nil,
         resolver: FakeResolver = FakeResolver { _, _ in throw DownloadError("No downloadable audio for this track") }) {
        self.root = root
        defaults = EphemeralDefaults()
        settings = AppSettings(defaults: defaults.defaults, credentials: InMemoryCredentialStore())
        self.network = FakeNetworkMonitor(network)
        self.resolver = resolver
        lyricsProvider = lyrics
        configuration = .init(workers: workers, chunkBytes: chunkBytes, retryDelays: [0.01, 0.02], lyricsTimeout: lyricsTimeout)
        let store = DownloadStore(root: root)
        transport = URLSessionDownloadTransport(configuration: stub.makeConfiguration(), stagingDirectory: store.stagingDirectory)
        library = DownloadLibrary(store: store)
        manager = DownloadManager(settings: settings, resolver: resolver, network: self.network, transport: transport,
                                  library: library, http: stub.makeSession(), lyricsProvider: lyrics, configuration: configuration)
    }

    /// The process dies: the manager stops dead, nothing is cleaned up, and transfers already handed
    /// to the session carry on.
    func terminate() {
        manager.simulateTermination()
    }

    /// A new process: a new session object and a new manager over the same folder.
    func launch() {
        let store = DownloadStore(root: root)
        transport = URLSessionDownloadTransport(configuration: stub.makeConfiguration(), stagingDirectory: store.stagingDirectory)
        library = DownloadLibrary(store: store)
        manager = DownloadManager(settings: settings, resolver: resolver, network: network, transport: transport,
                                  library: library, http: stub.makeSession(), lyricsProvider: lyricsProvider, configuration: configuration)
    }

    /// Serve `artwork` for any lh3 cover URL.
    func serveArtwork(_ artwork: Data = TestImages.image(width: 64, height: 64, type: .jpeg)) {
        stub.register(host: "lh3.googleusercontent.com") { _ in .data(artwork, headers: ["Content-Type": "image/jpeg"]) }
    }

    /// Resolve every track to googlevideo and serve `body` in ranges.
    func serveYouTube(_ body: Data, client: String = "ANDROID_VR") {
        resolver.answer { song, _ in
            ResolvedStream(url: googleVideoURL(song.videoId, length: body.count, client: client), origin: .youtube,
                           mimeType: "audio/mp4; codecs=\"mp4a.40.2\"", format: StreamFormat(codec: "aac", kbps: 130),
                           headers: ["User-Agent": "com.google.android.apps.youtube.vr.oculus/1.65.10"])
        }
        stub.register(host: "rr1---sn-test.googlevideo.com", rangeResponder(body))
    }

    var partFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: library.store.tracksDirectory.path(percentEncoded: false))) ?? [])
            .filter { $0.hasSuffix(".part") }
    }
}

func song(_ id: String, title: String? = nil, artist: String = "Artist", album: String? = nil, thumbnail: String? = nil) -> Song {
    Song(videoId: id, title: title ?? id, artist: artist, thumbnailUrl: thumbnail, albumName: album)
}

extension XCTestCase {
    /// Polls `condition` on the main actor until it holds or `timeout` passes.
    @MainActor
    func waitUntil(_ description: String = "condition", timeout: TimeInterval = 10, _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for \(description)")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

extension Data {
    func range(of needle: String, encoding: String.Encoding = .utf8) -> Range<Data.Index>? {
        guard let bytes = needle.data(using: encoding) else { return nil }
        return range(of: bytes)
    }
}

/// A googlevideo-shaped URL for `id`, carrying `clen` and the client name like the real ones.
func googleVideoURL(_ id: String, length: Int, client: String = "ANDROID_VR") -> URL {
    URL(string: "https://rr1---sn-test.googlevideo.com/videoplayback?id=\(id)&itag=140&mime=audio%2Fmp4&clen=\(length)&c=\(client)")!
}

/// Answers `Range: bytes=a-b` requests for `body` with 206 slices, like googlevideo.
func rangeResponder(_ body: Data) -> URLProtocolStub.Responder {
    { request in
        guard let header = request.value(forHTTPHeaderField: "Range"),
              let match = header.firstMatch(of: #/bytes=(\d+)-(\d+)/#),
              let start = Int(match.1), let end = Int(match.2) else {
            return .data(body, headers: ["Content-Length": "\(body.count)"])
        }
        let upper = Swift.min(end, body.count - 1)
        guard start <= upper else { return .status(416) }
        let slice = body.subdata(in: start..<(upper + 1))
        return .data(slice, status: 206, headers: [
            "Content-Range": "bytes \(start)-\(upper)/\(body.count)",
            "Content-Length": "\(slice.count)",
            "Content-Type": "audio/mp4",
        ])
    }
}

/// Holds a stub responder (which runs on URLProtocol's thread) until the test lets it go.
final class Gate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var opened = false

    /// Blocks the calling (stub) thread until ``open()``, or `timeout` seconds.
    func wait(timeout: Double = 10) {
        if lock.withLock({ opened }) { return }
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    func open() {
        let first = lock.withLock { () -> Bool in
            defer { opened = true }
            return !opened
        }
        // Enough signals for every thread that may be parked here.
        if first { for _ in 0..<16 { semaphore.signal() } }
    }
}

extension TestAudio {
    /// A file shaped like YouTube's itag 140: an fMP4 init segment whose `moov` *declares* the whole
    /// duration in `mvhd`/`tkhd`/`mdhd` (as googlevideo's does), followed by bare `moof`/`mdat`
    /// fragments.
    static func youtubeShaped(seconds: Double, in directory: URL) async throws -> Data {
        let source = try m4a(seconds: seconds, at: directory.appending(path: "yt-source-\(UUID().uuidString).m4a"))
        let segments = try await fmp4Segments(from: source)
        var file = declaringDurations(segments.initialization, seconds: seconds)
        for segment in segments.media {
            file.append(try Downloader.flatten(segment, isInitialization: false))
        }
        return file
    }

    /// `initialization` with its `mvhd`, `tkhd` and `mdhd` durations set to `seconds`.
    static func declaringDurations(_ initialization: Data, seconds: Double) -> Data {
        var bytes = [UInt8](initialization)
        guard let moov = Mp4Tagger.parseBoxes(bytes, 0, bytes.count).first(where: { $0.type == "moov" }) else { return initialization }
        func field(_ box: Mp4Tagger.BoxRef, v0: Int, v1: Int) -> (at: Int, wide: Bool) {
            let wide = bytes[box.contentOffset] == 1
            return (box.contentOffset + (wide ? v1 : v0), wide)
        }
        func put(_ value: UInt64, _ at: (at: Int, wide: Bool)) {
            if at.wide { writeU64(&bytes, at.at, value) } else { writeU32(&bytes, at.at, UInt32(value)) }
        }
        let children = Mp4Tagger.parseBoxes(bytes, moov.contentOffset, moov.end)
        var movieScale: UInt64 = 1000
        if let mvhd = children.first(where: { $0.type == "mvhd" }) {
            let scale = field(mvhd, v0: 12, v1: 20)
            movieScale = UInt64(readU32(bytes, scale.at))
            put(UInt64(seconds * Double(movieScale)), field(mvhd, v0: 16, v1: 24))
        }
        for trak in children where trak.type == "trak" {
            for child in Mp4Tagger.parseBoxes(bytes, trak.contentOffset, trak.end) {
                if child.type == "tkhd" { put(UInt64(seconds * Double(movieScale)), field(child, v0: 20, v1: 28)) }
                if child.type == "mdia", let mdhd = Mp4Tagger.parseBoxes(bytes, child.contentOffset, child.end).first(where: { $0.type == "mdhd" }) {
                    let scale = UInt64(readU32(bytes, field(mdhd, v0: 12, v1: 20).at))
                    put(UInt64(seconds * Double(scale)), field(mdhd, v0: 16, v1: 24))
                }
            }
        }
        return Data(bytes)
    }
}
