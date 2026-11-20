import VibraMusicCore
import Canvas
import Foundation
import Lyrics
import Observation
import Playback
import PlaybackPolicy
import SwiftUI
import Theming

/// Which sheet is up over the player. Presented from the player itself: the app's sheets are
/// attached under the full-screen player and can't show over it, so one the app asks for while the
/// player is up (the song menu's "Add to playlist" and "Lyrics offset") is shown here as `.app`.
enum NowPlayingSheet: Identifiable, Hashable {
    case output, pipeline, songActions, lyricsProvider, lyricsShare
    case app(AppSheet)

    var id: String {
        switch self {
        case .output: return "output"
        case .pipeline: return "pipeline"
        case .songActions: return "songActions"
        case .lyricsProvider: return "lyricsProvider"
        case .lyricsShare: return "lyricsShare"
        case .app(let sheet): return "app.\(sheet.id)"
        }
    }

    /// The player's own sheets by name (`-nowPlayingSheet`).
    init?(name: String) {
        switch name {
        case "output": self = .output
        case "pipeline": self = .pipeline
        case "songActions": self = .songActions
        case "lyricsProvider": self = .lyricsProvider
        case "lyricsShare": self = .lyricsShare
        default: return nil
        }
    }
}

/// The open player's state, owned by ``NowPlayingScreen`` and shared by both its layouts, so
/// rotating mid-song carries the open panel, the scrub and the sheets straight across.
@MainActor
@Observable
final class NowPlayingModel {
    var panes: PlayerPaneState {
        didSet {
            if panes.pane != oldValue.pane { persistPane?(panes.pane.lastPlayerScreen) }
        }
    }
    let scrub = PlayerScrub()
    let canvas = PlayerCanvasModel()
    let artwork = PlayerArtworkLoader()
    /// The full-bleed banner's sticky bit, per track. ``PlayerHeroState``.
    var hero = PlayerHeroState()
    let mesh: ArtworkMeshModel
    let legacyPalette: MeshPaletteModel
    let tint: ArtworkTintModel

    var sheet: NowPlayingSheet?
    /// The lyrics for the playing track: read by the strip over the scrubber and, through the
    /// environment, by the lyrics panel and the provider sheet — one lookup for all three. Not the
    /// player's own: the app's (``CurrentTrackLyrics``), which looked the track up when it started
    /// and outlives the player, so closing and reopening it doesn't look the lyrics up again.
    var lyrics: LyricsSession { currentLyrics?.session ?? unattached }
    private var currentLyrics: CurrentTrackLyrics?
    /// Stands in until the app's is attached (previews, tests that host a part on its own).
    @ObservationIgnored private let unattached = LyricsSession()
    var party = PlayerPartyBadge()
    var outputs: [AudioRouting.Device] = []
    /// Until when the menu glyph shows the undo arrow after a quality upgrade.
    var revertCueUntil: Date?
    /// How far the finger has dragged the artwork sideways (undamped).
    var swipeTranslation: CGFloat = 0
    /// How far the artwork has been pulled up towards the queue, 0…1.
    var queuePull: CGFloat = 0
    /// A finger is on the volume bar. With the scrubber's, the one touch the deck's idle wait
    /// never runs out under.
    var volumeDragging = false

    @ObservationIgnored var persistPane: ((LastPlayerScreen) -> Void)?
    @ObservationIgnored private var lastEntry: String?
    @ObservationIgnored private var lastStream: ResolvedStream?

    init(restoring screen: LastPlayerScreen = .main, lyrics: CurrentTrackLyrics? = nil, palettes: ArtworkPaletteCache = .shared) {
        panes = PlayerPaneState(restoring: screen)
        currentLyrics = lyrics
        mesh = ArtworkMeshModel(cache: palettes)
        legacyPalette = MeshPaletteModel(cache: palettes)
        tint = ArtworkTintModel(cache: palettes)
        #if DEBUG
        applyDebugLaunchArguments()
        #endif
    }

    /// Reads the app's lyrics for the playing track.
    func attachLyrics(_ current: CurrentTrackLyrics) {
        guard currentLyrics !== current else { return }
        currentLyrics = current
    }

