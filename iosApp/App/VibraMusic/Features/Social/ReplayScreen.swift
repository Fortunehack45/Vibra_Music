import VibraMusicCore
import PlaybackQueue
import Replay
import SwiftUI

// Ports ui/replay/ReplayScreen.kt and the part of MainActivity.kt that mounts it: the page washed
// in the top song's colours under a transparent top bar titled "Replay" once scrolled; the period
// line and picker; the headline cards; "Play your Replay" (which opens the stories at their
// first card); the four charts (a song starts playing on its own, an artist or album opens its
// page, found by name when the row has no id); the genres-pending note; the listening shape; and
// "Share my Replay". The stories and the share sheet are presented over it, the share sheet over
// the stories too.

struct ReplayScreen: View {
    /// Which chart the page opens scrolled to (a Library card for songs, artists or albums), or
    /// the top.
    var landingPage: ReplayStoryPage = .intro

    @Environment(AppModel.self) private var app

    var body: some View {
        ReplayPage(source: source, landingPage: landingPage, genresAvailable: ReplayText.genresAvailable(settings: app.settings))
    }

    private var source: ReplayDataSource {
        #if DEBUG
        if let demo = SocialDebugLaunch.replaySource { return demo }
        #endif
        return LiveReplayDataSource(stats: app.replayStats, onSummary: { [app] in app.replayEnrichment.drainArtistsIfNeeded() })
    }
}

/// Which card the stories open on (a value the full-screen cover can be presented for).
struct ReplayStoryLaunch: Identifiable, Hashable {
    let page: ReplayStoryPage
    var id: Int { page.rawValue }
}

/// What the share sheet is for: one story card, or the whole Replay (nil).
struct ReplayShareRequest: Identifiable, Hashable {
    let page: ReplayStoryPage?
    var id: Int { page?.rawValue ?? -1 }
}

/// The page over any ``ReplayDataSource``.
struct ReplayPage: View {
    let landingPage: ReplayStoryPage
    let genresAvailable: Bool

    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player
    @Environment(AppRouter.self) private var router
    @Environment(\.colorScheme) private var colorScheme

    @State private var model: ReplayPageModel
    @State private var story: ReplayStoryLaunch?
    @State private var share: ReplayShareRequest?

    init(source: ReplayDataSource, landingPage: ReplayStoryPage = .intro, genresAvailable: Bool = false, period: ReplayPeriod? = nil) {
        self.landingPage = landingPage
        self.genresAvailable = genresAvailable
        _model = State(initialValue: ReplayPageModel(source: source, period: period))
    }

