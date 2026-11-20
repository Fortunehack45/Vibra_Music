import VibraMusicCore
import UIKit
import XCTest
@testable import VibraMusic

/// Share lyrics: the sheet that draws the picked passage, and the two things you can
/// do to the picture — save it to Photos, or hand it to the share sheet.
@MainActor
final class LyricsShareSheetTests: XCTestCase {
    private var savedOverride: String?

    /// The sheet's copy is the app's, which follows the reader's language: pin English so these
    /// comparisons mean something on a phone that is not.
    override func setUp() {
        super.setUp()
        savedOverride = LanguageBundle.override
        LanguageBundle.override = "en"
    }

    override func tearDown() {
        LanguageBundle.override = savedOverride
        super.tearDown()
    }

    private let request = LyricsShareRequest(
        song: Song(videoId: "share-sheet", title: "Lighthouse", artist: "Vibra Music"),
        artworkUrl: nil,
        lines: [LyricsShareLine(text: "One line of the verse", subText: nil)]
    )

    func testTheSheetDrawsTheStripFirstAndTheStoryWhenAsked() async {
        final class Shapes: @unchecked Sendable { var drawn: [Bool] = [] }
        let shapes = Shapes()
        let model = LyricsShareModel(draw: { story in
            shapes.drawn.append(story)
            return UIImage()
        })

        XCTAssertFalse(model.ready, "nothing to save or send before the picture is drawn")
        XCTAssertFalse(model.canShare, "a share needs a picture to send")
        await model.render()
        XCTAssertTrue(model.ready)
        XCTAssertEqual(shapes.drawn, [false], "a card opens as the strip its lines make")
        XCTAssertEqual(model.storyLabel, L10n.lyricsShareStory)

        await model.toggleStory()
        XCTAssertTrue(model.story)
        XCTAssertEqual(shapes.drawn, [false, true], "the toggle redraws the same passage as a full story")
        XCTAssertEqual(model.storyLabel, L10n.lyricsShareStoryRevert)

        await model.toggleStory()
        XCTAssertFalse(model.story)
        XCTAssertEqual(shapes.drawn, [false, true, false])
        XCTAssertEqual(model.storyLabel, L10n.lyricsShareStory)
    }

    func testAStoryCanStartAsAStory() async {
        final class Shapes: @unchecked Sendable { var drawn: [Bool] = [] }
        let shapes = Shapes()
        let model = LyricsShareModel(story: true, draw: { story in
            shapes.drawn.append(story)
            return UIImage()
        })
        XCTAssertEqual(model.storyLabel, L10n.lyricsShareStoryRevert)
        await model.render()
        XCTAssertEqual(shapes.drawn, [true])
    }

    func testSavePutsTheCardInPhotosOnce() async {
        final class Counter: @unchecked Sendable { var saves = 0 }
        let counter = Counter()
        let model = LyricsShareModel(draw: { _ in UIImage() }, saver: { _ in
            counter.saves += 1
            return true
        })
        XCTAssertFalse(model.canSave, "disabled until the picture is drawn")
        await model.render()
        XCTAssertTrue(model.canShare)

        await model.save()
        XCTAssertTrue(model.saved)
        XCTAssertFalse(model.canSave, "the button says Saved! rather than offering it again")
        XCTAssertEqual(model.saveLabel, L10n.savedBang)
        await model.save()
        XCTAssertEqual(counter.saves, 1)
    }

    func testARefusedSaveCanBeTriedAgain() async {
        let model = LyricsShareModel(draw: { _ in UIImage() }, saver: { _ in false })
        await model.render()
        await model.save()
        XCTAssertFalse(model.saved)
        XCTAssertTrue(model.canSave)
    }

    func testTheOtherShapeIsANewPictureToSave() async {
        let model = LyricsShareModel(draw: { _ in UIImage() }, saver: { _ in true })
        await model.render()
        await model.save()
        XCTAssertFalse(model.canSave)

        await model.toggleStory()
        XCTAssertTrue(model.canSave, "the story has not been saved yet")
        XCTAssertEqual(model.saveLabel, L10n.save)
    }

    /// A save in flight owns the picture it was handed: reshaping the card underneath it would
    /// take that save's answer for the new one.
    func testTheStoryWaitsForASaveToFinish() async {
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        let model = LyricsShareModel(draw: { _ in UIImage() }, saver: { _ in
            for await _ in gate { break }
            return true
        })
        await model.render()

        let saving = Task { await model.save() }
        let deadline = Date().addingTimeInterval(5)
        while !model.saving, Date() < deadline { await Task.yield() }
        XCTAssertTrue(model.saving, "the save never started")
        XCTAssertFalse(model.canToggleStory, "the story toggle is offered while the card is being written")

        await model.toggleStory()
        XCTAssertFalse(model.story, "a toggle during a save is ignored")

        gateContinuation.yield(())
        gateContinuation.finish()
        await saving.value
        XCTAssertTrue(model.saved)
        XCTAssertTrue(model.canToggleStory, "once the save lands the card can be reshaped again")
    }

    func testAFailedDrawingSaysSoAndOffersNothingToDo() async {
        let model = LyricsShareModel(draw: { _ in nil })
        await model.render()
        XCTAssertTrue(model.failed)
        XCTAssertFalse(model.ready)
        XCTAssertFalse(model.canSave)
        XCTAssertFalse(model.canShare)
    }

    /// The sheet's copy is Android 1.8's, so a card shared from either phone reads the same.
    func testTheSheetsCopyMatchesAndroid() {
        XCTAssertEqual(L10n.lyricsShareTitle, "Share lyrics")
        XCTAssertEqual(L10n.lyricsShareDescription, "The lines you picked, laid out on a card with the cover.")
        XCTAssertEqual(L10n.lyricsShareStory, "Make it a story")
        XCTAssertEqual(L10n.lyricsShareStoryRevert, "Back to the card")
        XCTAssertEqual(L10n.lyricsSharePickLimit, "Card is full")
        XCTAssertEqual(L10n.savedBang, "Saved!")
        XCTAssertEqual(L10n.shareYourLyrics, "Send your lyrics card")
        XCTAssertEqual(L10n.yourLyricsCard, "Your lyrics card")
    }
}
