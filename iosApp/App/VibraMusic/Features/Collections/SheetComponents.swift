import VibraMusicCore
import SwiftUI
import Theming

// The furniture the three sheets share (ui/components/SongActionsSheet.kt's ActionRow,
// SheetTrackHeader, SheetHeading and TintedSheet; PlaylistPickerSheet.kt's RenamePlaylistForm), so
// the song menu, the release menu and the playlist picker read as one control.

/// One line of a sheet's menu (SongActionsSheet.kt's ActionRow). `tint` is for an icon that
/// carries state (a filled heart); `value` is a trailing word in the accent ("Cancel", "42%").
struct SheetActionRow: View {
    let symbol: String
    let label: String
    var value: String?
    var tint: Color?
    var accent: Color = .accentColor
    var enabled = true
    var identifier: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SheetActionRowLabel(symbol: symbol, label: label, value: value, tint: tint, accent: accent, enabled: enabled)
        }
        .buttonStyle(SheetRowButtonStyle())
        .disabled(!enabled)
        .accessibilityIdentifier(identifier ?? "")
    }
}

/// The row's look, shared with rows that aren't plain buttons (the Share link).
struct SheetActionRowLabel: View {
    let symbol: String
    let label: String
    var value: String?
    var tint: Color?
    var accent: Color = .accentColor
    var enabled = true
    var trailing: AnyView?

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle((tint ?? .primary).opacity(enabled ? 1 : 0.4))
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(label)
                .font(CollectionsType.body)
                .foregroundStyle(Color.primary.opacity(enabled ? 1 : 0.4))
                .frame(maxWidth: .infinity, alignment: .leading)
            if let value {
                Text(value)
                    .font(CollectionsType.body)
                    .foregroundStyle(accent.opacity(enabled ? 1 : 0.4))
                    .lineLimit(1)
            }
            if let trailing { trailing }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

/// A highlight while pressed, the way a menu row answers a touch.
struct SheetRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.08 : 0))
    }
}

/// The track a sheet is about, at its head (SongActionsSheet.kt's SheetTrackHeader).
struct SheetTrackHeader: View {
    let song: Song
    var subtitleColor: Color = .secondary

    var body: some View {
        HStack(spacing: 14) {
            ArtworkImage(song: song, pixels: ArtworkSize.row, cornerRadius: AppTheme.artCorner)
                .artworkFrame(52, cornerRadius: AppTheme.artCorner)
            VStack(alignment: .leading, spacing: 2) {
                ExplicitSongTitle(song: song, font: CollectionsType.title)
                Text(song.artist)
                    .font(CollectionsType.bodySmall)
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The heading over a sheet's second half — "ADD TO PLAYLIST" (SongActionsSheet.kt's SheetHeading).
struct SheetHeading: View {
    let text: String

    var body: some View {
        // As given: only "Who can see it" is set in capitals, by its caller (PlaylistPickerSheet.kt).
        Text(text)
            .font(CollectionsType.label)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A hairline between a sheet's groups.
struct SheetDivider: View {
    var color: Color = Color(.separator)
    var vertical: CGFloat = 0

    var body: some View {
        Rectangle().fill(color).frame(height: 0.5).padding(.vertical, vertical).accessibilityHidden(true)
    }
}

/// A panel's title row with a back button (the sleep-timer, new-playlist and rename panels).
struct SheetPanelHeader: View {
    let title: String
    var subtitle: String?
    var onBack: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.back)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(CollectionsType.titleLarge)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(CollectionsType.bodySmall)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, onBack == nil ? 22 : 8)
        .padding(.trailing, 22)
        .padding(.bottom, 8)
        .padding(.top, 8)
    }
}

/// The sheet wearing the artwork's colours (SongActionsSheet.kt's TintedSheet): the page tint with
/// the sleeve blurred into it.
struct TintedSheetBackground: View {
    let artwork: String?
    let palette: ArtworkPalette

    var body: some View {
        ZStack {
            palette.backgroundColor
            GeometryReader { proxy in
                ArtworkImage(artwork, pixels: ArtworkSize.row, cornerRadius: 0)
                    .frame(width: proxy.size.width, height: proxy.size.width)
                    .blur(radius: 50, opaque: true)
                    .opacity(0.55)
                    .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
            }
            LinearGradient(stops: [
                .init(color: palette.wash.withAlpha(0.35).color, location: 0),
                .init(color: palette.background.color, location: 0.75),
            ], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// A rounded name field (Common.kt's PillTextField as the playlist forms use it).
struct PillNameField: View {
    let placeholder: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var showsClear = true
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $text)
                .font(CollectionsType.body)
                .focused(focused)
                .submitLabel(.done)
                .onSubmit(onSubmit)
                .accessibilityIdentifier("playlist.nameField")
            if showsClear && !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.clearName)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }
}

/// The rename panel of the release menu, which swaps itself in rather than opening a dialog over
/// the sheet (PlaylistPickerSheet.kt's RenamePlaylistForm).
struct RenamePlaylistForm: View {
    let playlist: UserPlaylist
    let onBack: () -> Void
    let onRename: (String) -> Void

    @State private var name: String
    @FocusState private var focused: Bool

    init(playlist: UserPlaylist, onBack: @escaping () -> Void, onRename: @escaping (String) -> Void) {
        self.playlist = playlist
        self.onBack = onBack
        self.onRename = onRename
        _name = State(initialValue: playlist.title)
    }

    private var canSave: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && name != playlist.title
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetPanelHeader(title: L10n.renamePlaylist, onBack: onBack)
            SheetDivider()
            PillNameField(placeholder: L10n.playlistName, text: $name, focused: $focused, showsClear: false, onSubmit: submit)
            Button(action: submit) {
                Text(L10n.saveName).font(CollectionsType.title).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .disabled(!canSave)
            .padding(.horizontal, 22)
            .accessibilityIdentifier("playlist.saveName")
            Spacer(minLength: 28)
        }
        // The form exists to be typed into.
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sheet.renamePlaylist")
    }

    private func submit() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        focused = false
        onRename(name)
    }
}

extension View {
    /// The app language's reading direction. A sheet is presented outside the root view that sets
    /// it, so without this a Hebrew menu over a mirrored page reads left to right.
    func inAppLayoutDirection() -> some View {
        environment(\.layoutDirection, LanguageBundle.layoutDirection)
    }
}
