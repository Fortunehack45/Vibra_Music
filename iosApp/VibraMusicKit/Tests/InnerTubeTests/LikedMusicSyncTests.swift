import XCTest
import VibraMusicCore
@testable import InnerTube

/// The liked-music sync behind kushagrasinghx/Vibra Music#219 (Android's LikedMusicSyncTest): a liked collection
/// larger than one page — or than the old ten-page cap — must still have every id recognised as
/// liked, without holding the library page open, and a track menu that says nothing about a rating
/// must never downgrade a LIKE already known.
@MainActor
final class LikedMusicSyncTests: XCTestCase {
    private var likeState: LikeState!
    private var repository: YTMusicRepository!

    override func setUp() async throws {
        likeState = LikeState()
        // No network: every page comes from the injected loader.
        repository = YTMusicRepository(client: InnerTubeStub().makeClient(), likeState: likeState)
    }

    private func song(_ id: String) -> Song { Song(videoId: id, title: "t", artist: "a") }

    private func songs(_ count: Int, _ offset: Int) -> [Song] {
        (0..<count).map { song("v\(offset + $0)") }
    }

    // MARK: - Pagination beyond the old 1000-song (10 page) boundary

    func testLikedSyncFollowsContinuationsPastTheOldTenPageCap() async {
        let pageCount = 12
        let perPage = 100
        var pages: [String: YTMusicRepository.SongPage] = [:]
        for p in 0..<pageCount {
            pages["page-\(p)"] = YTMusicRepository.SongPage(
                songs: songs(perPage, p * perPage),
                continuation: p == pageCount - 1 ? nil : "page-\(p + 1)"
            )
        }
        let all = pages
        await repository.syncLikedMusic(from: "page-0") { all[$0] }

        XCTAssertEqual(likeState.overrides.count, pageCount * perPage)
        XCTAssertEqual(likeState.overrides.values.filter { $0 == .like }.count, pageCount * perPage)
        XCTAssertEqual(likeState.status(for: "v\(pageCount * perPage - 1)"), .like)
    }

    func testLikedSyncStopsWhenAContinuationPointsBackAtAPageAlreadyRead() async {
        let pages = [
            "t0": YTMusicRepository.SongPage(songs: songs(3, 0), continuation: "t1"),
            "t1": YTMusicRepository.SongPage(songs: songs(3, 3), continuation: "t0"),
        ]
        let calls = Counter()
        // "t0" → "t1" → "t0": without the repeat guard this spins forever.
        await repository.syncLikedMusic(from: "t0") { token in
            await calls.increment()
            return pages[token]
        }
        let count = await calls.value
        XCTAssertEqual(count, 2)
        XCTAssertEqual(Set(likeState.overrides.keys), ["v0", "v1", "v2", "v3", "v4", "v5"])
    }

    // MARK: - Continuation exhaustion

    func testLikedSyncStopsWhenTheContinuationRunsDry() async {
        let pages = [
            "t0": YTMusicRepository.SongPage(songs: songs(3, 0), continuation: "t1"),
            "t1": YTMusicRepository.SongPage(songs: songs(3, 3), continuation: nil),
        ]
        let calls = Counter()
        await repository.syncLikedMusic(from: "t0") { token in
            await calls.increment()
            return pages[token]
        }
        let count = await calls.value
        XCTAssertEqual(count, 2, "no attempt to read a page the feed never promised")
        XCTAssertEqual(Set(likeState.overrides.keys), ["v0", "v1", "v2", "v3", "v4", "v5"])
    }

    func testLikedSyncIsANoOpWithNoContinuation() async {
        let calls = Counter()
        await repository.syncLikedMusic(from: nil) { _ in
            await calls.increment()
            return nil
        }
        let count = await calls.value
        XCTAssertEqual(count, 0)
        XCTAssertTrue(likeState.overrides.isEmpty)
    }

    // MARK: - The first page is usable before the sync finishes

