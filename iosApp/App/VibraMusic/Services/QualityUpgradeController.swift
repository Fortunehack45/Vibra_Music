import AudioCache
import AVFoundation
import VibraMusicCore
import Foundation
import Observation
import Playback
import PlaybackPolicy
import Sources

// Ports the session side of the quality upgrade in PlaybackService.kt (`lookForBetterCopy`,
// `swapPointFor`, `auditionUpgrade`, `watchUpgrade`, `upgradeQualityNow`): a track that started
// on less than was asked for — YouTube's AAC because the lossless source was still searching —
// gets the question asked again while it plays, and swaps to the better copy if one turns up.

/// Where the playing track's quality upgrade stands, for the Now Playing badge.
struct QualityUpgradeStatus: Hashable {
    enum Phase: Hashable {
        /// A better copy is being looked for ("Upgrading quality").
        case searching
        /// One was found and is being opened silently before the audio is touched.
        case proving(StreamFormat)
        /// The track now plays the better copy.
        case upgraded(from: StreamFormat?, to: StreamFormat)
        /// Nothing better exists (or the one found didn't hold up); the track stays as it is.
        case unavailable
    }

    var videoId: String
    var phase: Phase

    /// Whether the badge should read "Upgrading quality".
    var isUpgrading: Bool {
        switch phase {
        case .searching, .proving: return true
        case .upgraded, .unavailable: return false
        }
    }
}

/// What a manual "Upgrade quality" press came to.
enum ManualUpgradeResult: Hashable {
    /// The second look is running.
    case searching
    /// This track's upgrade was already running; nothing changed.
    case alreadyRunning
    /// Pressed again within 30 s of the last accepted press.
    case coolingDown(remainingMs: Int64)
    /// Nothing outranks YouTube to search: the caller reopens the track instead.
    case nothingToSearch
}

/// Sources' `upgradeFor` behind PlaybackPolicy's search protocol.
///
/// `upgradeFor` applies its own worth-swapping bar against the floor the policy hands over (as
/// Android's `lookAgain` passes `waiting.playing`), and the policy's own verdict is applied to the
/// answer as well.
final class SourceUpgradeSearch: QualityUpgradeSearching, @unchecked Sendable {
    private let resolver: SourceResolver
    private let registry: SourceRegistry
    private let request: @Sendable () -> StreamRequest

    init(resolver: SourceResolver, registry: SourceRegistry, request: @escaping @Sendable () -> StreamRequest) {
        self.resolver = resolver
        self.registry = registry
        self.request = request
    }

    func clearCompletedAnswers() async {
        await registry.clearCompletedTrackCalls()
    }

    var canSubstituteForYouTube: Bool { resolver.canSubstituteForYouTube(request()) }

    /// The sources' lookup for `videoId` that lost the start's race to YouTube and is still running:
    /// the second look takes its answer before searching again (Android `DirectSourceGate.startedOnYouTube`).
    func lookupStillRunning(for videoId: String) -> Task<ResolvedStream?, Never>? {
        resolver.takeStillLooking(videoId)
    }

    func findUpgrade(
        for target: QualityUpgrade.Target,
        playing format: StreamFormat?,
        excluding servedBy: String?,
        isWorthSwapping: @escaping @Sendable (ResolvedStream) -> Bool
    ) async throws -> ResolvedStream? {
        let matcherTarget = TrackMatcher.Target(target.title, target.artist, durationSec: target.durationSec, album: target.album,
                                                isExplicit: target.isExplicit, isVideo: target.isVideo)
        guard let found = try await resolver.upgradeFor(matcherTarget, playing: format, servedBy: servedBy, request: request()) else { return nil }
        return isWorthSwapping(found) ? found : nil
    }
}

/// Runs the second look for the playing track and swaps the better copy in.
///
/// One upgrade per play, plus at most one lossless follow-up after a lossy win (JioSaavn's 320
/// first, then the slower FLAC): the rendition tags are `hifi`, then `hifi-2`, and nothing after.
/// Before a note of the playing stream is touched the found copy is opened silently and its length
/// checked against the one playing (the listener's upgrade-length slack); after the swap the new
/// copy is watched the same way and the old one put back if it disagrees.
@MainActor
@Observable
final class QualityUpgradeController {
    /// The playing track's upgrade, or nil when none was ever in question.
    private(set) var status: QualityUpgradeStatus?

    @ObservationIgnored let upgrade: QualityUpgrade
    @ObservationIgnored weak var player: PlayerController?
    @ObservationIgnored private let search: SourceUpgradeSearch?
    @ObservationIgnored private let nerdStats: NerdStats
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let isPinned: (String) -> Bool
    /// Opens a stream silently and answers its length in seconds, or nil if it wouldn't open.
    @ObservationIgnored private let prove: @MainActor (Song, ResolvedStream, String) async -> TimeInterval?
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var jobVideoId: String?
    /// The copy the running look has in hand and hasn't swapped in yet, so a lowered ceiling can
    /// tell one it still allows from one it doesn't (``follow(_:)``).
    @ObservationIgnored private var candidate: ResolvedStream?
    /// The ceiling ``follow(_:)`` last saw.
    @ObservationIgnored private var ceilingInForce: AudioQuality?
    /// Reads the ceiling again at every change of connection.
    @ObservationIgnored private var connectionWatch: Task<Void, Never>?
    /// The least of the track left for a swap to go ahead; see ``roomToSwap(length:)``.
    @ObservationIgnored private let minRemaining: TimeInterval
    @ObservationIgnored private let proofClock: ProofClock
    /// The monotonic clock the manual throttle counts in.
    @ObservationIgnored private let nowMs: () -> Int64

    /// How long a proof may take before the upgrade is let go (Android `UPGRADE_AUDITION_MS`),
    /// unless its copy is still arriving faster than it plays (see ``proof(of:stream:tag:against:)``).
    static let proveTimeout: Duration = .seconds(20)
    /// How often a proof past ``proveTimeout`` looks at how much of its copy has arrived.
    static let proveCheck: Duration = .seconds(1)
    /// How long a proof past ``proveTimeout`` goes on with nothing new arriving: longer than a
    /// segment takes at the rate it plays, so only a fetch that has stopped (a dropped connection
    /// whose retry never lands) trips it.
    static let proveStall: Duration = .seconds(10)
    /// The longest any proof runs, however its copy is arriving: past it the track has mostly
    /// played without the copy.
    static let proveCeiling: Duration = .seconds(120)

