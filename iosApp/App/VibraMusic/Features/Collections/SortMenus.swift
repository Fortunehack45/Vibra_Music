import VibraMusicCore
import SwiftUI

// The two sort controls of MainActivity.kt's top bar: the track-list sort on an album or playlist
// page (FrostedSortMenu) and the Library "Show all" grid's sort (a DropdownMenu).

extension SongSort {
    var label: String {
        switch self {
        case .default: return L10n.sortDefault
        case .titleAsc: return L10n.sortTitleAscending
        case .titleDesc: return L10n.sortTitleDescending
        case .dateAddedAsc: return L10n.sortDateAddedOldest
        case .dateAddedDesc: return L10n.sortDateAdded
        }
    }

    var isDateAdded: Bool { self == .dateAddedAsc || self == .dateAddedDesc }

    /// The date row flips direction; a fresh activation lands on newest first, the point of it.
    var flippedDateDirection: SongSort {
        switch self {
        case .dateAddedDesc: return .dateAddedAsc
        case .dateAddedAsc: return .dateAddedDesc
        default: return .dateAddedDesc
        }
    }
}

extension LibrarySort {
    var label: String {
        switch self {
        case .default: return L10n.sortDefault
        case .titleAsc: return L10n.sortTitleAscending
        case .titleDesc: return L10n.sortTitleDescending
        }
    }
}

/// The track-list sort button and its menu. Android drew a frosted panel under the bar; the iOS
/// equivalent is a popover on its own material, kept as a popover on iPhone so it can stay open
/// while the date row flips direction and the list reorders behind it (a `Menu` closes on every
/// tap).
struct SongSortButton: View {
    let browseId: String

    @Environment(AppSettings.self) private var settings
    @State private var open = false

    var body: some View {
        Button {
            Haptics.shared.play(.tap)
            open = true
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel(L10n.sortSongs)
        .accessibilityIdentifier("detail.sort")
        .popover(isPresented: $open, arrowEdge: .top) {
            SongSortPanel(selected: settings.detailSongSort(for: browseId)) { option in
                settings.setDetailSongSort(option, for: browseId)
                open = false
            } onFlipDate: {
                settings.setDetailSongSort(settings.detailSongSort(for: browseId).flippedDateDirection, for: browseId)
            }
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// The panel: "Date added" first as one row whose arrow shows and flips the direction, then the
/// other orders with a tick on the chosen one.
struct SongSortPanel: View {
    let selected: SongSort
    let onSelect: (SongSort) -> Void
    let onFlipDate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Haptics.shared.play(.tick)
                withAnimation(.easeInOut(duration: 0.2)) { onFlipDate() }
            } label: {
                row(L10n.sortDateAddedToggle) {
                    if selected.isDateAdded {
                        Image(systemName: "arrow.up")
                            .foregroundStyle(Color.accentColor)
                            .rotationEffect(.degrees(selected == .dateAddedAsc ? 180 : 0))
                    }
                }
            }
            .accessibilityValue(selected.isDateAdded ? selected.label : "")
            ForEach(SongSort.allCases.filter { !$0.isDateAdded }, id: \.self) { option in
                Button {
                    Haptics.shared.play(.select)
                    onSelect(option)
                } label: {
                    row(option.label) {
                        if option == selected {
                            Image(systemName: AppSymbol.check).foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .accessibilityAddTraits(option == selected ? .isSelected : [])
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 8)
        .frame(minWidth: 240)
        .accessibilityIdentifier("detail.sortMenu")
    }

    private func row(_ title: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack {
            Text(title).font(CollectionsType.body)
            Spacer(minLength: 16)
            trailing()
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// The Library grid's sort (MainActivity's DropdownMenu over `LibrarySort`): a native menu with a
/// tick on the current order.
struct LibrarySortButton: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Menu {
            Picker(L10n.sortLibrary, selection: $settings.librarySort) {
                ForEach(LibrarySort.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel(L10n.sortLibrary)
        .accessibilityIdentifier("library.sort")
    }
}
