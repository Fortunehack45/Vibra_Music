import VibraMusicCore
import Downloads
import InnerTube
import Playback
import PlaybackPolicy
import SwiftUI
import Theming

/// The song menu (ports ui/components/SongActionsSheet.kt, with the callbacks MainActivity.kt wires
/// into it).
///
/// Painted in the track's own colours. From the top: the track; the player's version rows (revert /
/// upgrade quality, song ↔ video — only for the playing track opened from the player); the account
/// rows (like, dislike, add to playlist, remove from this playlist on an editable playlist page) —
/// hidden signed out and for a file on the device, which has no YouTube identity to rate; the
/// download row carrying the download's whole life; start radio, play next, add to queue; open
/// album and open artist when the track knows them (resolved on the fly from the player); the
/// player's sleep timer and lyrics offset; share; and the player's copy-log row.
struct SongActionsSheet: View {
    let song: Song

    @Environment(AppModel.self) private var model
    @Environment(PlayerController.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var pickingSleepTimer = false
    @State private var links: Song?
    @State private var resolvingLinks = false

    private var store: CollectionsStore { CollectionsStore.shared(for: model) }

    /// "Opened from the player": the player is up and this is its track. Only that copy of the menu
    /// carries the player's rows (sleep timer, lyrics offset, versions, the log).
    private var fromPlayer: Bool {
        model.router.nowPlaying.isPresented && player.currentSong?.videoId == song.videoId
    }

    /// A local file or a finished download has no YouTube identity to rate, save, fetch again or
    /// share a link for.
    private var isOffline: Bool { song.localUri != nil }

    private var albumId: String? { nonEmpty(song.albumId) ?? nonEmpty(links?.albumId) }
    private var artistId: String? { nonEmpty(song.artistId) ?? nonEmpty(links?.artistId) }

    var body: some View {
        ArtworkPaletteReader(artwork: song.thumbnailUrl, artPixels: ArtworkSize.row) { palette in
            ScrollView {
                VStack(spacing: 0) {
                    if pickingSleepTimer {
                        SleepTimerPicker(accent: palette.accentColor, divider: palette.dividerColor) { pickingSleepTimer = false }
                    } else {
                        rows(palette: palette)
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .presentationBackground { TintedSheetBackground(artwork: song.thumbnailUrl, palette: palette) }
            .presentationDragIndicator(.visible)
            .tint(palette.accentColor)
        }
        .task(id: song.videoId) {
            // The rating the menu shows is refreshed from YouTube as it opens.
            await store.loadSongMenu(song.videoId)
        }
        .task(id: song.videoId) { await resolveLinksIfNeeded() }
        .onDisappear {
            // A failure is worth stating once, not again next week.
            if case .failed = store.service.downloadState(song.videoId) { store.service.dismissDownloadFailure(song.videoId) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sheet.songActions")
        .inAppLayoutDirection()
    }

    @ViewBuilder
    private func rows(palette: ArtworkPalette) -> some View {
        SheetTrackHeader(song: song, subtitleColor: palette.onBackgroundVariantColor)
        SheetDivider(color: palette.dividerColor)

        versionRows(palette: palette)

        if store.service.isSignedIn && !isOffline {
            let status = player.likeStatus(of: song)
            let liked = status == .like
            let disliked = status == .dislike
            SheetActionRow(symbol: liked ? AppSymbol.heartFilled : AppSymbol.heart, label: liked ? L10n.removeFromLiked : L10n.like,
                           tint: liked ? palette.accentColor : nil, accent: palette.accentColor, identifier: "songActions.like") {
                // The sheet stays up for a rating: it shows the new state in place.
                Haptics.shared.play(liked ? .toggleOff : .toggleOn)
                let next = player.toggleLike(song)
                Task { await store.ratingChanged(song.videoId, from: status, to: next) }
            }
            SheetActionRow(symbol: disliked ? AppSymbol.dislikeFilled : AppSymbol.dislike,
                           label: disliked ? L10n.undoDislike : L10n.dislike,
                           tint: disliked ? palette.accentColor : nil, accent: palette.accentColor, identifier: "songActions.dislike") {
                Haptics.shared.play(disliked ? .toggleOff : .toggleOn)
                // Disliking the song that is playing skips it (the player's DislikeSkipPolicy).
                let next = player.toggleDislike(song)
                Task { await store.ratingChanged(song.videoId, from: status, to: next) }
            }
            SheetActionRow(symbol: AppSymbol.playlistAdd, label: L10n.addToPlaylist, accent: palette.accentColor,
                           identifier: "songActions.addToPlaylist") {
                // The picker is the next step, replacing this sheet rather than stacking on it.
                model.router.present(.playlistPicker([song]))
            }
            if let editable = editablePlaylist {
                SheetActionRow(symbol: "text.badge.minus", label: L10n.removeFromPlaylist, accent: palette.accentColor,
                               identifier: "songActions.removeFromPlaylist") {
                    close()
                    Task { await store.removeFromPlaylist(editable.browseId, song: song) }
                }
            }
            SheetDivider(color: palette.dividerColor, vertical: 6)
        }

        SongDownloadRow(song: song, isOffline: isOffline, accent: palette.accentColor)
        SheetActionRow(symbol: AppSymbol.radio, label: L10n.startRadio, accent: palette.accentColor, identifier: "songActions.radio") {
            close()
            Task { await player.startRadio(from: song) }
        }
        SheetActionRow(symbol: AppSymbol.playNext, label: L10n.playNext, accent: palette.accentColor, identifier: "songActions.playNext") {
            close()
            player.playNext([song])
        }
        SheetActionRow(symbol: AppSymbol.addToQueue, label: L10n.addToQueue, accent: palette.accentColor, identifier: "songActions.addToQueue") {
            close()
            player.addToQueue([song])
        }
        if let albumId {
            SheetActionRow(symbol: AppSymbol.album, label: L10n.openAlbum, accent: palette.accentColor, identifier: "songActions.openAlbum") {
                // The track's cover stands in for the album's until the page loads its own.
                openPage(.album(browseId: albumId, seed: BrowseItem(browseId: albumId, title: song.albumName ?? song.title,
                                                                     subtitle: song.artist, thumbnailUrl: song.thumbnailUrl, type: .album)))
            }
        } else if resolvingLinks {
            loadingRow(symbol: AppSymbol.album, label: L10n.openAlbum, palette: palette)
        }
        if let artistId {
            SheetActionRow(symbol: "person", label: L10n.openArtist, accent: palette.accentColor, identifier: "songActions.openArtist") {
                // Never the track's cover for an artist: that page loads its own picture.
                openPage(.artist(browseId: artistId, seed: BrowseItem(browseId: artistId, title: song.artist, subtitle: L10n.artist,
                                                                       thumbnailUrl: nil, type: .artist)))
            }
        } else if resolvingLinks {
            loadingRow(symbol: "person", label: L10n.openArtist, palette: palette)
        }
        if fromPlayer {
            SheetActionRow(symbol: AppSymbol.sleepTimer, label: L10n.sleepTimer, value: sleepTimerStatus,
                           accent: palette.accentColor, identifier: "songActions.sleepTimer") {
                pickingSleepTimer = true
            }
            // Local files use the same lyric clock, so this sits outside the online-only rows.
            SheetActionRow(symbol: "slider.horizontal.3", label: L10n.lyricsOffset, accent: palette.accentColor,
                           identifier: "songActions.lyricsOffset") {
                model.router.present(.lyricsOffset)
            }
        }
        if !isOffline, !song.videoId.isEmpty, let url = DetailText.shareURL(videoId: song.videoId) {
            ShareLink(item: url, subject: Text(song.title)) {
                SheetActionRowLabel(symbol: AppSymbol.share, label: L10n.share, accent: palette.accentColor)
            }
            .buttonStyle(SheetRowButtonStyle())
            .accessibilityIdentifier("songActions.share")
        }
        if fromPlayer {
            // Last, and only from the player: it is about the track playing now.
            SheetActionRow(symbol: "ladybug", label: L10n.copyLog, accent: palette.accentColor, identifier: "songActions.copyLog") {
                let text = TrackLog.shared.forTrack(song)
                UIPasteboard.general.string = text
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
                player.notice = QueueNotice(message: L10n.logCopiedLineCount(lines), symbol: nil)
                close()
            }
        }
    }

    /// The version rows: which recording is playing, answered before anything else on the menu.
    @ViewBuilder
    private func versionRows(palette: ArtworkPalette) -> some View {
        let quality = PlayerQualityMenu.row(
            for: song, openedFromPlayer: fromPlayer,
            currentItem: player.currentSong.map { PlayerQualityMenu.CurrentItem(mediaId: $0.videoId, playbackURI: nil) }
        )
        // Offered from the player outside a party (every member plays the same cut). Android showed
        // it only once the other cut was known to exist; the iOS player looks for it when asked and
        // says so if there is none.
        let offersVersion = fromPlayer && !player.isInParty && !isOffline
        if quality != nil || offersVersion {
            switch quality {
            case .revertToOriginal:
                SheetActionRow(symbol: "arrow.uturn.backward", label: L10n.revertToOriginal, accent: palette.accentColor) {
                    player.revertToOriginal()
                    close()
                }
            case .upgradeQuality(let enabled):
                SheetActionRow(symbol: "sparkles", label: L10n.upgradeQuality, accent: palette.accentColor, enabled: enabled) {
                    player.upgradeQuality()
                    close()
                }
            case nil:
                EmptyView()
            }
            if offersVersion {
                SheetActionRow(symbol: song.isVideo ? AppSymbol.musicNote : "video",
                               label: song.isVideo ? L10n.convertToAudio : L10n.convertToVideo, accent: palette.accentColor) {
                    close()
                    Task { await player.switchVersion() }
                }
            }
            SheetDivider(color: palette.dividerColor, vertical: 6)
        }
    }

    private func loadingRow(symbol: String, label: String, palette: ArtworkPalette) -> some View {
        SheetActionRowLabel(symbol: symbol, label: label, enabled: false, trailing: AnyView(ProgressView().controlSize(.small)))
    }

    /// "Remove from this playlist": only on a playlist page the account can edit, for a row that
    /// carries the per-entry id a removal is expressed in, and never from the player.
    private var editablePlaylist: UserPlaylist? {
        guard !fromPlayer, song.setVideoId != nil else { return nil }
        guard let top = model.router.path(for: model.router.selectedTab).last, case .playlist(let browseId, _) = top else { return nil }
        return store.editablePlaylist(browseId)
    }

    private var sleepTimerStatus: String? {
        guard let timer = player.sleepTimer else { return nil }
        if timer.afterTrack { return L10n.afterThisSong }
        guard let remaining = player.sleepTimerRemaining else { return nil }
        let seconds = Int(remaining.rounded(.up))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Only the player's copy of a track is ever missing its album and artist ids and backfills them
    /// — a row opened from a list already has whatever it will ever have.
    private func resolveLinksIfNeeded() async {
        guard fromPlayer, !isOffline, song.albumId == nil || song.artistId == nil else { return }
        resolvingLinks = true
        links = try? await model.repository.trackLinks(videoId: song.videoId)
        resolvingLinks = false
    }

    private func close() {
        model.router.dismissSheet()
        dismiss()
    }

    /// Navigating takes the player down with the sheet, or the page lands behind a still-covering
    /// player.
    private func openPage(_ route: AppRoute) {
        close()
        model.router.nowPlaying.close()
        model.router.open(route)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

/// One row carrying the whole life of a download (SongActionsSheet.kt's DownloadRow): start it,
/// watch it, cancel it, delete what it produced. A failure stays legible as a failure whatever the
/// sleeve is tinted.
struct SongDownloadRow: View {
    let song: Song
    let isOffline: Bool
    let accent: Color

    @Environment(AppModel.self) private var model

    var body: some View {
        let store = CollectionsStore.shared(for: model)
        let service = store.service
        switch service.downloadState(song.videoId) {
        case .queued:
            // Held for Wi-Fi says why it sits still; a plain "Queued" on a stuck row reads as
            // broken (Android says it in the tap's toast; the row carries it here).
            SheetActionRow(symbol: "arrow.down.circle.dotted",
                           label: DownloadNotice.queuedRowLabel(waitingForWiFi: service.isWaitingForWiFi),
                           value: L10n.cancel, accent: accent,
                           identifier: "songActions.download") {
                service.cancelDownload(song.videoId)
            }
        case .running(let fraction):
            // Indeterminate until the first response names a length: a stuck "0%" reads as broken.
            SheetActionRow(symbol: "arrow.down.circle.dotted", label: L10n.downloadNotificationTitle,
                           value: fraction > 0 ? "\(Int(fraction * 100))%" : nil, tint: accent, accent: accent,
                           identifier: "songActions.download") {
                service.cancelDownload(song.videoId)
            }
        case .failed(let reason):
            SheetActionRow(symbol: "exclamationmark.circle", label: reason, value: L10n.retry, tint: .red, accent: .red,
                           identifier: "songActions.download") {
                store.download(song)
            }
        case nil:
            if service.isDownloaded(song.videoId) {
                SheetActionRow(symbol: AppSymbol.downloaded, label: L10n.savedToDownloads, value: L10n.delete, tint: accent, accent: accent,
                               identifier: "songActions.download") {
                    service.deleteDownload(song.videoId)
                }
            } else if !isOffline {
                SheetActionRow(symbol: AppSymbol.download, label: L10n.download, accent: accent, identifier: "songActions.download") {
                    // Stays open: the row it turns into is the progress.
                    store.download(song)
                }
            }
        }
    }
}

/// End of track or a duration, and a way out once one is running (SongActionsSheet.kt's
/// SleepTimerPicker). "After this song" leads: it is the one people reach for at the end of a listen.
struct SleepTimerPicker: View {
    let accent: Color
    let divider: Color
    let onBack: () -> Void

    @Environment(PlayerController.self) private var player

    var body: some View {
        let timer = player.sleepTimer
        VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                SheetPanelHeader(title: L10n.sleepTimer, subtitle: subtitle(timer), onBack: onBack)
            }
            SheetDivider(color: divider)
            option(L10n.afterThisSong, selected: timer?.afterTrack == true) {
                player.startSleepTimerAfterTrack()
            }
            ForEach(SleepTimerRequest.presetMinutes, id: \.self) { minutes in
                presetOption(minutes, timer: timer)
            }
            if timer != nil {
                SheetActionRow(symbol: AppSymbol.close, label: L10n.turnOffTimer, accent: accent, identifier: "sleepTimer.off") {
                    player.cancelSleepTimer()
                    onBack()
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sheet.sleepTimer")
    }

    private func subtitle(_ timer: SleepTimerState?) -> String {
        if let remaining = player.sleepTimerRemaining {
            let seconds = Int(remaining.rounded(.up))
            return L10n.pauseCountdown(String(format: "%d:%02d", seconds / 60, seconds % 60))
        }
        return timer?.afterTrack == true ? L10n.pauseAfterSong : L10n.pauseAfterAWhile
    }

    private func presetOption(_ minutes: Int, timer: SleepTimerState?) -> some View {
        let label: String = minutes == 60 ? L10n.oneHour : L10n.minuteCount(minutes)
        let selected: Bool = timer?.presetMinutes == minutes && timer?.afterTrack != true
        return option(label, selected: selected) { player.startSleepTimer(minutes: minutes) }
    }

    private func option(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.shared.play(.select)
            action()
            onBack()
        } label: {
            HStack {
                Text(label).font(CollectionsType.body)
                Spacer()
                if selected {
                    Image(systemName: AppSymbol.check)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(accent)
                        .accessibilityLabel(L10n.running)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(SheetRowButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
