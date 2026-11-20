import VibraMusicCore
import Lyrics
import Observation
import SwiftUI
import UIKit

// Ports ui/player/LyricsShare.kt: the pick mode and its floating bar. Long-pressing a lyric line
// starts choosing; taps then add or drop lines, up to a card's worth of words, and Share hands the
// chosen passage to the sheet that draws it.

/// One picked passage, as the string that goes on the card.
///
/// Held as text rather than as a `LyricLine` because the card has no idea what a line's timing is:
/// it is handed what the reader was looking at, translation and all, and nothing else.
///
/// - `subText` is the romanization or translation drawn small underneath, or nil when the panel was
///   showing the original alone.
/// - `isGap` stands in for the lines skipped between two picked ones, drawn as an ellipsis rather
///   than as words.
struct LyricsShareLine: Equatable, Sendable {
    var text: String
    var subText: String?
    var isGap = false
}

/// Everything the card renderer needs, gathered once by the panel.
struct LyricsShareRequest: Identifiable, Sendable {
    /// A fresh identity per share, so choosing a second passage opens the sheet again.
    let id = UUID()
    var song: Song
    /// The resolved sleeve — remote URL or local file, whatever the player found.
    var artworkUrl: String?
    var lines: [LyricsShareLine]
}

/// How much text one card is allowed to hold: the picked words, in characters.
///
/// About five short lines — the point where the size ladder still lands near its top rung and the
/// type stays big enough to read in a chat without pinching. Past it the only ways to keep going
/// would be to shrink the type or to grow the card past the 9:16 it is meant to be, so the panel
/// stops the pick instead: the line is not added, and the player says why. Nothing already picked is
/// ever dropped.
enum LyricsShareLimit {
    static let characters = 250
}

/// Whether a line of `text` can still join a card already holding `taken` characters — the whole of
/// the rule the panel enforces at the pick (Android: `fitsOnCard`).
///
/// Only the words are counted. The translation or romanization drawn under each line rides along
/// and costs the card height, which the ladder pays for by taking a rung or two; counting it here
/// instead would make the same five lines pickable or not depending on a toggle that has nothing to
/// do with how long the verse is.
///
/// Characters are counted the way Android's `String.length` counts them — UTF-16 units — so a
/// passage is refused at the same point on both platforms.
func fitsOnCard(taken: Int, text: String?) -> Bool {
    taken + (text?.utf16.count ?? 0) <= LyricsShareLimit.characters
}

/// The pick mode's state machine: the lines, what may be added to them, and the card the chosen
/// ones make (Android: `rememberLyricsPicker`).
///
/// Adding is subject to ``LyricsShareLimit``, counted across everything already chosen: the card
/// draws every line it is handed, so the pick is the only place a limit can sit without dropping
/// words afterwards.
///
/// Injected through the environment from Now Playing, because three things read it together and
/// none of them can be right on its own — the panel's rows, the bar under them, and the deck that
/// stands down while a pick is open.
@MainActor
@Observable
final class LyricsShareController {
    /// Whether the reader is choosing lines to put on a share card.
    private(set) var picking = false
    /// Which lines are chosen, as indices into the panel's own list.
    private(set) var picks: Set<Int> = []
    /// Set when a tap would have pushed the selection past what one card holds.
    private(set) var overBudget = false
    /// The passage handed to the sheet, once Share is confirmed.
    private(set) var request: LyricsShareRequest?

