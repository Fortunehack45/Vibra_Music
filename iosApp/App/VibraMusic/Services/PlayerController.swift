import AudioCache
import AudioDSP
import VibraMusicCore
import Foundation
import Observation
import Playback
import PlaybackPolicy
import PlaybackQueue

// Ports playback/PlayerConnection.kt (the UI's view of the player) and the controller glue
// PlaybackService.kt and MainActivity.kt spread between them: the queue model (PlaybackQueue)
// drives the engine (Playback), the engine reports back, and everything the UI shows about
// playback is read from here.

/// Where the player is, for the mini player's spinner and the audio pipeline readout.
enum PipelineStatus: Hashable {
    /// Nothing loaded.
    case idle
    /// Waiting for a stream URL (the source race, YouTube's client walk).
    case resolving
    /// Stream in hand, waiting on bytes.
    case buffering
    case playing
    case paused
    /// The queue ran out; play starts the last track over.
    case ended
    /// The current track could not be played.
    case failed(String)
}

/// A one-line confirmation or refusal after a queue action (Android's QueueActionNotice).
struct QueueNotice: Identifiable, Hashable {
    let id = UUID()
    var message: String
    var symbol: String?
}

/// Told about playback as it happens: scrobbling, Discord, Replay, YouTube history, the widget.
@MainActor
protocol PlaybackEventObserver: AnyObject {
    /// `song` became the current track. `previous` finished (`listened`) or was skipped.
    func playback(didStart song: Song, durationMs: Int64, isPlaying: Bool, previous: Song?, previousListened: Bool, previousPositionMs: Int64)
    func playback(didChangePlaying isPlaying: Bool, song: Song, positionMs: Int64, durationMs: Int64)
    /// Every checkpoint while playing (about every five seconds) and on pause/seek.
    func playback(progress song: Song, positionMs: Int64, durationMs: Int64, isPlaying: Bool)
    /// Playback stopped with nothing current (the queue was cleared).
    func playbackDidStop()
    /// The current track's like status changed.
    func playback(didChangeLike status: LikeStatus, song: Song)
}

extension PlaybackEventObserver {
    func playback(didStart song: Song, durationMs: Int64, isPlaying: Bool, previous: Song?, previousListened: Bool, previousPositionMs: Int64) {}
    func playback(didChangePlaying isPlaying: Bool, song: Song, positionMs: Int64, durationMs: Int64) {}
    func playback(progress song: Song, positionMs: Int64, durationMs: Int64, isPlaying: Bool) {}
    func playbackDidStop() {}
    func playback(didChangeLike status: LikeStatus, song: Song) {}
}

/// The app's one player API.
///
/// Binds ``PlaybackQueueController`` (what plays, in which order) to ``AudioPlayerEngine`` (how
/// it sounds): a queue change loads the named entry into the engine; the engine asks the queue
/// what follows for its gapless preload and crossfade, and reports when it moved on by itself so
/// the queue follows. Streams are resolved lazily through ``PlaybackSourceFactory`` under the
/// per-network ceiling and served through the audio cache; the DSP chain sits in the engine's tap.
@MainActor
@Observable
final class PlayerController {
    // MARK: Collaborators

    @ObservationIgnored let engine: AudioPlayerEngine
    @ObservationIgnored let queue: PlaybackQueueController
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let sources: PlaybackSourceFactory
    @ObservationIgnored let likeState: LikeState
    @ObservationIgnored let processors: [AudioDSPProcessor]
    /// Sends a rating to YouTube Music; nil keeps likes on the device (signed out, tests).
    @ObservationIgnored var rate: (@Sendable (String, LikeStatus) async throws -> Void)?
    /// Finds the song ↔ music video counterpart of a track (InnerTube's resolveAudio/resolveVideo).
    @ObservationIgnored var versionFinder: (@MainActor (Song) async -> Song?)?
    /// Measures the offset between two versions (Automix's VersionAudioAligner), in ms.
    @ObservationIgnored var versionAligner: (@MainActor (Song, Song) async -> Int64?)?
    /// Whether a Listen Together party member put the current track on, for "Played by".
    @ObservationIgnored var playedBy: (@MainActor (Song) -> String?)?
    /// The second look for a better copy of a track that started below what was asked for
    /// (PlaybackPolicy's QualityUpgrade). Nil: no upgrades (tests that don't ask for them).
    @ObservationIgnored var qualityUpgrades: QualityUpgradeController? {
        didSet { qualityUpgrades?.player = self }
    }
    /// Automix's planner, for its analysis readout (``automixPair``).
    @ObservationIgnored weak var automix: AutomixTransitionPlanner?
    /// Listen Together's say over play and pause (``ListenTogetherSession``): true means the party
    /// handled the press (a locked listener's own pause, or a play held for the party's start).
    @ObservationIgnored var partyTransport: (@MainActor (_ playing: Bool) async -> Bool)?
    /// Tells Listen Together the listener moved the playhead, so the party follows.
    @ObservationIgnored var partySeekIntent: (@MainActor () -> Void)?
    @ObservationIgnored private var observers: [ObjectIdentifier: PlaybackEventObserver] = [:]
    @ObservationIgnored private var trackers: [ChangeTracker] = []

    // MARK: Observable state

    /// The resolved stream behind the current track: its source and declared format (stats for
    /// nerds), loudness. Nil until the stream resolves, and for files on the device.
    private(set) var currentStream: ResolvedStream?
    /// The latest queue action's notice, for the toast above the mini player.
    var notice: QueueNotice?
    /// A version swap (song ↔ video, revert, upgrade) is under way.
    private(set) var isSwappingVersion = false
    /// How far the last song ↔ music video switch got lining the two cuts up (fetching,
    /// measuring, aligned with its offset, failed), for stats for nerds. Scoped to its pair: a
    /// view should ignore a status whose ids don't name the playing track.
    var versionAlignment: VersionAlignmentStatus?
    /// In a Listen Together party: transitions stay off (every device must change track at the
    /// same moment) and Automix measures nothing.
    var isInParty = false {
        didSet { updateTransitionSuspension() }
    }

    /// Set while the queue follows a move the engine already made, so the queue's report of it
    /// isn't loaded into the engine a second time.
    @ObservationIgnored private var followingEngine = false
    @ObservationIgnored private var lastStartedSong: Song?
    /// The last checkpointed position of each item, in ms. The engine resets its own `position`
    /// before announcing a track it had to open itself (nothing preloaded, or a skip), so the
    /// track that just ended is read from here.
    @ObservationIgnored private var lastCheckpointMs: [String: Int64] = [:]
    /// The item whose first checkpoint is still to come: the engine takes it before it has moved
    /// its position onto the new item, so on a preloaded advance it carries the track before's end.
    @ObservationIgnored private var awaitingFirstCheckpoint: String?
    @ObservationIgnored private var lastReportedPlaying = false
    @ObservationIgnored private var reopenCount = 0
    @ObservationIgnored private var holdingTransitionsForSwap = false
    /// A video the listener deliberately switched back to from its audio version: the music-only
    /// preference must leave it alone until the playing song changes (Android's `keepVideoId`).
    @ObservationIgnored private var keepVideoId: String?
    /// The last cache read-ahead update this player asked for. Cache updates are chained through
    /// this so a stop's cancellation can never overtake the plan a queue set right after it.
    @ObservationIgnored private var readAheadJob: Task<Void, Never>?
    /// How long after a track starts the partial add-on copies behind it are dropped (Android's
    /// `FOREIGN_CACHE_PURGE_DELAY_MS`): long enough for a crossfade to be done with the outgoing
    /// track, and for a run of skips to come to rest.
    @ObservationIgnored var addonCachePurgeDelay: Duration = .seconds(30)
    @ObservationIgnored private var addonCachePurge: Task<Void, Never>?
    /// Streams that resolved for a queue row *before* it became the current track, keyed by engine
    /// item id. The engine preloads the next item for a gapless or crossfaded advance, so its stream
    /// resolves while the previous song still plays; holding it here lets ``trackStarted(_:reason:)``
    /// apply it the moment the row is reached, exactly as a live resolution would. Bounded to a
    /// handful, and pruned to the rows still queued.
    @ObservationIgnored private var heldStreams: [String: ResolvedStream] = [:]
    /// The order ids were first held in, so the bound drops the oldest first.
    @ObservationIgnored private var heldStreamOrder: [String] = []
    /// Where the engine's last failure left the playhead, by engine item id: a fallback to YouTube
    /// picks up there.
    @ObservationIgnored private var failedAt: (itemID: String, position: TimeInterval)?
    /// How many resolved-but-not-yet-current streams to keep. Two decks preload at most a couple of
    /// items; a handful covers a rapid skip through the queue.
    private static let heldStreamLimit = 8

