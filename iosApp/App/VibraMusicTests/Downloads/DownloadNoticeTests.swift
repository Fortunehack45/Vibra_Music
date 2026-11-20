import VibraMusicCore
import Downloads
import Foundation
import InnerTube
import Observation
import SwiftUI
import XCTest
@testable import VibraMusic

// What a tap on Download finally tells the listener: the Wi-Fi hold said once, where
// the tap was; "Download all" confirmed; a held row that names the hold. Driven through the real
// wiring (`CollectionsStore.shared(for:)` on a real AppModel), not an injected `enqueueDownloads`:
// the bug lived exactly there, where the download's outcome was discarded, and the tests that
// replaced the closure never saw it.

/// A connection a test drives by hand (`NetworkMonitor` stands in `NetworkStatusProviding`, so a
/// metered connection can be faked without a real radio).
final class FakeNetworkStatusProvider: NetworkStatusProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var current: NetworkStatus
    private var continuations: [UUID: AsyncStream<NetworkStatus>.Continuation] = [:]

    init(_ status: NetworkStatus) { current = status }

    var status: NetworkStatus { lock.withLock { current } }

    /// Changes the status and notifies every ``statusUpdates()`` stream (the metered connection
    /// the user walks back into Wi-Fi on).
    func send(_ status: NetworkStatus) {
        let listeners = lock.withLock {
            current = status
            return Array(continuations.values)
        }
        listeners.forEach { $0.yield(status) }
    }

    func statusUpdates() -> AsyncStream<NetworkStatus> {
        AsyncStream { continuation in
            let id = UUID()
            let initial: NetworkStatus = lock.withLock {
                continuations[id] = continuation
                return current
            }
            continuation.yield(initial)
            continuation.onTermination = { [weak self] _ in
                _ = self?.lock.withLock { self?.continuations.removeValue(forKey: id) }
            }
        }
    }
}

@MainActor
final class DownloadNoticeTests: XCTestCase {
    /// A real app over a hand-driven connection, its engine shut down when the test ends.
    func makeModel(_ test: XCTestCase, network: FakeNetworkStatusProvider) -> AppModel {
        let suite = "vibramusic.notice.tests.\(UUID().uuidString)"
        var launch = AppLaunchOptions()
        launch.restoresQueue = false
        launch.integratesWithSystem = false
        let model = AppModel(
            settings: makeTestSettings(),
            likeState: LikeState(),
            searchHistory: SearchHistory(defaults: UserDefaults(suiteName: suite)!),
            network: network,
            innerTube: InnerTubeClient(),
            audioCache: nil,
            launch: launch
        )
        let engine = model.engine
        test.addTeardownBlock { @MainActor in
            engine.shutdown()
            // The queue holds downloads that a metered connection will never release; stop its
            // watchers so nothing lives past the test.
            model.downloads.cancelAll()
        }
        return model
    }

    /// Wi-Fi only on (the default) and nothing but metered in hand: tapping Download holds the
    /// download and says so — as a notice where the tap was, and as the held row's own label. A
    /// silent "Queued" ring that never moves is exactly the "downloads don't work" report.
    func testATapOnAMeteredConnectionHoldsAndSaysWhy() async throws {
        let network = FakeNetworkStatusProvider(.cellular)
        let model = makeModel(self, network: network)
        let store = CollectionsStore.shared(for: model)
        XCTAssertNil(model.player.notice)

        store.download(CollectionsFixtures.song("hold", "Still Waiting"))

        // The notice is above the mini player (MainActivity's refusal toast); the download waits
        // rather than being refused.
        XCTAssertEqual(model.player.notice?.message, L10n.wifiOnlyDownloadRefusal,
                       "the hold is said where the tap was: \(model.player.notice?.message ?? "nothing said")")
        XCTAssertEqual(model.player.notice?.symbol, "wifi.slash")
        XCTAssertEqual(store.service.downloadState("hold"), .queued, "held, not refused")
        // The held row says why it isn't moving, instead of "Queued".
        XCTAssertEqual(store.service.isWaitingForWiFi, true)
        XCTAssertEqual(model.downloads.active["hold"], .queued)
        XCTAssertTrue(model.downloads.isWaitingForWiFi)

        // A repeat onto the held queue says the hold again, not a phantom "it's downloading": the
        // notice is cleared first, so the assertion below can only be met by this tap.
        model.player.notice = nil
        store.download(CollectionsFixtures.song("hold", "Still Waiting"))
        XCTAssertEqual(model.player.notice?.message, L10n.wifiOnlyDownloadRefusal,
                       "a re-tap into a held queue repeats the hold: \(model.player.notice?.message ?? "nothing said")")
        XCTAssertEqual(model.player.notice?.symbol, "wifi.slash")
        XCTAssertEqual(model.downloads.active["hold"], .queued)
    }