    /// The proof's clock: ``proveTimeout``, ``proveCheck``, ``proveStall`` and ``proveCeiling``. A test
    /// runs the same rules on a shorter one rather than waiting out real minutes.
    struct ProofClock: Sendable {
        var timeout: Duration
        var check: Duration
        var stall: Duration
        var ceiling: Duration
    }
    static let standardProof = ProofClock(timeout: proveTimeout, check: proveCheck, stall: proveStall, ceiling: proveCeiling)
    /// How much of the track must be left for a swap to be worth its fetch (Android
    /// `UPGRADE_MIN_REMAINING_MS`).
    static let minRemaining: TimeInterval = 20
    /// How long a swap can hold the standby deck: the engine's crossover deadline (8 s) and a margin.
    /// A crossfade or Automix due meanwhile is held back by the engine, so it has to start after.
    static let swapHold: TimeInterval = 10
    /// How long a resolved row's second look waits for the decoder's length before it searches with
    /// the catalogue's: an ordinary start reports within it, a slow one doesn't hold the search.
    static let decoderGrace: Duration = .seconds(2)
    /// The longest anything waits for the decoder's length: a cached row's adoption, and the proof.
    static let decoderWait: Duration = .seconds(10)
    /// How long the swapped-in copy has to report a length that agrees (Android `UPGRADE_PROVE_MS`).
    static let watchTimeout: Duration = .seconds(10)
    /// How long the engine's crossover may take to land: its own 8 s deadline, the copy's open
    /// and the wait for it to sound.
    static let swapTimeout: Duration = .seconds(15)
    /// The longest a swap waits on a crossfade in flight (Android `UPGRADE_CROSSFADE_WAIT_TIMEOUT_MS`):
    /// well past any transition the engine plans, so it only ever binds on something stuck.
    static let crossfadeWait: Duration = .seconds(20)
    /// How often the wait looks at whether the crossfade has ended (Android `UPGRADE_CROSSFADE_POLL_MS`).
    static let crossfadePoll: Duration = .milliseconds(250)
    /// How long a crossfade must have been over before a swap may cut into the track it handed to
    /// (Android `UPGRADE_AFTER_CROSSFADE_MS`): the mix lands, then the music doesn't stop for the swap.
    static let afterCrossfade: TimeInterval = 5

    /// Whether a crossfade is in flight, and how long ago the last one ended.
    struct CrossfadeReading: Equatable {
        var isRunning: Bool
        var sinceEnded: TimeInterval?
    }

    init(
        upgrade: QualityUpgrade,
        search: SourceUpgradeSearch? = nil,
        nerdStats: NerdStats = .shared,
        settings: AppSettings,
        isPinned: @escaping (String) -> Bool = { OriginalVersion.shared.isPinned($0) },
        nowMs: @escaping () -> Int64 = { Int64(ProcessInfo.processInfo.systemUptime * 1_000) },
        minRemaining: TimeInterval = QualityUpgradeController.minRemaining,
        proofClock: ProofClock = QualityUpgradeController.standardProof,
        prove: (@MainActor (Song, ResolvedStream, String) async -> TimeInterval?)? = nil,
        crossfade: (@MainActor () -> CrossfadeReading)? = nil
    ) {
        self.upgrade = upgrade
        self.search = search
        self.nerdStats = nerdStats
        self.settings = settings
        self.isPinned = isPinned
        self.nowMs = nowMs
        self.minRemaining = minRemaining
        self.proofClock = proofClock
        self.prove = prove ?? { _, _, _ in nil }
        if prove == nil { usesDefaultProof = true }
        self.crossfadeOverride = crossfade
    }

    /// Stands in for the engine's crossfade state, for a test that cannot run a real blend.
    @ObservationIgnored private let crossfadeOverride: (@MainActor () -> CrossfadeReading)?

    @ObservationIgnored private var usesDefaultProof = false

    // MARK: Player hooks

    /// The playing row's stream resolved. A stream that came back below the request (a ranked
    /// source was still searching when YouTube answered) makes the track a candidate.
    func streamResolved(_ stream: ResolvedStream, for song: Song) {
        // A copy the row was forced onto (an upgrade landing) is not the row resolving afresh.
        guard player?.sources.forcedStream(for: song) == nil else { return }
        guard stream.belowRequest, !song.isVideo, !isPinned(song.videoId) else {
            // A fresh copy that already meets the request settles whatever an earlier visit left
            // open (``setAside(_:)`` keeps it), so no stale second look cuts into a track that
            // needs none.
            forget(song)
            return
        }
        let target = QualityUpgrade.Target(song: song)
        // The lookup that lost the race is waited on rather than repeated: its answer is the copy
        // that would have played had it been quicker. A press still searches afresh.
        let inFlight = search?.lookupStillRunning(for: song.videoId)
        guard upgrade.settledForLess(song.videoId, target: target, inFlight: inFlight, playing: stream.format,
                                     servedBy: stream.sourceConfigId) else { return }
        start(for: song, playing: stream.format, generation: 1)
    }

    /// A new track (or a repeat) started: the previous one's search is abandoned, and a fresh
    /// play of this one may be looked at again.
    func trackStarted(_ song: Song, previous: Song?) {
        if let previous, previous.videoId != song.videoId { setAside(previous) }
        upgrade.onPlaybackStarted(song.videoId, rendition: player?.sources.renditionTag(for: song))
        if status?.videoId != song.videoId { status = nil }
    }

