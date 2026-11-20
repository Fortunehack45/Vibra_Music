import VibraMusicCore
import Foundation
import Observation
import Replay

// Ports ui/replay/ReplayModel.kt's app half: `rememberReplayState` (the period, the summary for it,
// the member-since date) and the localized text — headlines, period labels, listening time, hours,
// days, counts, hero cards. The Replay module computes the numbers and the sentence shapes in
// English; every string a person reads is rebuilt here from the app's catalog.

/// Where a Replay's numbers come from. The live one reads ``ReplayListeningStats``; tests and the
/// debug screenshots hand in fixed summaries.
protocol ReplayDataSource: Sendable {
    func summary(for period: ReplayPeriod) async -> ReplaySummary
    /// `MM/YY` of the first month anything was recorded, for the cards' "member since".
    func memberSince() async -> String?
}

struct LiveReplayDataSource: ReplayDataSource {
    let stats: ReplayListeningStats
    /// Runs once a summary is built, which queues the artists on the page for lookup.
    var onSummary: @MainActor () -> Void = {}

    func summary(for period: ReplayPeriod) async -> ReplaySummary {
        // Merging the month files is disk work: off the main thread.
        let summary = await Task.detached(priority: .userInitiated) { stats.summary(for: period) }.value
        await onSummary()
        return summary
    }

    func memberSince() async -> String? {
        await Task.detached(priority: .utility) { stats.months().first?.memberSince }.value
    }
}

/// The Replay's state: which stretch of listening is shown, and the numbers for it. The period
/// survives (a choice); the summary is re-read each time the page opens (a result).
@MainActor
@Observable
final class ReplayPageModel {
    @ObservationIgnored private let source: ReplayDataSource

    private(set) var period: ReplayPeriod
    private(set) var summary: ReplaySummary?
    private(set) var loading = true
    private(set) var memberSince: String?

    /// The period chosen last, kept across openings like Android's `rememberSaveable`.
    @ObservationIgnored private static var rememberedPeriod: ReplayPeriod = .thisYear

    init(source: ReplayDataSource, period: ReplayPeriod? = nil) {
        self.source = source
        self.period = period ?? Self.rememberedPeriod
    }

    /// A summary with something in it, or nil (the page then shows its empty state).
    var shownSummary: ReplaySummary? {
        guard let summary, !summary.isEmpty else { return nil }
        return summary
    }

    /// "Play your Replay": the stories, from their first card (Android's row calls
    /// `onOpenStory(INTRO)`). Nil while there is nothing to tell.
    func playYourReplay() -> ReplayStoryPage? {
        shownSummary == nil ? nil : .intro
    }

    func load() async {
        memberSince = await source.memberSince()
        await reload()
    }

    /// Only the first read shows a spinner: switching period must not blank the charts for the
    /// beat the merge takes — that reads as the page breaking.
    func reload() async {
        loading = summary == nil
        let wanted = period
        let fresh = await source.summary(for: wanted)
        guard wanted == period else { return }
        summary = fresh
        loading = false
    }

    func select(_ next: ReplayPeriod) async {
        guard next != period else { return }
        period = next
        Self.rememberedPeriod = next
        await reload()
    }

    /// Artist pictures and pages land after the page is built; the charts are re-read while it is
    /// open so they appear (the stats cache the merge, so an unchanged answer is cheap).
    func refreshWhileVisible(every interval: Duration = .seconds(5)) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            let wanted = period
            let fresh = await source.summary(for: wanted)
            if wanted == period, fresh != summary { summary = fresh }
        }
    }
}

// MARK: - Text

/// The Replay's words, from the app's string catalog.
enum ReplayText {
    static var locale: Locale { LanguageBundle.locale }

    static func chip(_ period: ReplayPeriod) -> String {
        switch period {
        case .thisMonth: return L10n.thisMonth
        case .thisYear: return L10n.thisYear
        case .allTime: return L10n.allTime
        }
    }

    /// "September 2026", "2026" or "All time" (`localizedLabel`).
    static func label(_ period: ReplayPeriod, today: Date = Date(), calendar: Calendar = .current) -> String {
        switch period {
        case .thisMonth:
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
            let text = formatter.string(from: today)
            return text.prefix(1).uppercased(with: locale) + text.dropFirst()
        case .thisYear:
            return String(calendar.component(.year, from: today))
        case .allTime:
            return L10n.allTime
        }
    }

