import VibraMusicCore
import Lyrics
import SwiftUI

/// The full lyrics, inside Now Playing (ports `LyricsPanel` and its translate / romanize discs
/// from ui/player/PlayerLyrics.kt and NowPlayingScreen.kt).
///
/// Apple Music's lyrics view: big tight type, the line being sung lit word by word, everything
/// else falling out of focus the further it is from it. Scrolling by hand clears the blur and
/// suspends the auto-follow so you can read ahead; a moment after you stop it goes back to the
/// song. Tapping a line seeks to it.
///
/// The lyrics come from the player's ``LyricsSession`` in the environment (one lookup shared with
/// the strip over the scrubber and the provider sheet); without one — the panel shown on its own —
/// it looks the playing track up itself. Translation state likewise comes from an injected
/// ``LyricsTranslationController`` when the player provides one, so the status line and the strip
/// agree with the panel; otherwise the panel keeps its own.
struct LyricsPanel: View {
    @Environment(AppModel.self) private var app: AppModel?
    @Environment(PlayerController.self) private var player: PlayerController?
    @Environment(AppSettings.self) private var settings
    @Environment(LyricsSession.self) private var injectedSession: LyricsSession?
    @Environment(LyricsTranslationController.self) private var injectedTranslation: LyricsTranslationController?
    @Environment(LyricsShareController.self) private var share: LyricsShareController?
    @Environment(\.lyricsPanelChrome) private var chrome
    @Environment(\.scenePhase) private var scenePhase

    @State private var ownSession: LyricsSession?
    @State private var ownTranslation = LyricsTranslationController()
    @State private var clock = LyricFrameClock()

    private var session: LyricsSession? { injectedSession ?? ownSession }
    private var translation: LyricsTranslationController { injectedTranslation ?? ownTranslation }
    private var trackKey: String { player?.currentSong?.videoId ?? "" }

    var body: some View {
        LyricsPanelContent(
            lines: session?.lines ?? [],
            subLines: translation.subLines,
            looking: !(session?.isChecked ?? false),
            trackKey: trackKey,
            clock: clock,
            isPlaying: player?.isPlaying ?? false,
            translation: translation,
            onSeek: seek
        )
        .background {
            if let player {
                LyricClockFeed(player: player, clock: clock, offsetMs: settings.lyricsOffsetMs, trackKey: trackKey)
            }
        }
        .onAppear {
            if injectedSession == nil, ownSession == nil {
                ownSession = LyricsSession(repository: app?.lyrics ?? .shared)
            }
        }
        .task(id: ownLookupKey) { loadOwnLookup() }
        .onChange(of: translationKey, initial: true) {
            translation.configure(
                trackId: trackKey,
                lines: session?.lines,
                preferredLanguage: settings.translationLanguage,
                appLanguageTag: LanguageBundle.override ?? LyricsTranslationTarget.appLanguageTag
            )
        }
        .onChange(of: runnable, initial: true) { clock.isRunnable = runnable }
        // The panel's own lines, and the player's sleeve, for the card: the pick indexes into these
        // and the sheet draws them, so a new track or a re-fetched verse starts the pick over rather
        // than leaving stale indices behind.
        .onChange(of: shareKey, initial: true) {
            share?.configure(song: player?.currentSong, trackKey: trackKey, lines: session?.lines ?? [],
                             subLines: translation.subLines,
                             artworkUrl: player?.currentSong?.thumbnailUrl)
        }
        // `onDisappear` stops the display link; coming back with nothing else changed (a cover
        // dismissed over the player) has to start it again rather than wait for the next report,
        // and catch up with the engine first.
        .onAppear {
            clock.isRunnable = runnable
            clock.resume()
        }
        .onChange(of: translation.notice) { _, notice in
            guard let notice else { return }
            player?.notice = QueueNotice(message: LyricsStatus.message(for: notice.kind), symbol: nil)
        }
        .onDisappear { clock.stop() }
    }

    private var runnable: Bool {
        chrome.active && scenePhase == .active && (app?.isInForeground ?? true)
    }

    /// Everything the translation is keyed on (Android: `remember(trackId, translationLanguage,
    /// lyrics)`). The whole line list, not a summary of it: another provider's answer for the same
    /// song usually has the same line count and first line but different timings, and the
    /// translation and the strip must follow it.
    private var translationKey: TranslationKey {
        TranslationKey(track: trackKey, language: settings.translationLanguage, lines: session?.lines,
                       session: session.map(ObjectIdentifier.init))
    }

    private struct TranslationKey: Equatable {
        var track: String
        var language: String
        var lines: [LyricLine]?
        var session: ObjectIdentifier?
    }

    /// Everything the pick mode's lines and card are keyed on (Android's
    /// `LaunchedEffect(song.videoId, lines)` and the artwork the card carries).
    private struct ShareKey: Equatable {
        var song: Song?
        var lines: [LyricLine]
        var subLines: [LyricLine]?
        var artworkUrl: String?
    }

    private var shareKey: ShareKey {
        ShareKey(song: player?.currentSong, lines: session?.lines ?? [], subLines: translation.subLines,
                 artworkUrl: player?.currentSong?.thumbnailUrl)
    }

    private var ownLookupKey: String {
        guard injectedSession == nil, ownSession != nil, let player, let song = player.currentSong else { return "" }
        return "\(song.videoId)|\(player.duration > 0)|\(settings.syncedLyrics)|\(settings.lyricsSources.count)"
    }

