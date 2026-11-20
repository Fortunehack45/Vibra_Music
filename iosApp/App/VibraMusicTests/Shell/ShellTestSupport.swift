import AudioCache
import AVFoundation
import VibraMusicCore
import Foundation
import Playback
import PlaybackPolicy
import PlaybackQueue
import XCTest
@testable import Vibra Music

// Fakes and fixtures for the app-shell tests. The package's VibraMusicTestSupport isn't linked into
// the app's test bundle, so the few helpers these tests need live here.

/// Settings on a throwaway defaults suite with credentials in memory.
@MainActor
func makeTestSettings() -> AppSettings {
    let suite = "vibramusic.shell.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let settings = AppSettings(defaults: defaults, credentials: InMemoryCredentialStore())
    // Deterministic transport: no crossfade, no silence skipping, no normalization gain unless a
    // test asks for it.
    settings.crossfadeSeconds = 0
    settings.skipSilence = false
    settings.autoplay = false
    return settings
}

/// A fresh directory under the temporary directory, removed when the test ends.
func makeTemporaryDirectory(_ test: XCTestCase) -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "shell-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
}

/// Audio files the engine can really play: a quiet sine, as 16-bit PCM WAV (lossless) or AAC in
/// M4A (lossy).
enum TestAudio {
    enum Format {
        case wav
        case m4a
    }

    static func tone(seconds: Double, format: Format = .m4a, in directory: URL, name: String = UUID().uuidString) throws -> URL {
        let sampleRate = 44_100.0
        let url = directory.appending(path: "\(name).\(format == .wav ? "wav" : "m4a")")
        let settings: [String: Any]
        switch format {
        case .wav:
            settings = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ]
        case .m4a:
            settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000]
        }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(file.processingFormat.channelCount) {
            let samples = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) {
                samples[frame] = 0.1 * sin(2 * .pi * 440 * Float(frame) / Float(sampleRate))
            }
        }
        try file.write(from: buffer)
        return url
    }
}

extension TestAudio {
    /// A 440 Hz tone whose loudness jumps between levels every fraction of a second in a fixed
    /// pseudo-random pattern, after `leadingSilence` seconds of silence: two of these that differ
    /// only in the lead line up at exactly that offset, which is what the version aligner measures.
    static func pattern(seconds: Double, leadingSilence: Double = 0, in directory: URL, name: String) throws -> URL {
        let sampleRate = 22_050.0
        let url = directory.appending(path: "\(name).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let lead = Int(leadingSilence * sampleRate)
        let body = Int(seconds * sampleRate)
        let frames = AVAudioFrameCount(lead + body)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        var level: Float = 0
        var segmentLeft = 0
        for frame in 0..<Int(frames) {
            guard frame >= lead else { samples[frame] = 0; continue }
            if segmentLeft == 0 {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                level = Float((seed >> 33) % 100) / 100 * 0.5
                segmentLeft = Int(sampleRate * (0.08 + Double((seed >> 20) % 40) / 100))
            }
            segmentLeft -= 1
            samples[frame] = level * sin(2 * .pi * 440 * Float(frame - lead) / Float(sampleRate))
        }
        try file.write(from: buffer)
        return url
    }
}

/// A resolver that serves local files as streams and records what it was asked.
final class FakeStreamResolver: StreamResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: URL] = [:]
    private var formats: [String: StreamFormat] = [:]
    private var origins: [String: StreamOrigin] = [:]
    private var belowRequest: Set<String> = []
    private var delays: [String: Duration] = [:]
    private var log: [(videoId: String, request: StreamRequest)] = []

    func serve(_ videoId: String, from url: URL, format: StreamFormat = StreamFormat(codec: "aac", kbps: 128),
               origin: StreamOrigin = .addon) {
        lock.withLock {
            files[videoId] = url
            formats[videoId] = format
            origins[videoId] = origin
        }
    }

    /// Answers `videoId` the way SourceResolver answers when YouTube won the race while a ranked
    /// source was still looking: flagged below the request.
    func markBelowRequest(_ videoId: String) {
        _ = lock.withLock { belowRequest.insert(videoId) }
    }

    /// Makes a later resolve of `videoId` wait, so a test can reach a track before its stream does.
    func delay(_ videoId: String, by delay: Duration) {
        lock.withLock { delays[videoId] = delay }
    }

    private var gates: [String: ResolveGate] = [:]

    /// Holds every resolve of `videoId` open until ``ResolveGate/open()``, so a test can act while
    /// a read-ahead is genuinely in flight rather than racing a fixed delay.
    func gate(_ videoId: String) -> ResolveGate {
        lock.withLock {
            let gate = ResolveGate()
            gates[videoId] = gate
            return gate
        }
    }

    var requests: [(videoId: String, request: StreamRequest)] { lock.withLock { log } }
    var requestedIds: [String] { requests.map(\.videoId) }

    func resolveStream(for song: Song, request: StreamRequest) async throws -> ResolvedStream {
        let (url, format, origin, below, wait, gate): (URL?, StreamFormat?, StreamOrigin, Bool, Duration, ResolveGate?) = lock.withLock {
            log.append((song.videoId, request))
            return (files[song.videoId], formats[song.videoId], origins[song.videoId] ?? .addon, belowRequest.contains(song.videoId), delays[song.videoId] ?? .zero, gates[song.videoId])
        }
        await gate?.awaitOpen()
        if wait > .zero { try await Task.sleep(for: wait) }
        guard let url else { throw URLError(.fileDoesNotExist) }
        return ResolvedStream(url: url, origin: below ? .youtube : origin, mimeType: url.pathExtension == "wav" ? "audio/wav" : "audio/mp4",
                              format: format ?? StreamFormat(), loudnessDb: nil, belowRequest: below)
    }
}

