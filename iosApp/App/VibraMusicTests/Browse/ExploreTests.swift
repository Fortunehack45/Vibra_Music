import VibraMusicCore
import InnerTube
import PlaybackQueue
import SwiftUI
import XCTest
@testable import VibraMusic

/// PORTING.md "Explore": the Moods & Genres grid, and a category's playlists.
@MainActor
final class ExploreTests: XCTestCase {
    func testMoodsAndGenresLoadFromAStubbedInnerTubeAndBorrowTheirCovers() async throws {
        let repository = makeStubbedRepository()
        let explore = ExploreModel()

        await explore.load(repository)

        let sections = try XCTUnwrap(explore.state.value, "state: \(explore.state)")
        XCTAssertFalse(sections.isEmpty)
        XCTAssertTrue(sections.allSatisfy { !$0.items.isEmpty })
        // Covers arrive afterwards, a few at a time, from the categories' own playlists.
        await waitUntil("a tile gets its cover") {
            explore.state.value?.contains { $0.items.contains { $0.thumbnailUrl != nil } } == true
        }
    }

    func testCoversAreFetchedAtMostFourAtATime() async throws {
        let catalog = ScriptedCatalog()
        let items = (0..<10).map { MoodGenre(title: "M\($0)", browseId: "FEmusic_moods_and_genres_category", params: "p\($0)") }
        catalog.moodsAnswer = { [MoodGenreSection(title: "Moods", items: items)] }
        let counter = ConcurrencyCounter()
        catalog.artworkAnswer = { params in
            await counter.enter()
            try await Task.sleep(for: .milliseconds(20))
            await counter.leave()
            return "https://lh3.googleusercontent.com/\(params)"
        }
        let explore = ExploreModel()
        await explore.load(catalog)
        await waitUntil("every tile has a cover") {
            explore.state.value?.first?.items.allSatisfy { $0.thumbnailUrl != nil } == true
        }
        let peak = await counter.peak
        XCTAssertEqual(ExploreModel.artworkConcurrency, 4, "the rule this test is named for")
        XCTAssertLessThanOrEqual(peak, 4)
        XCTAssertEqual(explore.state.value?.first?.items.first?.thumbnailUrl, "https://lh3.googleusercontent.com/p0")
    }

    func testNothingToExploreAndFailuresAreMessages() async {
        let catalog = ScriptedCatalog()
        let explore = ExploreModel()
        await explore.load(catalog)
        XCTAssertEqual(explore.state.errorMessage, L10n.nothingToExplore)

        catalog.moodsAnswer = { throw URLError(.notConnectedToInternet) }
        await explore.load(catalog)
        XCTAssertEqual(explore.state.errorMessage, L10n.noInternetConnection)
    }

    func testACategoryOpensItsPlaylistShelves() async throws {
        let repository = makeStubbedRepository()
        let chill = MoodGenre(title: "Chill", browseId: "FEmusic_moods_and_genres_category", params: "ggMPOg1uX1JOQWZFeDByc2Jm")
        let page = MoodGenreModel()

        await page.load(chill, catalog: repository)

        let shelves = try XCTUnwrap(page.state.value, "state: \(page.state)")
        XCTAssertFalse(shelves.isEmpty)
        XCTAssertTrue(shelves.allSatisfy { !$0.items.isEmpty })
    }

    func testAnEmptyCategoryIsNothingToExplore() async {
        let page = MoodGenreModel()
        await page.load(MoodGenre(title: "X", browseId: "b", params: nil), catalog: ScriptedCatalog())
        XCTAssertEqual(page.state.errorMessage, L10n.nothingToExplore)
    }

    func testTilesKeepTheirAndroidColours() {
        // Kotlin's String.hashCode, masked and taken mod 8, as in ExploreScreen.kt's moodColor.
        XCTAssertEqual(MoodColor.javaHashCode("Chill"), 65_078_532)
        XCTAssertEqual(MoodColor.javaHashCode("Commute"), -1_679_899_910)
        XCTAssertEqual(MoodColor.index(for: "Chill"), 4)
        XCTAssertEqual(MoodColor.index(for: "Commute"), 2)
        XCTAssertEqual(MoodColor.index(for: "Feel good"), 7)
        XCTAssertEqual(MoodColor.index(for: "Focus"), 0)
    }

    // MARK: - Rendering

    func testExploreRendersTheGridFromAStubbedInnerTube() async {
        let app = makeBrowseTestApp()
        await host(ExploreScreen(), app: app) {
            InnerTubeStub.requests.contains { $0.contains("FEmusic_moods_and_genres") }
        }
        XCTAssertTrue(InnerTubeStub.requests.contains { $0.contains("FEmusic_moods_and_genres") })
    }

    func testAMoodPageRendersItsShelves() async {
        let app = makeBrowseTestApp()
        let chill = MoodGenre(title: "Chill", browseId: "FEmusic_moods_and_genres_category", params: "ggMPOg1uX1JOQWZFeDByc2Jm")
        await host(MoodGenreScreen(moodGenre: chill), app: app) {
            InnerTubeStub.requests.contains { $0.contains("FEmusic_moods_and_genres_category") }
        }
        XCTAssertTrue(InnerTubeStub.requests.contains { $0.contains("FEmusic_moods_and_genres_category") })
        await host(MoodGenreScreen(moodGenre: chill).environment(\.layoutDirection, .rightToLeft), app: app, colorScheme: .light, timeout: 1)
    }
}

/// Tracks how many callers are inside at once.
actor ConcurrencyCounter {
    private var current = 0
    private(set) var peak = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func leave() { current -= 1 }
}
