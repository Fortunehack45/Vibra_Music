import VibraMusicCore
import Observation
import Replay
import SwiftUI

// Ports ui/replay/ReplayStories.kt: the Replay as a run of full-screen cards. Tap the right of the
// screen to move on, the left to go back, hold anywhere to stop the clock, swipe to move by hand,
// the cross to leave. Every card holds for 14 s; the run stops at the last card rather than
// closing (closing on a timer would take the share button away from someone reaching for it).
// Each card is held to 9:16 and letterboxed, the shape the shared picture comes out as.

/// The story's clock and position, apart from any view so the mechanics can be tested.
@MainActor
@Observable
final class ReplayStoryPlayer {
    let pages: [ReplayStoryPage]
    /// The card on screen.
    private(set) var current: Int
    /// How far through the current card's hold, 0…1.
    private(set) var progress: Double = 0
    /// A finger is down.
    var held = false
    /// Something is up in front of the story (the share sheet): the clock waits for it, or by the
    /// time an app was chosen the card being sent would be two cards on.
    var paused = false
    /// Nobody is watching the clock run: the app is in the background, or VoiceOver is reading the
    /// card (a card that turns itself mid-sentence can't be listened to). Android gets the first for
    /// free — its progress is a frame animation, and no frames are drawn in the background.
    var suspended = false

    let pageDuration: TimeInterval

    init(summary: ReplaySummary, start: ReplayStoryPage, pageDuration: TimeInterval = TimeInterval(replayStoryPageDurationMs) / 1000) {
        // A category with nothing in it has no card: an empty page mid-story reads as a loss.
        pages = replayStoryPages(for: summary)
        current = pages.firstIndex(of: start) ?? 0
        self.pageDuration = pageDuration
    }

    var page: ReplayStoryPage { pages.indices.contains(current) ? pages[current] : .intro }
    var isLast: Bool { current == pages.count - 1 }
    var isRunning: Bool { !held && !paused && !suspended }

    /// The most one tick may move the clock. The clock stands in for a frame clock, which does not
    /// count time it was not drawing; a tick that arrives after the app was suspended must not
    /// spend the whole gap at once.
    static let maxTick: TimeInterval = 0.25

    /// The share of the width that means "back": the left edge, as everywhere else.
    static let backZone = 0.32

    /// Whether a touch at `point` on a card of `size` landed on one of the card's own buttons — the
    /// cross (top trailing) or the share button (bottom trailing). Android's tap detector never sees
    /// those (the button consumes the touch); here the story's press gesture runs alongside the
    /// buttons, so a tap on Share would otherwise also turn the page behind the share sheet.
    static func isOnControl(_ point: CGPoint, in size: CGSize, layoutDirection: LayoutDirection = .leftToRight) -> Bool {
        // Both buttons are 44 pt squares 20 pt in from the trailing edge; the cross sits 2 pt from
        // the top, the share button 18 pt from the bottom. A little slack around each.
        let fromTrailing = layoutDirection == .rightToLeft ? point.x : size.width - point.x
        guard fromTrailing <= 20 + 44 + 8 else { return false }
        let onClose = point.y <= 2 + 44 + 8
        let onShare = point.y >= size.height - (18 + 44 + 8)
        return onClose || onShare
    }

    /// A tap at `x` across a card `width` wide: back from the left third, forward otherwise.
    func tap(atX x: CGFloat, width: CGFloat, layoutDirection: LayoutDirection = .leftToRight) {
        var fraction = width > 0 ? Double(x / width) : 1
        // Mirrored in a right-to-left layout: "back" is at the leading edge wherever that is.
        if layoutDirection == .rightToLeft { fraction = 1 - fraction }
        step(forward: fraction >= Self.backZone)
    }

    func step(forward: Bool) {
        go(to: current + (forward ? 1 : -1))
    }

    /// Jumps to a card (a swipe settled there): the clock starts over on it.
    func go(to index: Int) {
        let next = min(max(index, 0), pages.count - 1)
        if next != current { current = next }
        progress = 0
    }