    /// Offers the playing track a second look if it is eligible — Android's `lookForBetterCopy`.
    ///
    /// A track served straight from the disk cache never reaches the resolver, so nothing has marked
    /// it for a second look: it plays because the bytes were already on disk, and the second look
    /// would otherwise only ever happen for a track that was resolved. This is that path, run from
    /// the three moments Android ran it from — track start, playback start, and the progress sample
    /// (five seconds there; every engine checkpoint here) as the backstop for a row that was not
    /// eligible yet when its track became current.
    ///
    /// Cheap and idempotent on purpose: the pending test comes first, a job already hunting this
    /// track is left alone, and the cached-track decision does not touch the cache at all — only the
    /// job that follows, once the decoder has reported the item, does.
    func lookForBetterCopy() {
        guard let player, let song = player.currentSong else { return }
        if job != nil, jobVideoId == song.videoId { return }
        // Nothing found now could be swapped in: the question waits for a replay, rather than
        // being searched for, or a shelved copy proved and shelved again, at every checkpoint.
        guard roomToSwap(length: player.engine.duration) else { return }
        // Back on a row whose better copy was found on an earlier visit: the row plays its ordinary
        // copy again, and the shelved one is proved back in rather than searched for.
        let returning = player.sources.renditionTag(for: song) == nil && !isPinned(song.videoId)
            && upgrade.shelved(song.videoId) != nil
        let alreadyPending = returning || upgrade.isPending(song.videoId)
        if !alreadyPending {
            // Only a YouTube-origin stream row served from the cache is a candidate (Android: a
            // `watch` URI). A source's own catalogue row, a file on this device and a download all
            // have somewhere else to play from, and a download was excluded by hand on Android too.
            //
            // Only a YouTube-origin stream row served whole from the disk cache is a candidate
            // (Android: a `watch` URI). A row the resolver answered, a source's own catalogue row,
            // a file on this device and a download all have somewhere else to play from; a download
            // was excluded by hand on Android too.
            guard player.sources.playingFromCache(for: song.videoId),
                  player.sources.playingCacheKey(for: song.videoId)?.rendition != "hifi-2",
                  SourceRegistry.parseTrackKey(song.videoId) == nil,
                  PlaybackSourceFactory.localFileURL(of: song) == nil,
                  player.sources.savedFile(song) == nil,
                  upgrade.couldStillUpgrade(song.videoId, uri: playbackURI(for: song)) else { return }
        }
        start(for: song, playing: alreadyPending ? player.currentStream?.format : nil,
              generation: generation(for: song), adoptCached: !alreadyPending)
    }

    private func generation(for song: Song) -> Int {
        // A shelved copy goes back into the slot it already fills: read from there, it costs
        // no download, where "the slot not playing" fetched all of it again into the other one.
        if let shelved = upgrade.shelved(song.videoId), let slot = player?.sources.upgradeSlot(holding: shelved, for: song) {
            return slot.rendition == "hifi-2" ? 2 : 1
        }
        return Self.generation(playing: player?.sources.renditionTag(for: song) ?? player?.sources.playingCacheKey(for: song.videoId)?.rendition)
    }

    /// The upgrade slot the row is not playing from, so a copy is never written into the entry being
    /// played: `hifi-2` (2) while it plays `hifi` — swapped in, or picked whole off the disk at its
    /// start — and `hifi` (1) otherwise, `hifi-2` included.
    nonisolated static func generation(playing tag: String?) -> Int {
        tag == "hifi" ? 2 : 1
    }

    /// The `vibramusic://` URI the playing row stands for, in the terms ``QualityUpgrade`` reads:
    /// Android's media-item URI minus its resolver. The video id and the music-video flag come from
    /// ``PlaybackURI/forStreaming(_:pinnedToOriginal:)``; the upgrade marker is added for a row that
    /// is already on an upgraded rendition, which is what makes `couldStillUpgrade` refuse it.
    private func playbackURI(for song: Song) -> String {
        var uri = PlaybackURI.forStreaming(song, pinnedToOriginal: isPinned(song.videoId))
        if PlaybackURI.queryValue(PlaybackURI.renditionParameter, in: uri) == nil,
           let tag = player?.sources.renditionTag(for: song), tag.hasPrefix("hifi") {
            uri += "&\(PlaybackURI.renditionParameter)=\(tag)"
        }
        return uri
    }

    /// The queue moved off `song`: its search stops, but what it learned is kept for a return
    /// visit (``QualityUpgrade/setAside(_:)``) — the question still open, or the better copy it
    /// swapped in, shelved. A return to a row whose opened audio the engine still holds resolves
    /// nothing, so without this the row came back on its old copy for good.
    private func setAside(_ song: Song) {
        if jobVideoId == song.videoId {
            job?.cancel()
            job = nil
            jobVideoId = nil
            candidate = nil
        }
        if let sources = player?.sources, sources.renditionTag(for: song)?.hasPrefix("hifi") == true,
           let upgraded = sources.forcedStream(for: song) {
            upgrade.shelve(song.videoId, stream: upgraded)
        }
        upgrade.setAside(song.videoId)
        if status?.videoId == song.videoId, status?.isUpgrading == true { status = nil }
    }

    /// Stops anything running for `song` (it stopped playing, or the listener pinned it).
    func forget(_ song: Song) {
        if jobVideoId == song.videoId {
            job?.cancel()
            job = nil
            jobVideoId = nil
            candidate = nil
        }
        upgrade.forget(song.videoId)
        if status?.videoId == song.videoId, status?.isUpgrading == true { status = nil }
    }

    /// "Upgrade quality" pressed (Android `upgradeQualityNow`).
    func requestByHand(for song: Song, playing: ResolvedStream?) -> ManualUpgradeResult {
        switch upgrade.requestByHand(song.videoId, nowMs: nowMs(), upgradeRunning: jobVideoId == song.videoId) {
        case .alreadyRunning: return .alreadyRunning
        case .coolingDown(let remaining): return .coolingDown(remainingMs: remaining)
        case .accepted: break
        }
        // A row played whole off the disk resolved nothing to measure it by: it is adopted as the
        // automatic look adopts it, its floor measured off the decoder and the entry (Android's press
        // runs `lookForBetterCopy`, and so `adoptCachedTrack`). With no floor only lossless passed.
        if playing == nil, !song.isVideo, player?.sources.playingFromCache(for: song.videoId) == true,
           upgrade.couldStillUpgrade(song.videoId, uri: playbackURI(for: song)) {
            start(for: song, playing: nil, generation: generation(for: song), adoptCached: true, afresh: true)
            return .searching
        }
        let target = QualityUpgrade.Target(song: song)
        guard !song.isVideo, upgrade.settledForLess(song.videoId, target: target, playing: playing?.format, servedBy: playing?.sourceConfigId) else {
            return .nothingToSearch
        }
        start(for: song, playing: playing?.format, generation: generation(for: song), afresh: true)
        return .searching
    }

    // MARK: The ceiling

    /// Follows the ceiling in force (Settings, or the connection it is read on) and lets go of what a
    /// lowered one no longer pays for (Android's settings observer calling `onCeilingLowered`).
    func follow(_ ceiling: PlaybackQualityCeiling) {
        // The connection through its provider's own updates: observing `effectiveQuality` sees a
        // change of network only when the provider is itself observable.
        connectionWatch?.cancel()
        connectionWatch = Task { @MainActor [weak self] in
            for await _ in ceiling.networkUpdates() {
                guard let self else { return }
                self.ceilingRead(ceiling.effectiveQuality)
            }
        }
        observe(ceiling)
    }