    init(
        engine: AudioPlayerEngine,
        queue: PlaybackQueueController,
        settings: AppSettings,
        sources: PlaybackSourceFactory,
        likeState: LikeState,
        processors: [AudioDSPProcessor] = []
    ) {
        self.engine = engine
        self.queue = queue
        self.settings = settings
        self.sources = sources
        self.likeState = likeState
        self.processors = processors
        queue.queueLabel = L10n.queue
        queue.onCurrentItemChange = { [weak self] change in self?.queueDidChangeItem(change) }
        engine.delegate = self
        engine.sourceRecovery = { [weak self, sources] item, reason in
            if let self, await self.fellBackToYouTube(item, reason: reason) { return nil }
            return await sources.recoveredSource(for: item, reason: reason)
        }
        sources.onResolved = { [weak self] itemID, stream in self?.streamResolved(itemID: itemID, stream: stream) }
        sources.onOpenedFromDisk = { [weak self] itemID in self?.openedFromDisk(itemID: itemID) }
        sources.onLoudness = { [weak self] videoId in
            guard let self else { return }
            for processor in self.processors { processor.loudnessArrived(forTrack: videoId) }
            // A lossless copy that began with no figure plays with no tap: this gives it one.
            self.engine.audioProcessingDidChange()
        }
        bindSettings()
        bindQueue()
        bindMusicOnlyConversion()
    }

    // MARK: - What the UI reads

    var queueState: PlaybackQueueState { queue.state }
    var currentSong: Song? { queue.currentSong }
    var currentIndex: Int { queue.state.currentIndex }
    var songs: [Song] { queue.state.songs }
    var hasNext: Bool { queue.state.hasNext }
    var hasPrevious: Bool { queue.state.hasPrevious }
    var isPlaying: Bool { engine.isPlaying }
    /// What the play/pause button shows: true while buffering towards play.
    var playWhenReady: Bool { engine.playWhenReady }
    var isBuffering: Bool { engine.isBuffering }
    /// Seconds into the current track. Read it only where a scrubber is drawn: it changes four
    /// times a second.
    var position: TimeInterval { engine.position }
    /// The decoder's length once known, else the catalogue's; 0 when unknown.
    var duration: TimeInterval {
        if engine.duration > 0 { return engine.duration }
        return TimeInterval(currentSong?.durationMillis ?? 0) / 1_000
    }
    var shuffleEnabled: Bool { queue.state.shuffleEnabled }
    var repeatMode: RepeatMode { queue.state.repeatMode }
    var isAutoplayEnabled: Bool { queue.isAutoplayEnabled }
    /// A Listen Together host holds the controls.
    var controlsLocked: Bool { queue.controlsLocked }
    var sections: QueueSections { QueueSections(queue: queue.state.songs, currentIndex: queue.state.currentIndex, showHistory: settings.showQueueHistory) }

    /// The caption above the artwork: "Played by …", "Playing … Radio", "Playing from …".
    var playingFrom: PlaybackOrigin? {
        guard let song = currentSong else { return nil }
        return PlaybackOrigin.of(song, playedBy: playedBy?(song), queueLabel: queue.queueLabel)
    }

    /// Where tapping "Playing from" goes back to.
    var playingFromSource: QueueSource? { queue.playingFrom }

    /// The source's own claim about the stream (codec, bitrate, sample rate).
    var streamFormat: StreamFormat? { currentStream?.format }
    /// Who supplied the copy playing when nothing resolved for it: YouTube, for its own copy whole
    /// off the disk. A source's copy on disk doesn't record which source it came from.
    var sourceOnDisk: String? {
        guard let song = currentSong, sources.playingFromCache(for: song.videoId),
              sources.playingCacheKey(for: song.videoId) == .youtube(videoId: song.videoId) else { return nil }
        return "YouTube"
    }
    /// What the decoder and access log measured (stats for nerds).
    var stats: PlaybackStats? { engine.stats }
    /// How the audio reaches the output: through the DSP tap, bit-transparent, or passed through
    /// for spatial rendering.
    var signalPath: PlaybackSignalPath? { engine.signalPath }
    var sleepTimer: SleepTimerState? { engine.sleepTimer }
    var speed: Float { engine.rate }
    var isTransitioning: Bool { engine.isTransitioning }
    /// Where Automix's analysis of the playing pair stands (analysing / analysed / failed…) and
    /// what the planner decided, for stats for nerds. Nil until Automix is first asked.
    var automixPair: AutomixPairStatus? {
        guard let pair = automix?.pairStatus, pair.currentId == currentSong?.videoId else { return nil }
        return pair
    }
    /// The Automix window on the scrubber (fractions of the track), once both sides are measured.
    var transitionWindow: TransitionWindow? { engine.transitionWindow }
    /// The playing track's quality upgrade, for the Now Playing badge ("Upgrading quality"). Nil
    /// when nothing is being or was upgraded for it.
    var qualityUpgrade: QualityUpgradeStatus? {
        guard let status = qualityUpgrades?.status, status.videoId == currentSong?.videoId else { return nil }
        return status
    }
    var isSmartMixInProgress: Bool { engine.isSmartMixInProgress }

    var pipelineStatus: PipelineStatus {
        guard currentSong != nil, engine.currentItem != nil else { return .idle }
        if let error = engine.lastError, !engine.isPlaying, engine.lastError?.itemID == engine.currentItem?.id {
            return .failed(error.message)
        }
        if engine.hasEnded { return .ended }
        if engine.isPlaying { return .playing }
        if engine.isBuffering { return currentStream == nil && !isLocalItem ? .resolving : .buffering }
        return .paused
    }

    private var isLocalItem: Bool {
        guard let song = currentSong else { return false }
        return PlaybackSourceFactory.localFileURL(of: song) != nil || sources.savedFile(song) != nil
    }

    /// The like status of `song` (the current track by default), as this device last knew it.
    func likeStatus(of song: Song? = nil) -> LikeStatus {
        guard let song = song ?? currentSong else { return .indifferent }
        return likeState.status(for: song.videoId) ?? .indifferent
    }

    // MARK: - Starting playback

