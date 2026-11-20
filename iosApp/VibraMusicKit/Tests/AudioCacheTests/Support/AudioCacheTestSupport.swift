import AVFoundation
import Foundation
import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import AudioCache

/// Serves byte buffers with HTTP range semantics through a `URLProtocolStub`, and can go offline,
/// refuse URLs, truncate responses or ignore ranges on demand.
final class RangeServer: @unchecked Sendable {
    struct Hosted {
        var data: Data
        var mimeType: String?
    }

    let stub = URLProtocolStub()
    private(set) lazy var session: URLSession = stub.makeSession()

    private let lock = NSLock()
    private var hosted: [String: Hosted] = [:]
    private var refused: [String: Int] = [:]
    private var _offline = false
    private var _maxBytesPerResponse: Int?
    private var _emptyBodies = false
    private var _ignoreRanges = false

    init() {
        stub.register(matching: { _ in true }) { [weak self] request in
            guard let self else { throw URLError(.cancelled) }
            return try self.respond(to: request)
        }
    }

    func host(_ data: Data, at url: URL, mimeType: String? = "audio/mp4") {
        lock.withLock { hosted[url.absoluteString] = Hosted(data: data, mimeType: mimeType) }
    }

    func refuse(_ url: URL, status: Int = 403) {
        lock.withLock { refused[url.absoluteString] = status }
    }

    var offline: Bool {
        get { lock.withLock { _offline } }
        set { lock.withLock { _offline = newValue } }
    }

    /// Answers every range with at most this many bytes (a server that cuts ranges short).
    var maxBytesPerResponse: Int? {
        get { lock.withLock { _maxBytesPerResponse } }
        set { lock.withLock { _maxBytesPerResponse = newValue } }
    }

    /// Answers 206 with no body at all.
    var emptyBodies: Bool {
        get { lock.withLock { _emptyBodies } }
        set { lock.withLock { _emptyBodies = newValue } }
    }

    /// Answers 200 with the whole file, whatever the Range header says.
    var ignoreRanges: Bool {
        get { lock.withLock { _ignoreRanges } }
        set { lock.withLock { _ignoreRanges = newValue } }
    }

    /// Every request made, in order.
    var requests: [URLRequest] { stub.requests }

    /// The ranges asked of `url` (or of every URL), in order. An open-ended ask ends at `Int64.max`.
    func ranges(for url: URL? = nil) -> [Range<Int64>] {
        requests
            .filter { url == nil || $0.url?.absoluteString == url?.absoluteString }
            .compactMap { $0.value(forHTTPHeaderField: "Range").flatMap(Self.parseRange) }
    }

    /// Total bytes asked for across requests to `url`.
    func requestedBytes(for url: URL? = nil, total: Int64) -> Int64 {
        ranges(for: url).reduce(0) { $0 + (min($1.upperBound, total) - $1.lowerBound) }
    }

    static func parseRange(_ header: String) -> Range<Int64>? {
        guard header.hasPrefix("bytes=") else { return nil }
        let parts = header.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int64(parts[0]) else { return nil }
        if parts[1].isEmpty { return start..<Int64.max }
        guard let end = Int64(parts[1]) else { return nil }
        return start..<(end + 1)
    }

    private func respond(to request: URLRequest) throws -> URLProtocolStub.Response {
        let state = lock.withLock { (_offline, refused, hosted, _maxBytesPerResponse, _emptyBodies, _ignoreRanges) }
        let (offline, refused, hosted, maxBytes, empty, ignoreRanges) = state
        if offline { throw URLError(.notConnectedToInternet) }
        guard let url = request.url else { throw URLError(.badURL) }
        if let status = refused[url.absoluteString] { return .status(status) }
        guard let file = hosted[url.absoluteString] else { return .status(404) }
        var headers: [String: String] = ["Accept-Ranges": "bytes"]
        if let mime = file.mimeType { headers["Content-Type"] = mime }
        let total = Int64(file.data.count)
        guard !ignoreRanges, let range = request.value(forHTTPHeaderField: "Range").flatMap(Self.parseRange) else {
            headers["Content-Length"] = String(total)
            return .data(file.data, status: 200, headers: headers)
        }
        guard range.lowerBound < total else {
            headers["Content-Range"] = "bytes */\(total)"
            return .data(Data(), status: 416, headers: headers)
        }
        var end = min(range.upperBound, total)
        if let maxBytes { end = min(end, range.lowerBound + Int64(maxBytes)) }
        let body = empty ? Data() : file.data.subdata(in: Int(range.lowerBound)..<Int(end))
        headers["Content-Range"] = "bytes \(range.lowerBound)-\(max(range.lowerBound, end - 1))/\(total)"
        headers["Content-Length"] = String(body.count)
        return .data(body, status: 206, headers: headers)
    }
}

