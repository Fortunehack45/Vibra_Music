import Foundation

/// Plain and "enhanced" (A2) LRC: the reader every line-synced source shares (Android:
/// `LrcLib.parseLrc`) and the writer the download path embeds with (Android: `LrcWriter.kt`).
public enum LRCFormat {

    // MARK: Reading

    /// `[mm:ss.xx] words`. Metadata tags carry no timestamp and fall out on their own. A
    /// stamp with no words marks an instrumental break; those are kept, but only where the
    /// silence is long enough to be worth showing — otherwise the line would blink out
    /// between two sung phrases. A stamp with nothing after it closes the final line, so it
    /// always survives.
    ///
    /// Lines written by `enhancedLRC` come back word-synced, with their duet side.
    public static func parse(_ lrc: String) -> [LyricLine] {
        let all = lrc.kLines.compactMap { line -> LyricLine? in
            guard let match = stamp.firstMatch(in: line) else { return nil }
            let body = line.kSubstring(from: match.end)
            // Detect the RTL marker that was written by `enhancedLRC`.
            let (text, alignment) = strippingAlignmentMarker(body)
            return LyricLine(
                timeMs: milliseconds(match.groupValues[1], match.groupValues[2], match.groupValues[3]),
                // Stripped rather than rebuilt from the runs below: the spacing and
                // punctuation between two words belong to the line, and re-joining the words
                // with single spaces would quietly rewrite a line that never had them.
                text: wordStamp.replacing(in: text, with: "").kTrimmed,
                words: wordRuns(text),
                alignment: alignment
            )
        }.kSortedBy(\.timeMs)

        let kept = all.enumerated().filter { index, line in
            if !line.isGap { return true }
            // A trailing stamp closes off the last line — that's the outro.
            guard let next = all.kGet(index + 1) else { return true }
            return next.timeMs - line.timeMs >= lyricMinGapMs
        }.map(\.element)

        // Nothing stands for the intro — LRC files start at the first sung word — so give
        // the run-up its own break when it's long enough.
        guard let first = kept.first else { return kept }
        if !first.isGap && first.timeMs >= lyricMinGapMs {
            return [LyricLine(timeMs: 0, text: "")] + kept
        }
        return kept
    }

    /// Strip the alignment marker written by `enhancedLRC` and return the clean body with
    /// the recovered alignment. The marker is `<R>` — a word-stamp-looking token that never
    /// appears in genuine A2 output — at the very start of the body.
    private static func strippingAlignmentMarker(_ body: String) -> (String, LyricAlignment) {
        if body.hasPrefix(alignmentMarker) {
            return (body.kSubstringAfter(alignmentMarker), .end)
        }
        return (body, .start)
    }

    /// The `<mm:ss.xx>` runs of an "enhanced" A2 line, as words.
    ///
    /// Each run ends where the next one starts, which is why a line written by
    /// `enhancedLRC` closes with a bare stamp: that last one names no word, it just states
    /// where the previous one stopped. A run with no text is therefore a terminator rather
    /// than a word, here and in the files other A2 writers produce.
    ///
    /// Empty for a plain line, which is what keeps `isWordSynced` honest — a line-synced
    /// source stays line-synced through this.
    private static func wordRuns(_ body: String) -> [LyricWord] {
        let marks = wordStamp.allMatches(in: body)
        if marks.isEmpty { return [] }
        let runs = marks.enumerated().map { index, mark -> (Int, String) in
            let until = marks.kGet(index + 1)?.start ?? body.kLength
            return (
                milliseconds(mark.groupValues[1], mark.groupValues[2], mark.groupValues[3]),
                body.kSubstring(mark.end, until)
            )
        }
        return runs.enumerated().compactMap { index, run in
            let (startMs, text) = run
            if text.kIsBlank { return nil }
            // The next run's stamp is this word's end — including when that run is the
            // closing terminator, which is the only thing that gives the last word an end.
            let endMs = runs.kGet(index + 1)?.0 ?? startMs
            return LyricWord(startMs: startMs, endMs: max(endMs, startMs), text: text.kTrimmed)
        }
    }

    /// Two digits mean centiseconds, three mean milliseconds.
    static func milliseconds(_ minutes: String, _ seconds: String, _ fraction: String) -> Int {
        let fractionMs: Int = switch fraction.count {
        case 2: (Int(fraction) ?? 0) * 10
        case 3: Int(fraction) ?? 0
        default: 0
        }
        return (Int(minutes) ?? 0) * 60_000 + (Int(seconds) ?? 0) * 1_000 + fractionMs
    }

