import VibraMusicCore
import PlaybackQueue
import SwiftUI

/// The live queue, in the player itself (ports ui/player/PlayerQueue.kt's InlineQueue).
///
/// What's playing, then each section in running order — what the listener queued ("Next in
/// queue", with Clear), the album or playlist ("Next from …"), and AutoPlay's suggestions under
/// their own heading. Tap a row to jump to it, drag it by its handle to reorder it within its own
/// section — a drag never leaves its section, and the playing row doesn't move — tap its ✕ to
/// remove it. (Android drew the lifted row itself over a LazyColumn; a List's own reordering is
/// the native equivalent, and it is started from the same handle.) While a Listen Together host holds the controls the queue
/// is there to be looked at, not worked.
///
/// Drawn in white over the player's backdrop, and scrolls back to the top on a track change.
struct QueuePanel: View {
    @Environment(PlayerController.self) private var player
    @State private var hasScrolledOnce = false

    var body: some View {
        let sections = player.sections
        let showHistory = player.settings.showQueueHistory
        let locked = player.controlsLocked
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L10n.queue)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if sections.canClearUserQueue {
                    ClearQueueButton(locked: locked, font: .headline) { clear() }
                }
            }
            ScrollViewReader { proxy in
                List {
                    // Each heading is the first row of its section, never a Section header: a
                    // plain List pins its headers to the top while their rows scroll on under
                    // them, and Android's headings are ordinary LazyColumn items that scroll
                    // away with the list.
                    if !sections.history.isEmpty {
                        Section {
                            QueueHeading(title: L10n.previouslyPlayed)
                                .padding(.top, 12)
                                .padding(.bottom, 6)
                                .queueHeadingRow()
                            ForEach(sections.history) { row in
                                QueueRowView(row: row, isCurrent: false, locked: locked, draggable: false,
                                             onJump: { jump(row) }, onRemove: { remove(row) })
                                    .moveDisabled(true)
                            }
                        }
                    }
                    if let now = sections.nowPlaying {
                        Section {
                            QueueHeading(title: L10n.nowPlaying)
                                .padding(.top, 12)
                                .padding(.bottom, 6)
                                .queueHeadingRow()
                                .id(QueueListAnchor.top)
                            QueueRowView(row: now, isCurrent: true, locked: locked, onJump: { jump(now) }, onRemove: { remove(now) })
                                .moveDisabled(true)
                        }
                    }
                    if !sections.user.isEmpty {
                        Section {
                            QueueHeading(title: L10n.nextInQueue) {
                                ClearQueueButton(locked: locked, font: .subheadline.weight(.semibold)) { clear() }
                            }
                            .padding(.top, 16)
                            .padding(.bottom, 6)
                            .queueHeadingRow()
                            rows(sections.user, section: .user, locked: locked)
                        }
                    }
                    if !sections.context.isEmpty {
                        Section {
                            QueueHeading(title: sections.contextTitle.map(L10n.nextFrom) ?? L10n.queue)
                                .padding(.top, 16)
                                .padding(.bottom, 6)
                                .queueHeadingRow()
                            rows(sections.context, section: .context, locked: locked)
                        }
                    }
                    if sections.showsAutoplaySection(autoplayEnabled: player.isAutoplayEnabled) {
                        Section {
                            AutoplayHeading(hasTracks: !sections.autoplay.isEmpty)
                                .queueHeadingRow()
                            rows(sections.autoplay, section: .autoplay, locked: locked)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                // Rows size themselves (a track row is 56pt tall, a heading shorter), as
                // LazyColumn items do.
                .environment(\.defaultMinListRowHeight, 0)
                .listSectionSpacing(0)
                .mask(FadingEdges())
                .onAppear {
                    if !hasScrolledOnce {
                        proxy.scrollTo(QueueListAnchor.top, anchor: .top)
                        hasScrolledOnce = true
                    }
                }
                .onChange(of: player.currentIndex) { _, _ in
                    if hasScrolledOnce {
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(QueueListAnchor.top, anchor: .top) }
                    } else {
                        proxy.scrollTo(QueueListAnchor.top, anchor: .top)
                        hasScrolledOnce = true
                    }
                }
                .onChange(of: showHistory) { _, _ in
                    if hasScrolledOnce {
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(QueueListAnchor.top, anchor: .top) }
                    } else {
                        proxy.scrollTo(QueueListAnchor.top, anchor: .top)
                        hasScrolledOnce = true
                    }
                }
            }
        }
        .accessibilityIdentifier("nowPlaying.queuePanel")
    }

    @ViewBuilder
    private func rows(_ rows: [QueueRow], section: QueueSection, locked: Bool) -> some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            QueueRowView(row: row, isCurrent: false, locked: locked, onJump: { jump(row) }, onRemove: { remove(row) })
                .moveDisabled(locked)
                .prefetchingCovers(after: index, in: rows) { [$0.song.thumbnailUrl] }
        }
        .onMove { offsets, destination in
            move(in: rows, offsets: offsets, destination: destination)
        }
    }

    // MARK: Actions

    private func jump(_ row: QueueRow) {
        Haptics.shared.play(.tap)
        player.jump(to: row.timelineIndex)
    }

    private func remove(_ row: QueueRow) {
        Haptics.shared.play(.tap)
        withAnimation(.easeOut(duration: 0.2)) { _ = player.remove(at: row.timelineIndex) }
    }

    private func clear() {
        Haptics.shared.play(.toggleOff)
        withAnimation(.easeOut(duration: 0.2)) { _ = player.clearQueue() }
    }

    private func move(in rows: [QueueRow], offsets: IndexSet, destination: Int) {
        guard let (from, to) = QueuePanelMove.timelineMove(rows: rows.map(\.timelineIndex), offsets: offsets, destination: destination) else { return }
        Haptics.shared.play(.select)
        player.move(from: from, to: to)
    }
}