    /// The panel on its own does the player's lookup (the same inputs MainViewModel uses).
    private func loadOwnLookup() {
        guard injectedSession == nil, let session = ownSession, let player else { return }
        guard let song = player.currentSong else { return session.reset() }
        let durationMs = player.duration > 0 ? Int(player.duration * 1_000) : song.durationMillis
        session.load(
            LyricsTrack(videoId: song.videoId, title: song.title, artist: song.artist, album: song.albumName,
                        durationMs: durationMs, localFileURL: PlaybackSourceFactory.localFileURL(of: song)),
            preferences: LyricsPreferences(settings: settings)
        )
    }

    /// Tapping a line lands on it with the listener's offset applied.
    private func seek(to lineTimeMs: Int) {
        guard let player else { return }
        let target = LyricsOffset.seekTarget(lineTimeMs: lineTimeMs, offsetMs: settings.lyricsOffsetMs)
        Haptics.shared.play(.select)
        player.seek(to: Double(target) / 1_000)
        clock.report(positionMs: lineTimeMs, isPlaying: player.isPlaying)
    }
}

/// Feeds the player's position reports into a lyric clock (the panel's and the strip's). Its own
/// view so the 4×-a-second position tick re-renders this and nothing else. It also hands the
/// clock a direct line to the player, so the clock can re-sync the moment frames resume instead
/// of waiting for the next report to come through SwiftUI.
struct LyricClockFeed: View {
    let player: PlayerController
    let clock: LyricFrameClock
    let offsetMs: Int
    let trackKey: String

    var body: some View {
        let position = LyricsOffset.adjustedPosition(positionMs: Int(player.position * 1_000), offsetMs: offsetMs)
        let playing = player.isPlaying
        Color.clear
            .onChange(of: trackKey, initial: true) {
                connect()
                clock.reset(positionMs: position, isPlaying: playing)
            }
            .onChange(of: position) { clock.report(positionMs: position, isPlaying: playing) }
            .onChange(of: playing) { clock.report(positionMs: position, isPlaying: playing) }
            .onChange(of: offsetMs) {
                connect()
                clock.reset(positionMs: position, isPlaying: playing)
            }
            .onAppear { connect() }
            .accessibilityHidden(true)
    }

    private func connect() {
        let offset = offsetMs
        clock.source = { [weak player] in
            guard let player else { return (0, false) }
            return (LyricsOffset.adjustedPosition(positionMs: Int(player.position * 1_000), offsetMs: offset), player.isPlaying)
        }
    }
}

/// The panel proper, fed with plain values so it can be hosted without a player (tests, previews,
/// the debug screens).
struct LyricsPanelContent: View {
    let lines: [LyricLine]
    /// Romanized or translated copies of `lines`, index for index, drawn small under each line.
    let subLines: [LyricLine]?
    /// Whether the lookup for this track is still out.
    let looking: Bool
    let trackKey: String
    let clock: LyricFrameClock
    let isPlaying: Bool
    let translation: LyricsTranslationController
    let onSeek: (Int) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(\.lyricsPanelChrome) private var chrome
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(LyricsShareController.self) private var share: LyricsShareController?
    @Environment(PlayerController.self) private var player: PlayerController?
    @State private var model = LyricsPanelModel()

    var body: some View {
        let picking = share?.picking ?? false
        ZStack(alignment: .bottom) {
            if lines.isEmpty {
                emptyState
            } else {
                LyricsList(
                    model: model,
                    subLines: subLines,
                    trackKey: trackKey,
                    clock: clock,
                    playing: isPlaying && chrome.active,
                    blurEnabled: settings.lyricsBlur && !settings.reduceDynamicBlur,
                    glowing: !reduceMotion && !settings.reduceDynamicBlur && settings.lyricsBlur,
                    rises: !systemReduceMotion,
                    reduceMotion: reduceMotion,
                    systemReduceMotion: systemReduceMotion,
                    particleTrigger: reduceMotion ? 0 : translation.transition,
                    picking: picking,
                    picks: share?.picks ?? [],
                    canPick: share != nil,
                    onPick: { refused(share?.pick($0) ?? false) },
                    onToggle: { refused(share?.toggle($0) ?? false) },
                    onSeek: onSeek
                )
            }
            LyricsTranslationDiscs(translation: translation, hasLyrics: !lines.isEmpty,
                                   shown: chrome.active && chrome.controlsOpen && !picking)
            // The bar arrives and leaves without a transition of its own: it is an instruction over
            // the words, and one that has to be legible the instant it is on.
            if let share, share.picking {
                LyricsPickBar(shareEnabled: share.canShare,
                              onCancel: { share.cancel() },
                              onShare: { share.share() })
            }
        }
        .onChange(of: lines, initial: true) {
            model.setLines(lines)
            model.update(positionMs: clock.positionMs)
        }
        .onAppear {
            let panel = model
            clock.onTick = { [weak panel] position in panel?.update(positionMs: position) }
            model.update(positionMs: clock.positionMs)
        }
        // A container: without this the identifier lands on every child and hides theirs.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lyrics.panel")
    }

    /// Either setting turns off the glow, the particles and the sub-lyric reveal. Only iOS's own
    /// Reduce Motion changes how the page moves: Android's "Reduce animation" leaves the scroll,
    /// fades, blur and scale running, and iOS's setting swaps the travel for a short ease.
    private var reduceMotion: Bool { settings.reduceAnimation || systemReduceMotion }

