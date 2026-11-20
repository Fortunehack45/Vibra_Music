import VibraMusicCore
import PlaybackQueue
import SwiftUI

/// The album or playlist menu (ports ui/components/BrowseActionsSheet.kt, with the callbacks
/// MainActivity.kt wires into it).
///
/// Opened by holding a card anywhere, or from a release page's own More circle. From a card: Play,
/// Shuffle, Play next, Add to queue, Download all, Open, Share, Pin; from the page itself Play,
/// Shuffle and Open are the buttons beside the one that opened it, so they are left off. The
/// account's own playlists add Rename (a panel in place) and Delete (asked a second time, in place:
/// the one loss in the app a second tap can't undo); a release downloaded whole adds Delete download.
/// Every row closes the menu first — the tracks may still have to be fetched.
struct BrowseActionsSheet: View {
    let item: BrowseItem

    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var confirmingDelete = false
    @State private var confirmingDeleteDownload = false

    private var store: CollectionsStore { CollectionsStore.shared(for: model) }

    /// The page's own rows, when the page's More circle opened this (see
    /// ``CollectionsStore/pageMenuContext``).
    private var context: [Song]? {
        guard let pending = store.pageMenuContext, pending.browseId == item.browseId else { return nil }
        return pending.songs
    }

    /// False when opened from the page it would navigate to (BrowseTarget's `fromCard`).
    private var fromCard: Bool { context == nil }
    private var songs: [Song] { context ?? [] }
    private var remote: Bool { !LocalBrowseID.isLocal(item.browseId) }
    /// Whose playlist this is, read live: only a playlist the account made can be renamed or deleted,
    /// and the answer for a card arrives after the sheet is up.
    private var playlist: UserPlaylist? {
        store.service.isSignedIn ? store.editablePlaylist(item.browseId) : nil
    }
    private var pinnableId: String? { item.type == .playlist ? item.browseId : nil }
    private var downloadId: String? { store.service.downloadRecordId(for: item.browseId) }

    init(item: BrowseItem) {
        self.item = item
    }

