import AudioDSP
import AVFoundation
import VibraMusicCore
import VibraMusicTestSupport
import XCTest
@testable import Playback

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
@discardableResult
func waitUntil(
    _ description: String = "condition",
    timeout: TimeInterval = 8,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    if condition() { return true }
    XCTFail("Timed out after \(timeout)s waiting for \(description)", file: file, line: line)
    return false
}

@MainActor
func pause(for seconds: TimeInterval) async {
    try? await Task.sleep(for: .seconds(seconds))
}

extension PlayableItem {
    static func file(_ url: URL, id: String? = nil, title: String? = nil, loudnessDb: Double? = nil) -> PlayableItem {
        PlayableItem(
            id: id ?? url.deletingPathExtension().lastPathComponent,
            title: title ?? url.deletingPathExtension().lastPathComponent,
            artist: "Test Artist",
            album: "Test Album",
            source: .file(url),
            loudnessDb: loudnessDb
        )
    }
}

/// Plays the queue it is given, in order, and records everything the engine says.
@MainActor
final class RecordingDelegate: AudioPlayerEngineDelegate {
    var queue: [PlayableItem]
    var repeatOne = false
    var changes: [(item: PlayableItem, reason: ItemChangeReason)] = []
    var finished: [PlayableItem] = []
    var failures: [(error: PlaybackError, willRetry: Bool)] = []
    var commands: [RemoteCommand] = []
    var commandResult: RemoteCommandResult?
    var checkpoints: [PlaybackCheckpoint] = []

    init(queue: [PlayableItem] = []) {
        self.queue = queue
    }

    func audioPlayerEngine(_ engine: AudioPlayerEngine, itemAfter item: PlayableItem) -> PlayableItem? {
        if repeatOne { return item }
        guard let index = queue.firstIndex(where: { $0.id == item.id }), index + 1 < queue.count else { return nil }
        return queue[index + 1]
    }

    func audioPlayerEngine(_ engine: AudioPlayerEngine, didChangeItemTo item: PlayableItem, reason: ItemChangeReason) {
        changes.append((item, reason))
    }

    func audioPlayerEngine(_ engine: AudioPlayerEngine, didFinishQueueAfter item: PlayableItem) {
        finished.append(item)
    }

    func audioPlayerEngine(_ engine: AudioPlayerEngine, didFail error: PlaybackError, willRetry: Bool) {
        failures.append((error, willRetry))
    }

    func audioPlayerEngine(_ engine: AudioPlayerEngine, handle command: RemoteCommand) -> RemoteCommandResult {
        commands.append(command)
        return commandResult ?? engine.performDefault(command)
    }

    func audioPlayerEngine(_ engine: AudioPlayerEngine, checkpoint: PlaybackCheckpoint) {
        checkpoints.append(checkpoint)
    }
}

/// A processor that records what the tap hands it.
final class RecordingProcessor: PlaybackAudioProcessor, @unchecked Sendable {
    let deck: PlaybackDeckID
    private let lock = NSLock()
    private var _frames = 0
    private var _formats: [AudioTapFormat] = []
    private var _begun: [(id: String, loudnessDb: Double?)] = []
    private var _filters: [TransitionFilterCutoffs] = []
    private var _peak: Float = 0
    private var _positions: [Int64] = []
    /// Multiplies every sample, to prove the processor's output is what plays.
    var gain: Float = 1
    /// What ``altersSignal(for:loudnessDb:)`` answers.
    var alters = true
    private(set) var resetCount = 0

    init(deck: PlaybackDeckID) {
        self.deck = deck
    }

    var frames: Int { lock.withLock { _frames } }
    var formats: [AudioTapFormat] { lock.withLock { _formats } }
    var begunItems: [(id: String, loudnessDb: Double?)] { lock.withLock { _begun } }
    var filters: [TransitionFilterCutoffs] { lock.withLock { _filters } }
    var peak: Float { lock.withLock { _peak } }
    /// The source frame position of every buffer that reported one.
    var framePositions: [Int64] { lock.withLock { _positions } }

    func prepare(format: AudioTapFormat, maximumFrames: Int) {
        lock.withLock { _formats.append(format) }
    }

    func beginItem(_ item: PlayableItem, loudnessDb: Double?) {
        lock.withLock { _begun.append((item.id, loudnessDb)) }
    }

    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int, format: AudioTapFormat, timing: AudioTapTiming) {
        lock.withLock {
            if let position = timing.sourceFramePosition { _positions.append(position) }
        }
        var peak: Float = 0
        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            for index in 0..<count {
                data[index] *= gain
                peak = max(peak, abs(data[index]))
            }
        }
        lock.withLock {
            _frames += frameCount
            _peak = max(_peak, peak)
        }
    }

    func setTransitionFilter(_ cutoffs: TransitionFilterCutoffs) {
        lock.withLock { _filters.append(cutoffs) }
    }

    func altersSignal(for item: PlayableItem, loudnessDb: Double?) -> Bool { alters }

    /// What ``loudnessReadout(for:loudnessDb:)`` reports; nil means normalization is inactive.
    private var _readout: LoudnessReadout?
    var readout: LoudnessReadout? {
        get { lock.withLock { _readout } }
        set { lock.withLock { _readout = newValue } }
    }

    func loudnessReadout(for item: PlayableItem, loudnessDb: Double?) -> LoudnessReadout? { readout }

    func reset() {
        lock.withLock { resetCount += 1 }
    }
}