    /// Plays `songs` (an album, playlist, artist's songs, history…) from `startAt`, with the rest of
    /// the list around it as context. `source` names where it was started, for "Playing from".
    @discardableResult
    func play(_ songs: [Song], startAt index: Int = 0, source: QueueSource? = nil) -> QueueEditResult {
        let result: QueueEditResult
        if let source {
            result = queue.playFrom(songs, index: index, source: source)
        } else {
            result = queue.play(songs, index: index)
        }
        announce(result)
        return result
    }

    /// A song picked on its own (a search hit, a home card, a shared link): it plays, the user's
    /// queue follows, and AutoPlay carries on from it.
    @discardableResult
    func playSong(_ song: Song, source: QueueSource) -> QueueEditResult {
        let result = queue.playSong(song, source: source)
        announce(result)
        return result
    }

    /// The Shuffle button on an album or playlist page: the list plays shuffled, from a random track.
    @discardableResult
    func shufflePlay(_ songs: [Song], source: QueueSource? = nil) -> QueueEditResult {
        guard !songs.isEmpty else { return .ignored }
        queue.enableShuffleForNextQueue()
        return play(songs, startAt: Int.random(in: songs.indices), source: source)
    }

    /// "Start radio": replaces the queue with YouTube Music's radio for `song`.
    @discardableResult
    func startRadio(from song: Song) async -> RadioStartResult {
        let result = await queue.startRadio(from: song)
        switch result {
        case .started(let name): notice = QueueNotice(message: L10n.radioStarted(name), symbol: AppSymbol.radio)
        case .failed: notice = QueueNotice(message: L10n.couldntLoadTracks, symbol: AppSymbol.error)
        case .refusedByHost: notice = QueueNotice(message: L10n.listenTogetherHostOnlyNotice, symbol: nil)
        case .superseded, .unavailable: break
        }
        return result
    }

    // MARK: - Queue edits

    @discardableResult
    func playNext(_ songs: [Song]) -> QueueEditResult {
        let result = songs.count == 1 ? queue.playNext(songs[0]) : queue.queueSongs(songs, next: true)
        announce(result, next: true)
        return result
    }

    @discardableResult
    func addToQueue(_ songs: [Song]) -> QueueEditResult {
        let result = songs.count == 1 ? queue.addToQueue(songs[0]) : queue.queueSongs(songs, next: false)
        announce(result, next: false)
        return result
    }

    /// A swipe on a song row: play next or add to queue, per the swipe setting.
    @discardableResult
    func queueFromSwipe(_ song: Song) -> QueueEditResult {
        let result = queue.queueFromSwipe(song)
        announce(result, next: settings.swipeToPlayNext)
        return result
    }

    @discardableResult
    func jump(to index: Int) -> QueueEditResult { refusalNotice(queue.jump(to: index)) }

    @discardableResult
    func move(from: Int, to: Int) -> QueueEditResult { refusalNotice(queue.moveInQueue(from: from, to: to)) }

    @discardableResult
    func remove(at index: Int) -> QueueEditResult { refusalNotice(queue.removeFromQueue(at: index)) }

    @discardableResult
    func clearQueue() -> QueueEditResult { refusalNotice(queue.clearUserQueue()) }

    // MARK: - Transport

    func togglePlayPause() {
        if engine.playWhenReady { pause() } else { play() }
    }

    func play() {
        guard currentSong != nil else { return }
        if let partyTransport, isInParty {
            Task { @MainActor [weak self] in
                guard await partyTransport(true) == false else { return }
                self?.playNow()
            }
            return
        }
        playNow()
    }

    private func playNow() {
        guard currentSong != nil else { return }
        if engine.currentItem == nil, let song = currentSong {
            // Restored or failed before it ever opened: load it now.
            engine.load(sources.item(for: song), startingAt: 0, playWhenReady: true)
            return
        }
        if engine.hasEnded {
            // Replaying a queue that ran out goes through the queue, or a late AutoPlay batch
            // would start over the replay (PlaybackQueue report, known gaps).
            followingEngine = true
            queue.seek(toItem: queue.state.currentIndex)
            followingEngine = false
            engine.seek(to: 0)
        }
        engine.play()
    }

    func pause() {
        musicOnlyHold = nil
        if let partyTransport, isInParty {
            // A listener in a locked party pauses their own device only; anyone else's pause is
            // published to the party.
            Task { @MainActor [weak self] in
                guard await partyTransport(false) == false else { return }
                self?.engine.pause()
            }
            return
        }
        engine.pause()
    }

    /// Next. Returns false when there is nowhere to go or a party host holds the controls.
    @discardableResult
    func next() -> Bool {
        refusalNotice(queue.skipToNext()) == .done
    }

    /// Previous: back a track within the first 10 s, otherwise to the start of this one.
    @discardableResult
    func previous() -> Bool {
        refusalNotice(queue.skipToPrevious(positionMs: Int64(engine.position * 1_000))) == .done
    }

    func seek(to seconds: TimeInterval) {
        guard !controlsLocked else {
            notice = QueueNotice(message: L10n.listenTogetherHostOnlyNotice, symbol: nil)
            return
        }
        engine.seek(to: seconds)
        // Here rather than in the checkpoint handler, which drops zeros: a seek to the start is real. The engine's
        // position is the clamped target.
        if let song = currentSong { lastCheckpointMs[Self.itemID(for: song)] = Int64(engine.position * 1_000) }
        queue.recordPlayhead(positionMs: Int64(seconds * 1_000), isPlaying: engine.isPlaying)
        if isInParty { partySeekIntent?() }
    }

    func toggleShuffle() { queue.toggleShuffle() }
    func cycleRepeatMode() { queue.cycleRepeatMode() }
    func setRepeatMode(_ mode: RepeatMode) { queue.setRepeatMode(mode) }
    func toggleAutoplay() { queue.toggleAutoplay() }

    /// Playback speed, 0.5×–2×, pitch kept. Persisted.
    func setSpeed(_ speed: Float) {
        settings.playbackSpeed = min(max(speed, AudioPlayerEngine.speedRange.lowerBound), AudioPlayerEngine.speedRange.upperBound)
    }

    // MARK: - Sleep timer

    func startSleepTimer(minutes: Int) {
        queue.sleepTimer?.cancel()
        engine.startSleepTimer(.minutes(minutes))
    }

    /// "End of this track". The queue's timer is armed too, so a track that ends the queue isn't
    /// followed by an AutoPlay batch arriving late (PlaybackQueue's `trackDidFinish`).
    func startSleepTimerAfterTrack() {
        queue.sleepTimer?.startAfterTrack()
        engine.startSleepTimer(.endOfTrack)
    }

    func cancelSleepTimer() {
        queue.sleepTimer?.cancel()
        engine.cancelSleepTimer()
    }

    /// Seconds left on a minutes timer; nil for none or "end of this track". Read on a timeline.
    var sleepTimerRemaining: TimeInterval? { engine.sleepTimerRemaining }

    // MARK: - Likes

    /// The heart. Returns the new status.
    @discardableResult
    func toggleLike(_ song: Song? = nil) -> LikeStatus {
        guard let song = song ?? currentSong else { return .indifferent }
        let next: LikeStatus = likeStatus(of: song) == .like ? .indifferent : .like
        setLike(next, for: song)
        return next
    }