private enum QueueListAnchor: Hashable {
    case top
}

/// SwiftUI's `onMove` in a section's terms, as the one queue move PlaybackQueue takes.
enum QueuePanelMove {
    /// The timeline move for dragging the row at `offsets` (one row) of a section whose rows sit at
    /// `rows` in the timeline to `destination` ("insert before this position" in the section, as
    /// `onMove` reports it). Nil for a no-op.
    static func timelineMove(rows: [Int], offsets: IndexSet, destination: Int) -> (from: Int, to: Int)? {
        guard offsets.count == 1, let source = offsets.first, rows.indices.contains(source) else { return nil }
        // "Insert before `destination`" counts the moving row itself when it lies above.
        let target = destination > source ? destination - 1 : destination
        let clamped = min(max(target, 0), rows.count - 1)
        guard clamped != source else { return nil }
        return (rows[source], rows[clamped])
    }
}

// MARK: - Rows

private struct QueueRowView: View {
    let row: QueueRow
    let isCurrent: Bool
    let locked: Bool
    var draggable: Bool = true
    let onJump: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if !isCurrent && !locked && draggable {
                // The handle says the row can be moved; the List's reorder drag starts on a
                // long press anywhere on the row, the handle included.
                Image(systemName: "line.3.horizontal")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 20)
                    .padding(.leading, -4)
                    .accessibilityHidden(true)
            }
            // Clipped to its 44pt square as Android's AsyncImage is: ArtworkImage lays out at the
            // filled image's own aspect ratio, so wide (video) art otherwise spills over the title.
            ArtworkImage(song: row.song, pixels: ArtworkSize.row, cornerRadius: 6)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                ExplicitSongTitle(song: row.song, font: .body.weight(.semibold), color: .white.opacity(isCurrent ? 1 : 0.92))
                Text(row.song.artist)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isCurrent {
                Image(systemName: "waveform")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .accessibilityLabel(L10n.nowPlaying)
            }
            if !locked {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.removeFromQueue)
            }
        }
        .contentShape(Rectangle())
        // Disabled rather than ignored while the host holds the queue.
        .onTapGesture { if !locked { onJump() } }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(L10n.removeFromQueue)) { if !locked { onRemove() } }
        .accessibilityHint(isCurrent || locked ? "" : L10n.dragToReorder)
        .accessibilityIdentifier(isCurrent ? "queue.nowPlaying" : "queue.row")
    }
}

private struct QueueHeading<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.75))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension QueueHeading where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

struct AutoplayHeading: View {
    let hasTracks: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // Scaled into its box, as Android's 18dp vector is (the path is 17.8 of its 24-unit
            // viewport): a symbol set by font alone drew wider than the box, and the row, which has
            // no leading inset, cut it off.
            Image(systemName: AppSymbol.infinity)
                .resizable()
                .fontWeight(.semibold)
                .scaledToFit()
                .frame(width: 13.5)
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.autoplay)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(hasTracks ? L10n.autoplayQueueDescription : L10n.autoplayEmptyDescription)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct ClearQueueButton: View {
    let locked: Bool
    var font: Font = .headline
    let action: () -> Void

    var body: some View {
        Button(L10n.clear, action: action)
            .font(font)
            .foregroundStyle(.white.opacity(locked ? 0.25 : 0.75))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Capsule())
            .buttonStyle(.plain)
            .disabled(locked)
            .accessibilityIdentifier("queue.clear")
    }
}

private extension View {
    /// A section heading as an ordinary list row: full width, no background, no separator,
    /// and not a place a dragged row can be dropped on.
    func queueHeadingRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .moveDisabled(true)
    }
}

/// Softens the list where it meets the header and the controls (Android's fadingEdges, 28dp).
private struct FadingEdges: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 28)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 28)
        }
    }
}
