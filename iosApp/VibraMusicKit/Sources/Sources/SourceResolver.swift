import Foundation
import VibraMusicCore

// Ports data/sources/SourceResolver.kt, plus the playback race Android ran in
// PlaybackService.resolveWithModulePriority (so this type can be the app's one StreamResolving).
//
// Android derived the request inside (`requestForNow()` read the settings and the connection);
// here every entry point takes Core's StreamRequest, which the caller builds with
// `AppSettings.playbackStreamRequest(for:)` or `.downloadStreamRequest`.

public enum SourceResolutionError: LocalizedError, Equatable {
    /// Nothing enabled could serve the track, and there was no YouTube resolver to fall back to.
    case noSource(String)

    public var errorDescription: String? {
        switch self {
        case .noSource(let title): return "No source could play '\(title)'"
        }
    }
}

/// Turns a queued track into an openable stream, using whichever source can best serve it.
///
/// Two things happen here that no single ``MusicSource`` does: the quality question is answered
/// once, from the request, and the order is applied — a track is pinned to the source that produced
/// it, but a pin is a starting point: with lossless asked for, a higher-ranked source that can serve
/// the same recording bit-exact goes first, and a source that fails is stepped over.
///
/// Whether another source *has* the same recording is ``TrackMatcher``'s question, and every search
/// here goes through it, so the library, a playlist, radio and search all substitute on identical
/// terms.
///
/// As a ``StreamResolving`` (``resolveStream(for:request:)``) it is what the app hands Playback and
/// Downloads: source ladder first, YouTube (the injected resolver) as the fallback.
public final class SourceResolver: StreamResolving, @unchecked Sendable {
    private let registry: SourceRegistry
    private let environment: SourceEnvironment
    private let directSourceWait: TimeInterval
    private let aheadSourceWait: TimeInterval
    private let substituteTimeout: TimeInterval
    private let lookupsLock = NSLock()
    /// The ranked sources' lookups a YouTube win left running, by video id; see ``takeStillLooking(_:)``.
    private var stillLooking: [String: Task<ResolvedStream?, Never>] = [:]

    /// `directSourceWait`, `aheadSourceWait` and `substituteTimeout` replace the caps of the same
    /// names; tests use them to avoid sleeping that long.
    public init(registry: SourceRegistry, directSourceWait: TimeInterval? = nil, aheadSourceWait: TimeInterval? = nil,
                substituteTimeout: TimeInterval? = nil) {
        self.registry = registry
        self.directSourceWait = directSourceWait ?? Self.directSourceWait
        self.aheadSourceWait = aheadSourceWait ?? Self.aheadSourceWait
        self.substituteTimeout = substituteTimeout ?? Self.substituteTimeout
        environment = registry.environment
    }

    // MARK: StreamResolving

    /// The app-facing entry point.
    ///
    /// - A source-backed track (`src:` id) resolves through ``resolve(configId:trackId:target:request:)``,
    ///   then YouTube's matching row (``youtubeFallback(_:)``).
    /// - A YouTube track, for playback, races ``substituteForYouTube(_:request:)`` against YouTube's
    ///   own resolve: the first to produce a stream wins (Android `resolveWithModulePriority`). A
    ///   source's stream has to be sending audio before it counts, as YouTube's has already been
    ///   probed: the race is to sound, not to a URL.
    ///   A YouTube answer that won while ranked sources were still looking comes back
    ///   ``ResolvedStream/belowRequest`` — the signal for Playback's quality upgrade to call
    ///   ``upgradeFor(_:playing:servedBy:request:)`` once audio is running. The sources' lookup is
    ///   not cancelled but handed to that second look (``takeStillLooking(_:)``), which takes its
    ///   answer before searching again.
    ///   With ``StreamRequest/waitsForSources`` YouTube's stream is held instead, for up to
    ///   ``directSourceWait`` after it is ready: a ranked source that answers in that time starts the
    ///   track, ranked sources that find nothing release YouTube's stream at once, and the cap running
    ///   out releases it ``ResolvedStream/belowRequest``.
    /// - A download (`request.purpose == .download`) asks ``forDownload(_:request:)`` first.
    public func resolveStream(for song: Song, request: StreamRequest) async throws -> ResolvedStream {
        let target = TrackMatcher.targetOf(song)
        if let key = SourceRegistry.parseTrackKey(song.videoId) {
            if let stream = try await resolve(configId: key.configId, trackId: key.trackId, target: target, request: request) {
                return stream
            }
            if let stream = try await youtubeFallback(target) { return stream }
            throw SourceResolutionError.noSource(song.title)
        }
        if request.purpose == .download {
            if let stream = try await withTimeout(Self.downloadLookupTimeout, { try await self.forDownload(target, request: request) }) ?? nil {
                return stream
            }
            return try await youTube(song, request: request)
        }
        return try await raceYouTube(song, target: target, request: request)
    }

    private func youTube(_ song: Song, request: StreamRequest) async throws -> ResolvedStream {
        guard let resolver = environment.youTubeStreams else { throw SourceResolutionError.noSource(song.title) }
        return try await resolver.resolveStream(for: song, request: request)
    }