    /// Thumbs down. Disliking the song that is playing skips it (DislikeSkipPolicy).
    @discardableResult
    func toggleDislike(_ song: Song? = nil) -> LikeStatus {
        guard let song = song ?? currentSong else { return .indifferent }
        let previous = likeStatus(of: song)
        let next: LikeStatus = previous == .dislike ? .indifferent : .dislike
        setLike(next, for: song)
        queue.dislikeToggled(previousStatus: previous, videoId: song.videoId)
        return next
    }

    private func setLike(_ status: LikeStatus, for song: Song) {
        likeState.set(status, for: song.videoId)
        if song.videoId == currentSong?.videoId {
            engine.setFeedback(status)
            observers.values.forEach { $0.playback(didChangeLike: status, song: song) }
        }
        guard let rate else { return }
        let videoId = song.videoId
        Task {
            do {
                try await rate(videoId, status)
            } catch {
                DebugLog.w("Player", "rating \(videoId) failed", error: error)
            }
        }
    }

    // MARK: - Versions

    /// Reverts the playing track to YouTube's own upload (pinned until "Upgrade quality").
    func revertToOriginal() {
        guard let song = currentSong, OriginalVersion.shared.revert(song) != nil else { return }
        qualityUpgrades?.forget(song)
        // A new identity, so the engine opens YouTube's copy rather than reusing the asset it has.
        sources.setRendition("original", stream: nil, for: song)
        reopenCurrent()
    }

    /// "Upgrade quality": lifts a revert pin and looks again for a better copy while the track
    /// plays on (Android's `upgradeQualityNow`), throttled to one request per 30 s. Without the
    /// upgrade controller, or when nothing outranks YouTube, the track is reopened instead.
    func upgradeQuality() {
        guard let song = currentSong else { return }
        if let qualityUpgrades {
            switch qualityUpgrades.requestByHand(for: song, playing: currentStream) {
            case .searching, .alreadyRunning, .coolingDown:
                // Android ignores a press inside the cooldown silently (the log says why).
                return
            case .nothingToSearch:
                break
            }
        }
        OriginalVersion.shared.unpin(song.videoId)
        reopenCount += 1
        sources.setRendition("reopen-\(reopenCount)", stream: nil, for: song)
        reopenCurrent()
    }

    /// The music-only preference's automatic conversion (MainActivity's
    /// `LaunchedEffect(player.song?.videoId, preferMusicOnly)` → `switchToMusicOnly`): the video
    /// starts so the player fills at once, and its catalogue audio version is resolved behind the
    /// loading indicators as soon as the playing song or the preference changes.
    private func bindMusicOnlyConversion() {
        trackers.append(ChangeTracker.track({ [weak self] in self?.musicOnlyKey ?? "" }, initial: false) { [weak self] _ in
            self?.maybeConvertToMusicOnly()
        })
        // A video that arrives by crossfade or Automix becomes the playing song at the hand-over,
        // with the mix still running, and the swap is refused until it ends: nothing else would ask
        // again, so the mix ending does.
        trackers.append(ChangeTracker.track({ [weak self] in self?.engine.isTransitioning ?? false }, initial: false) { [weak self] transitioning in
            guard !transitioning, let self, self.musicOnlyWaitingForMix else { return }
            self.musicOnlyWaitingForMix = false
            self.maybeConvertToMusicOnly()
        })
    }

    /// What Android's LaunchedEffect is keyed on: the playing song's videoId and the setting.
    private var musicOnlyKey: String { "\(currentSong?.videoId ?? "")|\(settings.preferMusicOnly)" }

    /// An automatic conversion was refused because a transition was under way; it runs again when
    /// the transition ends.
    @ObservationIgnored private var musicOnlyWaitingForMix = false

    /// An automatic conversion was refused because another switch was still under way; it runs
    /// again when that one ends.
    @ObservationIgnored private var musicOnlyWaitingForSwap = false

    /// The row an automatic conversion paused while it looks the other cut up, over a listener who
    /// was playing. That pause is the lookup's, not theirs: a skip off the row meanwhile carries
    /// their playing on to the next one (see ``queueDidChangeItem(_:)``), and a pause they press
    /// meanwhile drops it so nothing resumes over them.
    @ObservationIgnored private var musicOnlyHold: Song?

    /// Version lookups by video id, in flight or answered: the music-only preference looks the next
    /// videos' audio versions up while the current track plays, so their switch needs no search.
    @ObservationIgnored private var versionLookups: [String: Task<Song?, Never>] = [:]
    @ObservationIgnored private var versionLookupOrder: [String] = []
    /// How many videos ahead the music-only preference converts: a quick skip through two or three
    /// still lands on songs the engine could preload.
    private static let musicOnlyLookahead = 3
    /// An automatic conversion this close to the start of a track starts the song from its top, so
    /// the two cuts aren't measured (seconds of fetching and decoding for nothing heard yet).
    private static let musicOnlyFromTheTopSeconds: TimeInterval = 3

    private func otherVersion(of song: Song) async -> Song? {
        guard let versionFinder else { return nil }
        if let running = versionLookups[song.videoId] { return await running.value }
        let task = Task { await versionFinder(song) }
        versionLookups[song.videoId] = task
        versionLookupOrder.append(song.videoId)
        if versionLookupOrder.count > 32 { versionLookups[versionLookupOrder.removeFirst()] = nil }
        let found = await task.value
        // A miss may be a network blip: asked again next time, not remembered.
        if found == nil { versionLookups[song.videoId] = nil }
        return found
    }

    /// Music-only, ahead of time: the next queued videos are swapped for their audio versions while
    /// this track plays, so the engine preloads the songs themselves and an advance (or a quick
    /// skip) starts as fast as any other track — not the video, a pause, a search and a switch.
    private func convertUpcomingToMusicOnly() {
        guard settings.preferMusicOnly, !isInParty else { return }
        let state = queue.state
        guard state.currentIndex + 1 < state.songs.count else { return }
        let ahead = (state.currentIndex + 1)..<min(state.currentIndex + 1 + Self.musicOnlyLookahead, state.songs.count)
        for index in ahead {
            let video = state.songs[index]
            guard video.isVideo else { continue }
            Task { [weak self] in
                guard let self, let audio = await self.otherVersion(of: video), audio.videoId != video.videoId, !audio.isVideo else { return }
                let now = self.queue.state
                guard self.settings.preferMusicOnly, !self.isInParty, now.songs.indices.contains(index), index != now.currentIndex,
                      now.songs[index].queueEntryId == video.queueEntryId, now.songs[index].videoId == video.videoId else { return }
                self.queue.replaceItems(in: index..<(index + 1), with: [Self.inQueueSlot(of: video, audio)])
            }
        }
    }

    /// `replacement` dressed in `row`'s queue identity: same entry, tier and play source.
    private static func inQueueSlot(of row: Song, _ replacement: Song) -> Song {
        var swapped = replacement
        swapped.queueEntryId = row.queueEntryId
        swapped.queueTier = row.queueTier
        swapped.playbackSource = row.playbackSource
        swapped.playbackSourceType = row.playbackSourceType
        swapped.playbackSourceId = row.playbackSourceId
        swapped.radioName = row.radioName
        return swapped
    }

    private func maybeConvertToMusicOnly() {
        convertUpcomingToMusicOnly()
        // A video the listener switched back to stays theirs until the song changes
        // (MainActivity's `if (keepVideoId != player.song?.videoId) keepVideoId = null`).
        if let kept = keepVideoId, kept != currentSong?.videoId { keepVideoId = nil }
        guard settings.preferMusicOnly, let song = currentSong, song.isVideo, song.videoId != keepVideoId else { return }
        Task { await switchVersion(automatic: true) }
    }