/// Lets a test hold a resolve open until it chooses to release it.
final class ResolveGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    /// Releases every held resolve.
    func open() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            released = true
            defer { openWaiters = [] }
            return openWaiters
        }
        waiters.forEach { $0.resume() }
    }

    fileprivate func awaitOpen() async {
        await withCheckedContinuation { continuation in
            // Append while holding the lock: checking and appending separately can miss an
            // `open()` that drains the waiters in between, leaving this resolve suspended forever.
            let alreadyOpen: Bool = lock.withLock {
                if released { return true }
                openWaiters.append(continuation)
                return false
            }
            if alreadyOpen { continuation.resume() }
        }
    }
}

/// AutoPlay's related songs, canned.
final class FakeRadioSource: AutoplayRadioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var related: [Song]
    private var seeds: [String] = []

    init(related: [Song]) {
        self.related = related
    }

    var requestedSeeds: [String] { lock.withLock { seeds } }

    func radio(seedVideoId: String) async throws -> [Song] {
        lock.withLock {
            seeds.append(seedVideoId)
            return related
        }
    }
}

/// Stands in for MPRemoteCommandCenter: the test fires commands the way the lock screen would.
@MainActor
final class FakeRemoteCommandCenter: RemoteCommandRegistering {
    private var handler: ((RemoteCommand) -> RemoteCommandResult)?
    private(set) var feedback: (liked: Bool, disliked: Bool) = (false, false)

    func activate(handler: @escaping @MainActor (RemoteCommand) -> RemoteCommandResult) { self.handler = handler }
    func deactivate() { handler = nil }
    func updateFeedback(isLiked: Bool, isDisliked: Bool) { feedback = (isLiked, isDisliked) }

    @discardableResult
    func fire(_ command: RemoteCommand) -> RemoteCommandResult {
        handler?(command) ?? .noActionableNowPlayingItem
    }
}

/// A PlayerController over a real engine (no system integration) and a fake resolver.
@MainActor
struct PlayerHarness {
    let player: PlayerController
    let engine: AudioPlayerEngine
    let queue: PlaybackQueueController
    let resolver: FakeStreamResolver
    let settings: AppSettings
    let remote: FakeRemoteCommandCenter
    let processors: [AudioDSPProcessor]
    let factory: PlaybackSourceFactory
    /// The audio cache the factory serves from, when a test wants a fully cached track.
    let cache: AudioStreamCache?
    let directory: URL

