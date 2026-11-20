import Foundation

// MARK: - Background vocals (Android: BackgroundVocals.kt)

extension Array where Element == LyricLine {
    /// Pulls the answering vocal out of each line and hangs it underneath, as
    /// `LyricLine.background`.
    ///
    /// Only Apple's TTML says outright which spans are the backing voice (`ttm:role="x-bg"`).
    /// Every other provider — LyricsPlus, SimpMusic's rich sync, LRCLIB — writes it into the
    /// line as a bracket:
    ///
    ///     I'm foolishly patient (Foolishly patient)
    ///
    /// Which is a bracket doing the job of a second line, and it showed. The words inside it
    /// are sung *over* the line that follows, so the cursor moved on with the bracket
    /// half-swept and the strip cut it off mid-phrase. Split out, the bracket keeps its own
    /// timings and draws below the lead instead of being dragged through it.
    ///
    /// The parentheses are kept on the text rather than stripped. They are what the provider
    /// published, they are what `LRCFormat.lrc` has to write back out for a saved file to
    /// stay readable in other players, and a smaller line under the lead already says "this
    /// is the answer" without the punctuation being taken away.
    public func withBackgroundVocals() -> [LyricLine] {
        map { $0.splittingTrailingBracket() }
    }

    /// Marks the instrumental stretches with blank lines, the way an LRC file marks them
    /// with a bare timestamp.
    ///
    /// A break is only drawn where the line before it says when its singing stopped — see
    /// `LyricLine.hasKnownEnd`. Given that, the note appears the moment the vocal ends rather
    /// than several seconds later once the next line was due, which is the whole advantage
    /// over the LRC parser's stamp-to-stamp guess. Without it there is nothing to measure
    /// silence against: the distance to the next stamp is the line's own slot, and treating
    /// that as a break puts a note after every single line of a line-synced source.
    func withInstrumentalGaps() -> [LyricLine] {
        guard let firstLine = first else { return self }
        var out = [LyricLine]()
        out.reserveCapacity(count + 4)
        // Nothing stands for the intro, so give the run-up its own break.
        if firstLine.timeMs >= lyricMinGapMs { out.append(LyricLine(timeMs: 0, text: "")) }
        for (index, line) in enumerated() {
            out.append(line)
            guard let next = kGet(index + 1), line.hasKnownEnd else { continue }
            let silence = next.timeMs - line.endMs
            // A marker sharing its line's stamp could never be reached: the cursor takes the
            // last line whose stamp has passed, so the note would sit on top of the line it
            // belongs to and the words would never light up.
            if silence >= lyricMinGapMs && line.endMs > line.timeMs {
                out.append(LyricLine(timeMs: line.endMs, text: ""))
            }
        }
        return out
    }
}

/// Shorter instrumental breaks aren't worth interrupting the line for.
let lyricMinGapMs = 4_000

extension LyricLine {
    fileprivate func splittingTrailingBracket() -> LyricLine {
        // A source that marked its own backing vocal has already said everything guessing
        // from punctuation could, and better.
        if background != nil || isGap { return self }

        guard let open = Self.bracketStart(text) else { return self }
        let lead = text.kSubstring(0, open).kTrimmedEnd
        let backing = text.kSubstring(from: open).kTrimmed
        if lead.isEmpty || !backing.unicodeScalars.contains(where: \.kIsLetterOrDigit) { return self }

        var copy = self
        if words.isEmpty {
            // Line-synced: there is no timing to divide, so the two halves share the line's
            // stamp and simply stack. Both keep the stated end — it is the line's end, and
            // the line is both of them.
            copy.text = lead
            copy.background = LyricLine(timeMs: timeMs, text: backing, sungUntilMs: sungUntilMs)
            return copy
        }

        // `text` is the words joined by single spaces in every word-synced parser here, so
        // the bracket's character offset is a word boundary — unless the bracket opens
        // mid-word ("wait(ing)"), in which case it isn't one and there is nothing to hand
        // the backing line for timing. Leave those be.
        guard let split = Self.indexOfWord(startingAt: open, in: words), split > 0 else { return self }

        let backingWords = Array(words[split...])
        copy.text = lead
        copy.words = Array(words[..<split])
        copy.background = LyricLine(timeMs: backingWords[0].startMs, text: backing, words: backingWords)
        return copy
    }

