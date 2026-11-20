import VibraMusicCore
import Foundation
import Integrations
import Playback
import Replay
import StreamResolution
import UIKit
import WidgetKit

// What PlaybackService.kt did alongside playing: scrobbling, Discord presence, the Replay listening
// record, YouTube Music history pings and the widget. Each one listens to PlayerController.

/// Last.fm and ListenBrainz: "now playing", then a scrobble once enough of the track has played
/// (ScrobbleTracker's timing rules).
@MainActor
final class ScrobblingObserver: PlaybackEventObserver {
    private let settings: AppSettings
    private let lastFM: LastFMClient
    private let listenBrainz: ListenBrainzClient
    private let tracker: ScrobbleTracker
    private var startedAtMs: Int64 = 0
    private var pendingStart: (song: Song, durationMs: Int64)?

    init(settings: AppSettings, session: URLSession = VibraMusicHTTP.session) {
        self.settings = settings
        let lastFM = LastFMClient(configuration: LastFMConfiguration.resolved(settings: settings), session: session)
        let listenBrainz = ListenBrainzClient(session: session)
        self.lastFM = lastFM
        self.listenBrainz = listenBrainz
        // The submitters read the switches at the moment they fire, so turning scrobbling off takes
        // effect on the track already playing.
        let gate = ScrobbleGate(settings: settings)
        tracker = ScrobbleTracker(
            configuration: Self.configuration(settings),
            nowPlaying: { event in
                let state = await gate.snapshot()
                if state.lastFMNowPlaying {
                    try? await lastFM.updateNowPlaying(artist: event.artist, track: event.title, album: event.album, durationSeconds: event.durationSeconds)
                }
            },
            scrobble: { event in
                let state = await gate.snapshot()
                if state.lastFMScrobble {
                    try? await lastFM.scrobble(artist: event.artist, track: event.title, timestamp: event.timestamp,
                                               album: event.album, durationSeconds: event.durationSeconds)
                }
            }
        )
    }

    private static func configuration(_ settings: AppSettings) -> ScrobbleTracker.Configuration {
        ScrobbleTracker.Configuration(
            minDurationSeconds: settings.scrobbleMinDuration,
            delayPercent: Double(settings.scrobbleDelayPercent),
            maxDelaySeconds: settings.scrobbleDelaySeconds,
            useNowPlaying: settings.lastfmNowPlaying,
            usePrimaryArtistOnly: settings.lastfmPrimaryArtistOnly
        )
    }

    private var anyEnabled: Bool {
        (settings.lastfmEnabled && !settings.lastfmSessionKey.isEmpty) || (settings.listenBrainzEnabled && !settings.listenBrainzToken.isEmpty)
    }

    func playback(didStart song: Song, durationMs: Int64, isPlaying: Bool, previous: Song?, previousListened: Bool, previousPositionMs: Int64) {
        let tracker = self.tracker
        let configuration = Self.configuration(settings)
        // A finished listen only when the track was listened to the end (an advance, a repeat, a
        // crossfade at its end): a skip is not a listen (Android `if (prevSong != null && ended …)`).
        if let previous, previousListened, anyEnabled, settings.listenBrainzEnabled {
            submitListenBrainzFinished(previous, endMs: previousPositionMs)
        }
        pendingStart = nil
        guard anyEnabled else { return }
        startedAtMs = Int64(Date().timeIntervalSince1970 * 1_000)
        Task { await tracker.updateConfiguration(configuration) }
        let lastFM = self.lastFM
        let resolved = LastFMConfiguration.resolved(settings: settings)
        Task { await lastFM.updateConfiguration(resolved) }
        if isPlaying {
            Task { await tracker.noteStarted(song: song, durationMs: durationMs > 0 ? durationMs : nil) }
            submitListenBrainzPlayingNow(song)
        } else {
            pendingStart = (song, durationMs)
        }
    }

