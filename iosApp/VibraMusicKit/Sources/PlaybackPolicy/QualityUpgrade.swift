import Foundation
import VibraMusicCore

// Ports playback/QualityUpgrade.kt, with the pieces of data/sources/SourceResolver.kt and
// TrackMatcher.kt it decides with (worthSwapping, sameRecordingAs, isSevereMismatch, Target), and
// the session side of PlaybackService.upgradeQualityNow.

/// What the second look needs from the source layer.
///
/// Android's `SourceResolver.canSubstituteForYouTube` and `SourceResolver.upgradeFor`, minus the
/// policy: *whether* a stream is worth the break in the audio is decided here
/// (``QualityUpgrade/worthSwapping(_:over:)``) and handed to the search as `isWorthSwapping`, so the
/// Sources module only has to do the searching. The app wires the concrete implementation in.
public protocol QualityUpgradeSearching: Sendable {
    /// Whether any enabled source outranks YouTube right now — answerable from the source list
    /// alone, without a search. Read on the player's hot path (every progress sample), so it must be
    /// cheap and synchronous; keep a cached value.
    var canSubstituteForYouTube: Bool { get }

    /// A stream from a source ranked above YouTube for `target`, or nil if none exists.
    ///
    /// Contract, carried over from `upgradeFor`:
    /// - every ranked source is asked, including lossy ones, and they are raced rather than walked;
    ///   every module *within* a source is waited for (sound is already coming out, so there is time);
    /// - the source whose config id is `servedBy` is skipped: asked the same question again it can
    ///   only reproduce the stream already playing;
    /// - a match must share an artist credit and run within ``QualityUpgrade/sameRecordingToleranceSeconds``
    ///   of `target.durationSec` (always non-nil here): swapping audio mid-song is only defensible
    ///   for the same recording, and length is the check a title cannot fake;
    /// - the *first* stream for which `isWorthSwapping` returns true wins; refusals should be logged
    ///   (a silent skip reads exactly like a source having nothing).
    ///
    /// `playing` is the floor the track was marked with (resolved, or measured off the disk for a
    /// row nothing resolved): the search weighs candidates against it before proving any.
    ///
    /// Throw `CancellationError` (or let URLSession's cancellation propagate) when the calling task
    /// is cancelled; other errors mean the search itself failed and the question stays open.
    func findUpgrade(
        for target: QualityUpgrade.Target,
        playing: StreamFormat?,
        excluding servedBy: String?,
        isWorthSwapping: @escaping @Sendable (ResolvedStream) -> Bool
    ) async throws -> ResolvedStream?

    /// Drops the sources' completed answers, so the next search asks them again; running calls are
    /// left to be joined (Android `SourceRegistry.clearCompletedAddonTrackCalls`). A press of
    /// "Upgrade quality" means "ask now": an add-on whose upstream was briefly down answers "nothing"
    /// with a 200, and that answer is otherwise served again until it expires.
    func clearCompletedAnswers() async
}

/// The second look: a track that started on less than was asked for gets the question asked again,
/// properly, while it plays.
///
/// The live path has to answer in the time a listener will wait for a track to start, and it buys
/// that by giving up on the slow catalogue — regularly the one holding the lossless copy. Measured
/// on Android: the fastest module answered a search in 1.3 s, the slowest in 5.4 s plus a further
/// 8.2 s walking its fallback chain down to a 128 kbps MP3. Waiting for all of that costs 14 seconds
/// of silence; not waiting costs the FLAC. Neither trade has to be made once the search can happen
/// with sound already coming out.
///
/// So: play whatever can be had now, then look again with no time limit, and swap only if the answer
/// is genuinely the same recording *and* genuinely better than what is playing — usually the lossless
/// copy that was asked for, but also a 320 kbps stream against YouTube's ~160. The swap is not free
/// (there is a short break in the audio), which is why every guard here errs towards not doing it.
/// A missed upgrade is a quieter failure than an interrupted song.
///
/// ### How the swap reaches the player
///
/// The queue holds `vibramusic://watch?v=…` URIs that the player's resolver turns into real URLs at
/// open time (``PlaybackURI``). An upgrade re-points that indirection rather than touching the
/// queue: the stream is parked (``force(_:stream:)``), the item is replaced with the same URI plus a
/// `q=` marker (``upgradedURI(_:)``), and the marker does two jobs — it makes the item unequal to its
/// old self so the player actually rebuilds it, and it keys the disk cache separately
/// (``cacheTag(_:)``) so the FLAC is not written into the middle of the half-cached copy it replaces.
///
/// ### Lifetime
///
/// Everything here is scoped to the player. When the Playback engine is torn down and rebuilt within
/// one app process, call ``forgetLastSession()`` (and ``NerdStats/forgetLastSession()``) so a warm
/// restart behaves like a cold one.
///
/// Thread-safe; ``lookAgain(_:playingDurationSec:)`` is the only async entry point.
public final class QualityUpgrade: @unchecked Sendable {
    /// The recording being looked for, as much of it as the queue knows (Android's
    /// `TrackMatcher.Target`).
    public struct Target: Hashable, Sendable {
        public var title: String
        public var artist: String
        /// Runtime in whole seconds; nil when the queue row never carried one.
        public var durationSec: Int?
        /// Release name, when the queue knows it. Used to separate catalogue collisions.
        public var album: String?
        /// Explicit/clean edition; nil when the originating catalogue did not say.
        public var isExplicit: Bool?
        /// Music-video timing includes visual intros/outros that catalogue audio omits.
        public var isVideo: Bool