    private var dark: Bool { colorScheme == .dark }
    private var ink: Color { dark ? .white : .black }
    private var holder: String { app.accounts.account?.name ?? "" }
    private var periodLabel: String { ReplayText.label(model.period) }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    heading
                    content
                }
                .padding(.bottom, 24)
            }
            .onChange(of: model.shownSummary == nil) { scrollToLanding(reader) }
            .onChange(of: model.period) { scrollToLanding(reader) }
            .onAppear { scrollToLanding(reader) }
        }
        .background { backdrop }
        .navigationTitle(L10n.replay)
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            await model.load()
            #if DEBUG
            if let page = SocialDebugLaunch.storyPage { story = ReplayStoryLaunch(page: page) }
            if let request = SocialDebugLaunch.sharePage { share = request }
            #endif
            await model.refreshWhileVisible()
        }
        .fullScreenCover(item: $story) { launch in
            if let summary = model.shownSummary {
                ReplayStories(summary: summary, periodLabel: periodLabel, start: launch.page,
                              holder: holder, memberSince: model.memberSince) { story = nil }
            }
        }
        .sheet(item: $share) { request in
            if let summary = model.shownSummary {
                ReplayShareSheet(summary: summary, periodLabel: periodLabel, holder: holder,
                                 memberSince: model.memberSince, page: request.page)
            }
        }
    }

    // MARK: Backdrop

    /// The player's mesh in the top song's colours, then most of it put back under ink so a page
    /// of ranked lists reads over it.
    private var backdrop: some View {
        ZStack {
            ReplayMeshBackground(artwork: model.summary?.songs.first?.song.thumbnailUrl)
            LinearGradient(
                colors: dark
                    ? [.black.opacity(0.30), .black.opacity(0.72), .black.opacity(0.88)]
                    : [.white.opacity(0.25), .white.opacity(0.65), .white.opacity(0.82)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    // MARK: Heading

    private var heading: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Android: `summary?.localizedLabel ?: period.localizedChip` — the chip's words until
            // the first read lands.
            Text(model.summary == nil ? ReplayText.chip(model.period) : periodLabel)
                .font(.headline.weight(.regular))
                .foregroundStyle(ink.opacity(0.6))
                .accessibilityIdentifier("replay.periodLabel")
            ReplayPeriodPicker(selected: model.period, ink: ink, dark: dark) { period in
                Task { await model.select(period) }
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, ReplayMetrics.gutter)
        .padding(.bottom, 18)
        .id("heading")
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.loading && model.summary == nil {
            ProgressView()
                .tint(ink.opacity(0.6))
                .frame(maxWidth: .infinity)
                .padding(64)
        } else if let summary = model.shownSummary {
            loaded(summary)
        } else {
            ReplayEmptyState(period: model.period, ink: ink)
        }
    }

    @ViewBuilder
    private func loaded(_ summary: ReplaySummary) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(ReplayText.heroCards(summary, periodLabel: periodLabel), id: \.label) { card in
                    ReplayWalletCard(card: card, holder: holder, memberSince: model.memberSince) {
                        story = ReplayStoryLaunch(page: card.page)
                    }
                    .frame(width: 300)
                }
            }
            .padding(.horizontal, ReplayMetrics.gutter)
            .padding(.vertical, 8)
        }
        .scrollClipDisabled()
        .accessibilityIdentifier("replay.cards")

        ReplayActionRow(symbol: AppSymbol.play, title: L10n.playYourReplay, ink: ink) {
            if let page = model.playYourReplay() { story = ReplayStoryLaunch(page: page) }
        }
        .accessibilityIdentifier("replay.play")

        chart(id: "songs", title: L10n.topSongs, rows: replaySongRows(for: summary, limit: replayChartLength)) { index in
            guard summary.songs.indices.contains(index) else { return }
            // A track on a chart is one the listener already likes: it plays on its own, with
            // AutoPlay carrying on, rather than queueing the chart it was on.
            player.playSong(summary.songs[index].song, source: QueueSource(title: L10n.replay, type: .replay))
        }
        chart(id: "artists", title: L10n.topArtists, rows: replayArtistRows(for: summary, limit: replayChartLength), circular: true) { index in
            guard summary.artists.indices.contains(index) else { return }
            let artist = summary.artists[index]
            open(browseId: artist.browseId, name: artist.title, subtitle: nil, artwork: artist.artworkUrl, type: .artist)
        }
        chart(id: "albums", title: L10n.topAlbums, rows: replayAlbumRows(for: summary, limit: replayChartLength)) { index in
            guard summary.albums.indices.contains(index) else { return }
            let album = summary.albums[index]
            open(browseId: album.browseId, name: album.title, subtitle: album.subtitle, artwork: album.artworkUrl, type: .album)
        }
        if !summary.genres.isEmpty {
            chart(id: "genres", title: L10n.topGenres, rows: replayGenreRows(for: summary, limit: replayChartLength)) { _ in }
        } else if genresAvailable {
            Text(L10n.genresPending)
                .font(.subheadline)
                .foregroundStyle(ink.opacity(0.6))
                .padding(.horizontal, ReplayMetrics.gutter)
        }

        ReplayHabits(summary: summary, ink: ink)
        ReplayActionRow(symbol: "square.and.arrow.up", title: L10n.shareMyReplay, ink: ink) {
            share = ReplayShareRequest(page: nil)
        }
        .accessibilityIdentifier("replay.share")
    }

    @ViewBuilder
    private func chart(id: String, title: String, rows: [ReplayRow], circular: Bool = false, onTap: @escaping (Int) -> Void) -> some View {
        if !rows.isEmpty {
            Text(title)
                .font(.title.weight(.heavy))
                .foregroundStyle(ink)
                .padding(.horizontal, ReplayMetrics.gutter)
                .padding(.top, 8)
                .padding(.bottom, 10)
                .accessibilityAddTraits(.isHeader)
                .id("\(id)-title")
            ForEach(rows, id: \.key) { row in
                ReplayChartRow(row: row, circular: circular, ink: ink) { onTap(row.rank - 1) }
            }
            Spacer().frame(height: 20)
        }
    }

    // MARK: Actions

    /// A Library card lands on its chart; the minutes card and the intro land at the top.
    private func scrollToLanding(_ reader: ScrollViewProxy) {
        guard model.shownSummary != nil else { return }
        let target: String?
        switch landingPage {
        case .songs: target = "songs-title"
        case .artists: target = "artists-title"
        case .albums: target = "albums-title"
        default: target = nil
        }
        guard let target else { return }
        DispatchQueue.main.async { reader.scrollTo(target, anchor: .top) }
    }

    /// Opens an artist's or album's page. Most rows have no id — an artist is counted by name — so
    /// the page is found by searching for the name (MainActivity's `openByName`).
    private func open(browseId: String?, name: String, subtitle: String?, artwork: String?, type: BrowseType) {
        if let browseId {
            let seed = BrowseItem(browseId: browseId, title: name,
                                  subtitle: subtitle ?? (type == .artist ? L10n.artist : L10n.album),
                                  thumbnailUrl: artwork, type: type)
            router.open(type == .artist ? .artist(browseId: browseId, seed: seed) : .album(browseId: browseId, seed: seed))
            return
        }
        let repository = app.repository
        let query = [name, subtitle].compactMap { $0 }.joined(separator: " ")
        Task {
            let hit = try? await repository.search(query: query, filter: type == .artist ? .artists : .albums)
                .lazy.compactMap { result -> BrowseItem? in
                    if case .browse(let item) = result { return item }
                    return nil
                }.first
            if var hit {
                if hit.thumbnailUrl == nil { hit.thumbnailUrl = artwork }
                router.open(.item(hit))
            } else {
                player.notice = QueueNotice(message: L10n.couldntFind(name), symbol: nil)
            }
        }
    }
}

