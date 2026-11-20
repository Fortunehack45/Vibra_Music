import SwiftUI
import UIKit

// Ports AppIcon.kt and the "App icon" row of ui/screens/SettingsSheet.kt (Advanced group).
//
// Android enables one launcher activity-alias at a time; iOS swaps alternate icons with
// `setAlternateIconName`. Each choice is an Icon Composer file in the app target, listed in the
// ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES build setting. Android's Liquid Glass (light) is
// the default here, and the home screen's own Dark, Clear and Tinted styles apply on top of
// whichever icon is chosen. The Samsung and Pixel variants differ from the rest only in their
// mask, and iOS draws one shape, so they have no iOS form. The Neon icons are left out on size:
// Xcode stores every icon as pre-rendered full-size images, about 6 MB each in the IPA.

/// The home-screen icon choices, in Android's order. The raw value is the icon's file name.
enum AppIconChoice: String, CaseIterable, Identifiable {
    case `default` = "AppIcon"
    case monochrome = "AppIconMonochrome"
    case glassDark = "AppIconGlassDark"
    case glassClear = "AppIconGlassClear"
    case glassClearDark = "AppIconGlassClearDark"

    var id: Self { self }

    /// What `setAlternateIconName` takes: nil puts the primary icon back.
    var alternateName: String? { self == .default ? nil : rawValue }

    /// The tile image, rendered in light and dark into the asset catalog: an app icon can't be
    /// loaded as an image at run time.
    var preview: String { rawValue + "Preview" }

    var label: String {
        switch self {
        case .default: L10n.appIconDefault
        case .monochrome: L10n.appIconMonochrome
        case .glassDark: L10n.appIconLiquidGlassDark
        case .glassClear: L10n.appIconLiquidGlassClear
        case .glassClearDark: L10n.appIconLiquidGlassClearDark
        }
    }

    /// The choice for the icon the system shows. A name this build doesn't know, from a build
    /// that had another icon, reads as the default, which is also what the system falls back to.
    init(alternateName: String?) {
        self = alternateName.flatMap(Self.init(rawValue:)) ?? .default
    }
}

/// The "App icon" row: its title, and under it a sideways strip of tiles with the chosen one's
/// name in bold and the accent colour (Android's 68 dp tile with its label under it).
struct AppIconPickerRow: View {
    @State private var selected = AppIconChoice(alternateName: UIApplication.shared.alternateIconName)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsRow(symbol: "square.grid.2x2", title: L10n.appIcon)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(AppIconChoice.allCases) { tile($0) }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(.bottom, 6)
    }

    private func tile(_ choice: AppIconChoice) -> some View {
        let isSelected = choice == selected
        return Button {
            choose(choice)
        } label: {
            VStack(spacing: 6) {
                Image(choice.preview)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 68, height: 68)
                Text(choice.label)
                    .font(.caption)
                    .fontWeight(isSelected ? .bold : .regular)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 84)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(choice.label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Marks the tile at once, as Android does, then the system confirms the change with its own
    /// alert. Whatever comes back, and in whatever order quick taps come back, the tile marked
    /// afterwards is the icon the system now shows.
    private func choose(_ choice: AppIconChoice) {
        guard choice != selected else { return }
        selected = choice
        Task {
            try? await UIApplication.shared.setAlternateIconName(choice.alternateName)
            selected = AppIconChoice(alternateName: UIApplication.shared.alternateIconName)
        }
    }
}