        public init(
            title: String,
            artist: String = "",
            durationSec: Int? = nil,
            album: String? = nil,
            isExplicit: Bool? = nil,
            isVideo: Bool = false
        ) {
            self.title = title
            self.artist = artist
            self.durationSec = durationSec
            self.album = album
            self.isExplicit = isExplicit
            self.isVideo = isVideo
        }

        /// The target a queued song describes (Android `TrackMatcher.targetOf`).
        public init(song: Song) {
            self.init(
                title: song.title,
                artist: song.artist,
                durationSec: PlaybackURI.durationSeconds(of: song),
                album: song.albumName,
                isExplicit: song.isExplicit,
                isVideo: song.isVideo
            )
        }

        func with(durationSec: Int?) -> Target {
            var copy = self
            copy.durationSec = durationSec
            return copy
        }
    }

    /// What a manual "Upgrade quality" request came to (Android `upgradeQualityNow`'s branches).
    public enum ManualUpgradeOutcome: Hashable, Sendable {
        /// A second look for this track is already running; the command is ignored and the cooldown
        /// is not charged.
        case alreadyRunning
        /// Asked too soon after the last accepted request.
        case coolingDown(remainingMs: Int64)
        /// The pin is cleared and the verdicts reopened; start the second look now.
        case accepted
    }

    // MARK: Constants

    /// The marker that distinguishes an upgraded item from the one it replaced.
    public static let marker = PlaybackURI.renditionParameter
    private static let upgraded = "hifi"
    /// What a revert tags its rendition with — see ``PlaybackURI/directYouTube(for:)``.
    private static let original = "original"

    /// How far a replacement's runtime may sit from the playing track's before it stops being the
    /// same recording (Android `SourceResolver.UPGRADE_DRIFT_SEC`). Far tighter than the matcher's
    /// own tolerance, deliberately: that one decides what to play, this one whether to cut the audio
    /// a listener is in the middle of. Two seconds allows for a service rounding differently.
    public static let sameRecordingToleranceSeconds = 2

    /// Past this, two tracks sharing a title are not sharing a recording (Android
    /// `TrackMatcher.DURATION_LIMIT_SEC`): wide enough for a fade a service trims differently,
    /// narrow enough to rule out an extended cut.
    public static let severeMismatchSeconds = 30

    /// How many kbps a lossy stream has to gain before it earns a seam in the audio (Android
    /// `UPGRADE_MIN_GAIN_KBPS`). Sized off YouTube's ~160 against a lossy module tier's 320;
    /// anything much smaller would fire on differences no one can hear.
    public static let minimumLossyGainKbps = 96

    /// The cooldown between accepted manual upgrade requests (Android `MANUAL_UPGRADE_COOLDOWN_MS`).
    public static let manualUpgradeCooldownMs: Int64 = 30_000

    // MARK: State

    /// A track playing on less than was asked for.
    private struct Pending {
        var target: Target
        /// The live lookup that lost the race rather than ran out of answers — still running, and
        /// worth waiting on rather than repeating, because whatever it returns is precisely the
        /// stream that would have played had it been quicker.
        var inFlight: Task<ResolvedStream?, Never>?
        /// What the listener is actually hearing — the yardstick a lossy candidate is measured
        /// against. Nil only when nothing could say; an unknown floor is one nothing lossy clears.
        var playing: StreamFormat?
        /// The source already serving this track, left out of the second look.
        var servedBy: String?
    }

    private struct State {
        var pending: [String: Pending] = [:]
        /// A second pass to make after a worthwhile *lossy* upgrade when lossless was asked for:
        /// JioSaavn's 320 can win the first pass while a slower FLAC source is still searching, so
        /// once it plays, ask again with its bitrate as the floor. Dolby Atmos is final.
        var followUps: [String: Pending] = [:]
        var forced: [String: ResolvedStream] = [:]
        /// Streams being *proved* rather than played — see ``beginAudition(_:)``.
        var auditioning: Set<String> = []
        /// Upgrades found, proved and cached that never got to happen because the queue moved on
        /// in the last moments before the swap — see ``shelve(_:stream:)``.
        var shelved: [String: ResolvedStream] = [:]
        /// Tracks whose upgrade broke the playback it was meant to improve. Lives exactly as long as
        /// the player that broke on it (``forgetLastSession()``).
        var refused: Set<String> = []
        /// Tracks that have had their second look, whatever it found. ``QualityUpgrade/lookAgain(_:playingDurationSec:)``
        /// empties `pending` as the question is asked, so without this a track asked about and a
        /// track never a candidate look identical — which is the whole difference for
        /// ``QualityUpgrade/adoptUnresolved(_:uri:target:playingMime:playing:)``, offered the same
        /// playing track every few seconds.
        var asked: Set<String> = []
        /// Tracks the listener has asked to upgrade themselves — the one exemption from the marker
        /// rule in ``QualityUpgrade/couldStillUpgrade(_:uri:)``; see ``QualityUpgrade/askByHand(_:)``.
        var handAsked: Set<String> = []
    }