    /// Switches the playing track between its song and its music video, keeping the listener's
    /// place (the aligner's offset between the two when smart alignment is on).
    ///
    /// Ignored in a Listen Together party (every member plays the same cut; Android hides the
    /// toggle there and refuses the command from anything that still sends it) and while a
    /// transition is under way (the swap would tear the standby deck away from the mix).
    ///
    /// `automatic` is the music-only preference's own conversion (Android's
    /// `switchToMusicOnly(song, pauseWhileResolving = true)`): playback is held while the other
    /// cut is resolved and lined up and resumed for whatever the lookup leaves playing, and a
    /// failed or identical match keeps this cut silently — on Android a miss just leaves the
    /// video playing rather than reporting it.
    func switchVersion(automatic: Bool = false) async {
        guard let song = currentSong, versionFinder != nil else { return }
        guard !isSwappingVersion else {
            // A skip onto a second video while the first one's lookup runs: converted once that
            // lookup ends, or nothing would ever ask again.
            if automatic { musicOnlyWaitingForSwap = true }
            return
        }
        guard !isInParty else {
            DebugLog.d("Player", "version swap ignored: in a Listen Together party")
            return
        }
        guard !engine.isTransitioning else {
            DebugLog.d("Player", "version swap deferred: a transition is under way")
            if automatic { musicOnlyWaitingForMix = true }
            return
        }
        // Android's pauseWhileResolving: the automatic preference holds playback through the
        // lookup; a manual switch lets the current cut keep playing meanwhile.
        if automatic {
            if engine.playWhenReady { musicOnlyHold = song }
            engine.pause()
        }
        let fromTheTop = automatic && engine.position < Self.musicOnlyFromTheTopSeconds
        isSwappingVersion = true
        defer {
            isSwappingVersion = false
            musicOnlyHold = nil
            if musicOnlyWaitingForSwap {
                musicOnlyWaitingForSwap = false
                // Whatever is playing now, if it is still a video the preference converts.
                maybeConvertToMusicOnly()
            }
        }
        let found = await otherVersion(of: song)
        // The queue moved on while the other cut was looked up: nothing to switch, and nothing
        // failed either, so no "Couldn't find" for a track that is no longer playing.
        guard currentSong?.queueEntryId == song.queueEntryId, currentSong?.videoId == song.videoId else { return }
        guard let other = found, other.videoId != song.videoId else {
            if automatic {
                DebugLog.w("Player", "music-only switch found no distinct song")
                if musicOnlyHold != nil { play() }
            } else {
                notice = QueueNotice(message: L10n.couldntFind(song.title), symbol: AppSymbol.error)
            }
            return
        }
        var offsetMs: Int64 = 0
        if !fromTheTop, settings.smartVersionAlignment, let versionAligner {
            // No transition may start while the two cuts are being measured: the swap owns the
            // standby deck from here (Android's `versionSwapActive`).
            holdingTransitionsForSwap = true
            updateTransitionSuspension()
            // Nil is "could not be measured": the switch still happens, with no shift, rather
            // than refusing to move (Android's prepareVersionAlignment).
            offsetMs = await versionAligner(song, other) ?? 0
            holdingTransitionsForSwap = false
            updateTransitionSuspension()
        }
        let stillCurrent = currentSong?.queueEntryId == song.queueEntryId && currentSong?.videoId == song.videoId
        guard stillCurrent, !isInParty, !engine.isTransitioning else {
            if automatic, stillCurrent, engine.isTransitioning { musicOnlyWaitingForMix = true }
            // A listener who moved on took playback with them; the same track left held resumes.
            if stillCurrent, musicOnlyHold != nil { play() }
            return
        }
        // A manual switch back onto a video: the music-only preference leaves it alone until the
        // song changes (Android's `keepVideoId = original.videoId`).
        if !song.isVideo, other.isVideo { keepVideoId = other.videoId }
        // The playhead as it is now, not as it was before the measurement: the track played on.
        let positionMs = fromTheTop ? 0 : Self.alignedPosition(sourceMs: Int64(engine.position * 1_000), offsetMs: offsetMs,
                                                               targetDurationMs: Int64(other.durationMillis))
        swapCurrent(to: other, atMs: positionMs)
        if musicOnlyHold != nil { play() }
    }

    /// Where the other version picks up: the aligner's offset applied, never before the start
    /// and, when the other cut's length is known, not past its last second.
    nonisolated static func alignedPosition(sourceMs: Int64, offsetMs: Int64, targetDurationMs: Int64 = 0) -> Int64 {
        let aligned = VersionAlignmentStatus.targetPositionMs(sourcePositionMs: sourceMs, offsetMs: offsetMs)
        guard targetDurationMs > 1_000 else { return aligned }
        return min(aligned, targetDurationMs - 1_000)
    }

    /// Replaces the playing entry with `replacement` (same queue slot) and continues from `atMs`.
    func swapCurrent(to replacement: Song, atMs positionMs: Int64) {
        guard let current = currentSong else { return }
        let swapped = Self.inQueueSlot(of: current, replacement)
        let index = queue.state.currentIndex
        qualityUpgrades?.forget(current)
        sources.clearRendition(for: current)
        // Same entry id: the queue keeps it playing and reports no change, so the engine is loaded
        // here, at the aligned position.
        queue.replaceItems(in: index..<(index + 1), with: [swapped])
        currentStream = nil
        engine.load(sources.item(for: swapped), startingAt: TimeInterval(positionMs) / 1_000, playWhenReady: nil)
    }

    /// Puts the playing row onto another copy of the same recording at the current position: a
    /// quality upgrade's `stream` under `tag`, or (nil tag) back onto its ordinary copy.
    func reopenCurrent(onRendition tag: String?, stream: ResolvedStream?) {
        guard let song = currentSong else { return }
        if let tag {
            sources.setRendition(tag, stream: stream, for: song)
        } else {
            sources.clearRendition(for: song)
        }
        reopenCurrent()
    }

    private func updateTransitionSuspension() {
        engine.transitionsSuspended = isInParty || holdingTransitionsForSwap
    }

    /// Same row, same timeline, another copy: crossed over without a gap while it plays (see
    /// ``AudioPlayerEngine/replaceCurrent(with:)``), reopened in place while it's paused.
    private func reopenCurrent() {
        guard let song = currentSong else { return }
        currentStream = nil
        engine.replaceCurrent(with: sources.item(for: song))
    }

    /// A copy above YouTube (a substitute, an upgrade) that died mid-play is not retried: the row
    /// carries on from YouTube's own upload at the same place, after the engine's usual stutter
    /// (Android's `fallbackFailedAlternativeToYouTube`). The track is refused substitutes and
    /// upgrades for a while, so neither the retry nor the second look lands on the dead copy again,
    /// and the switch is a new engine item, so it doesn't spend the retries YouTube's copy may need.
    /// False leaves the failure to the ordinary retry.
    private func fellBackToYouTube(_ item: PlayableItem, reason: RecoveryReason) async -> Bool {
        guard case .retry = reason, let song = currentSong, sources.engineItemID(for: song) == item.id,
              sources.diedAboveYouTube(item) else { return false }
        let position = failedAt.flatMap { $0.itemID == item.id ? $0.position : nil } ?? engine.position
        DebugLog.w("Player", "'\(song.title)' failed on a higher-quality source; falling back to YouTube audio")
        qualityUpgrades?.forget(song)
        qualityUpgrades?.upgrade.refuseUpgrades(song.videoId)
        sources.fallBackToYouTube(song)
        // The same cache discard a retry makes, before the reopen.
        _ = await sources.recoveredSource(for: item, reason: reason)
        // A skip meanwhile took the engine elsewhere: the refusal stands, nothing is reopened.
        guard engine.currentItem?.id == item.id else { return true }
        currentStream = nil
        engine.load(sources.item(for: song), startingAt: position, playWhenReady: nil)
        return true
    }