    /// A line that will not fit on the card says so for itself, the way every other refusal in this
    /// player is worded (Android's `showMessage`). The bar is not the place to say it: it is two
    /// buttons over somebody's words, and a line that stays dim is the answer.
    private func refused(_ refused: Bool) {
        guard refused else { return }
        player?.notice = QueueNotice(message: L10n.lyricsSharePickLimit, symbol: nil)
    }

    @ViewBuilder
    private var emptyState: some View {
        Group {
            // "None" is a finding, and only worth reporting once the lookup has come back with it.
            if looking {
                LyricsSkeleton()
                    .accessibilityHidden(true)
            } else {
                Text(L10n.noLyricsForTrack)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("lyrics.empty")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { if !chrome.controlsOpen { chrome.onRevealControls() } }
    }
}

// MARK: - The list

/// The scrolling stack of lines, its auto-follow, and the hand-scroll hand-over.
private struct LyricsList: View {
    let model: LyricsPanelModel
    let subLines: [LyricLine]?
    let trackKey: String
    let clock: LyricFrameClock
    let playing: Bool
    let blurEnabled: Bool
    let glowing: Bool
    let rises: Bool
    let reduceMotion: Bool
    let systemReduceMotion: Bool
    let particleTrigger: Int
    /// A pick is open: the page holds still, the lower-half tap stands down, and the rows light up
    /// rather than seek.
    let picking: Bool
    /// Which lines are chosen, as indices into the list.
    let picks: Set<Int>
    /// Whether this panel can turn picked lines into a card at all.
    let canPick: Bool
    let onPick: (Int) -> Void
    let onToggle: (Int) -> Void
    let onSeek: (Int) -> Void

    @Environment(\.lyricsPanelChrome) private var chrome
    @State private var viewportHeight: CGFloat = 0
    /// Keyed to the track, not the lines: toggling a translation replaces every line while the
    /// reader's place in the song is unchanged, and must not snap the page back to the top.
    @State private var placedTrack: String?
    @State private var visibleRows: Set<Int> = []
    /// The page's journey to the playing line, for the rows that fan out behind it.
    @State private var fan = LyricFan()
    /// Where each row on screen sits in the list's frame. Plain storage, not state: it changes
    /// every scrolled frame and nothing is drawn from it.
    @State private var rowTops = RowTops()
    /// When the page's last move ends. Plain storage.
    @State private var followScroll = FollowScroll()
    /// When a line that landed mid-move gets its follow, once that move is over. A `.task(id:)`
    /// waits on it, so the wait dies with the panel and a cancelled wait skips the follow.
    @State private var catchUpAt: Date?
    /// The instrumental row standing open: the one the page is on. It opens and closes inside the
    /// page's own move, so the rows around it travel with the page.
    @State private var openGap: Int?
    @State private var scrollTravel: CGFloat = 0
    @State private var lastDragY: CGFloat?
    /// A lower-half tap that brought the controls back rather than seeking.
    @State private var tapRevealedAt: Date?

    private static let space = "lyrics.list"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.lines.enumerated()), id: \.offset) { index, line in
                        row(index: index, line: line)
                            .modifier(LyricFanOut(
                                elapsedMs: fan.elapsedMs,
                                delta: fan.delta,
                                durationMs: fan.durationMs,
                                delayMs: LyricHandover.delayMs(
                                    behind: LyricHandover.behind(index: index, focus: model.focusLine, delta: fan.delta),
                                    durationMs: fan.durationMs
                                )
                            ))
                            .id(index)
                            .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named(Self.space)).minY }) { rowTops.tops[index] = $0 }
                            .onAppear { visibleRows.insert(index) }
                            .onDisappear {
                                visibleRows.remove(index)
                                rowTops.tops[index] = nil
                            }
                    }
                }
                .padding(.horizontal, max(chrome.bleed - LyricsPanelMetrics.glowRoom, 0))
                // Room to scroll the last line up to the top of the page.
                .padding(.bottom, viewportHeight * 0.8)
                .animation(reduceMotion ? nil : LyricMotion.easing(milliseconds: 460), value: subLines == nil)
            }
            .scrollBounceBehavior(.basedOnSize)
            // The followed line rests at this margin, whatever its height: see followAnchor.
            .contentMargins(.top, LyricsPanelMetrics.followTop, for: .scrollContent)
            .coordinateSpace(name: Self.space)
            // Masked before bleeding out: a mask applied after the negative padding is sized to the
            // panel's own column, which shaved the bloom and every start-aligned line's first
            // letters, and knocked the platform-drawn lines off their frames.
            .mask(fadingEdges)
            .padding(.horizontal, -chrome.bleed)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { viewportHeight = $0 }
            .modifier(ScrollInteractionTracking(model: model, onTravel: travel))
            .simultaneousGesture(SpatialTapGesture(coordinateSpace: .local).onEnded { value in
                // With the controls away, the lower half of the page is the way to bring them back;
                // a tap there reveals instead of seeking (LyricsControlsGesture.kt). A pick has the
                // whole panel to itself: the transport must not surface under somebody choosing
                // lines.
                guard !chrome.controlsOpen, !picking, !model.isScrolling, value.location.y >= viewportHeight / 2 else { return }
                tapRevealedAt = Date()
                chrome.onRevealControls()
            })
            .onChange(of: followKey, initial: true) { follow(proxy) }
            .onChange(of: model.isScrolling) { _, scrolling in chrome.onScrollingChange(scrolling) }
            .task(id: catchUpAt) {
                guard let wake = catchUpAt else { return }
                do { try await Task.sleep(for: .seconds(max(wake.timeIntervalSinceNow, 0))) } catch { return }
                catchUpAt = nil
                follow(proxy, catchingUp: true)
            }
            .task(id: BrowseTimer(browsing: model.browsing, activeOnScreen: activeOnScreen, scrolling: model.isScrolling, playing: playing)) {
                // Paused, there's no song to follow back to: a hand scroll stays where it was left.
                guard playing, model.browsing, activeOnScreen, !model.isScrolling else { return }
                try? await Task.sleep(for: .milliseconds(600))
                if !Task.isCancelled { model.browsing = false }
            }
            .task(id: BrowseTimer(browsing: model.browsing, activeOnScreen: false, scrolling: model.isScrolling, playing: playing)) {
                guard playing, model.browsing, !model.isScrolling else { return }
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled { model.browsing = false }
            }
        }
    }

    private struct BrowseTimer: Hashable {
        var browsing: Bool
        var activeOnScreen: Bool
        var scrolling: Bool
        var playing: Bool
    }

    private struct FollowKey: Equatable {
        var focus: Int
        var browsing: Bool
        var picking: Bool
        var controlsOpen: Bool
        var active: Bool
        var track: String
        var height: CGFloat
    }

    private var followKey: FollowKey {
        FollowKey(focus: model.focusLine, browsing: model.browsing, picking: picking, controlsOpen: chrome.controlsOpen,
                  active: chrome.active, track: trackKey, height: viewportHeight > 0 ? 1 : 0)
    }

    private var activeOnScreen: Bool { visibleRows.contains(model.focusLine) }

    /// Keeps the line being sung at the top of the page, arriving on the run-up's own duration
    /// and curve so the move ends as the words start.
    private func follow(_ proxy: ScrollViewProxy, catchingUp: Bool = false) {
        let focus = model.focusLine
        let gap = model.lines.indices.contains(focus) && model.lines[focus].isGap ? focus : nil
        guard chrome.active, model.isSynced, !model.browsing, !picking, model.lines.indices.contains(focus), viewportHeight > 0 else {
            // No move to ride on: the break still opens and closes, on its own.
            if gap != openGap { withAnimation(LyricMotion.settle) { openGap = gap } }
            return
        }
        // An animated scrollTo issued while the last one is still running is lost: the page
        // finishes the old move and the sung line rests a row low. Android retargets
        // the running scroll; here a line that lands mid-move follows once that move is over. Only
        // a move on this track counts: a new track's first placement has no running move to wait for.
        let now = Date()
        if let left = followScroll.remaining(track: trackKey, now: now) {
            // A frame past the move's end.
            if catchUpAt == nil { catchUpAt = now.addingTimeInterval(left + 0.02) }
            return
        }
        // Moving now: a wait still under way is for a line this move already covers.
        if catchUpAt != nil { catchUpAt = nil }
        let runUp = LyricFocus.scrollLeadMs(model.lines, positionMs: clock.positionMs)
        let motion = LyricMotion.follow(
            placed: placedTrack == trackKey,
            systemReduceMotion: systemReduceMotion,
            rowOnScreen: visibleRows.contains(focus),
            leadMs: catchingUp
                ? LyricMotion.catchUpMs(lineStartMs: model.lines[focus].timeMs, positionMs: clock.positionMs, runUpMs: runUp)
                : runUp
        )
        placedTrack = trackKey
        followScroll.began(track: trackKey, now: now, duration: Double(motion.durationMs) / 1_000)
        // Only a glide fans the rows. Any other move (a new track's first placement, a seek, a
        // staged or short-eased move) drops a fan still running, or its rows keep the old offsets
        // through the new move.
        if case .glide = motion {} else if fan.elapsedMs != 0 { endFan(run: fan.run) }
        guard let animation = motion.animation else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                openGap = gap
                proxy.scrollTo(focus, anchor: LyricsPanelMetrics.followAnchor)
            }
            return
        }
        // Started in the same turn as the scroll, so the rows and the page they trail share a clock.
        if case .glide(let milliseconds) = motion { startFan(to: focus, durationMs: milliseconds) }
        // The break's row opens or closes in the same transaction as the scroll. Changed
        // on its own clock, the rows around it jumped as it did, a move still running was cut short,
        // and the line after it, already at the top, was pulled up past it: a ScrollView keeps its
        // offset when a row above shrinks, where Android's list keeps the top line in place.
        withAnimation(animation) {
            openGap = gap
            proxy.scrollTo(focus, anchor: LyricsPanelMetrics.followAnchor)
        }
    }

    /// Sets the rows after `focus` off behind the page. Android restarts the run when a newer line
    /// lands mid-move; here a move still under way just drops its offsets and the new one goes
    /// without them, which only a line shorter than the run-up reaches.
    private func startFan(to focus: Int, durationMs: Int) {
        let idle = fan.elapsedMs == 0
        // Onto a break, the row opening under the page pushes the rows behind it back down: they
        // barely move, and there is nothing to trail.
        guard idle, !model.lines[focus].isGap, let top = rowTops.tops[focus], abs(top - LyricsPanelMetrics.followTop) > 1 else {
            if !idle { endFan(run: fan.run) }
            return
        }
        let run = fan.run + 1
        let span = LyricHandover.spanMs(durationMs: durationMs)
        fan = LyricFan(run: run, delta: top - LyricsPanelMetrics.followTop, durationMs: durationMs, elapsedMs: 0)
        withAnimation(.linear(duration: span / 1_000), completionCriteria: .logicallyComplete) {
            fan.elapsedMs = span
        } completion: {
            endFan(run: run)
        }
    }

    /// Every row is back in its place by now, so dropping the offsets moves nothing.
    private func endFan(run: Int) {
        guard fan.run == run else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { fan = LyricFan(run: run) }
    }

    /// Reading on hides the player; coming back up brings it out again. Direction comes from the
    /// finger's own travel, and a change of mind starts the count over.
    private func travel(_ delta: CGFloat) {
        guard delta != 0 else { return }
        if scrollTravel != 0, (scrollTravel > 0) != (delta > 0) { scrollTravel = 0 }
        scrollTravel += delta
        if scrollTravel >= LyricsPanelMetrics.controlsScrollSlop {
            scrollTravel = 0
            chrome.onHideControls()
        } else if scrollTravel <= -LyricsPanelMetrics.controlsScrollSlop {
            scrollTravel = 0
            // A pick owns the panel: the transport must not surface under somebody choosing lines
            // (Android's `onReveal = { if (!picking) onRevealControls() }`).
            if !picking { chrome.onRevealControls() }
        }
    }

    private var fadingEdges: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: LyricsPanelMetrics.edgeFade)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: LyricsPanelMetrics.edgeFade)
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(index: Int, line: LyricLine) -> some View {
        let synced = model.isSynced
        if !synced && GeniusProvider.isSectionHeader(line.text) {
            LyricSectionHeader(text: line.text, first: index == 0)
        } else if !synced && line.isGap {
            Color.clear.frame(height: 14)
        } else {
            let offset = model.offset(of: index)
            let active = model.isActive(index)
            let alpha = LyricRowStyle.alpha(synced: synced, active: active, browsing: model.browsing, distance: offset)
            let blur = LyricRowStyle.blur(synced: synced, active: active, browsing: model.browsing, distance: offset, blurEnabled: blurEnabled)
            if line.isGap {
                LyricGapRow(
                    line: line,
                    until: model.lines.indices.contains(index + 1) ? model.lines[index + 1].timeMs : line.endMs,
                    open: openGap == index,
                    active: active,
                    alpha: alpha,
                    blur: blur,
                    clock: clock,
                    systemReduceMotion: systemReduceMotion,
                    picking: picking,
                    canSeek: synced,
                    onTap: { seek(line) }
                )
            } else {
                let focus = model.focusLine
                LyricRow(
                    line: line,
                    sub: subLines.flatMap { $0.indices.contains(index) ? $0[index] : nil },
                    active: active,
                    sung: offset < 0,
                    synced: synced,
                    alignEnd: model.isDuet && line.alignment == .end,
                    duet: model.isDuet,
                    browsing: model.browsing,
                    alpha: alpha,
                    blur: blur,
                    glowing: glowing,
                    rises: rises,
                    reduceMotion: reduceMotion,
                    systemReduceMotion: systemReduceMotion,
                    clock: clock,
                    // Only the rows in front of the reader get the particle pass.
                    particleTrigger: (synced ? abs(index - focus) <= 1 : index < 4) ? particleTrigger : 0,
                    picking: picking,
                    picked: picks.contains(index),
                    canPick: canPick,
                    onTap: { seek(line) },
                    onPick: { onPick(index) },
                    onToggle: { onToggle(index) }
                )
            }
        }
    }

    private func seek(_ line: LyricLine) {
        guard model.isSynced else { return }
        // A lower-half tap that just brought the controls back isn't also a seek. The two
        // gestures end on the same touch, in either order, so the check waits a turn.
        DispatchQueue.main.async {
            if let revealed = tapRevealedAt, Date().timeIntervalSince(revealed) < 0.4 { return }
            onSeek(line.timeMs)
        }
    }
}

