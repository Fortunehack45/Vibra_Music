import VibraMusicCore
import Foundation
import Observation

/// The lyrics for whatever is playing, and the per-track provider picker behind them
/// (Android: the lyrics half of `MainViewModel`).
///
/// Call `load(_:preferences:)` whenever the playing track (or its duration, or the lyrics
/// settings) changes; it is a cheap no-op when those lyrics are already loaded. The panel
/// reads `lines`, `source` and `isChecked`; the provider sheet reads `providerStates` and
/// calls `selectProvider(_:)`.
@MainActor
@Observable
public final class LyricsSession {
    /// Synced lyrics for the current track; nil while unknown or absent.
    public private(set) var lines: [LyricLine]?
    /// Which source `lines` came from, for the panel's credit. Nil for lyrics read out of
    /// the file itself — what the file records is the lyrics, not which service they came
    /// from months ago.
    public private(set) var source: LyricsSource?
    /// Whether the lookup for the current track has finished. `lines` alone can't tell
    /// "still looking" from "looked, found nothing" — both are nil — and the player needs
    /// that distinction to say "Lyrics not available" only once it actually means it.
    public private(set) var isChecked = false
    /// Each provider's state for the current track, for the picker.
    public private(set) var providerStates: [LyricsSource: LyricsProviderState] = LyricsSession.untouched
    /// The provider the listener picked for this track, if any.
    public private(set) var selectedSource: LyricsSource?

    private let repository: LyricsRepository
    private let embedded: @Sendable (URL) async -> [LyricLine]?

    private struct LoadKey: Equatable {
        let videoId: String
        let sources: Set<LyricsSource>
    }

    /// What the loaded lyrics are for: the track *and* the settings that chose them, so
    /// switching a source on or off re-runs the lookup rather than leaving the last answer
    /// on a player that would now find a different one.
    private var loadedFor: LoadKey?
    private var generation = 0
    private var currentTrack: LyricsTrack?
    private var currentPreferences = LyricsPreferences.default
    private var lookup: Task<Void, Never>?
    private var manualLookups: [LyricsSource: Task<Void, Never>] = [:]
    /// Completed hits are retained for the playing track so choosing one is instant.
    private var results: [LyricsSource: LyricsResult] = [:]

    private static let untouched = Dictionary(uniqueKeysWithValues: LyricsSource.allCases.map { ($0, LyricsProviderState.notFetched) })

    public init(
        repository: LyricsRepository = .shared,
        embedded: @escaping @Sendable (URL) async -> [LyricLine]? = { await EmbeddedLyrics.lyrics(forFileAt: $0) }
    ) {
        self.repository = repository
        self.embedded = embedded
    }

    /// Loads lyrics for `track`.
    ///
    /// A file on the device is read first: a downloaded track had its lyrics fetched once
    /// already and written into its own file, so asking the same servers again is a round
    /// trip to arrive at a string that is on disk — and one that fails outright offline.
    ///
    /// Without a local file the lookup waits for the duration (the databases match on it):
    /// a call with `durationMs <= 0` is turned away *before* claiming the lookup, so the
    /// re-trigger that carries the duration is never dropped as a duplicate.
    public func load(_ track: LyricsTrack, preferences: LyricsPreferences) {
        let sources = preferences.activeSources
        let key = LoadKey(videoId: track.videoId, sources: sources)
        if loadedFor == key { return }
        // Nothing is matched when no source is on, so a missing duration is no reason to wait.
        if track.localFileURL == nil && track.durationMs <= 0 && !sources.isEmpty { return }
        loadedFor = key
        generation += 1
        let generation = generation
        currentTrack = track
        currentPreferences = preferences
        selectedSource = nil
        manualLookups.values.forEach { $0.cancel() }
        manualLookups.removeAll()
        results.removeAll()
        providerStates = Self.untouched
        lines = nil
        source = nil
        lookup?.cancel()
        if sources.isEmpty {
            // Switched off, or every source unticked. Nothing to look up and nothing to say
            // about it — the player drops the lyric strip rather than reporting no lyrics.
            isChecked = true
            return
        }
        isChecked = false
        let onEvent = eventHandler(generation: generation)
        lookup = Task { [weak self, repository, embedded] in
            // The file first, and without the duration gate: nothing is being matched here —
            // these lyrics were written into this exact file, for this exact recording.
            if let file = track.localFileURL, let found = await embedded(file) {
                guard let self, self.generation == generation else { return }
                self.lines = found
                self.source = nil
                self.isChecked = true
                return
            }
            if track.durationMs <= 0 {
                // Duration arrives a beat after the track does; wait for it.
                if let self, self.generation == generation { self.loadedFor = nil }
                return
            }
            let found = await repository.lyrics(for: track, preferences: preferences, onEvent: onEvent)
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            let selected = self.selectedSource.flatMap { self.results[$0] } ?? found
            self.lines = selected?.lines
            self.source = selected?.source
            self.isChecked = true
        }
    }