    func playback(didChangePlaying isPlaying: Bool, song: Song, positionMs: Int64, durationMs: Int64) {
        guard anyEnabled else { return }
        let tracker = self.tracker
        if isPlaying, let pending = pendingStart, pending.song.videoId == song.videoId {
            pendingStart = nil
            // The listen starts when it's heard, not when the row was restored paused (Android
            // stamps listenBrainzStartMs on the first play too).
            startedAtMs = Int64(Date().timeIntervalSince1970 * 1_000)
            Task { await tracker.noteStarted(song: song, durationMs: durationMs > 0 ? durationMs : nil) }
            submitListenBrainzPlayingNow(song)
            return
        }
        Task { await tracker.notePlayingChanged(isPlaying: isPlaying, song: song, durationMs: durationMs > 0 ? durationMs : nil) }
    }

    func playbackDidStop() {
        let tracker = self.tracker
        Task { await tracker.noteStopped() }
    }

    private func submitListenBrainzPlayingNow(_ song: Song) {
        guard settings.listenBrainzEnabled, !settings.listenBrainzToken.isEmpty else { return }
        let token = settings.listenBrainzToken
        let primary = settings.listenBrainzPrimaryArtistOnly
        let client = listenBrainz
        Task { await client.submitPlayingNow(token: token, song: song, positionMs: 0, primaryArtistOnly: primary) }
    }

    private func submitListenBrainzFinished(_ song: Song, endMs: Int64) {
        guard !settings.listenBrainzToken.isEmpty else { return }
        let token = settings.listenBrainzToken
        let primary = settings.listenBrainzPrimaryArtistOnly
        let client = listenBrainz
        let start = startedAtMs
        let end = start + max(endMs, 0)
        Task { await client.submitFinished(token: token, song: song, startMs: start, endMs: end, primaryArtistOnly: primary) }
    }
}

/// The scrobbling switches, read on the main actor from the submitters' background closures.
private final class ScrobbleGate: Sendable {
    struct State: Sendable {
        var lastFMNowPlaying: Bool
        var lastFMScrobble: Bool
    }

    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func snapshot() async -> State {
        await MainActor.run {
            let signedIn = settings.lastfmEnabled && !settings.lastfmSessionKey.isEmpty
            return State(lastFMNowPlaying: signedIn && settings.lastfmNowPlaying,
                         lastFMScrobble: signedIn && settings.lastfmScrobbleEnabled)
        }
    }
}

/// Discord Rich Presence while playing (only while audio keeps the app alive: iOS suspends the
/// gateway socket otherwise, PORTING.md §4).
@MainActor
final class DiscordPresenceObserver: PlaybackEventObserver {
    private let settings: AppSettings
    private var client: DiscordPresenceClient?
    private var clientToken: String?
    private let speed: () -> Float
    /// What the decoder measured for a track, once it has; nil while the figures on hand would be
    /// another track's (Android's `NerdStats.current`).
    private let stats: (Song) -> PlaybackStats?

    init(settings: AppSettings, speed: @escaping () -> Float, stats: @escaping (Song) -> PlaybackStats?) {
        self.settings = settings
        self.speed = speed
        self.stats = stats
    }

    private func activeClient() -> DiscordPresenceClient? {
        guard settings.discordRpcEnabled, !settings.discordToken.isEmpty else {
            if let client {
                Task { await client.clear(); await client.close() }
                self.client = nil
                clientToken = nil
            }
            return nil
        }
        if client == nil || clientToken != settings.discordToken {
            client = DiscordPresenceClient(token: settings.discordToken)
            clientToken = settings.discordToken
        }
        return client
    }

    /// The sleeve's hover line: a premium format, when "Show audio quality" is on (Android
    /// `discordAudioQualityLine(NerdStats.current.value)` behind the same switch).
    private func qualityLine(for song: Song) -> String? {
        DiscordCard.audioQualityLine(stats(song), enabled: settings.discordShowAudioQuality)
    }

    private func options(for song: Song) -> DiscordPresenceOptions {
        DiscordPresenceOptions(
            useDetails: settings.discordUseDetails,
            status: settings.discordStatus,
            button1Text: settings.discordButton1Text,
            button1Visible: settings.discordButton1Visible,
            button2Text: settings.discordButton2Text,
            button2Visible: settings.discordButton2Visible,
            activityType: settings.discordActivityType,
            activityName: settings.discordActivityName,
            audioQuality: qualityLine(for: song)
        )
    }

