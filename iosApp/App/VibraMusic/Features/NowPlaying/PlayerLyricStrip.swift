import VibraMusicCore
import Lyrics
import SwiftUI

// Ports the two lyric lines the player itself draws, from ui/player/PlayerLyrics.kt:
// CurrentLyricStrip (the current line, one line, directly above the scrubber) and
// LyricsStatusWithChange (in its place while the lyrics are open: where they came from, and the
// way to pick another provider). The lyrics come from one LyricsSession for the open player,
// which the lyrics panel reads too.

/// The current lyric over the scrubber — or the line saying why there isn't one. Tapping it
/// opens the full lyrics. Switched off in Settings it goes entirely, leaving its one-line slot so
/// the controls don't move.
struct PlayerLyricStrip: View {
    let session: LyricsSession
    var onOpen: () -> Void

    @Environment(PlayerController.self) private var player
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Group {
            if settings.syncedLyrics {
                content
            } else {
                Color.clear
            }
        }
        .font(.headline)
        .foregroundStyle(.white)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 26)
        // The slider's touch target reaches above the drawn bar, so the strip reads as further
        // off it than it is; nudged down into that dead space (CurrentLyricStrip's offset).
        .offset(y: 6)
        .accessibilityIdentifier("nowPlaying.lyricStrip")
    }

    @ViewBuilder
    private var content: some View {
        let lines = session.lines ?? []
        if !lines.isEmpty {
            if PlayerLyricLine.isSynced(lines) {
                SyncedLyricStripLine(lines: lines, player: player, offsetMs: settings.lyricsOffsetMs, onOpen: onOpen)
            } else {
                // Plain lyrics have no current line to show: the strip becomes the way in.
                LyricStripRow(instrumental: true, onOpen: onOpen) {
                    Text(L10n.openLyrics)
                        .truncationMode(.tail)
                }
                .accessibilityLabel(L10n.openLyrics)
            }
        } else if session.isChecked {
            LyricsUnavailableLine(trackKey: player.currentSong?.videoId ?? "")
        } else {
            // Android names the wait with a rotating phrase; those phrases are a string array
            // the catalog doesn't carry, so the wait is shown as a quiet note instead.
            Image(systemName: AppSymbol.musicNote)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.4))
                .symbolEffect(.pulse, options: .repeating)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - The row

/// The strip's row (CurrentLyricLine's `Row`): the note while nothing is being sung, the words in
/// a slot that takes only the width they need, and the chevron that says the strip opens the
/// full lyrics, right after them. Clipped to a rounded rectangle for its press state.
struct LyricStripRow<Words: View>: View {
    let instrumental: Bool
    let onOpen: () -> Void
    @ViewBuilder let words: () -> Words

    var body: some View {
        Button {
            Haptics.shared.play(.tap)
            onOpen()
        } label: {
            HStack(spacing: 0) {
                if instrumental {
                    Image(systemName: AppSymbol.musicNote)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: LyricStripMetrics.noteSize, height: LyricStripMetrics.noteSize)
                        .accessibilityHidden(true)
                    Spacer().frame(width: LyricStripMetrics.spacing)
                }
                words()
                    .layoutPriority(1)
                Spacer().frame(width: LyricStripMetrics.spacing)
                Image(systemName: AppSymbol.chevronRight)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: LyricStripMetrics.chevronSize, height: LyricStripMetrics.chevronSize)
                    .foregroundStyle(.white.opacity(0.5))
                    .flipsForRightToLeftLayoutDirection(true)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(LyricStripPressStyle())
        .clipShape(RoundedRectangle(cornerRadius: LyricStripMetrics.cornerRadius))
        .accessibilityHint(L10n.openLyrics)
    }
}

/// The row's press state: a light wash inside its rounded clip, the way a ripple reads.
private struct LyricStripPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.white.opacity(configuration.isPressed ? 0.1 : 0))
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// CurrentLyricLine's fixed sizes.
enum LyricStripMetrics {
    static let noteSize: CGFloat = 16
    static let chevronSize: CGFloat = 14
    static let spacing: CGFloat = 6
    static let cornerRadius: CGFloat = 8
    /// How far a line travels on its way in and out, as a share of its own height.
    static let slide: CGFloat = 0.35
    /// The handover's length (ms): the slide, the fade and the slot's size change together.
    static let handoverMs = 340
    /// Unsung part of a word-synced line in the strip (UNSUNG_ALPHA_STRIP).
    static let unsungAlpha = 0.55