    /// Forgets the current track (e.g. playback stopped).
    public func reset() {
        generation += 1
        lookup?.cancel()
        manualLookups.values.forEach { $0.cancel() }
        manualLookups.removeAll()
        results.removeAll()
        loadedFor = nil
        currentTrack = nil
        selectedSource = nil
        providerStates = Self.untouched
        lines = nil
        source = nil
        isChecked = false
    }

    /// Picks a provider from the player's sheet. Completed hits are applied from memory;
    /// misses are inert; only an untouched provider goes online.
    public func selectProvider(_ source: LyricsSource) {
        guard let track = currentTrack else { return }
        switch providerStates[source] ?? .notFetched {
        case .found:
            selectedSource = source
            if let result = results[source] { show(result) }
        case .fetching:
            // Applied as soon as the already-running automatic attempt completes.
            selectedSource = source
        case .notFetched:
            selectedSource = source
            fetch(source, for: track, generation: generation)
        case .notFound:
            break
        }
    }

    private func fetch(_ source: LyricsSource, for track: LyricsTrack, generation: Int) {
        if let running = manualLookups[source], !running.isCancelled { return }
        let preferences = currentPreferences
        let onEvent = eventHandler(generation: generation)
        manualLookups[source] = Task { [weak self, repository] in
            repository.setPaxSenixAPIKey(preferences.paxSenixAPIKey)
            _ = await repository.lyrics(
                for: track,
                sources: [source],
                order: [source],
                prioritizeSyllableSync: false,
                onEvent: onEvent
            )
            if let self, self.generation == generation { self.manualLookups[source] = nil }
        }
    }

    /// Provider events for one generation, applied on the main actor in the order each
    /// provider's own task reports them.
    private func eventHandler(generation: Int) -> @Sendable (LyricsProviderEvent) async -> Void {
        { [weak self] event in await self?.handle(event, generation: generation) }
    }

    private func handle(_ event: LyricsProviderEvent, generation: Int) {
        guard generation == self.generation else { return }
        switch event {
        case .started(let source):
            providerStates[source] = .fetching
        case .finished(let source, let result):
            guard let result else {
                providerStates[source] = .notFound
                return
            }
            results[source] = result
            providerStates[source] = .found
            if selectedSource == source { show(result) }
        case .cancelled(let source):
            if providerStates[source] == .fetching { providerStates[source] = .notFetched }
            // A tap may have selected a provider while the priority race was still using it.
            // If the race then cancels the loser, honour the tap with a dedicated request
            // instead of leaving the row stuck at "Fetching".
            if selectedSource == source, let track = currentTrack {
                manualLookups[source] = nil
                fetch(source, for: track, generation: generation)
            }
        }
    }

    private func show(_ result: LyricsResult) {
        lines = result.lines
        source = result.source
        isChecked = true
    }
}