    private let lock = NSLock()
    private var state = State()
    private let search: QualityUpgradeSearching
    private let requestForNow: @Sendable () -> StreamRequest
    private let streamChoice: StreamChoice
    private let nerdStats: NerdStats
    private let manualThrottle: ManualUpgradeThrottle

    /// - Parameters:
    ///   - search: the source layer (Sources' resolver, wired by the app).
    ///   - requestForNow: what the connection and settings currently add up to — usually
    ///     ``PlaybackQualityCeiling/currentRequest``. Decides whether a lossy upgrade earns a
    ///     lossless follow-up.
    public init(
        search: QualityUpgradeSearching,
        requestForNow: @escaping @Sendable () -> StreamRequest,
        streamChoice: StreamChoice = .shared,
        nerdStats: NerdStats = .shared,
        manualThrottle: ManualUpgradeThrottle = ManualUpgradeThrottle(cooldownMs: QualityUpgrade.manualUpgradeCooldownMs)
    ) {
        self.search = search
        self.requestForNow = requestForNow
        self.streamChoice = streamChoice
        self.nerdStats = nerdStats
        self.manualThrottle = manualThrottle
    }

    // MARK: Decisions (pure)

    /// Whether `candidate` is enough better than `playing` to be worth the break in the audio that
    /// swapping to it costs (Android `SourceResolver.worthSwapping`).
    ///
    /// Lossless always is: it is what was asked for. A lossy candidate has to clear
    /// ``minimumLossyGainKbps`` over what is playing — a wide gap on purpose, because bitrate
    /// compares poorly across codecs (Opus 160 and AAC 256 are much the same to listen to). 160 to
    /// 320 clears it; 128 to 192 does not. An unknown bitrate on either side is a no.
    public static func worthSwapping(_ candidate: StreamFormat, over playing: StreamFormat?) -> Bool {
        // Never away from an immersive mix. A FLAC is a better *copy* and a worse *mix* once Atmos is
        // what the listener chose; this also covers a late answer from a pass started before the
        // Atmos stream landed.
        if playing?.isDolbyAtmos == true && !candidate.isDolbyAtmos { return false }
        if candidate.isLossless == true || candidate.isDolbyAtmos { return true }
        guard let candidateKbps = candidate.kbps, let playingKbps = playing?.kbps else { return false }
        return candidateKbps - playingKbps >= minimumLossyGainKbps
    }

    /// Whether two runtimes are close enough to be the same recording, for a swap into a track that
    /// is already playing (Android `SourceResolver.sameRecordingAs`). Either side unknown is a no:
    /// an unverifiable length is not a length that agrees.
    public static func sameRecording(candidateSec: Int?, playingSec: Int?) -> Bool {
        guard let candidateSec, let playingSec else { return false }
        return abs(candidateSec - playingSec) <= sameRecordingToleranceSeconds
    }

    /// Whether two runtimes differ by more than ``severeMismatchSeconds``, meaning they cannot be the
    /// same recording (Android `TrackMatcher.isSevereMismatch`). Unknown on either side is not a
    /// mismatch.
    public static func isSevereMismatch(expectedSec: Int?, actualSec: Int?) -> Bool {
        guard let expectedSec, let actualSec else { return false }
        return abs(actualSec - expectedSec) > severeMismatchSeconds
    }

    /// The duration to match against during an upgrade.
    ///
    /// The decoder's runtime is the one measured figure and normally wins — but when it disagrees
    /// severely with the catalogue's (a 3:29 music video cached for a 5:02 album track), it is the
    /// wrong recording that is playing, and matching against it would reject the right one. The
    /// catalogue duration is kept then.
    public static func effectiveTargetDuration(expectedSec: Int?, playingSec: Int?) -> Int? {
        if let expectedSec, let playingSec, isSevereMismatch(expectedSec: expectedSec, actualSec: playingSec) {
            return expectedSec
        }
        return playingSec ?? expectedSec
    }

    /// The upgraded stream should be followed by a lossless pass: lossless is what the connection
    /// and settings add up to, and this stream is neither lossless nor the (final) Atmos tier.
    func needsLosslessFollowUp(_ format: StreamFormat) -> Bool {
        requestForNow().tier == .lossless && format.isLossless != true && !format.isDolbyAtmos
    }

    // MARK: Auditions

    /// Marks `mediaId`'s upgraded stream as being *proved* on a silent second player rather than
    /// played. The audition reads through the same resolver the real player does, where the format
    /// it promises would be recorded for the stats; for the length of an audition the listener is
    /// still hearing the old stream, and a "Lossless" badge over it would describe a swap that has
    /// not happened and might never.
    public func beginAudition(_ mediaId: String) {
        _ = lock.withLock { state.auditioning.insert(mediaId) }
    }

    public func endAudition(_ mediaId: String) {
        _ = lock.withLock { state.auditioning.remove(mediaId) }
    }

    /// Whether the fetch about to happen for `videoId` is an audition, not playback.
    public func isAuditioning(_ videoId: String?) -> Bool {
        guard let videoId else { return false }
        return lock.withLock { state.auditioning.contains(videoId) }
    }

    // MARK: Shelf

