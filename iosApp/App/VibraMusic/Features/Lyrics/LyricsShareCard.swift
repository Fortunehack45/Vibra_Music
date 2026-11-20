import VibraMusicCore
import Lyrics
import UIKit

// Ports ui/player/LyricsShareCard.kt: the picked lines as one picture, drawn to a bitmap you can
// send.
//
// ## Why this is drawn rather than screenshotted
//
// The same reason the Replay is. A screenshot of the lyrics panel carries the scrubber, the glow
// falloff, whichever lines happened to be on screen and the status bar of that particular phone, so
// two people sharing the same verse would send two different-looking pictures. A card laid out here
// is the verse, the sleeve and this app's mark, and nothing else — and it is only as tall as that
// verse needs, which holds it inside 1080×1920 (9:16): the shape a story or a chat head expects.
// Keeping it there is the panel's job, by refusing more words at the pick rather than by shrinking
// them here.
//
// ## Fitting the type
//
// A passage can be one line or twenty, so both the size and the height are chosen rather than
// fixed: the layout is retried down a fixed ladder of sizes until the rows stop overflowing, and the
// card is then grown to exactly the room those rows take. The bottom rung of that ladder is a floor
// rather than a last resort — no card ever sets type smaller than it to squeeze a passage in, so a
// passage too long for the frame lengthens the card instead of being cut, or made small enough to
// hold a phone at arm's length to read.

/// The card's fixed furniture and the arithmetic that sizes it (Android: the `CARD_*`, `FOOTER_*`,
/// `GAP_*`, `FIT_LADDER` and type-ratio constants in LyricsShareCard.kt).
enum LyricsShareCardLayout {
    static let width: CGFloat = 1080

    /// 9:16 — a ceiling on the height, not the height itself. The card is grown to its passage and
    /// only ever comes out this tall when the passage demands it (or when it is drawn as a story).
    static let maxHeight: CGFloat = 1920

    static let margin: CGFloat = 72
    static let contentWidth: CGFloat = width - margin * 2

    static let logoGap: CGFloat = 20
    static let brand = "Vibra Music"

    /// Baseline of the mark at the top right, and just under it where the passage starts.
    static let headerBaseline: CGFloat = 132
    static let headerBottom: CGFloat = 170

    /// Air kept between the fixed furniture and the passage, both ends alike.
    static let gapAboveBody: CGFloat = 20
    static let gapBelowBody: CGFloat = 20

    /// The sleeve square in the footer, and the air kept under it.
    static let footerThumb: CGFloat = 160
    static let footerPad: CGFloat = 96

    /// Smallest the translation line is allowed to get before it stops being legible.
    static let subFloor: CGFloat = 24

    /// Small visual correction so the omission marker sits below the line above.
    static let gapMarkerOffset: CGFloat = 0.18

    /// The sizes tried, largest first (Android's `FIT_LADDER`).
    ///
    /// A ladder rather than a search: a dozen candidates is nothing to lay out, and stepping by a
    /// visible amount keeps two cards with adjacent line counts from coming out nearly the same size
    /// and reading as a mistake.
    static let fitLadder: [CGFloat] = [96, 88, 80, 72, 64, 56, 50, 44, 38, 32]

    // ── The panel's type, as ratios ──────────────────────────────────────────────────────────────
    // Every number here is one the lyrics panel uses, divided by the size it uses it at so it holds
    // at whatever size the ladder lands on.

    /// Tracking of the panel's headline: -0.7 pt against its 34 pt.
    static let tracking: CGFloat = -0.7 / 34

    /// The same -0.7 pt, against the 20 pt it sets the line underneath in.
    static let subTracking: CGFloat = -0.7 / 20

    /// Line advance: 41 over 34 for the words, 25 over 20 for the sub.
    static let lead: CGFloat = 41 / 34
    static let subLead: CGFloat = 25 / 20

    /// The sub-line against the words above it.
    static let subRatio: CGFloat = 20 / 34

    /// Where the passage starts when the card is only as tall as its words.
    static let bodyStart: CGFloat = headerBottom + gapAboveBody

    /// How much room the passage has before the card would have to grow past 9:16.
    static var bodyRoom: CGFloat { maxHeight - footerThumb - footerPad - gapBelowBody - bodyStart }

    /// The card's height: its own rows, plus the fixed header and footer, plus — in a story — the
    /// room left over up to 9:16, so the picture fills the frame it is going into.
    static func cardHeight(contentHeight: CGFloat, story: Bool) -> CGFloat {
        let spare = story ? max(bodyRoom - contentHeight, 0) : 0
        return bodyStart + contentHeight + spare + gapBelowBody + footerThumb + footerPad
    }

    /// Where the first row's top sits. A card that is only as tall as its words starts under the
    /// header; a story has spare room above the words as well as below, and the passage is centred
    /// in it rather than left hanging from the header.
    static func bodyTop(contentHeight: CGFloat, story: Bool) -> CGFloat {
        guard story else { return bodyStart }
        return bodyStart + max(bodyRoom - contentHeight, 0) / 2
    }
}

