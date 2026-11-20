import VibraMusicCore
import Lyrics
import XCTest
@testable import VibraMusic

/// Share lyrics: long-press to start picking, taps to add or drop lines, a card's
/// worth of characters, and the picture the picks make.
@MainActor
final class LyricsShareTests: XCTestCase {
    private let song = Song(videoId: "share-a", title: "Lighthouse", artist: "Vibra Music",
                            thumbnailUrl: "https://example.test/cover.jpg")

    private func lines(_ texts: [String]) -> [LyricLine] {
        texts.enumerated().map { LyricLine(timeMs: $0.offset * 3_000, text: $0.element, sungUntilMs: $0.offset * 3_000 + 2_500) }
    }

    private func controller(_ lines: [LyricLine], subLines: [LyricLine]? = nil,
                            trackKey: String = "share-a") -> LyricsShareController {
        let controller = LyricsShareController()
        controller.configure(song: song, trackKey: trackKey, lines: lines, subLines: subLines,
                             artworkUrl: song.thumbnailUrl)
        return controller
    }

    // MARK: The budget

    /// Android's LyricsShareCardTest: five ordinary lines still fit and the sixth is refused.
    private let shortLine = "Nie dzwoń do mnie teraz, nie przeszkadzaj mi"

    func testFiveShortLinesStillFitAndTheSixthIsRefused() {
        var taken = 0
        for index in 0..<5 {
            XCTAssertTrue(fitsOnCard(taken: taken, text: shortLine), "line \(index + 1) must be pickable")
            taken += shortLine.utf16.count
        }
        XCTAssertFalse(fitsOnCard(taken: taken, text: shortLine))
    }

    func testTheBudgetIsInclusiveByOneCharacterAndWordsAreCountedInUtf16() {
        XCTAssertTrue(fitsOnCard(taken: LyricsShareLimit.characters, text: ""))
        XCTAssertFalse(fitsOnCard(taken: LyricsShareLimit.characters, text: "x"))
        XCTAssertFalse(fitsOnCard(taken: 0, text: String(repeating: "x", count: LyricsShareLimit.characters + 1)))
        XCTAssertTrue(fitsOnCard(taken: LyricsShareLimit.characters, text: nil), "a line with no words costs nothing")
        XCTAssertTrue(fitsOnCard(taken: 248, text: "🎵"), "an emoji is two UTF-16 units, as on Android")
        XCTAssertFalse(fitsOnCard(taken: 249, text: "🎵"))
    }

    // MARK: Picking

    func testALongPressStartsPickingAndChoosesThatLine() {
        let controller = controller(lines(["One", "Two", "Three"]))
        controller.pick(1)

        XCTAssertTrue(controller.picking)
        XCTAssertEqual(controller.picks, [1])
        XCTAssertTrue(controller.canShare)
        XCTAssertEqual(controller.usedCharacters, 3)
    }

    func testDroppingTheOnlyLineLeavesTheModeOpenAndEmpty() {
        let controller = controller(lines(["One", "Two", "Three"]))
        controller.pick(2)
        XCTAssertTrue(controller.picking)
        XCTAssertEqual(controller.picks, [2])

        controller.toggle(2)
        XCTAssertTrue(controller.picking, "dropping a line does not close the pick")
        XCTAssertTrue(controller.picks.isEmpty)
        XCTAssertFalse(controller.canShare, "nothing chosen, nothing to send")
    }

    func testTapsWhilePickingAddAndDropLinesAcrossTheWholeList() {
        let controller = controller(lines(["One", "Two", "Three"]))
        controller.pick(0)
        controller.toggle(2)
        XCTAssertEqual(controller.picks, [0, 2])
        controller.toggle(0)
        XCTAssertEqual(controller.picks, [2])
        XCTAssertTrue(controller.canShare)
        XCTAssertEqual(controller.usedCharacters, 5)
    }

