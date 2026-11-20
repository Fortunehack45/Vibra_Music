import SwiftUI
import UIKit

// Ports the building blocks at the foot of ui/screens/SettingsSheet.kt (SettingsGroup, SettingsRow,
// SettingsSubRow, SliderRow, Badge, Chevron, SegmentedControl, DestructiveRow) and the three
// picker sheets (QualitySheet, DownloadQualitySheet, AutomixPerformanceSheet, PresetSheet).
//
// Android drew iOS's inset grouped list by hand: "inset cards of rows, a leading glyph per row,
// the current value on the right, and a plain-language footer". On iOS that is `List` with the
// `.insetGrouped` style, so the groups here are `Section`s and only the rows are custom. Shared by
// the Settings, Equalizer and Sources screens (Android shared them the same way).

/// Glyph width and the gap after it (Android `ICON_SIZE` 22 dp, `ICON_GAP` 14 dp).
enum SettingsMetrics {
    static let iconSize: CGFloat = 22
    static let iconGap: CGFloat = 14
    /// Where a row's text starts, which is also where `List` insets its separators.
    static let textInset: CGFloat = iconSize + iconGap
}

/// The row glyph: an SF Symbol in the label colour, the Material rounded icon's stand-in.
struct SettingsIcon: View {
    let symbol: String
    // Scaled with the text beside it, so a glyph doesn't shrink to a speck next to an
    // accessibility-size title.
    @ScaledMetric(relativeTo: .body) private var glyph: CGFloat = 17
    @ScaledMetric(relativeTo: .body) private var box: CGFloat = SettingsMetrics.iconSize

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: glyph, weight: .regular))
            .foregroundStyle(.primary)
            .frame(width: box, height: box)
            .accessibilityHidden(true)
    }
}

/// The small accent pill beside a title: "IN USE", "BLOCKING", "CONNECTED", a party's head count.
struct SettingsBadge: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// Title (with an optional badge) over an optional subtitle.
struct SettingsRowText: View {
    let title: String
    var subtitle: String?
    var badge: String?
    var subtitleColor: Color = .secondary
    /// At accessibility text sizes the row's value moves under the text rather than squeezing
    /// the title to an ellipsis beside it.
    var stackedValue: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Android's one-line titles and five-line subtitles, relaxed at accessibility sizes,
        // where a single line holds a word or two and truncation would hide what the row is.
        let large = typeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: 2) {
            if large {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let badge { SettingsBadge(text: badge) }
            } else {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let badge { SettingsBadge(text: badge) }
                }
            }
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(subtitleColor)
                    .lineLimit(large ? nil : 5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let stackedValue {
                Text(stackedValue)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // List separators start where the text does, not under the glyph (as on iOS and Android).
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }
}

/// The standard row: glyph, title, optional subtitle, and on the trailing edge either `trailing`
/// (a switch) or the current `value` followed by a chevron when the row opens something.
struct SettingsRow<Trailing: View>: View {
    var symbol: String?
    let title: String
    var subtitle: String?
    var value: String?
    var badge: String?
    var enabled = true
    var action: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        let content = HStack(spacing: 0) {
            if let symbol {
                SettingsIcon(symbol: symbol)
                Spacer().frame(width: SettingsMetrics.iconGap)
            }
            SettingsRowText(title: title, subtitle: subtitle, badge: badge, stackedValue: stacked ? value : nil)
            Spacer(minLength: 12)
            if Trailing.self != EmptyView.self {
                trailing()
            } else if value != nil || action != nil {
                if let value, !stacked {
                    Text(value)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.trailing, 4)
                }
                SettingsChevron()
            }
        }
        .frame(minHeight: 28)
        .contentShape(Rectangle())
        .opacity(enabled ? 1 : 0.45)

        if let action, enabled, Trailing.self == EmptyView.self {
            Button(action: action) { content }
                .buttonStyle(SettingsRowButtonStyle())
                .accessibilityElement(children: .combine)
        } else {
            content
                .accessibilityElement(children: .combine)
        }
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(symbol: String? = nil, title: String, subtitle: String? = nil, value: String? = nil, badge: String? = nil,
         enabled: Bool = true, action: (() -> Void)? = nil) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.badge = badge
        self.enabled = enabled
        self.action = action
        self.trailing = { EmptyView() }
    }
}

/// A row that is a switch: tapping anywhere on it flips the switch (Android's `onClick` toggling
/// the same setting its `Switch` shows). One accessibility element that reads as a switch.
struct SettingsToggleRow: View {
    var symbol: String?
    let title: String
    var subtitle: String?
    var badge: String?
    var enabled = true
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 0) {
                if let symbol {
                    SettingsIcon(symbol: symbol)
                    Spacer().frame(width: SettingsMetrics.iconGap)
                }
                SettingsRowText(title: title, subtitle: subtitle, badge: badge)
            }
        }
        .tint(Color.accentColor)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .frame(minHeight: 28)
        .sensoryFeedback(.selection, trigger: isOn)
    }
}

/// A toggle that reads as part of the row above it: no glyph, its text aligned with the parent's
/// text (Android `SettingsSubRow`). Placed as its own list row with the separator above hidden.
struct SettingsSubToggleRow: View {
    let title: String
    var subtitle: String?
    var badge: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            SettingsRowText(title: title, subtitle: subtitle, badge: badge)
        }
        .tint(Color.accentColor)
        .padding(.leading, SettingsMetrics.textInset)
        .sensoryFeedback(.selection, trigger: isOn)
        // Pulled up against its parent: no top padding, 10 below (Android SettingsSubRow).
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 10, trailing: 16))
    }
}