    // MARK: - Lifecycle

    /// Puts last session's queue back, paused where it was (called once at launch).
    @discardableResult
    func restore() -> Bool {
        queue.restore()
    }

    /// Writes the restart snapshot now. Call when the app leaves the foreground: iOS can kill a
    /// suspended app with an asynchronous write still queued.
    func flushPersistence() {
        queue.flushPersistence(positionMs: Int64(engine.position * 1_000), isPlaying: engine.isPlaying)
    }

    func addObserver(_ observer: PlaybackEventObserver) {
        observers[ObjectIdentifier(observer)] = observer
    }

    func removeObserver(_ observer: PlaybackEventObserver) {
        observers[ObjectIdentifier(observer)] = nil
    }

    // MARK: - Identity

    /// The engine item id for a queue row: its slot plus the recording, so a version swap in the
    /// same slot is a different item (the engine reuses an opened asset by id) while repeat-one of
    /// the same row is the same item (which the engine loops gaplessly).
    nonisolated static func itemID(for song: Song) -> String {
        PlaybackSourceFactory.itemID(for: song)
    }

    private func queueIndex(ofItem item: PlayableItem) -> Int? {
        let songs = queue.state.songs
        let base = PlaybackSourceFactory.baseItemID(item.id)
        if songs.indices.contains(queue.state.currentIndex), Self.itemID(for: songs[queue.state.currentIndex]) == base {
            return queue.state.currentIndex
        }
        return songs.firstIndex { Self.itemID(for: $0) == base }
    }

    // MARK: - Queue → engine

    private func queueDidChangeItem(_ change: QueueItemChange) {
        guard let song = change.song else {
            engine.stop()
            currentStream = nil
            heldStreams.removeAll()
            heldStreamOrder.removeAll()
            if let lastStartedSong { qualityUpgrades?.forget(lastStartedSong) }
            lastStartedSong = nil
            observers.values.forEach { $0.playbackDidStop() }
            return
        }
        let itemID = Self.itemID(for: song)
        let engineBase = engine.currentItem.map { PlaybackSourceFactory.baseItemID($0.id) }
        var playback = change.playback
        if let held = musicOnlyHold, held.queueEntryId != song.queueEntryId || held.videoId != song.videoId {
            // Off the row a music-only lookup is holding: "keep" means the listener's playing, not
            // the lookup's pause.
            musicOnlyHold = nil
            if playback == .keep { playback = .play }
        }
        let playWhenReady: Bool? = switch playback {
        case .play: true
        case .keep: nil
        case .pause: false
        }
        if followingEngine, engineBase == itemID {
            // The engine got here first (a gapless advance, a crossfade, repeat-one, a skip past an
            // unplayable track); only a pause the queue asks for is left to apply.
            if playWhenReady == false { engine.pause() }
            return
        }
        if change.reason == .restartCurrent, engineBase == itemID {
            engine.seek(to: 0)
            if playWhenReady == true { engine.play() }
            return
        }
        if engineBase != itemID { currentStream = nil }
        let start = TimeInterval(max(change.startPositionMs, 0)) / 1_000
        let play = change.reason == .restored ? false : playWhenReady
        engine.load(sources.item(for: song), startingAt: start, playWhenReady: play)
    }

    private func bindQueue() {
        // Any edit can change what follows the current track: the engine asks again, and the
        // cache reads ahead for the new neighbours.
        trackers.append(ChangeTracker.track({ [weak self] in self?.upcomingKey ?? [] }, initial: false) { [weak self] _ in
            self?.engine.upcomingItemDidChange()
        })
        // Read-ahead watches a deeper window than the engine's preload: a reorder that leaves the
        // immediate next track alone still moves the one after it, and the cache must chase
        // wherever the queue now leads. The play/pause flag is part of the key so a stopped or
        // paused player clears read-ahead (Android: `if (isPlaying) prefetchAround else
        // cancelPrefetch()`), rather than fetching for a paused restore or a queue appended while
        // stopped.
        trackers.append(ChangeTracker.track({ [weak self] in self?.prefetchKey ?? [] }, initial: false) { [weak self] _ in
            self?.prefetchUpcoming()
        })
    }

    /// Identifies the read-ahead plan — whether playback is intended, the current track and the
    /// queue ahead, and the conditions that shape what is fetched — for noticing when the cache's target changes on an edit, a reorder, an
    /// advance or a play/pause.
    private var prefetchKey: [String] {
        let state = queue.state
        guard let current = state.currentSong else { return [] }
        // The connection and the Direct source stream setting decide what read-ahead fetches for the
        // same rows (Queue only's whole next-track copy needs an unmetered one), so a change in
        // either re-plans it.
        return ["playing:\(engine.playWhenReady)", "unmetered:\(sources.isUnmetered())",
                "direct:\(settings.directSourceStream)", Self.itemID(for: current)]
            + state.upcoming.prefix(AudioStreamCache.queueDepth).map(Self.itemID(for:))
    }

    /// Hands the cache the queue ahead of the one playing (Android `prefetchAround`), or clears it
    /// when nothing follows or playback is stopped. The read-ahead policy itself lives in the
    /// cache; this only says which rows to consider, in play order. Updates are chained through
    /// ``readAheadJob`` so an older plan's cancellation can never land after a newer plan's
    /// prefetch.
    private func prefetchUpcoming() {
        guard let cache = sources.cache else { return }
        let songs = queue.state.currentSong != nil && engine.playWhenReady
            ? Array(queue.state.upcoming.prefix(AudioStreamCache.queueDepth))
            : []
        let items = songs.isEmpty ? [] : sources.prefetchItems(for: songs)
        let previous = readAheadJob
        readAheadJob = Task {
            _ = await previous?.value
            await cache.prefetch(items)
        }
    }

    /// Identifies what plays after the current track, for noticing when it changes.
    private var upcomingKey: [String] {
        let state = queue.state
        guard let target = state.finishTargetIndex, state.songs.indices.contains(target) else { return [state.currentSong.map(Self.itemID(for:)) ?? ""] }
        return [state.currentSong.map(Self.itemID(for:)) ?? "", Self.itemID(for: state.songs[target])]
    }

    private func streamResolved(itemID: String, stream: ResolvedStream) {
        // The queued row this answer is for. Nil means the copy the row is on now isn't the one
        // that resolved: a late answer for the copy an upgrade replaced is not it.
        guard let song = song(forEngineItemID: itemID) else { return }
        guard let current = currentSong, sources.engineItemID(for: current) == itemID else {
            // The engine preloaded this row: its stream resolves while the previous song still
            // plays. Hold it until the row is reached — see ``trackStarted(_:reason:)``.
            holdStream(stream, forItemID: itemID)
            return
        }
        currentStream = stream
        qualityUpgrades?.streamResolved(stream, for: song)
    }