/// Follows the reader's own scrolling: a drag starts a browse, and the finger's travel decides
/// whether the player's controls go away or come back. Only direct input counts — the panel
/// scrolls itself every time a line lands, and that is not somebody reading on.
private struct ScrollInteractionTracking: ViewModifier {
    let model: LyricsPanelModel
    let onTravel: (CGFloat) -> Void

    @State private var interacting = false
    @State private var lastOffset: CGFloat?
    @State private var lastDrag: CGFloat?

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onScrollPhaseChange { _, phase in
                    interacting = phase == .interacting
                    if phase == .interacting, !model.browsing { model.browsing = true }
                    let scrolling = phase == .interacting || phase == .decelerating
                    if scrolling != model.isScrolling { model.isScrolling = scrolling }
                    if phase != .interacting { lastOffset = nil }
                }
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, offset in
                    guard interacting else { return }
                    if let lastOffset { onTravel(offset - lastOffset) }
                    lastOffset = offset
                }
        } else {
            // iOS 17 has no scroll phases; a simultaneous drag sees the same finger.
            content.simultaneousGesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        if !model.browsing { model.browsing = true }
                        if !model.isScrolling { model.isScrolling = true }
                        if let lastDrag { onTravel(-(value.translation.height - lastDrag)) }
                        lastDrag = value.translation.height
                    }
                    .onEnded { _ in
                        lastDrag = nil
                        model.isScrolling = false
                    }
            )
        }
    }
}

