import VibraMusicCore
import Replay
import SwiftUI
import XCTest
@testable import VibraMusic

private func sample(_ period: ReplayPeriod = .thisYear) -> ReplaySummary { SocialSamples.summary(period: period) }

/// Replay stats (PORTING.md §2.10): top songs, artists, albums and genres plus habits, for this
/// month, this year or all time.
@MainActor
final class ReplayStatsPageTests: XCTestCase {
    func testThePageOpensOnThisYearAndSwitchingPeriodReadsThatPeriod() async {
        var month = sample(.thisMonth)
        month.artists = [ReplayRankedEntry(title: "Queen", ms: 60_000, plays: 1)]
        let model = ReplayPageModel(source: FixedReplaySource(summaries: [.thisYear: sample(), .thisMonth: month]), period: .thisYear)
        XCTAssertTrue(model.loading)
        await model.load()
        XCTAssertFalse(model.loading)
        XCTAssertEqual(model.memberSince, "01/26")
        XCTAssertEqual(model.shownSummary?.artists.first?.title, "Daft Punk", "the right top artist")

        await model.select(.thisMonth)
        XCTAssertEqual(model.period, .thisMonth)
        XCTAssertEqual(model.shownSummary?.artists.first?.title, "Queen")
    }

    func testAPeriodWithNothingPlayedShowsTheEmptyState() async {
        let model = ReplayPageModel(source: FixedReplaySource(summaries: [:]), period: .allTime)
        await model.load()
        XCTAssertNil(model.shownSummary)
        XCTAssertNil(model.playYourReplay())
    }

    func testTheChartsRankFiveOfEachWithTimeAndPlays() {
        let summary = sample()
        let songs = replaySongRows(for: summary, limit: replayChartLength)
        XCTAssertEqual(songs.map(\.rank), [1, 2, 3, 4, 5])
        XCTAssertEqual(songs.first?.title, "Instant Crush")
        XCTAssertEqual(replayGenreRows(for: summary, limit: replayChartLength).first?.artworkUrl, nil, "a genre has no cover")
        XCTAssertEqual(ReplayText.listening(7_320_000), L10n.hoursMinutesShort(2, 2))
        XCTAssertEqual(ReplayText.listening(600_000), L10n.minutesShort(10))
        XCTAssertEqual(ReplayText.listening(100_000_000), L10n.minutesGroupedShort("1,666"))
        XCTAssertEqual(ReplayText.hour(0), L10n.midnight)
        XCTAssertEqual(ReplayText.hour(21), L10n.hourPm(9))
    }

    func testTheHeadlineCardsAreLocalizedAndSkipEmptyCategories() {
        var summary = sample()
        let cards = ReplayText.heroCards(summary, periodLabel: "2026")
        XCTAssertEqual(cards.map(\.page), [.minutes, .songs, .artists, .albums])
        XCTAssertEqual(cards[0].label, L10n.minutesListened)
        XCTAssertEqual(cards[0].value, "391")
        XCTAssertEqual(cards[0].detail, "\(ReplayText.plays(195)) · 2026")
        summary.albums = []
        XCTAssertEqual(ReplayText.heroCards(summary, periodLabel: "2026").count, 3)
    }

    func testPeriodLabelsAndThePosterTitle() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_790_000_000) // September 2026
        XCTAssertEqual(ReplayText.label(.thisYear, today: date, calendar: calendar), "2026")
        XCTAssertEqual(ReplayText.label(.allTime), L10n.allTime)
        XCTAssertTrue(ReplayText.label(.thisMonth, today: date, calendar: calendar).contains("2026"))
        XCTAssertEqual(ReplayText.title(periodLabel: "2026"), "Replay'26")
        XCTAssertEqual(ReplayText.title(periodLabel: "All time"), "Replay · All time")
    }

    func testTheReplayPageRendersLoadedEmptyAndInRightToLeft() {
        let app = makeSocialApp()
        let full = ReplayPage(source: FixedReplaySource(summaries: [.thisYear: sample()]), period: .thisYear)
        assertSocialRendered(hostSocial(NavigationStack { full }.socialEnvironment(app)))
        let empty = ReplayPage(source: FixedReplaySource(summaries: [:]), period: .thisMonth)
        assertSocialRendered(hostSocial(NavigationStack { empty }.socialEnvironment(app)
            .environment(\.layoutDirection, .rightToLeft).environment(\.colorScheme, .light)))
    }
}

