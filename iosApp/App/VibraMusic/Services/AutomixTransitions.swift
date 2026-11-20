import Automix
import VibraMusicCore
import Foundation
import Observation
import Playback
import Sources

// Ports the Automix half of playback/CrossfadeController.kt (`considerSmartTransition`,
// `requestAnalysisAround`, `publishAnalysisState`) and PlaybackService.kt's analyzer wiring: the
// engine asks for a transition every idle tick, this answers with Automix's plan as the engine's
// plain-data TransitionSpec, and asks the analyzer for both sides of the pair as it goes.

/// What the planner reads from the analyzer. ``TrackAnalyzer`` in the app; recorded analyses in
/// tests.
@MainActor
protocol AutomixAnalysisProviding: AnyObject {
    func analysis(for trackId: String) -> TrackAnalysis
    func state(of trackId: String) -> AutomixAnalysisState
    func request(trackId: String, uri: URL, durationSeconds: Double)
}

extension TrackAnalyzer: AutomixAnalysisProviding {}

/// Where the current Automix pair stands, for stats for nerds and the scrubber.
struct AutomixPairStatus: Hashable {
    var currentId: String
    var nextId: String
    var current: AutomixAnalysisState
    var next: AutomixAnalysisState
    /// The planner's last verdict ("before-smart-duration", "smart-analysis-fallback", …).
    var reason: String
    var style: TransitionStyle
    var isRealMix: Bool
}

/// Automix's planner behind Playback's ``TransitionPlanning``.
///
/// Before analysis lands, or when the evidence supports nothing better, the planner answers with
/// the plain equal-power fade of the fallback length — the crossfade stays the floor. A pair
/// involving a video row never reaches here (the engine keeps those to the plain crossfade).
@MainActor
@Observable
final class AutomixTransitionPlanner: TransitionPlanning {
    /// The analyzer, created on first use: its model sessions are only worth loading once Automix
    /// is actually asked for a transition.
    @ObservationIgnored private let makeAnalyzer: @MainActor () -> AutomixAnalysisProviding
    @ObservationIgnored private var analyzerStorage: AutomixAnalysisProviding?
    /// True while nothing should be measured (a Listen Together party, Automix off).
    @ObservationIgnored private let isStopped: @MainActor () -> Bool

    /// The pair the engine last asked about, published only when it changes.
    private(set) var pairStatus: AutomixPairStatus?
    @ObservationIgnored private var lastVerdict = ""

    init(isStopped: @escaping @MainActor () -> Bool = { false }, analyzer: @escaping @MainActor () -> AutomixAnalysisProviding) {
        self.isStopped = isStopped
        makeAnalyzer = analyzer
    }

    var analyzer: AutomixAnalysisProviding {
        if let analyzerStorage { return analyzerStorage }
        let made = makeAnalyzer()
        analyzerStorage = made
        return made
    }

    /// Whether the analyzer has been created (tests; the app releases nothing before that).
    var hasAnalyzer: Bool { analyzerStorage != nil }

    // MARK: TransitionPlanning

    func transitionSpec(for context: TransitionContext) -> TransitionSpec? {
        guard let outgoing = context.outgoing.song, let incoming = context.incoming.song else {
            return Self.fallbackSpec(context)
        }
        let analyzer = self.analyzer
        let incomingDuration = context.incomingDuration ?? Self.catalogueSeconds(incoming)
        if !isStopped() {
            // Every tick: a no-op once analysed or in flight, and how a track that finishes
            // caching mid-song gets picked up.
            analyzer.request(trackId: outgoing.videoId, uri: Self.analysisURI(for: outgoing), durationSeconds: context.duration)
            analyzer.request(trackId: incoming.videoId, uri: Self.analysisURI(for: incoming), durationSeconds: incomingDuration ?? 0)
        }
        let current = analyzer.analysis(for: outgoing.videoId)
        let next = analyzer.analysis(for: incoming.videoId)
        let plan = TransitionPlanner.plan(
            analysis: current,
            nextAnalysis: next,
            currentTrack: Self.info(outgoing, durationSeconds: context.duration),
            nextTrack: Self.info(incoming, durationSeconds: incomingDuration ?? 0),
            currentTime: context.position,
            duration: context.duration,
            fadeSeconds: context.fallbackOverlap,
            mode: .smart
        )
        let currentState = analyzer.state(of: outgoing.videoId)
        let nextState = analyzer.state(of: incoming.videoId)
        publish(AutomixPairStatus(
            currentId: outgoing.videoId, nextId: incoming.videoId, current: currentState, next: nextState,
            reason: plan.reason, style: plan.transitionStyle, isRealMix: plan.isRealMix
        ))
        log(plan, from: outgoing.videoId, to: incoming.videoId, current: current, next: next)
        return Self.spec(for: plan, currentState: currentState, nextState: nextState)
    }