    func testALineThatWouldOverflowTheCardIsRefusedAndNothingAlreadyPickedIsDropped() {
        let controller = controller(lines(Array(repeating: shortLine, count: 6)))
        controller.pick(0)
        for index in 1..<5 { controller.toggle(index) }
        XCTAssertEqual(controller.picks.count, 5)

        XCTAssertTrue(controller.toggle(5), "the sixth line is refused")
        XCTAssertEqual(controller.picks.count, 5)
        XCTAssertTrue(controller.overBudget)
        XCTAssertFalse(controller.canShare, "the bar's Share goes dim rather than sending a half pick")
        XCTAssertEqual(controller.usedCharacters, shortLine.utf16.count * 5)
    }

    func testDroppingALineClearsTheRefusalSoTheNextOneCanJoin() {
        let controller = controller(lines(Array(repeating: shortLine, count: 6)))
        controller.pick(0)
        for index in 1..<6 { controller.toggle(index) }
        XCTAssertTrue(controller.overBudget)
        XCTAssertEqual(controller.picks.count, 5)

        controller.toggle(4)
        XCTAssertFalse(controller.overBudget)
        XCTAssertTrue(controller.canShare)
        controller.toggle(5)
        XCTAssertEqual(controller.picks, [0, 1, 2, 3, 5])
    }

    func testOneLineLongerThanACardOpensPickingWithNothingChosen() {
        let controller = controller(lines([String(repeating: "x", count: LyricsShareLimit.characters + 1)]))
        controller.pick(0)

        XCTAssertTrue(controller.picking)
        XCTAssertTrue(controller.picks.isEmpty)
        XCTAssertTrue(controller.overBudget)
        XCTAssertFalse(controller.canShare)
    }

    func testCancelLeavesTheWordsAndTheModeAlone() {
        let controller = controller(lines(["One", "Two"]))
        controller.pick(0)
        controller.cancel()

        XCTAssertFalse(controller.picking)
        XCTAssertTrue(controller.picks.isEmpty)
        XCTAssertFalse(controller.overBudget)
        XCTAssertNil(controller.request)
    }

    func testTheHeaderShareEntryStartsWithNothingChosenAndCannotToggle() {
        let controller = controller(lines(["One", "Two", "Three"]))
        controller.beginPicking()

        XCTAssertTrue(controller.picking)
        XCTAssertTrue(controller.picks.isEmpty, "the header names no line, so nothing is folded in")
        XCTAssertFalse(controller.canShare, "Share stays dim until a line is tapped")

        controller.toggle(2)
        XCTAssertEqual(controller.picks, [2])

        controller.beginPicking()
        XCTAssertTrue(controller.picking)
        XCTAssertEqual(controller.picks, [2], "a second press while picking leaves the pick alone")
        XCTAssertEqual(controller.usedCharacters, 5, "only the tapped line counts toward the card")
    }

    func testCancelAfterARefusalClearsTheRefusalToo() {
        let controller = controller(lines(Array(repeating: shortLine, count: 6)))
        controller.pick(0)
        for index in 1..<6 { controller.toggle(index) }
        XCTAssertTrue(controller.overBudget)

        controller.cancel()
        XCTAssertFalse(controller.picking)
        XCTAssertTrue(controller.picks.isEmpty)
        XCTAssertFalse(controller.overBudget)
    }

    func testANewTrackOrANewVerseClearsThePickAndTheSameOneKeepsIt() {
        let verse = lines(["One", "Two"])
        let controller = controller(verse)
        controller.pick(0)

        controller.configure(song: song, trackKey: "share-a", lines: verse, subLines: nil, artworkUrl: song.thumbnailUrl)
        XCTAssertEqual(controller.picks, [0], "the panel redrawing the same verse does not lose the pick")

        controller.configure(song: song, trackKey: "share-b", lines: verse, subLines: nil, artworkUrl: song.thumbnailUrl)
        XCTAssertFalse(controller.picking)
        XCTAssertTrue(controller.picks.isEmpty)

        controller.pick(1)
        controller.configure(song: song, trackKey: "share-b", lines: lines(["One", "Two", "Three"]),
                             subLines: nil, artworkUrl: song.thumbnailUrl)
        XCTAssertTrue(controller.picks.isEmpty, "a re-fetched verse could have fewer lines than the pick points at")
    }

