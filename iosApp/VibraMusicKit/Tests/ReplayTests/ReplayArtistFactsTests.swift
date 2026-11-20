import XCTest
import VibraMusicTestSupport
import VibraMusicCore
@testable import Replay

// Artist pictures, pages and genre tags: vocabulary filtering, lookup gating, resolution and
// persistence.

final class ReplayArtistFactsTests: XCTestCase {
    private func makeFacts(enabled: Bool = true) throws -> (ReplayArtistFacts, URL) {
        let dir = try makeTemporaryDirectory()
        let facts = ReplayArtistFacts(store: JSONFileStore(directory: dir), genresEnabled: enabled)
        return (facts, dir)
    }

    func testCanonicalKeepsRealGenres() {
        XCTAssertEqual(ReplayArtistFacts.canonical("Shoegaze"), "Shoegaze")
        XCTAssertEqual(ReplayArtistFacts.canonical("  dream pop "), "Dream Pop")
        XCTAssertEqual(ReplayArtistFacts.canonical("Hip-Hop"), "Hip-Hop")
        XCTAssertEqual(ReplayArtistFacts.canonical("R&B"), "R&B")
        XCTAssertEqual(ReplayArtistFacts.canonical("Drum & Bass"), "Drum & Bass")
    }

    func testCanonicalFoldsSpellings() {
        XCTAssertEqual(ReplayArtistFacts.canonical("hiphop"), "Hip-Hop")
        XCTAssertEqual(ReplayArtistFacts.canonical("r&b"), "R&B")
        XCTAssertEqual(ReplayArtistFacts.canonical("rnb"), "R&B")
        XCTAssertEqual(ReplayArtistFacts.canonical("kpop"), "K-Pop")
        XCTAssertEqual(ReplayArtistFacts.canonical("dnb"), "Drum & Bass")
        XCTAssertEqual(ReplayArtistFacts.canonical("lofi"), "Lo-Fi")
        XCTAssertEqual(ReplayArtistFacts.canonical("chillhop"), "Lo-Fi")
        XCTAssertEqual(ReplayArtistFacts.canonical("female vocalists"), "Pop")
        XCTAssertEqual(ReplayArtistFacts.canonical("alt rock"), "Alternative Rock")
        XCTAssertEqual(ReplayArtistFacts.canonical("trip hop"), "Downtempo")
    }

    func testCanonicalRejectsFolksonomy() {
        XCTAssertNil(ReplayArtistFacts.canonical("seen live"))
        XCTAssertNil(ReplayArtistFacts.canonical("favourites"))
        XCTAssertNil(ReplayArtistFacts.canonical("albums i own"))
        XCTAssertNil(ReplayArtistFacts.canonical(""))
        XCTAssertNil(ReplayArtistFacts.canonical("   "))
        XCTAssertNil(ReplayArtistFacts.canonical("awesome"))
    }

    func testGenresGatedOff() async throws {
        let (facts, _) = try makeFacts(enabled: false)
        facts.tagProvider = { _ in ["rock"] }
        facts.noticed("Some Band")
        await facts.resolvePending()
        XCTAssertEqual(facts.replayGenres(for: "Some Band"), [])
    }

    func testCardFiledOnlyForExactArtist() async throws {
        let (facts, _) = try makeFacts()
        facts.cardProvider = { name in
            if name == "Known Artist" {
                return ReplayArtistCard(title: "known artist", imageUrl: "https://example.test/face.jpg", browseId: "UCface")
            }
            return ReplayArtistCard(title: "Some Stranger", imageUrl: "https://example.test/wrong.jpg", browseId: "UCwrong")
        }
        facts.noticed("Known Artist")
        facts.noticed("Nobody Heard Of Them")
        await facts.resolvePending()
        XCTAssertEqual(facts.replayImage(for: "Known Artist"), "https://example.test/face.jpg")
        XCTAssertEqual(facts.replayBrowseId(for: "Known Artist"), "UCface")
        // A stranger's photograph under someone else's name is worse than keeping the sleeve.
        XCTAssertNil(facts.replayImage(for: "Nobody Heard Of Them"))
        XCTAssertTrue(facts.pendingArtists.isEmpty)
        XCTAssertGreaterThan(facts.replayFactsRevision, 0)
    }

