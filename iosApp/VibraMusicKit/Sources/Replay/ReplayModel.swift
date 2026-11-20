import Foundation
import VibraMusicCore

// Ports the data side of ui/replay/*: ReplayModel.kt fully, and the computations inside
// ReplayCard.kt, ReplayStories.kt, ReplayPoster.kt and ReplayShareSheet.kt — not the drawing.
//
// Everything here is a pure function over a `ReplaySummary`: rankings, the 8 story cards' content,
// the poster's content, and the "Play your Replay" queue. The app (SwiftUI) draws them; the share
// sheet renders them into an image with `ShareLink`/`PHPhotoLibrary` (see PORTING.md §4).
//
// Strings are English, matching res/values/strings.xml. The app localizes them; the sentence
// shapes (which run is emphasised, what a card carries) live here because the on-screen card and
// the shared picture must say the same thing.

// MARK: Story pages

/// Which page of the story view something opens onto. Raw values are the card order and double as
/// the artwork-pool rotation index (see `replayStoryArtwork`).
public enum ReplayStoryPage: Int, Codable, Hashable, Sendable, CaseIterable {
    case intro = 0
    case minutes = 1
    case artists = 2
    case songs = 3
    case albums = 4
    case genres = 5
    case habits = 6
    case summary = 7

    public static var ordered: [ReplayStoryPage] { allCases }
}

/// The pages a story run actually shows: a category with nothing in it has no card, since an
/// empty page in the middle of a story reads as the app having lost something.
public func replayStoryPages(for summary: ReplaySummary) -> [ReplayStoryPage] {
    ReplayStoryPage.ordered.filter { page in
        switch page {
        case .albums: return !summary.albums.isEmpty
        case .genres: return !summary.genres.isEmpty
        default: return true
        }
    }
}

/// How long a card holds before moving on (Android: `PAGE_MILLIS`), unless held.
public let replayStoryPageDurationMs = 14_000

/// How far a card's palette is turned around the colour wheel.
///
/// The mesh is sampled from artwork, and a Replay is frequently four covers by two artists with
/// the same art direction — a run of eight cards in one shade of blue. Rotating the hue per card
/// is what makes the story *look* like a story; only the hue moves, so the saturation and
/// lightness the mesh was tuned for are untouched and no card comes out muddy or blown out. The
/// steps are irregular rather than an even eighth of the wheel: an even walk reads as a
/// colour-picker demo.
public func replayStoryHue(_ page: ReplayStoryPage) -> Double {
    switch page {
    case .intro: return 0
    case .minutes: return 40
    case .songs: return 95
    case .artists: return 145
    case .albums: return 195
    case .genres: return 240
    case .habits: return 285
    case .summary: return 325
    }
}

/// Which cover a card is washed in: the three cards that are *about* something take that thing's
/// artwork; the rest walk a pool of everything on the Replay, so a run of eight cards is lit by
/// eight different records rather than by the top song eight times.
public func replayStoryArtwork(for summary: ReplaySummary, page: ReplayStoryPage) -> String? {
    let pool = (summary.songs.map { $0.song.thumbnailUrl }
        + summary.artists.map { $0.artworkUrl }
        + summary.albums.map { $0.artworkUrl }).compactMap { $0 }
        .reduce(into: [String]()) { acc, url in if !acc.contains(url) { acc.append(url) } }
    let pinned: String?
    switch page {
    case .songs: pinned = summary.songs.first?.song.thumbnailUrl
    case .artists: pinned = summary.artists.first?.artworkUrl
    case .albums: pinned = summary.albums.first?.artworkUrl
    default: pinned = nil
    }
    if let pinned { return pinned }
    if pool.isEmpty { return nil }
    return pool[page.rawValue % pool.count]
}

// MARK: Headlines

/// One run of a card's headline, and whether it is the emphasised part.
///
/// The sentence lives here rather than in the story that draws it because it is drawn twice —
// once on screen and once into the picture the share button produces — and a card that says
/// something different in the version people send is worse than no picture at all.
public struct ReplayHeadlineRun: Hashable, Sendable {
    public var text: String
    public var bold: Bool