    /// "Replay'26" for a year, which is the shape everyone knows this by; a month or "All time" has
    /// no two-digit form and is spelt out.
    static func title(periodLabel label: String) -> String {
        if label.count == 4, label.allSatisfy(\.isNumber) { return "Replay'\(label.suffix(2))" }
        return "Replay · \(label)"
    }

    /// Listening time in the largest unit that still says something: minutes, then hours and
    /// minutes up to a day, then grouped minutes.
    static func listening(_ ms: Int64) -> String {
        let minutes = ms / 60_000
        if minutes < 60 { return L10n.minutesShort(Int(minutes)) }
        if minutes < 1_440 { return L10n.hoursMinutesShort(Int(minutes / 60), Int(minutes % 60)) }
        return L10n.minutesGroupedShort(replayGrouped(minutes))
    }

    static func minutes(_ ms: Int64) -> String { replayFormatMinutes(ms) }

    /// "3 PM", "midnight".
    static func hour(_ hour: Int) -> String {
        switch hour {
        case 0: return L10n.midnight
        case 12: return L10n.midday
        case 1..<12: return L10n.hourAm(hour)
        default: return L10n.hourPm(hour - 12)
        }
    }

    static func day(_ iso: String) -> String { replayFormatDay(iso, locale: locale) }

    static func plays(_ count: Int) -> String { L10n.replayPlayCount(count, formatted: replayGrouped(Int64(count))) }
    static func songs(_ count: Int) -> String { L10n.replaySongCount(count, formatted: replayGrouped(Int64(count))) }
    static func artists(_ count: Int) -> String { L10n.replayArtistCount(count, formatted: replayGrouped(Int64(count))) }

    /// The sentence at the top of a story card, with its emphasised run.
    ///
    /// The catalog keeps the spaces Android's strings.xml carried at the ends of each fragment;
    /// Android's resource compiler trimmed them, and the runs put exactly one space between
    /// fragments — so they are trimmed here too.
    static func headline(_ page: ReplayStoryPage, summary: ReplaySummary, periodLabel: String) -> [ReplayHeadlineRun] {
        func t(_ text: String) -> String { text.trimmingCharacters(in: .whitespaces) }
        func runs(_ parts: (String, Bool)...) -> [ReplayHeadlineRun] {
            var out: [ReplayHeadlineRun] = []
            for (index, part) in parts.enumerated() {
                // A closing full stop sits on the word before it.
                if index > 0, part.0 != "." { out.append(ReplayHeadlineRun(" ", bold: false)) }
                out.append(ReplayHeadlineRun(part.0, bold: part.1))
            }
            return out
        }
        switch page {
        case .intro:
            return runs((t(L10n.replayIntroStart), false), ("Replay", true), (t(L10n.replayIntroEnd), false))
        case .minutes:
            return runs((t(L10n.replayMinutesStart), false), (L10n.replayMinutesValue(Int(summary.minutes), formatted: minutes(summary.totalMs)), true),
                        (t(L10n.replayMinutesEnd), false))
        case .songs:
            return runs((t(L10n.replaySongsStart), false), (songs(summary.totalPlays), true), (t(L10n.replaySongsEnd), false))
        case .artists:
            return runs((t(L10n.replayArtistStart), false), (L10n.replayArtistFocus, true), (t(L10n.replayArtistEnd), false))
        case .albums:
            return runs((t(L10n.replayAlbumStart), false), (L10n.replayAlbumFocus, true), (t(L10n.replayAlbumEnd), false))
        case .genres:
            return runs((t(L10n.replayGenreStart), false), (L10n.replayGenreFocus, true), (t(L10n.replayGenreEnd), false))
        case .habits:
            return runs((t(L10n.replayHabitsStart), false), (songs(summary.distinctSongs), true),
                        (t(L10n.replayHabitsMiddle), false), (artists(summary.distinctArtists), true), (".", false))
        case .summary:
            return runs((t(L10n.replaySummaryStart), false), (periodLabel, true), (".", false))
        }
    }

