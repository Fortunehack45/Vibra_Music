import NaturalLanguage
import SwiftUI
import UIKit

// The measuring half of the lyric renderer (ports the TextLayoutResult arithmetic in
// ui/player/PlayerLyrics.kt: xOn, horizontalAt and the row walks behind sweepTo / riseWith /
// growEach).
//
// SwiftUI's Text can't say where a character sits, and the sweep has to cut *inside* a word, so
// each lyric line is laid out once with TextKit and every copy of it (dim, lit, glow) is drawn from
// that one layout. TextKit counts in UTF-16, the same unit the Lyrics module's word spans use.

/// One type setting of a lyric voice: size, leading and weight, scaled for Dynamic Type.
struct LyricTypeface: Hashable {
    var size: CGFloat
    var lineHeight: CGFloat
    var weight: UIFont.Weight

    /// The lead line of a synced page (Android: 34 sp ExtraBold on 41 sp).
    static let synced = LyricTypeface(size: 34, lineHeight: 41, weight: .heavy)
    /// Lyrics with no timing at all (Android: 30 sp ExtraBold on 38 sp).
    static let plain = LyricTypeface(size: 30, lineHeight: 38, weight: .heavy)
    /// The answering vocal hung under the lead (BACKING_FONT_SIZE / BACKING_LINE_HEIGHT).
    static let backing = LyricTypeface(size: 23, lineHeight: 29, weight: .heavy)
    /// A translation or romanization under the lead (SUB_LYRIC_FONT_SIZE, Bold).
    static let sub = LyricTypeface(size: 20, lineHeight: 25, weight: .bold)
    /// A translation or romanization under the answering vocal.
    static let subBacking = LyricTypeface(size: 16, lineHeight: 21, weight: .bold)
    /// The one-line strip over the scrubber (Android: titleMedium; here the strip's `.headline`).
    static let strip = LyricTypeface(size: 17, lineHeight: 22, weight: .semibold)

    /// The same setting at the reader's text size. Lyrics are display type, so the scale is
    /// capped at the first accessibility size: past that a single word no longer fits a line.
    func scaled(for category: UIContentSizeCategory) -> LyricTypeface {
        let capped: UIContentSizeCategory = category > .accessibilityMedium ? .accessibilityMedium : category
        let traits = UITraitCollection(preferredContentSizeCategory: capped)
        let factor = UIFontMetrics(forTextStyle: .title1).scaledValue(for: 1, compatibleWith: traits)
        return LyricTypeface(size: (size * factor).rounded(), lineHeight: (lineHeight * factor).rounded(), weight: weight)
    }

    var font: UIFont { UIFont.systemFont(ofSize: size, weight: weight) }
}

/// A lyric line laid out at one width.
final class LyricTextLayout {
    /// One visual row the line wrapped to.
    struct Row: Equatable {
        /// The UTF-16 characters on the row, trailing whitespace excluded (Android's
        /// `getLineEnd(visibleEnd = true)`).
        var characters: Range<Int>
        /// Where the row was cut short for the ellipsis: the characters from here on aren't drawn.
        var truncatedFrom: Int? = nil
        /// The glyphs drawn for those characters.
        var glyphs: NSRange
        /// The row's inked extent and its band, in layout coordinates.
        var left: CGFloat
        var right: CGFloat
        var top: CGFloat
        var bottom: CGFloat
    }

    let text: String
    let typeface: LyricTypeface
    let alignEnd: Bool
    let rightToLeftLayout: Bool
    /// At most this many rows, the last one ending in "…" (0: no limit).
    let maxLines: Int
    /// Whether the words run right to left (Hebrew, Arabic…), which flips which end of a row the
    /// sweep starts from.
    let rightToLeftText: Bool
    private(set) var rows: [Row] = []
    private(set) var size: CGSize = .zero
    let length: Int

    let storage: NSTextStorage
    let layoutManager: NSLayoutManager
    let container: NSTextContainer