    public init(_ text: String, bold: Bool) {
        self.text = text
        self.bold = bold
    }

    /// The sentence as plain text.
    public static func plain(_ runs: [ReplayHeadlineRun]) -> String {
        runs.map(\.text).joined()
    }
}

/// The sentence at the top of `page`.
public func replayStoryHeadline(for summary: ReplaySummary, page: ReplayStoryPage) -> [ReplayHeadlineRun] {
    switch page {
    case .intro:
        return [.init("Your ", bold: false), .init("Replay", bold: true), .init(" is ready.", bold: false)]
    case .minutes:
        return [.init("You spent ", bold: false), .init(replayFormatMinutes(summary.totalMs), bold: true), .init(" with music.", bold: false)]
    case .songs:
        return [.init("In total, ", bold: false), .init(replayCount(summary.totalPlays, one: "song", other: "songs"), bold: true), .init(" filled your month.", bold: false)]
    case .artists:
        return [.init("All month, ", bold: false), .init("One artist", bold: true), .init(" kept coming back.", bold: false)]
    case .albums:
        return [.init("This time, ", bold: false), .init("One album", bold: true), .init(" held your attention.", bold: false)]
    case .genres:
        return [.init("Together, ", bold: false), .init("Your genres", bold: true), .init(" shaped your sound.", bold: false)]
    case .habits:
        return [
            .init("You explored ", bold: false),
            .init(replayCount(summary.distinctSongs, one: "song", other: "songs"), bold: true),
            .init(" from ", bold: false),
            .init(replayCount(summary.distinctArtists, one: "artist", other: "artists"), bold: true),
            .init(".", bold: false),
        ]
    case .summary:
        return [.init("Your listening had a ", bold: false), .init(summary.label, bold: true), .init(".", bold: false)]
    }
}

// MARK: Rows and cards

/// One line of one chart, with the four categories flattened onto a common shape.
///
/// `rank` is carried on the row rather than derived from its index because the same row is drawn
/// in three places — the page, a story, the shared poster — and only one of them has an index to
/// hand.
public struct ReplayRow: Hashable, Sendable {
    public var key: String
    public var rank: Int
    public var title: String
    public var subtitle: String?
    public var artworkUrl: String?
    public var ms: Int64
    public var plays: Int

    public init(key: String, rank: Int, title: String, subtitle: String? = nil, artworkUrl: String? = nil, ms: Int64 = 0, plays: Int = 0) {
        self.key = key
        self.rank = rank
        self.title = title
        self.subtitle = subtitle
        self.artworkUrl = artworkUrl
        self.ms = ms
        self.plays = plays
    }
}

/// How far down a chart a story card goes, and how far the Replay page goes: five. Ten was the
/// first guess and it made the page a scroll of forty rows whose second half nobody has an opinion
/// about — a top five is a result, and a top ten is a list.
public let replayStoryRowCount = 5

public func replaySongRows(for summary: ReplaySummary, limit: Int = replayStoryRowCount) -> [ReplayRow] {
    summary.songs.prefix(limit).enumerated().map { index, entry in
        ReplayRow(
            key: entry.song.videoId, rank: index + 1,
            title: entry.song.title,
            subtitle: entry.song.artist.isEmpty ? nil : entry.song.artist,
            artworkUrl: entry.song.thumbnailUrl, ms: entry.ms, plays: entry.plays
        )
    }
}

public func replayArtistRows(for summary: ReplaySummary, limit: Int = replayStoryRowCount) -> [ReplayRow] {
    summary.artists.prefix(limit).enumerated().map { index, entry in
        ReplayRow(
            key: entry.title, rank: index + 1, title: entry.title, subtitle: nil,
            artworkUrl: entry.artworkUrl, ms: entry.ms, plays: entry.plays
        )
    }
}

