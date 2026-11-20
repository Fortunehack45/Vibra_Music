import XCTest
@testable import Lyrics

/// Reading LRC (ported from Android's `LrcLibTest`) and writing it back (from `LrcWriterTest`).
final class LRCParsingTests: XCTestCase {
    private func words(_ lines: [LyricLine]) -> [String] { lines.sung.map(\.text) }

    func testParsesCentisecondStamps() {
        let lines = LRCFormat.parse("[00:32.07] first line\n[01:05.50] second line").sung
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].timeMs, 32_070)
        XCTAssertEqual(lines[0].text, "first line")
        XCTAssertEqual(lines[1].timeMs, 65_500)
    }

    func testParsesMillisecondStamps() {
        XCTAssertEqual(LRCFormat.parse("[02:03.456] third line").sung.first?.timeMs, 123_456)
    }

    func testDropsMetadataTagsAndShortGaps() {
        let lines = LRCFormat.parse("[ar:Arijit Singh]\n[ti:Zaalima]\n[00:10.00]\n[00:12.00] real words\n")
        // The 2s gap between the two stamps is too short to be worth showing.
        XCTAssertEqual(words(lines), ["real words"])
        XCTAssertEqual(lines.filter(\.isGap).count, 1)
    }

    func testKeepsLongInstrumentalGaps() {
        let lines = LRCFormat.parse("[00:00.00] intro words\n[00:05.00]\n[00:30.00] verse")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[1].isGap)
        XCTAssertEqual(lines[1].timeMs, 5_000)
    }

    func testKeepsATrailingGapAsTheOutro() {
        let lines = LRCFormat.parse("[00:10.00] words\n[04:49.01] ")
        XCTAssertEqual(words(lines), ["words"])
        XCTAssertEqual(lines.last?.timeMs, 289_010)
        XCTAssertEqual(lines.last?.isGap, true)
    }

    func testAddsALeadingGapForALongIntro() {
        let lines = LRCFormat.parse("[00:32.07] first words")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].isGap)
        XCTAssertEqual(lines[0].timeMs, 0)
        XCTAssertEqual(lines[1].text, "first words")
    }

    func testNoLeadingGapWhenSingingStartsStraightAway() {
        let lines = LRCFormat.parse("[00:01.00] straight in")
        XCTAssertEqual(lines.map(\.text), ["straight in"])
    }

    func testSortsOutOfOrderStamps() {
        let lines = LRCFormat.parse("[00:30.00] later\n[00:10.00] earlier")
        XCTAssertEqual(words(lines), ["earlier", "later"])
    }

    func testWindowsLineEndingsAreLineBreaks() {
        XCTAssertEqual(words(LRCFormat.parse("[00:01.00]one\r\n[00:02.00]two\r\n")), ["one", "two"])
    }

    func testReadsTheRealLRCLIBAnswerForGetLucky() throws {
        let synced = try XCTUnwrap(LrcLibProvider.syncedLyrics(inExactAnswer: Fixture.text("lrclib-get-get-lucky.json")))
        let lines = LRCFormat.parse(synced)
        XCTAssertGreaterThan(lines.sung.count, 40)
        XCTAssertTrue(lines.sung.allSatisfy { !$0.isWordSynced })
        XCTAssertTrue(lines.sung.contains { $0.text.hasPrefix("Tile press soft fast press hang") })
        XCTAssertEqual(lines.map(\.timeMs), lines.map(\.timeMs).sorted())
    }

    func testTheSearchFallbackPrefersTheHitClosestInLength() throws {
        let body = try Fixture.text("lrclib-search-get-lucky.json")
        let hits = try XCTUnwrap(LyricsJSON.parse(body)?.array)
        func synced(duration: Double) -> String? {
            hits.first { $0["duration"]?.double == duration }?["syncedLyrics"]?.content
        }
        // The recorded search holds 370 s, 368 s, 248 s and 32 s cuts.
        XCTAssertEqual(LrcLibProvider.bestSyncedLyrics(inSearchAnswer: body, seconds: 30), synced(duration: 32))
        XCTAssertEqual(LrcLibProvider.bestSyncedLyrics(inSearchAnswer: body, seconds: 250), synced(duration: 248))
        // 368 and 370 are equally close to 369: the first listed wins, as on Android.
        XCTAssertEqual(LrcLibProvider.bestSyncedLyrics(inSearchAnswer: body, seconds: 369), synced(duration: 370))
        XCTAssertNil(LrcLibProvider.bestSyncedLyrics(inSearchAnswer: "[]", seconds: 248))
    }

    func testCleansYouTubeNoiseOutOfTheTitle() {
        XCTAssertEqual(LrcLibProvider.clean("Zaalima (From \"Raees\")"), "Zaalima")
        XCTAssertEqual(LrcLibProvider.clean("Kesariya | Official Video"), "Kesariya")
        XCTAssertEqual(LrcLibProvider.clean("Tum Hi Ho [Lyrical]"), "Tum Hi Ho")
        XCTAssertEqual(LrcLibProvider.clean("(Official Video)"), "(Official Video)")
    }
}