/// Replay stories: 8 full-screen cards; tap to move, hold to pause.
@MainActor
final class ReplayStoriesTests: XCTestCase {
    func testTappingOnTheRightWalksThroughAllEightCardsAndTheLeftGoesBack() {
        let player = ReplayStoryPlayer(summary: sample(), start: .intro)
        XCTAssertEqual(player.pages, ReplayStoryPage.ordered)
        XCTAssertEqual(player.pages.count, 8)
        var seen = [player.page]
        for _ in 1..<8 {
            player.tap(atX: 300, width: 393)
            seen.append(player.page)
        }
        XCTAssertEqual(seen, ReplayStoryPage.ordered)
        XCTAssertTrue(player.isLast)
        player.tap(atX: 300, width: 393)
        XCTAssertEqual(player.page, .summary, "the run stops at the last card")
        player.tap(atX: 60, width: 393)
        XCTAssertEqual(player.page, .habits)
        player.tap(atX: 300, width: 393, layoutDirection: .rightToLeft)
        XCTAssertEqual(player.page, .genres, "in a right-to-left layout the back zone is on the right")
    }

    func testHoldingStopsTheClockAndACardMovesOnAfterFourteenSeconds() {
        let player = ReplayStoryPlayer(summary: sample(), start: .songs)
        XCTAssertEqual(player.page, .songs)
        player.held = true
        player.tick(20)
        XCTAssertEqual(player.progress, 0)
        XCTAssertEqual(player.page, .songs)
        player.held = false
        player.tick(7)
        XCTAssertEqual(player.progress, 0.5, accuracy: 0.001)
        player.paused = true
        player.tick(7)
        XCTAssertEqual(player.progress, 0.5, accuracy: 0.001, "the share sheet holds the clock too")
        player.paused = false
        player.tick(7)
        XCTAssertEqual(player.page, .albums)
        XCTAssertEqual(player.progress, 0)
    }

    func testTheClockStopsWhileNobodyIsWatching() {
        let player = ReplayStoryPlayer(summary: sample(), start: .songs)
        // In the background, or with VoiceOver reading the card.
        player.suspended = true
        player.tick(20)
        XCTAssertEqual(player.progress, 0)
        XCTAssertEqual(player.page, .songs)
        player.suspended = false
        // The on-screen clock never hands over more than a frame-sized step, so a tick that
        // arrives after a long suspension moves the card on by a sliver, not a whole card.
        player.tick(min(60, ReplayStoryPlayer.maxTick))
        XCTAssertEqual(player.page, .songs)
        XCTAssertEqual(player.progress, ReplayStoryPlayer.maxTick / player.pageDuration, accuracy: 0.0001)
    }

    func testATapOnTheShareOrCloseButtonDoesNotAlsoTurnThePage() {
        let size = CGSize(width: 393, height: 699)
        // The share button: 44 pt, 20 pt in from the trailing edge, 18 pt up from the bottom.
        XCTAssertTrue(ReplayStoryPlayer.isOnControl(CGPoint(x: 351, y: 659), in: size))
        // The cross, top trailing.
        XCTAssertTrue(ReplayStoryPlayer.isOnControl(CGPoint(x: 351, y: 24), in: size))
        // Mirrored in right-to-left.
        XCTAssertTrue(ReplayStoryPlayer.isOnControl(CGPoint(x: 42, y: 659), in: size, layoutDirection: .rightToLeft))
        XCTAssertFalse(ReplayStoryPlayer.isOnControl(CGPoint(x: 351, y: 659), in: size, layoutDirection: .rightToLeft))
        // Anywhere else on the card is a step.
        XCTAssertFalse(ReplayStoryPlayer.isOnControl(CGPoint(x: 351, y: 350), in: size))
        XCTAssertFalse(ReplayStoryPlayer.isOnControl(CGPoint(x: 200, y: 659), in: size))
    }

    func testTheLastCardFillsAndStays() {
        let player = ReplayStoryPlayer(summary: sample(), start: .summary)
        player.tick(30)
        XCTAssertEqual(player.page, .summary)
        XCTAssertEqual(player.progress, 1)
    }

    func testEmptyCategoriesHaveNoCard() {
        var summary = sample()
        summary.albums = []
        summary.genres = []
        let player = ReplayStoryPlayer(summary: summary, start: .albums)
        XCTAssertEqual(player.pages.count, 6)
        XCTAssertFalse(player.pages.contains(.albums))
        XCTAssertEqual(player.page, .intro, "a card that isn't there opens the first")
    }