    /// FastOutSlowInEasing over the handover; none with Reduce Motion.
    static func handover(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .timingCurve(0.4, 0, 0.2, 1, duration: Double(handoverMs) / 1_000)
    }
}

// MARK: - The synced line

/// Which line the strip is on, updated from the frame clock only when it changes — the clock
/// ticks every frame and must not invalidate the strip's body that often.
@MainActor
@Observable
final class LyricStripTracker {
    private(set) var index = -1
    @ObservationIgnored var lines: [LyricLine] = []

    func update(positionMs: Int) {
        let next = lines.lastIndex { $0.timeMs <= positionMs } ?? -1
        if next != index { index = next }
    }
}

/// One item of the strip: the line at an index, or the instrumental stand-in.
struct LyricStripItem: Equatable {
    let index: Int
    let line: LyricLine?
    let text: String

    var instrumental: Bool { line?.isGap ?? true }
    /// The swept highlight is for word-synced lines only; the rest are plain text.
    var swept: LyricLine? { instrumental ? nil : line.flatMap { $0.isWordSynced ? $0 : nil } }
    var key: String { "\(index)|\(text)" }

    init(lines: [LyricLine], index: Int) {
        self.index = index
        line = lines.indices.contains(index) ? lines[index] : nil
        let instrumental = line?.isGap ?? true
        text = instrumental ? L10n.instrumental : (line?.text ?? "")
    }
}

/// The current line of a synced sheet, off its own frame clock (the panel's clock port), handing
/// over to the next line the way Android's AnimatedContent does: the new line fades in rising
/// from 35 % of its height below, the old one fades out rising 35 % above, and the slot's width
/// eases to the new line's so the chevron follows. Nothing moves sideways: the words' leading
/// edge stays on the row's.
private struct SyncedLyricStripLine: View {
    let lines: [LyricLine]
    let player: PlayerController
    let offsetMs: Int
    let onOpen: () -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var clock = LyricFrameClock()
    @State private var tracker = LyricStripTracker()

    var body: some View {
        let item = LyricStripItem(lines: lines, index: tracker.index)
        let reduceMotion = settings.reduceAnimation || systemReduceMotion
        LyricStripRow(instrumental: item.instrumental, onOpen: onOpen) {
            LyricStripSlot(current: item.key) {
                words(item, reduceMotion: reduceMotion)
                    .layoutValue(key: LyricStripSlot.ItemKey.self, value: item.key)
                    .id(item.key)
                    .transition(reduceMotion ? .identity : LyricStripSlot.handover)
            }
        }
        .animation(LyricStripMetrics.handover(reduceMotion: reduceMotion), value: item.key)
        .accessibilityLabel(item.text)
        .background {
            LyricClockFeed(player: player, clock: clock, offsetMs: offsetMs, trackKey: player.currentSong?.videoId ?? "")
        }
        .onChange(of: lines, initial: true) {
            tracker.lines = lines
            tracker.update(positionMs: clock.positionMs)
        }
        .onAppear {
            let tracker = tracker
            clock.onTick = { [weak tracker] position in tracker?.update(positionMs: position) }
            clock.resume()
            tracker.update(positionMs: clock.positionMs)
        }
        .onChange(of: scenePhase == .active, initial: true) { _, active in clock.isRunnable = active }
        .onDisappear { clock.stop() }
    }

    @ViewBuilder
    private func words(_ item: LyricStripItem, reduceMotion: Bool) -> some View {
        if let swept = item.swept {
            LyricVoice(
                line: swept,
                style: LyricVoiceStyle(
                    typeface: LyricTypeface.strip.scaled(for: UIContentSizeCategory(dynamicTypeSize)),
                    room: 0,
                    sweeps: true,
                    rises: false,
                    feather: true,
                    maxLines: 1,
                    hugs: true
                ),
                dimAlpha: LyricStripMetrics.unsungAlpha,
                glowAlpha: 0,
                clock: clock,
                reduceMotion: reduceMotion
            )
        } else {
            Text(item.text)
                .foregroundStyle(.white.opacity(item.instrumental ? 0.5 : 1))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// The slot the strip's words sit in. Sized to the line coming in (so the chevron after it
/// eases to its new place with the handover), while the line going out keeps its own width and
/// is drawn unclipped past the slot until it has faded (SizeTransform(clip = false)). Every line
/// is placed at the slot's leading edge.
struct LyricStripSlot: Layout {
    /// Which child is the current line.
    let current: String

    struct ItemKey: LayoutValueKey {
        static let defaultValue = ""
    }

    /// The handover: in from below, out upwards, fading, by 35 % of the line's own height.
    static var handover: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .modifier(active: LyricStripShift(fraction: LyricStripMetrics.slide), identity: LyricStripShift(fraction: 0))),
            removal: .opacity.combined(with: .modifier(active: LyricStripShift(fraction: -LyricStripMetrics.slide), identity: LyricStripShift(fraction: 0)))
        )
    }