/// The picked lines, drawn (Android: `renderLyricsShareCard`).
enum LyricsShareCard {
    /// Everything the drawing needs, gathered once so it is a pure function of it.
    struct Content {
        var request: LyricsShareRequest
        var story: Bool
        var cover: UIImage?
    }

    /// Loads the sleeve the card carries, then draws the card off the main thread.
    static func render(request: LyricsShareRequest, story: Bool,
                       loader: @escaping @Sendable (String) async -> UIImage? = ReplayPoster.loadCover) async -> UIImage {
        var cover: UIImage?
        if let url = request.artworkUrl {
            cover = await loader(url)
        }
        let content = Content(request: request, story: story, cover: cover)
        return await Task.detached(priority: .userInitiated) { draw(content) }.value
    }

    // MARK: Drawing

    @Sendable static func draw(_ content: Content) -> UIImage {
        let layout = LyricsShareCardLayout.self
        // No room is reserved for the words to sit in: they get their own height, and the card is
        // built down from that number. A chorus comes out a strip barely taller than its own text
        // instead of a 9:16 sheet with a paragraph floating in the middle of it, and the size comes
        // down only as far as the ladder goes — past that the frame gives rather than the type does.
        let plan = fittest(content.request.lines)
        let cardHeight = layout.cardHeight(contentHeight: plan.content, story: content.story)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: layout.width, height: cardHeight), format: format)
        return renderer.image { context in
            let cg = context.cgContext
            ReplayPoster.drawBackdrop(cg, lead: content.cover, hue: 0, height: cardHeight)

            // ── Header ────────────────────────────────────────────────────────────────────────
            // The mark alone, at the top right — the same one the Replay carries, so two of these
            // cards still read as one family. Nothing else goes above the passage: the picture is
            // the verse, not a caption for it.
            let brandFont = ReplayPoster.heading(46)
            let brand = layout.brand
            ReplayPoster.text(brand, x: layout.width - layout.margin, baseline: layout.headerBaseline,
                              font: brandFont, color: ReplayPoster.white(0xE6), alignRight: true)
            ReplayPoster.drawLogo(
                right: layout.width - layout.margin - ReplayPoster.measure(brand, font: brandFont) - layout.logoGap,
                baseline: layout.headerBaseline
            )

            // ── The passage ───────────────────────────────────────────────────────────────────
            // Every row that exists is drawn: the frame below is measured from wherever these rows
            // end, so there is never room to be short of and nothing that has to be cut to make it.
            var y = layout.bodyTop(contentHeight: plan.content, story: content.story)
            for row in plan.rows {
                let baseline = y + row.gapBefore + row.font.ascender
                    + (row.isGap ? row.font.pointSize * layout.gapMarkerOffset : 0)
                // The omission mark is centred in the card, the words hang off the left edge
                // (Android's `Row.centered`, which `CARD_W / 2` places).
                let x = row.centered
                    ? (layout.width - ReplayPoster.measure(row.text, font: row.font, tracking: row.tracking)) / 2
                    : layout.margin
                ReplayPoster.text(row.text, x: x, baseline: baseline, font: row.font,
                                  color: row.color, tracking: row.tracking)
                y += row.gapBefore + row.height
            }

            // ── Footer ────────────────────────────────────────────────────────────────────────
            // Which song this is — which only the backdrop had been saying until now.
            let thumbY = cardHeight - layout.footerPad - layout.footerThumb
            ReplayPoster.drawArtwork(content.cover, fallback: content.request.song.title,
                                     x: layout.margin, y: thumbY, size: layout.footerThumb, circular: false)
            let textX = layout.margin + layout.footerThumb + 34
            let room = layout.width - layout.margin - textX
            let title = ReplayPoster.body(50, bold: true)
            ReplayPoster.text(ReplayPoster.ellipsised(content.request.song.title, font: title, width: room),
                              x: textX, baseline: thumbY + 74, font: title, color: .white)
            let artist = ReplayPoster.body(42)
            ReplayPoster.text(ReplayPoster.ellipsised(content.request.song.artist, font: artist, width: room),
                              x: textX, baseline: thumbY + 132, font: artist, color: ReplayPoster.white(0x99))
        }
    }

    // MARK: Fitting

    private struct Row {
        var text: String
        var font: UIFont
        var color: UIColor
        var tracking: CGFloat
        var height: CGFloat
        var gapBefore: CGFloat
        var isGap = false
        /// Drawn centred rather than off the left edge — the gap marker.
        var centered = false
    }

    /// The rows at one size, with everything needed to place them.
    private struct Plan {
        var rows: [Row]
        var ascent: CGFloat

        /// Distance from the top of the first line to the bottom of the last.
        var content: CGFloat {
            ascent + rows.reduce(0) { $0 + $1.gapBefore + $1.height }
        }
    }

    /// The largest size on the ladder whose rows still fit the passage's room, or the bottom rung
    /// when none of them do. Under that rung the type stops being worth sharing, so the frame grows
    /// to hold the words instead of the words shrinking to hold the frame. That the panel budgets
    /// characters at the pick is what keeps this branch from ever being reached in practice.
    private static func fittest(_ lines: [LyricsShareLine]) -> Plan {
        for size in LyricsShareCardLayout.fitLadder {
            let plan = plan(lines, size: size)
            if plan.content <= LyricsShareCardLayout.bodyRoom { return plan }
        }
        return plan(lines, size: LyricsShareCardLayout.fitLadder[LyricsShareCardLayout.fitLadder.count - 1])
    }

    /// The rows at one `size`, set in the face the lyrics panel draws with: SF Pro Heavy with the
    /// panel's tight tracking and its line advance, carried over as the same ratios the panel's 34 pt
    /// headline uses — so the card reads as a still of that panel rather than as a different app
    /// quoting it.
    private static func plan(_ lines: [LyricsShareLine], size: CGFloat) -> Plan {
        let layout = LyricsShareCardLayout.self
        let primary = ReplayPoster.heading(size)
        let subSize = max(size * layout.subRatio, layout.subFloor)
        let secondary = ReplayPoster.heading(subSize)

        var rows: [Row] = []
        for (index, line) in lines.enumerated() {
            if line.isGap {
                // The skipped lines, as "(...)" — the conventional editorial mark for an omission.
                // Smaller and a dim grey, and its row kept compact so the marker follows the
                // preceding lyric closely; the regular gap on the next lyric line provides the
                // separation below it.
                let marker = ReplayPoster.body(size * 0.65)
                rows.append(Row(text: "(...)", font: marker, color: ReplayPoster.white(0x66), tracking: 0,
                                height: marker.ascender - marker.descender, gapBefore: 0,
                                isGap: true, centered: true))
                continue
            }
            var firstOfLine = true
            func add(_ text: String, _ font: UIFont, _ color: UIColor, _ tracking: CGFloat, _ height: CGFloat) {
                // One verse line is one paragraph: its first row carries the space above it and its
                // wraps sit tight underneath, so a phrase reads as a block rather than as a list of
                // separate sentences.
                let gap: CGFloat
                if rows.isEmpty {
                    gap = 0
                } else if firstOfLine && index > 0 {
                    gap = size * 0.55
                } else {
                    gap = 0
                }
                rows.append(Row(text: text, font: font, color: color, tracking: tracking,
                                height: height, gapBefore: gap))
                firstOfLine = false
            }
            for text in wrapped(line.text, font: primary, tracking: layout.tracking, width: layout.contentWidth) {
                add(text, primary, .white, layout.tracking, size * layout.lead)
            }
            if let sub = line.subText, !sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, sub != line.text {
                for text in wrapped(sub, font: secondary, tracking: layout.subTracking, width: layout.contentWidth) {
                    add(text, secondary, ReplayPoster.white(0xD9), layout.subTracking, subSize * layout.subLead)
                }
            }
        }
        return Plan(rows: rows, ascent: primary.ascender)
    }

    // MARK: Text

    /// Greedy wrap at `width`, breaking wherever the line has to.
    ///
    /// Not a plain word-wrap: Japanese, Chinese and Korean lyrics carry no spaces at all, and a
    /// wrapper that only split on spaces would hand the whole verse to the drawing call and let it
    /// run off the card. The last character that fits is found first, and only then is the break
    /// walked back to a space — so scripts that keep their words apart lose nothing, and scripts
    /// that don't still get several lines.
    static func wrapped(_ text: String, font: UIFont, tracking: CGFloat, width: CGFloat) -> [String] {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.isEmpty { return [""] }

        var out: [String] = []
        var rest = source
        while !rest.isEmpty {
            let characters = Array(rest)
            let fit = fittingCount(characters, font: font, tracking: tracking, width: width)
            if fit <= 0 {
                out.append(rest)
                break
            }
            // Walk back to the last space inside the fit, but only when something still has to
            // follow it — otherwise the fit is the whole string and cutting at the space would drop
            // the final word.
            var space = -1
            var index = min(fit - 1, characters.count - 1)
            while index > 0 {
                if characters[index] == " " {
                    space = index
                    break
                }
                index -= 1
            }
            let take = space > 0 && fit < characters.count ? space : fit
            if take <= 0 {
                out.append(rest)
                break
            }
            out.append(String(characters[0..<take]).trimmingCharacters(in: .whitespacesAndNewlines))
            rest = String(characters[take...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let visible = out.filter { !$0.isEmpty }
        return visible.isEmpty ? [""] : visible
    }

    /// How many characters of `characters` fit on one row, from the start (Android's `breakText`).
    private static func fittingCount(_ characters: [Character], font: UIFont, tracking: CGFloat, width: CGFloat) -> Int {
        var count = characters.count
        while count > 0 {
            if ReplayPoster.measure(String(characters[0..<count]), font: font, tracking: tracking) <= width {
                return count
            }
            count -= 1
        }
        return 0
    }
}