    func testHeadlinesAreLocalizedSentencesWithTheirNumberInBold() {
        let summary = sample()
        let runs = ReplayText.headline(.songs, summary: summary, periodLabel: "2026")
        XCTAssertEqual(runs.filter(\.bold).map(\.text), [ReplayText.songs(195)])
        XCTAssertFalse(ReplayHeadlineRun.plain(runs).contains("  "), "one space between fragments")
        let summaryRuns = ReplayText.headline(.summary, summary: summary, periodLabel: "2026")
        XCTAssertTrue(ReplayHeadlineRun.plain(summaryRuns).hasSuffix("2026."))
        XCTAssertEqual(ReplayText.minutesDetail(summary),
                       "\(L10n.replayHoursAcross(6, formatted: "6")) across \(ReplayText.plays(195))\(L10n.replayMostlyAround(L10n.hourPm(9)))")
    }

    /// The minutes card names its unit and counts hours in the singular when there is one, never
    /// "You spent 105 with music" over "1 hours across 29 plays".
    func testTheMinutesCardSaysMinutesAndOneHourInTheSingular() {
        var summary = sample()
        summary.totalMs = 105 * 60_000
        summary.totalPlays = 29
        let runs = ReplayText.headline(.minutes, summary: summary, periodLabel: "2026")
        XCTAssertEqual(runs.filter(\.bold).map(\.text), [L10n.minuteCount(105)])
        XCTAssertTrue(ReplayText.minutesDetail(summary).hasPrefix(L10n.hourCount(1) + " "), ReplayText.minutesDetail(summary))
        XCTAssertEqual(L10n.replayMinutesValue(12_345, formatted: "12,345"), L10n.minuteCount(12_345).replacingOccurrences(of: "12345", with: "12,345"),
                       "a large total keeps its grouping")
    }

    func testTheCardIsAFixedCanvasShrunkOnlyWhenTheFrameIsNarrowerThanAPhone() {
        // Upright: letterboxed to 9:16 at the phone's own width, drawn at its own size.
        let upright = ReplayStories.fittedSize(in: CGSize(width: 393, height: 759))
        XCTAssertEqual(upright.width, 393)
        XCTAssertEqual(upright.height, 393 * 16 / 9, accuracy: 0.01)
        XCTAssertEqual(ReplayStories.canvasScale(forWidth: upright.width), 1)
        XCTAssertEqual(ReplayStories.canvasScale(forWidth: 375), 1, "the narrowest upright phone is not shrunk")
        // On its side: the height sets the size, and the card is the upright one shrunk to fit.
        let sideways = ReplayStories.fittedSize(in: CGSize(width: 852, height: 372))
        XCTAssertEqual(sideways.height, 372, accuracy: 0.01)
        XCTAssertEqual(sideways.width, 372 * 9 / 16, accuracy: 0.01)
        XCTAssertEqual(ReplayStories.canvasScale(forWidth: sideways.width), sideways.width / ReplayStories.canvasWidth, accuracy: 0.001)
        XCTAssertEqual(ReplayStories.fittedSize(in: .zero), .zero)
    }

    func testTheStoriesRenderSidewaysAndAtTheLargestTextSize() {
        let app = makeSocialApp()
        for page in [ReplayStoryPage.intro, .songs, .summary] {
            let sideways = hostSocial(ReplayStories(summary: sample(), periodLabel: "2026", start: page) {}.socialEnvironment(app),
                                      size: CGSize(width: 852, height: 393), settle: 0.2)
            assertSocialRendered(sideways)
            uiSnapshot(sideways, "stories-sideways-\(page.rawValue)")
            let large = hostSocial(ReplayStories(summary: sample(), periodLabel: "2026", start: page) {}.socialEnvironment(app)
                .environment(\.dynamicTypeSize, .accessibility5), settle: 0.2)
            assertSocialRendered(large)
            uiSnapshot(large, "stories-ax5-\(page.rawValue)")
        }
    }

    func testTheStoriesRenderEveryCard() {
        let app = makeSocialApp()
        for page in ReplayStoryPage.ordered {
            let host = hostSocial(ReplayStories(summary: sample(), periodLabel: "2026", start: page) {}.socialEnvironment(app), settle: 0.2)
            assertSocialRendered(host)
        }
    }
}

