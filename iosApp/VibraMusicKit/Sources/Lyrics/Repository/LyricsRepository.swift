import VibraMusicCore
import Foundation
import os

/// Where the player gets its lyrics.
///
/// Sixteen sources (`LyricsSource`), tried in the user's priority order:
///  - BiniLyrics, BetterLyrics and PaxSenix — Apple Music TTML, per-syllable, from
///    independent hosts so one having a bad day doesn't cost the timing.
///  - LyricsPlus — the YouLy+ backend; finest timing of the lot, flakiest hosting.
///  - SimpMusic — keyed on the video id, so it can't fetch the wrong edit.
///  - Unison — contributed rather than licensed; thin, occasionally the only place a track exists.
///  - LRCLIB, Musixmatch, KuGou, Megalobiz — line-synced, but between them almost always up.
///  - YouTube captions and the YouTube Music Lyrics tab — keyed on the playing video.
///  - Genius — plain text, last resort.
///
/// Every enabled source is asked *at the same time*, but their answers are taken in order:
/// the loop awaits them one at a time in that sequence, so a lower-priority source finishing
/// first never preempts one still pending ahead of it. Asked one after another instead, a
/// miss on each source would cost its own round trip before the next was even tried, and a
/// track with no lyrics anywhere would spend the best part of a minute finding that out.
///
/// A word-timed answer wins outright. Failing that, a line-timed one is taken from the
/// highest-priority source that had it — better a whole line lighting up in sync than the
/// right animation on lyrics that don't exist.
///
/// ### Matching on the recording
///
/// Everything above matches a *name*, and a name is ambiguous in a way that matters: a
/// single and its album cut share a title, an artist and very nearly a length, and
/// routinely differ in the words. An ISRC names one recording and settles it. BiniLyrics
/// and LyricsPlus accept one, and BiniLyrics is also the one that hands them out.
///
/// So the recording is settled *before* anybody is asked for words: one small search
/// against BiniLyrics, capped at `identifyTimeout` and remembered against the video id — a
/// track asked about twice pays for this once. A downloaded or local file can skip it: its
/// own tags name the recording (`LyricsTrack.isrc`).
///
/// Only run when BiniLyrics is enabled. A source somebody has turned off is a source this
/// app does not contact — not even for something it would only use to help the others.
public final class LyricsRepository: Sendable {
    /// A repository on the app's HTTP stack (``VibraMusicHTTP``) with every built-in provider.
    public static let shared = LyricsRepository()

    /// Longest the lookup will wait to find out which recording this is. Short on purpose:
    /// knowing the recording makes every match better, but not knowing it only puts things
    /// back where they were a release ago, and a lyrics panel sitting empty because one host
    /// is having a slow morning is a worse failure than a fuzzy match.
    static let identifyTimeout: TimeInterval = 2.5

    private let providers: [LyricsSource: any LyricsProvider]
    private let identifier: (any LyricsRecordingIdentifier)?
    private let paxSenix: PaxSenixProvider?
    /// Where found lyrics are kept for a track with no connection; nil keeps nothing.
    private let store: LyricsDiskStore?
    private let recordings = LyricsISRCMemory(capacity: 100)

    /// - Parameters:
    ///   - session: the session every built-in provider uses.
    ///   - innerTube: the client the two YouTube sources use; an anonymous
    ///     `LyricsWebRemixClient` on `session` by default.
    ///   - overrides: providers to use instead of the built-in ones, by source.
    ///   - identifier: what settles the recording before the race; the built-in BiniLyrics
    ///     provider by default.
    public init(
        session: URLSession = VibraMusicHTTP.session,
        innerTube: (any LyricsInnerTubeClient)? = nil,
        overrides: [LyricsSource: any LyricsProvider] = [:],
        identifier: (any LyricsRecordingIdentifier)? = nil,
        store: LyricsDiskStore? = nil
    ) {
        self.store = store
        let innerTube = innerTube ?? LyricsWebRemixClient(session: session)
        let paxSenix = PaxSenixProvider(session: session)
        let bini = BiniLyricsProvider(session: session)
        var providers: [LyricsSource: any LyricsProvider] = [
            .biniLyrics: bini,
            .betterLyrics: BetterLyricsProvider(endpoint: .apple, session: session),
            .betterLyricsPortato: BetterLyricsProvider(endpoint: .portato, session: session),
            .paxSenix: PaxSenixAppleRoute(provider: paxSenix),
            .paxSenixSpotify: PaxSenixSpotifyRoute(provider: paxSenix),
            .paxSenixMusixmatch: PaxSenixMusixmatchRoute(provider: paxSenix),
            .lyricsPlus: LyricsPlusProvider(session: session),
            .simpMusic: SimpMusicProvider(session: session),
            .unison: UnisonProvider(session: session),
            .youtubeTranscript: YouTubeTranscriptLyricsProvider(client: innerTube),
            .youtubeMusic: YouTubeMusicLyricsProvider(client: innerTube),
            .megalobiz: MegalobizProvider(session: session),
            .kuGou: KuGouProvider(session: session),
            .lrcLib: LrcLibProvider(session: session),
            .musixmatch: MusixmatchProvider(session: session),
            .genius: GeniusProvider(session: session),
        ]
        for (source, provider) in overrides { providers[source] = provider }
        self.providers = providers
        self.identifier = identifier ?? (overrides[.biniLyrics] == nil ? bini : overrides[.biniLyrics] as? any LyricsRecordingIdentifier)
        self.paxSenix = paxSenix
    }