    /// Index of the word starting at UTF-16 offset `offset` in the joined text.
    private static func indexOfWord(startingAt offset: Int, in words: [LyricWord]) -> Int? {
        var at = 0
        for (index, word) in words.enumerated() {
            if at == offset { return index }
            if at > offset { return nil }
            // The space that joins this word to the next one.
            at += word.text.kLength + 1
        }
        return nil
    }

    /// Where the bracket that closes the line opens (UTF-16 offset), or nil if the line does
    /// not end in one.
    ///
    /// Walked back from the end counting depth, so a nested bracket doesn't split the line
    /// at the inner pair. A line that is *entirely* bracketed is already its own backing line
    /// and has no lead to hang under, so it is left alone.
    private static func bracketStart(_ text: String) -> Int? {
        guard text.hasSuffix(")") else { return nil }
        let units = Array(text.utf16)
        var depth = 0
        for index in units.indices.reversed() {
            switch units[index] {
            case 0x29: depth += 1 // ")"
            case 0x28: // "("
                depth -= 1
                if depth == 0 { return index > 0 ? index : nil }
            default: break
            }
        }
        return nil
    }
}

// MARK: - Duet sides (Android: LyricAlignments.kt)

/// Which side of the panel each line is sung from, given the voice that sang it.
///
/// Not one side per voice: the sides alternate every time the voice changes, which is what
/// keeps a three-way song reading as a conversation instead of putting two of the three on
/// top of each other. A line sung by everyone at once (`group`) belongs to neither side and
/// stays on the left without disturbing whose turn it is.
///
/// The whole thing is flipped at the end if nearly every line came out on the right. That
/// happens when the song opens on the voice this walk starts the alternation away from, and
/// the result is a song laid out entirely down the right-hand side — correct by the rule,
/// and plainly not what was meant.
///
/// Shared by every provider that says who is singing, because the side a line sits on is a
/// property of the song: a listener who changes provider mid-track should not watch the
/// panel turn itself inside out. `types` maps a voice to `person`, `group` or `other`, and a
/// voice with no declaration is taken for a person.
func lineAlignments(singers: [String?], types: [String: String]) -> [LyricAlignment] {
    var left = true
    var lastVoice: String?
    var rightward = 0
    var placed = 0

    let sides = singers.map { singer -> LyricAlignment in
        guard let singer, !singer.isEmpty else { return .start }
        // Apple's two reserved ids carry no declaration of their own.
        let type = types[singer] ?? {
            switch singer {
            case AgentType.groupAgent: return AgentType.group
            case AgentType.otherAgent: return AgentType.other
            default: return AgentType.person
            }
        }()
        placed += 1
        if type == AgentType.group { return .start }

        if lastVoice == nil {
            left = type != AgentType.other
        } else if singer != lastVoice {
            left.toggle()
        }
        lastVoice = singer

        if !left { rightward += 1 }
        return left ? .start : .end
    }

    if placed == 0 || Float(rightward) / Float(placed) < AgentType.mostlyRight { return sides }
    return sides.map { $0 == .start ? .end : .start }
}

private enum AgentType {
    /// `ttm:agent` types, as both TTML and LyricsPlus name them.
    static let person = "person"
    static let group = "group"
    static let other = "other"
    /// Apple's two reserved voices: everyone at once, and the other singer.
    static let groupAgent = "v1000"
    static let otherAgent = "v2000"
    /// Past this share of lines on the right, the whole song is flipped. Not 100%: a chorus
    /// or two sung by the group lands on the left and would otherwise be enough to call it a
    /// genuine duet.
    static let mostlyRight: Float = 0.85
}