    /// Keeps a proved-but-unused upgrade for `mediaId` against a return visit.
    ///
    /// Measured on Android: a FLAC found in 10.1 s, proved in 2.0 s and cached in full, discarded
    /// because the listener skipped 254 ms before the swap. Held here, skipping back costs no
    /// search, no download, and an audition that reads from disk.
    public func shelve(_ mediaId: String, stream: ResolvedStream) {
        lock.withLock {
            state.shelved[mediaId] = stream
            // The answer was yes. Recording it as settled is what would stop couldStillUpgrade ever
            // offering the track again.
            state.asked.remove(mediaId)
        }
    }

    /// The upgrade already proved for `mediaId`, if one ran out of track.
    public func shelved(_ mediaId: String) -> ResolvedStream? {
        lock.withLock { state.shelved[mediaId] }
    }

    /// Takes `mediaId`'s upgrade off the shelf — it has happened. Without this the entry outlives
    /// the swap, is offered again on the next visit, the swap declines (the URI already carries the
    /// marker), and the decline is shelved afresh.
    public func unshelve(_ mediaId: String) {
        _ = lock.withLock { state.shelved.removeValue(forKey: mediaId) }
    }

    // MARK: Becoming a candidate

    /// Records that `mediaId` is playing on less than was asked for — a lossy stream a source
    /// handed over, or YouTube's own because nothing answered in time. Called from the resolver, the
    /// only place that knows both what was requested and what came back.
    ///
    /// The track stays in ``NerdStats/racingLossless`` from here until the second look finishes, so
    /// the player keeps saying "Upgrading quality" rather than going blank and then possibly
    /// changing its mind.
    ///
    /// Not gated on the request being lossless: a source ranked above YouTube can be worth swapping
    /// to on bitrate alone, and requiring lossless meant a lookup still running got cancelled the
    /// moment YouTube won, so a 320 kbps source never finished and never played.
    ///
    /// - Returns: true if the track is now pending. When false, `inFlight` has been cancelled.
    @discardableResult
    public func settledForLess(
        _ mediaId: String,
        target: Target,
        inFlight: Task<ResolvedStream?, Never>? = nil,
        playing: StreamFormat? = nil,
        servedBy: String? = nil
    ) -> Bool {
        let refused = lock.withLock { state.refused.contains(mediaId) }
        if target.title.trimmingCharacters(in: .whitespaces).isEmpty || target.isVideo || refused ||
            !search.canSubstituteForYouTube {
            inFlight?.cancel()
            return false
        }
        lock.withLock {
            state.pending[mediaId] = Pending(target: target, inFlight: inFlight, playing: playing, servedBy: servedBy)
        }
        nerdStats.onLosslessRaceStart(mediaId)
        TrackLog.d(
            Self.logCategory,
            inFlight != nil
                ? "'\(target.title)' started on the fallback; its lookup is still running"
                : "below request for '\(target.title)'; will look again during playback",
            about: mediaId
        )
        return true
    }

    /// Whether `mediaId` is worth a second look — and hasn't already had one.
    public func isPending(_ mediaId: String?) -> Bool {
        guard let mediaId else { return false }
        return lock.withLock { state.pending[mediaId] != nil }
    }

    /// Stops offering `mediaId` any further upgrades this session — its last one is what broke it.
    /// The search that produced it is deterministic: asked again, the same catalogue returns the
    /// same dead URL. Called from the recovery path.
    public func refuseUpgrades(_ mediaId: String) {
        _ = lock.withLock { state.refused.insert(mediaId) }
        TrackLog.d(Self.logCategory, "\(mediaId) broke on its upgrade; no more swaps for it", about: mediaId)
    }

    /// Whether `mediaId`, playing from `uri` without ever having been resolved, is worth
    /// *evaluating* for a second look. The cheap half of ``adoptUnresolved(_:uri:target:playingMime:playing:)``:
    /// asked on the main thread every progress sample, touches nothing but the queue entry and the
    /// settings.
    public func couldStillUpgrade(_ mediaId: String, uri: String?) -> Bool {
        guard let uri, PlaybackURI.queryValue(PlaybackURI.videoIdParameter, in: uri) != nil,
              PlaybackURI.queryValue(PlaybackURI.musicVideoParameter, in: uri) != "1" else { return false }
        let blocked: Bool = lock.withLock {
            // Already upgraded: this *is* the better copy. Except when the listener asked by hand,
            // where the marker is on a *reverted* item and "this is the copy that was chosen" is the
            // very thing being overruled.
            if !state.handAsked.contains(mediaId),
               PlaybackURI.queryValue(Self.marker, in: uri) != nil { return true }
            return state.asked.contains(mediaId) || state.refused.contains(mediaId) || state.pending[mediaId] != nil
        }
        if blocked { return false }
        // Same widening as settledForLess: a track playing off the cache is worth a second look
        // whenever anything outranks YouTube, not only when lossless was asked for.
        return search.canSubstituteForYouTube
    }