    /// The track (under which token) the card was last set for, so a progress tick can tell that
    /// Discord was switched on, or signed into, mid-song and publish then rather than at the next
    /// track change.
    private var publishedKey: String?
    /// The quality line that card carried, so a stats sample arriving after the track started (or
    /// the switch being flipped) can send it again — but only when the line actually differs, since
    /// Discord rate-limits presence updates (Android re-pushes on a changed line alone).
    private var publishedLine: String?

    private func publish(_ song: Song, positionMs: Int64, durationMs: Int64, isPlaying: Bool) {
        guard let client = activeClient() else {
            publishedKey = nil
            publishedLine = nil
            return
        }
        let options = self.options(for: song)
        publishedKey = isPlaying ? "\(clientToken ?? "")\u{1F}\(song.videoId)" : nil
        publishedLine = isPlaying ? options.audioQuality : nil
        let rate = Double(speed())
        Task {
            if isPlaying {
                await client.updateSong(song, currentPositionMs: positionMs, durationMs: durationMs, playbackSpeed: rate, options: options)
            } else {
                await client.clear()
            }
        }
    }

    func playback(didStart song: Song, durationMs: Int64, isPlaying: Bool, previous: Song?, previousListened: Bool, previousPositionMs: Int64) {
        publish(song, positionMs: 0, durationMs: durationMs, isPlaying: isPlaying)
    }

    func playback(didChangePlaying isPlaying: Bool, song: Song, positionMs: Int64, durationMs: Int64) {
        publish(song, positionMs: positionMs, durationMs: durationMs, isPlaying: isPlaying)
    }

    func playback(progress song: Song, positionMs: Int64, durationMs: Int64, isPlaying: Bool) {
        // Cheap on every tick: only a card that isn't up for this track under this token, or whose
        // quality line has changed since it went out, is sent.
        guard isPlaying, settings.discordRpcEnabled, !settings.discordToken.isEmpty,
              publishedKey != "\(settings.discordToken)\u{1F}\(song.videoId)"
                || publishedLine != qualityLine(for: song) else { return }
        publish(song, positionMs: positionMs, durationMs: durationMs, isPlaying: true)
    }

    func playbackDidStop() {
        publishedKey = nil
        publishedLine = nil
        guard let client else { return }
        Task { await client.clear() }
    }
}

/// The device's own listening record behind Replay.
@MainActor
final class ReplayObserver: PlaybackEventObserver {
    private let recorder: ReplayListeningRecorder
    private let enrichment: ReplayEnrichment

    init(recorder: ReplayListeningRecorder, enrichment: ReplayEnrichment) {
        self.recorder = recorder
        self.enrichment = enrichment
    }

    /// One tick, with whatever the lookups have found about the track, and the artists it
    /// queued looked up in the background.
    private func sample(_ song: Song, durationMs: Int64) {
        recorder.onSample(enrichment.enriched(song), durationMs: durationMs)
        enrichment.drainArtistsIfNeeded()
    }

    func playback(didStart song: Song, durationMs: Int64, isPlaying: Bool, previous: Song?, previousListened: Bool, previousPositionMs: Int64) {
        // Anchors the new track; the next sample starts counting it.
        if isPlaying { sample(song, durationMs: durationMs) } else { recorder.onStopped() }
    }

    func playback(progress song: Song, positionMs: Int64, durationMs: Int64, isPlaying: Bool) {
        if isPlaying { sample(song, durationMs: durationMs) }
    }

    func playback(didChangePlaying isPlaying: Bool, song: Song, positionMs: Int64, durationMs: Int64) {
        if isPlaying { sample(song, durationMs: durationMs) } else { recorder.onStopped() }
    }

    func playbackDidStop() { recorder.onStopped() }
}

