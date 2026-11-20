import AVFoundation
import AudioCache
import VibraMusicCore

/// One item built for one deck: the `AVPlayerItem`, its tap, and what the engine knows about it.
@MainActor
final class DeckEntry {
    let item: PlayableItem
    let playerItem: AVPlayerItem
    let asset: AVURLAsset
    /// The asset-level audio track. Nil for a streaming playlist (HLS), whose tracks only exist
    /// on the player item once variants load; such an item plays without a processing tap.
    let audioTrack: AVAssetTrack?
    let trackFormat: AudioTrackFormat
    let content: AudioContentKind
    let loudnessDb: Double?
    let declaredFormat: StreamFormat?
    /// The tap's context while the item is processed; nil while it plays without one.
    private(set) var tap: TapContext?
    private(set) var signalPath: PlaybackSignalPath = .unprocessed
    /// Where playback is trimmed to end because of a silent outro, when skip silence found one.
    private(set) var trimmedEnd: TimeInterval?
    /// The whole length the cache's source knows ahead of the bytes (a segmented copy's playlist).
    let knownLength: TimeInterval?

    init(
        item: PlayableItem,
        playerItem: AVPlayerItem,
        asset: AVURLAsset,
        audioTrack: AVAssetTrack?,
        trackFormat: AudioTrackFormat,
        loudnessDb: Double?,
        declaredFormat: StreamFormat?
    ) {
        self.item = item
        self.playerItem = playerItem
        self.asset = asset
        self.audioTrack = audioTrack
        self.trackFormat = trackFormat
        self.content = AudioContentKind.classify(trackFormat, declared: declaredFormat)
        self.loudnessDb = loudnessDb
        self.declaredFormat = declaredFormat
        self.knownLength = AudioStreamCache.knownDuration(of: asset)
    }

    /// Puts the item on `path`: a tap calling `context` for ``PlaybackSignalPath/processed``, no
    /// tap for anything else. Swapping a playing item's audio mix is supported by AVFoundation and
    /// takes effect within a render cycle, so a DSP setting switched on mid-track reaches a
    /// bit-transparent item without reopening it. Returns the path actually in effect.
    @discardableResult
    func apply(_ path: PlaybackSignalPath, context: @autoclosure () -> TapContext) -> PlaybackSignalPath {
        guard path != signalPath || (path == .processed && tap == nil) else { return signalPath }
        if path == .processed {
            let made = context()
            if let audioTrack, let mix = AudioTap.audioMix(for: audioTrack, context: made) {
                playerItem.audioMix = mix
                tap = made
                signalPath = .processed
            } else {
                playerItem.audioMix = nil
                tap = nil
                signalPath = .unprocessed
            }
        } else {
            playerItem.audioMix = nil
            tap = nil
            signalPath = path
        }
        return signalPath
    }

    /// The decoder's length once the item has loaded, else the catalogue's. A segmented copy
    /// still arriving shows its playlist's length while AVFoundation, counting only the fragments
    /// it has read, says less; once whole, AVFoundation's own figure stands.
    var duration: TimeInterval? {
        if let knownLength, isStillArriving { return knownLength }
        let decoded = playerItem.duration
        if decoded.isNumeric, decoded.seconds.isFinite, decoded.seconds > 0 { return decoded.seconds }
        return item.duration
    }

    /// Whether a seek here lands where it says. Not one in a raw FLAC or MP3 opened for a play from the
    /// top (see ``AudioStreamCache/preciselyTimed(_:)``): the engine reopens it for a mid-song seek.
    var isPreciselyTimed = true

    /// Whether the deck may stop this item for bytes still arriving (``PlaybackDeck/holdForBytes()``).
    var holdsForBytes = true

    /// Whether AVFoundation knows less of this segmented copy than its playlist says there is.
    var isStillArriving: Bool {
        guard let knownLength else { return false }
        let decoded = playerItem.duration
        guard decoded.isNumeric, decoded.seconds.isFinite, decoded.seconds > 0 else { return true }
        return decoded.seconds < knownLength - Self.arrivingMargin
    }