    private func incoming(_ subviews: Subviews) -> LayoutSubview? {
        subviews.last { $0[ItemKey.self] == current } ?? subviews.last
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        incoming(subviews)?.sizeThatFits(proposal) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            // Offered what the slot was offered, not the slot's (new) width: the line going out
            // keeps its own layout rather than re-wrapping or re-truncating as it leaves.
            subview.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: proposal.width, height: proposal.height))
        }
    }
}

/// Moves a line vertically by a share of its own height (slideIn/OutVertically).
struct LyricStripShift: GeometryEffect {
    var fraction: CGFloat

    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 0, y: size.height * fraction))
    }
}

/// While the lyrics are open, the strip's slot says where they came from, with the provider picker
/// inline (LyricsStatusWithChange): the status takes what it needs and gives way first, "Change"
/// always shows in full.
struct PlayerLyricsStatus: View {
    let session: LyricsSession
    var onChange: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            let status = Self.status(session)
            if !status.isEmpty {
                Text(status)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Button {
                Haptics.shared.play(.select)
                onChange()
            } label: {
                Text(L10n.changeLyricsProvider)
                    .underline()
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("nowPlaying.changeLyricsProvider")
            Spacer(minLength: 0)
        }
        .font(.headline)
        .frame(height: 26)
        .offset(y: 6)
    }

    /// Android's status line without the translation states (the translation lives with the
    /// panel): who the lyrics are by, that there are none, or — still looking — nothing yet.
    static func status(_ session: LyricsSession) -> String {
        if let source = session.source { return L10n.lyricsBy(source.label) }
        let hasLyrics = !(session.lines ?? []).isEmpty
        if session.isChecked, !hasLyrics { return L10n.noLyricsFound }
        if !hasLyrics { return "" }
        return L10n.lyricsSavedWithDownload
    }
}

/// "Lyrics not available", held for five seconds and then faded out, so a track without lyrics
/// doesn't carry the notice for its whole length (PlayerLyrics.kt's `LyricsUnavailableLine`).
private struct LyricsUnavailableLine: View {
    let trackKey: String

    static let hold: TimeInterval = 5
    static let fade: TimeInterval = 0.9

    @State private var visible = true

    var body: some View {
        Text(L10n.lyricsNotAvailable)
            .foregroundStyle(.white.opacity(0.55))
            .opacity(visible ? 1 : 0)
            .task(id: trackKey) {
                visible = true
                try? await Task.sleep(for: .seconds(Self.hold))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: Self.fade)) { visible = false }
            }
    }
}

/// Which words the strip shows at a position.
enum PlayerLyricLine {
    /// Whether any line carries a time: plain lyrics have none to follow.
    static func isSynced(_ lines: [LyricLine]) -> Bool {
        lines.contains { $0.timeMs > 0 }
    }

    /// Whether the strip is between sung lines at `positionMs`: before the first, or in a gap.
    static func isInstrumental(_ lines: [LyricLine], positionMs: Int, offsetMs: Int) -> Bool {
        let adjusted = LyricsOffset.adjustedPosition(positionMs: positionMs, offsetMs: offsetMs)
        guard let index = lines.lastIndex(where: { $0.timeMs <= adjusted }) else { return true }
        return lines[index].isGap
    }

    /// The line at `positionMs` (less the listener's offset), or "Instrumental" in a gap or before
    /// the first sung line.
    static func text(_ lines: [LyricLine], positionMs: Int, offsetMs: Int) -> String {
        let adjusted = LyricsOffset.adjustedPosition(positionMs: positionMs, offsetMs: offsetMs)
        guard let index = lines.lastIndex(where: { $0.timeMs <= adjusted }) else { return L10n.instrumental }
        let line = lines[index]
        return line.isGap ? L10n.instrumental : line.text
    }
}