// MARK: - Fan-out

/// One move of the page to a new line, as the rows behind it see it.
private struct LyricFan: Equatable {
    var run = 0
    /// How far the page is going.
    var delta: CGFloat = 0
    var durationMs = 0
    /// Milliseconds into the move: set to the move's span inside a linear animation, so the rows
    /// read it frame by frame without the list being rebuilt each time.
    var elapsedMs: Double = 0
}

/// When the page's last move ends, and which track's lines it was moving over.
final class FollowScroll {
    private var busyUntil: Date?
    private var busyTrack: String?

    /// Seconds until the page's move is over, or nil when it is free to take another. A move over
    /// another track's lines says nothing about this one's.
    func remaining(track: String, now: Date) -> TimeInterval? {
        guard busyTrack == track, let busy = busyUntil, now < busy else { return nil }
        return busy.timeIntervalSince(now)
    }

    func began(track: String, now: Date, duration: TimeInterval) {
        busyTrack = track
        busyUntil = now.addingTimeInterval(duration)
    }
}

private final class RowTops {
    var tops: [Int: CGFloat] = [:]
}

/// Holds a row back against the page's own scroll (Android: the row's `translationY`). The page has
/// already taken the row part of the way, so giving back what it has not earned yet leaves the row
/// trailing; a row with no delay reads nothing and sits exactly still against the list.
private struct LyricFanOut: GeometryEffect {
    var elapsedMs: Double
    let delta: CGFloat
    let durationMs: Int
    let delayMs: Double