    /// False until something is picked, and again once the pick is over budget.
    /// Agrees with what `share()` sends: a pick of blank lines alone makes no card, so it can't
    /// light Share up only to do nothing.
    var canShare: Bool {
        !overBudget && picks.contains { !(line(at: $0)?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
    }

    /// The characters the picks add up to (Android's `usedChars`).
    var usedCharacters: Int {
        picks.reduce(0) { total, index in total + (line(at: index)?.text.utf16.count ?? 0) }
    }

    @ObservationIgnored private var song: Song?
    @ObservationIgnored private var trackKey = ""
    @ObservationIgnored private var lines: [LyricLine] = []
    @ObservationIgnored private var subLines: [LyricLine]?
    @ObservationIgnored private var artworkUrl: String?

    /// The panel's lines, index for index with the picks. The picks index into `lines`, and the
    /// panel outlives changes to it — another track or a re-fetched verse would otherwise leave a
    /// stale set pointing at lines that are no longer there (Android's
    /// `LaunchedEffect(song.videoId, lines)`).
    func configure(song: Song?, trackKey: String, lines: [LyricLine], subLines: [LyricLine]?, artworkUrl: String?) {
        let changed = trackKey != self.trackKey || lines != self.lines
        self.song = song
        self.trackKey = trackKey
        self.lines = lines
        self.subLines = subLines
        self.artworkUrl = artworkUrl
        if changed { cancel() }
    }

    /// Long-press on a line: start picking, or fold that line into the pick.
    ///
    /// The only way in, so it opens the mode *and* — once the mode is open — behaves exactly as a
    /// tap does. Otherwise the same press on the same line means one thing before and another after,
    /// which is a rule the reader has to learn for no reason.
    /// Returns whether the line was refused, so the panel can say so for the first press too.
    @discardableResult
    func pick(_ index: Int) -> Bool {
        if picking {
            return toggle(index)
        }
        Haptics.shared.play(.select)
        picking = true
        picks = []
        overBudget = false
        // The first line goes through the same budget as the rest, so one very long one opens the
        // mode with nothing chosen rather than opening it already too big to send.
        return toggle(index)
    }

    /// Header share button: the same mode a long press opens, but with nothing preselected — the
    /// header names no line, so there is nothing to fold in (Android's `beginPicking`, commit
    /// 89912638).
    ///
    /// Kept apart from ``pick(_:)`` so a tap on it can never seek or toggle: it only ever turns the
    /// mode on, and it is a no-op once it already is, because the header is the way out then.
    func beginPicking() {
        guard !picking else { return }
        Haptics.shared.play(.select)
        picking = true
        picks = []
        overBudget = false
    }

    /// Tap while picking: add or drop that line. Returns whether the line was refused.
    @discardableResult
    func toggle(_ index: Int) -> Bool {
        if picks.contains(index) {
            picks.remove(index)
            overBudget = false
            return false
        }
        guard fitsOnCard(taken: usedCharacters, text: line(at: index)?.text) else {
            // A line that will not fit says so and nothing else lights up. The bar is not the place
            // to say it: it is two buttons over somebody's words, and a line that stays dim is the
            // answer.
            overBudget = true
            return true
        }
        picks.insert(index)
        overBudget = false
        return false
    }

    func cancel() {
        picking = false
        picks = []
        overBudget = false
    }

    /// Hands the chosen lines over as a card request, then closes the pick.
    func share() {
        guard let song else {
            cancel()
            return
        }
        // Blank picks are dropped before the gaps are worked out, so a gap is only ever marked
        // between two lines that are on the card, never ahead of the first one.
        let chosen = picks.sorted().filter { !(line(at: $0)?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
        var shared: [LyricsShareLine] = []
        var previous: Int?
        for index in chosen {
            // A jump over unchosen lines is marked on the card, so the picture says the verse was
            // cut here rather than letting two distant halves read as if they ran on from each
            // other.
            if let previous, index > previous + 1 {
                shared.append(LyricsShareLine(text: "", subText: nil, isGap: true))
            }
            previous = index
            guard let line = line(at: index) else { continue }
            let sub = subLines.flatMap { $0.indices.contains(index) ? $0[index].text : nil }
            shared.append(LyricsShareLine(text: line.text, subText: sub.flatMap { differing($0, from: line.text) }))
        }
        let picked = shared.filter { $0.isGap || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // A pick with no words in it (blank lines, with only a gap mark between them) draws nothing
        // worth sending, so it is simply left alone rather than putting an empty card on screen to
        // be dismissed.
        if picked.contains(where: { !$0.isGap }) {
            request = LyricsShareRequest(song: song, artworkUrl: artworkUrl, lines: picked)
        }
        cancel()
    }

    private func line(at index: Int) -> LyricLine? {
        lines.indices.contains(index) ? lines[index] : nil
    }

    /// Android's `sub?.takeIf { it.isNotBlank() && it != line.text }`: a line the translation left
    /// unchanged gets no second copy of itself.
    private func differing(_ sub: String, from text: String) -> String? {
        guard !sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, sub != text else { return nil }
        return sub
    }
}

/// The floating bar while lines are being picked: Cancel, and Share (Android: `LyricsPickBar`).
///
/// A pill over the words rather than a row in the controls, for the reason the translate disc floats
/// too — the controls fade away on their own, and a mode that can vanish while it is still on reads
/// as the panel having started ignoring taps.
///
/// Nothing else. No count of lines, no budget, no warning: what has been chosen is already said by
/// the rows themselves, which light up, and what is left of the budget is not the reader's problem —
/// a line that will not fit simply does not light up.
struct LyricsPickBar: View {
    /// False until something is picked, and again once the pick is over budget.
    let shareEnabled: Bool
    let onCancel: () -> Void
    let onShare: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            PickAction(title: L10n.cancel, symbol: "xmark", accent: false, enabled: true) {
                Haptics.shared.play(.tap)
                onCancel()
            }
            .accessibilityIdentifier("lyrics.pick.cancel")
            PickAction(title: L10n.share, symbol: "square.and.arrow.up", accent: true, enabled: shareEnabled) {
                Haptics.shared.play(.select)
                onShare()
            }
            .accessibilityIdentifier("lyrics.pick.share")
        }
        .padding(12)
        .background(Color(red: 0x14 / 255, green: 0x14 / 255, blue: 0x14 / 255).opacity(0.92),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityIdentifier("lyrics.pickBar")
    }
}

/// One button of ``LyricsPickBar``, in the player's own colours.
///
/// White alphas rather than the theme's, because that is what every other control in this player is
/// drawn with, and a bar picked out of a different palette reads as a sheet borrowed from another
/// app. Share is the solid one: it is the only thing the whole mode is for, and it should be the
/// thing the eye lands on.
private struct PickAction: View {
    let title: String
    let symbol: String
    /// The one that sends it, which is the one that should be reached for.
    let accent: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .semibold))
                Text(title)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .background(background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var background: Color {
        if accent { return .white.opacity(enabled ? 1 : 0.3) }
        return .white.opacity(enabled ? 0.10 : 0.05)
    }

    /// The drawer's own base colour, so the label on the solid button reads as cut out of it rather
    /// than as black paint laid over white.
    private var foreground: Color {
        if accent {
            return Color(red: 0x12 / 255, green: 0x12 / 255, blue: 0x12 / 255).opacity(enabled ? 1 : 0.4)
        }
        return .white.opacity(enabled ? 0.85 : 0.4)
    }
}