/// Registers plays with YouTube Music so they show up in the account's history (Android's
/// PlaybackTracker). The tracker does nothing while signed out.
@MainActor
final class YouTubeHistoryObserver: PlaybackEventObserver {
    private let tracker: PlaybackHistoryTracker
    private var current: String?
    private var lastPositionSeconds = 0

    init(tracker: PlaybackHistoryTracker) {
        self.tracker = tracker
    }

    private static func isCatalogue(_ song: Song) -> Bool {
        YouTubeVideoIdShape.isValid(song.videoId) && song.localUri == nil
    }

    func playback(didStart song: Song, durationMs: Int64, isPlaying: Bool, previous: Song?, previousListened: Bool, previousPositionMs: Int64) {
        let tracker = self.tracker
        let seconds = Int(previousPositionMs / 1_000)
        let hadPrevious = current != nil
        current = Self.isCatalogue(song) ? song.videoId : nil
        lastPositionSeconds = 0
        let videoId = current
        Task {
            if hadPrevious {
                if previousListened {
                    await tracker.onPlaybackFinished(positionSeconds: seconds)
                } else {
                    await tracker.onTrackChanged(positionSeconds: seconds)
                }
            }
            if isPlaying, let videoId { await tracker.onPlaying(videoId) }
        }
    }

    func playback(didChangePlaying isPlaying: Bool, song: Song, positionMs: Int64, durationMs: Int64) {
        guard isPlaying, let videoId = current, videoId == song.videoId else { return }
        let tracker = self.tracker
        Task { await tracker.onPlaying(videoId) }
    }

    func playback(progress song: Song, positionMs: Int64, durationMs: Int64, isPlaying: Bool) {
        guard let videoId = current, videoId == song.videoId else { return }
        lastPositionSeconds = Int(positionMs / 1_000)
        guard isPlaying else { return }
        let tracker = self.tracker
        let seconds = lastPositionSeconds
        Task { await tracker.onProgress(videoId: videoId, positionSeconds: seconds) }
    }

    /// The queue was cleared: no transition will close the last play out (Android's `onDestroy`).
    func playbackDidStop() {
        guard current != nil else { return }
        current = nil
        let tracker = self.tracker
        let seconds = lastPositionSeconds
        Task { await tracker.onPlaybackFinished(positionSeconds: seconds) }
    }
}

/// YouTube's 11-character video id shape, so device files and source tracks are never pinged.
enum YouTubeVideoIdShape {
    static func isValid(_ id: String) -> Bool {
        id.count == 11 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
}

/// Writes ``NowPlayingSnapshot`` for the widget and asks WidgetKit to redraw.
@MainActor
final class WidgetSnapshotObserver: PlaybackEventObserver {
    private weak var player: PlayerController?
    private let defaults: UserDefaults?
    private let reloadsWidgets: Bool
    private var lastArtworkURL: String?
    private(set) var lastWritten: NowPlayingSnapshot?
    private var queueShapeTracker: ChangeTracker?

    init(player: PlayerController, defaults: UserDefaults? = NowPlayingSnapshot.sharedDefaults, reloadsWidgets: Bool = true) {
        self.player = player
        self.defaults = defaults
        self.reloadsWidgets = reloadsWidgets
        // Shuffle, repeat and the ends of the queue change the widget's face (the 4x1's Shuffle,
        // which buttons are dimmed) but aren't playback events, so they are watched here.
        queueShapeTracker = ChangeTracker.track({ [weak player] in QueueShape(player) }, initial: false) { [weak self] _ in
            guard let self, self.player?.currentSong != nil else { return }
            self.write()
        }
    }

    /// The parts of the queue the widget draws besides the song.
    private struct QueueShape: Equatable {
        var shuffle = false
        var repeatMode = ""
        var hasNext = false
        var hasPrevious = false

        @MainActor
        init(_ player: PlayerController?) {
            guard let player else { return }
            shuffle = player.shuffleEnabled
            repeatMode = "\(player.repeatMode)"
            hasNext = player.hasNext
            hasPrevious = player.hasPrevious
        }
    }

