import VibraMusicCore
import Downloads
import SwiftUI

/// Ports ui/components/DownloadManagerSheet.kt: every track asked for this sitting, what became of
/// it, and a way out of the ones still going.
///
/// A list rather than a single line because the thing being reported on is a batch: forty tracks
/// were asked for, which of them arrived. Rows carry the cover, the title and the credit, because a
/// batch download is precisely when a user can't tell from a name whether the right thing is being
/// fetched. Closing the sheet marks the batch seen, which is what takes the top-bar indicator down.
struct DownloadManagerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let context = DownloadsContext.shared(for: model)
        DownloadManagerList(session: context.service.session,
                            waitingForWiFi: context.service.isWaitingForWiFi,
                            onCancel: { context.service.cancelDownload($0) },
                            onRetry: { context.service.retryDownload($0) },
                            onClose: { dismiss() })
            .onDisappear { context.service.session.markSeen() }
    }
}

/// The sheet's body, over a session and the two row actions (so it can be drawn in tests).
struct DownloadManagerList: View {
    let session: DownloadSession
    var waitingForWiFi = false
    let onCancel: (String) -> Void
    let onRetry: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        let state = session.state
        // Newest ask last, the order the queue will actually reach them in.
        let items = state.items.sorted { $0.sequence < $1.sequence }
        VStack(spacing: 0) {
            header(state, items: items)
            // The batch's own bar, under the heading it belongs to: the per-row bars are about one
            // track each; this one answers "how much longer".
            if state.busy {
                ProgressView(value: state.fraction)
                    .tint(.accentColor)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                    .accessibilityLabel(L10n.downloadsProgress(Int(state.fraction * 100)))
                    .accessibilityIdentifier("downloadManager.progress")
            }
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        DownloadManagerRow(item: item,
                                           waitingForWiFi: waitingForWiFi,
                                           onCancel: { onCancel(item.videoId) },
                                           onRetry: { onRetry(item.videoId) })
                    }
                }
                .padding(.bottom, 24)
            }
        }
        .padding(.top, 20)
        .presentationDragIndicator(.visible)
        .environment(\.layoutDirection, LanguageBundle.layoutDirection)
        .accessibilityIdentifier("sheet.downloadManager")
    }

    private func header(_ state: DownloadSession.State, items: [DownloadSession.Item]) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.downloads)
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(DownloadManagerSummary.text(for: state))
                    .font(.subheadline)
                    .foregroundStyle(state.failed > 0 && !state.busy ? Color.red : .secondary)
                    .accessibilityIdentifier("downloadManager.summary")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if state.busy {
                Button(L10n.cancelAll) {
                    // Only what is still going. Cancelling a finished row would drop it from the
                    // list, which is the one thing this sheet exists to still be showing.
                    items.filter { !$0.progress.settled }.forEach { onCancel($0.videoId) }
                }
                .accessibilityIdentifier("downloadManager.cancelAll")
            } else {
                Button(L10n.clear) {
                    session.clear()
                    onClose()
                }
                .accessibilityIdentifier("downloadManager.clear")
            }
        }
        .font(.body.weight(.semibold))
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .padding(.bottom, 8)
    }
}

/// The one line under the heading — what state the batch as a whole is in. Counts rather than a
/// percentage: the bar already draws the percentage, and what it can't say is that thirty-nine of
/// forty arrived and one did not, which is the only outcome anybody needs to act on.
enum DownloadManagerSummary {
    static func text(for state: DownloadSession.State) -> String {
        var parts: [String] = []
        if state.waiting > 0 { parts.append(L10n.downloadWaitingCount(state.waiting)) }
        if state.finished > 0 { parts.append(L10n.downloadDoneCount(state.finished)) }
        if state.failed > 0 { parts.append(L10n.downloadFailedCount(state.failed)) }
        if parts.isEmpty { return L10n.nothingDownloading }
        if state.busy || state.failed > 0 { return parts.joined(separator: " · ") }
        return L10n.allSongsDownloaded(state.finished)
    }

    /// The row's status line.
    static func status(of progress: DownloadProgress, waitingForWiFi: Bool = false) -> String {
        switch progress {
        case .queued: return DownloadNotice.queuedRowLabel(waitingForWiFi: waitingForWiFi)
        case .running(let fraction):
            return fraction > 0 ? L10n.downloadingProgress(Int(fraction * 100)) : L10n.starting
        // Android said "Saved to Music/Vibra Music"; iOS keeps downloads inside the app, where the
        // Downloads folder is the place to find them.
        case .done: return L10n.savedToDownloads
        case .failed(let reason): return reason
        }
    }
}

/// One track: its cover, what it is, and where it has got to (DownloadManagerRow).
struct DownloadManagerRow: View {
    let item: DownloadSession.Item
    /// The queue is holding for Wi-Fi: the queued row says so instead of a "Queued" that reads as
    /// a stuck queue.
    var waitingForWiFi = false
    let onCancel: () -> Void
    let onRetry: () -> Void

    private var failed: Bool {
        if case .failed = item.progress { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                ArtworkImage(song: item.song, pixels: ArtworkSize.row)
                // A finished or failed track is stated over its own cover rather than in a fourth
                // column: the list is scanned for the odd one out, and a mark on the artwork is what
                // the eye lands on.
                if item.progress.settled {
                    RoundedRectangle(cornerRadius: AppTheme.artCorner, style: .continuous)
                        .fill(.black.opacity(0.45))
                    Image(systemName: failed ? "exclamationmark.circle" : "checkmark.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(failed ? Color.red : .white)
                }
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                ExplicitSongTitle(song: item.song, font: .callout.weight(.semibold))
                Text(credit)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                progress
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("downloadManager.row")
    }

    /// The release is worth naming where there is one: in forty rows off three albums, the credit
    /// alone doesn't say which batch a row belongs to.
    private var credit: String {
        let parts = [item.song.artist.isEmpty ? nil : item.song.artist,
                     item.from.flatMap { $0.isEmpty || $0 == item.song.artist ? nil : $0 }].compactMap { $0 }
        return parts.isEmpty ? L10n.unknownArtist : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var progress: some View {
        let status = Text(DownloadManagerSummary.status(of: item.progress, waitingForWiFi: waitingForWiFi))
            .font(.caption.weight(.semibold))
            .lineLimit(2)
        switch item.progress {
        case .running(let fraction):
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: fraction)
                    .tint(.accentColor)
                status.foregroundStyle(.secondary)
            }
        case .failed:
            status.foregroundStyle(.red)
        case .queued, .done:
            status.foregroundStyle(.secondary)
        }
    }

    /// One control, following the row's state: a running track can be stopped, a failed one asked
    /// for again, and a finished one needs nothing.
    @ViewBuilder
    private var action: some View {
        if failed {
            rowButton(symbol: "arrow.clockwise", label: L10n.retry, identifier: "downloadManager.retry", perform: onRetry)
        } else if !item.progress.settled {
            rowButton(symbol: AppSymbol.close, label: L10n.cancel, identifier: "downloadManager.cancel", perform: onCancel)
        } else {
            Color.clear.frame(width: 36, height: 36)
        }
    }

    private func rowButton(symbol: String, label: String, identifier: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}