    /// The two settings, through observation.
    private func observe(_ ceiling: PlaybackQualityCeiling) {
        let quality = withObservationTracking { ceiling.effectiveQuality } onChange: { [weak self, weak ceiling] in
            // onChange fires before the new value lands; it is read once it has.
            Task { @MainActor in
                guard let self, let ceiling else { return }
                self.observe(ceiling)
            }
        }
        ceilingRead(quality)
    }

    /// Acts on a reading of the ceiling that lost a source kind the last one paid for. Both
    /// watches can report the same change; the second finds nothing lost.
    private func ceilingRead(_ quality: AudioQuality) {
        defer { ceilingInForce = quality }
        guard let previous = ceilingInForce,
              SourceKind.allCases.contains(where: { previous.permits($0) && !quality.permits($0) }) else { return }
        ceilingLowered(to: quality)
    }

    /// Android `onCeilingLowered`, for the upgrade's part. Android leaves an audition running and
    /// drops it after; here a look holding a copy the ceiling now skips stops at once, so the copy
    /// isn't warmed and proved on the connection the listener just limited. A copy the ceiling still
    /// allows carries on, as does a swap that has landed, whose watch may yet put the old copy back.
    private func ceilingLowered(to quality: AudioQuality) {
        guard let player else { return }
        let playing = player.currentSong?.videoId
        TrackLog.d("PlaybackPolicy", "quality ceiling now \(quality); letting go of upgrades it no longer pays for", about: playing)
        var swapped = false
        if case .upgraded? = status?.phase, status?.videoId == jobVideoId { swapped = true }
        if job != nil, let id = jobVideoId, !(candidate.map(upgrade.permitsForPlayback) ?? swapped) {
            // Still searching, it asked sources the ceiling may no longer pay for: it is asked again
            // below, under the new one. Holding a copy, the copy is let go and its race ended.
            if candidate != nil { nerdStats.onLosslessRaceEnd(id) }
            job?.cancel()
            job = nil
            jobVideoId = nil
            candidate = nil
            if status?.videoId == id, status?.isUpgrading == true { status = nil }
        }
        upgrade.onCeilingLowered(keep: Set([playing].compactMap { $0 }), permitted: upgrade.permitsForPlayback)
        lookForBetterCopy()
    }

    // MARK: The second look

    private func start(for song: Song, playing: StreamFormat?, generation: Int, adoptCached: Bool = false, afresh: Bool = false) {
        job?.cancel()
        candidate = nil
        jobVideoId = song.videoId
        // The cached path only earns the badge once adoption has actually made the track a
        // candidate: a track that turns out already to be lossless must not flash "Upgrading".
        if !adoptCached { status = QualityUpgradeStatus(videoId: song.videoId, phase: .searching) }
        job = Task { @MainActor [weak self] in
            // A press asks the sources as they are now (Android `upgradeQualityNow`): an answer
            // cached a minute ago, an add-on's "nothing" while its upstream was down, is dropped.
            if afresh { await self?.upgrade.clearCompletedAnswers() }
            await self?.lookForBetterCopy(song, playing: playing, generation: generation, adoptCached: adoptCached)
            self?.settle(song)
        }
    }

    /// Every way out of a look ends the badge, as Android's `finally` around `swapIn` does:
    /// a path that returned with the status still on searching or proving is closed as
    /// unavailable, and the race the badge reads is ended. A cancelled look's status belongs to
    /// whoever cancelled it: ``setAside(_:)`` and ``forget(_:)`` clear it, and ``start(for:playing:generation:adoptCached:)``
    /// hands it to the look it starts, whose race must not be ended here.
    private func settle(_ song: Song) {
        guard !Task.isCancelled else {
            Self.log("upgrade look for '\(song.title)' stopped: the queue moved on or a new look replaced it", song)
            return
        }
        nerdStats.onLosslessRaceEnd(song.videoId)
        guard status?.videoId == song.videoId, status?.isUpgrading == true else { return }
        TrackLog.w("PlaybackPolicy", "upgrade look for '\(song.title)' ended without a verdict; unavailable", about: song.videoId)
        finish(song, phase: .unavailable)
    }