    /// The Library tab shows its first page without waiting for the whole liked collection: the
    /// page is seeded, then the continuation sync runs without being awaited. Here the background
    /// sync is held on its next page while the first page's ids are already visible.
    func testFirstPageIsSeededWhileBackgroundSyncIsStillInFlight() async {
        let (gate, open) = AsyncStream.makeStream(of: YTMusicRepository.SongPage?.self)
        let repository = self.repository!
        let background = Task {
            await repository.syncLikedMusic(from: "t0") { _ in
                for await page in gate { return page }
                return nil
            }
        }
        await Task.yield()
        let firstPage: Set<String> = ["v0", "v1", "v2"]
        likeState.seedLiked(firstPage)
        XCTAssertEqual(Set(likeState.overrides.keys), firstPage)

        open.yield(YTMusicRepository.SongPage(songs: songs(3, 3), continuation: nil))
        open.finish()
        await background.value
        XCTAssertEqual(Set(likeState.overrides.keys), ["v0", "v1", "v2", "v3", "v4", "v5"])
    }

    // MARK: - Failure and cancellation

    func testAFailedContinuationStopsTheSyncWithoutLosingEarlierIds() async {
        let pages = ["t0": YTMusicRepository.SongPage(songs: songs(3, 0), continuation: "t1")]
        // A refused page reads as nil, like the default loader's failed request.
        await repository.syncLikedMusic(from: "t0") { token in token == "t1" ? nil : pages[token] }
        XCTAssertEqual(Set(likeState.overrides.keys), ["v0", "v1", "v2"])
    }

    func testCancellingTheSyncStopsFurtherPagination() async {
        let pages = ["t0": YTMusicRepository.SongPage(songs: songs(3, 0), continuation: "t1")]
        let (reached, signal) = AsyncStream.makeStream(of: Void.self)
        let repository = self.repository!
        let job = Task {
            await repository.syncLikedMusic(from: "t0") { token in
                guard token == "t1" else { return pages[token] }
                signal.yield()
                // Returns early once the sync is cancelled — with a page that must not be seeded.
                try? await Task.sleep(for: .seconds(10))
                return YTMusicRepository.SongPage(songs: (3..<6).map { Song(videoId: "v\($0)", title: "t", artist: "a") }, continuation: "t2")
            }
        }
        for await _ in reached { break }
        job.cancel()
        await job.value
        XCTAssertEqual(Set(likeState.overrides.keys), ["v0", "v1", "v2"])
    }

    func testTheDefaultLoaderReadsContinuationsThroughTheClient() async throws {
        let stub = InnerTubeStub()
        try stub.onContinuation("LIKED_PAGE_2", fixture: "signed_in/liked_music_continuation.json")
        let repository = YTMusicRepository(client: stub.makeClient(), likeState: likeState)
        await repository.syncLikedMusic(from: "LIKED_PAGE_2")
        XCTAssertEqual(Set(likeState.overrides.keys), ["ADdaooPZG50", "ep76vmKxtfI", "Jb6gcoR266U"])
        XCTAssertEqual(stub.requests(to: "browse").count, 1)
    }

    // MARK: - A missing like button means no stated rating

    func testARowWithoutALikeButtonStatesNoRating() {
        let response = json(#"{"contents":[{"playlistPanelVideoRenderer":{"videoId":"abc123","menu":{"menuRenderer":{"items":[]}}}}]}"#)
        // Nil, not .indifferent: a missing button and a stated "no rating" are different answers.
        XCTAssertNil(InnerTubeParser.parseSongMenu(response, videoId: "abc123")?.likeStatus)
    }

    // MARK: - A stated LIKE is never overwritten by a silent menu

    func testAnExistingLikeSurvivesAMenuThatSaysNothing() {
        likeState.set(.like, for: "abc123")
        let menu = InnerTubeParser.parseSongMenu(json(#"{"contents":[{"playlistPanelVideoRenderer":{"videoId":"abc123"}}]}"#), videoId: "abc123")
        XCTAssertNil(menu?.likeStatus, "a missing button is not a stated .indifferent")
        likeState.rememberStated(menu?.likeStatus, for: "abc123")
        XCTAssertEqual(likeState.status(for: "abc123"), .like)

        // Silence records nothing for an id the session knows nothing about, while a stated rating
        // is remembered: the two are different answers, not both a no-op.
        likeState.rememberStated(nil, for: "fresh")
        XCTAssertNil(likeState.status(for: "fresh"))
        likeState.rememberStated(.dislike, for: "fresh")
        XCTAssertEqual(likeState.status(for: "fresh"), .dislike)
    }

    func testAStatedIndifferentRatingDoesNotDowngradeAnExistingLike() {
        likeState.set(.like, for: "abc123")
        likeState.rememberStated(.indifferent, for: "abc123")
        XCTAssertEqual(likeState.status(for: "abc123"), .like)
    }
}

/// A call counter a `@Sendable` closure can bump.
actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
