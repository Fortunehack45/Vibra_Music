import UIKit
import XCTest
@testable import Vibra Music

/// The App icon row (Android 1.8.2 AppIcon.kt): what it offers must be what the build ships.
@MainActor
final class AppIconPickerTests: XCTestCase {
    /// Each alternate is an .icon file the ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES setting
    /// compiles into the Info.plist. A choice missing there fails at `setAlternateIconName`, and an
    /// icon shipped but not offered is dead weight; both show up here, on the built app.
    func testEveryChoiceShipsAsAnAlternateIcon() throws {
        let offered = Set(AppIconChoice.allCases.compactMap(\.alternateName))
        // The iPhone key always; the iPad one wherever the build writes it.
        let keys = ["CFBundleIcons"] + (Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons~ipad") == nil ? [] : ["CFBundleIcons~ipad"])
        for key in keys {
            let icons = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: key) as? [String: Any], key)
            let alternates = try XCTUnwrap(icons["CFBundleAlternateIcons"] as? [String: Any], "\(key) lists no alternates")
            XCTAssertEqual(Set(alternates.keys), offered, key)
        }
        XCTAssertNil(AppIconChoice.default.alternateName, "the default is the primary icon, set back with nil")
    }

    /// The tiles are rendered previews in the asset catalog, one for each appearance. A missing
    /// dark image would fall back to the light one, so the two must differ.
    func testEveryChoiceHasItsPreviewTileInLightAndDark() {
        func tile(_ choice: AppIconChoice, _ style: UIUserInterfaceStyle) -> UIImage? {
            UIImage(named: choice.preview, in: .main, compatibleWith: UITraitCollection(userInterfaceStyle: style))
        }
        for choice in AppIconChoice.allCases {
            let light = tile(choice, .light), dark = tile(choice, .dark)
            XCTAssertEqual(light?.size, CGSize(width: 68, height: 68), "\(choice) light: a 68 pt tile at 3x")
            XCTAssertEqual(dark?.size, CGSize(width: 68, height: 68), "\(choice) dark: a 68 pt tile at 3x")
            XCTAssertNotEqual(light?.pngData(), dark?.pngData(), "\(choice): the dark tile fell back to the light one")
        }
    }

    /// An icon name this build doesn't know, from a build that had another icon, shows as the
    /// default, which is what the system falls back to.
    func testTheSelectedTileFollowsTheSystemsIconName() {
        XCTAssertEqual(AppIconChoice(alternateName: nil), .default)
        XCTAssertEqual(AppIconChoice(alternateName: "AppIconMonochrome"), .monochrome)
        XCTAssertEqual(AppIconChoice(alternateName: "AppIconRetired"), .default)
    }

    func testTheRowSitsInAdvancedAndAnswersAndroidsKeywords() {
        for query in ["app icon", "launcher", "logo"] {
            let groups = SettingsCatalog.groups(visibility: .init(), search: SettingsSearch(query))
            XCTAssertEqual(groups.map(\.id), ["advanced"], query)
            XCTAssertEqual(groups.first?.rows.map(\.id), [.appIcon], query)
        }
    }

    /// Mac Catalyst keeps one Dock icon (`supportsAlternateIcons` is false), so no row there.
    func testNoRowWhereTheIconCantChange() {
        let all = SettingsCatalog.groups(visibility: SettingsVisibility(alternateIcons: false), search: SettingsSearch(""))
        XCTAssertFalse(all.flatMap(\.rows).map(\.id).contains(.appIcon))
    }
}