    /// First past the post between the ranked sources and YouTube's own walk.
    private func raceYouTube(_ song: Song, target: TrackMatcher.Target, request: StreamRequest) async throws -> ResolvedStream {
        guard let resolver = environment.youTubeStreams else {
            if let stream = try await substituteForYouTube(target, request: request) { return stream }
            throw SourceResolutionError.noSource(song.title)
        }
        guard canSubstituteForYouTube(request), !target.isVideo, target.title.nonBlank != nil else {
            return try await resolver.resolveStream(for: song, request: request)
        }
        enum Leg: Sendable {
            case substitute(ResolvedStream?)
            case youTube(Result<ResolvedStream, Error>)
            case waitedLongEnough
        }
        let started = ContinuousClock.now
        func note(_ what: String) {
            SourcesLog.d("race for '\(target.title)': \(what) at \(TrackLog.ms(since: started))ms")
        }
        // Queue only's look at a track ahead: nobody is waiting to hear it, so the ranked sources
        // get as long as a slow catalogue needs (a cold lossless file can take an add-on well past
        // the play-time limits) for the track to start on their copy.
        let ahead = request.waitsForSources && request.readsAheadFromSources
        // Ahead, the hold is counted from the race's start, as the sources' limit is, and runs out
        // before it: a look that gives up still marks YouTube's copy for the upgrade however late
        // YouTube was ready.
        let holdCap = ahead ? self.aheadSourceWait : self.directSourceWait
        let sourcesTimeout = ahead ? self.aheadSourceWait + (self.substituteTimeout - self.directSourceWait) : self.substituteTimeout
        // The sources' lookup runs outside the race, so a YouTube win can hand it, still running, to
        // the second look (Android `DirectSourceGate.startedOnYouTube`) instead of cancelling it.
        // Their limit still bounds it. Every other way out of the race cancels it.
        let lookup = Task<ResolvedStream?, Never> {
            let found = try? await self.withTimeout(sourcesTimeout, {
                try await self.substituteForYouTube(target, request: request)
            })
            return found ?? nil
        }
        var handedOff = false
        defer { if !handedOff { lookup.cancel() } }
        return try await withThrowingTaskGroup(of: Leg.self) { group in
            group.addTask {
                let found = await Self.answer(of: lookup)
                try Task.checkCancellation()
                return .substitute(found)
            }
            group.addTask {
                do { return .youTube(.success(try await resolver.resolveStream(for: song, request: request))) }
                catch { return .youTube(.failure(error)) }
            }
            defer { group.cancelAll() }
            var youTubeResult: Result<ResolvedStream, Error>?
            var substituteDone = false
            var held: ResolvedStream?
            while let leg = try await group.next() {
                switch leg {
                case .substitute(let stream?):
                    note("a ranked source won with \(stream.format.summary)")
                    return stream
                case .substitute(nil):
                    substituteDone = true
                    note("no ranked source had it" + (youTubeResult == nil ? "; waiting on YouTube" : ""))
                    if let youTubeResult { return try youTubeResult.get() }
                    if let held {
                        note("releasing YouTube's held stream")
                        return held
                    }
                case .youTube(.success(var stream)):
                    if request.waitsForSources, !substituteDone {
                        held = stream
                        note("YouTube ready with \(stream.format.summary); holding it for the ranked sources")
                        let spent = started.duration(to: .now)
                        let hold = ahead ? max(0, holdCap - Double(spent.components.seconds) - Double(spent.components.attoseconds) / 1e18) : holdCap
                        group.addTask {
                            try await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
                            return .waitedLongEnough
                        }
                        continue
                    }
                    // The sources are still looking: sound now, quality shortly after.
                    if !substituteDone {
                        stream.belowRequest = true
                        handOff(lookup, for: song.videoId)
                        handedOff = true
                    }
                    note("YouTube won with \(stream.format.summary)" + (substituteDone ? "" : "; ranked sources still looking, handed to the second look"))
                    return stream
                case .youTube(let failure):
                    // A YouTube walk that ended without a URL has not won anything: an age-gated
                    // track YouTube will never serve may be one a catalogue has.
                    youTubeResult = failure
                    note("YouTube failed" + (substituteDone ? "" : "; waiting on the ranked sources"))
                    if substituteDone { return try failure.get() }
                case .waitedLongEnough:
                    guard var stream = held else { continue }
                    stream.belowRequest = true
                    handOff(lookup, for: song.videoId)
                    handedOff = true
                    note("no ranked source in time; YouTube plays and the upgrade carries on with their lookup")
                    return stream
                }
            }
            if let youTubeResult { return try youTubeResult.get() }
            throw SourceResolutionError.noSource(song.title)
        }
    }

    /// The ranked sources' lookup for `videoId` that was still running when YouTube won its race,
    /// handed over once (Android `DirectSourceGate.stillLooking`): whoever takes it owns it, and
    /// cancels it if it no longer wants the answer. Nil once it has finished untaken.
    public func takeStillLooking(_ videoId: String) -> Task<ResolvedStream?, Never>? {
        lookupsLock.withLock { stillLooking.removeValue(forKey: videoId) }
    }

