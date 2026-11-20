import Downloads
import UIKit
import XCTest
@testable import Vibra Music

/// A finished background download can launch the app with no window and so no `AppModel.current`;
/// the wake must still reach the download queue instead of being handed back to iOS at once.
@MainActor
final class BackgroundWakeTests: XCTestCase {
    func testAWakeThatLaunchedTheProcessReachesTheDownloadQueue() {
        let app = makeAppModel(self)
        SystemAppAccess.override = app
        addTeardownBlock { @MainActor in SystemAppAccess.override = nil }
        XCTAssertNil(AppModel.current, "nothing opened a window")

        var handedBack = false
        AppDelegate().application(
            UIApplication.shared,
            handleEventsForBackgroundURLSession: URLSessionDownloadTransport.defaultBackgroundIdentifier
        ) { handedBack = true }
        XCTAssertFalse(handedBack, "the download queue holds the handler until its events are delivered")
    }
}