    /// Marks a track that is playing without ever having been resolved.
    ///
    /// ``settledForLess(_:target:inFlight:playing:servedBy:)`` is reached from the resolver, which a
    /// track playing off the disk cache never reaches: the cache serves bytes already on disk
    /// without a resolve. The tracks hit hardest are the ones restored into the queue at launch —
    /// their bytes were written by a previous process, so they would play at last session's bitrate
    /// for ever while a freshly queued copy of the same song upgraded within seconds.
    ///
    /// - Parameters:
    ///   - playingMime: what the *decoder* says about this track's bytes
    ///     (``MeasuredAudioFormat/mimeType``). The one thing worth not doing here is hunting a
    ///     lossless copy of a track already playing one — which is exactly what a cache entry
    ///     written by a previous session's successful upgrade holds.
    ///   - playing: how good those bytes are, measured off the decoder or the cache entry's size.
    ///     This used to be hardcoded nil ("an unknown floor is conservative"). It is not
    ///     conservative: it is a floor nothing lossy clears, and it quietly narrowed the path to
    ///     lossless-only — a 320 kbps AAC found three times over and refused each time on
    ///     `playing?.kbps ?? return false`.
    /// - Returns: true if the track is now pending, i.e. worth calling ``lookAgain(_:playingDurationSec:)`` for.
    @discardableResult
    public func adoptUnresolved(
        _ mediaId: String,
        uri: String,
        target: Target,
        playingMime: String?,
        playing: StreamFormat?
    ) -> Bool {
        guard couldStillUpgrade(mediaId, uri: uri) else { return false }
        // `asked` is set only on the two *verdicts* below, not on adoption: pending keeps
        // couldStillUpgrade off an adopted track for exactly as long as the question is open, and
        // marking it answered before it was asked is what made a skip permanent.
        if NerdStats.isLosslessMime(playingMime) {
            _ = lock.withLock { state.asked.insert(mediaId) }
            // The codec is named because this line is a dead end, and without it a correct verdict
            // can't be told from one reached on the previous track's format.
            TrackLog.d(
                Self.logCategory,
                "'\(target.title)' is already playing \(playingMime ?? "") from cache; no second look needed",
                about: mediaId
            )
            return false
        }
        if target.title.trimmingCharacters(in: .whitespaces).isEmpty {
            _ = lock.withLock { state.asked.insert(mediaId) }
            return false
        }
        lock.withLock {
            state.pending[mediaId] = Pending(target: target, inFlight: nil, playing: playing, servedBy: nil)
        }
        nerdStats.onLosslessRaceStart(mediaId)
        TrackLog.d(
            Self.logCategory,
            "'\(target.title)' is playing \(playing?.summary ?? "an unmeasured stream") from cache "
                + "and was never resolved; looking for a better copy",
            about: mediaId
        )
        return true
    }

    // MARK: The second look

    /// Looks for a stream that actually satisfies the request, for a track already playing.
    ///
    /// The track stays in ``NerdStats/racingLossless`` when this returns a stream — the caller ends
    /// it (``NerdStats/onLosslessRaceEnd(_:)``) once the swap has landed or been given up on. The
    /// badge describes the *upgrade*, not the search, and the search now often finishes before the
    /// track it was for comes round.
    ///
    /// If the calling task is cancelled (the queue moved on), nothing is learned: the track stays
    /// pending and is asked about again if the listener comes back to it. That was the single
    /// biggest hole in the Android feature — two seconds on another track recorded a search that
    /// never finished as a settled "nothing better exists".
    ///
    /// - Parameter playingDurationSec: the runtime the *decoder* reports — the one thing here that
    ///   is measured rather than claimed. Candidates have to match it (or the catalogue's, when the
    ///   two disagree severely; see ``effectiveTargetDuration(expectedSec:playingSec:)``).
    /// - Returns: the better stream, or nil — in which case, unless cancelled, this track is not
    ///   asked about again this play.
    public func lookAgain(_ mediaId: String, playingDurationSec: Int?) async -> ResolvedStream? {
        guard let waiting = lock.withLock({ state.pending[mediaId] }) else { return nil }
        let expectedSec = waiting.target.durationSec
        let effectiveSec = Self.effectiveTargetDuration(expectedSec: expectedSec, playingSec: playingDurationSec)
        if Self.isSevereMismatch(expectedSec: expectedSec, actualSec: playingDurationSec) {
            TrackLog.w(
                Self.logCategory,
                "playing duration (\(playingDurationSec ?? 0) s) drifted severely from catalogue duration "
                    + "(\(expectedSec ?? 0) s); preserving catalogue duration for upgrade",
                about: mediaId
            )
        }
        let target = waiting.target.with(durationSec: effectiveSec)
        let playing = waiting.playing

        // The lookup still running when the fallback won the race gets first refusal: what it
        // returns is the stream that would have played with no seam at all. It is not taken on
        // trust, though — its match was made against a runtime *claimed* by whoever queued the
        // track, and cutting into a track already playing is a stricter question. Measured on
        // Android: a 189-second cut swapped into a 163-second song.
        if let lookup = waiting.inFlight {
            let late = await awaitUnlessCancelled(lookup)
            if Task.isCancelled { return notAnswered(mediaId) }
            if let late, Self.worthSwapping(late.format, over: playing),
               Self.sameRecording(candidateSec: late.durationSeconds, playingSec: effectiveSec) {
                return answered(mediaId, with: late, target: target)
            }
            // Named, as Android names it: the live lookup logged its find, so a refusal that said
            // nothing would read as a swap that happened.
            if let late {
                let lateLength = late.durationSeconds.map { String($0) } ?? "?"
                let playingLength = effectiveSec.map { String($0) } ?? "?"
                TrackLog.d(
                    Self.logCategory,
                    "'\(target.title)': the live lookup's \(late.format.summary) (\(lateLength) s against \(playingLength) s playing) "
                        + "isn't worth swapping to; searching again",
                    about: mediaId
                )
            }
        }
        if Task.isCancelled { return notAnswered(mediaId) }

        // `upgradeFor`'s own preconditions: no search without a title, without a length to check
        // candidates against, or for a music video.
        if target.title.trimmingCharacters(in: .whitespaces).isEmpty || target.durationSec == nil || target.isVideo {
            return answered(mediaId, with: nil, target: target)
        }

        // The lookup finished with nothing better, so the question is asked again from scratch —
        // this time waiting on every module, which is what the live path could not afford.
        do {
            let found = try await search.findUpgrade(
                for: target,
                playing: playing,
                excluding: waiting.servedBy,
                isWorthSwapping: { Self.worthSwapping($0.format, over: playing) }
            )
            if Task.isCancelled { return notAnswered(mediaId) }
            return answered(mediaId, with: found, target: target)
        } catch is CancellationError {
            return notAnswered(mediaId)
        } catch {
            if Task.isCancelled { return notAnswered(mediaId) }
            // The search itself failed (no network, a source crashed). That is not an answer about
            // this track either, so it stays open for the next look.
            TrackLog.w(Self.logCategory, "second look for '\(target.title)' failed", error: error, about: mediaId)
            return notAnswered(mediaId)
        }
    }

