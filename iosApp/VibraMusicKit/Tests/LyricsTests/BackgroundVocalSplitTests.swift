import XCTest
@testable import Lyrics

/// Only Apple's TTML marks the answering vocal outright. Every other provider writes it into
/// the line as a bracket, and left there it was sung over the *next* line's stamp — so the
/// cursor moved on with the bracket half-swept. These cover the split that pulls it out
/// (ported from Android's `BackgroundVocalTest`; placeholder words, "Heartbreak
/// Anniversary"'s shape).
final class BackgroundVocalSplitTests: XCTestCase {

    private func wordSynced(_ spans: (Int, Int, String)...) -> LyricLine {
        let words = spans.map { LyricWord(startMs: $0.0, endMs: $0.1, text: $0.2) }
        return LyricLine(timeMs: words[0].startMs, text: words.map(\.text).joined(separator: " "), words: words)
    }

    private func split(_ line: LyricLine) -> LyricLine {
        [line].withBackgroundVocals()[0]
    }

    func testATrailingBracketBecomesTheAnsweringLine() {
        let line = split(LyricLine(timeMs: 1_000, text: "lead words (echoed words)"))
        XCTAssertEqual(line.text, "lead words")
        XCTAssertEqual(line.background?.text, "(echoed words)")
    }

    func testTheAnsweringLineTakesTheWordsThatWereInsideTheBracket() throws {
        let line = split(wordSynced((1_000, 1_400, "lead"), (1_400, 1_900, "words"), (2_100, 2_500, "(echoed"), (2_500, 3_200, "words)")))
        XCTAssertEqual(line.text, "lead words")
        XCTAssertEqual(line.words.map(\.text), ["lead", "words"])
        let backing = try XCTUnwrap(line.background)
        XCTAssertEqual(backing.text, "(echoed words)")
        XCTAssertEqual(backing.words.map(\.text), ["(echoed", "words)"])
        // Its own stamp, so it sweeps on its own clock rather than the lead's.
        XCTAssertEqual(backing.timeMs, 2_100)
        XCTAssertTrue(backing.isWordSynced)
    }

    /// The bug the split exists for: the answer runs past the lead's last word, and the line
    /// is not over until it stops.
    func testTheLineEndsWhenTheAnswerDoesNotWhenTheLeadDoes() {
        XCTAssertEqual(split(wordSynced((1_000, 1_400, "lead"), (2_100, 3_200, "(echo)"))).endMs, 3_200)
    }

    func testALineThatIsEntirelyBracketedIsLeftAsItIs() {
        // It is already its own line; there is no lead to hang it under.
        let line = split(LyricLine(timeMs: 1_000, text: "(ooh ooh)"))
        XCTAssertEqual(line.text, "(ooh ooh)")
        XCTAssertNil(line.background)
    }

    func testABracketInTheMiddleOfALineIsLeftAlone() {
        let line = split(LyricLine(timeMs: 1_000, text: "a (parenthetical) aside"))
        XCTAssertEqual(line.text, "a (parenthetical) aside")
        XCTAssertNil(line.background)
    }

    func testABracketOpeningMidWordIsNotASecondVoice() {
        // "wait(ing)" is one word; there is no word boundary to split on.
        let line = split(wordSynced((1_000, 1_400, "still"), (1_400, 2_000, "wait(ing)")))
        XCTAssertEqual(line.text, "still wait(ing)")
        XCTAssertNil(line.background)
    }

    func testNestingSplitsAtTheOuterBracket() {
        let line = split(LyricLine(timeMs: 1_000, text: "lead (echo (twice))"))
        XCTAssertEqual(line.text, "lead")
        XCTAssertEqual(line.background?.text, "(echo (twice))")
    }

    func testABracketWithNoWordsInItIsNotASecondVoice() {
        let line = split(LyricLine(timeMs: 1_000, text: "lead words (!)"))
        XCTAssertEqual(line.text, "lead words (!)")
        XCTAssertNil(line.background)
    }

    func testALineSyncedAnswerSharesTheLinesStampAndItsStatedEnd() {
        let line = split(LyricLine(timeMs: 1_000, text: "lead words (echo)", sungUntilMs: 4_000))
        XCTAssertEqual(line.text, "lead words")
        XCTAssertEqual(line.background?.timeMs, 1_000)
        XCTAssertEqual(line.background?.sungUntilMs, 4_000)
        XCTAssertEqual(line.endMs, 4_000)
    }

    func testASourceThatMarkedItsOwnAnswerIsNotSecondGuessed() {
        let marked = LyricLine(timeMs: 1_000, text: "lead words (already split)", background: LyricLine(timeMs: 1_500, text: "(the real answer)"))
        XCTAssertEqual(split(marked), marked)
    }

    func testInstrumentalBreaksAreLeftUntouched() {
        let line = split(LyricLine(timeMs: 1_000, text: ""))
        XCTAssertTrue(line.isGap)
        XCTAssertNil(line.background)
    }

    func testANonLatinLeadSplitsOnUTF16Offsets() {
        let line = split(wordSynced((0, 500, "안녕"), (500, 900, "(안녕)")))
        XCTAssertEqual(line.text, "안녕")
        XCTAssertEqual(line.background?.words.map(\.text), ["(안녕)"])
    }
}