/// A continuous setting: glyph, title, subtitle and value on one line, the slider beneath aligned
/// with the text (Android `SliderRow`; the bare track without tick marks is what `Slider` draws).
struct SettingsSliderRow: View {
    let symbol: String
    let title: String
    var subtitle: String?
    let value: String
    @Binding var sliderValue: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                SettingsIcon(symbol: symbol)
                Spacer().frame(width: SettingsMetrics.iconGap)
                SettingsRowText(title: title, subtitle: subtitle)
                Spacer(minLength: 12)
                Text(value)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: Binding(get: { sliderValue }, set: { raw in
                let snapped = (raw / step).rounded() * step
                if snapped != sliderValue { sliderValue = min(max(snapped, range.lowerBound), range.upperBound) }
            }), in: range) {
                Text(title)
            }
            .padding(.leading, SettingsMetrics.textInset)
            .accessibilityValue(value)
            .sensoryFeedback(.selection, trigger: sliderValue)
        }
        .padding(.vertical, 4)
    }
}

/// The trailing chevron of a row that opens something. Mirrors itself right to left.
struct SettingsChevron: View {
    var body: some View {
        Image(systemName: "chevron.forward")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

/// Highlights the row while pressed, the way a List row does.
struct SettingsRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(
                Color(uiColor: .systemFill)
                    .opacity(configuration.isPressed ? 1 : 0)
                    .padding(.horizontal, -16)
                    .padding(.vertical, -12)
            )
    }
}

/// A centred, accent-coloured action with no glyph: Reset (Android `DestructiveRow`).
struct SettingsCenteredActionRow: View {
    let label: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .frame(maxWidth: .infinity)
                .foregroundStyle(Color.accentColor)
        }
        .disabled(!enabled)
    }
}

// MARK: - Picker sheets

/// One option of a ``SettingsChoiceSheet``.
struct SettingsChoice<Value: Hashable>: Identifiable {
    let value: Value
    let label: String
    var detail: String?
    var selectable = true
    var id: Value { value }
}

/// The bottom sheet Android opens for a setting with more than two choices: a glyph and title
/// with a line saying what the choice is about, a hairline, then one row per option with a tick
/// on the current one. Picking commits and closes.
struct SettingsChoiceSheet<Value: Hashable>: View {
    var symbol: String?
    let title: String
    var subtitle: String?
    let options: [SettingsChoice<Value>]
    let selected: Value
    let onSelect: (Value) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.title3)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.bold())
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 14)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(options) { option in
                        Button {
                            Haptics.shared.play(.tick)
                            onSelect(option.value)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label).foregroundStyle(.primary)
                                    if let detail = option.detail {
                                        Text(detail)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.leading)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if option.value == selected {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                        .accessibilityHidden(true)
                                }
                            }
                            .padding(.horizontal, 22)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(SettingsSheetRowStyle())
                        .disabled(!option.selectable)
                        .accessibilityAddTraits(option.value == selected ? .isSelected : [])
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct SettingsSheetRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color(uiColor: .systemFill).opacity(configuration.isPressed ? 1 : 0))
    }
}

// MARK: - Groups

/// One of Android's `SettingsGroup`s: an inset card of rows with an UPPERCASE header above it in
/// `labelSmall` (caption2 semibold, secondary), 26 pt above the header and 8 pt below it, inset 4 pt
/// from the card's edge; a group without a header still gets its 26 pt. The optional footer is the
/// plain-language line under the card. Lists using it set `.settingsGroupList()`.
struct SettingsGroup<Content: View>: View {
    var header: String?
    var footer: String?
    /// Room above a card with no header (Android `topSpacing`).
    var topSpacing: CGFloat = 26
    @ViewBuilder var content: () -> Content

    var body: some View {
        Section {
            // Android's row padding: 16 either side, 12 above and below a 28 pt line (52 pt rows).
            content()
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        } header: {
            Group {
                if let header {
                    Text(header.uppercased(with: LanguageBundle.locale))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                        .accessibilityAddTraits(.isHeader)
                } else {
                    Color.clear.frame(height: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(top: header == nil ? topSpacing : 26, leading: 4, bottom: header == nil ? 0 : 8, trailing: 4))
        } footer: {
            if let footer {
                Text(footer)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
                    .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 0, trailing: 4))
            }
        }
    }
}

extension View {
    /// The list style every Settings page uses: inset cards, Android's spacing between groups
    /// (carried by the group headers) and its 52 pt minimum row height.
    func settingsGroupList() -> some View {
        listStyle(.insetGrouped)
            .listSectionSpacing(0)
            .environment(\.defaultMinListRowHeight, 0)
    }
}

/// Makes the navigation bar lay its search field out again once the page is back on screen.
///
/// Coming back to Settings from Listen together left the field's filled box undrawn for a few
/// seconds on iOS 27: the bar was handed back mid-pop from a page with its own trailing item (the
/// server ping, which changes while the page is open), and the system drawer only redrew when
/// something else next invalidated the bar. Nothing in the page sets that appearance, so the page
/// asks for the layout pass itself when it has fully appeared.
struct SearchFieldRedraw: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    static func redraw(in navigationController: UINavigationController?) {
        let bar = navigationController?.topViewController?.navigationItem.searchController?.searchBar
        bar?.setNeedsLayout()
        bar?.layoutIfNeeded()
        navigationController?.navigationBar.setNeedsLayout()
        navigationController?.navigationBar.layoutIfNeeded()
    }

    final class Controller: UIViewController {
        // Called after a pop's transition has finished too, which is the moment that matters.
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            SearchFieldRedraw.redraw(in: navigationController)
        }
    }
}