enum ReplayMetrics {
    /// PAGE_GUTTER + 10 dp.
    static let gutter: CGFloat = AppTheme.gutter + 10
}

// MARK: - Parts

/// The three stretches a Replay can cover — months and years, the granularity listening is kept
/// at. Android drew these as a row of chips on a tinted track; the same here, since a system
/// segmented control would not sit on the mesh.
struct ReplayPeriodPicker: View {
    let selected: ReplayPeriod
    let ink: Color
    let dark: Bool
    let onSelect: (ReplayPeriod) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ReplayPeriod.allCases, id: \.self) { period in
                let active = period == selected
                Button {
                    onSelect(period)
                } label: {
                    Text(ReplayText.chip(period))
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(active ? (dark ? Color.black : Color.white) : ink.opacity(0.75))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(active ? ink.opacity(0.92) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? [.isSelected] : [])
                .accessibilityIdentifier("replay.period.\(period.rawValue)")
            }
        }
        .padding(3)
        .background(ink.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.easeInOut(duration: 0.16), value: selected)
    }
}

/// The page's two acts — open the Replay, send the Replay — drawn alike.
struct ReplayActionRow: View {
    let symbol: String
    let title: String
    let ink: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 18)
                Text(title)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: AppSymbol.chevronRight)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ink.opacity(0.5))
                    .flipsForRightToLeftLayoutDirection(true)
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(ink.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, ReplayMetrics.gutter)
        .padding(.vertical, 18)
    }
}

/// One line of one chart: rank, cover, title, "subtitle · time", plays.
struct ReplayChartRow: View {
    let row: ReplayRow
    let circular: Bool
    let ink: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                ReplayRankBadge(rank: row.rank, quiet: ink.opacity(0.45))
                cover
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(ink)
                        .lineLimit(1)
                    Text([row.subtitle, ReplayText.listening(row.ms)].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(ink.opacity(0.55))
                        .lineLimit(1)
                }
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                if row.plays > 0 {
                    Text("\(row.plays)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(ink.opacity(0.45))
                        .padding(.leading, 8)
                }
            }
            .padding(.horizontal, ReplayMetrics.gutter)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.rank). \(row.title)")
        .accessibilityIdentifier("replay.row")
    }

    @ViewBuilder
    private var cover: some View {
        if circular {
            ReplayCover(url: row.artworkUrl, fallbackText: row.title, size: 48, shape: Circle())
        } else {
            ReplayCover(url: row.artworkUrl, fallbackText: row.title, size: 48, shape: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

/// "Listening shape": three counts, then when and on which day.
private struct ReplayHabits: View {
    let summary: ReplaySummary
    let ink: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.listeningShape)
                .font(.title.weight(.heavy))
                .foregroundStyle(ink)
                .padding(.top, 8)
                .padding(.bottom, 14)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 10) {
                tile(L10n.songs, summary.distinctSongs)
                tile(L10n.artists, summary.distinctArtists)
                tile(L10n.albums, summary.distinctAlbums)
            }
            if let peak = summary.peakHour {
                note(L10n.listenMostAround(ReplayText.hour(peak))).padding(.top, 10)
            }
            if let day = summary.busiestDay {
                note(L10n.biggestDayNote(ReplayText.day(day), ReplayText.listening(summary.busiestDayMs))).padding(.top, 6)
            }
        }
        .padding(.horizontal, ReplayMetrics.gutter)
        .accessibilityIdentifier("replay.habits")
    }

    private func tile(_ label: String, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title.weight(.heavy))
                .foregroundStyle(ink)
            Text(label)
                .font(.caption2)
                .tracking(1)
                .foregroundStyle(ink.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(ink.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(ink.opacity(0.6))
    }
}

/// Nothing to show yet for this stretch.
private struct ReplayEmptyState: View {
    let period: ReplayPeriod
    let ink: Color

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: AppSymbol.clock)
                .font(.system(size: 44))
                .foregroundStyle(ink.opacity(0.4))
            Text(L10n.notEnoughListening)
                .font(.title3.weight(.semibold))
                .foregroundStyle(ink)
                .padding(.top, 16)
            Text(period == .thisMonth ? L10n.notEnoughThisMonth : L10n.replayEmptyDescription)
                .font(.subheadline)
                .foregroundStyle(ink.opacity(0.6))
                .padding(.top, 8)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 36)
        .padding(.vertical, 48)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("replay.empty")
    }
}