    /// Records a verdict: the question has been asked, whatever the answer. Leaving it pending would
    /// re-run the whole search on every pause and resume, and leaving it out of `asked` would let
    /// adoptUnresolved offer it again at the next progress sample. Only a *no* ends the race here.
    private func answered(_ mediaId: String, with found: ResolvedStream?, target: Target) -> ResolvedStream? {
        let followUp = found.flatMap { stream -> Pending? in
            guard needsLosslessFollowUp(stream.format) else { return nil }
            return Pending(target: target, inFlight: nil, playing: stream.format, servedBy: stream.sourceConfigId)
        }
        lock.withLock {
            state.pending[mediaId] = nil
            state.asked.insert(mediaId)
            if let followUp { state.followUps[mediaId] = followUp }
        }
        if found == nil { nerdStats.onLosslessRaceEnd(mediaId) }
        return found
    }

    /// The search was cancelled on its way to an answer: the track is left exactly as it was found,
    /// still pending, and only the badge goes out.
    private func notAnswered(_ mediaId: String) -> ResolvedStream? {
        nerdStats.onLosslessRaceEnd(mediaId)
        return nil
    }

    /// A fresh play of `mediaId` has begun — re-open a verdict that no longer describes what is
    /// playing.
    ///
    /// `asked` is scoped to one playback, and nothing enforced that: playing the same song twice in
    /// one session read the *base* cache entry (YouTube's copy) the second time, and was refused a
    /// second look on the strength of a yes about the upgraded copy it was no longer playing.
    ///
    /// Guarded on the marker: an item that *is* the upgraded copy, or a hand-reverted
    /// `q=original`, is excluded by couldStillUpgrade on its own terms, and re-opening those would
    /// have the swap that just happened looked for again. This is a transition, not a progress
    /// sample, so pausing and resuming does not come through here.
    ///
    /// - Parameter rendition: the item's marker, via ``cacheTag(_:)`` — nil for an ordinary entry.
    public func onPlaybackStarted(_ mediaId: String, rendition: String?) {
        guard rendition == nil else { return }
        _ = lock.withLock { state.asked.remove(mediaId) }
    }

    /// Whether `mediaId` is *known* to be playing YouTube's own copy, so the player menu should
    /// offer to upgrade it rather than to revert it. See the static overload.
    public func isKnownToBePlayingYouTubesOwn(_ mediaId: String, rendition: String?) -> Bool {
        Self.isKnownToBePlayingYouTubesOwn(mediaId, rendition: rendition, streamChoice: streamChoice)
    }

    /// Whether `mediaId` is *known* to be playing YouTube's own copy.
    ///
    /// Both halves are required, and each rules out a different wrong answer:
    /// - **No upgrade marker on the item.** ``StreamChoice`` records the copy the *first* resolve
    ///   settled on and is not cleared when an upgrade swaps a better one in, so on an upgraded
    ///   track it still names YouTube — and that track is exactly the one that should keep "Revert".
    /// - **A recorded choice that is not a substitute.** None means nothing resolved this track in
    ///   this process — it is playing off the disk cache, contents genuinely unknown — and "Revert"
    ///   stays on offer as the escape hatch for a substitution nothing announced.
    public static func isKnownToBePlayingYouTubesOwn(
        _ mediaId: String,
        rendition: String?,
        streamChoice: StreamChoice = .shared
    ) -> Bool {
        guard rendition == nil else { return false }
        return streamChoice.stream(for: mediaId) != nil && !streamChoice.isSubstitute(mediaId)
    }

    /// Test seam: whether `mediaId` has had its second look this play.
    func hasAnswered(_ mediaId: String) -> Bool {
        lock.withLock { state.asked.contains(mediaId) }
    }

    /// Test seam: puts `mediaId` in the state a completed second look leaves it.
    func markAnsweredForTest(_ mediaId: String) {
        _ = lock.withLock { state.asked.insert(mediaId) }
    }