/// A googlevideo-shaped URL: host, `c`, `clen`, and an `expire` an hour out unless given.
func googlevideoURL(client: String = "ANDROID_VR", length: Int, itag: Int = 140, id: String = "a", expire: Date = Date().addingTimeInterval(3_600)) -> URL {
    URL(string: "https://rr1---sn-test.googlevideo.com/videoplayback?id=\(id)&itag=\(itag)&c=\(client)&cver=1.65.10&clen=\(length)&expire=\(Int(expire.timeIntervalSince1970))")!
}

/// Deterministic bytes that differ at every offset a test is likely to compare.
func patternData(count: Int, seed: UInt8 = 0) -> Data {
    var data = Data(count: count)
    data.withUnsafeMutableBytes { raw in
        let bytes = raw.bindMemory(to: UInt8.self)
        for index in 0..<count {
            bytes[index] = UInt8(truncatingIfNeeded: index &* 31 &+ (index >> 8) &+ Int(seed))
        }
    }
    return data
}

func stream(_ url: URL, length: Int?, mimeType: String? = "audio/mp4", headers: [String: String] = [:]) -> ResolvedStream {
    ResolvedStream(url: url, origin: .youtube, mimeType: mimeType, headers: headers, contentLength: length.map(Int64.init), expiresAt: ResolvedStream.expiry(in: url))
}

/// A byte source counting what it's asked, for tests that don't need HTTP.
final class MemoryAudioSource: AudioRangeDataSource, @unchecked Sendable {
    let data: Data
    let mimeType: String?
    let rangeBytes: Int64
    private let lock = NSLock()
    private var _reads: [Range<Int64>] = []
    private var _infoCalls = 0
    private var _failing = false

    init(_ data: Data, mimeType: String? = "audio/mp4", rangeBytes: Int64 = 1_024 * 1_024) {
        self.data = data
        self.mimeType = mimeType
        self.rangeBytes = rangeBytes
    }

    var reads: [Range<Int64>] { lock.withLock { _reads } }
    var infoCalls: Int { lock.withLock { _infoCalls } }
    var failing: Bool {
        get { lock.withLock { _failing } }
        set { lock.withLock { _failing = newValue } }
    }

    func contentInfo() async throws -> AudioContentInfo {
        try lock.withLock {
            _infoCalls += 1
            if _failing { throw URLError(.notConnectedToInternet) }
        }
        return AudioContentInfo(contentLength: Int64(data.count), mimeType: mimeType)
    }

    func read(_ range: Range<Int64>) async throws -> Data {
        try lock.withLock {
            _reads.append(range)
            if _failing { throw URLError(.notConnectedToInternet) }
        }
        let end = min(range.upperBound, Int64(data.count))
        guard range.lowerBound < end else { return Data() }
        return data.subdata(in: Int(range.lowerBound)..<Int(end))
    }

    var maxRangeBytes: Int64 { rangeBytes }
}

/// A clock tests move by hand, so last-used order is deterministic.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval = 1) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

extension XCTestCase {
    func makeCache(
        directory: URL? = nil,
        limit: Int64 = 256 * 1_024 * 1_024,
        minimumFree: Int64 = 0,
        capacity: (@Sendable (URL) -> Int64?)? = nil,
        headBytes: Int64 = 4 * 1_024 * 1_024,
        headBudget: Int64 = 96 * 1_024 * 1_024,
        clock: TestClock? = nil,
        prefetchDelay: Duration = .zero
    ) throws -> AudioStreamCache {
        let dir = try directory ?? makeTemporaryDirectory()
        return try AudioStreamCache(configuration: .init(
            directory: dir,
            limitBytes: limit,
            minimumFreeBytes: minimumFree,
            headBytes: headBytes,
            headBudgetBytes: headBudget,
            prefetchDelay: prefetchDelay,
            retryDelay: .milliseconds(20),
            queueWarmUpStagger: .milliseconds(1),
            networkRetryDelays: [.milliseconds(50), .milliseconds(100), .milliseconds(200)],
            availableCapacity: capacity ?? { _ in nil },
            clock: clock.map { clock in { clock.now } } ?? { Date() }
        ))
    }