public func replayAlbumRows(for summary: ReplaySummary, limit: Int = replayStoryRowCount) -> [ReplayRow] {
    summary.albums.prefix(limit).enumerated().map { index, entry in
        ReplayRow(
            key: entry.title + "|" + (entry.subtitle ?? ""), rank: index + 1,
            title: entry.title, subtitle: entry.subtitle,
            artworkUrl: entry.artworkUrl, ms: entry.ms, plays: entry.plays
        )
    }
}

/// Genres, with the artwork deliberately dropped: the cover of whichever artist happened to lead
/// the genre is not a picture of the genre, and putting it there makes a row of five look like
/// five artists mislabelled. The app draws an initial tile instead.
public func replayGenreRows(for summary: ReplaySummary, limit: Int = replayStoryRowCount) -> [ReplayRow] {
    summary.genres.prefix(limit).enumerated().map { index, entry in
        ReplayRow(
            key: entry.title, rank: index + 1, title: entry.title, subtitle: nil,
            artworkUrl: nil, ms: entry.ms, plays: entry.plays
        )
    }
}

/// A stand-in tile's hue for a word with no artwork (a genre): the word's own hue, so the same
/// genre is the same colour every time the page is opened.
public func replayInitialTileHue(for text: String) -> Double {
    let hash = text.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
    return Double(((hash % 360) + 360) % 360)
}

/// One of the Replay headline cards: minutes, top song, top artist, top album, in that order.
/// Minutes leads because it is the one figure that needs no context to mean something. A category
/// with nothing in it is left out rather than shown empty.
public struct ReplayHeroCard: Hashable, Sendable {
    public var label: String
    public var value: String
    public var detail: String?
    public var artworkUrl: String?
    public var page: ReplayStoryPage

    public init(label: String, value: String, detail: String? = nil, artworkUrl: String? = nil, page: ReplayStoryPage) {
        self.label = label
        self.value = value
        self.detail = detail
        self.artworkUrl = artworkUrl
        self.page = page
    }
}

/// Labels for the hero cards, in English. The app passes localized ones.
public struct ReplayHeroCardLabels: Hashable, Sendable {
    public var minutesListened: String
    public var topSong: String
    public var topArtist: String
    public var topAlbum: String

    public init(minutesListened: String = "Minutes listened", topSong: String = "Top song", topArtist: String = "Top artist", topAlbum: String = "Top album") {
        self.minutesListened = minutesListened
        self.topSong = topSong
        self.topArtist = topArtist
        self.topAlbum = topAlbum
    }
}

public func replayHeroCards(
    for summary: ReplaySummary,
    labels: ReplayHeroCardLabels = ReplayHeroCardLabels()
) -> [ReplayHeroCard] {
    var cards: [ReplayHeroCard] = [
        ReplayHeroCard(
            label: labels.minutesListened,
            value: replayFormatMinutes(summary.totalMs),
            detail: "\(replayCount(summary.totalPlays, one: "play", other: "plays")) · \(summary.label)",
            artworkUrl: summary.songs.first?.song.thumbnailUrl,
            page: .minutes
        ),
    ]
    if let top = summary.songs.first {
        cards.append(ReplayHeroCard(
            label: labels.topSong, value: top.song.title,
            detail: "\(top.song.artist) · \(replayCount(top.plays, one: "play", other: "plays"))",
            artworkUrl: top.song.thumbnailUrl, page: .songs
        ))
    }
    if let top = summary.artists.first {
        cards.append(ReplayHeroCard(
            label: labels.topArtist, value: top.title,
            detail: "\(replayFormatListening(top.ms)) · \(replayCount(top.plays, one: "play", other: "plays"))",
            artworkUrl: top.artworkUrl, page: .artists
        ))
    }
    if let top = summary.albums.first {
        cards.append(ReplayHeroCard(
            label: labels.topAlbum, value: top.title,
            detail: [top.subtitle, replayFormatListening(top.ms)].compactMap { $0 }.joined(separator: " · "),
            artworkUrl: top.artworkUrl, page: .albums
        ))
    }
    return cards
}

// MARK: Story card bodies