    var animatableData: Double {
        get { elapsedMs }
        set { elapsedMs = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(
            translationX: 0,
            y: LyricHandover.shift(delta: delta, elapsedMs: elapsedMs, durationMs: durationMs, delayMs: delayMs)
        ))
    }
}

// MARK: - Rows

/// Dips under a finger the way a button does, and scales about the edge the line is written from.
private struct LyricRowButtonStyle: ButtonStyle {
    let active: Bool
    let alignEnd: Bool
    let systemReduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(LyricRowStyle.scale(pressed: configuration.isPressed, active: active), anchor: alignEnd ? .trailing : .leading)
            .animation(LyricMotion.easing(milliseconds: configuration.isPressed ? 120 : 400, reduceMotion: systemReduceMotion), value: configuration.isPressed)
            .animation(LyricMotion.easing(milliseconds: 400, reduceMotion: systemReduceMotion), value: active)
    }
}

/// The long press that starts a pick, or folds the line under the finger into one. Off where the
/// platform has no card to put the lines on, so a press that did nothing is never the only sign.
private struct LyricPickGesture: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        content.highPriorityGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in action() },
            including: enabled ? .all : .none
        )
    }
}

/// One line of the song: the lead, its translation or romanization, and the answering vocal
/// under it. They are one row — they scale and dim together, and tapping any of them seeks.
private struct LyricRow: View {
    let line: LyricLine
    let sub: LyricLine?
    let active: Bool
    let sung: Bool
    let synced: Bool
    let alignEnd: Bool
    let duet: Bool
    let browsing: Bool
    let alpha: Double
    let blur: CGFloat
    let glowing: Bool
    let rises: Bool
    /// Either Reduce setting: the sub-lyric reveal is switched off.
    let reduceMotion: Bool
    /// iOS's own: movement gives way to a short ease.
    let systemReduceMotion: Bool
    let clock: LyricFrameClock
    let particleTrigger: Int
    /// A pick is open: a tap chooses the line rather than seeking to it.
    let picking: Bool
    /// This line is one of the chosen ones, and says so on its own row.
    let picked: Bool
    /// Whether a long press can start a pick here at all.
    let canPick: Bool
    let onTap: () -> Void
    let onPick: () -> Void
    let onToggle: () -> Void

