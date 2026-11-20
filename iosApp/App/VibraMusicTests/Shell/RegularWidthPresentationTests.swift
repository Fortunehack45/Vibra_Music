import SwiftUI
import XCTest
@testable import VibraMusic

/// iPad and Mac windows use the regular-width tab bar, where a sheet or cover hung from the TabView
/// does not inherit the objects injected on the root. The first view of each reads `AppModel`, which
/// stops the app when it is missing (as on a Mac), so reaching the end is the check.
@MainActor
final class RegularWidthPresentationTests: XCTestCase {
    private func regularShell() -> (host: UIViewController, router: AppRouter) {
        let app = makeAppModel(self)
        let host = hostInScene(AppShell(model: app), test: self, size: CGSize(width: 1024, height: 768))
        host.traitOverrides.horizontalSizeClass = .regular
        return (host, app.router)
    }

    func testASheetOpenedFromTheTabBarAtRegularWidthReadsTheAppsObjects() async {
        let shell = regularShell()
        shell.router.sheet = .profileSwitcher
        await enableAccessibilityTree()
        await waitUntil("the sheet is up") { shell.host.presentedViewController != nil }
        await waitUntil("the sheet drew its rows") { shell.host.presentedViewController?.view.renderedLabels.isEmpty == false }
    }

    func testNowPlayingOpenedFromTheTabBarAtRegularWidthReadsTheAppsObjects() async {
        let shell = regularShell()
        shell.router.nowPlaying.open()
        await waitUntil("Now Playing is up") { shell.host.presentedViewController != nil }
        XCTAssertNotNil(shell.host.presentedViewController)
    }
}