    // Three minute digits, not two: `stampText` writes `[100:00.00]` for a line past 99 minutes
    // rather than wrapping it, and a reader that couldn't take that back would lose the line.
    private static let stamp = LyricsRegex(#"\[([0-9]{1,3}):([0-9]{2})[.:]([0-9]{2,3})\]"#)
    private static let wordStamp = LyricsRegex(#"<([0-9]{1,3}):([0-9]{2})[.:]([0-9]{2,3})>"#)

    /// Marker that survives round-trip through file tags and signals RTL (`.end`) alignment.
    static let alignmentMarker = "<R>"

    // MARK: Writing

    /// The name of the container field the word-timed form is written to (MP4 freeform
    /// item, Vorbis comment, Matroska SimpleTag): this app's own, which other players ignore.
    public static let wordLyricsField = "VIBRAMUSIC_LYRICS"

    /// Parsed lines back into the text of an LRC file.
    ///
    /// **Word timings are deliberately dropped.** The way to keep them in a file is the
    /// "enhanced" A2 extension, and a reader that doesn't implement it does not ignore those
    /// stamps, it *shows* them. Line stamps degrade to plain text in the same reader; word
    /// stamps corrupt it. The file is for other players, so it gets the syntax they all read.
    ///
    /// Nothing writes the `[ti:]`/`[ar:]`/`[al:]` header tags either — the container's own
    /// title, artist and album fields already say all three.
    public static func lrc(from lines: [LyricLine]) -> String {
        if lines.isEmpty { return "" }
        // Plain unsynced lyrics have no timestamps — emit clean text rows.
        if !lines.contains(where: { $0.timeMs > 0 }) {
            return lines.map(\.flattenedText).joined(separator: "\n")
        }
        // Sorted here rather than assumed: one line of insurance against a file whose
        // stamps run backwards, which every reader renders as lyrics that jump about.
        return lines.kSortedBy(\.timeMs).map { stampText($0.timeMs) + $0.flattenedText }.joined(separator: "\n")
    }

    /// The same lines as `lrc`, with the word timings kept — the "enhanced" A2 extension.
    ///
    /// This does **not** replace `lrc`: a reader without A2 does not ignore a word stamp, it
    /// shows it. The two are written to different fields — plain LRC to the container's own
    /// lyrics field, where every other player looks, and this to `wordLyricsField`. That is
    /// what lets a downloaded song light up word by word offline.
    ///
    /// Empty when nothing here is word-synced. Each line closes with a bare `<stamp>` at its
    /// end, which is what carries `LyricLine.endMs` across.
    public static func enhancedLRC(from lines: [LyricLine]) -> String {
        if lines.isEmpty { return "" }
        if !lines.contains(where: { $0.isWordSynced || $0.background?.isWordSynced == true }) { return "" }
        return lines.kSortedBy(\.timeMs).map { stampText($0.timeMs) + $0.enhancedBody }.joined(separator: "\n")
    }

    /// `[mm:ss.xx]`, in centiseconds — the two-digit fraction, which has the widest support.
    ///
    /// Built from integers rather than `String(format:)`, which is not a style preference:
    /// the output has to be ASCII digits wherever the device is. Minutes are not wrapped at
    /// 99 — truncating would silently move the line.
    static func stampText(_ timeMs: Int) -> String { "[" + clock(timeMs) + "]" }

    /// The same clock inside angle brackets — one word's start, in A2.
    static func wordStampText(_ timeMs: Int) -> String { "<" + clock(timeMs) + ">" }

    private static func clock(_ timeMs: Int) -> String {
        // A negative stamp is not something to sort or write.
        let total = max(timeMs, 0)
        return pad(total / 60_000) + ":" + pad(total % 60_000 / 1_000) + "." + pad(total % 1_000 / 10)
    }

    private static func pad(_ value: Int) -> String {
        let digits = String(value)
        return digits.count < 2 ? String(repeating: "0", count: 2 - digits.count) + digits : digits
    }
}

extension LyricLine {
    /// The line as one row of text, answering vocal and all. `background` is a display
    /// split and LRC has no way to say that; a stamp of its own would put a second line into
    /// the file where the song has one, so it goes back on the end of the lead.
    fileprivate var flattenedText: String {
        guard let background else { return text }
        return (text + " " + background.text).kTrimmed
    }

    /// One line as stamped word runs, or its plain text when it has none. The answering
    /// vocal rides along on the end, keeping its own stamps.
    fileprivate var enhancedBody: String {
        let runs = timedRuns
        if runs.isEmpty { return flattenedText }
        var out = ""
        // Emit an RTL marker so the offline reader can restore vocal alignment.
        if alignment == .end { out += LRCFormat.alignmentMarker }
        // Clamped to run forwards. A background vocal legitimately starts partway through
        // the lead it answers, so concatenating the two can hand us a stamp earlier than the
        // one before it — and a reader taking each run's end from the next one's start would
        // read that as a negative-length word.
        var previous = timeMs
        for (index, word) in runs.enumerated() {
            let start = max(word.startMs, previous)
            out += LRCFormat.wordStampText(start) + word.text
            if index != runs.count - 1 { out += " " }
            previous = start
        }
        out += LRCFormat.wordStampText(max(runs.map(\.endMs).max() ?? previous, previous))
        return out
    }

    /// The line's words, the answering vocal's after them — or nothing, when the lead has no
    /// timings to anchor them to.
    private var timedRuns: [LyricWord] {
        if words.isEmpty { return [] }
        var answer = [LyricWord]()
        if let background {
            if !background.words.isEmpty {
                answer = background.words
            } else if !background.text.kIsBlank {
                answer = [LyricWord(startMs: background.timeMs, endMs: background.endMs, text: background.text)]
            }
        }
        return words + answer
    }
}