    /// The engine's spec for an Automix plan, or nil for "no transition here" (blocked: a speech or
    /// live track, too short to mix).
    ///
    /// The scrubber marker waits for the outgoing track's whole-track pass (a head-only result has
    /// no mix-out anchors, so the window would slide once it lands) but only for the incoming
    /// track's head — its tempo and cue are exactly what a head pass measures.
    static func spec(for plan: TransitionPlan, currentState: AutomixAnalysisState, nextState: AutomixAnalysisState) -> TransitionSpec? {
        guard !plan.blocked, plan.fadeSeconds > 0 else { return nil }
        let markable = plan.markerVisible && currentState == .analysed && (nextState == .analysed || nextState == .refining)
        return TransitionSpec(
            startTime: plan.transitionStart,
            overlap: plan.fadeSeconds,
            incomingCueTime: plan.incomingCueTime,
            incomingRate: plan.incomingPlaybackRate,
            outgoingGain: .equalPowerFall,
            incomingGain: .equalPowerRise,
            filters: .ride(TransitionFilterRide(
                style: rideStyle(plan.transitionStyle),
                bassSwap: plan.bassSwap,
                bassSwapFraction: plan.bassSwapFraction,
                filterSweep: plan.filterSweep,
                vocalOverlap: plan.vocalOverlap
            )),
            markerVisible: markable
        )
    }

    static func rideStyle(_ style: TransitionStyle) -> TransitionFilterRide.Style {
        switch style {
        case .equalPower: return .equalPower
        case .gapless: return .gapless
        case .djBlend: return .djBlend
        case .djFilter: return .djFilter
        }
    }

    /// A row without a song (never the case for queue items): the plain fade.
    private static func fallbackSpec(_ context: TransitionContext) -> TransitionSpec? {
        let fade = min(context.fallbackOverlap, context.duration / 3)
        return fade > 0 ? .crossfade(endingAt: context.duration, overlap: fade) : nil
    }

    // MARK: Identity

    /// The URI the analyzer reads a row by: a device file as itself; a source-backed row as a
    /// `vibramusic://source?…` URI carrying what the catalogue match needs (the analyzer resolves it
    /// to YouTube's copy, since analysis always reads YouTube's own rendition); anything else as
    /// YouTube's watch URI.
    static func analysisURI(for song: Song) -> URL {
        if let local = PlaybackSourceFactory.localFileURL(of: song) { return local }
        if SourceRegistry.parseTrackKey(song.videoId) != nil {
            var components = URLComponents()
            components.scheme = "vibramusic"
            components.host = "source"
            components.queryItems = [
                URLQueryItem(name: "id", value: song.videoId),
                URLQueryItem(name: "title", value: song.title),
                URLQueryItem(name: "artist", value: song.artist),
                URLQueryItem(name: "d", value: song.durationMillis > 0 ? String(song.durationMillis / 1_000) : nil),
            ]
            if let url = components.url { return url }
        }
        return URL(string: "vibramusic://watch?v=\(song.videoId)")!
    }

    static func info(_ song: Song, durationSeconds: Double) -> TransitionTrackInfo {
        let ms = durationSeconds > 0 ? Int64(durationSeconds * 1_000) : Int64(song.durationMillis)
        return TransitionTrackInfo(id: song.videoId, durationMs: ms, title: song.title, artist: song.artist,
                                   album: song.albumName ?? "", albumId: song.albumId ?? "")
    }

    static func catalogueSeconds(_ song: Song) -> Double? {
        song.durationMillis > 0 ? Double(song.durationMillis) / 1_000 : nil
    }

    // MARK: Publishing

    private func publish(_ status: AutomixPairStatus) {
        if pairStatus != status { pairStatus = status }
    }

    /// One line per distinct verdict rather than one per tick (as Android logged it).
    private func log(_ plan: TransitionPlan, from: String, to: String, current: TrackAnalysis, next: TrackAnalysis) {
        let verdict = "\(plan.reason)|\(plan.transitionStyle.rawValue)|fade=\(plan.fadeMs)|cue=\(plan.incomingCueTime)"
            + "|rate=\(plan.incomingPlaybackRate)|blocked=\(plan.blocked)|policy=\(plan.policyReasons.joined(separator: ","))"
        guard verdict != lastVerdict else { return }
        lastVerdict = verdict
        DebugLog.d("Automix", "plan \(from)->\(to): \(verdict) bpm=\(current.bpm)/\(next.bpm) conf=\(current.beatConfidence)/\(next.beatConfidence)")
    }
}

/// A source-backed row's YouTube twin, so its analysis reads YouTube's copy (Android's
/// `TrackAnalyzer.youtubeVideoIdFor`, over the same search and matcher AutoPlay's seed uses).
struct AutomixYouTubeMatcher: AutomixCatalogMatcher {
    let search: @Sendable (String) async throws -> [Song]

    func youTubeVideoId(forSourceURI sourceURI: URL) async -> String? {
        let items = URLComponents(url: sourceURI, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let title = value("title"), !title.isEmpty else { return nil }
        let artist = value("artist") ?? ""
        let seconds = value("d").flatMap(Int.init)
        let song = Song(videoId: value("id") ?? "", title: title, artist: artist,
                        durationText: seconds.map { DurationText.format(seconds: $0) })
        let candidates = (try? await search("\(title) \(artist)")) ?? []
        return TrackMatcher.best(candidates, TrackMatcher.targetOf(song))?.videoId
    }
}

extension AutomixAnalysisBudget {
    /// The listener's Automix performance setting as the analyzer's CPU budget.
    init(_ mode: AutomixPerformanceMode) {
        switch mode {
        case .efficient: self = .efficient
        case .balanced: self = .balanced
        case .performance: self = .performance
        }
    }
}