    var body: some View {
        let room = LyricsPanelMetrics.glowRoom
        let lead = synced ? LyricTypeface.synced : LyricTypeface.plain
        Button {
            if picking { onToggle() } else { onTap() }
        } label: {
            VStack(alignment: alignEnd ? .trailing : .leading, spacing: 0) {
                voice(line, typeface: lead, room: room, glow: active && glowing && !browsing ? LyricRowStyle.glowAlpha : 0)
                if let sub, sub.text.lyricDiffers(from: line.text) {
                    voice(sub, typeface: .sub, room: 0, glow: 0, particles: particleTrigger)
                        .padding(.horizontal, room)
                        .padding(.bottom, room)
                        .offset(y: -LyricsPanelMetrics.subTuck)
                        .opacity(LyricRowStyle.subAlpha)
                        .transition(subTransition)
                }
                if let backing = line.background {
                    voice(backing.withoutBracketPunctuation(), typeface: .backing, room: 0, glow: 0)
                        .padding(.horizontal, room)
                        .padding(.bottom, room)
                        .opacity(LyricRowStyle.backingAlpha)
                    if let subBacking = sub?.background, subBacking.text.lyricDiffers(from: backing.text) {
                        voice(subBacking.withoutBracketPunctuation(), typeface: .subBacking, room: 0, glow: 0)
                            .padding(.horizontal, room)
                            .padding(.bottom, room)
                            .offset(y: -LyricsPanelMetrics.subTuck)
                            .opacity(LyricRowStyle.backingAlpha * LyricRowStyle.subAlpha)
                            .transition(subTransition)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: alignEnd ? .trailing : .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(LyricRowButtonStyle(active: active, alignEnd: alignEnd, systemReduceMotion: systemReduceMotion))
        // The chosen lines are marked on the row itself rather than with a mark beside it: a lane
        // down the side would have to be reserved for every line whether or not anybody was picking,
        // and this panel is words from edge to edge. Everything else dims a little instead, so what
        // is picked is read against what isn't.
        .background(rowFill, in: RoundedRectangle(cornerRadius: 10))
        // Long-press is the way in: a list of words gives no sign that pressing one does anything
        // beyond seeking. Where a card cannot be made there is nothing to pick, and a long press that
        // did nothing would be the only sign of it — so the gesture is off there.
        .disabled(!synced && !picking)
        // Outside `.disabled`: plain (untimed) lyrics have no seek, but their lines are still picked.
        .modifier(LyricPickGesture(enabled: canPick, action: onPick))
        // The lane the other voice sings in, kept clear.
        .padding(.leading, duet && alignEnd ? LyricsPanelMetrics.duetLane : 0)
        .padding(.trailing, duet && !alignEnd ? LyricsPanelMetrics.duetLane : 0)
        .opacity(alpha)
        .blur(radius: blur)
        .animation(LyricMotion.easing(milliseconds: 400, reduceMotion: systemReduceMotion), value: alpha)
        .animation(LyricMotion.easing(milliseconds: 400, reduceMotion: systemReduceMotion), value: blur)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("lyrics.line")
        .accessibilityAddTraits(synced ? .isButton : .isStaticText)
        .accessibilityAddTraits(active ? .isSelected : [])
        // A chosen line is announced as chosen. The trait is taken by the line being sung, so the
        // pick says it in the value instead of sharing a word with playback.
        .accessibilityValue(picked ? L10n.selected : "")
    }

    private var rowFill: Color {
        if picked { return .white.opacity(0.16) }
        if picking { return .white.opacity(0.05) }
        return .clear
    }

    private var subTransition: AnyTransition {
        reduceMotion ? .identity : .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -12)),
            removal: .opacity.animation(.easeOut(duration: 0.26))
        )
    }

    private var accessibilityText: String {
        [line.text, sub.map(\.text), line.background?.withoutBracketPunctuation().text]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// Word-synced voices sweep; the rest light whole the moment they start, and hold back until
    /// then so a line-synced source agrees with a word-synced one about what "not yet" looks like.
    private func voice(_ voice: LyricLine, typeface: LyricTypeface, room: CGFloat, glow: CGFloat, particles: Int = 0) -> some View {
        let sweeps = voice.isWordSynced
        let dim = sweeps
            ? LyricRowStyle.tailAlpha(sung: sung)
            : LyricRowStyle.litAlpha(synced: synced, sung: sung, active: active)
        return ScaledLyricVoice(
            line: voice,
            style: LyricVoiceStyle(typeface: typeface, alignEnd: alignEnd, room: room, sweeps: sweeps, rises: rises, feather: active),
            dimAlpha: dim,
            glowAlpha: glow,
            clock: clock,
            particleTrigger: particles
        )
    }
}

/// ``LyricVoice`` at the reader's Dynamic Type size.
private struct ScaledLyricVoice: View {
    let line: LyricLine
    let style: LyricVoiceStyle
    let dimAlpha: Double
    let glowAlpha: CGFloat
    let clock: LyricFrameClock
    let particleTrigger: Int

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        var scaled = style
        scaled.typeface = style.typeface.scaled(for: UIContentSizeCategory(dynamicTypeSize))
        return LyricVoice(line: line, style: scaled, dimAlpha: dimAlpha, glowAlpha: glowAlpha, clock: clock,
                          particleTrigger: particleTrigger)
    }
}

/// A break between verses, counted out rather than marked: three dots lighting in turn across the
/// interlude. The row opens as the page moves onto it and closes as the page moves off it, so the
/// list carries no hole through the verses either side.
///
/// Android opens it on its own stamp and closes it on the next line's, each after the page has
/// moved. Here it rides the page's move instead, a run-up earlier (see `LyricsList.follow`).
private struct LyricGapRow: View {
    let line: LyricLine
    let until: Int
    /// Whether the row stands open; animated by the transaction that changes it.
    let open: Bool
    let active: Bool
    let alpha: Double
    let blur: CGFloat
    let clock: LyricFrameClock
    let systemReduceMotion: Bool
    /// A pick is open: a stray tap in the silence must not jump the song.
    let picking: Bool
    /// Whether the source stamps its lines at all. A gap is nothing to pick, so it only ever seeks.
    let canSeek: Bool
    let onTap: () -> Void

    var body: some View {
        let swell: CGFloat = open ? 1 : 0
        let metrics = LyricsPanelMetrics.self
        Button(action: onTap) {
            TimelineView(.animation(paused: !active)) { _ in
                let span = max(until - line.timeMs, 1)
                let through = min(max(Double(clock.positionMs - line.timeMs) / Double(span), 0), 1)
                HStack(spacing: metrics.gapDotGap) {
                    ForEach(0..<3, id: \.self) { dot in
                        let lit = min(max(through * 3 - Double(dot), 0), 1)
                        Circle()
                            .fill(.white.opacity(metrics.gapDotRest + (1 - metrics.gapDotRest) * lit))
                            .frame(width: metrics.gapDotSize, height: metrics.gapDotSize)
                    }
                }
            }
            .padding(metrics.glowRoom)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!canSeek || picking)
        // Only the brightness rides the row's own clock. The size and fade of opening are
        // `openGap`'s transaction's: a second curve on them fought it when `open` and `active`
        // flipped together (first placement, a seek).
        .animation(LyricMotion.easing(milliseconds: active ? 400 : 350, reduceMotion: systemReduceMotion)) { row in
            row.opacity(alpha).blur(radius: blur)
        }
        .scaleEffect(metrics.gapRestScale + (1 - metrics.gapRestScale) * swell, anchor: .leading)
        .opacity(swell)
        .frame(height: (metrics.gapRowHeight + metrics.gapRowSpacing) * swell, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .accessibilityLabel(L10n.instrumental)
        // Open, not active: the row is laid out a run-up before the break starts.
        .accessibilityHidden(!open)
    }
}

/// A "[Chorus]"-style heading in plain (Genius) lyrics, drawn as a small chip.
private struct LyricSectionHeader: View {
    let text: String
    let first: Bool