    func testTagsFilteredDistinctAndCapped() async throws {
        let (facts, _) = try makeFacts()
        facts.tagProvider = { _ in ["seen live", "shoegaze", "dream pop", "Shoegaze", "rock", "metal"] }
        facts.noticed("Gaze Band")
        await facts.resolvePending()
        // Folksonomy out, duplicates folded, at most two genres per artist.
        XCTAssertEqual(facts.replayGenres(for: "Gaze Band"), ["Shoegaze", "Dream Pop"])
    }

    func testNoticeDedupesWhileQueued() throws {
        let (facts, _) = try makeFacts()
        facts.noticed("Repeat")
        facts.noticed("repeat")
        facts.noticed("  Repeat  ")
        XCTAssertEqual(facts.pendingArtists, ["Repeat"])
    }

    func testNoticeIgnoresBlankAndHugeNames() throws {
        let (facts, _) = try makeFacts()
        facts.noticed("   ")
        facts.noticed(String(repeating: "x", count: ReplayArtistFacts.maxNameLength + 1))
        XCTAssertTrue(facts.pendingArtists.isEmpty)
    }

    func testKnownArtistNotRequeued() async throws {
        let (facts, _) = try makeFacts()
        facts.cardProvider = { name in ReplayArtistCard(title: name, imageUrl: "https://example.test/f.jpg", browseId: "UCx") }
        facts.tagProvider = { _ in ["rock"] }
        facts.noticed("Done Deal")
        await facts.resolvePending()
        facts.noticed("Done Deal")
        XCTAssertTrue(facts.pendingArtists.isEmpty)
    }

    func testACardSearchThatFindsNothingIsNotRepeatedOnTheNextPlay() async throws {
        let (facts, _) = try makeFacts(enabled: false)
        facts.cardProvider = { _ in nil }
        facts.noticed("Unknown Act")
        await facts.resolvePending()
        facts.noticed("Unknown Act")
        XCTAssertTrue(facts.pendingArtists.isEmpty)
    }

    func testAnArtistWithAPictureButNoPageIsLookedUpAgainAfterTheRetryInterval() async throws {
        final class Clock { var now: Int64 = 1_000 }
        let clock = Clock()
        let dir = try makeTemporaryDirectory()
        let facts = ReplayArtistFacts(store: JSONFileStore(directory: dir), nowMillis: { clock.now })
        facts.cardProvider = { name in ReplayArtistCard(title: name, imageUrl: "https://example.test/f.jpg") }
        facts.noticed("Half Known")
        await facts.resolvePending()
        clock.now += Int64(ReplayArtistFacts.retryIntervalDays + 1) * 86_400_000
        facts.cardProvider = { name in ReplayArtistCard(title: name, imageUrl: "https://example.test/f.jpg", browseId: "UCpage") }
        facts.noticed("Half Known")
        await facts.resolvePending()
        XCTAssertEqual(facts.replayBrowseId(for: "Half Known"), "UCpage")
    }

    func testPersistsAcrossInstances() async throws {
        let dir = try makeTemporaryDirectory()
        let store = { JSONFileStore(directory: dir) }
        let first = ReplayArtistFacts(store: store())
        first.cardProvider = { name in ReplayArtistCard(title: name, imageUrl: "https://example.test/f.jpg", browseId: "UCx") }
        first.tagProvider = { _ in ["rock"] }
        first.genresEnabled = true
        first.noticed("Saved Band")
        await first.resolvePending()
        let second = ReplayArtistFacts(store: store(), genresEnabled: true)
        second.load()
        XCTAssertEqual(second.replayImage(for: "Saved Band"), "https://example.test/f.jpg")
        XCTAssertEqual(second.replayGenres(for: "Saved Band"), ["Rock"])
    }
}
