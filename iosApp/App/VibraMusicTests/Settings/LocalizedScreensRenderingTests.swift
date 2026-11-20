import VibraMusicCore
import SwiftUI
import XCTest
@testable import VibraMusic

/// Localization audit: the screens in the audit's scope must read from the generated `L10n`
/// catalog rather than shipping English literals. These render a couple of them under the German
/// override and look for the translated text in what was drawn.
@MainActor
final class LocalizedScreensRenderingTests: XCTestCase {
    private var savedOverride: String?

    override func setUp() {
        super.setUp()
        savedOverride = LanguageBundle.override
    }

    override func tearDown() {
        LanguageBundle.override = savedOverride
        super.tearDown()
    }

    /// Every string UIKit actually put on screen — navigation titles, field placeholders and
    /// accessibility labels. (Bare SwiftUI `Text` is drawn into a display list, not a `UILabel`,
    /// so the navigation title is the reliable probe for which language a screen rendered in.)
    private func renderedText(in view: UIView) -> [String] {
        var found: [String] = []
        func walk(_ element: UIView) {
            if let label = element as? UILabel, let text = label.text, !text.isEmpty { found.append(text) }
            if let field = element as? UITextField {
                if let text = field.text, !text.isEmpty { found.append(text) }
                if let placeholder = field.placeholder, !placeholder.isEmpty { found.append(placeholder) }
            }
            if let label = element.accessibilityLabel, !label.isEmpty { found.append(label) }
            element.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    /// Settings is built entirely from `L10n` rows; under German its title comes out translated.
    func testSettingsScreenRendersGerman() async {
        LanguageBundle.override = "de"
        // The audit's expectation: the catalog really does translate these.
        XCTAssertEqual(L10n.settings, "Einstellungen")
        XCTAssertNotEqual(L10n.settings, "Settings")
        XCTAssertEqual(L10n.crossfade, "Überblendung")

        let settings = makeSettingsTestSettings()
        let app = makeSettingsTestApp(settings: settings)
        let controller = await host(SettingsScreen(), model: app)

        let text = renderedText(in: controller.view)
        XCTAssertTrue(text.contains("Einstellungen"), text.description)
    }

    /// The crossfade row's value reads through `seconds_short`, so under Japanese it comes out as
    /// "12秒" (German and English both say "12 s", which could not tell a translated row from an
    /// English one).
    func testTheCrossfadeValueIsTranslated() async {
        LanguageBundle.override = "ja"
        XCTAssertEqual(L10n.secondsShort(12), "12秒")
        await enableAccessibilityTree()

        let settings = makeSettingsTestSettings()
        settings.crossfadeSeconds = 12
        let app = makeSettingsTestApp(settings: settings)
        // Tall enough that the list draws the Playback rows without scrolling.
        let controller = settingsHostAndLayOut(NavigationStack { SettingsScreen() }.settingsTestEnvironment(app),
                                               size: CGSize(width: 393, height: 3_000))
        addTeardownBlock { @MainActor in controller.view.window?.isHidden = true }

        let values = await settledRenderedValues(controller, until: "12秒")
        XCTAssertTrue(values.contains("12秒"), values.description)
    }

    /// The Equalizer screen renders under the override with its catalog title, not the English one.
    /// French, because German spells it "Equalizer" too and so could not tell the two apart.
    func testEqualizerScreenRendersUnderFrench() async {
        LanguageBundle.override = "fr"
        XCTAssertEqual(L10n.equalizer, "Égaliseur")
        let settings = makeSettingsTestSettings()
        let app = makeSettingsTestApp(settings: settings)
        let controller = await host(EqualizerScreen(), model: app)

        let text = renderedText(in: controller.view)
        XCTAssertTrue(text.contains("Égaliseur"), text.description)
    }

    /// The Library screen's title comes from the same catalog.
    func testLibraryScreenRendersGerman() async {
        LanguageBundle.override = "de"
        XCTAssertEqual(L10n.library, "Bibliothek")

        let (app, _, _) = makeCollectionsTestModel(self)
        let controller = await host(LibraryScreen(), model: app)

        let text = renderedText(in: controller.view)
        XCTAssertTrue(text.contains("Bibliothek"), text.description)
    }
}