    /// How long the deck stands under the lyrics untouched before going (Android's
    /// `LYRICS_CONTROLS_IDLE_MS`).
    nonisolated static let lyricsControlsIdle: Duration = .seconds(5)

    /// What the lyrics panel hears from the portrait player: whether the deck is up, and how to put
    /// it away or bring it back. Each change runs on the deck's own 420 ms curve, so the lyrics
    /// take the freed height as the deck goes.
    var lyricsPanelChrome: LyricsPanelChrome {
        LyricsPanelChrome(
            controlsOpen: panes.lyricsControlsOpen,
            onRevealControls: { [weak self] in self?.setLyricsControls(open: true) },
            onHideControls: { [weak self] in self?.setLyricsControls(open: false) }
        )
    }

    func setLyricsControls(open: Bool) {
        guard panes.lyricsOpen, panes.lyricsControlsOpen != open else { return }
        // VoiceOver reaches none of the ways back (a scroll's travel, the lower-half tap), so under
        // it the deck stays where the transport can be reached, however the hide was asked for.
        guard open || !UIAccessibility.isVoiceOverRunning else { return }
        withAnimation(NowPlayingMotion.collapse) { panes.lyricsControlsOpen = open }
    }

    /// Present when you arrive, out of the way once you are reading: left alone for
    /// ``lyricsControlsIdle`` the deck stands down and gives the words the screen. Run by the
    /// portrait player as a task keyed on everything it reads, so bringing the deck back, or
    /// letting go of the scrubber or the volume, starts the wait over. Never while either is held:
    /// they are used while nothing else on screen moves, and timing out under them would take the
    /// control away mid-gesture.
    func hideLyricsControlsWhenIdle(after idle: Duration = lyricsControlsIdle) async {
        guard lyricsControlsCanIdle else { return }
        try? await Task.sleep(for: idle)
        guard !Task.isCancelled, lyricsControlsCanIdle else { return }
        setLyricsControls(open: false)
    }

    /// Everything ``hideLyricsControlsWhenIdle(after:)`` waits on, for the task's key.
    var lyricsControlsIdleKey: [Bool] {
        [panes.lyricsOpen, panes.lyricsControlsOpen, scrub.scrubbing, volumeDragging]
    }

    private var lyricsControlsCanIdle: Bool {
        panes.lyricsOpen && panes.lyricsControlsOpen && !scrub.scrubbing && !volumeDragging
    }

    var showsRevertCue: Bool {
        guard let revertCueUntil else { return false }
        return revertCueUntil > Date()
    }

    /// Fed with every change of the playing entry's stream: a quality upgrade lights the revert
    /// cue for ``PlayerRevertCue/duration``.
    func streamDidChange(_ stream: ResolvedStream?, entry: String?) {
        defer {
            lastEntry = entry
            if stream != nil { lastStream = stream }
        }
        let sameEntry = entry != nil && entry == lastEntry
        if !sameEntry { lastStream = nil }
        guard PlayerRevertCue.isUpgrade(from: lastStream, to: stream, sameEntry: sameEntry) else { return }
        let until = Date().addingTimeInterval(PlayerRevertCue.duration)
        revertCueUntil = until
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(PlayerRevertCue.duration))
            if self?.revertCueUntil == until { self?.revertCueUntil = nil }
        }
    }

    /// A new track: the swipe, the scrub and the revert cue belonged to the last one, and the
    /// banner starts over.
    func trackDidChange() {
        scrub.trackDidChange()
        swipeTranslation = 0
        revertCueUntil = nil
        hero.trackDidChange()
    }

    #if DEBUG
    /// `-nowPlayingPane lyrics|queue` and `-nowPlayingSheet output|pipeline` open the player on a
    /// given surface, for screenshots and manual checks.
    private func applyDebugLaunchArguments() {
        let arguments = UserDefaults.standard
        if let pane = arguments.string(forKey: "nowPlayingPane") {
            switch pane {
            case "lyrics": panes.openLyrics()
            case "queue": panes.openQueue()
            default: panes.showMain()
            }
        }
        if let sheet = arguments.string(forKey: "nowPlayingSheet") {
            self.sheet = NowPlayingSheet(name: sheet)
        }
    }
    #endif
}