    /// Abandons the second look for `mediaId` — the queue has moved on. Cancels any lookup it held.
    public func forget(_ mediaId: String) {
        let (pending, followUp): (Pending?, Pending?) = lock.withLock {
            let pending = state.pending.removeValue(forKey: mediaId)
            let followUp = state.followUps.removeValue(forKey: mediaId)
            state.forced[mediaId] = nil
            state.shelved[mediaId] = nil
            state.auditioning.remove(mediaId)
            // A request made by hand is about the track the listener was listening to. Once the
            // queue has moved off it there is nothing left to honour.
            state.handAsked.remove(mediaId)
            return (pending, followUp)
        }
        pending?.inFlight?.cancel()
        followUp?.inFlight?.cancel()
        nerdStats.onLosslessRaceEnd(mediaId)
    }

    /// The queue moved off `mediaId`: its lookups stop, but an open question stays open and a
    /// shelved copy stays shelved, for a return visit. Coming back to a row whose opened audio the
    /// player still holds resolves nothing, so nothing else would ask again — this is the promise
    /// ``lookAgain(_:playingDurationSec:)`` makes about a cancelled search.
    public func setAside(_ mediaId: String) {
        let (inFlight, followUp): (Task<ResolvedStream?, Never>?, Pending?) = lock.withLock {
            let inFlight = state.pending[mediaId]?.inFlight
            state.pending[mediaId]?.inFlight = nil
            let followUp = state.followUps.removeValue(forKey: mediaId)
            state.forced[mediaId] = nil
            state.auditioning.remove(mediaId)
            state.handAsked.remove(mediaId)
            return (inFlight, followUp)
        }
        inFlight?.cancel()
        followUp?.inFlight?.cancel()
        nerdStats.onLosslessRaceEnd(mediaId)
    }

    /// Re-opens the upgrade question for `mediaId` because the listener asked (the player menu's
    /// "Upgrade quality"). Both sets this clears hold a *no* that is right for the automatic path
    /// and does not survive being contradicted by the listener. A lookup already in flight is left
    /// alone: it is the answer being waited for, not a stale one.
    public func askByHand(_ mediaId: String) {
        lock.withLock {
            state.handAsked.insert(mediaId)
            state.asked.remove(mediaId)
            state.refused.remove(mediaId)
        }
    }

    /// The session side of "Upgrade quality" (Android `PlaybackService.upgradeQualityNow`).
    ///
    /// Ignored without charging the cooldown when this track's upgrade is already running (the UI
    /// disables the row too, but this is the authoritative boundary for controllers like CarPlay).
    /// Otherwise throttled to one accepted request per ``manualUpgradeCooldownMs``; when accepted,
    /// the track is unpinned from its original, its verdicts are reopened (``askByHand(_:)``), and
    /// the caller should drop any completed addon answers for it and start the second look.
    ///
    /// Nothing is replaced: the item is left playing and the search runs under it, so the listener
    /// hears one cut — for the change they asked for — instead of a pointless restart first.
    ///
    /// - Parameters:
    ///   - nowMs: a monotonic clock in milliseconds.
    ///   - upgradeRunning: whether the player's own upgrade job for this track is active.
    public func requestByHand(
        _ mediaId: String,
        nowMs: Int64,
        upgradeRunning: Bool,
        originalVersion: OriginalVersion = .shared
    ) -> ManualUpgradeOutcome {
        if nerdStats.isRacing(mediaId) || upgradeRunning {
            TrackLog.d(Self.logCategory, "manual upgrade ignored for \(mediaId): upgrade already running", about: mediaId)
            return .alreadyRunning
        }
        let remaining = manualThrottle.tryAcquire(nowMs: nowMs)
        if remaining > 0 {
            TrackLog.d(Self.logCategory, "manual upgrade ignored for \(mediaId): \(remaining)ms cooldown remaining", about: mediaId)
            return .coolingDown(remainingMs: remaining)
        }
        originalVersion.unpin(mediaId)
        askByHand(mediaId)
        TrackLog.d(Self.logCategory, "upgrade asked for by hand for \(mediaId)", about: mediaId)
        return .accepted
    }

    /// The sources' completed answers, dropped ahead of a look the listener asked for (see
    /// ``QualityUpgradeSearching/clearCompletedAnswers()``).
    public func clearCompletedAnswers() async {
        await search.clearCompletedAnswers()
    }

    // MARK: The ceiling

    /// Whether the ceiling in force still pays for `stream`'s source (Android
    /// `SourceRegistry.permitsForPlayback`). A stream found or shelved under a higher ceiling (on
    /// Wi-Fi, before the listener left the house) is asked again where it would be warmed and where
    /// it would be swapped in. A stream no source kind serves (a file, a share) is a yes, as is
    /// YouTube's, which every rung permits.
    public func permitsForPlayback(_ stream: ResolvedStream) -> Bool {
        guard let kind = stream.origin.sourceKind else { return true }
        return requestForNow().permits(kind)
    }

