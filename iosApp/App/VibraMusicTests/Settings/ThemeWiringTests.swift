import VibraMusicCore
import Lyrics
import SwiftUI
import XCTest
@testable import VibraMusic

/// PORTING §2.11 "Theme": what the settings do to the screens, read off what is drawn.
@MainActor
final class ThemeWiringTests: XCTestCase {
    /// Light and Dark are forced on the whole app, whatever the device uses (Theme.kt): the
    /// shell's own chrome and the screens inside it all take the chosen style.
    func testLightAndDarkAreForcedOnEveryScreenWhateverTheDeviceUses() async throws {
        for (mode, device, chosen) in [
            (ThemeMode.light, UIUserInterfaceStyle.dark, UIUserInterfaceStyle.light),
            (.dark, .light, .dark),
        ] {
            let settings = makeTestSettings()
            settings.themeMode = mode
            let app = makeAppModel(self, settings: settings)
            let host = UIHostingController(rootView: AppShell(model: app))
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            // The device's own setting, which only the theme can override.
            window.overrideUserInterfaceStyle = device
            window.rootViewController = host
            window.makeKeyAndVisible()
            addTeardownBlock { @MainActor in window.isHidden = true }
            await settle(host, style: chosen)
            app.router.open(.settings)
            await settle(host, style: chosen)

            XCTAssertEqual(host.view.traitCollection.userInterfaceStyle, chosen, "\(mode) on a \(device.rawValue) device")
            // Every tab's screen (Home also has Settings pushed on it), and the tab bar.
            for tab in AppTab.allCases {
                app.router.select(tab)
                await settle(host, style: chosen)
                let screens = host.view.allSubviews.filter { $0 is UITabBar || $0 is UINavigationBar || $0 is UIScrollView }
                XCTAssertGreaterThan(screens.count, 1, "\(tab) is on screen")
                for view in screens {
                    XCTAssertEqual(view.traitCollection.userInterfaceStyle, chosen, "\(type(of: view)) on \(tab) under \(mode) on a \(device.rawValue) device")
                }
            }
        }
    }

    /// Waits for the screen to finish building: the view tree has kept the same size for three polls (50 ms apart, so at least 200 ms in all)
    /// (a fixed half second per screen was most of this file's runtime), or two seconds have passed.
    /// The count only settles once the host carries `style`, the trait the assertions read: a tree can stop growing before the theme reaches it.
    private func settle(_ host: UIViewController, style: UIUserInterfaceStyle) async {
        var last = -1
        var steady = 0
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(50))
            let count = host.view.allSubviews.count
            steady = count == last && host.view.traitCollection.userInterfaceStyle == style ? steady + 1 : 0
            last = count
            if steady >= 3 { return }
        }
    }

    /// Reduce blur takes the blur off the lyrics' unfocused lines, the way switching the lyrics
    /// blur off does (Android: `blurEnabled = lyricsBlur && !reduceDynamicBlur`). Read off the
    /// Core Animation layers SwiftUI gives each line: a blurred line sits under a gaussian blur.
    func testReduceBlurTakesTheBlurOffTheLyricsLikeSwitchingTheLyricsBlurOff() async {
        func blurredLines(lyricsBlur: Bool, reduceBlur: Bool) async -> (blurred: Int, lines: Int) {
            let settings = makeTestSettings()
            settings.lyricsBlur = lyricsBlur
            settings.reduceDynamicBlur = reduceBlur
            let clock = LyricFrameClock()
            clock.reset(positionMs: 15_900, isPlaying: false)
            let host = renderLyricsView(
                LyricsPanelContent(lines: LyricsDemo.wordSynced, subLines: nil, looking: false, trackKey: "t", clock: clock, isPlaying: false,
                                   translation: LyricsTranslationController(), onSeek: { _ in }),
                settings: settings
            )
            try? await Task.sleep(for: .milliseconds(600))
            defer { host.view.window?.isHidden = true }
            let lines = host.view.lyricsDescendants(of: LyricLineUIView.self)
            return (lines.filter(hasBlurAbove).count, lines.count)
        }

        let blurred = await blurredLines(lyricsBlur: true, reduceBlur: false)
        let reduced = await blurredLines(lyricsBlur: true, reduceBlur: true)
        let off = await blurredLines(lyricsBlur: false, reduceBlur: false)

        XCTAssertGreaterThan(blurred.lines, 2, "the panel drew its lines")
        XCTAssertGreaterThan(blurred.blurred, 0, "the unfocused lines are blurred when nothing reduces it")
        XCTAssertEqual(reduced.blurred, 0, "reduce blur left \(reduced.blurred) of \(reduced.lines) lines blurred")
        XCTAssertEqual(off.blurred, 0)
    }

    /// Whether a gaussian blur filter sits on `view`'s layer or any layer above it.
    private func hasBlurAbove(_ view: UIView) -> Bool {
        var layer: CALayer? = view.layer
        while let current = layer {
            if (current.filters ?? []).contains(where: { "\($0)".contains("gaussianBlur") }) { return true }
            layer = current.superlayer
        }
        return false
    }
}