    var body: some View {
        let title = text.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).trimmingCharacters(in: .whitespaces)
        Text(title.uppercased())
            .font(.system(size: 11.5, weight: .bold))
            .tracking(1.3)
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, LyricsPanelMetrics.glowRoom)
            .padding(.top, first ? 6 : 24)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Stands in for the lyrics while the lookup is out: the shape of the page they will fill, a
/// band of light crossing the whole column.
private struct LyricsSkeleton: View {
    /// One entry per line of the song, one fraction per row it wraps to.
    private static let blocks: [[CGFloat]] = [
        [0.97, 0.54],
        [0.92, 0.99, 0.41],
        [0.68],
        [0.95, 0.73],
        [0.89, 0.96, 0.37],
    ]
    private static let period: TimeInterval = 1.4

    var body: some View {
        GeometryReader { geometry in
            let column = geometry.size.width
            TimelineView(.animation) { timeline in
                let sweep = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
                VStack(alignment: .leading, spacing: 35) {
                    ForEach(Self.blocks.indices, id: \.self) { block in
                        VStack(alignment: .leading, spacing: 15) {
                            ForEach(Self.blocks[block].indices, id: \.self) { row in
                                bar(width: column * Self.blocks[block][row], column: column, sweep: sweep)
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, LyricsPanelMetrics.topPadding)
        // The page has more bars than a short panel has room for. They stay inside the panel,
        // fading out at its foot the way the lines do, rather than running on over the
        // scrubber, the transport and the volume row below it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .mask {
            VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: LyricsPanelMetrics.edgeFade)
            }
        }
    }

    /// Every bar sweeps against the column's width rather than its own, so one band crosses the page.
    private func bar(width: CGFloat, column: CGFloat, sweep: Double) -> some View {
        let band = column * 0.45
        let startX = -band + CGFloat(sweep) * (column + band * 2)
        return RoundedRectangle(cornerRadius: 4)
            .fill(.white.opacity(0.10))
            .overlay(alignment: .leading) {
                LinearGradient(colors: [.white.opacity(0.10), .white.opacity(0.26), .white.opacity(0.10)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: band)
                    .offset(x: startX)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .frame(width: width, height: 26)
    }
}

// MARK: - Translate and romanize

/// The romanize disc at the foot's leading corner and the translate disc at its trailing one,
/// floated over the lyrics rather than laid out under them so they cost the page no line. They
/// ride on the player's controls: away when the controls are.
private struct LyricsTranslationDiscs: View {
    let translation: LyricsTranslationController
    let hasLyrics: Bool
    let shown: Bool

    var body: some View {
        HStack {
            LyricsTranslationDisc(
                kind: .romanize,
                state: translation.romanizationState,
                showing: translation.showingRomanization,
                enabled: shown && hasLyrics
            ) { toggle(translation.romanizationState) { translation.toggleRomanization() } }
            Spacer()
            LyricsTranslationDisc(
                kind: .translate,
                state: translation.translationState,
                showing: translation.showingTranslation,
                enabled: shown && hasLyrics
            ) { toggle(translation.translationState) { translation.toggleTranslation() } }
        }
        .opacity(shown ? 1 : 0)
        .animation(.easeOut(duration: shown ? 0.22 : 0.16), value: shown)
        .allowsHitTesting(shown)
        .onChange(of: readyCount) { old, new in
            if new > old { Haptics.shared.play(.toggleOn) }
        }
    }

    /// How many versions have come back, so arriving at one plays the "on" haptic.
    private var readyCount: Int {
        [translation.translationState, translation.romanizationState].filter {
            if case .ready = $0 { return true }
            return false
        }.count
    }

    private func toggle(_ state: LyricsTranslationController.State, _ action: () -> Void) {
        if case .ready = state { Haptics.shared.play(.select) } else if state != .loading { Haptics.shared.play(.tap) }
        action()
    }
}

/// One disc, sized and lit like every other in the player; a request in flight takes the icon's
/// place.
struct LyricsTranslationDisc: View {
    enum Kind {
        case translate
        case romanize

        var symbol: String { self == .translate ? "translate" : "globe" }
    }

    let kind: Kind
    let state: LyricsTranslationController.State
    let showing: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        let loading = state == .loading
        let active = showing || loading
        let tint: Double = (!enabled || state == .sameLanguage) ? 0.42 : (active ? 1 : 0.78)
        Button(action: action) {
            ZStack {
                Circle().fill(.white.opacity(active ? 0.34 : 0.18))
                if loading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(tint))
                } else {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(tint))
                }
            }
            .frame(width: 34, height: 34)
            .animation(.easeOut(duration: 0.2), value: active)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(kind == .translate ? "lyrics.translate" : "lyrics.romanize")
    }

    private var label: String {
        if showing { return L10n.showOriginalLyrics }
        return kind == .translate ? L10n.translateLyrics : L10n.romanizeLyrics
    }
}