/// The subline under the minutes headline: hours when there is at least one ("That's 0 hours" is
/// what an unconditional hours line says for the first afternoon of listening, and it reads as the
/// page failing to count), otherwise the plays alone — plus the peak hour when one exists.
///
/// Note: Android concatenates these pieces without the joining words ("21 hours12 plays. ,
/// mostly around …"). That is reproduced here as the evidently intended sentence ("21 hours
/// across 12 plays, mostly around …") instead; every element is the same.
public func replayMinutesDetail(for summary: ReplaySummary) -> String {
    var text: String
    if summary.hours >= 1 {
        text = "\(replayGrouped(summary.hours)) hours across "
    } else {
        text = " across "
    }
    text += replayCount(summary.totalPlays, one: "play", other: "plays")
    if let peak = summary.peakHour {
        text += ", mostly around \(replayFormatHour(peak))"
    }
    return text + "."
}

/// One big fact on the habits card.
public struct ReplayHabitStat: Hashable, Sendable {
    public var value: String
    public var label: String

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }
}

/// Labels for the habits card and recap, in English. The app passes localized ones.
public struct ReplaySectionLabels: Hashable, Sendable {
    public var differentAlbums: String
    public var yourBiggestDay: String
    public var whenYouListenMost: String
    public var minutes: String
    public var topSong: String
    public var topArtist: String
    public var topAlbum: String
    public var topGenre: String

    public init(
        differentAlbums: String = "Different albums",
        yourBiggestDay: String = "Your biggest day: %@",
        whenYouListenMost: String = "When you listen most",
        minutes: String = "Minutes",
        topSong: String = "Top song",
        topArtist: String = "Top artist",
        topAlbum: String = "Top album",
        topGenre: String = "Top genre"
    ) {
        self.differentAlbums = differentAlbums
        self.yourBiggestDay = yourBiggestDay
        self.whenYouListenMost = whenYouListenMost
        self.minutes = minutes
        self.topSong = topSong
        self.topArtist = topArtist
        self.topAlbum = topAlbum
        self.topGenre = topGenre
    }
}

public func replayHabitStats(for summary: ReplaySummary, labels: ReplaySectionLabels = ReplaySectionLabels()) -> [ReplayHabitStat] {
    var stats: [ReplayHabitStat] = []
    if summary.distinctAlbums > 0 {
        stats.append(ReplayHabitStat(value: replayGrouped(Int64(summary.distinctAlbums)), label: labels.differentAlbums))
    }
    if let day = summary.busiestDay {
        stats.append(ReplayHabitStat(
            value: replayFormatDay(day),
            label: labels.yourBiggestDay.replacingOccurrences(of: "%@", with: replayFormatListening(summary.busiestDayMs))
        ))
    }
    if let peak = summary.peakHour {
        stats.append(ReplayHabitStat(value: replayFormatHour(peak), label: labels.whenYouListenMost))
    }
    return stats
}

/// The recap card: one line per category that has anything in it.
public func replayRecapLines(for summary: ReplaySummary, labels: ReplaySectionLabels = ReplaySectionLabels()) -> [(label: String, value: String)] {
    var lines: [(label: String, value: String)] = [(labels.minutes, replayFormatMinutes(summary.totalMs))]
    if let top = summary.songs.first { lines.append((labels.topSong, top.song.title)) }
    if let top = summary.artists.first { lines.append((labels.topArtist, top.title)) }
    if let top = summary.albums.first { lines.append((labels.topAlbum, top.title)) }
    if let top = summary.genres.first { lines.append((labels.topGenre, top.title)) }
    return lines
}

// MARK: Poster content

/// The shared picture is 1080 × 1920: exactly the 9:16 the story cards are held to, so what gets
/// shared is the shape of what was being looked at, and the size every messaging app and story
/// surface expects.
public let replayPosterWidth = 1080
public let replayPosterHeight = 1920

/// How far down a chart the whole-Replay picture goes (songs/artists), and the album/genre counts.
public let replayPosterSongRows = 5
public let replayPosterAlbumCount = 3
public let replayPosterGenreCount = 4