    private func lookForBetterCopy(_ song: Song, playing: StreamFormat?, generation: Int, adoptCached: Bool) async {
        defer {
            if jobVideoId == song.videoId, !Task.isCancelled {
                jobVideoId = nil
                job = nil
                candidate = nil
            }
        }
        guard let player else { return }
        let waited = ContinuousClock.now
        // A cached row is adopted from what the decoder reports, so it waits for it; a resolved row
        // searches after a short grace with the catalogue's length if the start is slow. A
        // row with no catalogue length waits as long as a cached one: with neither length the
        // search refuses to run, and its "nothing better" would stand for the rest of the play.
        let catalogued = QualityUpgrade.Target(song: song).durationSec != nil
        let playingSeconds = await playingDuration(of: song, within: adoptCached || !catalogued ? Self.decoderWait : Self.decoderGrace)
        guard !Task.isCancelled else { return }
        Self.log("second look for '\(song.title)' starts: the decoder's length "
            + (playingSeconds.map { "(\(Int($0.rounded())) s)" } ?? "never came") + " after \(TrackLog.ms(since: waited))ms", song)
        var floor = playing
        // A row nothing resolved has to be adopted now the decoder has reported it (Android
        // `adoptCachedTrack`); one already marked by the resolver is left as it is.
        if adoptCached, !upgrade.isPending(song.videoId) {
            // By now the item has opened, so if the row did resolve after all (a re-minted stream
            // under the same entry), its own verdict stands. Only a row that never resolved is
            // adopted.
            guard player.sources.facts.stream(for: player.sources.engineItemID(for: song)) == nil else { return }
            switch await adoptCachedTrack(song) {
            case .refused:
                if status?.videoId == song.videoId, status?.isUpgrading == true { status = nil }
                return
            case .adopted(let adoptedFloor):
                floor = adoptedFloor
                status = QualityUpgradeStatus(videoId: song.videoId, phase: .searching)
            }
        }
        // Back on a row that opened its shelved copy whole off the disk (`cachedCopy` picks a whole
        // `#hifi`): it already plays the upgrade, and proving it again would only cross it over to
        // itself. Asked once the item has opened, when the key it opened under is known.
        if let shelved = upgrade.shelved(song.videoId), let slot = player.sources.upgradeSlot(holding: shelved, for: song),
           player.sources.playingFromCache(for: song.videoId), player.sources.playingCacheKey(for: song.videoId) == slot {
            Self.log("second look for '\(song.title)' not needed: it opened its shelved \(shelved.format.summary) off the disk", song)
            upgrade.unshelve(song.videoId)
            finish(song, phase: .upgraded(from: nil, to: shelved.format))
            return
        }
        let searched = ContinuousClock.now
        // A copy shelved on an earlier visit is proved again (mostly from disk) instead of searched for.
        var found = upgrade.shelved(song.videoId)
        if found == nil { found = await upgrade.lookAgain(song.videoId, playingDurationSec: playingSeconds.map { Int($0.rounded()) }) }
        guard !Task.isCancelled else { return }
        Self.log("second look for '\(song.title)' answered in \(TrackLog.ms(since: searched))ms: "
            + (found.map { "\($0.format.summary) from \($0.sourceConfigId ?? "\($0.origin)")" } ?? "nothing better"), song)
        guard let found else {
            finish(song, phase: .unavailable)
            return
        }
        // Found or shelved under a higher ceiling (on Wi-Fi, before the listener left it): asked again
        // here, before it costs data, and again before the cut (Android `swapIn`).
        guard upgrade.permitsForPlayback(found) else {
            Self.log("upgrade dropped: the quality ceiling no longer allows \(found.sourceConfigId ?? found.origin.rawValue)", song)
            finish(song, phase: .unavailable)
            return
        }
        candidate = found
        // About to cut into the track: its length is the decoder's, waited for now if the search
        // started without it (before the audition opens, so the wait isn't charged to it).
        var decoded = playingSeconds
        if decoded == nil { decoded = await playingDuration(of: song, within: Self.decoderWait) }
        guard !Task.isCancelled else { return }
        // Everything that must still be true before the audio is cut (Android `swapPointFor`).
        guard isStillPlaying(song), !isPinned(song.videoId) else {
            // Proved nothing yet, but the answer is good: kept for a return visit.
            shelve(song, stream: found)
            return
        }
        // Too little track left to be worth the fetch, or to swap before a transition: kept for a
        // replay rather than spent on the last seconds (Android `UPGRADE_MIN_REMAINING_MS`).
        guard roomToSwap(length: decoded ?? player.engine.duration) else {
            Self.log("upgrade shelved: too near the end of the track to swap", song)
            shelve(song, stream: found)
            return
        }
        let tag = generation <= 1 ? "hifi" : "hifi-\(generation)"
        status = QualityUpgradeStatus(videoId: song.videoId, phase: .proving(found.format))
        upgrade.force(song.videoId, stream: found)
        upgrade.beginAudition(song.videoId)
        let reference = decoded ?? (player.engine.duration > 0 ? player.engine.duration : nil)
        // A clean slot first, as Android's audition does: `hifi` names a slot, and whatever an
        // earlier attempt (or session) left in it belongs to another candidate.
        await player.sources.emptyUpgradeSlot(for: song, stream: found, tag: tag)
        // The copy's header and the bytes at the swap point, ahead of the proof and the swap
        // (Android warms a fixed megabyte from byte zero ahead of `auditionUpgrade`; see
        // `UpgradeWarm`). The copy is read from the playhead onward, so these are the swap's first
        // reads after the cut, and nothing else would fetch them before it. Under the proof's
        // deadline: a server trickling bytes just fast enough to dodge the idle timeout must not
        // hold the upgrade open for good.
        let sources = player.sources
        let engine = player.engine
        let warming = ContinuousClock.now
        let warmed = await withDeadline(Self.proveTimeout) { @Sendable () async -> WarmedHead? in
            let layout = await sources.warmUpgradeHead(for: song, stream: found, tag: tag)
            QualityUpgradeController.log("upgrade warm: header " + (layout.map { "of \($0.headerRange.upperBound) bytes" } ?? "unread (fixed opening)")
                + " in \(TrackLog.ms(since: warming))ms", song)
            guard let layout, let reference else { return WarmedHead(layout: nil) }
            // Where the playhead is once the header is in, not before it: the window has to hold
            // the swap, and the swap lands wherever the playhead has got to.
            let position = await engine.position
            let window = await sources.warmUpgradeSwapPoint(for: song, stream: found, tag: tag, layout: layout, position: position, duration: reference)
            QualityUpgradeController.log("upgrade warm: swap window " + (window.map { "[\($0.lowerBound), \($0.upperBound))" } ?? "none")
                + " for \(String(format: "%.1f", position)) s, done at \(TrackLog.ms(since: warming))ms", song)
            return WarmedHead(layout: layout)
        }
        guard !Task.isCancelled else {
            upgrade.endAudition(song.videoId)
            return
        }
        // Not even the header and a few seconds of audio in twenty seconds: a server that slow
        // can't keep the copy playing, so it's dropped now rather than stalling after the cut
        // (Android's audition drops a copy that doesn't buffer in time, for the same reason).
        guard let warmed else {
            upgrade.endAudition(song.videoId)
            TrackLog.w("PlaybackPolicy", "upgrade dropped before it was heard: its opening didn't arrive in \(Self.proveTimeout)", about: song.videoId)
            finish(song, phase: .unavailable)
            return
        }
        let proving = ContinuousClock.now
        Self.log("upgrade audition: proving \(found.format.summary)", song)
        let proved = await proof(of: song, stream: found, tag: tag, against: reference)
        upgrade.endAudition(song.videoId)
        guard !Task.isCancelled else { return }
        Self.log("upgrade proof: " + (proved.map { "\(String(format: "%.1f", $0)) s long" } ?? "never opened")
            + " against \(reference.map { String(format: "%.1f", $0) } ?? "?") s, in \(TrackLog.ms(since: proving))ms", song)
        guard let proved, lengthsAgree(proved, reference) else {
            TrackLog.w("PlaybackPolicy", "upgrade dropped before it was heard: \(proved.map { "\($0)s against \(reference ?? 0)s" } ?? "it didn't open as promised")",
                       about: song.videoId)
            finish(song, phase: .unavailable)
            return
        }
        // Never cut into a crossfade (the engine would bail the blend to a cut), nor the instant one
        // ends (Android waits before `swapPointFor`; here it is after the proof, so the proof's own
        // seconds count towards the grace).
        await waitOutCrossfade(for: song)
        guard !Task.isCancelled else { return }
        // The window was twelve seconds past the playhead when it was fetched; a slow fetch, a long
        // proof or a crossfade waited out moves the playhead into it or beyond. Warm again from
        // wherever it is now (bytes already on disk aren't fetched twice), and swap only once all of
        // it is on disk, as Android's audition buffers `UPGRADE_PREBUFFER_MS` past the moving
        // playhead before its verdict. The crossover then reads from disk, and a copy that
        // can't get there in time is let go unheard, not cut over to mid-song and stalled on.
        if let layout = warmed.layout, let reference, isStillPlaying(song) {
            let cache = player.sources.cache
            let key = AudioCacheKey(trackID: song.videoId, rendition: tag)
            let ready = await withDeadline(Self.proveTimeout) { @Sendable () async -> Bool? in
                let position = await engine.position
                guard let window = await sources.warmUpgradeSwapPoint(for: song, stream: found, tag: tag, layout: layout,
                                                                      position: position, duration: reference),
                      let cache else { return true }
                let ranges = await cache.cachedRanges(of: key)
                return UpgradeWarm.covers(ranges, window)
            }
            guard !Task.isCancelled else { return }
            guard ready == true else {
                TrackLog.w("PlaybackPolicy", "upgrade dropped before it was heard: \(Int(UpgradeWarm.windowAfter)) s past the playhead weren't on disk "
                           + (ready == nil ? "within \(Self.proveTimeout)" : "after the warm"), about: song.videoId)
                finish(song, phase: .unavailable)
                return
            }
        }
        guard isStillPlaying(song), !isPinned(song.videoId) else {
            shelve(song, stream: found)
            return
        }
        // A blend that began during the hold: the proof is kept for next time rather than thrown away.
        guard !crossfadeReading().isRunning else {
            Self.log("upgrade shelved: a crossfade was still running", song)
            shelve(song, stream: found)
            return
        }
        // The proof and the warm take seconds: long enough for the ceiling to drop under them, or the
        // track to near its end (Android asks both again right before `replaceMediaItem`).
        guard upgrade.permitsForPlayback(found) else {
            Self.log("upgrade dropped: the quality ceiling no longer allows \(found.sourceConfigId ?? found.origin.rawValue)", song)
            finish(song, phase: .unavailable)
            return
        }
        guard roomToSwap(length: reference) else {
            Self.log("upgrade shelved: too near the end of the track to swap", song)
            shelve(song, stream: found)
            return
        }

        let previousTag = player.sources.renditionTag(for: song)
        let previousStream = player.sources.forcedStream(for: song)
        // The engine says how it landed: crossed over with no gap, or cut over (and its first audio).
        Self.log("upgrade swap at \(String(format: "%.1f", player.engine.position)) s, "
            + "\(TrackLog.ms(since: warming))ms after the warm began", song)
        player.reopenCurrent(onRendition: tag, stream: found)
        candidate = nil
        upgrade.unshelve(song.videoId)
        nerdStats.onLosslessRaceEnd(song.videoId)
        status = QualityUpgradeStatus(videoId: song.videoId, phase: .upgraded(from: floor, to: found.format))
        TrackLog.d("PlaybackPolicy", "upgraded '\(song.title)' to \(found.format.summary)", about: song.videoId)

        guard await watch(song, previousSeconds: reference) else {
            TrackLog.w("PlaybackPolicy", "upgrade reverted: the replacement's length disagrees", about: song.videoId)
            upgrade.forget(song.videoId)
            upgrade.refuseUpgrades(song.videoId)
            if isStillPlaying(song) { player.reopenCurrent(onRendition: previousTag, stream: previousStream) }
            finish(song, phase: .unavailable)
            return
        }
        // A lossy win while lossless was asked for: one more look, with this stream as the floor.
        if generation < 2, upgrade.continueAfterLossySwap(song.videoId) {
            await lookForBetterCopy(song, playing: found.format, generation: generation + 1, adoptCached: false)
        }
    }

