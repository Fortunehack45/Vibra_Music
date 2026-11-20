import XCTest
@testable import Lyrics

/// Word-level timing in every format that carries it, the instrumental breaks between
/// lines, and the arithmetic of the sweep (ported from Android's `WordSyncTest`).
final class WordSyncTests: XCTestCase {

    // MARK: Apple TTML, as BetterLyrics serves it

    /// Trimmed from a live lyrics-api.boidu.dev response.
    private let ttml = """
    <tt xmlns="http://www.w3.org/ns/ttml" itunes:timing="Word" xml:lang="en">
      <body dur="3:21.570">
        <div begin="27.395" end="32.529" itunes:songPart="Verse">
          <p begin="27.395" end="28.960" itunes:key="L1" ttm:agent="v1">
            <span begin="27.395" end="27.549">Paint</span> <span begin="27.549" end="27.740">frame</span> <span begin="27.740" end="28.077">clever</span> <span begin="28.077" end="28.960">paper</span>
          </p>
          <p begin="30.189" end="32.529" itunes:key="L2" ttm:agent="v1">
            <span begin="30.189" end="30.396">shake</span> <span begin="31.839" end="31.996">q</span><span begin="31.996" end="32.529">uiet</span>
          </p>
        </div>
      </body>
    </tt>
    """