    /// How far short of the known length AVFoundation's figure must be to count as a copy still
    /// arriving: it lags by at least a segment (seconds), and is within a frame once the copy is whole.
    static let arrivingMargin: TimeInterval = 1

    /// Where the item stops: its trimmed end, else its length.
    var effectiveEnd: TimeInterval? { trimmedEnd ?? duration }

    /// How far past `position` an item that reported its end there still has to be off for it not
    /// to count as finished: more than a catalogue's rounding, less than the shortest gap worth
    /// getting back.
    static let shortEndMargin: TimeInterval = 3

    /// The length this item is known to have, when an end reported at `position` falls well short
    /// of it; nil for an end where it should be, or a length nobody knows. The catalogue's figure
    /// counts only through the cache: anywhere else the decoder has the whole file's length.
    func lengthBeyondEnd(at position: TimeInterval) -> TimeInterval? {
        let catalogue = asset.url.scheme == AudioStreamCache.urlScheme ? item.duration ?? 0 : 0
        let known = trimmedEnd ?? max(duration ?? 0, catalogue)
        return known - position > Self.shortEndMargin ? known : nil
    }

    /// What AVFoundation has loaded, for the log.
    var loadedDescription: String {
        playerItem.loadedTimeRanges.map(\.timeRangeValue)
            .map { String(format: "%.1f-%.1fs", $0.start.seconds, $0.end.seconds) }.joined(separator: ", ")
    }

    func trimEnd(at time: TimeInterval?) {
        trimmedEnd = time
        playerItem.forwardPlaybackEndTime = time.map { CMTime(seconds: $0, preferredTimescale: 1_000) } ?? .invalid
    }
}

/// What a deck tells the engine.
enum DeckEvent {
    /// The queue player moved on to the queued entry by itself (gapless advance).
    case advanced(from: DeckEntry, to: DeckEntry)
    /// The current entry played to its end and the deck stopped there (nothing queued, or
    /// automatic advance switched off).
    case endedWithoutAdvancing(DeckEntry)
    case itemReady(DeckEntry)
    case itemFailed(DeckEntry, Error)
    case timeControlChanged
    case stalled(DeckEntry)
    /// The entry the deck is holding has the bytes it stopped for on disk and the player hasn't
    /// taken them up.
    case bytesArrivedWhileHeld(DeckEntry)
}

/// One of the engine's two players.
///
/// An `AVQueuePlayer` holding the current entry and, for a gapless advance, the entry queued after
/// it: the queue player opens the next item while the current one plays and switches without a gap.
/// A crossfade needs the next track on the *other* deck, so the controller loads it there instead
/// and the queued copy here is dropped as the fade starts.
@MainActor
final class PlaybackDeck: TransitionDeck {
    let id: PlaybackDeckID
    let player: AVQueuePlayer
    let binding: DeckProcessorBinding
    var onEvent: ((PlaybackDeck, DeckEvent) -> Void)?

    private(set) var current: DeckEntry? {
        didSet { if current !== oldValue { stopHolding() } }
    }
    private(set) var queued: DeckEntry?
    private(set) var hasEnded = false
    private(set) var failure: Error?
    /// The listener's intent on this deck, which is what the play/pause glyph shows. AVPlayer's own
    /// rate drops to 0 at the end of an item and while waiting, so it can't answer this.
    private(set) var wantsToPlay = false
    /// Whether an item that ends moves straight on to the queued one. Off while "sleep after this
    /// track" is armed, so the next track is never heard.
    var advancesAutomatically = true { didSet { updateActionAtItemEnd() } }
    private var pendingSeek: TimeInterval?
    /// Preroll state for a deck armed to start a crossfade: requested, running, done.
    private var wantsPreroll = false
    private var prerolling = false
    private var prerolled = false
    private var filter = TransitionFilterCutoffs.open
    /// The current entry has stalled since it started (or was last sought): it then waits for
    /// ``resumeBuffer`` rather than ``startBuffer`` before it is started again.
    private var rebuffering = false
    /// Where the buffer ended when ``startIfBuffered()`` last started the current entry: it starts it
    /// again only on more than that, so a stream that won't play what it has isn't kicked in a loop.
    private var startedOnBufferEnd: TimeInterval?
    /// The current entry's "nothing buffered at the playhead" was logged: once per entry is enough.
    private var reportedNothingBuffered = false
    /// Stopped at the end of what AVFoundation has read of a copy still arriving, until more has
    /// (see ``holdForBytes()``). The listener still wants it playing, so it shows as buffering.
    private(set) var isHeldForBytes = false
    private var holdTask: Task<Void, Never>?
    private var playerObservations: [NSKeyValueObservation] = []
    private var itemObservations: [ObjectIdentifier: [NSKeyValueObservation]] = [:]
    private var itemNotifications: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    private var timeObserver: Any?