    private func handOff(_ lookup: Task<ResolvedStream?, Never>, for videoId: String) {
        lookupsLock.withLock { stillLooking[videoId] = lookup }
        // Kept only while it runs, as Android's is: one nobody took finishes into the sources'
        // caches, where a later search finds its answer.
        Task { [weak self] in
            _ = await lookup.value
            guard let self else { return }
            self.lookupsLock.withLock {
                if self.stillLooking[videoId] == lookup { self.stillLooking[videoId] = nil }
            }
        }
    }

    /// `lookup`'s answer, or nil as soon as the caller is cancelled: the wait is let go of, the
    /// lookup isn't.
    private static func answer(of lookup: Task<ResolvedStream?, Never>) async -> ResolvedStream? {
        // Boxed: the gate keeps an early value in an optional, where a bare nil would read as none.
        struct Answer: Sendable { var stream: ResolvedStream? }
        if Task.isCancelled { return nil }
        let gate = ResumeOnce<Answer>()
        let answer = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Answer, Never>) in
                gate.install(continuation)
                Task { gate.resume(with: Answer(stream: await lookup.value)) }
            }
        } onCancel: {
            gate.resume(with: Answer(stream: nil))
        }
        return answer.stream
    }

    // MARK: Entry points (Android's)

    /// A `vibramusic://source?s=…&t=…&n=…` URI (``SourceRegistry/trackURI(configId:trackId:)`` or
    /// PlaybackPolicy's `PlaybackURI.source`), resolved; nil when nothing enabled could serve it.
    public func resolve(uri: String, request: StreamRequest) async throws -> ResolvedStream? {
        guard let components = URLComponents(string: uri),
              let configId = components.queryItems?.first(where: { $0.name == "s" })?.value,
              let trackId = components.queryItems?.first(where: { $0.name == "t" })?.value else { return nil }
        return try await resolve(configId: configId, trackId: trackId, target: Self.target(in: uri), request: request)
    }

    /// The recording a playback URI describes (`n` title, `a` artist, `d` seconds, `l` album,
    /// `e` explicit, `m` music video), for matching it elsewhere.
    public static func target(in uri: String) -> TrackMatcher.Target {
        let items = URLComponents(string: uri)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        return TrackMatcher.Target(
            value("n") ?? "",
            value("a") ?? "",
            durationSec: value("d").flatMap { Int($0) },
            album: value("l"),
            isExplicit: value("e").map { $0 == "1" },
            isVideo: value("m") == "1"
        )
    }

    /// A source-backed track: the pinned source, stepped over when it fails, with a lossless
    /// upgrade from a higher-ranked source first when lossless is asked for and the pin can't.
    public func resolve(configId: String, trackId: String, target: TrackMatcher.Target, request: StreamRequest) async throws -> ResolvedStream? {
        let tier = request.tier
        // Downloads aren't budgeted by the connection's ceiling (see forDownload).
        let active = request.purpose == .download ? registry.active() : registry.activeForPlayback(request)
        // A pin identifies where the row came from; it does not override the source switch. Looking
        // the instance up directly reopened disabled sources' tracks already in the queue.
        let pinned = active.first { $0.configId == configId }

        if tier == .lossless, pinned?.kind.canServeLossless != true {
            for source in Self.rankedAbove(configId, active) where source.kind.canServeLossless {
                guard let upgraded = try await matchAndStream(source, target, tier) else { continue }
                // Only a genuinely lossless answer beats the pin: a lossless-capable source that
                // settled for a transcode of this track has not beaten the listener's own source.
                guard upgraded.format.isLossless == true else { continue }
                SourcesLog.d("lossless upgrade: '\(target.title)' served by \(source.displayName)")
                return upgraded
            }
        }

        if let pinned, var stream = try await attempt(pinned, { try await pinned.stream(trackId: trackId, tier: tier) }) {
            stream.sourceConfigId = pinned.configId
            return stream
        }

        // Last resort: a track whose own source is down is still a track the user asked for.
        guard let (source, stream) = try await bestAcross(active.filter { $0.configId != configId }, target, tier) else {
            return nil
        }
        SourcesLog.d("fallback: '\(target.title)' served by \(source.displayName)")
        return stream
    }

    /// The stream for a YouTube track from a source ranked above YouTube, or nil. Every ranked
    /// source is asked at once and the first playable answer taken — this is the latency-critical
    /// half, racing YouTube's own walk; ``upgradeFor(_:playing:servedBy:request:)`` is where a slow
    /// source's better answer gets its hearing.
    public func substituteForYouTube(_ target: TrackMatcher.Target, request: StreamRequest) async throws -> ResolvedStream? {
        // Video rows keep YouTube's own stream: a catalogue match is another recording and can be a
        // wrong song altogether.
        guard target.title.nonBlank != nil, !target.isVideo else { return nil }
        let active = registry.activeForPlayback(request)
        guard let youtube = active.first(where: { $0.kind == .youtube }) else { return nil }
        guard let (source, stream) = try await bestAcross(Self.rankedAbove(youtube.configId, active), target, request.tier, provesFirstBytes: true) else {
            return nil
        }
        SourcesLog.d("substituted: '\(target.title)' served by \(source.displayName) over YouTube at \(stream.format.summary)"
            + (stream.belowRequest ? " (below request)" : ""))
        return stream
    }

    /// The reliable last rung for a source-backed item whose stream failed in the player: YouTube
    /// only (the failed source must not return the same URL), found by metadata, strictly.
    public func youtubeFallback(_ target: TrackMatcher.Target) async throws -> ResolvedStream? {
        guard target.title.nonBlank != nil, !target.isVideo else { return nil }
        guard let youtube = registry.active().first(where: { $0.kind == .youtube }) else { return nil }
        let stream = try await matchAndStream(
            youtube, target, .best,
            strictLength: target.durationSec != nil,
            requireSharedArtist: true
        )
        if stream != nil { SourcesLog.d("YouTube fallback matched '\(target.title)' after its higher-quality source failed") }
        return stream
    }

    /// The copy of `target` held by a source quick enough to ask before the track plays
    /// (``SourceKind/worthPrefetching``), or nil. The caller must pin what it gets (PlaybackPolicy's
    /// StreamChoice) before caching a byte, or playback re-runs the race and may write a second
    /// source's bytes into the same cache entry.
    public func prefetchSubstitute(_ target: TrackMatcher.Target, request: StreamRequest) async throws -> ResolvedStream? {
        guard target.title.nonBlank != nil, !target.isVideo else { return nil }
        let active = registry.activeForPlayback(request)
        guard let youtube = active.first(where: { $0.kind == .youtube }) else { return nil }
        let quick = Self.rankedAbove(youtube.configId, active).filter { $0.kind.worthPrefetching }
        guard !quick.isEmpty, let (source, stream) = try await bestAcross(quick, target, request.tier) else { return nil }
        SourcesLog.d("warmed: '\(target.title)' from \(source.displayName) at \(stream.format.summary)")
        return stream
    }

    /// A stream that genuinely beats what is playing, for a track already playing — or nil.
    ///
    /// Every ranked source is asked at once, patiently (`waitForAll`), including lossy ones: the
    /// bar is ``worthSwapping(_:playing:)``, not "satisfies the request", and a 320 kbps AAC clears
    /// it over YouTube's AAC. `target` must carry the runtime of the track actually playing: length
    /// is the check a title can't fake. `servedBy` is left out (asking it again only reproduces the
    /// stream playing). A copy whose server won't send it (a 502, a dead link) is passed over for
    /// the next source's, rather than chosen and then dropped by the upgrade's own warm-up.
    public func upgradeFor(
        _ target: TrackMatcher.Target,
        playing: StreamFormat?,
        servedBy: String? = nil,
        request: StreamRequest
    ) async throws -> ResolvedStream? {
        guard target.title.nonBlank != nil, target.durationSec != nil, !target.isVideo else { return nil }
        let active = registry.activeForPlayback(request)
        guard let youtube = active.first(where: { $0.kind == .youtube }) else { return nil }
        let candidates = Self.rankedAbove(youtube.configId, active).filter { $0.configId != servedBy }
        guard let (source, chosen) = try await bestAcross(
            candidates, target, request.tier,
            waitForAll: true, strictLength: true, requireSharedArtist: true, provesFirstBytes: true,
            patience: Self.upgradePatience,
            accept: { candidate, stream in
                let worth = Self.worthSwapping(stream.format, playing: playing)
                if !worth {
                    // Named rather than skipped silently: a silent skip reads like a source having
                    // nothing.
                    SourcesLog.d("\(candidate.displayName)'s \(stream.format.summary) isn't worth swapping "
                        + "'\(target.title)' off \(playing?.summary ?? "an unmeasured stream")")
                }
                return worth
            }
        ) else { return nil }
        SourcesLog.d("upgrade found: '\(target.title)' at \(chosen.format.summary) from \(source.displayName)")
        return chosen
    }

    /// The copy of a track about to be downloaded that is worth keeping over YouTube's, or nil.
    ///
    /// 1. **Bit-exact, in rank order** — on the lossless tier only. The first genuinely lossless
    ///    (or Dolby Atmos) file wins outright.
    /// 2. **The best lossy copy otherwise**, raced across everything else at once, weighed with
    ///    ``isBetter(_:than:)``. JioSaavn's 320 comes in here.
    /// 3. **YouTube**, by returning nil — also when the best lossy copy doesn't clear
    ///    ``beatsYouTubeAac(_:)``.
    ///
    /// The capped tier (Standard, 128 kbps) returns nil at once: a source can't be asked for *that*
    /// rung, only for its best. On the best tier (High) a bit-exact answer is refused — someone who
    /// chose High chose the smaller file. Uses ``SourceRegistry/active()``, not the playback list:
    /// a download isn't budgeted by the streaming ceiling.
    public func forDownload(_ target: TrackMatcher.Target, request: StreamRequest = .download(.lossless)) async throws -> ResolvedStream? {
        guard target.title.nonBlank != nil else { return nil }
        let wantsLossless: Bool
        switch request.tier {
        case .lossless: wantsLossless = true
        case .best: wantsLossless = false
        case .capped: return nil
        }
        let active = registry.active()
        // An absent (disabled) YouTube means everything enabled outranks it.
        let youtubeId = active.first { $0.kind == .youtube }?.configId ?? ""
        let ranked = Self.rankedAbove(youtubeId, active)
        let strictLength = target.durationSec != nil
        let bitExact = wantsLossless ? ranked.filter { $0.kind.canServeLossless } : []
        let elsewhere = ranked.filter { source in !bitExact.contains { $0 === source } }

        // Asked now, read at the end, raced: these differ in speed by two orders of magnitude and
        // the whole lookup is on a clock.
        async let elsewhereBest = bestAcross(
            elsewhere, target, .best,
            waitForAll: true, strictLength: strictLength,
            accept: { source, stream in
                let ok = wantsLossless || stream.format.isLossless != true
                if !ok { SourcesLog.d("\(source.displayName) offered \(stream.format.summary); more than this download asked for") }
                return ok
            }
        )

        var best: (MusicSource, ResolvedStream)?
        for source in bitExact {
            guard let stream = try await matchAndStream(source, target, request.tier, waitForAll: true, strictLength: strictLength) else {
                continue
            }
            // Atmos is not bit-exact PCM but it is the premium rendition playback prefers.
            if stream.format.isLossless == true || stream.format.isDolbyAtmos {
                SourcesLog.d("download: '\(target.title)' from \(source.displayName) at \(stream.format.summary)")
                return stream
            }
            SourcesLog.d("\(source.displayName) offered \(stream.format.summary) to download; not lossless or Dolby")
            if Self.isBetter(stream.format, than: best?.1.format) { best = (source, stream) }
        }
        if let (source, stream) = try await elsewhereBest, Self.isBetter(stream.format, than: best?.1.format) {
            best = (source, stream)
        }
        guard let (winner, chosen) = best else { return nil }
        guard Self.beatsYouTubeAac(chosen.format) else {
            SourcesLog.d("best offered for '\(target.title)' is \(winner.displayName)'s \(chosen.format.summary); taking YouTube's AAC over that")
            return nil
        }
        SourcesLog.d("download: '\(target.title)' from \(winner.displayName) at \(chosen.format.summary), over YouTube's AAC")
        return chosen
    }

    /// Whether anything outranks YouTube right now — answerable from the source list alone, which
    /// lets the cache and read-ahead decide how to treat a YouTube id before asking anyone.
    public func canSubstituteForYouTube(_ request: StreamRequest) -> Bool {
        (registry.activeForPlayback(request).firstIndex { $0.kind == .youtube } ?? 0) > 0
    }

    // MARK: The race

    /// The best stream `sources` can serve for `target` — all asked at once — with the source that
    /// answered, or nil.
    ///
    /// Raced, not queued: measured on '9:45', JioSaavn answered in ~0.4 s and an addon in ~13.5 s,
    /// and queued behind it JioSaavn's 320 lost to YouTube every time. Rank still decides who is
    /// asked and breaks ties between answers that arrive together: once a usable answer is in, the
    /// others get ``coalesceWindow`` to cross the line and the best of those present wins (Android
    /// folded in whatever had already completed at that instant; Swift task groups can't poll, so
    /// "already completed" is "completed within a few milliseconds"). Then the rest are cancelled
    /// — unless `waitForAll`, the patient upgrade path, which must not let a fast lower tier cancel
    /// a later, better rendition.
    ///
    /// With `provesFirstBytes` (a track's start, and the copy an upgrade swaps in), an answer counts
    /// only once its server has sent audio (``firstBytesArrive(_:)``): a URL is not sound, and a
    /// dead one falls to the next source.
    func bestAcross(
        _ sources: [MusicSource],
        _ target: TrackMatcher.Target,
        _ tier: StreamRequest.Tier,
        waitForAll: Bool = false,
        strictLength: Bool = false,
        requireSharedArtist: Bool = false,
        provesFirstBytes: Bool = false,
        patience: TimeInterval? = nil,
        accept: @escaping @Sendable (MusicSource, ResolvedStream) -> Bool = { _, _ in true }
    ) async throws -> (MusicSource, ResolvedStream)? {
        guard !sources.isEmpty else { return nil }
        enum Event: Sendable {
            case answer(Int, ResolvedStream?)
            case settle
        }
        let atmos = await environment.atmosWanted()
        return try await withThrowingTaskGroup(of: Event.self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    // One line per source asked, answer or not: a source that had nothing, or was
                    // cut off by another's answer, otherwise leaves no trace at all.
                    let asked = ContinuousClock.now
                    do {
                        var stream = try await self.matchAndStream(
                            source, target, tier,
                            waitForAll: waitForAll, strictLength: strictLength,
                            requireSharedArtist: requireSharedArtist, atmosWanted: atmos
                        )
                        SourcesLog.d("\(source.displayName) answered '\(target.title)' with \(stream?.format.summary ?? "nothing") "
                            + "in \(TrackLog.ms(since: asked))ms")
                        // Weighed before it is proved: no request for a copy that wouldn't be taken.
                        if let found = stream, !accept(source, found) { stream = nil }
                        if provesFirstBytes, let found = stream {
                            let sounded = await self.firstBytesArrive(found)
                            try Task.checkCancellation()
                            SourcesLog.d("\(source.displayName)'s copy of '\(target.title)' "
                                + (sounded ? "sent its first bytes" : "sent no audio; passing over it")
                                + " at \(TrackLog.ms(since: asked))ms")
                            if !sounded { stream = nil }
                        }
                        return .answer(index, stream)
                    } catch {
                        SourcesLog.d("\(source.displayName) stopped looking for '\(target.title)' after \(TrackLog.ms(since: asked))ms"
                            + (error is CancellationError ? " (no longer needed)" : ": \(error.localizedDescription)"))
                        throw error
                    }
                }
            }
            defer { group.cancelAll() }
            var best: (index: Int, stream: ResolvedStream)?
            var settling = false
            var outstanding = sources.count
            while let event = try await group.next() {
                switch event {
                case .settle:
                    return best.map { (sources[$0.index], $0.stream) }
                case .answer(let index, let stream):
                    outstanding -= 1
                    guard let stream else { break }
                    // Ties go to rank: an equal stream from a lower-ranked source doesn't displace.
                    if best == nil || Self.isBetter(stream.format, than: best!.stream.format)
                        || (!Self.isBetter(best!.stream.format, than: stream.format) && index < best!.index) {
                        best = (index, stream)
                    }
                    // Waiting for all, a `patience` still bounds how long a usable answer waits on
                    // the rest: one source that stops answering mustn't hold it for its timeouts.
                    if let settleAfter = waitForAll ? patience : Optional(Self.coalesceWindow), !settling, outstanding > 0 {
                        settling = true
                        group.addTask {
                            try? await Task.sleep(nanoseconds: UInt64(settleAfter * 1_000_000_000))
                            return .settle
                        }
                    }
                }
                if outstanding == 0 { break }
            }
            return best.map { (sources[$0.index], $0.stream) }
        }
    }

    /// Searches `source` for `target` and streams it if an answer really is that recording.
    ///
    /// Each matcher query is tried in turn: the first failing is usually the catalogue disagreeing
    /// about how a track is *filed*. A source that throws gets no second chance — that is its
    /// server having a problem.
    func matchAndStream(
        _ source: MusicSource,
        _ target: TrackMatcher.Target,
        _ tier: StreamRequest.Tier,
        waitForAll: Bool = false,
        strictLength: Bool = false,
        requireSharedArtist: Bool = false,
        atmosWanted: Bool? = nil
    ) async throws -> ResolvedStream? {
        let atmos: Bool
        if let atmosWanted { atmos = atmosWanted } else { atmos = await environment.atmosWanted() }
        for query in TrackMatcher.queries(target) {
            guard let candidates = try await attempt(source, {
                try await source.search(query, limit: Self.matchCandidates, waitForAll: waitForAll, tier: tier)
            }) else { return nil }
            var matches = TrackMatcher.ranked(candidates, target)
            if requireSharedArtist {
                matches = matches.filter { TrackMatcher.sharesArtist(target.artist, $0.artist) }
            }
            // JioSaavn can hold different audio under one title and artist on different releases.
            // With no album on the requested track there is no honest way to choose; a unique
            // fullest credit may, otherwise this source is a miss and the known-correct fallback
            // stands.
            if source.kind == .jioSaavn, TrackMatcher.hasConflictingAlbums(matches, target) {
                guard let canonical = TrackMatcher.uniquelyMostCreditedCloseMatch(matches, target) else {
                    SourcesLog.w("\(source.displayName) returned conflicting albums for '\(target.title)'; refusing to guess")
                    continue
                }
                SourcesLog.d("\(source.displayName) resolved conflicting albums for '\(target.title)' using the uniquely fullest credit: '\(canonical.artist)'")
                matches = [canonical]
            }
            // Standing in for one specific recording: the same length to the second or so.
            if strictLength {
                matches = matches.filter { TrackMatcher.withinSeconds($0, target, Self.upgradeDriftSec) }
            } else if !target.isVideo {
                matches = matches.filter { Self.mayStartSongRow($0, target, from: source) }
            }
            if matches.isEmpty { continue }
            return try await streamBest(source, matches, target, tier, atmosWanted: atmos)
        }
        return nil
    }

    /// Whether `match` is near enough to a song row's length to start it (``startDriftSec``). The
    /// matcher's 30 s, and 90 s for a credited artist, are for a video's intro and outro, and let a
    /// same-titled recording 35 s longer take the row from the right copy that answered 7 ms later.
    /// A row or a copy stating no length has nothing to compare, and stays as it was.
    private static func mayStartSongRow(_ match: Song, _ target: TrackMatcher.Target, from source: MusicSource) -> Bool {
        guard let wanted = target.durationSec, let got = TrackMatcher.secondsOf(match.durationText),
              abs(wanted - got) > startDriftSec else { return true }
        SourcesLog.d("\(source.displayName) has '\(match.title)' at \(TrackMatcher.durationText(got)), "
            + "too far from the row's \(TrackMatcher.durationText(wanted)) to start it")
        return false
    }

    /// Opens the best of `matches` that can serve `tier`: rows advertising the tier first (see
    /// ``preferred(_:target:wantsLossless:atmosWanted:)``), and what comes back is checked — a
    /// module that can't serve lossless doesn't always say so and hands back a 128 kbps MP3 with
    /// the right title. The under-quality stream is kept as a floor (the best of what was refused).
    private func streamBest(
        _ source: MusicSource,
        _ matches: [Song],
        _ target: TrackMatcher.Target,
        _ tier: StreamRequest.Tier,
        atmosWanted: Bool
    ) async throws -> ResolvedStream? {
        let wantsLossless = tier == .lossless
        var settleFor: ResolvedStream?
        for match in Self.preferred(matches, target: target, wantsLossless: wantsLossless, atmosWanted: atmosWanted).prefix(Self.streamAttempts) {
            let trackId = SourceRegistry.parseTrackKey(match.videoId)?.trackId ?? match.videoId
            guard var stream = try await attempt(source, { try await source.stream(trackId: trackId, tier: tier) }) else {
                SourcesLog.d("\(source.displayName) has no stream for '\(match.title)' (\(trackId)); trying its next match, if any")
                continue
            }
            // The row knows how long the recording is; the URL doesn't.
            stream.durationSeconds = TrackMatcher.secondsOf(match.durationText) ?? stream.durationSeconds
            stream.sourceConfigId = source.configId
            let served = stream.format
            let row = "'\(match.title)' by '\(match.artist)' id='\(match.videoId)' album='\(match.albumName ?? "?")' "
                + "duration=\(match.durationText ?? "?") row=\(target.durationSec.map(TrackMatcher.durationText) ?? "?") "
                + "explicit=\(match.isExplicit.map(String.init) ?? "?")"
            if !wantsLossless || served.isLossless == true || served.isDolbyAtmos || Self.statesNothingLossy(served) {
                SourcesLog.d("\(source.displayName) matched \(row) → \(served.summary)")
                return stream
            }
            SourcesLog.d("\(source.displayName) offered \(served.summary) for \(row); looking further")
            stream.belowRequest = true
            if settleFor == nil || Self.isBetter(stream.format, than: settleFor!.format) { settleFor = stream }
        }
        return settleFor
    }

    /// Whether `stream`'s server starts sending audio within ``firstBytesTimeout``: one small range
    /// with the stream's own headers, read to its first byte and dropped. A lossless copy behind a
    /// slow server (an add-on fronting another service can take seconds to its first byte) must not
    /// win a start YouTube's copy could already have made, and one whose server refuses it, or
    /// hasn't answered by then, is not one to start on or swap to. For a remote playlist it is the
    /// playlist's server that answers. A file this device converted or holds has nothing to prove.
    func firstBytesArrive(_ stream: ResolvedStream) async -> Bool {
        guard let scheme = stream.url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return true }
        var request = URLRequest(url: stream.url)
        for (name, value) in stream.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=0-\(Self.firstBytesRange - 1)", forHTTPHeaderField: "Range")
        let session = environment.session
        let sounded = try? await withDeadline(Self.firstBytesTimeout) { @Sendable () async throws -> Bool in
            let (bytes, response) = try await session.bytes(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else { return false }
            for try await _ in bytes { return true }
            return false
        }
        return sounded ?? false
    }

    /// Runs `block`, turning a failure into nil and a log line: a source that throws costs the
    /// *source* its turn, not the track its playback. Cancellation is rethrown.
    private func attempt<T>(_ source: MusicSource, _ block: () async throws -> T?) async throws -> T? {
        do {
            return try await block()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            SourcesLog.w("\(source.displayName) failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T? {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }

    // MARK: Rules (pure)

    /// The matching rows in the order worth opening. Length decides which recording first: when any
    /// candidate agrees with the runtime to within ``sameRecordingSec``, only those are eligible (a
    /// 185 s DJ edit once beat the 180 s album track on the strength of the word `flac`). Then,
    /// when immersive audio is wanted, the Atmos row first — a catalogue may publish the mix as its
    /// own row, and picking the row is the only way to hear it. Then lossless between equals.
    /// Stable throughout, so the matcher's confidence order survives inside each tier.
    public static func preferred(_ matches: [Song], target: TrackMatcher.Target, wantsLossless: Bool, atmosWanted: Bool) -> [Song] {
        let sameLength = matches.filter { TrackMatcher.withinSeconds($0, target, sameRecordingSec) }
        let eligible = sameLength.isEmpty ? matches : sameLength
        if atmosWanted, let immersive = SourceQuality.immersive {
            let immersiveFirst = eligible.filter { $0.sourceQuality == immersive } + eligible.filter { $0.sourceQuality != immersive }
            if immersiveFirst.first?.sourceQuality == immersive { return immersiveFirst }
        }
        guard wantsLossless else { return eligible }
        return eligible.filter { $0.sourceQuality == .lossless } + eligible.filter { $0.sourceQuality != .lossless }
    }

    /// Whether `candidate` is a better rendition than `current`: immersive first (an Atmos stream
    /// is E-AC-3 and answers `isLossless == false`, so testing lossless first made the Atmos rule
    /// unreachable), then lossless, then bitrate. Nil `current` is beaten by anything.
    public static func isBetter(_ candidate: StreamFormat, than current: StreamFormat?) -> Bool {
        guard let current else { return true }
        if candidate.isDolbyAtmos != current.isDolbyAtmos { return candidate.isDolbyAtmos }
        if candidate.isLossless != current.isLossless { return candidate.isLossless == true }
        return (candidate.kbps ?? 0) > (current.kbps ?? 0)
    }

    /// Whether `candidate` is enough better than `playing` to be worth a seam in the audio. Never
    /// away from an immersive mix; lossless and Atmos always; lossy only with a gain of
    /// ``upgradeMinGainKbps`` (160 → 320 clears it; 128 → 192 does not). An unmeasured side is a no.
    public static func worthSwapping(_ candidate: StreamFormat, playing: StreamFormat?) -> Bool {
        if playing?.isDolbyAtmos == true, !candidate.isDolbyAtmos { return false }
        if candidate.isLossless == true || candidate.isDolbyAtmos { return true }
        guard let gained = candidate.kbps, let base = playing?.kbps else { return false }
        return gained - base >= upgradeMinGainKbps
    }

    /// Whether two runtimes are close enough to swap one into the other mid-play. Unknown is a no.
    public static func sameRecordingAs(_ candidateSec: Int?, _ playingSec: Int?) -> Bool {
        guard let candidateSec, let playingSec else { return false }
        return abs(candidateSec - playingSec) <= upgradeDriftSec
    }

    /// Whether a lossy candidate is worth keeping as a file over YouTube's AAC: it must beat the top
    /// of YouTube's ladder. An unstated bitrate is a no — a download names its file before the
    /// first byte lands.
    public static func beatsYouTubeAac(_ candidate: StreamFormat) -> Bool {
        (candidate.kbps ?? 0) > youTubeBestAacKbps
    }

    /// Unknown is not lossy: a source that states neither a codec nor a bitrate has declined to
    /// describe the stream. A stated bitrate is different — nothing states a bitrate for a FLAC.
    static func statesNothingLossy(_ format: StreamFormat) -> Bool {
        format.isLossless == nil && format.kbps == nil
    }

    /// The sources ranked above `configId`; one not in `active` ranks last.
    static func rankedAbove(_ configId: String, _ active: [MusicSource]) -> [MusicSource] {
        let index = active.firstIndex { $0.configId == configId } ?? active.count
        return Array(active.prefix(index))
    }

    // MARK: Constants

    /// Answers per query worth weighing: the matcher scores the whole list, so the album cut below
    /// three covers and a sped-up edit is still in reach.
    static let matchCandidates = 15
    /// Matching rows worth actually opening (each is a round trip).
    static let streamAttempts = 3
    /// How far a replacement's runtime may sit from the playing track's: rounding, nothing else.
    static let upgradeDriftSec = 2
    /// How far a copy's stated length may sit from a song row's and still start it. Measured against
    /// the add-ons on 222 tracks: 3 s turned away right masters with no nearer copy, and 4 s turned
    /// away a 3:30 row whose add-on copies run 3:25. The other versions 5 s off sit on rows with a nearer copy the matcher prefers;
    /// from 6 s up what comes in is mostly tributes, covers and other versions.
    static let startDriftSec = 5
    /// How close two runtimes have to be to be the same cut of a song.
    static let sameRecordingSec = 3
    /// The top of YouTube's AAC ladder (itag 141 at 256 kbps signed in).
    static let youTubeBestAacKbps = 256
    /// Sized off the two rates this decides between: YouTube around 160, a lossy module tier 320.
    static let upgradeMinGainKbps = 96
    /// How long answers arriving just after the first usable one still count as "together".
    static let coalesceWindow: TimeInterval = 0.03
    /// How long the second look waits on the other sources once it has a copy worth swapping: room
    /// for a slow catalogue's better answer, not for a dead one's timeouts. A lossy win that wasn't
    /// the lossless asked for gets a second pass, which finds a slower source's answer cached.
    static let upgradePatience: TimeInterval = 8
    /// The range ``firstBytesArrive(_:)`` asks for. Only its first byte is waited for; the rest is
    /// there so a server that only answers ranges a player would ask for answers this one too.
    static let firstBytesRange = 16 * 1_024
    /// How long ``firstBytesArrive(_:)`` waits for that first byte: the YouTube probe's budget
    /// (`StreamURLProbe.timeout`). A server slower than that to start can't keep a track playing.
    static let firstBytesTimeout: TimeInterval = 6
    /// How long a ``StreamRequest/waitsForSources`` track holds YouTube's ready stream for a ranked
    /// source, counted from when YouTube's stream is ready. Past it YouTube plays and the upgrade
    /// takes over, so a slow catalogue costs a wait, never a stall.
    static let directSourceWait: TimeInterval = 12
    /// How long a look ahead in Queue only waits for the ranked sources (both their search and
    /// holding YouTube's stream for them): a track ahead isn't playing, so the wait costs nothing
    /// audible, and the track starts on their copy rather than YouTube's.
    static let aheadSourceWait: TimeInterval = 60
    /// Android `PlaybackService.SUBSTITUTE_TIMEOUT_MS`: long enough for a module's index, engine
    /// and search, short enough that a dead server costs a pause, not a stall.
    static let substituteTimeout: TimeInterval = 20
    /// Android `Downloads.SOURCE_LOOKUP_MS`.
    static let downloadLookupTimeout: TimeInterval = 60
}