    /// The api.paxsenix.org key the two authenticated PaxSenix sources send.
    public func setPaxSenixAPIKey(_ key: String) {
        paxSenix?.setAPIKey(key)
    }

    /// Lyrics for `track` under the user's settings: nothing is contacted when synced lyrics
    /// are off or every source is unticked. Also applies the PaxSenix key.
    public func lyrics(
        for track: LyricsTrack,
        preferences: LyricsPreferences,
        onEvent: (@Sendable (LyricsProviderEvent) async -> Void)? = nil
    ) async -> LyricsResult? {
        setPaxSenixAPIKey(preferences.paxSenixAPIKey)
        let found = await lyrics(
            for: track,
            sources: preferences.activeSources,
            order: preferences.sourceOrder,
            prioritizeSyllableSync: preferences.prioritizeSyllableSync,
            onEvent: onEvent
        )
        if let found {
            store?.save(found, for: track.videoId)
            return found
        }
        // Nothing came back (no connection, usually): what was found last time, if lyrics are on.
        // Only from a source that is still switched on, and reported the way a live answer is, so
        // the provider picker shows the row the panel credits.
        guard !Task.isCancelled, let saved = store?.load(track.videoId), preferences.activeSources.contains(saved.source) else { return nil }
        await onEvent?(.finished(saved.source, saved))
        return saved
    }

    /// Lyrics for `track`.
    ///
    /// `sources` is the user's pick; anything not in it is not contacted at all, and an
    /// empty set means no lyrics. `order` is tried first-to-last; a source missing from it
    /// falls in after everything named, in `LyricsSource`'s own order.
    ///
    /// `prioritizeSyllableSync` decides what happens once *something* has come back: off,
    /// the highest-priority source's own answer is taken as-is, word-synced or not. On, a
    /// merely line-synced answer is kept only as a fallback, and the search keeps going
    /// through the rest of `order` for a word-synced one.
    ///
    /// `onEvent` is awaited from each provider's own task — `.started` before it asks,
    /// `.finished` with its answer (nil for a genuine miss) before that answer is used, and
    /// `.cancelled` when it lost the race mid-flight. Every event is delivered before this
    /// returns, as Android's `coroutineScope` guaranteed.
    public func lyrics(
        for track: LyricsTrack,
        sources: Set<LyricsSource>,
        order: [LyricsSource] = LyricsSource.allCases,
        prioritizeSyllableSync: Bool = false,
        onEvent: (@Sendable (LyricsProviderEvent) async -> Void)? = nil
    ) async -> LyricsResult? {
        let sequence = order.filter { sources.contains($0) } + LyricsSource.allCases.filter { sources.contains($0) && !order.contains($0) }
        if sequence.isEmpty { return nil }

        // Every source but SimpMusic is asked for a name, and YouTube's is not the name
        // anyone catalogued. Cleaned once, here, rather than by whichever source thought to.
        var request = LyricsProviderRequest(
            videoId: track.videoId,
            title: track.title.forLyricsSearch,
            artist: track.artist.artistForLyricsSearch,
            durationMs: track.durationMs,
            album: track.album
        )

        // Settled before anyone is asked for words. What the caller knows beats what we
        // worked out last time, and both beat asking again.
        let known = track.isrc.flatMap { $0.kIsBlank ? nil : $0 } ?? recordings[track.videoId]
        if let known {
            request.isrc = known
        } else if sequence.contains(.biniLyrics), let identifier {
            let identifyRequest = request
            let identified = try? await withLyricsDeadline(Self.identifyTimeout) {
                try await identifier.identify(identifyRequest)
            }
            if let identified = identified ?? nil, !identified.kIsBlank {
                recordings[track.videoId] = identified
                request.isrc = identified
            }
        }

        let bag = LyricsTaskBag()
        let started = request
        let launch: @Sendable (LyricsSource) -> Task<LyricsResult?, Never> = { [self] source in
            Task { await self.attempt(source, request: started, onEvent: onEvent) }
        }
        // Genius is a plain text web scraper. To preserve bandwidth and avoid rate limits, it
        // starts lazily and is only contacted if every higher-priority source missed.
        for source in sequence where source != .genius {
            bag.insert(source, launch(source))
        }

        return await withTaskCancellationHandler {
            var lineSynced: LyricsResult?
            var winner: LyricsResult?
            for source in sequence {
                if Task.isCancelled { break }
                // Already holding a line-synced (or plain) answer: Genius has nothing to add.
                if lineSynced != nil && source == .genius { continue }
                let task = bag.task(for: source) ?? bag.insert(source, launch(source))
                guard let found = await task.value else { continue }
                if found.isWordSynced {
                    winner = found
                    break
                }
                if !prioritizeSyllableSync && found.isTimed {
                    winner = found
                    break
                }
                // A plain answer held as the fallback gives way to a timed one behind it.
                if lineSynced == nil || (found.isTimed && lineSynced?.isTimed == false) { lineSynced = found }
            }
            // Whoever lost the race is no longer worth waiting on — but is waited for, so
            // their cancellation is reported before this returns.
            await bag.cancelAndDrain()
            return winner ?? lineSynced
        } onCancel: {
            bag.cancelAll()
        }
    }