    // MARK: Sharing

    func testTheChosenPassageKeepsItsGapsAndOnlyItsDifferentTranslations() {
        let verse = lines(["a", "b", "c", "d", "e"])
        let subs = lines(["a", "", "  ", "D", "e"])
        let controller = controller(verse, subLines: subs)
        controller.pick(0)
        controller.toggle(1)
        controller.toggle(3)
        controller.share()

        let shared = controller.request?.lines ?? []
        XCTAssertEqual(shared.map(\.text), ["a", "b", "", "d"])
        XCTAssertEqual(shared.map(\.isGap), [false, false, true, false], "the skipped line reads as an omission")
        XCTAssertEqual(shared.map(\.subText), [nil, nil, nil, "D"],
                       "a blank translation costs no row, and one identical to the words is not printed twice")
        XCTAssertEqual(controller.request?.song, song)
        XCTAssertEqual(controller.request?.artworkUrl, song.thumbnailUrl)
        XCTAssertFalse(controller.picking, "sharing closes the pick")
        XCTAssertTrue(controller.picks.isEmpty)
    }

    func testEachShareIsItsOwnCard() {
        let controller = controller(lines(["One", "Two"]))
        controller.pick(0)
        controller.share()
        let first: UUID? = controller.request?.id
        XCTAssertNotNil(first)

        controller.pick(1)
        controller.share()
        let second: UUID? = controller.request?.id
        XCTAssertNotNil(second)
        XCTAssertNotEqual(second, first, "a second pick opens the sheet again")
    }

    func testAPickWithNoWordsInItOpensNoSheet() {
        let controller = controller(lines(["", "Two"]))
        controller.pick(0)
        controller.share()

        XCTAssertNil(controller.request)
        XCTAssertFalse(controller.picking)

        // Two blank lines apart: only the gap mark between them would be drawn.
        let apart = self.controller(lines(["", "Two", ""]))
        apart.pick(0)
        apart.toggle(2)
        XCTAssertFalse(apart.canShare, "Share stays dim for a pick with no words")
        apart.toggle(1)
        XCTAssertTrue(apart.canShare)
        apart.toggle(1)
        apart.share()
        XCTAssertNil(apart.request, "a card of nothing but (…) is not sent")

        // A blank first pick doesn't open the card with a gap mark.
        let leading = self.controller(lines(["", "Two", "Three", "Four"]))
        leading.pick(0)
        leading.toggle(3)
        leading.share()
        XCTAssertEqual(leading.request?.lines.map(\.isGap), [false], "just the words, no (…) ahead of them")
    }

    // MARK: The card

    /// The two numbers the brief names, so a change to the geometry has to say so here.
    func testTheCardIsNineBySixteenRoomAndOnlyAsTallAsItsContent() {
        XCTAssertEqual(LyricsShareCardLayout.cardHeight(contentHeight: 500, story: false), 966)
        XCTAssertEqual(LyricsShareCardLayout.cardHeight(contentHeight: 500, story: true), 1920)
        XCTAssertEqual(LyricsShareCardLayout.cardHeight(contentHeight: 1_500, story: false), 1966)
        XCTAssertEqual(LyricsShareCardLayout.cardHeight(contentHeight: 1_500, story: true), 1966,
                       "a passage past the frame lengthens the card rather than shrinking the type")
    }