    func testReadsWordTimingsOutOfAppleTTML() {
        let lines = TTMLLyrics.parse(ttml).sung
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].text, "Paint frame clever paper")
        XCTAssertEqual(lines[0].timeMs, 27_395)
        XCTAssertTrue(lines[0].isWordSynced)
        XCTAssertEqual(lines[0].words.map(\.text), ["Paint", "frame", "clever", "paper"])
        XCTAssertEqual(lines[0].words[0].endMs, 27_549)
        XCTAssertEqual(lines[0].endMs, 28_960)
    }

    func testMergesAdjacentSpansWithNoSpaceBetweenThemIntoOneWord() {
        // "e" + "nough" are separate spans; split, they would render "e nough".
        let line = TTMLLyrics.parse(ttml).sung[1]
        XCTAssertEqual(line.text, "shake quiet")
        XCTAssertEqual(line.words.map(\.text), ["shake", "quiet"])
        XCTAssertEqual(line.words[1].startMs, 31_839)
        XCTAssertEqual(line.words[1].endMs, 32_529)
    }

    /// A span holding only a space is the gap between two words, the same as a text node.
    func testATimedSpanOfOnlyWhitespaceSeparatesTheWordsAroundIt() throws {
        let line = try XCTUnwrap(TTMLLyrics.parse("""
        <tt><body><div>
          <p begin="27.395" end="27.9"><span begin="27.395" end="27.549">I</span><span begin="27.549" end="27.600"> </span><span begin="27.600" end="27.9">been</span></p>
        </div></body></tt>
        """).sung.first)
        XCTAssertEqual(line.text, "I been")
        XCTAssertEqual(line.words.map(\.text), ["I", "been"])
        XCTAssertEqual(line.words[1].startMs, 27_600)
    }

    func testSkipsTranslationsAndHangsBackgroundVocalsUnderTheLead() throws {
        let lines = TTMLLyrics.parse("""
        <tt><body><div>
          <p begin="1.0" end="2.0">
            <span begin="1.0" end="2.0">hello</span>
            <span ttm:role="x-bg" begin="1.5" end="2.4"><span begin="1.5" end="2.4">(ooh)</span></span>
            <span ttm:role="x-translation" xml:lang="es" begin="1.0" end="2.0">hola</span>
          </p>
        </div></body></tt>
        """).sung
        let line = try XCTUnwrap(lines.first)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(line.text, "hello")
        XCTAssertEqual(line.background?.text, "(ooh)")
        // Its own stamp, not the lead's — it starts partway through the line.
        XCTAssertEqual(line.background?.timeMs, 1_500)
        XCTAssertEqual(line.background?.isWordSynced, true)
        // And the line is not over until the answer is.
        XCTAssertEqual(line.endMs, 2_400)
    }

    /// A backing span written as a single timed leaf, with no syllables in it.
    func testReadsABackgroundVocalThatIsOneTimedSpan() throws {
        let line = try XCTUnwrap(TTMLLyrics.parse("""
        <tt><body><div>
          <p begin="1.0" end="2.0">
            <span begin="1.0" end="2.0">hello</span>
            <span ttm:role="x-bg" begin="1.5" end="2.0">(ooh)</span>
          </p>
        </div></body></tt>
        """).sung.first)
        XCTAssertEqual(line.text, "hello")
        XCTAssertEqual(line.background?.text, "(ooh)")
    }

    func testFallsBackToPlainTextForLineSyncedTTML() throws {
        let lines = TTMLLyrics.parse(#"<tt><body><div><p begin="00:12.50">just a line</p></div></body></tt>"#).sung
        let line = try XCTUnwrap(lines.first)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(line.text, "just a line")
        XCTAssertEqual(line.timeMs, 12_500)
        XCTAssertTrue(line.words.isEmpty)
    }

    /// Two named voices trading lines, as Apple writes a duet.
    private let duet = """
    <tt xmlns="http://www.w3.org/ns/ttml">
      <head><metadata>
        <ttm:agent type="person" xml:id="v1"/>
        <ttm:agent type="person" xml:id="v2"/>
        <ttm:agent type="group" xml:id="v1000"/>
      </metadata></head>
      <body><div>
        <p begin="1.0" end="2.0" ttm:agent="v1">mine</p>
        <p begin="2.0" end="3.0" ttm:agent="v2">yours</p>
        <p begin="3.0" end="4.0" ttm:agent="v2">still yours</p>
        <p begin="4.0" end="5.0" ttm:agent="v1">mine again</p>
        <p begin="5.0" end="6.0" ttm:agent="v1000">both of us</p>
      </div></body>
    </tt>
    """

    func testLaysADuetOutOnAlternatingSides() {
        XCTAssertEqual(
            TTMLLyrics.parse(duet).sung.map(\.alignment),
            // The same voice twice running stays where it was: the side changes when the
            // singer does. Sung by everyone, the last belongs to neither side.
            [.start, .end, .end, .start, .start]
        )
    }

    func testASongWithOneVoiceIsAllOnOneSide() {
        XCTAssertEqual(TTMLLyrics.parse(ttml).sung.map(\.alignment), [.start, .start])
    }

    func testASongThatWouldLandEntirelyOnTheRightIsFlippedBack() {
        // One voice, declared `other` — the side the walk starts away from.
        let sides = TTMLLyrics.parse("""
        <tt><head><metadata><ttm:agent type="other" xml:id="v2"/></metadata></head>
        <body><div>
          <p begin="1.0" end="2.0" ttm:agent="v2">one</p>
          <p begin="2.0" end="3.0" ttm:agent="v2">two</p>
        </div></body></tt>
        """).sung.map(\.alignment)
        XCTAssertEqual(sides, [.start, .start])
    }

    func testParsesEveryTTMLClockShape() {
        XCTAssertEqual(TTMLLyrics.time("27.395"), 27_395)
        XCTAssertEqual(TTMLLyrics.time("1:05.20"), 65_200)
        XCTAssertEqual(TTMLLyrics.time("1:02:03.4"), 3_723_400)
        XCTAssertEqual(TTMLLyrics.time("1.5s"), 1_500)
        XCTAssertEqual(TTMLLyrics.time("250ms"), 250)
        XCTAssertNil(TTMLLyrics.time(""))
        XCTAssertNil(TTMLLyrics.time(nil))
    }

    func testBadXMLYieldsNothingRatherThanThrowing() {
        XCTAssertEqual(TTMLLyrics.parse("<tt><body><p begin="), [])
    }

    func testAnXMLEntityInsideASpanStaysInItsWord() {
        let line = TTMLLyrics.parse(#"<tt><body><p begin="1" end="2"><span begin="1" end="1.5">rock&amp;</span><span begin="1.5" end="2">roll</span></p></body></tt>"#).sung
        XCTAssertEqual(line.first?.words.map(\.text), ["rock&roll"])
    }

    /// The real document BiniLyrics served for "Get Lucky" (radio edit): Apple's word timing
    /// with a second voice and backing vocals.
    func testParsesARealAppleDocument() throws {
        let lines = TTMLLyrics.parse(try Fixture.text("binilyrics-USQX91300809.ttml"))
        let sung = lines.sung
        XCTAssertGreaterThan(sung.count, 40)
        XCTAssertTrue(sung.allSatisfy(\.isWordSynced))
        XCTAssertEqual(sung.first?.text, "Tile press soft fast press hang, shadow")
        XCTAssertEqual(sung.first?.timeMs, 14_865)
        // The intro before the first word is an instrumental break.
        XCTAssertTrue(lines[0].isGap)
        // Sorted, and every word inside its own line's run.
        XCTAssertEqual(sung.map(\.timeMs), sung.map(\.timeMs).sorted())
        XCTAssertTrue(sung.contains { $0.background != nil })
        // Two declared voices, so some lines sit on the other side.
        XCTAssertTrue(sung.contains { $0.alignment == .end })
    }

    // MARK: Enhanced LRC, as SimpMusic serves rich sync

    func testReadsWordTimingsOutOfEnhancedLRC() {
        let lines = EnhancedLRC.parse("""
        [00:27.39]<00:27.39>Paint <00:27.54>frame <00:27.74>clever <00:28.07>paper
        [00:30.18]<00:30.18>pillow <00:30.39>shop <00:30.64>drum
        """).sung
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].text, "Paint frame clever paper")
        XCTAssertEqual(lines[0].words.map(\.text), ["Paint", "frame", "clever", "paper"])
        // Only starts are written down, so a word ends where the next begins...
        XCTAssertEqual(lines[0].words[0].endMs, 27_540)
        // ...and the last word of a line ends where the next line starts.
        XCTAssertEqual(lines[0].words.last?.endMs, 30_180)
    }

    func testPlainLRCIsLeftForTheLineSyncedParser() {
        XCTAssertEqual(EnhancedLRC.parse("[00:12.00] no word stamps here\n[00:15.00] none here either"), [])
    }

    func testDecodesTheHTMLEntitiesSimpMusicEscapes() {
        XCTAssertEqual(EnhancedLRC.parse("[00:01.00]<00:01.00>don&#x27;t <00:01.50>stop").sung.first?.text, "don't stop")
    }

    func testDoesNotDoubleDecodeAnEscapedAmpersand() {
        XCTAssertEqual(EnhancedLRC.decodeEntities("&amp;#x27;"), "&#x27;")
    }

    // MARK: LyricsPlus / YouLy+ syllables

    private func singer(_ id: String) -> LyricsJSON {
        var object = LyricsJSONObject()
        object["singer"] = .string(id)
        return .object(object)
    }

    /// The same duet the TTML tests cover, as LyricsPlus states it.
    func testLaysOutALyricsPlusDuetFromTheVoicesItNames() {
        let sides = LyricsPlusProvider.parse(.init(
            lines: [
                .init(time: 1_000, duration: 1_000, text: "mine", element: singer("v1")),
                .init(time: 2_000, duration: 1_000, text: "yours", element: singer("v2")),
                .init(time: 3_000, duration: 1_000, text: "still yours", element: singer("v2")),
                .init(time: 4_000, duration: 1_000, text: "mine again", element: singer("v1")),
                .init(time: 5_000, duration: 1_000, text: "both", element: singer("v1000")),
            ],
            agents: [("v1", "person", nil), ("v2", "person", nil), ("v1000", "group", nil)]
        )).sung.map(\.alignment)
        XCTAssertEqual(sides, [.start, .end, .end, .start, .start])
    }

    func testAVoiceNamedByAliasIsMatchedToItsDeclaration() {
        let sides = LyricsPlusProvider.parse(.init(
            lines: [
                .init(time: 1_000, duration: 500, text: "solo", element: singer("v2")),
                .init(time: 2_000, duration: 500, text: "everyone", element: singer("v1")),
            ],
            // Declared under one key, referred to by another.
            agents: [("agent1", "group", "v1")]
        )).sung.map(\.alignment)
        // A group line stays left beside the lead. Without the alias v1 would read as a
        // second person answering, and sit on the right.
        XCTAssertEqual(sides, [.start, .start])
    }

    func testTheOlderTagListStillMarksTheAnsweringSide() {
        let sides = LyricsPlusProvider.parse(.init(lines: [
            .init(time: 1_000, duration: 500, text: "mine"),
            .init(time: 2_000, duration: 500, text: "yours", element: .array([.string("opposite")])),
        ])).sung.map(\.alignment)
        XCTAssertEqual(sides, [.start, .end])
    }

    func testAPayloadThatSaysNothingAboutVoicesStaysOnOneSide() {
        let sides = LyricsPlusProvider.parse(.init(lines: [
            .init(time: 1_000, duration: 500, text: "one"),
            .init(time: 2_000, duration: 500, text: "two"),
        ])).sung.map(\.alignment)
        XCTAssertEqual(sides, [.start, .start])
    }

    func testMergesLyricsPlusSyllablesOnTheirTrailingSpace() throws {
        let lines = LyricsPlusProvider.parse(.init(type: "Word", lines: [
            .init(time: 30_189, duration: 2_340, text: "long enough", syllabus: [
                .init(time: 30_189, duration: 341, text: "long "),
                .init(time: 31_839, duration: 157, text: "e"),
                .init(time: 31_996, duration: 533, text: "nough"),
            ]),
        ])).sung
        let line = try XCTUnwrap(lines.first)
        XCTAssertEqual(line.text, "long enough")
        XCTAssertEqual(line.words.map(\.text), ["long", "enough"])
        XCTAssertEqual(line.words[0].startMs, 30_189)
        XCTAssertEqual(line.words[1].endMs, 32_529)
    }

    // MARK: Instrumental breaks

    private func lineSyncedPlus(_ rows: [(Int, Int?, String)]) -> [LyricLine] {
        LyricsPlusProvider.parse(.init(type: "Line", lines: rows.map { .init(time: $0.0, duration: $0.1, text: $0.2, syllabus: []) }))
    }

    /// "Qayde Se", as LyricsPlus actually serves it: `type: Line`, empty syllabus, and each
    /// line's duration running right up to the next stamp. Ten seconds between stamps is one
    /// line sung over ten seconds, not a ten-second break.
    func testASlowlySungLineSyncedSongGetsNoBreakBetweenItsLines() {
        let lines = lineSyncedPlus([
            (19_740, 10_020, "दिल जला के मुस्कुराने की जो आदत हुई है मुझे"),
            (29_760, 9_910, "लग रहा है, क़ायदे से अब मोहब्बत हुई है मुझे"),
            (39_670, 10_000, "मेरी तुम्हीं से है जवाब-दारी"),
        ])
        // Only the 19.7s run-up before the first word.
        XCTAssertEqual(lines.filter(\.isGap).count, 1)
        XCTAssertTrue(lines[0].isGap)
        XCTAssertEqual(lines.sung.count, 3)
    }

    /// A break stamped at the same millisecond as a line shadows it forever, because the
    /// cursor takes the *last* line whose stamp has passed.
    func testNoBreakEverSharesAStampWithTheLineItFollows() {
        let lines = lineSyncedPlus([(19_740, 10_020, "one"), (29_760, 9_910, "two"), (39_670, 10_000, "three")])
        let sungStamps = Set(lines.sung.map(\.timeMs))
        XCTAssertEqual(lines.filter { $0.isGap && $0.timeMs > 0 }, [], "these lines run right up to the next stamp")
        XCTAssertEqual(lines.filter { $0.isGap && sungStamps.contains($0.timeMs) }, [])

        // And where a break is real it is stamped when the singing stopped, not on a line.
        let withBreaks = lineSyncedPlus([(1_000, 2_000, "one"), (30_000, 2_000, "two"), (60_000, 2_000, "three")])
        let breaks = withBreaks.filter { $0.isGap && $0.timeMs > 0 }
        XCTAssertEqual(breaks.map(\.timeMs), [3_000, 32_000])
        let stamps = Set(withBreaks.sung.map(\.timeMs))
        XCTAssertEqual(breaks.filter { stamps.contains($0.timeMs) }, [])
    }

    /// With no duration to go on, the distance to the next stamp proves nothing.
    func testALineSyncedSourceWithNoDurationsGetsNoSynthesisedBreaks() {
        XCTAssertEqual(lineSyncedPlus([(1_000, nil, "one"), (20_000, nil, "two")]).filter(\.isGap).count, 0)
    }

    /// A stated end well short of the next line is a real break, and is drawn.
    func testAStatedLineEndShortOfTheNextStampIsMarkedAsABreak() throws {
        let lines = lineSyncedPlus([(1_000, 2_000, "before the solo"), (30_000, 2_000, "after the solo")])
        let gap = try XCTUnwrap(lines.first { $0.isGap && $0.timeMs > 0 })
        // The note lands when the singing stopped, not when the next line was due.
        XCTAssertEqual(gap.timeMs, 3_000)
    }

    /// Same for line-synced TTML, where the end lives on the `<p>`.
    func testLineSyncedTTMLTakesItsBreakFromTheParagraphEnd() {
        let lines = TTMLLyrics.parse("""
        <tt><body><div>
          <p begin="1.0" end="3.0">before the solo</p>
          <p begin="30.0" end="32.0">after the solo</p>
        </div></body></tt>
        """)
        XCTAssertEqual(lines.sung.count, 2)
        XCTAssertEqual(lines.first { $0.isGap && $0.timeMs > 0 }?.timeMs, 3_000)
    }

    // MARK: The sweep's own arithmetic

    private let line = LyricLine(
        timeMs: 1_000,
        text: "one two",
        words: [LyricWord(startMs: 1_000, endMs: 1_500, text: "one"), LyricWord(startMs: 2_000, endMs: 2_400, text: "two")]
    )

    func testRevealRunsAcrossAWordOverThatWordsOwnSpan() {
        XCTAssertEqual(line.revealedChars(500), 0, accuracy: 0.01)
        XCTAssertEqual(line.revealedChars(1_000), 0, accuracy: 0.01)
        // Halfway through "one".
        XCTAssertEqual(line.revealedChars(1_250), 1.5, accuracy: 0.01)
        XCTAssertEqual(line.revealedChars(1_500), 3, accuracy: 0.01)
    }

    func testThePauseBetweenWordsFillsTheSpaceBetweenThem() {
        // 1500..2000 is silence; the space fills across it rather than the highlight sitting
        // still on the end of "one".
        XCTAssertEqual(line.revealedChars(1_750), 3.5, accuracy: 0.01)
        XCTAssertEqual(line.revealedChars(2_000), 4, accuracy: 0.01)
    }

    func testRevealCoversTheWholeLineOnceTheLastWordIsDone() {
        XCTAssertEqual(line.revealedChars(2_400), 7, accuracy: 0.01)
        XCTAssertEqual(line.revealedChars(99_000), 7, accuracy: 0.01)
    }

    func testARepeatedWordLinesUpWithItsOwnOccurrence() {
        let repeated = LyricLine(timeMs: 0, text: "go go go", words: [
            LyricWord(startMs: 0, endMs: 100, text: "go"),
            LyricWord(startMs: 1_000, endMs: 1_100, text: "go"),
            LyricWord(startMs: 2_000, endMs: 2_100, text: "go"),
        ])
        // Start of the third "go" is character 6, not character 0.
        XCTAssertEqual(repeated.revealedChars(2_000), 6, accuracy: 0.01)
        XCTAssertEqual(repeated.wordSpans, [0..<2, 3..<5, 6..<8])
    }

    func testOffsetsAreUTF16SoTheyMatchTextKitRanges() {
        let emoji = LyricLine(timeMs: 0, text: "🎵 la", words: [
            LyricWord(startMs: 0, endMs: 100, text: "🎵"),
            LyricWord(startMs: 100, endMs: 200, text: "la"),
        ])
        XCTAssertEqual(emoji.wordSpans, [0..<2, 3..<5])
        XCTAssertEqual(emoji.revealedChars(200), 5, accuracy: 0.01)
    }

    func testTheLiftRisesAndSettlesAroundEachWord() {
        XCTAssertEqual(line.wordLift(0, 1_000), 0, accuracy: 0.001)
        XCTAssertGreaterThan(line.wordLift(0, 1_300), 0)
        // Past its own end by the whole rise, it has settled.
        XCTAssertEqual(line.wordLift(0, 2_300), 0, accuracy: 0.001)
        XCTAssertEqual(line.wordFall(0, 1_400), 1, accuracy: 0.001)
        XCTAssertEqual(line.wordLift(9, 1_300), 0)
        XCTAssertFalse(line.isLifted(1_000))
        XCTAssertTrue(line.isLifted(1_200))
        XCTAssertFalse(line.isLifted(3_200))
    }

    // MARK: Words held long enough to animate letter by letter

    private func held(_ text: String, _ heldMs: Int) -> LyricLine {
        LyricLine(timeMs: 0, text: text, words: [LyricWord(startMs: 0, endMs: heldMs, text: text)])
    }

    func testANoteCarriedEarnsTheLetterByLetterTreatmentAndPatterDoesNot() {
        XCTAssertEqual(held("hold", 1_500).growingWords.count, 1)
        XCTAssertTrue(held("hold", 300).growingWords.isEmpty)
    }

    func testHowLongAWordMustBeHeldDependsOnHowLongItIs() {
        // Two letters over a second and a half is unmistakably a held note; the same second
        // and a half spread over seven letters is ordinary singing.
        XCTAssertFalse(held("ah", 1_500).growingWords.isEmpty)
        XCTAssertTrue(held("holding", 900).growingWords.isEmpty)
        XCTAssertFalse(held("holding", 1_500).growingWords.isEmpty)
        // Past seven letters there is no wave left to run, however long it goes.
        XCTAssertTrue(held("standing", 4_000).growingWords.isEmpty)
    }

    func testWordsThatDoNotComeApartIntoLettersAreLeftAlone() {
        XCTAssertTrue(held("一二三", 2_000).growingWords.isEmpty)
        XCTAssertTrue(held("re-do", 2_000).growingWords.isEmpty)
        XCTAssertTrue(held("שלום", 2_000).growingWords.isEmpty)
    }

    func testTheSwellTravelsAlongTheWordRatherThanPulsingAtOnce() throws {
        let word = try XCTUnwrap(held("golden", 2_000).growingWords.first)
        // Early on, the first letter is well up and the last has not started.
        XCTAssertGreaterThan(word.sample(0, 500).scale, word.sample(5, 500).scale)
        XCTAssertEqual(word.sample(5, 500).scale, 1, accuracy: 0.001)
        // Later the order reverses: the front is settling while the tail is still coming up.
        XCTAssertGreaterThan(word.sample(5, 2_600).scale, word.sample(0, 2_600).scale)
    }

    func testEveryLetterComesToRestAtTheLiftAnOrdinarySungWordCarries() throws {
        let word = try XCTUnwrap(held("golden", 2_000).growingWords.first)
        let settled = word.sample(0, word.restsAtMs)
        XCTAssertEqual(settled.scale, 1, accuracy: 0.001)
        XCTAssertEqual(settled.shift, 0, accuracy: 0.001)
        XCTAssertEqual(settled.rise, 1, accuracy: 0.001)
        XCTAssertEqual(settled.bloom, 0, accuracy: 0.001)
    }

    func testTheBloomPeaksPartwayUpAndIsGoneBeforeTheLetterSettles() throws {
        let word = try XCTUnwrap(held("golden", 2_000).growingWords.first)
        XCTAssertEqual(word.sample(0, 0).bloom, 0, accuracy: 0.001)
        XCTAssertGreaterThan(word.sample(0, 800).bloom, 0.3)
        XCTAssertEqual(word.sample(0, 2_400).bloom, 0, accuracy: 0.001)
    }

    func testLettersLeanAwayFromTheMiddleOfTheWordAsItSwells() throws {
        let word = try XCTUnwrap(held("golden", 2_000).growingWords.first)
        XCTAssertLessThan(word.sample(0, 800).shift, 0)
        XCTAssertGreaterThan(word.sample(5, 2_300).shift, 0)
    }

    func testALineOfOrdinarySyllablesHasNothingToAnimate() {
        let patter = LyricLine(timeMs: 0, text: "one two three", words: [
            LyricWord(startMs: 0, endMs: 200, text: "one"),
            LyricWord(startMs: 200, endMs: 400, text: "two"),
            LyricWord(startMs: 400, endMs: 700, text: "three"),
        ])
        XCTAssertTrue(patter.growingWords.isEmpty)
        XCTAssertFalse(patter.isGrowing(300))
    }

    func testALineWithNoWordTimingsHasNothingToAnimate() {
        XCTAssertTrue(LyricLine(timeMs: 0, text: "no timings here").growingWords.isEmpty)
        XCTAssertFalse(LyricLine(timeMs: 0, text: "no timings here").isGrowing(500))
    }

    func testALineWithNoWordTimingsRevealsWhole() {
        let plain = LyricLine(timeMs: 1_000, text: "no timings here")
        XCTAssertEqual(plain.revealedChars(999), 0, accuracy: 0.01)
        XCTAssertEqual(plain.revealedChars(1_000), 15, accuracy: 0.01)
    }

    func testChangingAWordRecomputesTheCachedSpans() {
        var copy = line
        XCTAssertEqual(copy.wordSpans, [0..<3, 4..<7])
        copy.text = "xx one two"
        XCTAssertEqual(copy.wordSpans, [3..<6, 7..<10])
        // The original is untouched by its copy's edit.
        XCTAssertEqual(line.wordSpans, [0..<3, 4..<7])
    }

    func testALineSurvivesACodableRoundTrip() throws {
        var original = line
        original.background = LyricLine(timeMs: 1_200, text: "(echo)", sungUntilMs: 2_000)
        original.alignment = .end
        let decoded = try JSONDecoder().decode(LyricLine.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }
}