    var body: some View {
        Group {
            if renaming, let playlist {
                RenamePlaylistForm(playlist: playlist, onBack: { renaming = false }) { name in
                    close()
                    Task { await store.renamePlaylist(playlist, to: name) }
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) { rows }
                        .padding(.top, 12)
                        .padding(.bottom, 24)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .presentationDragIndicator(.visible)
        .onDisappear { store.pageMenuContext = nil }
        .task(id: item.browseId) {
            await store.loadPlaylistsIfNeeded()
            await store.resolvePlaylistOwnership(item.browseId)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sheet.browseActions")
        .inAppLayoutDirection()
    }

    @ViewBuilder
    private var rows: some View {
        BrowseSheetHeader(item: item, songCount: songs.count)
        SheetDivider()
        if fromCard {
            SheetActionRow(symbol: AppSymbol.play, label: L10n.play, identifier: "browseActions.play") {
                act { player.play($0, startAt: 0, source: source) }
            }
            SheetActionRow(symbol: AppSymbol.shuffle, label: L10n.shuffle, identifier: "browseActions.shuffle") {
                // Shuffle goes on before the queue is built, so it is built shuffled.
                act { player.shufflePlay($0, source: source) }
            }
        }
        SheetActionRow(symbol: AppSymbol.playNext, label: L10n.playNext, identifier: "browseActions.playNext") {
            act { player.playNext($0) }
        }
        SheetActionRow(symbol: AppSymbol.addToQueue, label: L10n.addToQueue, identifier: "browseActions.addToQueue") {
            act { player.addToQueue($0) }
        }
        if remote {
            downloadAllRow
        }
        if fromCard {
            SheetActionRow(symbol: AppSymbol.chevronRight, label: DetailText.openLabel(of: item.type), identifier: "browseActions.open") {
                close()
                model.router.open(AppRoute.item(item))
            }
        }
        if remote, item.type == .album || item.type == .playlist, let url = DetailText.shareURL(browseId: item.browseId, type: item.type) {
            ShareLink(item: url, subject: Text(item.title)) {
                SheetActionRowLabel(symbol: AppSymbol.share, label: L10n.share)
            }
            .buttonStyle(SheetRowButtonStyle())
            .accessibilityIdentifier("browseActions.share")
        }
        if let pinnableId {
            let pinned = settings.pinnedPlaylists.contains(pinnableId)
            SheetActionRow(symbol: pinned ? "pin.slash" : AppSymbol.pin, label: pinned ? L10n.unpin : L10n.pin, identifier: "browseActions.pin") {
                // Pinning touches only this device's Library order, never the account. Past the cap
                // it is refused rather than evicting a pin made on purpose.
                let nowPinned = settings.togglePinnedPlaylist(pinnableId)
                if !nowPinned && !pinned {
                    player.notice = QueueNotice(message: L10n.pinnedPlaylistLimit(AppSettings.maxPinnedPlaylists), symbol: AppSymbol.pin)
                }
                close()
            }
        }
        if playlist != nil {
            SheetActionRow(symbol: "pencil", label: L10n.rename, identifier: "browseActions.rename") { renaming = true }
            if confirmingDelete {
                SheetActionRow(symbol: "trash.fill", label: L10n.deletePlaylistConfirmation(item.title), tint: .red,
                               identifier: "browseActions.confirmDelete") {
                    guard let playlist else { return }
                    close()
                    Task { await store.deletePlaylist(playlist) }
                }
            } else {
                SheetActionRow(symbol: "trash", label: L10n.deletePlaylist, identifier: "browseActions.delete") {
                    withAnimation { confirmingDelete = true }
                }
            }
        }
        if let downloadId {
            if confirmingDeleteDownload {
                SheetActionRow(symbol: "trash.fill", label: L10n.deleteDownloadConfirmation(item.title), tint: .red,
                               identifier: "browseActions.confirmDeleteDownload") {
                    close()
                    store.service.deleteDownloadedCollection(downloadId)
                }
            } else {
                SheetActionRow(symbol: "trash", label: L10n.deleteDownload, identifier: "browseActions.deleteDownload") {
                    withAnimation { confirmingDeleteDownload = true }
                }
            }
        }
    }

    /// Says which of the three it is — this is where a release is downloaded from, and a menu that
    /// can't say "already on the device" leaves the question open. The tap is live in every state:
    /// the queue leaves a saved, queued or running track alone.
    private var downloadAllRow: some View {
        let service = store.service
        let waiting = service.releaseIsDownloading(item.browseId)
        // Every one of its tracks saved; unknown (not "no") for a card whose page was never opened.
        let downloaded = !waiting && !songs.isEmpty && songs.allSatisfy { service.isDownloaded($0.videoId) }
        return SheetActionRow(
            symbol: waiting ? AppSymbol.clock : downloaded ? AppSymbol.check : AppSymbol.download,
            label: L10n.downloadAll,
            value: waiting ? L10n.downloading : downloaded ? L10n.downloaded : nil,
            identifier: "browseActions.downloadAll"
        ) {
            act { store.downloadAll($0, item: item) }
        }
    }

    private var source: QueueSource {
        QueueSource(title: item.title, type: .browse, id: item.browseId)
    }

    /// Closes the menu, then hands `action` the release's tracks (fetched first for a card).
    private func act(_ action: @escaping ([Song]) -> Void) {
        let known = songs
        close()
        Task {
            switch await store.songs(for: item, known: known) {
            case .success(let tracks): action(tracks)
            case .failure(let error): store.notify(error.text, AppSymbol.error)
            }
        }
    }

    private func close() {
        model.router.dismissSheet()
        dismiss()
    }
}

/// Which release the sheet is about: the same row the card was (BrowseActionsSheet.kt's
/// BrowseSheetHeader). A card with no subtitle says what kind of thing it is, or failing that how
/// many tracks it has.
struct BrowseSheetHeader: View {
    let item: BrowseItem
    let songCount: Int

    var body: some View {
        HStack(spacing: 14) {
            ArtworkImage(item.thumbnailUrl, pixels: ArtworkSize.row, cornerRadius: item.type == .artist ? 26 : AppTheme.artCorner)
                .artworkFrame(52, cornerRadius: item.type == .artist ? 26 : AppTheme.artCorner)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(CollectionsType.title)
                    .lineLimit(1)
                Text(subtitle)
                    .font(CollectionsType.bodySmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var subtitle: String {
        if !item.subtitle.isEmpty { return item.subtitle }
        if let noun = DetailText.label(of: item.type) { return noun.capitalized(with: LanguageBundle.locale) }
        return songCount > 0 ? L10n.songCountPlural(songCount) : ""
    }
}