    func testTheStripIsOnlyAsTallAsItsLinesAndAStoryFillsNineBySixteen() {
        let content: CGFloat = 300
        let strip = LyricsShareCardLayout.cardHeight(contentHeight: content, story: false)
        XCTAssertEqual(strip, LyricsShareCardLayout.bodyTop(contentHeight: content, story: false) + content + 276,
                       "header, air, the words, then the footer")

        let taller = LyricsShareCardLayout.cardHeight(contentHeight: content + 100, story: false)
        XCTAssertEqual(taller, strip + 100, "a longer passage makes a taller card, not smaller type")

        XCTAssertEqual(LyricsShareCardLayout.cardHeight(contentHeight: content, story: true), 1920)
        XCTAssertEqual(LyricsShareCardLayout.cardHeight(contentHeight: 1_500, story: true),
                       LyricsShareCardLayout.cardHeight(contentHeight: 1_500, story: false),
                       "past nine by sixteen the frame gives rather than the type shrinking")
    }

    func testAStoryCentresThePassageInTheRoomAboveTheFooter() {
        let content: CGFloat = 200
        let top = LyricsShareCardLayout.bodyTop(contentHeight: content, story: true) - LyricsShareCardLayout.bodyStart
        XCTAssertEqual(top, LyricsShareCardLayout.bodyRoom - content - top, accuracy: 0.001,
                       "the air above the words matches the air below them")
        XCTAssertEqual(LyricsShareCardLayout.bodyTop(contentHeight: content, story: false), LyricsShareCardLayout.bodyStart,
                       "a strip starts straight under the mark")
    }

    func testLongLinesWrapInsideTheCardAndScriptsWithoutSpacesStillBreak() {
        let font = ReplayPoster.heading(96)
        let tracking = LyricsShareCardLayout.tracking
        let width = LyricsShareCardLayout.contentWidth

        let long = "A much longer line that keeps on going until it wraps onto another row of the card"
        let rows = LyricsShareCard.wrapped(long, font: font, tracking: tracking, width: width)
        XCTAssertGreaterThan(rows.count, 1)
        XCTAssertEqual(rows.joined(separator: " ").split(separator: " "), long.split(separator: " "),
                       "wrapping keeps every word, in order")
        for row in rows {
            XCTAssertLessThanOrEqual(ReplayPoster.measure(row, font: font, tracking: tracking), width)
        }

        let japanese = String(repeating: "静かな港に灯りがともる頃に", count: 4)
        let broken = LyricsShareCard.wrapped(japanese, font: font, tracking: tracking, width: width)
        XCTAssertGreaterThan(broken.count, 1, "a script with no spaces still gets several rows")
        XCTAssertEqual(broken.joined(), japanese)

        XCTAssertEqual(LyricsShareCard.wrapped("   ", font: font, tracking: tracking, width: width), [""])
    }

    func testTheCardIsTenEightyWideAndOnlyAsTallAsItsLines() async {
        let request = LyricsShareRequest(song: song, artworkUrl: nil,
                                         lines: [LyricsShareLine(text: "One short line", subText: nil)])
        let strip = await LyricsShareCard.render(request: request, story: false, loader: { _ in nil })
        XCTAssertEqual(strip.size.width, 1080)
        XCTAssertEqual(strip.scale, 1)
        XCTAssertLessThan(strip.size.height, 1920)
        XCTAssertGreaterThan(strip.size.height, 466, "the card always holds its header and footer")

        let story = await LyricsShareCard.render(request: request, story: true, loader: { _ in nil })
        XCTAssertEqual(story.size, CGSize(width: 1080, height: 1920))
    }

    func testTheCardAsksForTheSleeveOnce() async {
        final class Counter: @unchecked Sendable { var asked: [String] = [] }
        let counter = Counter()
        let request = LyricsShareRequest(song: song, artworkUrl: song.thumbnailUrl,
                                         lines: [LyricsShareLine(text: "One line", subText: nil)])
        _ = await LyricsShareCard.render(request: request, story: false, loader: { url in
            counter.asked.append(url)
            return nil
        })
        XCTAssertEqual(counter.asked, [song.thumbnailUrl])
    }
}
