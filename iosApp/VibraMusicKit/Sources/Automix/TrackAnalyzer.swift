/*
 * Modeled on Orchard's own TrackAnalyzer (https://github.com/SFG5453/Orchard).
 * Phase 1 is the DSP-only pass (AutomixAnalyzer/analyzer/audio_analysis.cpp);
 * Phase 2 adds the Beat This! ONNX model (see BeatTracker) and Phase 3 the
 * open-unmix vocal mask (see VocalTracker), both over the head and tail of
 * the track, which is the only part a transition ever reads.
 *
 * Copyright (C) 2026 Kushagra Singh
 *
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation, either version 3 of the License, or (at your
 * option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
 * Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation
import os

/// Produces ``TrackAnalysis`` for tracks that are about to be mixed, and hands it to
/// ``TransitionPlanner``.
///
/// ``analysis(for:)`` is called from the crossfade watcher every tick, so it never blocks or
/// computes: it returns what is already known, and an unanalysed track simply reads as no
/// evidence, which the policy ladder answers with a plain fade.
///
/// Analysis runs one track at a time, off the caller's thread, in up to two passes per track:
/// a head-only pass over whatever opening of a still-downloading track is cached (beat grid and
/// entry points, provisional), and the whole-track pass once a complete copy exists (everything,
/// persisted to ``AutomixAnalysisStore``). A track playing off the device goes straight to the
/// whole-track pass.
///
/// iOS limits background CPU: analysis runs while the app is alive (the audio background mode
/// keeps it so during playback), at the priority ``AutomixAnalysisBudget`` asks for.
public final class TrackAnalyzer: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.fortune.vibramusic.ios", category: "Automix")

    /// What an unmeasured instant reads as. Below the policy's vocal threshold by design, so
    /// absence of measurement is never mistaken for absence of a vocal, or for the presence of one.
    static let neutralVocal = 0.5

    /// How much more than the average-bitrate estimate of the opening window to insist on before
    /// decoding it: the container header, and an opening rarely at its own average bitrate.
    static let headBytesMargin = 1.35

    /// Floor under the computed threshold, and the whole requirement when the duration is unknown.
    /// Roughly fifteen seconds at 128 kbps.
    static let minHeadBytes: Int64 = 256 * 1024

    /// How much of the container's stated duration must actually decode before the whole-track
    /// pass is trusted. Not 1.0: a decoder legitimately comes up a frame or two short.
    static let minDecodedFraction = 0.95

    /// Refusals before a track is written off as truncated rather than still filling in.
    static let maxShortDecodeAttempts = 3

    /// Clean-slate retries per rendition. One: a second identical answer means the source is
    /// serving that file rather than the cache having mangled it.
    static let maxRenditionDiscards = 1

    /// How far two renditions' container durations may differ and still count as the same cut.
    static let renditionDurationTolerance = 1.0

    /// Stand-in bitrate (about 160 kbps) for a rendition whose length isn't recorded yet, used only
    /// to rank copies against each other.
    static let assumedBytesPerSecond = 20_000.0

    /// The least decoded audio a head-only tempo estimate may rest on: around 24 beats at 120 bpm.
    static let minHeadSeconds = 12.0

    /// How much more of the file has to be cached before the head is worth decoding again.
    static let headRetryGrowth: Int64 = 2

    private let renditions: AutomixRenditionProvider?
    private let store: AutomixAnalysisStore?
    private let catalogMatcher: AutomixCatalogMatcher?
    private let isStoppedProvider: @Sendable () -> Bool
    private let budget: @Sendable () -> AutomixAnalysisBudget
    private let tracker: BeatTracker
    private let vocals: VocalTracker
    private let jobs = AutomixSerialJobs()
    private let workQueue = DispatchQueue(label: "com.fortune.vibramusic.ios.automix.analysis")

    private let lock = NSLock()
    private var results: [String: TrackAnalysis] = [:]
    private var running: Set<String> = []
    private var sourceAnalysisURIs: [String: URL] = [:]
    private var sourceResolutions: Set<String> = []
    private var sourceResolutionAttempted: Set<String> = []
    /// Tracks whose result came from the head pass and is waiting to be superseded.
    private var provisional: Set<String> = []
    /// Cached prefix size at the last head attempt on each *rendition* (not track: a track can
    /// move between copies, and a number belonging to one file must not refuse another).
    private var headAttempts: [String: Int64] = [:]
    private var headSkipLogged: Set<String> = []
    /// Whole-track refusals for decoding short, counted so a rendition still filling its holes
    /// gets a few more chances while a genuinely truncated one stops being re-decoded.
    private var shortDecodes: [String: Int] = [:]
    private var restoreAttempted: Set<String> = []
    /// Renditions that decoded short despite the cache calling them complete, so the next attempt
    /// at the same track reaches for a *different* copy.
    private var badRenditions: Set<String> = []
    /// Copies already put through the whole-track pass. What reopens a written-off track is a copy
    /// nobody has read yet — a quality upgrade, or the head fetch the analyzer itself asked for.
    private var triedRenditions: Set<String> = []
    /// Clean-slate discards per rendition, so refuse-delete-refetch cannot loop.
    private var discarded: [String: Int] = [:]
    private var released = false

    /// - Parameters:
    ///   - renditions: the playback cache. Nil analyses local files only.
    ///   - store: where results persist across launches. Nil keeps them in memory.
    ///   - catalogMatcher: resolves source-backed URIs (`vibramusic://source?...`) to a YouTube id.
    ///   - isStopped: read fresh at every entry point and between stages. While true, nothing is
    ///     started and work in flight is abandoned — a Listen Together party never mixes, so
    ///     measuring for it is pure cost.
    ///   - budget: the analysis CPU budget, read per model session and per job.
    public init(
        renditions: AutomixRenditionProvider? = nil,
        store: AutomixAnalysisStore? = AutomixAnalysisStore(),
        catalogMatcher: AutomixCatalogMatcher? = nil,
        isStopped: @escaping @Sendable () -> Bool = { false },
        budget: @escaping @Sendable () -> AutomixAnalysisBudget = { .balanced }
    ) {
        self.renditions = renditions
        self.store = store
        self.catalogMatcher = catalogMatcher
        self.isStoppedProvider = isStopped
        self.budget = budget
        self.tracker = BeatTracker(threads: { budget().inferenceThreads })
        self.vocals = VocalTracker(threads: { budget().inferenceThreads })
    }

    init(
        renditions: AutomixRenditionProvider?,
        store: AutomixAnalysisStore?,
        catalogMatcher: AutomixCatalogMatcher?,
        isStopped: @escaping @Sendable () -> Bool,
        budget: @escaping @Sendable () -> AutomixAnalysisBudget,
        beatModelURL: URL?,
        vocalModelURL: URL?
    ) {
        self.renditions = renditions
        self.store = store
        self.catalogMatcher = catalogMatcher
        self.isStoppedProvider = isStopped
        self.budget = budget
        self.tracker = BeatTracker(modelURL: beatModelURL, threads: { budget().inferenceThreads })
        self.vocals = VocalTracker(modelURL: vocalModelURL, threads: { budget().inferenceThreads })
    }

    private var stopped: Bool { isStoppedProvider() || withLock { released } }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Reading

    /// What is known about `trackId` right now: never a computation, never a block. An empty
    /// analysis for anything not yet finished, which the policy reads as no evidence.
    public func analysis(for trackId: String) -> TrackAnalysis {
        withLock { results[trackId] } ?? TrackAnalysis(trackId: trackId)
    }

    /// True once `trackId` has a result, including a failure.
    public func isAnalysed(_ trackId: String) -> Bool { withLock { results[trackId] != nil } }

    /// True while a decode and inference for `trackId` is actually in flight — the difference
    /// between something being wrong and something simply taking the seconds it takes.
    public func isAnalysing(_ trackId: String) -> Bool { withLock { running.contains(trackId) } }

    /// Where `trackId` stands, for stats for nerds and the scrubber marker.
    public func state(of trackId: String) -> AutomixAnalysisState {
        withLock { AutomixAnalysisState.of(results[trackId] ?? TrackAnalysis(trackId: trackId), running: running.contains(trackId)) }
    }

    /// Waits until every job queued so far has finished. For callers that want a result now
    /// rather than on a later tick, and for tests.
    public func waitUntilIdle() async { await jobs.drain() }

    // MARK: - Requesting

    /// Queues `trackId` (playing at `uri`) for analysis if it is not already done or in flight.
    /// Cheap to call repeatedly; callers re-request as caching progresses.
    ///
    /// A track with enough of a head cached gets the head pass first — beat grid only, over the
    /// opening window, which is all the incoming side of a transition is read for — because a
    /// track only finishes downloading once it is already playing, so waiting for the whole file
    /// is what left the incoming track of every transition unanalysed. That result is provisional
    /// and is replaced by the whole-track pass as soon as the remaining bytes arrive.
    public func request(trackId: String, uri: URL, durationSeconds: Double) {
        if trackId.isBlank { return }
        // Before anything else this would spend: resolving a source URI alone can put a catalogue
        // match on the network for a track that will never be mixed.
        if stopped { return }
        if isAnalysing(trackId) { return }
        guard let analysisURI = analysisURI(for: trackId, playbackURI: uri) else { return }

        // Queued before the cache is even consulted, so a track measured in an earlier session
        // short-circuits the whole path rather than being re-earned from evicted audio.
        restoreOnce(trackId)

        let local = AutomixLocalAudioSource.isLocal(analysisURI)
        let videoId = analysisURI.automixQueryParameter("v")
        let bad = withLock { badRenditions }
        // Complete *and* not already written off: a copy that decoded to nothing is not a copy
        // worth routing to. Not asked of a local file, which is whole from the first tick.
        let complete: [AutomixRendition] = local ? [] : (renditions?.renditions(of: analysisURI) ?? [])
            .filter { AutomixAnalysisSource.isCanonicalYouTubeRendition(videoId: videoId, cacheKey: $0.key) }
            .filter { $0.isComplete && !bad.contains($0.key) }
        let usableComplete = local || !complete.isEmpty

        let (recorded, isProvisional, untried) = withLock { () -> (TrackAnalysis?, Bool, Bool) in
            let untried = local
                ? !triedRenditions.contains(analysisURI.absoluteString)
                : complete.contains { !triedRenditions.contains($0.key) }
            return (results[trackId], provisional.contains(trackId), untried)
        }
        // Two things are worth superseding: a provisional head result, and a recorded failure once
        // a copy nobody has read yet turns up. Re-deciding a failure against the renditions that
        // produced it would spend the decode again for the same answer.
        let supersedable: Bool
        if let recorded {
            supersedable = isProvisional ? usableComplete : (!recorded.isUsable && untried)
        } else {
            supersedable = false
        }
        if recorded != nil && !supersedable {
            // A provisional result is a placeholder; what supersedes it is bytes, and nothing else
            // ever asks for the rest.
            if isProvisional && !usableComplete { renditions?.requestAnalysisHead(for: analysisURI) }
            return
        }
        // The strike count belongs to the attempt that was given up on; a reopened track starts level.
        if let recorded, !recorded.isUsable { _ = withLock { shortDecodes.removeValue(forKey: trackId) } }

        // One head attempt per growth step. Skipped for a local file: the head pass exists to get
        // ahead of a download, and there is no download.
        let headRendition = usableComplete ? nil : headWorthTrying(trackId: trackId, uri: analysisURI, durationSeconds: durationSeconds)
        if !usableComplete && headRendition == nil {
            // Nothing on disk worth decoding, so ask for something.
            renditions?.requestAnalysisHead(for: analysisURI)
            return
        }
        guard withLock({ running.insert(trackId).inserted }) else { return }

        jobs.enqueue { [self] in
            await runPass(
                trackId: trackId,
                uri: analysisURI,
                durationSeconds: durationSeconds,
                usableComplete: usableComplete,
                headRendition: headRendition
            )
        }
    }

    private func runPass(
        trackId: String,
        uri: URL,
        durationSeconds: Double,
        usableComplete: Bool,
        headRendition: AutomixRendition?
    ) async {
        defer {
            let idle = withLock { () -> Bool in
                running.remove(trackId)
                return running.isEmpty
            }
            // The sessions hold a parsed graph and its buffers for as long as they are open,
            // which a backgrounded music player cannot justify between transitions.
            if idle {
                tracker.release()
                vocals.release()
            }
        }
        // A stored result restored after this was queued makes the pass redundant; a provisional
        // one is exempt, since superseding it is the point.
        let skip = withLock { () -> Bool in
            guard let landed = results[trackId] else { return false }
            return landed.isUsable && !provisional.contains(trackId)
        }
        if skip || stopped { return }

        if usableComplete {
            let outcome = await analyze(trackId: trackId, uri: uri, durationSeconds: durationSeconds)
            if let whole = outcome.analysis {
                withLock {
                    results[trackId] = whole
                    provisional.remove(trackId)
                    shortDecodes.removeValue(forKey: trackId)
                    restoreAttempted.insert(trackId)
                }
                // Only the whole-track pass is persisted: a head result is deliberately partial.
                store?.save(trackId, whole)
            } else if outcome.decodedShort {
                withLock {
                    let strikes = (shortDecodes[trackId] ?? 0) + 1
                    shortDecodes[trackId] = strikes
                    guard strikes >= Self.maxShortDecodeAttempts else { return }
                    Self.logger.warning("Giving up on \(trackId, privacy: .public) after \(Self.maxShortDecodeAttempts) short decodes")
                    // A provisional head result already published stays: partial beats empty.
                    if !provisional.contains(trackId) {
                        results[trackId] = TrackAnalysis(status: TrackAnalysis.statusReady, trackId: trackId, duration: durationSeconds)
                    }
                }
            }
        } else if let headRendition,
                  let head = await analyzeHead(trackId: trackId, uri: uri, durationSeconds: durationSeconds, rendition: headRendition) {
            // Marked before it is published, so a reader can never see a provisional result that is
            // not flagged as one.
            withLock {
                provisional.insert(trackId)
                results[trackId] = head
            }
        }
    }

    /// Looks `trackId` up on disk, once per session, off the caller's thread.
    private func restoreOnce(_ trackId: String) {
        let first = withLock { () -> Bool in
            if results[trackId] != nil { return false }
            return restoreAttempted.insert(trackId).inserted
        }
        guard first, let store else { return }
        jobs.enqueue { [self] in
            guard let stored = store.load(trackId) else { return }
            Self.logger.debug("Restored analysis for \(trackId, privacy: .public): bpm=\(stored.bpm) conf=\(stored.beatConfidence)")
            withLock {
                if results[trackId] == nil { results[trackId] = stored }
            }
        }
    }

    // MARK: - Choosing a copy

    /// Whether enough of `uri`'s head is on disk to be worth a decode, claiming the attempt if so.
    ///
    /// The byte threshold is derived from the rendition's own average bitrate where the duration
    /// is known, because "twelve seconds of audio" is a wildly different number of bytes at 96 kbps
    /// and at lossless. An attempt is allowed again only when the cached prefix has doubled since
    /// the last one, so a track gets a handful of tries spread across its download.
    private func headWorthTrying(trackId: String, uri: URL, durationSeconds: Double) -> AutomixRendition? {
        guard let renditions else { return nil }
        let videoId = uri.automixQueryParameter("v")
        let (bad, attempts) = withLock { (badRenditions, headAttempts) }
        // Across every rendition of the recording, with the growth guard applied as a filter
        // rather than to the winner, so a refused best candidate does not end the search.
        let candidate = renditions.renditions(of: uri)
            .filter { AutomixAnalysisSource.isCanonicalYouTubeRendition(videoId: videoId, cacheKey: $0.key) }
            .filter { $0.cachedPrefix > 0 && !bad.contains($0.key) }
            .filter { rendition in
                guard let previous = attempts[rendition.key] else { return true }
                return rendition.cachedPrefix >= previous * Self.headRetryGrowth
            }
            // Most *audio*, not most bytes: renditions differ in bitrate.
            .max { headSeconds(of: $0, durationSeconds: durationSeconds) < headSeconds(of: $1, durationSeconds: durationSeconds) }
        guard let candidate else { return nil }

        let prefix = candidate.cachedPrefix
        let total = candidate.contentLength
        let needed: Int64
        if durationSeconds.isFinite && durationSeconds > Self.minHeadSeconds && total > 0 {
            let bytesPerSecond = Double(total) / durationSeconds
            needed = min(max(Int64(Self.minHeadSeconds * bytesPerSecond * Self.headBytesMargin), Self.minHeadBytes), total)
        } else {
            needed = Self.minHeadBytes
        }
        if prefix < needed {
            let firstTime = withLock { headSkipLogged.insert("\(trackId)@\(candidate.key)").inserted }
            if firstTime {
                Self.logger.debug("Head pass for \(trackId, privacy: .public) waiting: \(prefix / 1024)kB cached of \(needed / 1024)kB needed (rendition \(candidate.key, privacy: .public))")
            }
            return nil
        }
        withLock { headAttempts[candidate.key] = prefix }
        return candidate
    }

    /// Roughly how many seconds of audio a rendition's cached prefix holds. The assumed bitrate
    /// stands in where the length isn't known — which is precisely the case for a head just
    /// fetched with a bounded request.
    private func headSeconds(of rendition: AutomixRendition, durationSeconds: Double) -> Double {
        if rendition.contentLength > 0 && durationSeconds.isFinite && durationSeconds > 0 {
            return Double(rendition.cachedPrefix) * durationSeconds / Double(rendition.contentLength)
        }
        return Double(rendition.cachedPrefix) / Self.assumedBytesPerSecond
    }

    /// Picks which rendition to analyse: the lightest one that is both complete and the same cut
    /// as the track being played. The duration check is what makes sharing safe: a `#alt` copy
    /// can be a radio edit, and a beat grid borrowed across that would put every anchor seconds out.
    private func chooseRendition(trackId: String, uri: URL, durationSeconds: Double) async -> AutomixRendition? {
        guard let renditions else { return nil }
        let videoId = uri.automixQueryParameter("v")
        let bad = withLock { badRenditions }
        let complete = renditions.renditions(of: uri)
            .filter { AutomixAnalysisSource.isCanonicalYouTubeRendition(videoId: videoId, cacheKey: $0.key) }
            .filter { $0.isComplete && !bad.contains($0.key) }
        if complete.isEmpty { return nil }

        let own = renditions.cacheKey(of: uri)
        guard durationSeconds.isFinite && durationSeconds > 0 else {
            // Without a length to check a sibling against, only the player's own copy can be
            // trusted — or the only copy there is, since one copy is not a choice between cuts.
            if let mine = complete.first(where: { $0.key == own }) { return mine }
            if complete.count == 1 {
                Self.logger.debug("Analysing \(trackId, privacy: .public) from its only cached rendition \(complete[0].key, privacy: .public); no duration to check it against")
                return complete[0]
            }
            return nil
        }

        for candidate in complete {
            guard let length = await AutomixAudioDecoder.containerDuration(of: candidate.fileURL), length > 0 else { continue }
            if abs(length - durationSeconds) > Self.renditionDurationTolerance {
                Self.logger.debug("Rendition \(candidate.key, privacy: .public) rejected for \(trackId, privacy: .public): \(length)s against \(durationSeconds)s expected")
                continue
            }
            if candidate.key != own {
                Self.logger.debug("Analysing \(trackId, privacy: .public) from lighter rendition \(candidate.key, privacy: .public)")
            }
            return candidate
        }
        return nil
    }

    /// Where a whole-track pass reads its audio from, and the identity the retry bookkeeping keys
    /// off. `rendition` nil means a local file: exactly one copy, and not ours to delete.
    private struct Copy {
        var key: String
        var rendition: AutomixRendition?
        var url: URL
    }

    private func copyToRead(trackId: String, uri: URL, durationSeconds: Double) async -> Copy? {
        if AutomixLocalAudioSource.isLocal(uri) {
            // An unreadable file is still returned as a copy: its key is what marks the file as
            // tried, so it is not re-checked on every tick. Decoding it simply comes back empty.
            if !AutomixLocalAudioSource.isReadable(uri) {
                Self.logger.debug("Cannot open \(uri.lastPathComponent, privacy: .private) for analysis")
            }
            return Copy(key: uri.absoluteString, rendition: nil, url: uri)
        }
        guard let rendition = await chooseRendition(trackId: trackId, uri: uri, durationSeconds: durationSeconds) else { return nil }
        return Copy(key: rendition.key, rendition: rendition, url: rendition.fileURL)
    }

    /// Source-backed playback URIs (JioSaavn, add-ons) carry the same identity hints as a YouTube
    /// item. Resolve that identity once, then keep playback on its original URI while analysis
    /// reads the separately pinned YouTube entry.
    private func analysisURI(for trackId: String, playbackURI: URL) -> URL? {
        if playbackURI.automixQueryParameter("v") != nil || playbackURI.host != "source" { return playbackURI }
        let claim = withLock { () -> URL?? in
            if let resolved = sourceAnalysisURIs[trackId] { return .some(resolved) }
            if sourceResolutionAttempted.contains(trackId) { return .some(nil) }
            if !sourceResolutions.insert(trackId).inserted { return .some(nil) }
            return nil
        }
        if let answered = claim { return answered }
        guard let catalogMatcher else {
            withLock {
                sourceResolutionAttempted.insert(trackId)
                sourceResolutions.remove(trackId)
            }
            return nil
        }
        Task.detached(priority: .utility) { [self] in
            let videoId = await catalogMatcher.youTubeVideoId(forSourceURI: playbackURI)
            withLock {
                if let videoId, let resolved = URL(string: AutomixAnalysisSource.opusURI(videoId: videoId)) {
                    sourceAnalysisURIs[trackId] = resolved
                }
                sourceResolutionAttempted.insert(trackId)
                sourceResolutions.remove(trackId)
            }
            if let videoId {
                Self.logger.debug("Automix analysis for \(trackId, privacy: .public) will use YouTube \(videoId, privacy: .public)")
            } else {
                Self.logger.debug("No YouTube match for Automix analysis of \(trackId, privacy: .public)")
            }
        }
        return nil
    }

    // MARK: - Passes

    /// The opening window only: a beat grid, and only the fields that describe an *entry* — where
    /// the file starts making sound, the pickup, the end of the intro, the mix-in candidates.
    ///
    /// Everything describing the rest of the track (content end, outro, mix-out anchors, the energy
    /// curve and so the vocal mask) is dropped: over a 30 s head that pass does not fail, it answers
    /// confidently about a track that is mostly missing, and the planner could not tell.
    private func analyzeHead(
        trackId: String,
        uri: URL,
        durationSeconds: Double,
        rendition: AutomixRendition
    ) async -> TrackAnalysis? {
        // A sibling rendition can be a different cut. A header that will not parse yet is not held
        // against the rendition — more bytes may fix it — but a length that disagrees is.
        if durationSeconds.isFinite && durationSeconds > 0, rendition.key != renditions?.cacheKey(of: uri) {
            guard let length = await AutomixAudioDecoder.containerDuration(of: rendition.fileURL), length > 0 else {
                Self.logger.debug("Head rendition \(rendition.key, privacy: .public) for \(trackId, privacy: .public) has no readable duration yet")
                return nil
            }
            if abs(length - durationSeconds) > Self.renditionDurationTolerance {
                Self.logger.debug("Head rendition \(rendition.key, privacy: .public) rejected for \(trackId, privacy: .public): \(length)s against \(durationSeconds)s expected")
                _ = withLock { badRenditions.insert(rendition.key) }
                return nil
            }
        }

        guard let head = await region(rendition.fileURL, from: 0, to: BeatTracker.windowSeconds, features: nil, deriveFeatures: true) else {
            if !stopped { Self.logger.debug("Head pass for \(trackId, privacy: .public) could not decode rendition \(rendition.key, privacy: .public)") }
            return nil
        }
        // What was decoded, not what was asked for: a tempo read off a few seconds is a much more
        // credulous measurement, and the planner cannot see the difference.
        if head.seconds < Self.minHeadSeconds {
            Self.logger.debug("Head pass for \(trackId, privacy: .public) decoded only \(head.seconds)s; too short")
            return nil
        }
        let grid = head.grid
        let entry = head.features
        if grid == nil && entry == nil { return nil }

        Self.logger.debug("Analysed head of \(trackId, privacy: .public): bpm=\(grid?.bpm ?? entry?.bpm ?? 0) conf=\(grid?.beatConfidence ?? entry?.beatConfidence ?? 0) over \(head.seconds)s")

        return TrackAnalysis(
            status: TrackAnalysis.statusReady,
            trackId: trackId,
            duration: durationSeconds,
            bpm: grid?.bpm ?? entry?.bpm ?? 0,
            beatInterval: grid?.beatInterval ?? entry?.beatInterval ?? 0,
            beatConfidence: grid?.beatConfidence ?? entry?.beatConfidence ?? 0,
            downbeats: grid?.downbeats ?? entry?.downbeats ?? [],
            firstBeat: grid?.firstBeat ?? entry?.firstBeat ?? 0,
            key: entry?.key ?? "",
            keyConfidence: entry?.keyConfidence ?? 0,
            audibleStartTime: entry?.audibleStartTime,
            pickupTime: entry?.pickupTime,
            introEndTime: entry?.introEndTime ?? 0,
            mixInTime: entry?.mixInTime ?? 0,
            mixInCandidates: entry?.mixInCandidates ?? []
        )
    }

    /// What a whole-track pass came back with. `decodedShort` separates "this copy is broken,
    /// strike it" from "there was no copy to read", which are counted very differently.
    private struct WholeTrack {
        var analysis: TrackAnalysis?
        var decodedShort = false
    }

    private struct Structural {
        var features: TrackFeatures.Features?
        var decodedShort = false
    }

    /// Decodes the whole track and reduces it to DSP features. Everything it decodes is dead by
    /// the time it returns, which is the point of it being a function of its own.
    private func structure(trackId: String, uri: URL, copy: Copy, effectiveDuration: Double) async -> Structural {
        let abort: @Sendable () -> Bool = { [weak self] in self?.stopped ?? true }
        guard let pcm = await AutomixLocalAudioSource.withAccess(to: copy.url, {
            await AutomixAudioDecoder.decodeMono(copy.url, from: 0, to: effectiveDuration, abort: abort)
        }) else { return Structural() }

        // A decode that stops early is indistinguishable, downstream, from a track that goes
        // quiet: the analyzer reads the difference as trailing silence and puts the mix-out anchor
        // where the bytes ran out, and the track is faded out minutes early. Refused outright,
        // because a missing analysis degrades to a plain crossfade and a wrong one does not.
        let decodedSeconds = pcm.durationSeconds
        if decodedSeconds < effectiveDuration * Self.minDecodedFraction {
            Self.logger.warning("Analysis of \(trackId, privacy: .public) refused: \(copy.key, privacy: .public) decoded \(decodedSeconds)s of a \(effectiveDuration)s container — \(copy.rendition != nil ? "cached with holes?" : "truncated file?", privacy: .public)")
            // Both halves are about renditions. A local file has no sibling to route to and is not
            // ours to delete; the three-strike count is the whole bound there.
            if let rendition = copy.rendition {
                let discardsSoFar = withLock { () -> Int in
                    badRenditions.insert(rendition.key)
                    return discarded[rendition.key] ?? 0
                }
                // Thrown off disk, not merely remembered: a file the cache calls complete will
                // never be rewritten, so only deleting it lets a clean copy be fetched.
                if rendition.isComplete && discardsSoFar < Self.maxRenditionDiscards,
                   renditions?.discardBadRendition(for: uri, key: rendition.key) == true {
                    // Every memory of that copy goes with the bytes, or the clean replacement
                    // would be filtered straight back out.
                    withLock {
                        discarded[rendition.key, default: 0] += 1
                        badRenditions.remove(rendition.key)
                        triedRenditions.remove(rendition.key)
                        shortDecodes.removeValue(forKey: trackId)
                    }
                }
            }
            return Structural(decodedShort: true)
        }

        let features = await onWorker { () -> TrackFeatures.Features? in
            let samples: [Float]?
            if abs(pcm.sampleRate - TrackFeatures.sampleRate) > 1 {
                samples = AutomixResampler.resample(pcm.samples, from: pcm.sampleRate, to: TrackFeatures.sampleRate)
            } else {
                samples = pcm.samples
            }
            return samples.flatMap { TrackFeatures.analyze($0, durationSeconds: effectiveDuration) }
        }
        return Structural(features: features)
    }

    /// The whole-track pass. A nil analysis means "not now, try again".
    private func analyze(trackId: String, uri: URL, durationSeconds: Double) async -> WholeTrack {
        guard let copy = await copyToRead(trackId: trackId, uri: uri, durationSeconds: durationSeconds) else {
            return WholeTrack()
        }
        // Recorded before the outcome is known: what this gates is whether a written-off track is
        // worth reopening, and that is only ever "yes" for a copy that has not been read yet.
        _ = withLock { triedRenditions.insert(copy.key) }

        var effectiveDuration = durationSeconds
        if !effectiveDuration.isFinite || effectiveDuration <= 0 {
            effectiveDuration = await AutomixLocalAudioSource.withAccess(to: copy.url) {
                await AutomixAudioDecoder.containerDuration(of: copy.url)
            } ?? 0
        }
        if effectiveDuration <= 0 {
            Self.logger.debug("Skipping \(trackId, privacy: .public): \(copy.key, privacy: .public) has no readable duration")
            return WholeTrack(analysis: empty(trackId, 0))
        }

        // Pass 1 (DSP): the whole track at the analyzer's low rate — the energy curve, phrase
        // structure and mix-out anchor all read the tail, not just a window of it.
        let structural = await structure(trackId: trackId, uri: uri, copy: copy, effectiveDuration: effectiveDuration)
        // Read *before* the two lines below: an abort comes back as a decode that produced
        // nothing, and that is exactly what they would record as "cannot be analysed".
        if stopped { return WholeTrack() }
        if structural.decodedShort { return WholeTrack(decodedShort: true) }
        guard let features = structural.features else { return WholeTrack(analysis: empty(trackId, effectiveDuration)) }

        // Pass 2 (models): the beat grid and the vocal mask over the head and tail only. A
        // transition reads the tail of the outgoing track and the head of the incoming one, and a
        // track is both of those at different moments; the middle is never decoded for this.
        let window = BeatTracker.windowSeconds
        let tailStart = max(0, effectiveDuration - window)
        let head = await region(copy.url, from: 0, to: min(window, effectiveDuration), features: features)
        if stopped { return WholeTrack() }
        let tail = tailStart > window / 2
            ? await region(copy.url, from: tailStart, to: effectiveDuration, features: features)
            : nil
        // An abort during the tail leaves `tail` nil, which is indistinguishable from a window the
        // models found nothing in; a result assembled from a half-finished analysis is worse than none.
        if stopped { return WholeTrack() }

        let headGrid = head?.grid
        let tailGrid = tail?.grid
        // The tail governs where the outgoing track is mixed out, so it takes precedence; the head
        // is what a track uses when it is the *incoming* side of a different transition.
        let leading = tailGrid ?? headGrid

        Self.logger.debug("Analysed \(trackId, privacy: .public): bpm=\(leading?.bpm ?? features.bpm) conf=\(leading?.beatConfidence ?? features.beatConfidence) key=\(features.key, privacy: .public) contentEnd=\(features.contentEndTime) vocalMask=\(head?.vocalMask != nil || tail?.vocalMask != nil ? "model" : "dsp", privacy: .public)")

        var downbeats = (headGrid?.downbeats ?? []) + (tailGrid?.downbeats ?? [])
        if downbeats.isEmpty { downbeats = features.downbeats }
        return WholeTrack(analysis: TrackAnalysis(
            status: TrackAnalysis.statusReady,
            trackId: trackId,
            duration: effectiveDuration,
            bpm: leading?.bpm ?? features.bpm,
            beatInterval: leading?.beatInterval ?? features.beatInterval,
            beatConfidence: leading?.beatConfidence ?? features.beatConfidence,
            downbeats: downbeats.sorted(),
            phraseBoundaries: features.phraseBoundaries,
            firstBeat: headGrid?.firstBeat ?? features.firstBeat,
            key: features.key,
            keyConfidence: features.keyConfidence,
            audibleStartTime: features.audibleStartTime,
            pickupTime: features.pickupTime,
            introEndTime: features.introEndTime,
            contentEndTime: features.contentEndTime > 0 ? features.contentEndTime : effectiveDuration,
            outroStartTime: features.outroStartTime,
            mixInTime: features.mixInTime,
            mixOutTime: features.mixOutTime,
            mixInCandidates: features.mixInCandidates,
            mixOutCandidates: features.mixOutCandidates,
            energyCurve: features.energyCurve,
            lowEnergyCurve: features.lowEnergyCurve,
            // The model's mask where it ran, the DSP heuristic's where it didn't: the policy reads
            // an absent mask and a neutral one identically, so a failed model pass would otherwise
            // silently discard the estimate the DSP pass already had.
            vocalActivityMask: Self.mergeMasks(size: features.energyCurve.count, head: head?.vocalMask, tail: tail?.vocalMask)
                ?? features.vocalActivityMask,
            vocalProbability: features.vocalProbability
        ))
    }

    /// Everything a decoded region contributes, once its audio has been let go of.
    private struct Region {
        var grid: BeatTracker.Grid?
        var vocalMask: [Double]?
        /// What was actually decoded, which for a partially cached file is not what was asked for.
        var seconds: Double
        var features: TrackFeatures.Features?
    }

    /// Decodes one stereo region and runs both models over it, returning only their results. The
    /// extractor can start slightly before what was asked for, so the region's real start is what
    /// beat times are stated against.
    private func region(
        _ url: URL,
        from start: Double,
        to end: Double,
        features: TrackFeatures.Features?,
        deriveFeatures: Bool = false
    ) async -> Region? {
        let abort: @Sendable () -> Bool = { [weak self] in self?.stopped ?? true }
        guard let stereo = await AutomixLocalAudioSource.withAccess(to: url, {
            await AutomixAudioDecoder.decodeStereo(url, from: start, to: end, abort: abort)
        }) else {
            Self.logger.debug("Region [\(start), \(end)) would not open")
            return nil
        }
        if Double(stereo.left.count) < stereo.sampleRate {
            Self.logger.debug("Region [\(start), \(end)) decoded \(stereo.left.count) frames; too few")
            return nil
        }
        let seconds = stereo.durationSeconds
        let tracker = self.tracker
        let vocals = self.vocals
        return await onWorker { () -> Region in
            // The full-rate mono downmix is the largest single allocation here and is read exactly
            // twice, so both of its readers are fed inside one scope that releases it.
            let (forModel, derived) = Self.regionInputs(
                stereo,
                seconds: seconds,
                deriveFeatures: deriveFeatures,
                modelInput: tracker.isConfigured
            )
            return Region(
                grid: forModel.flatMap { tracker.track($0, offsetSeconds: stereo.startSeconds) },
                vocalMask: features.flatMap { Self.vocalMask(stereo, features: $0, actualStart: stereo.startSeconds, vocals: vocals) },
                seconds: seconds,
                features: derived
            )
        }
    }

    private static func regionInputs(
        _ stereo: AutomixAudioDecoder.StereoPCM,
        seconds: Double,
        deriveFeatures: Bool,
        modelInput: Bool
    ) -> (forModel: [Float]?, derived: TrackFeatures.Features?) {
        var mono = [Float](repeating: 0, count: stereo.left.count)
        for index in mono.indices { mono[index] = (stereo.left[index] + stereo.right[index]) * 0.5 }
        // Not made at all without a beat model to read it: the resample is a full pass over the
        // window at the source rate.
        let forModel: [Float]?
        if !modelInput {
            forModel = nil
        } else if abs(stereo.sampleRate - MelSpectrogram.sampleRate) > 1 {
            forModel = AutomixResampler.resample(mono, from: stereo.sampleRate, to: MelSpectrogram.sampleRate)
        } else {
            forModel = mono
        }
        var derived: TrackFeatures.Features?
        if deriveFeatures {
            let forFeatures = abs(stereo.sampleRate - TrackFeatures.sampleRate) > 1
                ? AutomixResampler.resample(mono, from: stereo.sampleRate, to: TrackFeatures.sampleRate)
                : mono
            derived = forFeatures.flatMap { TrackFeatures.analyze($0, durationSeconds: seconds) }
        }
        return (forModel, derived)
    }

    /// A vocal-presence value for every point on the energy curve, filled only where the model
    /// actually ran. Everywhere else stays at ``neutralVocal``, below the policy's threshold, so
    /// unmeasured material can never trip vocal logic in either direction.
    private static func vocalMask(
        _ stereo: AutomixAudioDecoder.StereoPCM,
        features: TrackFeatures.Features,
        actualStart: Double,
        vocals: VocalTracker
    ) -> [Double]? {
        let curve = features.energyCurve
        // Android asks whether the native front end loaded; here the equivalent question is
        // whether there is a model to run, asked before the channels are copied and resampled.
        if curve.isEmpty || !vocals.isConfigured { return nil }

        // The beat model's window is longer than the vocal model's fixed input, so the region is
        // trimmed rather than refused. Two frames of margin absorb the ±1 sample a rate conversion
        // can land on.
        let maxSeconds = Double(VocalTracker.fixedFrames - 2) * Double(VocalSpectrogram.hop) / VocalSpectrogram.sampleRate
        let maxSamples = min(Int(maxSeconds * stereo.sampleRate), stereo.left.count)
        if maxSamples <= 0 { return nil }
        let left = maxSamples < stereo.left.count ? Array(stereo.left.prefix(maxSamples)) : stereo.left
        let right = maxSamples < stereo.right.count ? Array(stereo.right.prefix(maxSamples)) : stereo.right

        guard let values = vocals.track(left: left, right: right, sampleRate: stereo.sampleRate) else { return nil }

        var mask = [Double](repeating: neutralVocal, count: curve.count)
        for index in curve.indices {
            let frame = Int((curve[index].time - actualStart) * VocalSpectrogram.frameRate)
            if values.indices.contains(frame) { mask[index] = Double(values[frame]) }
        }
        return mask
    }

    /// Overlays the head and tail masks onto one full-length curve, or nil when neither ran —
    /// which the caller answers by keeping the DSP heuristic.
    static func mergeMasks(size: Int, head: [Double]?, tail: [Double]?) -> [Double]? {
        if size <= 0 || (head == nil && tail == nil) { return nil }
        var merged = [Double](repeating: neutralVocal, count: size)
        for source in [head, tail].compactMap({ $0 }) {
            for index in merged.indices where index < source.count && source[index] != neutralVocal {
                merged[index] = source[index]
            }
        }
        return merged
    }

    /// Recorded ready-but-empty so a track that cannot be decoded is not retried every tick.
    private func empty(_ trackId: String, _ durationSeconds: Double) -> TrackAnalysis {
        TrackAnalysis(status: TrackAnalysis.statusReady, trackId: trackId, duration: durationSeconds)
    }

    /// Runs CPU-heavy synchronous work (the C++ analyzer, the models) on the analysis queue at the
    /// budget's priority, keeping it off Swift's cooperative pool.
    private func onWorker<T>(_ body: @escaping () -> T) async -> T {
        let qos = budget().qos
        let work = UncheckedSendable(body)
        return await withCheckedContinuation { continuation in
            workQueue.async(qos: qos) {
                continuation.resume(returning: UncheckedSendable(work.value()).value)
            }
        }
    }

    /// Stops everything: queued work is dropped, work in flight is abandoned at its next check,
    /// and every model session and bookkeeping set is released.
    public func release() {
        withLock {
            released = true
            // A job dropped with the queue never reaches the defer that would clear its entry.
            running.removeAll()
            sourceAnalysisURIs.removeAll()
            sourceResolutions.removeAll()
            sourceResolutionAttempted.removeAll()
            headAttempts.removeAll()
            headSkipLogged.removeAll()
            provisional.removeAll()
            restoreAttempted.removeAll()
            shortDecodes.removeAll()
            badRenditions.removeAll()
            triedRenditions.removeAll()
            discarded.removeAll()
        }
        jobs.close()
        tracker.release()
        vocals.release()
    }
}

/// A single-consumer queue of async jobs: Android's single-threaded executor, for work that has
/// to await (asset loading) between its synchronous stages.
final class AutomixSerialJobs: @unchecked Sendable {
    typealias Job = @Sendable () async -> Void

    /// A drain marker is not work: it resolves whether or not the queue was closed, or a caller
    /// waiting on it is stranded.
    private enum Item: Sendable {
        case work(Job)
        case marker(CheckedContinuation<Void, Never>)
    }

    private final class Closed: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    private let continuation: AsyncStream<Item>.Continuation
    private let closed = Closed()

    init() {
        let (stream, continuation) = AsyncStream<Item>.makeStream()
        self.continuation = continuation
        let closed = closed
        Task.detached(priority: .utility) {
            for await item in stream {
                switch item {
                case .work(let job): if !closed.isSet { await job() }
                case .marker(let done): done.resume()
                }
            }
        }
    }

    func enqueue(_ job: @escaping Job) {
        continuation.yield(.work(job))
    }

    /// Returns once every job enqueued before this call has run or, if the queue is closed first,
    /// been dropped (or at once if it is already closed).
    func drain() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            if case .terminated = continuation.yield(.marker(done)) { done.resume() }
        }
    }

    /// Drops everything not yet started. A job already running is not interrupted; it stops at
    /// its own next check.
    func close() {
        closed.set()
        continuation.finish()
    }

    deinit { close() }
}