    /// Advances the clock by `seconds` of real time. A card that runs out moves on — except the
    /// last, which fills and holds.
    func tick(_ seconds: TimeInterval) {
        guard isRunning, pageDuration > 0, seconds > 0 else { return }
        progress = min(1, progress + seconds / pageDuration)
        if progress >= 1, !isLast { go(to: current + 1) }
    }
}

struct ReplayStories: View {
    let summary: ReplaySummary
    let periodLabel: String
    let holder: String
    let memberSince: String?
    let onClose: () -> Void

    @State private var player: ReplayStoryPlayer
    @State private var share: ReplayShareRequest?
    @State private var pressStarted: Date?
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.scenePhase) private var scenePhase

    init(summary: ReplaySummary, periodLabel: String, start: ReplayStoryPage, holder: String = "",
         memberSince: String? = nil, onClose: @escaping () -> Void) {
        self.summary = summary
        self.periodLabel = periodLabel
        self.holder = holder
        self.memberSince = memberSince
        self.onClose = onClose
        _player = State(initialValue: ReplayStoryPlayer(summary: summary, start: start))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // Fitted rather than filled: whichever of width and height runs out first sets the
            // size, and the rest is black — cropping would take the headline or the share button
            // off the edge on exactly the phones most likely to run this.
            GeometryReader { proxy in
                let fitted = Self.fittedSize(in: proxy.size)
                let scale = Self.canvasScale(forWidth: fitted.width)
                // A story is a fixed canvas (Android's StoryFrame): its type sizes, the collage and
                // the room each band gets are set against one phone-width card. On a frame
                // narrower than that — a phone on its side, where the 9:16 card is ~220 pt wide —
                // it is drawn at that width and shrunk to fit, rather than laid out again in a
                // column its contents overflow into the share button.
                stage
                    .frame(width: fitted.width / scale, height: fitted.height / scale)
                    .scaleEffect(scale)
                    .frame(width: fitted.width, height: fitted.height)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            // The card's text is part of the picture, sized against the canvas; past this size the
            // chrome's two lines ran into the headline under them.
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        }
        .statusBarHidden(false)
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
        .task { await runClock() }
        .onChange(of: share) { player.paused = share != nil }
        .onChange(of: scenePhase, initial: true) { updateSuspension() }
        .onChange(of: voiceOver, initial: true) { updateSuspension() }
        .sheet(item: $share) { request in
            ReplayShareSheet(summary: summary, periodLabel: periodLabel, holder: holder,
                             memberSince: memberSince, page: request.page)
        }
        .accessibilityAction(.escape) { onClose() }
    }

    // MARK: Stage

    /// The narrowest card the stage is laid out at: the narrowest phone held upright, so every
    /// phone in portrait draws it at its own size and only a sideways one shrinks it.
    static let canvasWidth: CGFloat = 360

    /// The largest 9:16 box that fits in `size` — letterboxed rather than cropped.
    static func fittedSize(in size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let width = min(size.width, size.height * 9 / 16)
        return CGSize(width: width, height: width * 16 / 9)
    }

    /// How far a card `width` wide is shrunk from the canvas (1 when it is at least that wide).
    static func canvasScale(forWidth width: CGFloat) -> CGFloat {
        guard width > 0 else { return 1 }
        return min(1, width / canvasWidth)
    }

    private var stage: some View {
        let page = player.page
        return GeometryReader { proxy in
            ZStack(alignment: .top) {
                Color(red: 0x17 / 255, green: 0x17 / 255, blue: 0x1A / 255)
                // The soft colour behind everything, from whatever the card is about, turned per
                // card so no two backdrops in the run are the same colour.
                ReplayMeshBackground(artwork: replayStoryArtwork(for: summary, page: page), hue: replayStoryHue(page))
                    .id(page)
                    .transition(.opacity)
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.45), location: 0),
                    .init(color: .black.opacity(0.10), location: 0.35),
                    .init(color: .black.opacity(0.34), location: 1),
                ], startPoint: .top, endPoint: .bottom)

                TabView(selection: Binding(get: { player.current }, set: { player.go(to: $0) })) {
                    ForEach(Array(player.pages.enumerated()), id: \.offset) { index, page in
                        ReplayStoryCard(page: page, summary: summary, periodLabel: periodLabel) {
                            share = ReplayShareRequest(page: page)
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .simultaneousGesture(pressGesture(size: proxy.size))

                // Handed the player rather than its progress: the clock ticks 30 times a second, and
                // only the segments read it — reading it here would rebuild every card on each tick.
                ReplayStoryChrome(title: ReplayText.title(periodLabel: periodLabel), player: player, onClose: onClose)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: page)
        }
        .clipped()
        .accessibilityIdentifier("replay.stories")
    }

    /// Down: hold the clock. Up quickly without travelling: a tap, which steps by where it landed.
    /// Up after the long-press timeout: only the hold ending — without that line, holding to pause
    /// would turn the page the moment the finger came off.
    private func pressGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { _ in
                if pressStarted == nil {
                    pressStarted = Date()
                    player.held = true
                }
            }
            .onEnded { value in
                let started = pressStarted ?? Date()
                pressStarted = nil
                player.held = false
                let travelled = hypot(value.translation.width, value.translation.height)
                guard travelled < 10, Date().timeIntervalSince(started) < 0.5,
                      !ReplayStoryPlayer.isOnControl(value.location, in: size, layoutDirection: layoutDirection)
                else { return }
                withTransaction(Transaction(animation: nil)) {
                    player.tap(atX: value.location.x, width: size.width, layoutDirection: layoutDirection)
                }
            }
    }

    private func updateSuspension() {
        player.suspended = scenePhase != .active || voiceOver
    }

    private func runClock() async {
        var last = ContinuousClock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(33))
            let now = ContinuousClock.now
            let elapsed = now - last
            last = now
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            player.tick(min(seconds, ReplayStoryPlayer.maxTick))
        }
    }
}

