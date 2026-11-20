import XCTest

/// End-to-end flows against the real app. Part of the Vibra MusicE2E test plan, not the default
/// gate: they need the network and a live YouTube Music.
final class LaunchUITests: XCTestCase {
    func testAppLaunches() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }
}