    /// The four headline cards, minutes first; a category with nothing in it is left out.
    static func heroCards(_ summary: ReplaySummary, periodLabel: String) -> [ReplayHeroCard] {
        var cards = [ReplayHeroCard(
            label: L10n.minutesListened, value: minutes(summary.totalMs),
            detail: "\(plays(summary.totalPlays)) · \(periodLabel)",
            artworkUrl: summary.songs.first?.song.thumbnailUrl, page: .minutes
        )]
        if let top = summary.songs.first {
            cards.append(ReplayHeroCard(label: L10n.topSong, value: top.song.title,
                                        detail: "\(top.song.artist) · \(plays(top.plays))",
                                        artworkUrl: top.song.thumbnailUrl, page: .songs))
        }
        if let top = summary.artists.first {
            cards.append(ReplayHeroCard(label: L10n.topArtist, value: top.title,
                                        detail: "\(listening(top.ms)) · \(plays(top.plays))",
                                        artworkUrl: top.artworkUrl, page: .artists))
        }
        if let top = summary.albums.first {
            cards.append(ReplayHeroCard(label: L10n.topAlbum, value: top.title,
                                        detail: [top.subtitle, listening(top.ms)].compactMap { $0 }.joined(separator: " · "),
                                        artworkUrl: top.artworkUrl, page: .albums))
        }
        return cards
    }

    /// The minutes card's subline: hours only once there is one ("That's 0 hours" reads as the
    /// page failing to count), the plays, and the peak hour. Android's resource compiler trimmed
    /// the fragments' spaces and ran them together ("21 hours12 plays. , mostly around 9 PM"); this
    /// is the sentence those pieces were meant to make.
    static func minutesDetail(_ summary: ReplaySummary) -> String {
        let across = L10n.replayAcross.trimmingCharacters(in: .whitespaces)
        var text: String
        if summary.hours >= 1 {
            text = L10n.replayHoursAcross(Int(summary.hours), formatted: replayGrouped(summary.hours)) + " " + across + " " + plays(summary.totalPlays)
        } else {
            text = across.prefix(1).uppercased(with: locale) + across.dropFirst() + " " + plays(summary.totalPlays)
        }
        if let peak = summary.peakHour { return text + L10n.replayMostlyAround(hour(peak)) }
        return text + "."
    }

    /// The habits card's big numbers.
    static func habitStats(_ summary: ReplaySummary) -> [ReplayHabitStat] {
        var stats: [ReplayHabitStat] = []
        if summary.distinctAlbums > 0 {
            stats.append(ReplayHabitStat(value: replayGrouped(Int64(summary.distinctAlbums)), label: L10n.differentAlbums))
        }
        if let day = summary.busiestDay {
            stats.append(ReplayHabitStat(value: self.day(day), label: L10n.yourBiggestDay(listening(summary.busiestDayMs))))
        }
        if let peak = summary.peakHour {
            stats.append(ReplayHabitStat(value: hour(peak), label: L10n.whenYouListenMost))
        }
        return stats
    }

    /// The summary card's lines.
    static func recapLines(_ summary: ReplaySummary) -> [(label: String, value: String)] {
        var lines: [(String, String)] = [(L10n.minutes, minutes(summary.totalMs))]
        if let top = summary.songs.first { lines.append((L10n.topSong, top.song.title)) }
        if let top = summary.artists.first { lines.append((L10n.topArtist, top.title)) }
        if let top = summary.albums.first { lines.append((L10n.topAlbum, top.title)) }
        if let top = summary.genres.first { lines.append((L10n.topGenre, top.title)) }
        return lines
    }

    /// Whether a genre chart can be drawn at all on this build and these settings (Android's
    /// `ArtistFacts.genresAvailable`): the setting is on and there is a Last.fm key to ask with.
    @MainActor static func genresAvailable(settings: AppSettings, bundle: Bundle = .main) -> Bool {
        let key = (bundle.object(forInfoDictionaryKey: "LASTFM_API_KEY") as? String) ?? ""
        return settings.replayGenres && !key.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// How far down each chart the page goes: a top five is a result, a top ten is a list.
let replayChartLength = 5