    init(
        test: XCTestCase,
        settings: AppSettings? = nil,
        lastPlayed: LastPlayedStore? = nil,
        radio: AutoplayRadioSource? = nil,
        partyStash: PartyPersonalQueueStash? = nil,
        cache: AudioStreamCache? = nil,
        session: URLSession = VibraMusicHTTP.session,
        canSubstitute: @escaping @Sendable (StreamRequest) -> Bool = { _ in true },
        request: @escaping @Sendable () -> StreamRequest = { .playback(.lossless) },
        streams: (any StreamResolving)? = nil,
        youTube: (any StreamResolving)? = nil,
        facts: StreamFactsBook = StreamFactsBook()
    ) {
        let settings = settings ?? makeTestSettings()
        let processors = [AudioDSPProcessor(facts: facts), AudioDSPProcessor(facts: facts)]
        let remote = FakeRemoteCommandCenter()
        let engine = AudioPlayerEngine(configuration: AudioPlayerEngine.Configuration(
            audioProcessorFactory: { deck in processors[deck == .a ? 0 : 1] },
            integratesWithSystem: false,
            remoteCommandCenter: remote,
            scansAheadForSilence: false,
            positionUpdateInterval: 0.05,
            sampleInterval: 0.5
        ))
        let queue = PlaybackQueueController(settings: settings, lastPlayed: lastPlayed, partyStash: partyStash, radioSource: radio, sleepTimer: SleepTimer())
        let resolver = FakeStreamResolver()
        // `streams` stands in for the app's SourceResolver; the fake resolver otherwise.
        let factory = PlaybackSourceFactory(resolver: streams ?? resolver, youTube: youTube, cache: cache, facts: facts, session: session, request: request,
                                            atmosAllowed: { true })
        factory.isPinnedToOriginal = { _ in false }
        // Refusals of this test's own, never another's.
        factory.streamChoice = StreamChoice()
        factory.canSubstitute = canSubstitute
        self.player = PlayerController(engine: engine, queue: queue, settings: settings, sources: factory, likeState: LikeState(), processors: processors)
        self.engine = engine
        self.queue = queue
        self.resolver = resolver
        self.settings = settings
        self.remote = remote
        self.processors = processors
        self.factory = factory
        self.cache = cache
        self.directory = makeTemporaryDirectory(test)
        let engineToStop = engine
        test.addTeardownBlock { @MainActor in engineToStop.shutdown() }
    }

    /// A song whose stream is a `seconds`-long local tone.
    func song(_ id: String, seconds: Double = 8, format: TestAudio.Format = .m4a, streamFormat: StreamFormat? = nil,
              origin: StreamOrigin = .addon) throws -> Song {
        let url = try TestAudio.tone(seconds: seconds, format: format, in: directory, name: id)
        resolver.serve(id, from: url, format: streamFormat ?? (format == .wav ? StreamFormat(codec: "wav") : StreamFormat(codec: "aac", kbps: 128)),
                       origin: origin)
        return Song(videoId: id, title: "Title \(id)", artist: "Artist \(id)", durationText: DurationText.format(seconds: Int(seconds)))
    }
}

extension XCTestCase {
    /// Waits on the main actor until `condition` holds.
    @MainActor
    func waitUntil(_ description: String, timeout: TimeInterval = 10, _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for: \(description)")
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// A cache in its own directory, with no free-space floor so a test can fill an entry regardless of
/// the machine's disk. The production read-ahead delay is kept by default; read-ahead tests pass
/// `.zero` so the next track's bytes land as soon as the queue wires them.
func makeTestCache(in directory: URL, prefetchDelay: Duration = .seconds(8)) throws -> AudioStreamCache {
    try AudioStreamCache(configuration: .init(
        directory: directory.appending(path: "cache", directoryHint: .isDirectory),
        minimumFreeBytes: 0,
        prefetchDelay: prefetchDelay,
        availableCapacity: { _ in nil }
    ))
}

extension AudioStreamCache {
    /// A YouTube track's bytes written to disk in full, so the next open serves it from the cache
    /// without resolving — the path the cached-track quality upgrade exists for.
    @discardableResult
    func fillFullyCachedYouTube(_ videoId: String, from file: URL, mimeType: String = "audio/mp4") async -> Bool {
        await cacheCompletely(.youtube(videoId: videoId),
                              source: InMemoryAudioSource(data: (try? Data(contentsOf: file)) ?? Data(), mimeType: mimeType))
    }
}