    /// The ceiling was lowered (Android `QualityUpgrade.onCeilingLowered`):
    /// - a live lookup still running for a pending track was started against sources the new
    ///   ceiling may not pay for; it is cancelled and the track left pending, so the next look asks
    ///   afresh;
    /// - follow-ups only ever chase a lossless copy, which a lowered ceiling no longer asks for;
    /// - a shelved or forced stream from a source the ceiling now skips is dropped, except a forced
    ///   one in `keep`: the copy the player is reading, which plays out.
    public func onCeilingLowered(keep: Set<String>, permitted: (ResolvedStream) -> Bool) {
        let (lookups, followUps): ([Task<ResolvedStream?, Never>], [Pending]) = lock.withLock {
            let lookups = state.pending.values.compactMap(\.inFlight)
            for id in state.pending.keys { state.pending[id]?.inFlight = nil }
            let followUps = Array(state.followUps.values)
            state.followUps.removeAll()
            state.shelved = state.shelved.filter { permitted($0.value) }
            state.forced = state.forced.filter { keep.contains($0.key) || permitted($0.value) }
            return (lookups, followUps)
        }
        lookups.forEach { $0.cancel() }
        followUps.forEach { $0.inFlight?.cancel() }
    }

    /// Abandons the second look for every track at once, because the player all of it was about is
    /// gone. Makes a warm restart of the Playback engine behave like a cold one: on Android a
    /// surviving process kept `asked` from last session's *successful* upgrade and refused the same
    /// track its second look for ever after.
    ///
    /// ``StreamChoice`` is deliberately not reset: it records which source is filling each on-disk
    /// cache entry, and those entries outlive the player.
    public func forgetLastSession() {
        let ids: Set<String> = lock.withLock {
            Set(state.pending.keys)
                .union(state.followUps.keys)
                .union(state.forced.keys)
                .union(state.shelved.keys)
                .union(state.auditioning)
        }
        // Via forget, so a live lookup is torn down properly and its badge goes out with it.
        ids.forEach(forget)
        lock.withLock {
            state.asked.removeAll()
            state.refused.removeAll()
        }
    }

    // MARK: Handing the stream to the player

    /// Parks `stream` for `mediaId`, to be picked up when the item is reopened.
    public func force(_ mediaId: String, stream: ResolvedStream) {
        lock.withLock { state.forced[mediaId] = stream }
    }

    /// Re-arms the lossless pass only after a lossy stream has actually swapped in. A failed
    /// audition must leave the original search as the last word rather than trigger a second
    /// interruption attempt.
    @discardableResult
    public func continueAfterLossySwap(_ mediaId: String) -> Bool {
        let rearmed: Bool = lock.withLock {
            guard let next = state.followUps.removeValue(forKey: mediaId) else { return false }
            state.pending[mediaId] = next
            state.asked.remove(mediaId)
            return true
        }
        if rearmed { nerdStats.onLosslessRaceStart(mediaId) }
        return rearmed
    }

    /// The upgraded stream for a playback URI carrying an upgrade marker, or nil.
    ///
    /// Read rather than consumed: a player reopens a source more than once over a track's life (a
    /// seek past the buffer, a resume, a cache miss) and each has to arrive at the same bytes.
    public func forcedStream(_ uri: String) -> ResolvedStream? {
        guard PlaybackURI.queryValue(Self.marker, in: uri)?.hasPrefix(Self.upgraded) == true,
              let videoId = PlaybackURI.queryValue(PlaybackURI.videoIdParameter, in: uri) else { return nil }
        return lock.withLock { state.forced[videoId] }
    }

    /// The same URI, marked so the player rebuilds it and each upgrade gets its own cache entry:
    /// `q=hifi`, then `q=hifi-2`, `q=hifi-3`…
    ///
    /// Replaces rather than duplicates the marker (the first duplicate wins on lookup, which would
    /// send the second stream back into the first upgrade's cache entry). A revert's `original` is
    /// not a generation to count from — read as one, the first swap after a revert came out as
    /// `hifi-2`, which the player refuses, so the lossless pass could never run. And
    /// `direct_youtube=1` is dropped: a reverted item says "this exact YouTube rendition", which the
    /// resolver honours before it looks for a forced stream, so an upgrade built on it would cut the
    /// audio and hand back the very copy it was replacing (see ``askByHand(_:)``).
    public static func upgradedURI(_ uri: String) -> String {
        let markerStart = "&\(marker)="
        let previousRaw = String(uri.after(markerStart, missing: "").before("&"))
        let previous: String? = previousRaw.trimmingCharacters(in: .whitespaces).isEmpty || previousRaw == original
            ? nil
            : previousRaw
        let previousGeneration = previous.flatMap { value -> Int? in
            let stripped = value.hasPrefix("\(upgraded)-") ? String(value.dropFirst(upgraded.count + 1)) : value
            return Int(stripped)
        } ?? 1
        let tag = previous == nil ? upgraded : "\(upgraded)-\(previousGeneration + 1)"
        return String(uri.before(markerStart))
            .replacingOccurrences(of: "&\(PlaybackURI.directYouTubeParameter)=1", with: "")
            + "\(markerStart)\(tag)"
    }

    /// The rendition suffix that keeps an upgraded track's bytes off the copy it replaced (the
    /// AudioCache key factory appends it), or nil for an ordinary entry.
    public static func cacheTag(_ uri: String) -> String? {
        PlaybackURI.queryValue(marker, in: uri)
    }

    static let logCategory = "PlaybackPolicy"
}