    /// The hold, said for a whole album in one line: the batch toast is the refusal when the
    /// connection can't take the batch (Android's `blocked` branch speaks whatever the count).
    func testDownloadAllOnAMeteredConnectionSaysTheHoldForTheWholeBatch() async throws {
        let network = FakeNetworkStatusProvider(.cellular)
        let model = makeModel(self, network: network)
        let store = CollectionsStore.shared(for: model)
        XCTAssertNil(model.player.notice)

        let album = BrowseItem(browseId: "MPREb_album", title: "Discovery", subtitle: "Daft Punk",
                               thumbnailUrl: nil, type: .album)
        store.downloadAll(CollectionsFixtures.albumSongs, item: album)

        XCTAssertEqual(model.player.notice?.message, L10n.wifiOnlyDownloadRefusal,
                       "one line for the batch: \(model.player.notice?.message ?? "nothing said")")
        XCTAssertEqual(store.service.releaseIsDownloading("MPREb_album"), true, "the batch is held")
        XCTAssertEqual(model.downloads.active.count, 4, "every track asked for is held")
        XCTAssertTrue(model.downloads.isWaitingForWiFi)
    }

    /// What each kind of tap turns into, in Android's words — driven through the same `make` the
    /// wiring calls, so the table and the wiring cannot drift apart.
    func testTheNoticeFollowsTheTapAndTheOutcome() {
        // A hold speaks first, whatever the count.
        XCTAssertEqual(DownloadNotice.make(for: DownloadRequestOutcome(queued: 3, waitingForWiFi: true),
                                           requested: 3),
                       DownloadNotice.Line(message: L10n.wifiOnlyDownloadRefusal, symbol: "wifi.slash"))
        // "Download all" that starts work confirms it in one line.
        XCTAssertEqual(DownloadNotice.make(for: DownloadRequestOutcome(queued: 2), requested: 2),
                       DownloadNotice.Line(message: L10n.downloadingSongCount(2), symbol: "arrow.down.circle"))
        // A batch already on the device is said, not silently ignored.
        XCTAssertEqual(DownloadNotice.make(for: DownloadRequestOutcome(alreadyDownloaded: 4), requested: 4),
                       DownloadNotice.Line(message: L10n.alreadyDownloaded, symbol: nil))
        // Everything asked for was already queued: still said (Android counts the queue too).
        XCTAssertEqual(DownloadNotice.make(for: DownloadRequestOutcome(alreadyQueued: 2), requested: 2),
                       DownloadNotice.Line(message: L10n.downloadingSongCount(2), symbol: "arrow.down.circle"))
        // One track, nothing to hold: its row turns into the progress; a toast would say nothing
        // a row can't.
        XCTAssertNil(DownloadNotice.make(for: DownloadRequestOutcome(queued: 1), requested: 1))
        XCTAssertNil(DownloadNotice.make(for: DownloadRequestOutcome(alreadyQueued: 1), requested: 1))
        // A repeat tap onto a queue already held: nothing new was queued, but the hold is still
        // what the tap means — not a phantom "Downloading N songs" over a queue that isn't moving.
        XCTAssertEqual(DownloadNotice.make(for: DownloadRequestOutcome(alreadyQueued: 3), requested: 3,
                                           queueHoldingForWiFi: true),
                       DownloadNotice.Line(message: L10n.wifiOnlyDownloadRefusal, symbol: "wifi.slash"))
        // The same outcome on a queue that isn't held: the batch count stands.
        XCTAssertEqual(DownloadNotice.make(for: DownloadRequestOutcome(alreadyQueued: 3), requested: 3),
                       DownloadNotice.Line(message: L10n.downloadingSongCount(3), symbol: "arrow.down.circle"))
    }
}