    /// The snapshot for what `player` is doing now; nil with nothing current.
    static func snapshot(of player: PlayerController, playing: Bool? = nil, now: Date = Date()) -> NowPlayingSnapshot? {
        guard let song = player.currentSong else { return nil }
        let repeatMode: String = switch player.repeatMode {
        case .off: "OFF"
        case .all: "ALL"
        case .one: "ONE"
        }
        return NowPlayingSnapshot(
            videoId: song.videoId,
            title: song.title,
            artist: song.artist,
            albumName: song.albumName,
            artworkURL: song.artworkAt(ArtworkSize.card),
            artworkFileName: nil,
            isPlaying: playing ?? player.playWhenReady,
            isLiked: player.likeStatus(of: song) == .like,
            shuffleEnabled: player.shuffleEnabled,
            repeatMode: repeatMode,
            hasNext: player.hasNext,
            hasPrevious: player.hasPrevious,
            positionMs: Int64(player.position * 1_000),
            durationMs: Int64(player.duration * 1_000),
            updatedAt: now
        )
    }

    func write(playing: Bool? = nil) {
        guard let player else { return }
        guard var snapshot = Self.snapshot(of: player, playing: playing) else {
            NowPlayingSnapshot.clear(from: defaults)
            lastWritten = nil
            reload()
            return
        }
        if snapshot.artworkURL == lastArtworkURL, let previous = lastWritten?.artworkFileName {
            snapshot.artworkFileName = previous
        } else {
            saveArtwork(snapshot.artworkURL)
        }
        snapshot.save(to: defaults)
        let changedVisibly = lastWritten.map { !$0.sameFace(as: snapshot) } ?? true
        lastWritten = snapshot
        if changedVisibly { reload() }
    }

    private func reload() {
        guard reloadsWidgets else { return }
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Copies the cover into the App Group, then writes the snapshot again pointing at it.
    private func saveArtwork(_ raw: String?) {
        lastArtworkURL = raw
        guard let raw, let url = URL(string: raw), let container = NowPlayingSnapshot.containerURL else { return }
        Task { [weak self] in
            guard let image = await ArtworkImageCache.shared.image(for: url),
                  let data = image.jpegData(compressionQuality: 0.85) else { return }
            // Checked before the file is touched: after a quick skip an older cover can arrive
            // after the newer one, and must not overwrite the single shared file under it.
            guard let self, self.lastArtworkURL == raw, var snapshot = self.lastWritten else { return }
            let file = container.appending(path: NowPlayingSnapshot.artworkFileName)
            guard (try? data.write(to: file, options: .atomic)) != nil else { return }
            snapshot.artworkFileName = NowPlayingSnapshot.artworkFileName
            snapshot.save(to: self.defaults)
            self.lastWritten = snapshot
            self.reload()
        }
    }

    func playback(didStart song: Song, durationMs: Int64, isPlaying: Bool, previous: Song?, previousListened: Bool, previousPositionMs: Int64) {
        write(playing: isPlaying)
    }

    func playback(didChangePlaying isPlaying: Bool, song: Song, positionMs: Int64, durationMs: Int64) {
        write(playing: isPlaying)
    }

    func playback(progress song: Song, positionMs: Int64, durationMs: Int64, isPlaying: Bool) {
        // Position only: saved for extrapolation, but not worth a widget reload.
        guard let player, var snapshot = Self.snapshot(of: player, playing: isPlaying) else { return }
        snapshot.artworkFileName = lastWritten?.artworkFileName
        snapshot.save(to: defaults)
        lastWritten = snapshot
    }

    func playback(didChangeLike status: LikeStatus, song: Song) {
        write()
    }

    func playbackDidStop() {
        write()
    }
}

private extension NowPlayingSnapshot {
    /// Whether two snapshots draw the same widget (position aside).
    func sameFace(as other: NowPlayingSnapshot) -> Bool {
        videoId == other.videoId && isPlaying == other.isPlaying && isLiked == other.isLiked
            && artworkFileName == other.artworkFileName && shuffleEnabled == other.shuffleEnabled
            && repeatMode == other.repeatMode && hasNext == other.hasNext && hasPrevious == other.hasPrevious
    }
}
