import AVFoundation
import VibraMusicCore

extension AudioPlayerEngine {
    var silencePolicy: SkipSilencePolicy { configuration.skipSilencePolicy }

    func skipSilenceChanged() {
        if skipSilence {
            for entry in [active.current, active.queued, standby.current].compactMap({ $0 }) {
                startSilenceScan(for: entry.item, asset: entry.asset)
                applySilenceMap(to: entry)
            }
        } else {
            endLiveSkip()
            silenceScans.values.forEach { $0.cancel() }
            silenceScans.removeAll()
            for entry in [active.current, active.queued, standby.current].compactMap({ $0 }) {
                entry.trimEnd(at: nil)
            }
        }
    }

    /// Starts the look-ahead scan for `item`, unless it has already been scanned (or can't be).
    func startSilenceScan(for item: PlayableItem, asset: AVURLAsset) {
        guard configuration.scansAheadForSilence, silenceScans[item.id] == nil,
              silenceMaps[item.id]?.isComplete != true, !silenceScanFailures.contains(item.id) else { return }
        let policy = silencePolicy
        let id = item.id
        // A file gets an asset of its own so the scan never contends with the player's.
        let scanAsset = item.fileURL.map { AVURLAsset(url: $0) } ?? asset
        let report: @Sendable (SilenceMap) -> Void = { [weak self] map in
            Task { @MainActor in self?.silenceMapFound(map, for: id) }
        }
        let fail: @Sendable (Error) -> Void = { [weak self] error in
            Task { @MainActor in self?.silenceScanFailed(id, error: error) }
        }
        // User-initiated, not utility: the item being opened waits (briefly) on this scan's leading
        // verdict so it can start past a silent intro, and the whole scan is a fraction of a second.
        silenceScans[id] = Task.detached(priority: .userInitiated) {
            do {
                let map = try await SilenceScanner.scan(asset: scanAsset, policy: policy, onLeadingVerdict: report)
                report(map)
            } catch is CancellationError {
                return
            } catch {
                fail(error)
            }
        }
    }

    func silenceMapFound(_ map: SilenceMap, for id: String) {
        // The leading verdict can arrive after the full map; never replace a complete map.
        if silenceMaps[id]?.isComplete == true, !map.isComplete { return }
        silenceMaps[id] = map
        if map.isComplete { silenceScans[id] = nil }
        guard skipSilence else { return }
        for entry in [active.current, active.queued, standby.current].compactMap({ $0 }) where entry.item.id == id {
            applySilenceMap(to: entry)
        }
        if let entry = active.current, entry.item.id == id {
            skipIntroIfNeeded(entry, on: active)
        }
        if let queued = active.queued, queued.item.id == id, let target = map.startPosition(policy: silencePolicy) {
            queued.playerItem.seek(to: CMTime(seconds: target, preferredTimescale: 1_000), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
        }
    }

    func silenceScanFailed(_ id: String, error: Error) {
        silenceScans[id] = nil
        silenceScanFailures.insert(id)
        PlaybackLog.debug("can't scan \(id) ahead for silence (\(error)); the live detector covers it", about: id)
    }

    /// Trims a silent outro so the item ends — and the queue advances gaplessly — where the music
    /// does.
    func applySilenceMap(to entry: DeckEntry) {
        guard skipSilence, let map = silenceMaps[entry.item.id] else { return }
        entry.trimEnd(at: map.endPosition(policy: silencePolicy))
    }

    /// Jumps past a silent intro if the item is still in it.
    func skipIntroIfNeeded(_ entry: DeckEntry, on deck: PlaybackDeck) {
        guard skipSilence, let target = silenceMaps[entry.item.id]?.startPosition(policy: silencePolicy) else { return }
        let at = deck.position
        guard at < target - 0.1, at < 0.75 else { return }
        PlaybackLog.debug("skipping \(String(format: "%.2f", target))s of silent intro", about: entry.item.trackID)
        deck.seek(to: target)
        if deck === active { position = target }
    }

    /// Waits briefly for the scan's leading verdict so an item can open past its silent intro rather
    /// than playing into it and jumping. A local file answers in milliseconds.
    func leadingSkipTarget(for id: String, timeout: TimeInterval = 0.4) async -> TimeInterval? {
        guard configuration.scansAheadForSilence else { return nil }
        let deadline = clock.now + timeout
        while silenceMaps[id] == nil, silenceScans[id] != nil, !silenceScanFailures.contains(id), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(15))
        }
        return silenceMaps[id]?.startPosition(policy: silencePolicy)
    }

    /// Run from the position tick: jumps out of a silent gap the playhead has entered.
    func enforceSkipSilence(on deck: PlaybackDeck, entry: DeckEntry) {
        let at = deck.position
        let map = silenceMaps[entry.item.id]
        if let map, let target = map.skipTarget(at: at, policy: silencePolicy) {
            PlaybackLog.debug("skipping silence \(String(format: "%.2f", at))s → \(String(format: "%.2f", target))s", about: entry.item.trackID)
            deck.seek(to: target)
            position = target
            return
        }
        if map?.isComplete == true { return }
        enforceLiveSkip(on: deck, entry: entry, at: at)
    }

    /// Speed at which the live fallback runs through a silent gap. The spectral time-pitch
    /// algorithm the items use accepts up to 32×; 8× clears a ten-second gap in about a second
    /// while the tap still sees every buffer.
    static let liveSkipRate: Float = 8

    /// The live fallback: fast-forward, muted, through a gap the tap is inside, then return to
    /// just before where sound resumed (see ``LiveSilenceDetector``).
    func enforceLiveSkip(on deck: PlaybackDeck, entry: DeckEntry, at: TimeInterval) {
        guard let detector = entry.tap?.silence else { return }
        let keep = silencePolicy.retained(for: silencePolicy.minimumSilence) / 2
        if detector.isSkipping {
            guard let resume = detector.resumePoint else { return }
            let target = max(resume - keep, 0)
            PlaybackLog.debug("live skip: sound again at \(String(format: "%.2f", resume))s; back to \(String(format: "%.2f", target))s", about: entry.item.trackID)
            endLiveSkip()
            deck.seek(to: target)
            position = target
            return
        }
        guard !crossfade.isTransitioning, deck.playWhenReady,
              let run = detector.ongoingRun, run.length >= silencePolicy.minimumSilence, at >= run.start + keep else { return }
        PlaybackLog.debug("live skip: fast-forwarding a gap from \(String(format: "%.2f", run.start))s", about: entry.item.trackID)
        detector.beginSkipping()
        liveSkip = (deck, entry)
        deck.rate = Self.liveSkipRate
    }

    /// Drops out of a live fast-forward: normal speed, detector unmuted. Called on the way back to
    /// sound, and on anything that takes the deck elsewhere (seek, pause, item change, turning skip
    /// silence off).
    func endLiveSkip() {
        guard let (deck, entry) = liveSkip else { return }
        liveSkip = nil
        entry.tap?.silence.endSkipping()
        // Even mid-transition: a skip only starts on the session deck outside one, so this deck is
        // the outgoing side, which the controller never stretches.
        deck.rate = rate
    }
}
