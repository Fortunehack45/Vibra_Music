import Foundation
import XCTest
@testable import NetworkLibrary

/// Extraction is synchronous and an SMB read is async, so each read blocks its thread until
/// a task of its own runs. On the shared async pool, a list's worth of covers at once took every
/// thread and all of the app's async work stopped for good. The bound is an expectation, because
/// an async timeout can't fire on a deadlocked pool.
final class RemoteArtReaderTests: XCTestCase {
    @discardableResult
    private func extractAll(count: Int, readDelay: Duration? = nil) -> FakeSmbShare {
        let (client, share, _) = makeSmbStack()
        share.readDelay = readDelay
        for index in 0..<count { share.files["\(index).mp3"] = Data(count: 64) }
        let finished = expectation(description: "all cover extractions finish")
        finished.expectedFulfillmentCount = count
        for index in 0..<count {
            Task {
                _ = await RemoteArtReader.picture(
                    url: "smb://nas.local/Music/\(index).mp3", isSmb: true,
                    session: .shared, smbClient: client, smbShare: "Music"
                )
                finished.fulfill()
            }
        }
        wait(for: [finished], timeout: 30)
        return share
    }

    func testMoreCoverExtractionsAtOnceThanThreadsAllFinish() {
        extractAll(count: ProcessInfo.processInfo.activeProcessorCount * 2)
    }

    /// Counted rather than timed, so a loaded runner can't fail it: a serial queue never has two
    /// reads under way.
    func testSlowCoverExtractionsDoNotQueueBehindEachOther() {
        let share = extractAll(count: 6, readDelay: .milliseconds(300))
        XCTAssertGreaterThanOrEqual(share.peakConcurrentReads, 2)
    }
}
