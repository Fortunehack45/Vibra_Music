import VibraMusicCore
import SwiftUI

/// Where a track goes: one of the account's playlists, or a new one (ports
/// ui/components/PlaylistPickerSheet.kt, with the callbacks MainActivity.kt wires into it).
///
/// Two panels in one sheet: creating a playlist here is nearly always in service of adding the track
/// that opened it, so the form comes back to the same place and the create request carries the
/// track. Opened with no tracks — the Library's New playlist tile — it goes straight to the form.
///
/// Playlists are ticked rather than picked: one track often belongs in more than one list, and a
/// sheet that closed on the first tap meant opening it again for each. The button adds to every
/// ticked playlist at once.
struct PlaylistPickerSheet: View {
    let songs: [Song]

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var creating: Bool
    @State private var selection = PlaylistPickerSelection()

    private var store: CollectionsStore { CollectionsStore.shared(for: model) }

    init(songs: [Song]) {
        self.songs = songs
        _creating = State(initialValue: songs.isEmpty)
    }

    var body: some View {
        Group {
            if creating {
                NewPlaylistForm(onBack: songs.isEmpty ? nil : { creating = false }) { title, privacy in
                    let seeds = songs
                    close()
                    Task { await store.createPlaylist(title: title, privacy: privacy, songs: seeds) }
                }
            } else {
                picker
            }
        }
        .presentationDragIndicator(.visible)
        .task { await store.loadPlaylists() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sheet.playlistPicker")
        .inAppLayoutDirection()
    }

    private var picker: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let song = songs.first {
                    SheetTrackHeader(song: song)
                    SheetDivider()
                }
                SheetHeading(text: songs.isEmpty ? L10n.yourPlaylists : L10n.addToPlaylist)
                SheetActionRow(symbol: AppSymbol.plus, label: L10n.newPlaylist, identifier: "picker.newPlaylist") {
                    creating = true
                }
                if store.playlistsLoading && store.playlists.isEmpty {
                    // Only while there is nothing to show: a refetch under a list already up would
                    // swap it for a spinner for no gain.
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                } else if store.playlists.isEmpty {
                    Text(L10n.noPlaylistsYet)
                        .font(CollectionsType.bodySmall)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 18)
                } else {
                    SheetDivider(vertical: 6)
                    ForEach(store.playlists) { playlist in
                        PlaylistRow(playlist: playlist, selected: selection.isTicked(playlist.playlistId)) {
                            selection.toggle(playlist.playlistId)
                        }
                    }
                    Button(action: addTicked) {
                        Text(selection.buttonTitle)
                            .font(CollectionsType.title)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
                    .disabled(selection.isEmpty)
                    .padding(.horizontal, 22)
                    .padding(.top, 12)
                    .accessibilityIdentifier("picker.add")
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// One line for the whole batch, saying the outcome that matters most (MainActivity's `onAdd`).
    private func addTicked() {
        let picked = selection.picked(from: store.playlists)
        let adding = songs
        close()
        guard !adding.isEmpty else { return }
        Task {
            guard let result = await store.addToPlaylists(picked, songs: adding) else { return }
            store.notify(
                PlaylistBatchNotice.text(added: result.added, alreadyThere: result.alreadyThere, failed: result.failed),
                AppSymbol.playlistAdd
            )
        }
    }

    private func close() {
        model.router.dismissSheet()
        dismiss()
    }
}

/// The sheet's ticked rows, kept by playlist id so a refreshed list keeps its ticks
/// (PlaylistPickerSheet.kt's `selected`).
struct PlaylistPickerSelection: Equatable {
    private(set) var ticked: Set<String> = []

    init() {}

    var isEmpty: Bool { ticked.isEmpty }

    func isTicked(_ playlistId: String) -> Bool { ticked.contains(playlistId) }

    mutating func toggle(_ playlistId: String) {
        if ticked.contains(playlistId) {
            ticked.remove(playlistId)
        } else {
            ticked.insert(playlistId)
        }
    }

    /// "Add to playlist" until something is ticked, then the count.
    var buttonTitle: String {
        isEmpty ? L10n.addToPlaylist : L10n.addToPlaylistsCount(ticked.count)
    }

    /// The ticked playlists in the list's order — the order they are added in.
    func picked(from playlists: [UserPlaylist]) -> [UserPlaylist] {
        playlists.filter { isTicked($0.playlistId) }
    }
}

private struct PlaylistRow: View {
    let playlist: UserPlaylist
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ArtworkImage(playlist.thumbnailUrl, pixels: ArtworkSize.row, cornerRadius: 7)
                    .artworkFrame(44, cornerRadius: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(playlist.title)
                        .font(CollectionsType.body)
                        .lineLimit(1)
                    if !playlist.subtitle.isEmpty {
                        Text(playlist.subtitle)
                            .font(CollectionsType.bodySmall)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(SheetRowButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("picker.playlist")
    }
}

/// Name and visibility, and nothing else (PlaylistPickerSheet.kt's NewPlaylistForm): YouTube also
/// takes a description, which nobody fills in from a phone at the moment of saving a song.
struct NewPlaylistForm: View {
    /// Nil when the sheet opened straight onto the form: its own dismiss is the way out.
    let onBack: (() -> Void)?
    let onCreate: (String, PlaylistPrivacy) -> Void

    @State private var name = ""
    @State private var privacy: PlaylistPrivacy = .private
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                SheetPanelHeader(title: L10n.newPlaylist, subtitle: L10n.savedToYoutubeMusicAccount, onBack: onBack)
                SheetDivider()
                PillNameField(placeholder: L10n.playlistName, text: $name, focused: $focused, onSubmit: submit)
                SheetHeading(text: L10n.whoCanSeeIt.uppercased(with: LanguageBundle.locale))
                HStack(spacing: 8) {
                    ForEach(PlaylistPrivacy.allCases, id: \.self) { option in
                        PrivacyPill(option: option, selected: option == privacy) { privacy = option }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 4)
                Button(action: submit) {
                    Text(L10n.createPlaylist).font(CollectionsType.title).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .accessibilityIdentifier("playlist.create")
            }
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .scrollBounceBehavior(.basedOnSize)
        // Opened to be typed into: the keyboard comes up with it.
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sheet.newPlaylist")
    }

    private func submit() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        focused = false
        onCreate(name, privacy)
    }
}

/// A visibility choice with the glyph that says what it means — a padlock, a shared link, a globe.
private struct PrivacyPill: View {
    let option: PlaylistPrivacy
    let selected: Bool
    let action: () -> Void

    private var symbol: String {
        switch option {
        case .private: return "lock.fill"
        case .unlisted: return "link"
        case .public: return "globe"
        }
    }

    var body: some View {
        Button {
            Haptics.shared.play(.select)
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                // Android labels these with the enum's own English words too (Models.kt).
                Text(option.label).font(CollectionsType.title)
            }
            .foregroundStyle(selected ? Color.white : Color.secondary)
            .padding(.leading, 11)
            .padding(.trailing, 14)
            .padding(.vertical, 7)
            .background(selected ? Color.accentColor : Color(.secondarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("privacy.\(option.rawValue)")
    }
}
