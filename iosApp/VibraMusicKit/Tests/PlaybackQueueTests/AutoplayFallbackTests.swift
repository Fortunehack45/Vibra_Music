import XCTest
@testable import PlaybackQueue

/// Ports AutoplayFallbackTest: when AutoPlay forgets its seed and tries the current track again.
final class AutoplayFallbackTests: XCTestCase {

    func testEnabledAutoplayRefreshesWhenTheCurrentTrackHasNothingAfterIt() {
        XCTAssertTrue(AutoplayPolicy.queueNeedsRefresh(enabled: true, repeatAll: false, currentIndex: 2, itemCount: 3, loadInProgress: false))
    }

    func testAnExistingQueueOrActiveLoadDoesNotStartADuplicateRefresh() {
        XCTAssertFalse(AutoplayPolicy.queueNeedsRefresh(enabled: true, repeatAll: false, currentIndex: 1, itemCount: 3, loadInProgress: false))
        XCTAssertFalse(AutoplayPolicy.queueNeedsRefresh(enabled: true, repeatAll: false, currentIndex: 2, itemCount: 3, loadInProgress: true))
    }

    func testDisabledAutoplayRepeatAllAndAMissingCurrentTrackDoNotRefresh() {
        XCTAssertFalse(AutoplayPolicy.queueNeedsRefresh(enabled: false, repeatAll: false, currentIndex: 0, itemCount: 1, loadInProgress: false))
        XCTAssertFalse(AutoplayPolicy.queueNeedsRefresh(enabled: true, repeatAll: true, currentIndex: 0, itemCount: 1, loadInProgress: false))
        XCTAssertFalse(AutoplayPolicy.queueNeedsRefresh(enabled: true, repeatAll: false, currentIndex: -1, itemCount: 0, loadInProgress: false))
    }
}