/// "Play your Replay": on Android the row opens the stories at their first card.
@MainActor
final class PlayYourReplayTests: XCTestCase {
    func testPlayYourReplayOpensTheStoriesAtTheIntro() async {
        let model = ReplayPageModel(source: FixedReplaySource(summaries: [.thisYear: sample()]), period: .thisYear)
        XCTAssertNil(model.playYourReplay(), "nothing to open before the numbers are read")
        await model.load()
        XCTAssertEqual(model.playYourReplay(), .intro)
    }
}

/// Share the Replay poster: as an image, or saved to Photos.
@MainActor
final class ReplayPosterShareTests: XCTestCase {
    func testThePosterIsNineBySixteenAtTenEightyByNineteenTwenty() async {
        let whole = await ReplayPoster.render(summary: sample(), periodLabel: "2026", holder: "Alex", memberSince: "03/25",
                                              page: nil, loader: { _ in nil })
        XCTAssertEqual(whole.size, CGSize(width: 1080, height: 1920))
        XCTAssertEqual(whole.scale, 1)
        for page in ReplayStoryPage.ordered {
            let card = await ReplayPoster.render(summary: sample(), periodLabel: "2026", holder: "", memberSince: nil,
                                                 page: page, loader: { _ in nil })
            XCTAssertEqual(card.size, CGSize(width: 1080, height: 1920), "\(page)")
        }
    }

    func testThePosterAsksForEveryCoverItDraws() {
        let urls = ReplayPoster.artworkURLs(summary: sample(), page: nil)
        XCTAssertEqual(Set(urls).count, urls.count)
        XCTAssertTrue(urls.contains(SocialSamples.thumb("khnokW3Mw24")))
    }

    func testTheAlbumsCardAsksForAllFiveCoversItDraws() {
        var summary = sample()
        summary.albums = (1...5).map { ReplayRankedEntry(title: "Album \($0)", artworkUrl: "https://art.example/\($0)", ms: Int64(10 - $0), plays: 1) }
        let card = ReplayPoster.artworkURLs(summary: summary, page: .albums)
        XCTAssertTrue(card.contains("https://art.example/5"), "rank 5 is on the card")
        let whole = ReplayPoster.artworkURLs(summary: summary, page: nil)
        XCTAssertFalse(whole.contains("https://art.example/4"), "the whole poster shows three albums")
    }

    func testTheHeadlineWrapsAndLongNamesAreEllipsised() {
        let font = ReplayPoster.body(30)
        let trimmed = ReplayPoster.ellipsised(String(repeating: "Long title ", count: 20), font: font, width: 200)
        XCTAssertTrue(trimmed.hasSuffix("…"))
        XCTAssertLessThanOrEqual(ReplayPoster.measure(trimmed, font: font), 200)
    }

    func testSaveDrawsThePosterAndSavesItOnceToPhotos() async {
        final class Counter: @unchecked Sendable { var saves = 0 }
        let counter = Counter()
        let image = UIImage()
        let model = ReplayShareModel(draw: { image }, saver: { _ in
            counter.saves += 1
            return true
        })
        XCTAssertFalse(model.canSave, "disabled until the picture is drawn")
        await model.render()
        XCTAssertTrue(model.ready)
        await model.save()
        XCTAssertTrue(model.saved)
        XCTAssertFalse(model.canSave, "saved once")
        await model.save()
        XCTAssertEqual(counter.saves, 1)
    }

    func testARefusedSaveCanBeTriedAgain() async {
        let model = ReplayShareModel(draw: { UIImage() }, saver: { _ in false })
        await model.render()
        await model.save()
        XCTAssertFalse(model.saved)
        XCTAssertTrue(model.canSave)
    }

    func testTheShareSheetRendersForTheWholeReplayAndForACard() {
        let app = makeSocialApp()
        for page in [nil, ReplayStoryPage.genres] {
            let sheet = ReplayShareSheet(summary: sample(), periodLabel: "2026", holder: "", memberSince: nil, page: page, saver: { _ in true })
            assertSocialRendered(hostSocial(sheet.socialEnvironment(app)))
        }
        assertSocialRendered(hostSocial(ReplayWalletCard(card: ReplayText.heroCards(sample(), periodLabel: "2026")[0],
                                                         holder: "", memberSince: "01/26") {}.frame(width: 300)))
    }
}