    nonisolated private static func log(_ message: String, _ song: Song) {
        TrackLog.d("PlaybackPolicy", message, about: song.videoId)
    }

    /// The queue moved off the track (or it was pinned) with a good answer in hand: the answer is
    /// kept for a return visit and the badge goes out, rather than reading "Upgrading quality"
    /// the next time this track plays.
    private func shelve(_ song: Song, stream: ResolvedStream) {
        upgrade.shelve(song.videoId, stream: stream)
        nerdStats.onLosslessRaceEnd(song.videoId)
        if status?.videoId == song.videoId, status?.isUpgrading == true { status = nil }
    }

    private func finish(_ song: Song, phase: QualityUpgradeStatus.Phase) {
        nerdStats.onLosslessRaceEnd(song.videoId)
        // Nothing found, or a copy that didn't hold up: nothing to come back for.
        if phase == .unavailable { upgrade.unshelve(song.videoId) }
        if status?.videoId == song.videoId { status = QualityUpgradeStatus(videoId: song.videoId, phase: phase) }
    }

    /// Whether enough of a track `length` seconds long is left to swap in: ``minRemaining``, and with a
    /// crossfade or Automix on, enough for the swap to be done before the transition starts. The
    /// engine holds transitions while its crossover has the standby deck (up to ``swapHold``), and
    /// one due meanwhile came late or as a hard cut. Unknown length is a yes.
    private func roomToSwap(length: TimeInterval?) -> Bool {
        guard let player, let length, length > 0 else { return true }
        let transition = settings.smartFadeEnabled ? TimeInterval(AppSettings.crossfadeRange.upperBound) : TimeInterval(settings.crossfadeSeconds)
        let room = max(minRemaining, transition > 0 ? transition + Self.swapHold : 0)
        return length - player.engine.position >= room
    }

    private func crossfadeReading() -> CrossfadeReading {
        if let crossfadeOverride { return crossfadeOverride() }
        guard let engine = player?.engine else { return CrossfadeReading(isRunning: false, sinceEnded: nil) }
        return CrossfadeReading(isRunning: engine.isTransitioning, sinceEnded: engine.timeSinceLastTransition)
    }