final class LRCWriterTests: XCTestCase {

    func testEachLineIsStampedAsMinutesSecondsAndCentiseconds() {
        let lines = [LyricLine(timeMs: 0, text: "first line"), LyricLine(timeMs: 61_230, text: "second line")]
        XCTAssertEqual(LRCFormat.lrc(from: lines), "[00:00.00]first line\n[01:01.23]second line")
    }

    func testMillisecondsAreTruncatedToCentisecondsRatherThanRoundedPastASecond() {
        // 59.999s must not become [01:00.00]: that would reorder it against the next line.
        XCTAssertEqual(LRCFormat.lrc(from: [LyricLine(timeMs: 59_999, text: "x")]), "[00:59.99]x")
    }

    func testStampsAreASCIIDigitsWhateverTheLocale() {
        // Built from integers, never from a locale-aware formatter.
        XCTAssertEqual(LRCFormat.lrc(from: [LyricLine(timeMs: 75_400, text: "x")]), "[01:15.40]x")
        XCTAssertTrue(LRCFormat.lrc(from: [LyricLine(timeMs: 75_400, text: "x")]).unicodeScalars.allSatisfy(\.isASCII))
    }

    func testAStampPastNinetyNineMinutesOverflowsToThreeDigitsRatherThanWrapping() {
        XCTAssertEqual(LRCFormat.lrc(from: [LyricLine(timeMs: 6_000_000, text: "x")]), "[100:00.00]x")
    }

    func testAStampPastNinetyNineMinutesIsReadBackWhereItWasWritten() {
        let written = LRCFormat.lrc(from: [LyricLine(timeMs: 6_000_000, text: "x")])
        XCTAssertEqual(LRCFormat.parse(written).sung.map(\.timeMs), [6_000_000])
    }

    func testAnInstrumentalGapIsWrittenAsABareStamp() {
        let lines = [LyricLine(timeMs: 1_000, text: "first line"), LyricLine(timeMs: 8_000, text: ""), LyricLine(timeMs: 20_000, text: "second line")]
        XCTAssertEqual(LRCFormat.lrc(from: lines), "[00:01.00]first line\n[00:08.00]\n[00:20.00]second line")
    }

    func testLinesAreSortedByTheirStampWhateverOrderTheyArriveIn() {
        let lines = [LyricLine(timeMs: 5_000, text: "later"), LyricLine(timeMs: 1_000, text: "earlier")]
        XCTAssertEqual(LRCFormat.lrc(from: lines), "[00:01.00]earlier\n[00:05.00]later")
    }

