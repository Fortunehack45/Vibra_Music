import VibraMusicCore
import Lyrics
import SwiftUI

/// The rules behind the sources list (LyricsSourcesDialog.kt's `onToggle` / `toggleable`).
enum LyricsSourceSelection {
    /// The set after tapping `source`, or nil when the tap is refused: the last source standing
    /// can't be unticked — an empty list is indistinguishable from switching lyrics off, and
    /// there is already a switch for that.
    static func toggling(_ source: LyricsSource, in selected: Set<LyricsSource>) -> Set<LyricsSource>? {
        if selected.contains(source) {
            guard selected.count > 1 else { return nil }
            return selected.subtracting([source])
        }
        return selected.union([source])
    }

    /// Whether the row can be tapped (the last enabled one reads as disabled rather than looking
    /// clickable and silently doing nothing).
    static func isToggleable(_ source: LyricsSource, in selected: Set<LyricsSource>) -> Bool {
        !selected.contains(source) || selected.count > 1
    }

    /// The priority order after a drag. Priority and participation are separate questions, so a
    /// row moves whether or not it is ticked.
    static func moving(_ order: [LyricsSource], from offsets: IndexSet, to destination: Int) -> [LyricsSource] {
        var order = order
        order.move(fromOffsets: offsets, toOffset: destination)
        return order
    }
}

/// Which lyric databases the player may ask, and in which order (ports
/// ui/components/LyricsSourcesDialog.kt): the sources with a tick each, dragged by their handles
/// to reorder; then the PaxSenix key, "Prioritize syllable lyrics", Reset to default and Done.
///
/// Android draws this as a frosted iOS-style alert. A system alert can't hold a reorderable list,
/// so on iOS it is a sheet laid out like that alert — the title and explanation centred on top,
/// the list, and the same four action rows pinned under it — with the system's own reorder
/// handles (which sit on the trailing edge on iOS).
struct LyricsSourcesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @State private var editingKey = false
    @State private var keyInput = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text(L10n.lyricsSources)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(L10n.lyricsSourcesOrder)
                    .font(.footnote)
                    .foregroundStyle(.primary)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.top, 22)
            .padding(.bottom, 19)

            List {
                ForEach(settings.lyricsSourceOrder, id: \.self) { source in
                    sourceRow(source)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 8))
                }
                .onMove { offsets, destination in
                    Haptics.shared.play(.select)
                    settings.lyricsSourceOrder = LyricsSourceSelection.moving(settings.lyricsSourceOrder, from: offsets, to: destination)
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 44)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
            .accessibilityIdentifier("lyricsSources.list")

            Divider()
            AlertActionRow(
                label: settings.paxSenixApiKey.isEmpty ? L10n.paxsenixApiKeyMissing : L10n.paxsenixApiKeyConfigured,
                emphasised: false
            ) {
                keyInput = settings.paxSenixApiKey
                editingKey = true
            }
            Divider()
            syllableSyncRow
            Divider()
            AlertActionRow(label: L10n.resetToDefault, emphasised: false) {
                Haptics.shared.play(.tap)
                settings.resetLyricsSourceSettings()
            }
            .accessibilityIdentifier("lyricsSources.reset")
            Divider()
            AlertActionRow(label: L10n.done, emphasised: true) { dismiss() }
                .accessibilityIdentifier("lyricsSources.done")
        }
        .presentationDetents([.large])
        .presentationBackground(.regularMaterial)
        .alert(L10n.paxsenixApiKey, isPresented: $editingKey) {
            SecureField(L10n.paxsenixApiKey, text: $keyInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(L10n.save) { settings.setPaxSenixApiKey(keyInput) }
            Button(L10n.cancel, role: .cancel) {}
        }
        // A container: without this the identifier lands on every child and hides theirs.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lyrics.sourcesSheet")
    }

    private func sourceRow(_ source: LyricsSource) -> some View {
        let checked = settings.lyricsSources.contains(source)
        let toggleable = LyricsSourceSelection.isToggleable(source, in: settings.lyricsSources)
        return Button {
            guard let next = LyricsSourceSelection.toggling(source, in: settings.lyricsSources) else { return }
            Haptics.shared.play(checked ? .toggleOff : .toggleOn)
            settings.lyricsSources = next
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.label)
                        .font(.subheadline)
                        .foregroundStyle(.primary.opacity(toggleable ? 1 : 0.5))
                        .lineLimit(1)
                    Text(source.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if checked {
                    Image(systemName: AppSymbol.check)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 9)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!toggleable)
        .accessibilityAddTraits(checked ? .isSelected : [])
        .accessibilityValue(checked ? L10n.enabled : "")
        .accessibilityHint(L10n.dragToReorder)
        .accessibilityIdentifier("lyricsSources.\(source.rawValue)")
    }

    /// Not a source to ask or not, but a rule about what to do once one has answered — so a row
    /// of its own under the list.
    private var syllableSyncRow: some View {
        Button {
            Haptics.shared.play(settings.prioritizeSyllableSync ? .toggleOff : .toggleOn)
            settings.prioritizeSyllableSync.toggle()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.prioritizeSyllableLyrics)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Text(L10n.prioritizeSyllableLyricsSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if settings.prioritizeSyllableSync {
                    Image(systemName: AppSymbol.check)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(AlertRowButtonStyle())
        .accessibilityAddTraits(settings.prioritizeSyllableSync ? .isSelected : [])
        .accessibilityIdentifier("lyricsSources.syllableSync")
    }
}

/// An action row of the alert this sheet stands in for: full width, tinted text, a wash when
/// pressed instead of a ripple.
struct AlertActionRow: View {
    let label: String
    let emphasised: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.body.weight(emphasised ? .semibold : .regular))
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(AlertRowButtonStyle())
    }
}

struct AlertRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.09) : .clear)
    }
}
