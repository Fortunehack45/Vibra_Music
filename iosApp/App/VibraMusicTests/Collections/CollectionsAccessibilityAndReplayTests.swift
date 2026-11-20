import VibraMusicCore
import Replay
import SwiftUI
import Theming
import XCTest
@testable import VibraMusic

// Follow-up fixes after integration: track rows are named by their song, screens expose their
// children to UI tests and VoiceOver, and the Library's Replay entry draws Android's card and mesh.

@MainActor
final class SongRowAccessibilityTests: XCTestCase {
    /// PORTING.md "Album and playlist pages": a row is found by its title, never by the sleeve number
    /// or the now-playing glyph drawn in front of it.
    func testATrackRowIsNamedByItsTitleFirst() {
        var song = CollectionsFixtures.song("v1", "One More Time", duration: "5:20")
        XCTAssertEqual(DetailText.songRowLabel(song), "One More Time, Daft Punk, 5:20")
        XCTAssertTrue(DetailText.songRowLabel(song).hasPrefix(song.title))

        song.artist = ""
        song.durationText = nil
        XCTAssertEqual(DetailText.songRowLabel(song), "One More Time", "empty parts leave no stray commas")
    }
}

@MainActor
final class LibraryReplayEntryTests: XCTestCase {
    /// PORTING.md "Library": before there is listening to show, the Library leads with the Replay
    /// banner; once there is, with the Replay page's own wallet cards.
    func testTheLibraryLeadsWithTheBannerAndThenTheCards() async {
        let empty = FakeCollectionsService()
        let (emptyModel, emptyStore, _) = makeCollectionsTestModel(self, service: empty)
        let bannerHost = await host(LibraryScreen(), model: emptyModel)
        XCTAssertTrue(emptyStore.replayCards.isEmpty)
        XCTAssertGreaterThan(bannerHost.view.bounds.height, 0)

        let listened = FakeCollectionsService()
        listened.cards = [
            ReplayHeroCard(label: "Minutes listened", value: "5,231", detail: "Mostly Daft Punk", page: .minutes),
            ReplayHeroCard(label: "Top artist", value: "Daft Punk", page: .artists),
        ]
        let (model, store, _) = makeCollectionsTestModel(self, service: listened)
        let cardsHost = await host(LibraryScreen(), model: model, colorScheme: .light)
        XCTAssertEqual(store.replayCards.map(\.page), [.minutes, .artists])
        XCTAssertGreaterThan(cardsHost.view.bounds.height, 0)
        // Which of the two is drawn, and that the rows inside `screen.*` keep their own identifiers,
        // is checked on the running app (SearchAndPlayE2ETests and the screenshots): SwiftUI builds
        // its accessibility tree only for a live accessibility client.
    }

    /// LibraryScreen.kt's banner mesh runs `continuous`: a linear orbit, one full turn every
    /// `defaultDriftDuration × 4`, that never wraps back; with Reduce Motion it rests at phase 0.
    func testTheBannerMeshOrbitsLinearlyAndRestsUnderReduceMotion() {
        let orbit = MeshGradientMotion.phaseChange(animated: true, reduceAnimation: false, continuous: true)
        let lap = MeshGradientMotion.defaultDriftDuration * 4
        XCTAssertEqual(ReplayBannerMesh.phase(for: orbit, elapsed: 0), 0)
        XCTAssertEqual(ReplayBannerMesh.phase(for: orbit, elapsed: lap / 2), .pi, accuracy: 1e-9)
        XCTAssertEqual(ReplayBannerMesh.phase(for: orbit, elapsed: lap * 1.5), 3 * .pi, accuracy: 1e-9,
                       "the orbit keeps going rather than jumping back each lap")

        let still = MeshGradientMotion.phaseChange(animated: true, reduceAnimation: true, continuous: true)
        XCTAssertEqual(ReplayBannerMesh.phase(for: still, elapsed: 123), 0)
    }
}

@MainActor
final class ListBottomInsetTests: XCTestCase {
    /// MainActivity hands the Library, History, Show all and artist pages the same `listPadding` as
    /// an album (140 dp, 210 with something playing), so their last row or card scrolls clear of the
    /// mini player and the tab bar instead of stopping underneath them.
    func testTheHistoryListEndsClearOfTheBottomBars() async {
        let service = FakeCollectionsService()
        service.historySongs = (0..<30).map { CollectionsFixtures.song("h\($0)", "Song \($0)") }
        let (model, _, _) = makeCollectionsTestModel(self, service: service)
        let host = await host(HistoryScreen(), model: model)
        let scrolls = host.view.collectionsSubviews.compactMap { $0 as? UIScrollView }
        XCTAssertFalse(scrolls.isEmpty, "the history is not a scroll view")
        let bottom = scrolls.map(\.adjustedContentInset.bottom).max() ?? 0
        XCTAssertGreaterThanOrEqual(bottom, 140, "the list's foot is only \(bottom) pt above the screen's bottom edge")
    }

    func testTheInsetMatchesAndroidsListPadding() {
        XCTAssertEqual(detailBottomInset(bottomInset: 83, isPlaying: true), 127)
        XCTAssertEqual(detailBottomInset(bottomInset: 83, isPlaying: false), 57)
        XCTAssertEqual(detailBottomInset(bottomInset: 300, isPlaying: true), 0, "never negative")
    }
}

private extension UIView {
    var collectionsSubviews: [UIView] { subviews + subviews.flatMap(\.collectionsSubviews) }
}