/// The whole-Replay picture's content: totals, two charts side by side (songs left, artists
/// right as circles), the albums, and the genre chips. The app draws it; this is what it draws.
public struct ReplayPosterContent: Hashable, Sendable {
    public var title: String
    public var creditLine: String
    public var minutesValue: String
    public var minutesLabel: String
    public var totalsLine: String
    public var songs: [ReplayRow]
    public var artists: [ReplayRow]
    public var albums: [ReplayRow]
    public var genres: [ReplayRow]
    public var footer: String

    public init(
        title: String, creditLine: String, minutesValue: String, minutesLabel: String,
        totalsLine: String, songs: [ReplayRow], artists: [ReplayRow], albums: [ReplayRow],
        genres: [ReplayRow], footer: String
    ) {
        self.title = title
        self.creditLine = creditLine
        self.minutesValue = minutesValue
        self.minutesLabel = minutesLabel
        self.totalsLine = totalsLine
        self.songs = songs
        self.artists = artists
        self.albums = albums
        self.genres = genres
        self.footer = footer
    }
}

/// The header title: "Replay'26" for a year, which is the shape everyone knows this by. A month
/// or "All time" has no two-digit form and is spelt out rather than truncated into nonsense.
public func replayPosterTitle(periodLabel label: String) -> String {
    if label.count == 4 && label.allSatisfy(\.isNumber) {
        return "Replay'\(label.suffix(2))"
    }
    return "Replay · \(label)"
}

/// "HOLDER · Member since MM/YY", uppercased — the cardholder line that makes the card *yours*.
/// Falls back to the listener label when there is no signed-in account to name.
public func replayPosterCredit(holder: String, memberSince: String?) -> String {
    let name = holder.isEmpty ? "Vibra Music listener" : holder
    var parts = [name]
    if let memberSince { parts.append("Member since \(memberSince)") }
    return parts.joined(separator: " · ").uppercased()
}

public func replayPosterContent(
    for summary: ReplaySummary,
    holder: String,
    memberSince: String?,
    minutesLabel: String = "Minutes listened",
    footer: String = "Counted on this device with Vibra Music"
) -> ReplayPosterContent {
    ReplayPosterContent(
        title: replayPosterTitle(periodLabel: summary.label),
        creditLine: replayPosterCredit(holder: holder, memberSince: memberSince),
        minutesValue: replayFormatMinutes(summary.totalMs),
        minutesLabel: minutesLabel,
        totalsLine: "\(replayCount(summary.totalPlays, one: "play", other: "plays")) · "
            + "\(replayCount(summary.distinctSongs, one: "song", other: "songs")) · "
            + "\(replayCount(summary.distinctArtists, one: "artist", other: "artists"))",
        songs: replaySongRows(for: summary, limit: replayPosterSongRows),
        artists: replayArtistRows(for: summary, limit: replayPosterSongRows),
        albums: replayAlbumRows(for: summary, limit: replayPosterAlbumCount),
        genres: replayGenreRows(for: summary, limit: replayPosterGenreCount),
        footer: footer
    )
}

/// One story card's share picture: the same sentence, the same hero, the same four runners-up, in
/// the same order as the card on screen. Somebody who sends a card and somebody who saw it are
/// looking at the same facts. (A card's share button sends the card — the whole-Replay picture is
/// what the Replay page's own button produces.)
public enum ReplayPosterCard: Hashable, Sendable {
    /// The scatter of covers (squares) and faces (circles) the opening cards are built around.
    case collage(squares: [String], faces: [String])
    /// The number one, large, with its runners-up under it. Artists draw circular.
    case leaderboard(rows: [ReplayRow], circular: Bool)
    /// One word, big, then the rest as a ranked list.
    case genreList(rows: [ReplayRow])
    case habits(stats: [ReplayHabitStat])
    case recap(lines: [(label: String, value: String)])

