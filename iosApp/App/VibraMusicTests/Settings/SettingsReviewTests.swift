import VibraMusicCore
import SwiftUI
import XCTest
@testable import Vibra Music

/// Regressions found in review: the cache slider follows the stored limit, and rows stay readable
/// at accessibility text sizes.
@MainActor
final class SettingsReviewTests: XCTestCase {
    /// The slider used to keep its own copy, read once on appear, so a restored backup (or any
    /// other writer) left it showing the old limit. It now reads the setting itself.
    func testTheCacheSliderFollowsTheStoredLimit() async throws {
        await enableAccessibilityTree()
        let settings = makeSettingsTestSettings()
        settings.audioCacheLimitBytes = SongCacheLimit.bytes(ofMegabytes: 1_024)
        let app = makeSettingsTestApp(settings: settings)
        // Tall enough that the list draws the Storage rows without scrolling.
        let host = settingsHostAndLayOut(NavigationStack { SettingsScreen() }.settingsTestEnvironment(app),
                                         size: CGSize(width: 393, height: 3_000))
        let shown = await settledRenderedValues(host, until: "1 GB")
        XCTAssertTrue(shown.contains("1 GB"), "the slider reads the limit it opened with: \(shown)")

        settings.audioCacheLimitBytes = SongCacheLimit.bytes(ofMegabytes: 4_096)
        let moved = await settledRenderedValues(host, until: "4 GB")
        XCTAssertTrue(moved.contains("4 GB"), "the slider followed the stored limit: \(moved)")
        XCTAssertFalse(moved.contains("1 GB"), "the slider kept the limit it opened with: \(moved)")
    }

    func testTheScreensRenderAtAccessibilityTextSizes() {
        let app = makeSettingsTestApp(settings: makeSettingsTestSettings())
        settingsHostAndLayOut(NavigationStack { SettingsScreen() }
            .settingsTestEnvironment(app).dynamicTypeSize(.accessibility3))
        settingsHostAndLayOut(NavigationStack { EqualizerScreen() }
            .settingsTestEnvironment(app).dynamicTypeSize(.accessibility3))
        settingsHostAndLayOut(NavigationStack { SourcesScreen() }
            .settingsTestEnvironment(app).dynamicTypeSize(.accessibility3))
    }

    /// A value row's text grows to three lines and takes its value under it, rather than
    /// truncating the title, once the text size is an accessibility one.
    func testAValueRowStacksAtAccessibilitySizes() {
        let row = SettingsRow(symbol: "wifi", title: L10n.onWifi, value: L10n.lossless, badge: L10n.inUse) {}
        let regular = UIHostingController(rootView: row.dynamicTypeSize(.large))
        let large = UIHostingController(rootView: row.dynamicTypeSize(.accessibility3))
        let regularHeight = regular.sizeThatFits(in: CGSize(width: 361, height: 1_000)).height
        let largeHeight = large.sizeThatFits(in: CGSize(width: 361, height: 1_000)).height
        XCTAssertGreaterThan(largeHeight, regularHeight * 2)
    }
}
