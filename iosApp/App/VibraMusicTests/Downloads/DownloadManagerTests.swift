import VibraMusicCore
import Downloads
import SwiftUI
import XCTest
@testable import VibraMusic

/// PORTING §2.6 "Download songs, albums and playlists": the queue with progress, cancel and retry,
/// as the manager sheet and the top-bar indicator show it.
@MainActor
final class DownloadManagerTests: XCTestCase {
    private func batch(_ session: DownloadSession) -> [Song] {
        let songs = (1...4).map { DownloadsFixtures.song("v\($0)", "Track \($0)", album: "Discovery") }
        for song in songs { session.queued(song, from: "Discovery") }
        session.done("v1")
        session.running("v2", fraction: 0.5)
        session.failed("v3", reason: "Network error")
        return songs
    }

    func testTheSummaryCountsWhatIsWaitingDoneAndFailed() {
        let session = DownloadSession()
        XCTAssertEqual(DownloadManagerSummary.text(for: session.state), L10n.nothingDownloading)
        _ = batch(session)
        XCTAssertEqual(DownloadManagerSummary.text(for: session.state),
                       [L10n.downloadWaitingCount(2), L10n.downloadDoneCount(1), L10n.downloadFailedCount(1)].joined(separator: " · "))
        session.done("v2")
        session.done("v4")
        XCTAssertEqual(DownloadManagerSummary.text(for: session.state),
                       [L10n.downloadDoneCount(3), L10n.downloadFailedCount(1)].joined(separator: " · "))
        session.done("v3")
        XCTAssertEqual(DownloadManagerSummary.text(for: session.state), L10n.allSongsDownloaded(4))

        XCTAssertEqual(DownloadManagerSummary.status(of: .running(fraction: 0)), L10n.starting)
        XCTAssertEqual(DownloadManagerSummary.status(of: .running(fraction: 0.42)), L10n.downloadingProgress(42))
        XCTAssertEqual(DownloadManagerSummary.status(of: .failed(reason: "Nope")), "Nope")

        // A queued row on a queue holding for Wi-Fi says why it is sitting still, not a "Queued"
        // that reads as stalled (Android says it in the tap's toast, the row carries it).
        XCTAssertEqual(DownloadManagerSummary.status(of: .queued), L10n.queued)
        XCTAssertEqual(DownloadManagerSummary.status(of: .queued, waitingForWiFi: true), wifiOnlyWaitingMessage)
        XCTAssertEqual(DownloadNotice.queuedRowLabel(waitingForWiFi: true), wifiOnlyWaitingMessage,
                       "the song menu's held row says it too (one label for both sheets)")
        XCTAssertEqual(DownloadManagerSummary.status(of: .running(fraction: 0.4), waitingForWiFi: true),
                       L10n.downloadingProgress(40), "a running row keeps its percentage")

        // The sheet's rows read the same flag the song menu's row does (the service is the seam).
        let fakeService = FakeDownloadsService(library: makeTestDownloadLibrary(self))
        XCTAssertEqual(DownloadManagerSummary.status(of: .queued, waitingForWiFi: fakeService.isWaitingForWiFi), L10n.queued)
        fakeService.isWaitingForWiFi = true
        XCTAssertEqual(DownloadManagerSummary.status(of: .queued, waitingForWiFi: fakeService.isWaitingForWiFi),
                       wifiOnlyWaitingMessage)
    }

    /// Render smoke test and the row actions: a running row cancels, a failed row retries, Cancel
    /// all stops only what is still going, and closing the sheet marks the batch seen.
    func testTheSheetListsTheBatchAndCancelsAndRetries() async throws {
        let service = FakeDownloadsService(library: makeTestDownloadLibrary(self))
        _ = batch(service.session)
        let (model, _) = makeDownloadsTestModel(self, service: service)

        let controller = await host(DownloadManagerSheet(), model: model, inNavigation: false, settle: 0.6)
        assertDrew(controller)
        let rows = service.session.state.items.sorted { $0.sequence < $1.sequence }
        XCTAssertEqual(rows.map(\.song.title), ["Track 1", "Track 2", "Track 3", "Track 4"], "newest ask last")
        XCTAssertEqual(DownloadManagerSummary.status(of: rows[2].progress), "Network error", "a failed row says why")

        // The row actions, as the sheet wires them.
        let failedRow = try XCTUnwrap(service.session.item("v3"))
        DownloadManagerRow(item: failedRow, onCancel: {}, onRetry: { service.retryDownload("v3") }).onRetry()
        XCTAssertEqual(service.retried, ["v3"])
        XCTAssertEqual(service.session.item("v3")?.progress, .queued, "retrying puts the row back in the queue")

        // Cancel all: only unsettled rows.
        let unsettled = service.session.state.items.filter { !$0.progress.settled }.map(\.videoId)
        unsettled.forEach(service.cancelDownload)
        XCTAssertEqual(Set(service.cancelled), ["v2", "v3", "v4"])
        XCTAssertEqual(service.session.state.items.map(\.videoId), ["v1"], "the finished row stays on the list")
        XCTAssertTrue(service.session.state.visible, "unseen until the sheet closes")
        service.session.markSeen()
        XCTAssertFalse(service.session.state.visible)
    }

    func testTheIndicatorShowsOnlyWhileThereIsABatchToReportOn() async {
        let service = FakeDownloadsService(library: makeTestDownloadLibrary(self))
        let (model, _) = makeDownloadsTestModel(self, service: service)
        XCTAssertFalse(service.session.state.visible)
        let empty = await host(DownloadBatchIndicator(state: service.session.state, action: {}), model: model, inNavigation: false)
        assertDrew(empty)

        _ = batch(service.session)
        XCTAssertTrue(service.session.state.visible)
        XCTAssertTrue(service.session.state.busy)
        let busy = await host(DownloadBatchIndicator(state: service.session.state, action: {}), model: model, inNavigation: false)
        assertDrew(busy)
        // Settled and looked at: the indicator goes.
        for id in ["v2", "v3", "v4"] { service.session.done(id) }
        XCTAssertTrue(service.session.state.visible, "a finished batch waits to be seen")
        service.session.markSeen()
        XCTAssertFalse(service.session.state.visible)
    }
}