// MARK: - Chrome

/// The cross, the run of progress segments, and the two words saying what this is — over the
/// pager, so they stay put while the cards slide under them.
private struct ReplayStoryChrome: View {
    let title: String
    let player: ReplayStoryPlayer
    let onClose: () -> Void

    var body: some View {
        let count = player.pages.count
        let current = player.current
        let progress = player.progress
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: AppSymbol.close)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.closeReplay)
                .accessibilityIdentifier("replay.stories.close")
            }
            .padding(.top, 2)
            HStack(spacing: 4) {
                ForEach(0..<count, id: \.self) { index in
                    let fraction = index < current ? 1 : (index > current ? 0 : progress)
                    Capsule()
                        .fill(.white.opacity(0.28))
                        .overlay(alignment: .leading) {
                            GeometryReader { proxy in
                                Capsule().fill(.white).frame(width: proxy.size.width * min(max(fraction, 0), 1))
                            }
                        }
                        .frame(height: 2.5)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("\(current + 1) / \(count)")
            .accessibilityIdentifier("replay.stories.progress")
            HStack(spacing: 7) {
                Text(title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ReplayLogo(height: 17)
                    .opacity(0.9)
                Text(verbatim: "Vibra Music")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 20)
    }
}

// MARK: - One card

/// Every card is the same three bands: a sentence with its number set bold, the thing the sentence
/// is about, and the share button (on every card, since the card somebody wants to send is
/// whichever one surprised them; it sends that card).
private struct ReplayStoryCard: View {
    let page: ReplayStoryPage
    let summary: ReplaySummary
    let periodLabel: String
    let onShare: () -> Void

    /// Room the chrome takes above a card's content (it is drawn over the pager and pushes nothing).
    static let chromeHeight: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                let headline = ReplayText.headline(page, summary: summary, periodLabel: periodLabel)
                switch page {
                case .intro: intro(headline)
                case .minutes: minutes(headline)
                case .songs: leaderboard(headline, rows: replaySongRows(for: summary), circular: false)
                case .artists: leaderboard(headline, rows: replayArtistRows(for: summary), circular: true)
                case .albums: leaderboard(headline, rows: replayAlbumRows(for: summary), circular: false)
                case .genres: genres(headline)
                case .habits: habits(headline)
                case .summary: recap(headline)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                Spacer()
                Button(action: onShare) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(.white.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.shareMyReplay)
                .accessibilityIdentifier("replay.stories.share")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, Self.chromeHeight)
        .padding(.bottom, 18)
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
    }

    // MARK: Cards

    @ViewBuilder
    private func intro(_ headline: [ReplayHeadlineRun]) -> some View {
        ReplayHeadline(runs: headline)
        Spacer(minLength: 8)
        ReplayCollage(summary: summary)
        Spacer(minLength: 8)
        Text(L10n.replayPrivateCounting)
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.5))
    }

    @ViewBuilder
    private func minutes(_ headline: [ReplayHeadlineRun]) -> some View {
        ReplayHeadline(runs: headline)
        Spacer(minLength: 8)
        ReplayCollage(summary: summary)
        Spacer(minLength: 8)
        Text(ReplayText.minutesDetail(summary))
            .font(.body)
            .foregroundStyle(.white.opacity(0.62))
    }

    /// A number one with its runners-up: the hero is the answer, the list is the evidence.
    @ViewBuilder
    private func leaderboard(_ headline: [ReplayHeadlineRun], rows: [ReplayRow], circular: Bool) -> some View {
        if let lead = rows.first {
            ReplayHeadline(runs: headline)
            HStack(spacing: 16) {
                cover(lead, size: 116, circular: circular, pixels: ArtworkSize.header, elevated: true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(lead.title)
                        .font(.system(size: 26, weight: .heavy))
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                    if let subtitle = lead.subtitle {
                        Text(subtitle)
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    Text("\(ReplayText.listening(lead.ms)) · \(ReplayText.plays(lead.plays))")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.top, 4)
                }
            }
            .padding(.top, 18)
            Spacer(minLength: 8)
            ForEach(rows.dropFirst(), id: \.key) { row in
                HStack(spacing: 0) {
                    ReplayRankBadge(rank: row.rank)
                    cover(row, size: 36, circular: circular, pixels: ArtworkSize.row, elevated: false)
                    Text(row.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .padding(.leading, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(ReplayText.listening(row.ms))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private func genres(_ headline: [ReplayHeadlineRun]) -> some View {
        let rows = replayGenreRows(for: summary)
        if let lead = rows.first {
            ReplayHeadline(runs: headline)
            Spacer(minLength: 8)
            Text(lead.title)
                .font(.system(size: 60, weight: .heavy))
                .lineLimit(2)
                .minimumScaleFactor(0.5)
            Text(ReplayText.listening(lead.ms))
                .font(.headline.weight(.regular))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.bottom, 22)
            ForEach(rows.dropFirst(), id: \.key) { row in
                HStack(spacing: 0) {
                    ReplayRankBadge(rank: row.rank)
                    Text(row.title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(ReplayText.listening(row.ms))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .padding(.vertical, 5)
                .accessibilityElement(children: .combine)
            }
            Spacer().frame(height: 8)
        }
    }

    @ViewBuilder
    private func habits(_ headline: [ReplayHeadlineRun]) -> some View {
        ReplayHeadline(runs: headline)
        Spacer(minLength: 8)
        ForEach(ReplayText.habitStats(summary), id: \.label) { stat in
            VStack(alignment: .leading, spacing: 0) {
                Text(stat.value).font(.largeTitle.weight(.heavy))
                Text(stat.label).font(.subheadline).foregroundStyle(.white.opacity(0.58))
            }
            .padding(.bottom, 22)
            .accessibilityElement(children: .combine)
        }
        Spacer().frame(height: 8)
    }

    @ViewBuilder
    private func recap(_ headline: [ReplayHeadlineRun]) -> some View {
        ReplayHeadline(runs: headline)
        Spacer().frame(height: 20)
        ForEach(Array(ReplayText.recapLines(summary).enumerated()), id: \.offset) { _, line in
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(line.label)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 96, alignment: .leading)
                Text(line.value)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 9)
            .accessibilityElement(children: .combine)
        }
        Spacer(minLength: 8)
        Text(L10n.tapShareForPicture)
            .font(.body)
            .foregroundStyle(.white.opacity(0.55))
    }

    @ViewBuilder
    private func cover(_ row: ReplayRow, size: CGFloat, circular: Bool, pixels: Int, elevated: Bool) -> some View {
        if circular {
            ReplayCover(url: row.artworkUrl, fallbackText: row.title, size: size, shape: Circle(), pixels: pixels, elevated: elevated)
        } else {
            ReplayCover(url: row.artworkUrl, fallbackText: row.title, size: size,
                        // One shape for the lead and its runners-up, as Android's Leaderboard.
                        shape: RoundedRectangle(cornerRadius: 10, style: .continuous), pixels: pixels, elevated: elevated)
        }
    }
}

/// The sentence at the top of every card: two weights in one line, so the number is the loud
/// part of an ordinary sentence.
struct ReplayHeadline: View {
    let runs: [ReplayHeadlineRun]

    var body: some View {
        runs.reduce(Text(verbatim: "")) { text, run in
            text + Text(verbatim: run.text)
                .font(.system(size: 30, weight: run.bold ? .heavy : .semibold))
                .foregroundColor(run.bold ? .white : .white.opacity(0.62))
        }
        .lineSpacing(3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The scatter of covers and faces the opening cards are built around: hand-placed as fractions
/// of the box, so the pile keeps its shape at any size; releases square, artists round.
struct ReplayCollage: View {
    let summary: ReplaySummary

    nonisolated static func pieces(_ summary: ReplaySummary) -> (covers: [String], faces: [String]) {
        var covers: [String] = []
        for url in summary.songs.compactMap(\.song.thumbnailUrl) where !covers.contains(url) {
            covers.append(url)
            if covers.count == 3 { break }
        }
        var faces: [String] = []
        for url in summary.artists.compactMap(\.artworkUrl) where !covers.contains(url) && !faces.contains(url) {
            faces.append(url)
            if faces.count == 3 { break }
        }
        return (covers, faces)
    }

    private static let squares: [(x: CGFloat, y: CGFloat, size: CGFloat, angle: Double)] = [
        (0.26, 0.34, 168, -3), (0.05, 0.10, 88, -9), (0.62, 0.04, 72, 7),
    ]
    private static let circles: [(x: CGFloat, y: CGFloat, size: CGFloat)] = [
        (0.02, 0.62, 62), (0.70, 0.34, 76), (0.44, 0.78, 66),
    ]

    var body: some View {
        let (covers, faces) = Self.pieces(summary)
        if !covers.isEmpty || !faces.isEmpty {
            GeometryReader { proxy in
                let w = proxy.size.width, h = proxy.size.height
                // Scaled down with a short frame so every piece stays inside the box.
                let scale = min(1, h / 300)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(covers.enumerated()), id: \.offset) { index, url in
                        let spot = Self.squares[index]
                        ReplayCover(url: url, fallbackText: "", size: spot.size * scale,
                                    shape: RoundedRectangle(cornerRadius: 4, style: .continuous), pixels: ArtworkSize.card, elevated: true)
                            .rotationEffect(.degrees(spot.angle))
                            .offset(x: w * spot.x, y: h * spot.y)
                    }
                    ForEach(Array(faces.enumerated()), id: \.offset) { index, url in
                        let spot = Self.circles[index]
                        ReplayCover(url: url, fallbackText: "", size: spot.size * scale, shape: Circle(),
                                    pixels: ArtworkSize.card, elevated: true)
                            .offset(x: w * spot.x, y: h * spot.y)
                    }
                }
                .frame(width: w, height: h, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 300)
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityHidden(true)
        }
    }
}