    /// The item's open played a copy whole off the disk, so no stream describes it. The one read
    /// when it became current, before the open ran, was an earlier resolve's (the add-on's, before
    /// YouTube's copy was whole): it must not name the source or claim the format.
    private func openedFromDisk(itemID: String) {
        if heldStreams.removeValue(forKey: itemID) != nil { heldStreamOrder.removeAll { $0 == itemID } }
        guard let current = currentSong, sources.engineItemID(for: current) == itemID else { return }
        currentStream = nil
    }

    /// The queued row whose engine item id is `itemID` — the current track first, then any row
    /// still in the queue. Nil for an engine id no row is on now (a rendition an upgrade replaced).
    private func song(forEngineItemID itemID: String) -> Song? {
        if let current = currentSong, sources.engineItemID(for: current) == itemID { return current }
        return queue.state.songs.first { sources.engineItemID(for: $0) == itemID }
    }

    /// Remembers a stream resolved for a row the engine has preloaded but not reached, dropping the
    /// oldest once a handful are held.
    private func holdStream(_ stream: ResolvedStream, forItemID itemID: String) {
        if heldStreams[itemID] == nil { heldStreamOrder.append(itemID) }
        heldStreams[itemID] = stream
        while heldStreamOrder.count > Self.heldStreamLimit {
            let oldest = heldStreamOrder.removeFirst()
            heldStreams[oldest] = nil
        }
        pruneHeldStreams()
    }

    /// Applies the stream held for the row that just became current, exactly as a live resolution
    /// would, or clears the previous track's when nothing is known for the new one yet. Called after
    /// ``QualityUpgradeController/trackStarted(_:previous:)``, whose reset must not wipe it.
    private func applyHeldStream(for song: Song) {
        let itemID = sources.engineItemID(for: song)
        if let stream = heldStreams.removeValue(forKey: itemID) {
            heldStreamOrder.removeAll { $0 == itemID }
            currentStream = stream
            qualityUpgrades?.streamResolved(stream, for: song)
        } else {
            // Nothing resolved for this row yet: never keep describing the track before it.
            currentStream = nil
        }
        pruneHeldStreams()
    }

    /// Drops held streams for rows no longer in the queue.
    private func pruneHeldStreams() {
        guard !heldStreams.isEmpty else { return }
        let queued = Set(queue.state.songs.map { sources.engineItemID(for: $0) })
        heldStreams = heldStreams.filter { queued.contains($0.key) }
        heldStreamOrder = heldStreamOrder.filter { heldStreams[$0] != nil }
    }

    // MARK: - Settings → engine

    private func bindSettings() {
        let settings = self.settings
        trackers.append(ChangeTracker.track({ settings.crossfadeSeconds }) { [weak self] seconds in
            self?.engine.crossfadeDuration = TimeInterval(seconds)
        })
        trackers.append(ChangeTracker.track({ settings.skipSilence }) { [weak self] on in
            self?.engine.skipSilence = on
        })
        trackers.append(ChangeTracker.track({ settings.playbackSpeed }) { [weak self] speed in
            self?.engine.rate = speed
        })
        trackers.append(ChangeTracker.track({ settings.smartFadeEnabled }) { [weak self] on in
            self?.engine.automixEnabled = on
        })
        trackers.append(ChangeTracker.track({ AudioDSPSettings.from(settings) }) { [weak self] dsp in
            guard let self else { return }
            for processor in self.processors { processor.apply(dsp, automix: settings.smartFadeEnabled) }
            self.engine.audioProcessingDidChange()
        })
    }

    // MARK: - Notices

    private func announce(_ result: QueueEditResult, next: Bool? = nil) {
        switch result {
        case .added(let count):
            guard let next else { return }
            if next {
                notice = QueueNotice(message: count == 1 ? L10n.songWillPlayNext : L10n.songsWillPlayNext(count), symbol: AppSymbol.playNext)
            } else {
                notice = QueueNotice(message: count == 1 ? L10n.songAddedToQueue : L10n.songsAddedToQueue(count), symbol: AppSymbol.addToQueue)
            }
        case .refusedByHost:
            notice = QueueNotice(message: L10n.listenTogetherHostOnlyNotice, symbol: nil)
        case .partyQueueFull(let limit):
            notice = QueueNotice(message: L10n.partyQueueFull(limit), symbol: nil)
        case .done, .ignored:
            break
        }
    }

    @discardableResult
    private func refusalNotice(_ result: QueueEditResult) -> QueueEditResult {
        announce(result)
        return result
    }

    // MARK: - Engine → observers

    private func trackStarted(_ song: Song, reason: ItemChangeReason) {
        let previous = lastStartedSong
        // The live position is exact when the engine advanced by itself with the next item preloaded,
        // but 0 once it had to open the item (a skip, or nothing preloaded): then the last checkpoint,
        // at most one sampler interval old, is the best there is. A track that ended played from the
        // start, so the larger of the two is never wrong.
        let live = Int64(engine.position * 1_000)
        let checkpointed = previous.flatMap { lastCheckpointMs[Self.itemID(for: $0)] } ?? 0
        let previousPosition = reason.previousEnded ? max(live, checkpointed) : (checkpointed > 0 ? checkpointed : live)
        lastStartedSong = song
        // Only the new track's entry (just checkpointed, or about to be) is worth keeping.
        // A repeat starts the row over: the last lap's end is not where this lap stands.
        lastCheckpointMs = reason == .repeated ? [:] : lastCheckpointMs.filter { $0.key == Self.itemID(for: song) }
        awaitingFirstCheckpoint = Self.itemID(for: song)
        // Before the renditions are dropped: an upgraded copy the queue moves off is shelved from them.
        qualityUpgrades?.trackStarted(song, previous: previous)
        // Another row's reopened copy (an upgrade, a revert) is forgotten once it stops playing:
        // a forced stream's URL doesn't outlive it, and a fresh play resolves afresh.
        sources.retainRenditions(for: [Self.itemID(for: song)])
        // After the upgrade controller's reset, or the fresh start it just denied would be wiped:
        // a stream the engine resolved while this row was only preloaded starts the second look now.
        applyHeldStream(for: song)
        engine.setFeedback(likeStatus(of: song))
        convertUpcomingToMusicOnly()
        let durationMs = Int64(song.durationMillis)
        let playing = engine.playWhenReady
        lastReportedPlaying = playing
        observers.values.forEach {
            $0.playback(didStart: song, durationMs: durationMs, isPlaying: playing, previous: previous,
                        previousListened: reason.previousEnded, previousPositionMs: previousPosition)
        }
        // After the controller's reset and the held stream's application, so a row served from disk
        // (which never went through the resolver) is offered its second look from the moment it
        // starts — Android called this from `onTrackBecameCurrent`.
        qualityUpgrades?.lookForBetterCopy()
        scheduleAddonCachePurge()
    }

    /// Android's `scheduleForeignCachePurge`: once the queue has settled on this track, the partial
    /// add-on and upgrade copies of tracks it has moved past are dropped (see
    /// ``AudioStreamCache/dropPartialAddonEntries(keepingTracks:)``). Kept: the track before (a
    /// crossfade may still read it), this one, the ones read-ahead looks ahead for, and whatever the
    /// engine has preloaded.
    private func scheduleAddonCachePurge() {
        guard let cache = sources.cache else { return }
        addonCachePurge?.cancel()
        let delay = addonCachePurgeDelay
        addonCachePurge = Task { [weak self] in
            guard (try? await Task.sleep(for: delay)) != nil, let self else { return }
            let state = queue.state
            let window = (state.currentIndex - 1)...(state.currentIndex + AudioStreamCache.queueDepth)
            var keep = Set(window.filter { state.songs.indices.contains($0) }.map { state.songs[$0].videoId })
            if let current = currentSong { keep.insert(current.videoId) }
            if let preloaded = engine.upcomingItem?.song { keep.insert(preloaded.videoId) }
            await cache.dropPartialAddonEntries(keepingTracks: keep)
        }
    }

