import XCTest
import VibraMusicCore
import VibraMusicTestSupport
@testable import PlaybackQueue

/// The song every Kotlin queue test builds: "Title <id>" by "Artist <id>".
func testSong(
    _ id: String,
    tier: QueueTier = .context,
    entryId: String? = nil,
    source: String? = nil,
    title: String? = nil,
    artist: String? = nil,
    album: String? = nil
) -> Song {
    Song(
        videoId: id,
        title: title ?? "Title \(id)",
        artist: artist ?? "Artist \(id)",
        albumName: album,
        queueTier: tier,
        queueEntryId: entryId,
        playbackSource: source
    )
}

/// A radio that answers from a script, records what it was asked, and can be told to fail.
final class FakeRadioSource: AutoplayRadioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var stations: [String: [Song]] = [:]
    /// Seeds whose next `n` requests fail; `Int.max` fails for good.
    private var failures: [String: Int] = [:]
    private var requested: [String] = []
    private var seeds: [String: String?] = [:]

    func setStation(_ seed: String, _ songs: [Song]) { lock.withLock { stations[seed] = songs } }
    func setFailure(_ seed: String, times: Int = .max) { lock.withLock { failures[seed] = times } }
    func setSeed(for videoId: String, _ seed: String?) { lock.withLock { _ = seeds.updateValue(seed, forKey: videoId) } }
    var requests: [String] { lock.withLock { requested } }

    struct RadioFailure: Error {}

    func youtubeSeed(for song: Song) async -> String? {
        lock.withLock {
            if let scripted = seeds[song.videoId] { return scripted }
            return song.videoId
        }
    }

    /// When set, every radio request waits here until it is released.
    var gate: RadioGate? {
        get { lock.withLock { currentGate } }
        set { lock.withLock { currentGate = newValue } }
    }
    private var currentGate: RadioGate?

    func radio(seedVideoId: String) async throws -> [Song] {
        let gate = lock.withLock {
            requested.append(seedVideoId)
            return currentGate
        }
        await gate?.wait()
        return try lock.withLock {
            if let remaining = failures[seedVideoId], remaining > 0 {
                failures[seedVideoId] = remaining == .max ? .max : remaining - 1
                throw RadioFailure()
            }
            return stations[seedVideoId] ?? []
        }
    }
}

/// A related-tracks batch with distinct titles and artists, so QueueBuilder keeps all of it.
func station(_ prefix: String, count: Int) -> [Song] {
    (1...count).map { Song(videoId: "\(prefix)\($0)", title: "\(prefix) song \($0)", artist: "\(prefix) artist \($0)") }
}

extension XCTestCase {
    /// Settings on an ephemeral suite with in-memory credentials.
    @MainActor
    func makeSettings(autoplay: Bool = false) -> AppSettings {
        let settings = AppSettings(defaults: makeEphemeralDefaults(), credentials: InMemoryCredentialStore())
        settings.autoplay = autoplay
        return settings
    }
}

/// Records every item change the controller reports.
@MainActor
final class ItemChangeRecorder {
    private(set) var changes: [QueueItemChange] = []
    var last: QueueItemChange? { changes.last }

    func attach(to controller: PlaybackQueueController) {
        controller.onCurrentItemChange = { [weak self] change in self?.changes.append(change) }
    }

    func reset() { changes = [] }
}

extension PlaybackQueueState {
    var ids: [String] { songs.map(\.videoId) }
    var upcomingIds: [String] { upcoming.map(\.videoId) }
}

/// Holds radio requests until the test lets them through, so a test can act while a load is in flight.
final class RadioGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let proceed = lock.withLock {
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if proceed { continuation.resume() }
        }
    }

    func release() {
        let pending = lock.withLock {
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume() }
    }
}

/// Polls `condition` on the main actor until it holds, failing after `timeout`.
@MainActor
func waitUntil(timeout: Duration = .seconds(5), file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            XCTFail("condition not met in time", file: file, line: line)
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}
