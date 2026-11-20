import Foundation

/// Apple Music's word-timed lyric format.
///
/// A document is `<p>` per sung line, each holding one `<span>` per syllable with its own
/// `begin`/`end`:
///
///     <p begin="27.395" end="28.960" ttm:agent="v1">
///       <span begin="27.395" end="27.549">I</span>
///       <span begin="27.549" end="27.740">been</span>
///     </p>
///
/// Syllables of one word are written as adjacent spans with no whitespace between them
/// ("e" + "nough"), so whitespace — not the span boundary — is what separates words. That
/// is the whole trick to reading this format.
public enum TTMLLyrics {

    /// Roles that are not this line at all: translations and romanisations are alternate
    /// renderings of the same words and would double the line up.
    private static let skippedRoles: Set<String> = ["x-translation", "x-roman"]

    /// The answering vocal. It is this line, sung by a second voice over the lead and often
    /// past the *next* line's stamp, so it is collected apart and carried as
    /// `LyricLine.background` — run into the lead's own words it dragged the sweep along and
    /// the tail of the line was skipped.
    private static let backgroundRole = "x-bg"

    /// The lines in `ttml`; empty for anything that does not parse.
    public static func parse(_ ttml: String) -> [LyricLine] {
        guard let document = LyricsXMLNode.parse(ttml) else { return [] }

        // The line and the voice that sang it, kept together: which side of the panel a line
        // belongs on can only be worked out once they all are.
        var sung = [(line: LyricLine, singer: String?)]()
        for paragraph in document.elements(named: "p") {
            guard let line = line(from: paragraph) else { continue }
            let agent = qualified(paragraph, "ttm:agent")
            sung.append((line, agent.isEmpty ? nil : agent))
        }
        sung = sung.kSortedBy(\.line.timeMs)

        let sides = lineAlignments(singers: sung.map(\.singer), types: agentTypes(document))
        return sung.enumerated().map { index, entry in
            var line = entry.line
            line.alignment = sides[index]
            return line
        }.withInstrumentalGaps()
    }

    /// The `<ttm:agent>` declarations in the head, as id to type — `person`, `group`,
    /// `other`. A document that names its voices without describing them is common enough
    /// that `lineAlignments` guesses rather than gives up.
    private static func agentTypes(_ document: LyricsXMLNode) -> [String: String] {
        var agents = document.elements(named: "ttm:agent")
        if agents.isEmpty { agents = document.elements(named: "agent") }
        var types = [String: String]()
        for agent in agents {
            let id = qualified(agent, "xml:id")
            let type = agent.attribute("type")
            if !id.isEmpty && !type.isEmpty { types[id] = type }
        }
        return types
    }

    /// An attribute named with a prefix. Asked for by its whole name first and, failing
    /// that, by any attribute whose name or local name matches — Android had to do this
    /// because its Expat-backed DOM files `ttm:agent` under its local name, and the same
    /// fallback keeps this reader tolerant of a document that writes the prefix differently.
    private static func qualified(_ element: LyricsXMLNode, _ name: String) -> String {
        let direct = element.attribute(name)
        if !direct.isEmpty { return direct }
        let local = name.kSubstringAfter(":")
        for (key, value) in element.attributes.sorted(by: { $0.key < $1.key }) {
            if key == name || key == local || key.kSubstringAfter(":") == local { return value }
        }
        return ""
    }

    private static func line(from paragraph: LyricsXMLNode) -> LyricLine? {
        var pieces = [Piece]()
        var backingPieces = [Piece]()
        collect(paragraph, into: &pieces, backing: &backingPieces, toBacking: false)
        let words = mergeIntoWords(pieces)
        let backingWords = mergeIntoWords(backingPieces)
        let backing: LyricLine? = backingWords.isEmpty ? nil : LyricLine(
            timeMs: backingWords[0].startMs,
            text: backingWords.map(\.text).joined(separator: " "),
            words: backingWords
        )

        if words.isEmpty {
            // Line-synced TTML: a <p> with a stamp and bare text, no spans. textContent is
            // the whole paragraph, backing vocal included, so there is nothing here to hang
            // underneath — the bracket in the text is all the separation the document gave.
            let text = paragraph.textContent.kTrimmed
            guard let begin = time(paragraph.attribute("begin")) else { return nil }
            if text.isEmpty { return nil }
            // The paragraph's own end is the only thing that says when the singing stops, so
            // carry it — a break can't be found without it.
            let end = time(paragraph.attribute("end")).flatMap { $0 > begin ? $0 : nil }
            return LyricLine(timeMs: begin, text: text, sungUntilMs: end)
        }

        // Prefer the paragraph's own stamp: Apple sets it a hair before the first syllable
        // on lines that open with a soft consonant, and that lead-in is when the line should
        // appear.
        let begin = time(paragraph.attribute("begin")) ?? words[0].startMs
        return LyricLine(
            timeMs: min(begin, words[0].startMs),
            text: words.map(\.text).joined(separator: " "),
            words: words,
            background: backing
        )
    }