    private func reportPlayingIfChanged() {
        guard let song = currentSong else { return }
        let playing = engine.isPlaying
        guard playing != lastReportedPlaying else { return }
        lastReportedPlaying = playing
        let positionMs = Int64(engine.position * 1_000)
        let durationMs = Int64(duration * 1_000)
        observers.values.forEach { $0.playback(didChangePlaying: playing, song: song, positionMs: positionMs, durationMs: durationMs) }
        // Sound is out of the speaker (Android called `lookForBetterCopy` from
        // `onIsPlayingChanged` when it turned true), so a cached row that was not eligible when it
        // became current gets its look now.
        if playing { qualityUpgrades?.lookForBetterCopy() }
    }
}

// MARK: - AudioPlayerEngineDelegate

extension PlayerController: AudioPlayerEngineDelegate {
    func audioPlayerEngine(_ engine: AudioPlayerEngine, itemAfter item: PlayableItem) -> PlayableItem? {
        let state = queue.state
        guard let index = queueIndex(ofItem: item) else { return nil }
        let target: Int?
        if index == state.currentIndex {
            target = state.finishTargetIndex
        } else if state.repeatMode == .one {
            target = index
        } else if index + 1 < state.songs.count {
            target = index + 1
        } else {
            target = state.repeatMode == .all ? 0 : nil
        }
        guard let target, state.songs.indices.contains(target) else { return nil }
        return sources.item(for: state.songs[target])
    }

    func audioPlayerEngine(_ engine: AudioPlayerEngine, didChangeItemTo item: PlayableItem, reason: ItemChangeReason) {
        switch reason {
        case .requested:
            break
        case .ended, .crossfade, .repeated:
            // The engine moved on by itself: the queue follows (transition bookkeeping, AutoPlay
            // top-up, the restart snapshot) and reports a change the handler recognises.
            followingEngine = true
            queue.trackDidFinish()
            followingEngine = false
            if let current = currentSong, Self.itemID(for: current) != PlaybackSourceFactory.baseItemID(item.id) {
                // The queue changed under the preload; what the queue says wins. The load reports
                // the queue's row as started on its own, so the stale item is never reported.
                engine.load(sources.item(for: current), startingAt: 0, playWhenReady: nil)
                return
            }
        case .skippedUnplayable(let why):
            if let index = queueIndex(ofItem: item) {
                followingEngine = true
                queue.seek(toItem: index)
                followingEngine = false
            }
            DebugLog.w("Player", "skipped an unplayable track: \(why)")
        }
        // Before the start is reported: a row played again from the audio the engine still holds
        // opens nothing, and the upgrade's slot choice and fallback read the key it plays from.
        if let videoId = item.song?.videoId { sources.playingKeys.becameCurrent(item.id, videoId: videoId) }
        // Every new track, and every repeat of one, is a start for scrobbling and history; a
        // reopen of the same recording in the same slot (a revert, a retry) is not.
        if let song = item.song ?? currentSong,
           reason == .repeated || lastStartedSong?.id != song.id || lastStartedSong?.videoId != song.videoId {
            trackStarted(song, reason: reason)
        }
        sources.facts.retain(only: Set([item.id] + (engine.upcomingItem.map { [$0.id] } ?? [])))
        if let stream = sources.facts.stream(for: item.id) { currentStream = stream }
    }

    func audioPlayerEngine(_ engine: AudioPlayerEngine, didFinishQueueAfter item: PlayableItem) {
        followingEngine = true
        queue.trackDidFinish()
        followingEngine = false
        reportPlayingIfChanged()
    }

    func audioPlayerEngine(_ engine: AudioPlayerEngine, didFail error: PlaybackError, willRetry: Bool) {
        // Filed under the track, so its pasted log says why it stopped.
        TrackLog.w("Player", "playback failed (\(willRetry ? "retrying" : "giving up")): \(error.message)",
                   about: song(forEngineItemID: error.itemID)?.videoId ?? TrackLog.currentTrack)
        // Read now: the engine's own retry captured the same playhead a moment ago.
        failedAt = (error.itemID, engine.position)
    }

    func audioPlayerEngine(_ engine: AudioPlayerEngine, handle command: RemoteCommand) -> RemoteCommandResult {
        handleRemoteCommand(command)
    }

    func audioPlayerEngine(_ engine: AudioPlayerEngine, checkpoint: PlaybackCheckpoint) {
        let positionMs = Int64(checkpoint.position * 1_000)
        let checkpointed = PlaybackSourceFactory.baseItemID(checkpoint.itemID)
        if awaitingFirstCheckpoint == checkpointed {
            awaitingFirstCheckpoint = nil
        } else if positionMs > 0 {
            // A zero is only ever a reopen's transition checkpoint; it must not wipe a real position.
            lastCheckpointMs[checkpointed] = positionMs
        }
        queue.recordPlayhead(positionMs: positionMs, isPlaying: checkpoint.isPlaying)
        reportPlayingIfChanged()
        // The progress sample's backstop (Android's five-second `reportProgress`): a track skipped
        // to directly may not be resolved yet when its transition comes and goes, and this is what
        // picks it up once the decoder has reported it.
        if checkpoint.isPlaying { qualityUpgrades?.lookForBetterCopy() }
        guard let song = currentSong, Self.itemID(for: song) == PlaybackSourceFactory.baseItemID(checkpoint.itemID) else { return }
        let durationMs = Int64(duration * 1_000)
        observers.values.forEach { $0.playback(progress: song, positionMs: positionMs, durationMs: durationMs, isPlaying: checkpoint.isPlaying) }
    }

    /// Lock screen, Control Center, AirPods, CarPlay. Next/previous go through the queue; the heart
    /// rates the track; transport is held while a Listen Together host has control.
    func handleRemoteCommand(_ command: RemoteCommand) -> RemoteCommandResult {
        guard currentSong != nil else { return .noActionableNowPlayingItem }
        switch command {
        case .nextTrack:
            return next() ? .success : (controlsLocked ? .commandFailed : .noSuchContent)
        case .previousTrack:
            return previous() ? .success : (controlsLocked ? .commandFailed : .noSuchContent)
        case .like:
            toggleLike()
            return .success
        case .dislike:
            toggleDislike()
            return .success
        case .play:
            play()
            return .success
        case .pause:
            pause()
            return .success
        case .togglePlayPause:
            togglePlayPause()
            return .success
        case .changePlaybackPosition(let seconds):
            guard !controlsLocked else { return .commandFailed }
            seek(to: seconds)
            return .success
        case .skipForward(let seconds):
            guard !controlsLocked else { return .commandFailed }
            seek(to: engine.position + seconds)
            return .success
        case .skipBackward(let seconds):
            guard !controlsLocked else { return .commandFailed }
            seek(to: max(engine.position - seconds, 0))
            return .success
        case .changePlaybackRate(let rate):
            setSpeed(rate)
            return .success
        case .stop:
            pause()
            return .success
        }
    }
}
