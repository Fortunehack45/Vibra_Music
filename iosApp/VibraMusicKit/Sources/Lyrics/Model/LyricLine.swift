import Foundation
import os

/// One word of a line, with the stretch of the song it is sung over.
///
/// Apple's TTML splits long words into syllables; those are merged back into whole words
/// on the way in, so `startMs` is the first syllable's start and `endMs` the last one's
/// end. Whole words are what the sweep needs — a highlight that ran across "e" and "nough"
/// separately reads as a stutter.
public struct LyricWord: Hashable, Sendable, Codable {
    public var startMs: Int
    public var endMs: Int
    public var text: String

    public init(startMs: Int, endMs: Int, text: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
    }
}

/// Which side of the panel a line is sung from.
///
/// A duet is written in TTML as a `ttm:agent` per line, and Apple lays the two voices out
/// on opposite sides so a call-and-response reads as two people rather than one long verse.
/// `.start` is the default and the only side a single-voice song ever uses — see
/// `lineAlignments` for how the sides are worked out from the agents, which is not simply
/// "one agent per side".
public enum LyricAlignment: String, Hashable, Sendable, Codable {
    case start
    case end
}

/// One synced line. `timeMs` is when it starts; a blank `text` is an instrumental
/// stretch — LRC files mark those with a bare timestamp.
///
/// `words` is populated only by the providers that carry word-level timing (BetterLyrics,
/// LyricsPlus, SimpMusic's rich sync…). LRCLIB has none, so a line from there highlights
/// whole; see `isWordSynced`.
///
/// `sungUntilMs` is the line's own end where a line-synced provider states one, which is
/// what lets an interlude be told apart from a slowly sung line.
///
/// `background` is the answering vocal — the "(ooh)" or the echoed half-phrase a second
/// voice sings over the lead. It is a line in its own right, with its own stamp and its own
/// words, because that is what it is: it starts partway through the line it answers and
/// routinely runs past the *next* line's stamp. Run into `text` it dragged the sweep along
/// with it, and the cursor — which takes the last line whose stamp has passed — moved on
/// before the bracket had been sung, so the tail of the line was skipped. Kept apart it
/// draws underneath the lead on its own clock. Never nested: a background line's own
/// `background` is always nil.
///
/// Character offsets (`revealedChars`, `wordSpans`) are UTF-16 offsets into `text`, the
/// unit `NSString`/TextKit ranges use — the same unit the Android code measured in.
public struct LyricLine: Sendable {
    public var timeMs: Int { didSet { invalidate() } }
    public var text: String { didSet { invalidate() } }
    public var words: [LyricWord] { didSet { invalidate() } }
    public var sungUntilMs: Int? { didSet { invalidate() } }
    public var alignment: LyricAlignment

    public var background: LyricLine? {
        get { backgroundBox?.line }
        set { backgroundBox = newValue.map(LyricLineBox.init); invalidate() }
    }

    /// Display-only translation: drive its sweep and bloom from the original vocal. See
    /// `LyricsTranslator` — a translated sentence cannot keep the source's word boundaries,
    /// so it borrows the source's character progress instead.
    public var timingSource: LyricLine? {
        get { timingSourceBox?.line }
        set { timingSourceBox = newValue.map(LyricLineBox.init) }
    }

    private var backgroundBox: LyricLineBox?
    private var timingSourceBox: LyricLineBox?
    /// Derived values computed once per distinct line rather than once per frame; replaced
    /// (never mutated) whenever a field it depends on changes, so copies never share a stale one.
    private var cache = LyricLineCache()

    public init(
        timeMs: Int,
        text: String,
        words: [LyricWord] = [],
        sungUntilMs: Int? = nil,
        background: LyricLine? = nil,
        alignment: LyricAlignment = .start,
        timingSource: LyricLine? = nil
    ) {
        self.timeMs = timeMs
        self.text = text
        self.words = words
        self.sungUntilMs = sungUntilMs
        self.alignment = alignment
        self.backgroundBox = background.map(LyricLineBox.init)
        self.timingSourceBox = timingSource.map(LyricLineBox.init)
    }

    private mutating func invalidate() { cache = LyricLineCache() }

    public var isGap: Bool { text.isEmpty }

    public var isWordSynced: Bool { !words.isEmpty }

    /// Where each of `words` sits in `text`, as UTF-16 ranges.
    ///
    /// Walked from where the last one ended rather than searched from the start, so a word
    /// repeated in the line lines up with its own occurrence — the same walk
    /// `revealedChars` does, kept once because the rise reads it on every frame of the line
    /// being sung rather than once as it passes.
    public var wordSpans: [Range<Int>] {
        cache.wordSpans { [text, words] in
            var offset = 0
            return words.map { word in
                let start = text.kIndexOf(word.text, from: offset) ?? offset
                let end = start + word.text.kLength
                offset = end
                return start..<end
            }
        }
    }