    init(text: String, typeface: LyricTypeface, width: CGFloat, alignEnd: Bool = false, rightToLeftLayout: Bool = false, maxLines: Int = 0) {
        self.text = text
        self.maxLines = maxLines
        self.typeface = typeface
        self.alignEnd = alignEnd
        self.rightToLeftLayout = rightToLeftLayout
        length = (text as NSString).length
        rightToLeftText = Self.isRightToLeft(text)

        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = typeface.lineHeight
        paragraph.maximumLineHeight = typeface.lineHeight
        // A capped line ends on an ellipsis (Compose's TextOverflow.Ellipsis).
        paragraph.lineBreakMode = maxLines > 0 ? .byTruncatingTail : .byWordWrapping
        // Android's TextAlign.Start / End follow the *layout* direction, not the words'.
        let startIsLeft = !rightToLeftLayout
        paragraph.alignment = (alignEnd != startIsLeft) ? .left : .right
        paragraph.baseWritingDirection = rightToLeftText ? .rightToLeft : .leftToRight
        let font = typeface.font
        // Centre the glyphs in the fixed line height, the way Compose does.
        let baselineShift = max(typeface.lineHeight - font.lineHeight, 0) / 2
        storage = NSTextStorage(string: text, attributes: [
            .font: font,
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraph,
            .baselineOffset: baselineShift,
        ])
        layoutManager = NSLayoutManager()
        layoutManager.usesFontLeading = false
        container = NSTextContainer(size: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = max(maxLines, 0)
        if maxLines > 0 { container.lineBreakMode = .byTruncatingTail }
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        measure()
    }

    private func measure() {
        var rows: [Row] = []
        let whitespace = CharacterSet.whitespacesAndNewlines
        let ns = text as NSString
        layoutManager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)) { rect, used, _, glyphRange, _ in
            let chars = self.layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            var end = chars.location + chars.length
            while end > chars.location, let scalar = UnicodeScalar(ns.character(at: end - 1)), whitespace.contains(scalar) {
                end -= 1
            }
            let visible = NSRange(location: chars.location, length: end - chars.location)
            let glyphs = self.layoutManager.glyphRange(forCharacterRange: visible, actualCharacterRange: nil)
            var ink = glyphs.length > 0
                ? self.layoutManager.boundingRect(forGlyphRange: glyphs, in: self.container)
                : CGRect(x: used.minX, y: rect.minY, width: 0, height: rect.height)
            var truncatedFrom: Int?
            if self.maxLines > 0, glyphs.length > 0 {
                let cut = self.layoutManager.truncatedGlyphRange(inLineFragmentForGlyphAt: glyphs.location)
                if cut.location != NSNotFound {
                    truncatedFrom = self.layoutManager.characterIndexForGlyph(at: cut.location)
                    // The hidden glyphs keep their untruncated places; the row ends where the
                    // ellipsis does.
                    ink = ink.intersection(used).isNull ? used : CGRect(x: max(ink.minX, used.minX), y: ink.minY, width: min(ink.maxX, used.maxX) - max(ink.minX, used.minX), height: ink.height)
                }
            }
            rows.append(Row(
                characters: chars.location..<end,
                truncatedFrom: truncatedFrom,
                glyphs: glyphs,
                left: ink.minX,
                right: ink.maxX,
                top: rect.minY,
                bottom: rect.maxY
            ))
        }
        self.rows = rows
        let used = layoutManager.usedRect(for: container)
        let height = rows.last?.bottom ?? (length == 0 ? 0 : typeface.lineHeight)
        size = CGSize(width: ceil(used.width), height: ceil(max(height, used.height)))
    }

    /// The row a character sits on.
    func row(ofCharacter offset: Int) -> Int? {
        rows.firstIndex { $0.characters.contains(offset) }
    }

    /// Where a character boundary sits *on the row it was cut out of* (Android's `xOn`): the row's
    /// own edges answer for its two ends, so a word that runs up to a wrap doesn't report a
    /// position at the far side of the next row. Measured along the reading direction: for
    /// right-to-left words the start edge is the right one.
    func x(ofBoundary offset: Int, row index: Int) -> CGFloat {
        let row = rows[index]
        let startEdge = rightToLeftText ? row.right : row.left
        let endEdge = rightToLeftText ? row.left : row.right
        if offset <= row.characters.lowerBound { return startEdge }
        if offset >= row.characters.upperBound { return endEdge }
        // Past the ellipsis nothing is drawn: the sweep's edge waits at the row's end.
        if let cut = row.truncatedFrom, offset >= cut { return endEdge }
        let glyph = layoutManager.glyphIndexForCharacter(at: offset)
        let box = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let leading = rightToLeftText ? box.maxX : box.minX
        return min(max(leading, row.left), row.right)
    }

    /// The horizontal extent of `characters` on `row`, left to right on screen.
    func span(_ characters: Range<Int>, row index: Int) -> (from: CGFloat, to: CGFloat) {
        let a = x(ofBoundary: characters.lowerBound, row: index)
        let b = x(ofBoundary: characters.upperBound, row: index)
        return (min(a, b), max(a, b))
    }

    /// Where the sweep's edge is on `row` for a fractional character count (Android's
    /// `horizontalAt`): between two character positions, so it glides instead of stepping.
    func sweepEdge(revealed: Float, row index: Int) -> CGFloat {
        let row = rows[index]
        let whole = min(max(Int(revealed), row.characters.lowerBound), row.characters.upperBound)
        let here = x(ofBoundary: whole, row: index)
        let next = x(ofBoundary: min(whole + 1, row.characters.upperBound), row: index)
        return here + (next - here) * CGFloat(revealed - Float(whole))
    }

    /// The glyphs that draw `characters`.
    func glyphs(for characters: Range<Int>) -> NSRange {
        layoutManager.glyphRange(forCharacterRange: NSRange(location: characters.lowerBound, length: characters.count), actualCharacterRange: nil)
    }

    /// Draws `glyphs` at their laid-out places, offset by `origin`, into the current context.
    func draw(_ glyphs: NSRange, at origin: CGPoint) {
        guard glyphs.length > 0 else { return }
        layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
    }

    /// The box of one character, for the translation particles.
    func box(ofCharacter offset: Int) -> CGRect {
        let glyph = layoutManager.glyphIndexForCharacter(at: offset)
        return layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
    }

    private static func isRightToLeft(_ text: String) -> Bool {
        guard let language = NLLanguageRecognizer.dominantLanguage(for: text) else { return false }
        return Locale.Language(identifier: language.rawValue).characterDirection == .rightToLeft
    }
}