    private enum Piece {
        case text(String)
        case timed(String, start: Int, end: Int)
    }

    /// Flattens a paragraph into timed spans and the whitespace between them. Nested spans
    /// (Apple wraps background vocals, and occasionally whole phrases, in an outer timed
    /// span) recurse to their leaves, so only the innermost timings — the ones actually
    /// per-syllable — survive.
    ///
    /// Spans marked `backgroundRole` and everything under them go to `backing` instead of
    /// `lead`, which is what keeps the two voices apart.
    private static func collect(
        _ node: LyricsXMLNode,
        into lead: inout [Piece],
        backing: inout [Piece],
        toBacking: Bool
    ) {
        for child in node.children {
            if child.isElement {
                let role = qualified(child, "ttm:role")
                if skippedRoles.contains(role) { continue }
                // Inside a backing span every leaf is backing, so the sink switches for the
                // whole of that subtree — whether the span holds its own syllables or is a
                // single timed leaf.
                let sinkIsBacking = toBacking || role == backgroundRole
                let begin = time(child.attribute("begin"))
                let end = time(child.attribute("end"))
                if let begin, let end, !hasTimedChild(child) {
                    let piece = Piece.timed(child.textContent, start: begin, end: end)
                    if sinkIsBacking { backing.append(piece) } else { lead.append(piece) }
                } else {
                    collect(child, into: &lead, backing: &backing, toBacking: sinkIsBacking)
                }
            } else if child.isText {
                let text = child.textContent
                if !text.isEmpty {
                    if toBacking { backing.append(.text(text)) } else { lead.append(.text(text)) }
                }
            }
        }
    }

    private static func hasTimedChild(_ element: LyricsXMLNode) -> Bool {
        element.children.contains { child in
            child.isElement && (!child.attribute("begin").isEmpty || hasTimedChild(child))
        }
    }

    /// Glues syllables back into words. A word ends at the first whitespace after it —
    /// whether that whitespace is a text node between two spans or part of a span's own
    /// text — and its span runs from the first syllable's start to the last one's end.
    private static func mergeIntoWords(_ pieces: [Piece]) -> [LyricWord] {
        var words = [LyricWord]()
        var current = ""
        var start = 0
        var end = 0
        // Untimed text is punctuation hanging off a span, or a line that was never
        // word-timed at all. Either way it can't carry a word of its own.
        var timed = false

        func flush() {
            let text = current.kTrimmed
            current = ""
            if !text.isEmpty && timed { words.append(LyricWord(startMs: start, endMs: end, text: text)) }
            timed = false
        }

        for piece in pieces {
            switch piece {
            case .text(let text):
                if text.kIsBlank {
                    flush()
                } else if timed {
                    // Trailing punctuation belongs to the word it follows; anything before
                    // the first span has no timing to join.
                    current += text
                }
            case .timed(let text, let pieceStart, let pieceEnd):
                // A span that is only whitespace is still the gap between two words.
                if text.kIsBlank {
                    flush()
                    continue
                }
                // Leading whitespace closes off whatever came before it.
                if text.unicodeScalars.first?.kIsWhitespace == true { flush() }
                if current.isEmpty { start = pieceStart }
                current += text.kTrimmed
                end = pieceEnd
                timed = true
                if text.unicodeScalars.last?.kIsWhitespace == true { flush() }
            }
        }
        flush()
        return words
    }

    /// TTML clock values: `27.395`, `1:05.20`, `1:02:03.4`, or a plain number with an `s`
    /// or `ms` unit. Returned in milliseconds.
    static func time(_ value: String?) -> Int? {
        guard let raw = value?.kTrimmed, !raw.isEmpty else { return nil }
        if raw.hasSuffix("ms") { return kDouble(String(raw.dropLast(2))).map(kLong) }
        let stripped = raw.kRemovingSuffix("s")
        let parts = stripped.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let seconds: Double?
        switch parts.count {
        case 1:
            seconds = kDouble(parts[0])
        case 2:
            seconds = kDouble(parts[0]).flatMap { m in kDouble(parts[1]).map { m * 60 + $0 } }
        case 3:
            seconds = kDouble(parts[0]).flatMap { h in
                kDouble(parts[1]).flatMap { m in kDouble(parts[2]).map { h * 3600 + m * 60 + $0 } }
            }
        default:
            seconds = nil
        }
        return seconds.map { kLong($0 * 1000) }
    }
}