    /// Whether anything on this line is off the floor at `positionMs`.
    ///
    /// Two comparisons, so the lines that are not being sung — which is every line but one,
    /// on every frame — settle the question without walking their words.
    public func isLifted(_ positionMs: Int) -> Bool {
        guard let first = words.first else { return false }
        if positionMs <= first.startMs { return false }
        // A word animated letter by letter runs on past the ordinary fall — its last letter
        // only starts moving as the word ends. Stopping at the fall would drop that letter
        // back to the line mid-swell.
        return Float(positionMs) < Float(words[words.count - 1].endMs) + lyricRiseMs || isGrowing(positionMs)
    }

    /// How far the word covering `positionMs` has lifted, 0…1.
    ///
    /// Apple Music's words don't only light up, they rise as they land and settle back once
    /// they are past — the lift travelling along the line is most of what separates singing
    /// from a bar sliding across the text. Up from the word's own start and down from its
    /// own end, both over `lyricRiseMs`, so a word held longer than that reaches the top and
    /// rests there while patter only ever gets part of the way up.
    public func wordLift(_ index: Int, _ positionMs: Int) -> Float {
        guard let word = words.kGet(index) else { return 0 }
        let rising = kClamp(Float(positionMs - word.startMs) / lyricRiseMs, 0, 1)
        let falling = kClamp(1 - Float(positionMs - word.endMs) / lyricRiseMs, 0, 1)
        return lyricSmooth(min(rising, falling))
    }

    /// Whether anything actually told us when the singing stops, rather than only when it
    /// starts. Word timings carry it, and so does a provider that stamps the line's own end.
    ///
    /// The distance to the next line's stamp is *not* evidence of an end: that distance is
    /// the line's own slot, and on a line-synced source it is routinely ten seconds for a
    /// line sung over all ten of them.
    public var hasKnownEnd: Bool { !words.isEmpty || sungUntilMs != nil }

    /// When the last word finishes — or the line's own end where the provider gave one, or
    /// `timeMs` when nothing did. Check `hasKnownEnd` before reading a silence out of this.
    ///
    /// The answering vocal counts: it is still this line being sung, and it regularly holds
    /// a note past the lead's last word.
    public var endMs: Int {
        let lead = words.last?.endMs ?? sungUntilMs ?? timeMs
        return max(lead, background?.endMs ?? lead)
    }

    /// How far through the line the singing has got, as a fractional UTF-16 index into
    /// `text`. The sweep reveals up to this character.
    ///
    /// Within a word it interpolates across that word's own span, so a held note draws
    /// slowly and a rattled-off one snaps. Whitespace between two words is credited to the
    /// gap between them: it fills as the singer moves on rather than jumping ahead of the
    /// next word's first letter.
    public func revealedChars(_ positionMs: Int) -> Float {
        if let source = timingSource {
            if source.text.isEmpty { return 0 }
            return kClamp(source.revealedChars(positionMs) / Float(source.text.kLength), 0, 1) * Float(text.kLength)
        }
        if words.isEmpty { return positionMs >= timeMs ? Float(text.kLength) : 0 }
        var offset = 0
        for (index, word) in words.enumerated() {
            // Where this word sits in `text`. Built by walking rather than searching, so a
            // word repeated in the line still lines up.
            let start = text.kIndexOf(word.text, from: offset) ?? offset
            let end = start + word.text.kLength
            if positionMs < word.startMs { return Float(start) }
            if positionMs < word.endMs {
                let span = max(word.endMs - word.startMs, 1)
                let through = Float(positionMs - word.startMs) / Float(span)
                return Float(start) + through * Float(word.text.kLength)
            }
            // Past this word: the trailing space fills over the pause before the next one,
            // so the highlight keeps creeping instead of resting on the word's last letter.
            if let next = words.kGet(index + 1), positionMs < next.startMs {
                let gapStart = text.kIndexOf(next.text, from: end) ?? end
                let pause = max(next.startMs - word.endMs, 1)
                let through = Float(positionMs - word.endMs) / Float(pause)
                return Float(end) + through * Float(gapStart - end)
            }
            offset = end
        }
        return Float(text.kLength)
    }

    /// How much of a word's lift is left at `positionMs` — 1 while it is being sung, easing
    /// to 0 over `lyricRiseMs` once it is past. Split out of `wordLift` because a word
    /// animated letter by letter has its own way up but settles back down the same way
    /// every other word does.
    public func wordFall(_ index: Int, _ positionMs: Int) -> Float {
        guard let word = words.kGet(index) else { return 0 }
        return lyricSmooth(kClamp(1 - Float(positionMs - word.endMs) / lyricRiseMs, 0, 1))
    }