    func testWordTimingsAreDroppedAndTheLinesOwnTextIsKeptWhole() {
        let lines = [LyricLine(timeMs: 1_000, text: "two words", words: [
            LyricWord(startMs: 1_000, endMs: 1_400, text: "two"), LyricWord(startMs: 1_400, endMs: 2_000, text: "words"),
        ])]
        let written = LRCFormat.lrc(from: lines)
        XCTAssertEqual(written, "[00:01.00]two words")
        XCTAssertFalse(written.contains("<"))
    }

    /// The backing-vocal split is a display decision; the file gets the line the way every
    /// provider that didn't mark it structurally published it.
    func testAnAnsweringVocalIsWrittenBackOntoTheEndOfItsLead() {
        let lines = [LyricLine(timeMs: 1_000, text: "the lead line", background: LyricLine(timeMs: 1_600, text: "(the answer)"))]
        XCTAssertEqual(LRCFormat.lrc(from: lines), "[00:01.00]the lead line (the answer)")
    }

    func testNoLinesIsEmptyTextRatherThanABlankStamp() {
        XCTAssertEqual(LRCFormat.lrc(from: []), "")
    }

    func testUnsyncedLyricsAreWrittenAsPlainRows() {
        XCTAssertEqual(LRCFormat.lrc(from: [LyricLine(timeMs: 0, text: "a"), LyricLine(timeMs: 0, text: "b")]), "a\nb")
    }

    /// What this writes, the parser reads back to the same stamps and the same words.
    func testWhatItWritesTheParserReadsBackUnchanged() {
        let lines = [
            LyricLine(timeMs: 0, text: ""),
            LyricLine(timeMs: 6_120, text: "first line"),
            LyricLine(timeMs: 12_340, text: "second line"),
            LyricLine(timeMs: 18_000, text: ""),
            LyricLine(timeMs: 25_500, text: "third line"),
        ]
        let reparsed = LRCFormat.parse(LRCFormat.lrc(from: lines))
        XCTAssertEqual(reparsed.map(\.timeMs), lines.map(\.timeMs))
        XCTAssertEqual(reparsed.map(\.text), lines.map(\.text))
    }

    // MARK: Enhanced (A2)

    func testEnhancedLRCKeepsWordTimingsAndTheLinesEnd() {
        let lines = [LyricLine(timeMs: 1_000, text: "two words", words: [
            LyricWord(startMs: 1_000, endMs: 1_400, text: "two"), LyricWord(startMs: 1_400, endMs: 2_000, text: "words"),
        ])]
        let written = LRCFormat.enhancedLRC(from: lines)
        XCTAssertEqual(written, "[00:01.00]<00:01.00>two <00:01.40>words<00:02.00>")
        let read = LRCFormat.parse(written)
        XCTAssertEqual(read.map(\.text), ["two words"])
        XCTAssertEqual(read[0].words.map(\.text), ["two", "words"])
        XCTAssertEqual(read[0].words.map(\.startMs), [1_000, 1_400])
        XCTAssertEqual(read[0].endMs, 2_000)
    }

    func testEnhancedLRCIsEmptyWhenNothingIsWordSynced() {
        XCTAssertEqual(LRCFormat.enhancedLRC(from: lineSynced("a", "b")), "")
    }

    func testEnhancedLRCCarriesTheDuetSideAndBackgroundAcross() {
        var line = wordSynced("call back")[0]
        line.alignment = .end
        line.background = LyricLine(timeMs: 1_200, text: "(back)", words: [LyricWord(startMs: 1_200, endMs: 1_900, text: "(back)")])
        let read = LRCFormat.parse(LRCFormat.enhancedLRC(from: [line])).withBackgroundVocals()
        XCTAssertEqual(read.first?.alignment, .end)
        XCTAssertEqual(read.first?.text, "call back")
        XCTAssertEqual(read.first?.background?.text, "(back)")
        // Clamped to run forwards: the background starts before the lead's last word.
        XCTAssertEqual(read.first?.background?.words.first?.startMs, 1_300)
    }
}