    public static func == (lhs: ReplayPosterCard, rhs: ReplayPosterCard) -> Bool {
        switch (lhs, rhs) {
        case (.collage(let a, let b), .collage(let c, let d)): return a == c && b == d
        case (.leaderboard(let a, let b), .leaderboard(let c, let d)): return a == c && b == d
        case (.genreList(let a), .genreList(let c)): return a == c
        case (.habits(let a), .habits(let c)): return a == c
        case (.recap(let a), .recap(let c)): return a.elementsEqual(c) { $0.label == $1.label && $0.value == $1.value }
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .collage(let squares, let faces):
            hasher.combine(0); hasher.combine(squares); hasher.combine(faces)
        case .leaderboard(let rows, let circular):
            hasher.combine(1); hasher.combine(rows); hasher.combine(circular)
        case .genreList(let rows):
            hasher.combine(2); hasher.combine(rows)
        case .habits(let stats):
            hasher.combine(3); hasher.combine(stats)
        case .recap(let lines):
            hasher.combine(4); hasher.combine(lines.map { $0.label }); hasher.combine(lines.map { $0.value })
        }
    }
}

public func replayPosterCard(
    for summary: ReplaySummary,
    page: ReplayStoryPage,
    labels: ReplaySectionLabels = ReplaySectionLabels()
) -> ReplayPosterCard {
    switch page {
    case .intro, .minutes:
        let squares = summary.songs.compactMap { $0.song.thumbnailUrl }
            .reduce(into: [String]()) { acc, url in if !acc.contains(url) { acc.append(url) } }.prefix(3).map { $0 }
        let faces = summary.artists.compactMap { $0.artworkUrl }
            .filter { !squares.contains($0) }
            .reduce(into: [String]()) { acc, url in if !acc.contains(url) { acc.append(url) } }.prefix(3).map { $0 }
        return .collage(squares: squares, faces: faces)
    case .songs:
        return .leaderboard(rows: replaySongRows(for: summary), circular: false)
    case .artists:
        return .leaderboard(rows: replayArtistRows(for: summary), circular: true)
    case .albums:
        return .leaderboard(rows: replayAlbumRows(for: summary), circular: false)
    case .genres:
        return .genreList(rows: replayGenreRows(for: summary))
    case .habits:
        return .habits(stats: replayHabitStats(for: summary, labels: labels))
    case .summary:
        return .recap(lines: replayRecapLines(for: summary, labels: labels))
    }
}

// MARK: "Play your Replay"

/// The ordered song list to queue when the user taps "Play your Replay": their top songs, best
/// first, each carrying the whole row so playback can start immediately.
public func replayQueueSongs(for summary: ReplaySummary) -> [Song] {
    summary.songs.map(\.song)
}

// MARK: Formatting

/// Thousands-grouped, US style ("1,284"), matching Android's `grouped` (`String.format(US, "%,d")`).
public func replayGrouped(_ value: Int64) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
}

/// Listening time, in the largest unit that still says something: minutes up to an hour, then
/// "21h 5m".
public func replayFormatListening(_ ms: Int64) -> String {
    let minutes = ms / 60_000
    if minutes < 60 { return "\(minutes) min" }
    if minutes < 1_440 { return "\(minutes / 60)h \(minutes % 60)m" }
    return "\(replayGrouped(minutes)) min"
}

/// The headline figure on the minutes card: always minutes, always grouped.
public func replayFormatMinutes(_ ms: Int64) -> String {
    replayGrouped(ms / 60_000)
}

/// "3 PM", "midnight" — an hour of the day said the way anyone would say it.
public func replayFormatHour(_ hour: Int) -> String {
    switch hour {
    case 0: return "midnight"
    case 12: return "midday"
    case 1..<12: return "\(hour) AM"
    default: return "\(hour - 12) PM"
    }
}

/// `2026-08-14` as "14 August", in `locale`.
public func replayFormatDay(_ iso: String, locale: Locale = .current) -> String {
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.timeZone = TimeZone(secondsFromGMT: 0)
    parser.dateFormat = "yyyy-MM-dd"
    guard let date = parser.date(from: iso) else { return iso }
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "d MMMM"
    return formatter.string(from: date)
}

/// A grouped count with its noun ("1 song", "12 plays").
public func replayCount(_ count: Int, one: String, other: String) -> String {
    "\(replayGrouped(Int64(count))) \(count == 1 ? one : other)"
}