    /// The words held long enough to be worth animating letter by letter.
    ///
    /// A word carried for a second and a half is the one moment in a line where there is
    /// time to see anything happen to it; each letter of one swells, lifts and lights in
    /// turn — see `GrowingWord`. Rare by design: most lines have none at all.
    public var growingWords: [GrowingWord] {
        cache.growingWords { [words] in
            words.enumerated().compactMap { index, word in
                word.canGrow ? GrowingWord(index: index, word: word) : nil
            }
        }
    }

    /// The letter-by-letter treatment for word `index`, where it has earned one.
    public func growingAt(_ index: Int) -> GrowingWord? {
        growingWords.first { $0.index == index }
    }

    /// Whether any word on this line is mid-flight at `positionMs`.
    public func isGrowing(_ positionMs: Int) -> Bool {
        growingWords.contains { positionMs >= $0.startMs && positionMs <= $0.restsAtMs }
    }
}

extension LyricLine: Equatable {
    public static func == (lhs: LyricLine, rhs: LyricLine) -> Bool {
        lhs.timeMs == rhs.timeMs && lhs.text == rhs.text && lhs.words == rhs.words
            && lhs.sungUntilMs == rhs.sungUntilMs && lhs.alignment == rhs.alignment
            && lhs.background == rhs.background && lhs.timingSource == rhs.timingSource
    }
}

extension LyricLine: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(timeMs)
        hasher.combine(text)
        hasher.combine(words)
        hasher.combine(sungUntilMs)
        hasher.combine(alignment)
        hasher.combine(background)
    }
}

extension LyricLine: Codable {
    private enum CodingKeys: String, CodingKey {
        case timeMs, text, words, sungUntilMs, background, alignment, timingSource
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            timeMs: try container.decode(Int.self, forKey: .timeMs),
            text: try container.decode(String.self, forKey: .text),
            words: try container.decodeIfPresent([LyricWord].self, forKey: .words) ?? [],
            sungUntilMs: try container.decodeIfPresent(Int.self, forKey: .sungUntilMs),
            background: try container.decodeIfPresent(LyricLine.self, forKey: .background),
            alignment: try container.decodeIfPresent(LyricAlignment.self, forKey: .alignment) ?? .start,
            timingSource: try container.decodeIfPresent(LyricLine.self, forKey: .timingSource)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timeMs, forKey: .timeMs)
        try container.encode(text, forKey: .text)
        if !words.isEmpty { try container.encode(words, forKey: .words) }
        try container.encodeIfPresent(sungUntilMs, forKey: .sungUntilMs)
        try container.encodeIfPresent(background, forKey: .background)
        if alignment != .start { try container.encode(alignment, forKey: .alignment) }
        try container.encodeIfPresent(timingSource, forKey: .timingSource)
    }
}

extension LyricLine: CustomDebugStringConvertible {
    public var debugDescription: String {
        var parts = ["\(timeMs)", "\"\(text)\""]
        if !words.isEmpty { parts.append("words: \(words.count)") }
        if let sungUntilMs { parts.append("until: \(sungUntilMs)") }
        if alignment != .start { parts.append("end-aligned") }
        if let background { parts.append("bg: \(background.debugDescription)") }
        return "LyricLine(" + parts.joined(separator: ", ") + ")"
    }
}

/// Lets `LyricLine` hold another `LyricLine` (a struct cannot contain itself directly).
private final class LyricLineBox: Sendable {
    let line: LyricLine
    init(_ line: LyricLine) { self.line = line }
}

/// Memo for the two derived values the renderer asks for on every frame. Thread-safe so a
/// line can be read from a render loop and a background task at once.
private final class LyricLineCache: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var spans: [Range<Int>]?
    private var growing: [GrowingWord]?

    func wordSpans(_ compute: () -> [Range<Int>]) -> [Range<Int>] {
        lock.lock()
        defer { lock.unlock() }
        if let spans { return spans }
        let value = compute()
        spans = value
        return value
    }

    func growingWords(_ compute: () -> [GrowingWord]) -> [GrowingWord] {
        lock.lock()
        defer { lock.unlock() }
        if let growing { return growing }
        let value = compute()
        growing = value
        return value
    }
}

/// How long a word takes to rise, and to settle back down once it is past.
let lyricRiseMs: Float = 700

/// Ease in and out of the ends, so the lift has no corners on it.
@inline(__always)
func lyricSmooth(_ fraction: Float) -> Float { fraction * fraction * (3 - 2 * fraction) }