    /// Polls `condition` until it holds or `timeout` passes.
    func eventually(timeout: TimeInterval = 5, _ message: String = "condition never held", file: StaticString = #filePath, line: UInt = #line, _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message, file: file, line: line)
    }

    /// Reads `range` of `key` the way the resource loader does: disk first, then the source.
    /// With `knownInfo` it skips the content-information step, as the loader does after its first
    /// answer.
    func readThroughCache(_ cache: AudioStreamCache, key: AudioCacheKey, source: (any AudioRangeDataSource)?, range: Range<Int64>, knownInfo: AudioContentInfo? = nil) async throws -> Data {
        let info: AudioContentInfo
        if let knownInfo {
            info = knownInfo
        } else {
            info = try await cache.store.contentInfo(for: key, source: source)
        }
        var data = Data()
        var position = range.lowerBound
        let end = min(range.upperBound, info.contentLength)
        while position < end {
            try Task.checkCancellation()
            if let piece = await cache.store.read(key, at: position, maxLength: end - position) {
                data.append(piece)
                position += Int64(piece.count)
                continue
            }
            let subscription = try await cache.store.subscribe(key, at: position, wantEnd: end, source: source, info: info)
            do {
                for try await piece in subscription.stream {
                    let take = min(Int64(piece.count), end - position)
                    data.append(piece.prefix(Int(take)))
                    position += take
                    if position >= end { break }
                }
            } catch {
                await cache.store.release(subscription, cancelled: Task.isCancelled)
                throw error
            }
            await cache.store.release(subscription, cancelled: Task.isCancelled)
        }
        return data
    }
}

/// Writes a real audio file with a sine tone. `.m4a` is AAC; `.flac` is FLAC.
func writeTone(to url: URL, seconds: Double, sampleRate: Double = 44_100) throws {
    let settings: [String: Any]
    switch url.pathExtension {
    case "flac":
        settings = [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16]
    default:
        settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000]
    }
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let total = AVAudioFrameCount(seconds * sampleRate)
    let chunk: AVAudioFrameCount = 4_096
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { throw URLError(.cannotCreateFile) }
    var written: AVAudioFrameCount = 0
    while written < total {
        let count = min(chunk, total - written)
        buffer.frameLength = count
        for channel in 0..<Int(file.processingFormat.channelCount) {
            let samples = buffer.floatChannelData![channel]
            for index in 0..<Int(count) {
                samples[index] = Float(sin(2 * Double.pi * 440 * Double(Int(written) + index) / sampleRate)) * 0.3
            }
        }
        try file.write(from: buffer)
        written += count
    }
}

/// Decodes every audio sample of `asset`, off the cooperative pool (AVAssetReader blocks).
func decodeAllFrames(of asset: AVAsset) async throws -> Int {
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw URLError(.cannotDecodeContentData) }
    return try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            do {
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
                reader.add(output)
                guard reader.startReading() else { throw reader.error ?? URLError(.cannotDecodeContentData) }
                var frames = 0
                while let sample = output.copyNextSampleBuffer() {
                    frames += CMSampleBufferGetNumSamples(sample)
                }
                guard reader.status == .completed else { throw reader.error ?? URLError(.cannotDecodeContentData) }
                continuation.resume(returning: frames)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

extension XCTestCase {
    /// `cache.cacheCompletely(key, source:)`, failing the test when it doesn't get every byte.
    /// (XCTAssert's autoclosures can't `await`.)
    func assertCachesCompletely(_ cache: AudioStreamCache, _ key: AudioCacheKey, source: any AudioRangeDataSource, file: StaticString = #filePath, line: UInt = #line) async {
        let cached = await cache.cacheCompletely(key, source: source)
        XCTAssertTrue(cached, "\(key) was not cached completely", file: file, line: line)
    }
}