    /// Holds while a crossfade is in flight (bounded by ``crossfadeWait``), then until one that has
    /// just ended is ``afterCrossfade`` behind (Android's two waits before the swap). Returns early
    /// if the job is cancelled.
    private func waitOutCrossfade(for song: Song) async {
        let deadline = ContinuousClock.now + Self.crossfadeWait
        while crossfadeReading().isRunning, ContinuousClock.now < deadline {
            guard (try? await Task.sleep(for: Self.crossfadePoll)) != nil else { return }
        }
        // Read again after each hold: a blend that began and ended during it starts the grace over.
        while let since = crossfadeReading().sinceEnded, since < Self.afterCrossfade {
            let hold = Self.afterCrossfade - since
            Self.log("upgrade holding \(Int(hold * 1_000))ms: a transition just ended", song)
            guard (try? await Task.sleep(for: .seconds(hold))) != nil else { return }
        }
    }

    /// The decoder's length for the playing row, once it has one (a few seconds at most).
    ///
    /// The stream resolves while the engine is still opening the item, when `engine.duration` is
    /// only the catalogue's figure (PlayableItem's placeholder); the decoder's own length lands when
    /// the item has opened, so the wait is for that (Android read `player.duration`).
    private func playingDuration(of song: Song, within wait: Duration) async -> TimeInterval? {
        let deadline = ContinuousClock.now + wait
        while ContinuousClock.now < deadline, !Task.isCancelled, isStillPlaying(song) {
            if let player, player.engine.currentItem?.id == player.sources.engineItemID(for: song),
               !player.engine.isBuffering, player.engine.duration > 0 {
                return player.engine.duration
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private func isStillPlaying(_ song: Song) -> Bool {
        guard let current = player?.currentSong else { return false }
        return current.queueEntryId == song.queueEntryId && current.videoId == song.videoId
    }

    /// What the copy's warm-up left to go on: the layout of its file, when its container could be read.
    private struct WarmedHead: Sendable {
        var layout: UpgradeWarm.Layout?
    }

    // MARK: The cached-track half (Android `adoptCachedTrack`)

    private enum CachedAdoption {
        /// Not a candidate (no decoder verdict yet, already lossless, or a blank target).
        case refused
        /// Now pending. The floor is how good the bytes already on disk measured — nil when
        /// nothing could say.
        case adopted(StreamFormat?)
    }

    /// Decides whether a track nothing resolved is worth a second look, now that the decoder has
    /// settled enough to say what it is playing (Android `adoptCachedTrack`).
    ///
    /// Two questions need the player rather than the queue entry. **What codec is actually coming
    /// out**: a cache entry can already hold the FLAC a previous session upgraded to, and hunting a
    /// lossless copy of a lossless track buys a break in the audio for nothing — and a codec the
    /// renderer is reporting for some *other* track has to be treated the same as no answer at all,
    /// because the two are indistinguishable (Android's `audioFormatFor`). **Whether the listener
    /// owns the file**: a download plays from its own copy on disk, and the second look would spend
    /// data replacing a file the user deliberately saved.
    private func adoptCachedTrack(_ song: Song) async -> CachedAdoption {
        guard let player else { return .refused }
        let itemID = player.sources.engineItemID(for: song)
        // The decoder must be reporting THIS item: after a queue advance the renderer still names
        // the outgoing track's codec for a moment, and reading it here cost Android a track its
        // upgrade for the rest of the session.
        guard player.engine.currentItem?.id == itemID,
              let stats = player.engine.stats, stats.itemID == itemID,
              let mime = PlayerNerdStatsText.mimeType(forCodec: stats.codec) else { return .refused }
        guard player.sources.savedFile(song) == nil else { return .refused }
        // Dolby Atmos is final: a kept Atmos copy playing from disk is not "less than lossless" to
        // be searched past and swapped for the same mix as a stream.
        guard !mime.contains("eac3") else { return .refused }
        let target = QualityUpgrade.Target(song: song)
        let durationSec = player.engine.duration > 0 ? Int(player.engine.duration.rounded()) : nil
        if QualityUpgrade.isSevereMismatch(expectedSec: target.durationSec, actualSec: durationSec) {
            TrackLog.w(
                "PlaybackPolicy",
                "cached rendition duration mismatch: playing \(durationSec ?? 0)s vs catalogue \(target.durationSec ?? 0)s "
                    + "for \(song.videoId); discarding cache rendition",
                about: song.videoId
            )
            if let cache = player.sources.cache, let key = player.sources.playingCacheKey(for: song.videoId) {
                await cache.discardRendition(key)
            }
        }
        let floor = await cachedFloor(for: song, stats: stats, durationSec: durationSec)
        guard upgrade.adoptUnresolved(song.videoId, uri: playbackURI(for: song), target: target,
                                      playingMime: mime, playing: floor) else { return .refused }
        return .adopted(floor)
    }

    /// How good the bytes already on disk are (Android `cachedFloor`), in the only terms a track
    /// nothing resolved can be measured in: the decoder's bitrate where it states one (MP4/AAC
    /// usually does), otherwise the cache entry's full size over the decoder's runtime — which is
    /// what a YouTube entry needs, since WebM/Opus states no bitrate at all.
    ///
    /// The codec is deliberately not filled in: ``StreamFormat/isLossless`` reads it, and a name
    /// carried over from the decoder's MIME type would have to be translated to be recognised —
    /// where being wrong means claiming a cached stream is already lossless. Only the bitrate is
    /// wanted; ``QualityUpgrade/adoptUnresolved(_:uri:target:playingMime:playing:)`` settles the
    /// lossless question separately, from the MIME type itself.
    private func cachedFloor(for song: Song, stats: PlaybackStats, durationSec: Int?) async -> StreamFormat? {
        if let kbps = stats.bitrateKbps, kbps > 0 { return StreamFormat(kbps: kbps) }
        guard let durationSec, durationSec > 0, let player else { return nil }
        let bytes = await player.sources.playingContentLength(for: song.videoId)
        guard bytes > 0 else { return nil }
        return StreamFormat(kbps: Int(bytes * 8 / Int64(durationSec) / 1_000))
    }

    /// Whether the replacement's length is within the listener's slack of the one playing.
    /// Unknown on the playing side is a yes: there is nothing to disagree with.
    func lengthsAgree(_ candidate: TimeInterval, _ playing: TimeInterval?) -> Bool {
        guard let playing, playing > 0 else { return true }
        return abs(candidate - playing) <= TimeInterval(settings.upgradeLengthSlackSeconds) + 0.5
    }

    /// Opens the found copy without playing it and reads its length: a dead URL, a refused
    /// range or a container that won't parse is found out here rather than in the listener's ears.
    ///
    /// An add-on's segmented copy (a fragmented MP4 through the cache) answers only once all of it
    /// has arrived: AVFoundation reads every fragment before it reports the file's length, tracks
    /// or readiness, and the swap waits on the same read, so the proof can't skip it. How
    /// long that takes grows with the copy, so past ``proveTimeout`` the proof goes on while the
    /// copy arrives faster than it plays, which is what Android's audition asks of a copy too.
    ///
    /// Bounded however the copy behaves: only bytes that arrive during the proof count, it
    /// ends once nothing has arrived for ``proveStall`` and at ``proveCeiling`` regardless, and each
    /// look at the cache is under the check's own deadline.
    private func proof(of song: Song, stream: ResolvedStream, tag: String, against reference: TimeInterval?) async -> TimeInterval? {
        if !usesDefaultProof { return await prove(song, stream, tag) }
        let clock = proofClock
        guard let player else { return nil }
        let cache = player.sources.cache
        let key = AudioCacheKey(trackID: song.videoId, rendition: tag)
        let look = { @Sendable () async -> Arrival? in await QualityUpgradeController.arrival(of: key, in: cache) }
        // Only what arrives from here on counts. The slot can already hold most of the copy (a press
        // after an attempt at the same URL keeps its bytes), and counted, that head start passed a
        // copy nothing more was arriving for as one arriving faster than it plays.
        var arrived = await withDeadline(clock.check, look)
        // A start read that didn't answer in time is taken from the first one that does, not as an
        // empty slot: a head start counted from zero is the very thing being ruled out.
        var before = arrived?.bytes
        // Silent: the row still plays its old copy, and this one may yet be refused.
        let factory = player.sources.forcedAssetFactory(for: song, stream: stream, tag: tag, silent: true)
        let promised = stream.format
        let videoId = song.videoId
        let opening = Task.detached { () -> TimeInterval? in
            guard let asset = try? await factory() else { return nil }
            guard let duration = try? await asset.load(.duration), duration.isNumeric else { return nil }
            // What the decoder is handed, against what the source promised (Android's audition
            // verdict): a copy that promised lossless and decodes lossy buys a break in the
            // audio for nothing, under a "Lossless" badge. A codec nothing states is let through, as
            // on Android: only a stated one can contradict the promise.
            if promised.isLossless == true, let mime = try? await AudioFormatMeasurement.measure(asset: asset)?.mimeType,
               !NerdStats.isLosslessMime(mime) {
                TrackLog.w("PlaybackPolicy", "upgrade refused: it promised \(promised.summary), the decoder was handed \(mime)", about: videoId)
                return nil
            }
            return duration.seconds
        }
        defer { opening.cancel() }
        let started = ContinuousClock.now
        var lastArrival = started
        while true {
            if let answer = await withDeadline(clock.check, { () async -> TimeInterval?? in .some(await opening.value) }) {
                return answer
            }
            guard !Task.isCancelled else { return nil }
            // A look that doesn't answer in time (the entry held by a fetch that never ends) is
            // nothing new arriving.
            if let now = await withDeadline(clock.check, look) {
                // The stall clock starts when the slot could first be read, not before it.
                if before == nil { before = now.bytes; lastArrival = .now }
                if now.bytes > (arrived?.bytes ?? now.bytes) { lastArrival = .now }
                arrived = now
            }
            let elapsed = ContinuousClock.now - started
            guard elapsed >= clock.timeout else { continue }
            guard let progress = arrived, let baseline = before, progress.length > 0, let reference else { return nil }
            let arrivedSeconds = Double(progress.bytes - baseline) / Double(progress.length) * reference
            let summary = "\(String(format: "%.1f", arrivedSeconds)) s of audio arrived in \(TrackLog.ms(since: started))ms"
            // A copy already whole on disk (a shelved one proved again) has nothing left to arrive:
            // only the decoder's report is outstanding, and only the ceiling bounds that.
            let complete = progress.bytes >= progress.length
            if elapsed >= clock.ceiling {
                TrackLog.w("PlaybackPolicy", "upgrade proof given up at its \(clock.ceiling) ceiling: \(summary)", about: song.videoId)
                return nil
            }
            if !complete, ContinuousClock.now - lastArrival >= clock.stall {
                TrackLog.w("PlaybackPolicy", "upgrade proof given up: nothing arrived for \(TrackLog.ms(since: lastArrival))ms, "
                           + "\(progress.bytes) of \(progress.length) bytes in (\(summary))", about: song.videoId)
                return nil
            }
            guard complete || arrivedSeconds > elapsed / .seconds(1) else {
                TrackLog.w("PlaybackPolicy", "upgrade proof given up: the copy arrives slower than it plays (\(summary))", about: song.videoId)
                return nil
            }
        }
    }

    /// How much of an upgrade slot's copy is on disk, against its whole length.
    private struct Arrival: Sendable {
        var length: Int64
        var bytes: Int64
    }

    nonisolated private static func arrival(of key: AudioCacheKey, in cache: AudioStreamCache?) async -> Arrival? {
        guard let cache else { return nil }
        let length = await cache.contentLength(of: key)
        let bytes = await cache.cachedRanges(of: key).reduce(Int64(0)) { $0 + ($1.upperBound - $1.lowerBound) }
        return Arrival(length: length, bytes: bytes)
    }

    /// After the swap: true once the new copy reports a length within the slack; false if it
    /// disagrees, fails, or never says (Android `watchUpgrade`).
    private func watch(_ song: Song, previousSeconds: TimeInterval?) async -> Bool {
        guard let previousSeconds, previousSeconds > 0 else { return true }
        // The copy becomes current when the engine's crossover lands, seconds after the request
        // (``AudioPlayerEngine/replaceCurrent(with:)``): its ``watchTimeout`` starts then.
        var deadline = ContinuousClock.now + Self.swapTimeout + Self.watchTimeout
        var landed = false
        while ContinuousClock.now < deadline {
            guard let player, isStillPlaying(song) else { return true }
            if player.engine.lastError?.itemID == player.engine.currentItem?.id, player.engine.lastError?.isPermanent == true { return false }
            let current = player.engine.currentItem?.id == player.sources.engineItemID(for: song)
            if current, !landed {
                landed = true
                deadline = ContinuousClock.now + Self.watchTimeout
            }
            if current, !player.engine.isBuffering, player.engine.duration > 0 {
                return lengthsAgree(player.engine.duration, previousSeconds)
            }
            guard (try? await Task.sleep(for: .milliseconds(100))) != nil else { return true }
        }
        return false
    }
}
