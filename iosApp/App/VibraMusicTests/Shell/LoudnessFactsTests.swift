import AudioDSP
import VibraMusicCore
import Playback
import XCTest
@testable import VibraMusic

/// YouTube's loudness figure reaches every copy of a recording, not only the stream that carried it.
final class LoudnessFactsTests: XCTestCase {
    private func item(_ videoId: String, id: String? = nil) -> PlayableItem {
        var item = PlayableItem(song: Song(videoId: videoId, title: "t", artist: "a"), source: .file(URL(fileURLWithPath: "/dev/null")))
        if let id { item.id = id }
        return item
    }

    private func normalising(_ facts: StreamFactsBook) -> AudioDSPProcessor {
        let processor = AudioDSPProcessor(facts: facts)
        var settings = AudioDSPSettings()
        settings.loudnessNormalization = true
        processor.apply(settings, automix: false)
        return processor
    }

    func testALosslessAddonCopyIsNormalisedWithItsRecordingsYouTubeFigure() {
        let facts = StreamFactsBook()
        let processor = normalising(facts)
        let flac = item("addonTrack1", id: "row|addonTrack1#hifi")
        XCTAssertFalse(processor.altersSignal(for: flac, loudnessDb: nil), "no figure yet: nothing to change")
        facts.noteLoudness(4, forTrack: "addonTrack1")
        XCTAssertTrue(processor.altersSignal(for: flac, loudnessDb: nil), "the recording's figure applies to its add-on copy")
        XCTAssertEqual(processor.loudnessReadout(for: flac, loudnessDb: nil)?.gainDb, -4)
    }

    func testFiguresOutliveTheProcess() throws {
        let suite = "LoudnessFactsTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        StreamFactsBook(defaults: defaults).noteLoudness(-2.5, forTrack: "relaunchTr1")
        XCTAssertEqual(StreamFactsBook(defaults: defaults).trackLoudness("relaunchTr1"), -2.5)
    }

    func testAFullBookForgetsOneFigureNotAll() {
        let facts = StreamFactsBook()
        let ids = (0..<StreamFactsBook.trackLimit).map { "track\($0)" }
        for id in ids { facts.noteLoudness(1, forTrack: id) }
        facts.noteLoudness(2, forTrack: "oneMore")
        XCTAssertEqual(facts.trackLoudness("oneMore"), 2)
        XCTAssertEqual(ids.filter { facts.trackLoudness($0) != nil }.count, StreamFactsBook.trackLimit - 1,
                       "going past the limit costs one learned figure, not the whole book")
    }

    func testUpdatingAKnownFigureInAFullBookForgetsNothing() {
        let facts = StreamFactsBook()
        let ids = (0..<StreamFactsBook.trackLimit).map { "track\($0)" }
        for id in ids { facts.noteLoudness(1, forTrack: id) }
        facts.noteLoudness(3, forTrack: ids[0])
        XCTAssertEqual(facts.trackLoudness(ids[0]), 3)
        XCTAssertEqual(ids.filter { facts.trackLoudness($0) != nil }.count, StreamFactsBook.trackLimit,
                       "the key was already there: the book did not grow, so nothing goes")
    }

    func testAFigureThatArrivesMidTrackIsTakenUpByTheChainPlayingIt() {
        let facts = StreamFactsBook()
        let processor = normalising(facts)
        processor.beginItem(item("lateFigure1"), loudnessDb: nil)
        XCTAssertNil(processor.chain.loudness.readout.gainDb, "began with no figure")

        processor.loudnessArrived(forTrack: "otherTrack1")
        facts.noteLoudness(6, forTrack: "lateFigure1")
        processor.loudnessArrived(forTrack: "lateFigure1")
        XCTAssertEqual(processor.chain.loudness.readout.gainDb, -6)
    }
}