    init(id: PlaybackDeckID, processor: PlaybackAudioProcessor?) {
        self.id = id
        self.player = AVQueuePlayer()
        self.binding = DeckProcessorBinding(processor: processor)
        player.actionAtItemEnd = .pause
        playerObservations.append(player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.currentItemChanged() } }
        })
        playerObservations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.startIfBuffered()
                    self.onEvent?(self, .timeControlChanged)
                }
            }
        })
        // The reason can turn from "evaluating" to "minimizing stalls" with the status unchanged.
        playerObservations.append(player.observe(\.reasonForWaitingToPlay, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.startIfBuffered() } }
        })
    }

    func invalidate() {
        playerObservations.forEach { $0.invalidate() }
        playerObservations.removeAll()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        clear()
    }

    /// Calls `handler` every `interval` seconds of playback (and on start/stop/seek).
    func observePeriodically(every interval: TimeInterval, handler: @escaping @MainActor (PlaybackDeck) -> Void) {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: interval, preferredTimescale: 1_000),
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.holdIfRunningOut()
                handler(self)
            }
        }
    }

    // MARK: - Items

    /// Replaces everything on the deck with `entry`, positioned at `time`.
    func setCurrent(_ entry: DeckEntry, at time: TimeInterval) {
        detachAll()
        current = entry
        hasEnded = false
        failure = nil
        pendingSeek = nil
        forgetBuffering()
        watch(entry)
        if time > 0 {
            pendingSeek = time
            entry.playerItem.seek(to: CMTime(seconds: time, preferredTimescale: 1_000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.seekFinished(entry) } }
            }
        }
        player.insert(entry.playerItem, after: nil)
        player.volume = storedVolume
        updateActionAtItemEnd()
        if wantsToPlay { startPlayer() }
    }

    /// Starts the player on what it has: a track sounds as soon as its first samples decode, not
    /// once AVPlayer judges the buffer "likely to keep up", which on a fresh stream costs a second
    /// or more of silence after the bytes are already in. Waiting to minimise stalls stays on, so a
    /// stall (or a start with nothing buffered yet) waits and shows as buffering; what ends that
    /// wait is ``startIfBuffered()``, not AVPlayer's guess at the link.
    private func startPlayer() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.playImmediately(atRate: player.defaultRate > 0 ? player.defaultRate : 1)
    }

    /// Audio in hand before a stream that is waiting on its bytes is started anyway, and after a
    /// stall: Android's `START_PLAYBACK_MS` and `RESUME_PLAYBACK_MS`. More after a stall, which says
    /// the link really is struggling and a second in hand only buys the next one.
    static let startBuffer: TimeInterval = 0.5
    static let resumeBuffer: TimeInterval = 2

    /// Starts a deck that wants to play and is waiting for AVPlayer to judge its stream fast enough,
    /// once ``startBuffer`` (``resumeBuffer`` after a stall) is buffered at the playhead.
    ///
    /// Every byte the player reads comes through the cache's resource loader, and for such an asset
    /// AVPlayer's waiting to minimise stalls holds playback until it predicts the stream will play
    /// to its end without stalling — a prediction Apple's header says does not work through a
    /// resource loader. On a link slower than the stream's bitrate (a 192 kHz FLAC at 5.5 Mbps over
    /// 2.5 Mbps) that never comes, and the track sat silent with half a minute of it on disk.
    /// `playImmediately` plays what is there, and when that runs out the player stalls and waits
    /// again, showing as buffering, and this starts it once more: ExoPlayer's behaviour. A playlist
    /// (HLS) is left to AVPlayer, whose prediction holds for the segments it fetches itself.
    private func startIfBuffered() {
        guard wantsToPlay, let entry = current, pendingSeek == nil, failure == nil, !entry.asset.isStreamingPlaylist,
              player.currentItem === entry.playerItem, entry.playerItem.status == .readyToPlay,
              player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
              player.reasonForWaitingToPlay == .toMinimizeStalls || player.reasonForWaitingToPlay == .evaluatingBufferingRate
        else { return }
        let now = entry.playerItem.currentTime()
        guard let end = Self.bufferedEnd(in: entry.playerItem.loadedTimeRanges.map(\.timeRangeValue), at: now) else {
            if !reportedNothingBuffered {
                reportedNothingBuffered = true
                PlaybackLog.debug(bufferReport(entry) + " (waiting with nothing buffered at the playhead)", about: entry.item.trackID)
            }
            return
        }
        let ahead = end - (now.isNumeric ? now.seconds : 0)
        guard ahead >= (rebuffering ? Self.resumeBuffer : Self.startBuffer), end > (startedOnBufferEnd ?? -1) else { return }
        startedOnBufferEnd = end
        PlaybackLog.debug("\(entry.item.id): starting on \(String(format: "%.1f", ahead))s buffered rather than waiting "
            + "for the stream to look fast enough" + (rebuffering ? " (after a stall)" : ""), about: entry.item.trackID)
        player.playImmediately(atRate: player.rate > 0 ? player.rate : (player.defaultRate > 0 ? player.defaultRate : 1))
    }

    /// A new entry, or a seek: nothing about the last one's stalls and starts carries over.
    private func forgetBuffering() {
        rebuffering = false
        startedOnBufferEnd = nil
        reportedNothingBuffered = false
    }

    /// What the player makes of `entry`'s buffer, as one log line: what tells a start that waited
    /// on an empty buffer from one waiting on readiness or on a copy that won't render.
    func bufferReport(_ entry: DeckEntry) -> String {
        let item = entry.playerItem
        let status = switch item.status {
        case .readyToPlay: "ready"
        case .failed: "failed"
        default: "unknown"
        }
        let control = switch player.timeControlStatus {
        case .playing: "playing"
        case .paused: "paused"
        default: "waiting"
        }
        let loaded = item.loadedTimeRanges.map(\.timeRangeValue)
            .map { String(format: "%.1f-%.1fs", $0.start.seconds, $0.end.seconds) }.joined(separator: ", ")
        let at = item.currentTime().isNumeric ? item.currentTime().seconds : 0
        var line = "\(entry.item.id) buffer: status=\(status) bufferEmpty=\(item.isPlaybackBufferEmpty) "
            + "likelyToKeepUp=\(item.isPlaybackLikelyToKeepUp) loaded=[\(loaded)] at=\(String(format: "%.1f", at))s "
            + "timeControl=\(control) onPlayer=\(player.currentItem === item)"
        if let reason = player.reasonForWaitingToPlay { line += " reason=\(reason.rawValue)" }
        if let error = item.error { line += " error=\(error)" }
        return line
    }

    /// Where the loaded range holding `time` ends, in seconds; nil when nothing is loaded there. A
    /// range starting a hair after `time` counts, for a playhead a seek left just short of it.
    static func bufferedEnd(in ranges: [CMTimeRange], at time: CMTime) -> TimeInterval? {
        let now = time.isNumeric ? time.seconds : 0
        return ranges.compactMap { range -> Double? in
            let start = range.start.seconds, end = range.end.seconds
            guard start.isFinite, end.isFinite, start <= now + 0.1, end > now else { return nil }
            return end
        }.max()
    }

    /// Queues `entry` to follow the current one gaplessly, replacing whatever was queued.
    func enqueue(_ entry: DeckEntry) {
        removeQueued()
        guard let current, player.canInsert(entry.playerItem, after: current.playerItem) else { return }
        queued = entry
        watch(entry)
        player.insert(entry.playerItem, after: current.playerItem)
        updateActionAtItemEnd()
    }

    func removeQueued() {
        guard let queued else { return }
        self.queued = nil
        unwatch(queued)
        player.remove(queued.playerItem)
        updateActionAtItemEnd()
    }

    /// Stops this deck going on to its queued entry, leaving the item on the player. Within seconds of
    /// its current item's end the queue player has started on the next, and taking it off then cuts
    /// the sound for 100 to 200 ms (measured on macOS, on FLAC and AAC). A crossfade's handoff comes
    /// just there, with the outgoing track still at full volume. The item goes when the deck retires.
    func stopAdvancingToQueued() {
        guard let queued else { return }
        self.queued = nil
        unwatch(queued)
        updateActionAtItemEnd()
    }

    /// Moves onto the queued entry now (a skip to the preloaded next track, or the sleep timer's
    /// paused advance). Returns the new current entry.
    @discardableResult
    func advanceToQueued() -> DeckEntry? {
        guard let next = queued, let previous = current else { return nil }
        queued = nil
        current = next
        hasEnded = false
        pendingSeek = nil
        forgetBuffering()
        unwatch(previous)
        player.advanceToNextItem()
        if player.currentItem !== next.playerItem {
            // The queue player refused (the item failed while waiting): put it in by hand.
            player.removeAllItems()
            player.insert(next.playerItem, after: nil)
            player.volume = storedVolume
        }
        updateActionAtItemEnd()
        if wantsToPlay { startPlayer() }
        return next
    }

    /// Empties the deck.
    func clear() {
        detachAll()
        current = nil
        hasEnded = false
        failure = nil
        pendingSeek = nil
        resetPreroll()
    }

    // MARK: - Preroll

    /// Primes the paused deck's render pipeline at its position once the item is ready, so that
    /// ``play()`` makes sound at once. Without it, starting a player that has never rendered takes
    /// about half a second on the first buffers — at the head of a crossfade that is half a second of
    /// the incoming track arriving late, measured off its own position, and a fade that reaches the
    /// outgoing track's end before it has reached full volume.
    func preroll() {
        wantsPreroll = true
        attemptPreroll()
    }

    private func attemptPreroll() {
        guard wantsPreroll, !prerolling, !prerolled, !wantsToPlay, pendingSeek == nil,
              let entry = current, entry.playerItem.status == .readyToPlay, player.status == .readyToPlay else { return }
        prerolling = true
        let rate = player.defaultRate > 0 ? player.defaultRate : 1
        player.preroll(atRate: rate) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.prerolling, self.current === entry else { return }
                    self.prerolling = false
                    // Finished or interrupted (a play or a seek cancels it), the deck is as ready
                    // as it is going to get.
                    self.prerolled = true
                }
            }
        }
    }

    private func resetPreroll() {
        if prerolling { player.cancelPendingPrerolls() }
        wantsPreroll = false
        prerolling = false
        prerolled = false
    }

    private func detachAll() {
        if let current { unwatch(current) }
        if let queued { unwatch(queued) }
        queued = nil
        player.removeAllItems()
    }

    /// Puts the deck back in the drawer: emptied, at full volume, on the listener's rate, filter
    /// open. The volume matters as much as the emptying — a deck left at the gain it faded out on is
    /// the next transition's *incoming* deck, and would arrive already turned down.
    func retire(rate: Float) {
        wantsToPlay = false
        player.pause()
        clear()
        volume = 1
        self.rate = rate
        setTransitionFilter(.open)
    }

    // MARK: - Transport

    /// The deck's gain. Held here as well as on the player: an `AVPlayer` with no item can drop a
    /// volume set while it is empty (measured on macOS: a retired deck set back to 1 still read as
    /// the gain it had faded out on), and the next transition would then bring the incoming track in
    /// already turned down. Re-applied whenever an item goes onto the player.
    private var storedVolume: Float = 1

    var volume: Float {
        get { storedVolume }
        set {
            storedVolume = newValue
            player.volume = newValue
        }
    }

    var rate: Float {
        get { player.defaultRate }
        set {
            player.defaultRate = newValue
            if player.rate != 0 { player.rate = newValue }
        }
    }

    var playWhenReady: Bool {
        get { wantsToPlay }
        set { newValue ? play() : pause() }
    }

    func play() {
        wantsToPlay = true
        prerolling = false
        guard current != nil, !isHeldForBytes else { return }
        if hasEnded {
            hasEnded = false
            seek(to: 0)
        }
        startPlayer()
    }

    /// Starts this paused, prerolled deck from where it stands so that it is heard at the moment
    /// `other`'s item is heard at `otherTime`. The start is scheduled on the host clock both players
    /// run against (AVPlayer's synchronized start), not timed off a guess at how long a player takes
    /// to sound, which differs with the DSP tap and the route. False, with nothing started, for a
    /// playlist (which can't be started that way), before `other` has a timebase, or with under
    /// `margin` seconds to schedule in.
    func start(inStepWith other: PlaybackDeck, at otherTime: TimeInterval, margin: TimeInterval) -> Bool {
        // Both items need a timebase: the other's to say when it gets there, this one's for the
        // scheduled start itself.
        guard let entry = current, !entry.asset.isStreamingPlaylist, entry.playerItem.timebase != nil,
              let timebase = other.current?.playerItem.timebase else { return false }
        // The timebase's rate is the other deck's real speed, so `wait` is in wall seconds.
        let rate = CMTimebaseGetRate(timebase)
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        let wait = (otherTime - CMTimebaseGetTime(timebase).seconds) / rate
        guard rate > 0, player.defaultRate > 0, wait >= margin else { return false }
        wantsToPlay = true
        prerolling = false
        // Required for a synchronized start (AVPlayer raises otherwise); back on with the next play().
        player.automaticallyWaitsToMinimizeStalling = false
        player.setRate(player.defaultRate, time: .invalid, atHostTime: CMTimeAdd(hostNow, CMTime(seconds: wait, preferredTimescale: 1_000_000_000)))
        return true
    }

    func pause() {
        wantsToPlay = false
        stopHolding()
        player.pause()
    }

    func seek(to time: TimeInterval, completion: (@MainActor (Bool) -> Void)? = nil) {
        guard let entry = current else { return }
        hasEnded = false
        pendingSeek = time
        forgetBuffering()
        if isHeldForBytes {
            stopHolding()
            startPlayer()
        }
        player.seek(to: CMTime(seconds: max(time, 0), preferredTimescale: 1_000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.seekFinished(entry)
                    completion?(finished)
                }
            }
        }
    }

    private func seekFinished(_ entry: DeckEntry) {
        guard current === entry else { return }
        pendingSeek = nil
        attemptPreroll()
        startIfBuffered()
        resumeIfBytesArrived()
    }

    // MARK: - Bytes still arriving

    /// How close to the end of what's loaded a copy still arriving is stopped. Three position ticks,
    /// so a tick that comes late still lands before the end.
    static let holdMargin: TimeInterval = 0.75
    /// Audio in hand before it plays on: Android's `RESUME_PLAYBACK_MS`.
    static let resumeAhead: TimeInterval = 2

    /// How much is fetched before a held copy is opened again: more than a segment, so the next open
    /// has a whole fragment past the playhead, and few enough stops on a link that can't keep up.
    static let fetchAhead: TimeInterval = 10
    /// How long a hold waits on a link that brings nothing before it counts as a failure.
    static let stallLimit: Duration = .seconds(90)

    /// Stops the player at the end of what it has until more arrives.
    ///
    /// AVFoundation knows a fragmented file only as far as the fragments it has read. Played
    /// up to the last of them with the next not in yet, an item has been seen to report it played to
    /// its end rather than stall, and to know no more of the file even once all of it was on disk (a
    /// new asset does), so the track was gone at the first segment a slow link took longer than the
    /// music to deliver. Android's player has the playlist's length and just buffers.
    ///
    /// So nothing here relies on what a stopped player reports, or on it reading on. The bytes are
    /// fetched into the cache regardless, and then either the player has seen them, or the engine
    /// opens the item afresh over them (``DeckEvent/bytesArrivedWhileHeld(_:)``). A link that fails
    /// or brings nothing fails the item into the usual recovery. A hold always ends in one of those.
    private func holdForBytes() {
        guard wantsToPlay, !isHeldForBytes, let entry = current else { return }
        let at = position
        let length = entry.duration ?? 0
        isHeldForBytes = true
        player.pause()
        PlaybackLog.info("\(entry.item.id): stopped at \(String(format: "%.1f", at))s of \(String(format: "%.1f", length))s, "
            + "the end of what has arrived [\(entry.loadedDescription)]; fetching more", about: entry.item.trackID)
        holdTask = Task { [weak self] in
            do {
                try await AudioStreamCache.fetchAhead(of: entry.asset, at: at, of: length, ahead: Self.fetchAhead, stallLimit: Self.stallLimit)
                // A player that did read on says so now (`resumeIfBytesArrived`), with no reopen.
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                guard !Task.isCancelled, let self, self.current === entry, self.isHeldForBytes else { return }
                PlaybackLog.warning("\(entry.item.id): stopped at \(String(format: "%.1f", at))s and the rest isn't coming", about: entry.item.trackID, error: error)
                self.stopHolding()
                self.failed(entry, error)
                return
            }
            guard let self, self.current === entry, self.isHeldForBytes else { return }
            self.onEvent?(self, .bytesArrivedWhileHeld(entry))
        }
    }

    /// Lets go of a hold that opening the item afresh can't help: it plays what it has to whatever
    /// end AVFoundation sees, and isn't held again.
    func letGo(of entry: DeckEntry) {
        entry.holdsForBytes = false
        guard entry === current, isHeldForBytes else { return }
        stopHolding()
        startPlayer()
    }

    private func holdIfRunningOut() {
        guard !isHeldForBytes, pendingSeek == nil, let entry = current, entry.holdsForBytes, entry.isStillArriving,
              entry.playerItem.status == .readyToPlay, player.timeControlStatus == .playing,
              loadedAhead(of: entry) < Self.holdMargin else { return }
        holdForBytes()
    }

    private func resumeIfBytesArrived() {
        guard isHeldForBytes, pendingSeek == nil, let entry = current, loadedAhead(of: entry) >= Self.resumeAhead else { return }
        PlaybackLog.info("\(entry.item.id): more has arrived [\(entry.loadedDescription)]; playing on from \(String(format: "%.1f", position))s", about: entry.item.trackID)
        stopHolding()
        startPlayer()
    }

    private func stopHolding() {
        holdTask?.cancel()
        holdTask = nil
        isHeldForBytes = false
    }

    /// Seconds loaded past the playhead; 0 when nothing is loaded there.
    private func loadedAhead(of entry: DeckEntry) -> TimeInterval {
        let now = entry.playerItem.currentTime().seconds
        return entry.playerItem.loadedTimeRanges.map(\.timeRangeValue).compactMap { range -> TimeInterval? in
            let end = range.end.seconds
            return range.start.seconds <= now + 0.1 && end > now ? end - now : nil
        }.max() ?? 0
    }

    var position: TimeInterval {
        if let pendingSeek { return pendingSeek }
        guard current != nil else { return 0 }
        let time = player.currentTime()
        return time.isNumeric && time.seconds.isFinite ? max(time.seconds, 0) : 0
    }

    var knownDuration: TimeInterval? { current?.duration }

    var isPlaying: Bool { player.timeControlStatus == .playing }

    var isWaiting: Bool { isHeldForBytes || player.timeControlStatus == .waitingToPlayAtSpecifiedRate }

    /// Loaded and buffered enough at its position to start at once — what arming waits for.
    var isReadyToPlay: Bool {
        guard let entry = current, pendingSeek == nil, failure == nil else { return false }
        let item = entry.playerItem
        guard item.status == .readyToPlay, item.isPlaybackLikelyToKeepUp || item.isPlaybackBufferFull else { return false }
        return !wantsPreroll || prerolled
    }

    /// Nothing loaded, or what was loaded failed (Media3's `STATE_IDLE`).
    var isIdle: Bool { current == nil || failure != nil }

    func setTransitionFilter(_ cutoffs: TransitionFilterCutoffs) {
        guard cutoffs != filter else { return }
        filter = cutoffs
        binding.processor?.setTransitionFilter(cutoffs)
    }

    var transitionFilter: TransitionFilterCutoffs { filter }

    private func updateActionAtItemEnd() {
        player.actionAtItemEnd = advancesAutomatically && queued != nil ? .advance : .pause
    }

    // MARK: - Observation

    private func currentItemChanged() {
        let now = player.currentItem
        guard now !== current?.playerItem else { return }
        if let queued, now === queued.playerItem, let previous = current {
            // The queue player advanced by itself.
            current = queued
            self.queued = nil
            hasEnded = false
            pendingSeek = nil
            forgetBuffering()
            unwatch(previous)
            updateActionAtItemEnd()
            onEvent?(self, .advanced(from: previous, to: queued))
        }
    }

    private func watch(_ entry: DeckEntry) {
        let key = ObjectIdentifier(entry.playerItem)
        itemObservations[key] = [
            entry.playerItem.observe(\.status, options: [.new]) { [weak self, weak entry] _, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, let entry else { return }
                        self.statusChanged(entry)
                    }
                }
            },
            // Bytes arriving while the player waits are what lets it start (see `startIfBuffered`).
            entry.playerItem.observe(\.loadedTimeRanges, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.startIfBuffered() } }
            },
        ]
        // Bytes arriving are what ends a hold.
        itemObservations[key]?.append(entry.playerItem.observe(\.loadedTimeRanges, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.resumeIfBytesArrived() } }
        })
        let center = NotificationCenter.default
        itemNotifications[key] = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: entry.playerItem, queue: .main) { [weak self, weak entry] _ in
                MainActor.assumeIsolated {
                    guard let self, let entry else { return }
                    self.playedToEnd(entry)
                }
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: entry.playerItem, queue: .main) { [weak self, weak entry] note in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                MainActor.assumeIsolated {
                    guard let self, let entry else { return }
                    self.failed(entry, error ?? entry.playerItem.error ?? PlaybackSourceError.noAudioTrack)
                }
            },
            center.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: entry.playerItem, queue: .main) { [weak self, weak entry] _ in
                MainActor.assumeIsolated {
                    guard let self, let entry else { return }
                    if entry === self.current { self.rebuffering = true }
                    self.onEvent?(self, .stalled(entry))
                }
            },
        ]
        if entry.playerItem.status != .unknown { statusChanged(entry) }
    }

    private func unwatch(_ entry: DeckEntry) {
        let key = ObjectIdentifier(entry.playerItem)
        itemObservations.removeValue(forKey: key)?.forEach { $0.invalidate() }
        itemNotifications.removeValue(forKey: key)?.forEach(NotificationCenter.default.removeObserver)
    }

    private func statusChanged(_ entry: DeckEntry) {
        guard entry === current || entry === queued else { return }
        switch entry.playerItem.status {
        case .readyToPlay:
            if entry === current {
                attemptPreroll()
                startIfBuffered()
            }
            onEvent?(self, .itemReady(entry))
        case .failed:
            failed(entry, entry.playerItem.error ?? PlaybackSourceError.noAudioTrack)
        default:
            break
        }
    }

    private func failed(_ entry: DeckEntry, _ error: Error) {
        guard entry === current || entry === queued else { return }
        if entry === current { failure = error }
        onEvent?(self, .itemFailed(entry, error))
    }

    private func playedToEnd(_ entry: DeckEntry) {
        guard entry === current else { return }
        // With a queued entry and automatic advance on, the queue player is already moving on and
        // `currentItemChanged` reports it; otherwise the deck has stopped at the end.
        if queued != nil, advancesAutomatically { return }
        hasEnded = true
        onEvent?(self, .endedWithoutAdvancing(entry))
    }
}