    /// One provider's attempt, reported as it goes.
    private func attempt(
        _ source: LyricsSource,
        request: LyricsProviderRequest,
        onEvent: (@Sendable (LyricsProviderEvent) async -> Void)?
    ) async -> LyricsResult? {
        await onEvent?(.started(source))
        guard let provider = providers[source] else {
            await onEvent?(.finished(source, nil))
            return nil
        }
        do {
            let answer = try await provider.lyrics(for: request)
            // A cancelled request surfaces as a miss from the HTTP layer; tell the two apart.
            if Task.isCancelled {
                await onEvent?(.cancelled(source))
                return nil
            }
            if let isrc = answer?.isrc { recordings[request.videoId] = isrc }
            let found = answer.map { Self.result(source, $0.lines) }
            lyricsLog.debug("\(source.rawValue, privacy: .public): \(found.map { "\($0.lines.count) lines, word-synced \($0.isWordSynced)" } ?? "miss", privacy: .public)")
            await onEvent?(.finished(source, found))
            return found
        } catch {
            if Task.isCancelled || error is CancellationError {
                await onEvent?(.cancelled(source))
            } else {
                lyricsLog.debug("\(source.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                await onEvent?(.finished(source, nil))
            }
            return nil
        }
    }

    /// Whichever source won, its lines get the same last pass: the answering vocal split
    /// off the lead so it can be drawn under it. Done here rather than in each parser
    /// because most write it as a bracket and only TTML knows it structurally —
    /// `withBackgroundVocals` leaves that one's own split alone.
    static func result(_ source: LyricsSource, _ lines: [LyricLine]) -> LyricsResult {
        LyricsResult(source: source, lines: lines.withBackgroundVocals())
    }

    /// The recording remembered for a video id, if any lookup has worked it out.
    public func rememberedISRC(forVideoId videoId: String) -> String? {
        recordings[videoId]
    }
}

/// The recording behind a video id, once something has worked it out.
///
/// Bounded, least-recently-used, and in memory only. This is a shortcut, not a store:
/// losing it costs one fuzzy match, and keeping it on disk would mean keeping a wrong answer
/// on disk too.
final class LyricsISRCMemory: Sendable {
    private struct State {
        var order: [String] = []
        var values: [String: String] = [:]
    }

    private let capacity: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(capacity: Int) { self.capacity = capacity }

    subscript(videoId: String) -> String? {
        get {
            state.withLock { state in
                guard let value = state.values[videoId] else { return nil }
                state.order.removeAll { $0 == videoId }
                state.order.append(videoId)
                return value
            }
        }
        set {
            guard let newValue, !newValue.kIsBlank, !videoId.isEmpty else { return }
            let capacity = capacity
            state.withLock { state in
                state.values[videoId] = newValue
                state.order.removeAll { $0 == videoId }
                state.order.append(videoId)
                while state.order.count > capacity {
                    state.values[state.order.removeFirst()] = nil
                }
            }
        }
    }
}

/// The race's provider tasks, cancellable from a cancellation handler.
private final class LyricsTaskBag: Sendable {
    private let tasks = OSAllocatedUnfairLock(initialState: [(LyricsSource, Task<LyricsResult?, Never>)]())

    @discardableResult
    func insert(_ source: LyricsSource, _ task: Task<LyricsResult?, Never>) -> Task<LyricsResult?, Never> {
        tasks.withLock { $0.append((source, task)) }
        return task
    }

    func task(for source: LyricsSource) -> Task<LyricsResult?, Never>? {
        tasks.withLock { list in list.first { $0.0 == source }?.1 }
    }

    func cancelAll() {
        tasks.withLock { list in list.forEach { $0.1.cancel() } }
    }

    func cancelAndDrain() async {
        let all = tasks.withLock { list in list.map(\.1) }
        all.forEach { $0.cancel() }
        for task in all { _ = await task.value }
    }
}