/// Records what the engine would show on the lock screen.
@MainActor
final class RecordingNowPlaying: NowPlayingPublishing {
    var info: [String: Any]?
    var publishCount = 0
    var lastState: (isPlaying: Bool, hasItem: Bool)?

    func publish(_ info: [String: Any]?) {
        self.info = info
        publishCount += 1
    }

    func publishPlaybackState(isPlaying: Bool, hasItem: Bool) {
        lastState = (isPlaying, hasItem)
    }
}

/// Stands in for `MPRemoteCommandCenter`: keeps the handler so tests can fire commands.
@MainActor
final class FakeRemoteCommandCenter: RemoteCommandRegistering {
    var handler: (@MainActor (RemoteCommand) -> RemoteCommandResult)?
    var isActive = false
    var feedback: (liked: Bool, disliked: Bool) = (false, false)

    func activate(handler: @escaping @MainActor (RemoteCommand) -> RemoteCommandResult) {
        self.handler = handler
        isActive = true
    }

    func deactivate() {
        handler = nil
        isActive = false
    }

    func updateFeedback(isLiked: Bool, isDisliked: Bool) {
        feedback = (isLiked, isDisliked)
    }

    @discardableResult
    func send(_ command: RemoteCommand) -> RemoteCommandResult {
        handler?(command) ?? .commandFailed
    }
}

/// Collects the processors the engine's factory makes.
@MainActor
final class ProcessorRegistry {
    var processors: [PlaybackDeckID: RecordingProcessor] = [:]
}

/// An engine with no system integration and fast sampling, plus the fakes it was built with.
@MainActor
struct EngineHarness {
    let engine: AudioPlayerEngine
    let delegate: RecordingDelegate
    let nowPlaying: RecordingNowPlaying
    let remote: FakeRemoteCommandCenter
    let processors: [PlaybackDeckID: RecordingProcessor]

    init(
        queue: [PlayableItem] = [],
        artworkSession: URLSession = .shared,
        scansAheadForSilence: Bool = true,
        withProcessors: Bool = true
    ) {
        let delegate = RecordingDelegate(queue: queue)
        let nowPlaying = RecordingNowPlaying()
        let remote = FakeRemoteCommandCenter()
        let made = ProcessorRegistry()
        var factory: PlaybackAudioProcessorFactory?
        if withProcessors {
            factory = { id in
                let processor = RecordingProcessor(deck: id)
                made.processors[id] = processor
                return processor
            }
        }
        let configuration = AudioPlayerEngine.Configuration(
            audioProcessorFactory: factory,
            integratesWithSystem: false,
            nowPlayingPublisher: nowPlaying,
            remoteCommandCenter: remote,
            artworkSession: artworkSession,
            scansAheadForSilence: scansAheadForSilence,
            positionUpdateInterval: 0.05,
            sampleInterval: 0.5
        )
        let engine = AudioPlayerEngine(configuration: configuration)
        engine.delegate = delegate
        self.engine = engine
        self.delegate = delegate
        self.nowPlaying = nowPlaying
        self.remote = remote
        self.processors = made.processors
    }
}

/// Base class: a scratch directory and an engine that is always shut down.
@MainActor
class EngineTestCase: XCTestCase {
    var directory: URL!
    private var engines: [AudioPlayerEngine] = []

    override func setUp() async throws {
        try await super.setUp()
        directory = try makeTemporaryDirectory()
    }

    override func tearDown() async throws {
        engines.forEach { $0.shutdown() }
        engines.removeAll()
        try await super.tearDown()
    }

    func harness(
        queue: [PlayableItem] = [],
        artworkSession: URLSession = .shared,
        scansAheadForSilence: Bool = true,
        withProcessors: Bool = true
    ) -> EngineHarness {
        let harness = EngineHarness(queue: queue, artworkSession: artworkSession, scansAheadForSilence: scansAheadForSilence, withProcessors: withProcessors)
        engines.append(harness.engine)
        return harness
    }

    func tone(_ seconds: Double, frequency: Double = 440, name: String) throws -> PlayableItem {
        .file(try ToneFile.tone(seconds, frequency: frequency, in: directory, name: name))
    }
}

#if os(iOS)
/// Records when the engine asks for the track's rate, against whether its deck was already
/// playing: the rate request must land before the deck plays.
@MainActor
final class FakeAudioSession: AudioSessionControlling {
    /// Whether the deck was playing at each rate request, in request order.
    private(set) var rateRequestedWhilePlaying: [Bool] = []
    /// The probe sampled when each rate request arrives; the test binds it to the deck.
    var playbackStateProbe: (() -> Bool)?
    private(set) var activated = false
    private(set) var activations = 0
    private(set) var resets = 0
    private(set) var multichannelAllowed = false

    var trackSampleRate: Double? {
        didSet { rateRequestedWhilePlaying.append(playbackStateProbe?() ?? false) }
    }

    func activate() {
        activated = true
        activations += 1
    }
    func mediaServicesWereReset() { resets += 1 }
    func allowMultichannelContent() { multichannelAllowed = true }
}
#endif
