import AudioCache
import AudioDSP
import AVFoundation
import VibraMusicCore
import PlaybackPolicy

extension AudioPlayerEngine {
    // MARK: - Opening items

    /// Opens `item` on the session deck at `start`. `reason` nil is a retry of the same item
    /// (no announcement, and the retry budget carries over).
    func openItem(_ item: PlayableItem, at start: TimeInterval, reason: ItemChangeReason?, source: PlayableItem.Source? = nil) {
        loadGeneration += 1
        let generation = loadGeneration
        // The item's own preload, still opening it (a skip or a track end that came first): the load
        // joins that open before the preload lets go of it. Cancelled first, the preload was its only
        // waiter, so the resolve under way was thrown away and started again from nothing.
        let joined = source == nil ? openingAudio[item.id].flatMap { $0.join() ? $0 : nil } : nil
        loadTask?.cancel()
        preloadTask?.cancel()
        active.clear()
        position = start
        isLoadingItem = true
        // Timed only when it is meant to play (a paused restore would time the listener), and a
        // retry (nil reason) keeps the original clock: first audio is measured from the tap.
        if !playWhenReady {
            awaitingFirstAudio = nil
        } else if reason != nil || awaitingFirstAudio?.itemID != item.id {
            awaitingFirstAudio = (item.id, .now)
        }
        if let reason {
            itemBecameCurrent(item, reason: reason)
        } else {
            currentItem = item
            recovery.itemBecameCurrent(item.id)
            publishNowPlaying()
        }
        updatePlayingState()
        let deck = active
        loadTask = Task { [weak self] in
            guard let self else {
                joined?.leave()
                return
            }
            do {
                let opening = ContinuousClock.now
                let entry = try await self.makeEntry(for: item, on: deck, source: source, joined: joined, preciselyTimed: start > 0)
                guard generation == self.loadGeneration, deck === self.active else { return }
                let opened = TrackLog.ms(since: opening)
                var at = start
                if self.skipSilence, start <= 0.05, let lead = await self.leadingSkipTarget(for: item.id) {
                    at = lead
                }
                PlaybackLog.debug("\(item.id) opened in \(opened)ms (source and tracks); starting at \(at)s", about: item.trackID)
                guard generation == self.loadGeneration, deck === self.active else { return }
                deck.rate = self.rate
                deck.volume = 1
                #if os(iOS)
                // Rate first, then play: on a USB DAC the session's rate is the DAC's, and asking
                // once the deck plays would re-clock it under the track's opening.
                self.audioSession?.trackSampleRate = entry.trackFormat.sampleRate
                #endif
                if self.playWhenReady { deck.play() } else { deck.pause() }
                deck.setCurrent(entry, at: at)
                self.position = at
                self.isLoadingItem = false
                self.entryBecameCurrent(entry)
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.loadGeneration else { return }
                self.isLoadingItem = false
                self.updatePlayingState()
                self.handleFailure(itemID: item.id, error: error)
            }
        }
    }

    /// Builds the `AVPlayerItem` for `item` on `deck`, with its tap when the item's content and
    /// the DSP chain call for one (see ``desiredSignalPath(for:on:)``).
    /// `preciselyTimed` for an entry that will be sought mid-song straight away.
    func makeEntry(for item: PlayableItem, on deck: PlaybackDeck, source: PlayableItem.Source? = nil,
                   joined: AudioOpenFlight? = nil, preciselyTimed: Bool = false) async throws -> DeckEntry {
        let opened = try await openAudio(for: item, source: source, joined: joined)
        try Task.checkCancellation()
        // An HLS asset has no asset-level tracks (they live on the player item's variants), so an
        // empty list only means "no audio" for a non-playlist asset.
        var asset = opened.asset
        var track = try await asset.loadTracks(withMediaType: .audio).first
        guard track != nil || asset.isStreamingPlaylist else { throw PlaybackSourceError.noAudioTrack }
        var isPrecise = asset.isStreamingPlaylist
        if !isPrecise { isPrecise = (try? await asset.load(.providesPreciseDurationAndTiming)) == true }
        if preciselyTimed, !isPrecise {
            asset = AudioStreamCache.preciselyTimed(asset)
            track = try await asset.loadTracks(withMediaType: .audio).first
            isPrecise = true
        }
        let format = if let track { await AudioTrackFormat.load(track) } else { AudioTrackFormat() }
        try Task.checkCancellation()
        let playerItem = AVPlayerItem(asset: asset)
        // Speed changes keep the pitch; spectral is the algorithm meant for music.
        playerItem.audioTimePitchAlgorithm = .spectral
        let entry = DeckEntry(
            item: item,
            playerItem: playerItem,
            asset: asset,
            audioTrack: track,
            trackFormat: format,
            loudnessDb: opened.loudnessDb ?? item.loudnessDb,
            declaredFormat: opened.settlesFormat ? opened.declaredFormat : opened.declaredFormat ?? item.declaredFormat
        )
        entry.isPreciselyTimed = isPrecise
        if entry.content == .dolbyAtmos {
            // Let the system render the object mix spatially (multichannel out over HDMI/AirPlay,
            // head-tracked on AirPods) rather than folding it to stereo first.
            playerItem.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        }
        applySignalPath(to: entry, on: deck)
        if skipSilence {
            startSilenceScan(for: item, asset: opened.asset)
            applySilenceMap(to: entry)
        }
        return entry
    }

    /// Where `entry`'s audio should go as things stand. Atmos never gets a tap; lossless gets one
    /// only while the DSP chain would change it; everything else is processed (the tap also feeds
    /// the live silence detector).
    func desiredSignalPath(for entry: DeckEntry, on deck: PlaybackDeck) -> PlaybackSignalPath {
        switch entry.content {
        case .dolbyAtmos:
            return .spatialPassthrough
        case .lossless:
            let alters = deck.binding.processor?.altersSignal(for: entry.item, loudnessDb: entry.loudnessDb) ?? false
            return alters ? .processed : .bitTransparent
        case .lossy:
            return .processed
        }
    }

    func applySignalPath(to entry: DeckEntry, on deck: PlaybackDeck) {
        let wanted = desiredSignalPath(for: entry, on: deck)
        let policy = configuration.skipSilencePolicy
        let path = entry.apply(wanted, context: TapContext(
            item: entry.item,
            loudnessDb: entry.loudnessDb,
            binding: deck.binding,
            silence: LiveSilenceDetector(threshold: policy.thresholdLevel)
        ))
        if path == .unprocessed {
            PlaybackLog.warning("no processing tap for \(entry.item.id); playing unprocessed", about: entry.item.trackID)
        } else if path != .processed {
            PlaybackLog.debug("\(entry.item.id) plays with no tap (\(path))", about: entry.item.trackID)
        }
    }

    /// Opens (or reuses) the asset behind `item`. The same asset backs the preloaded gapless copy
    /// and the crossfade's standby copy, so the source is resolved once — also when the second
    /// caller arrives while the first is still opening: it waits on that open (see
    /// ``AudioOpenFlight``). An explicit `source` (a recovery's) is always opened on its own.
    /// `joined` is a flight the caller already joined, its place as a waiter taken over here.
    func openAudio(for item: PlayableItem, source: PlayableItem.Source?, joined: AudioOpenFlight? = nil) async throws -> OpenedAudio {
        if source == nil, let cached = openedAudio[item.id] {
            joined?.leave()
            return cached
        }
        let flight: AudioOpenFlight
        if let joined {
            flight = joined
        } else if source == nil, let running = openingAudio[item.id], running.join() {
            flight = running
        } else {
            let opening = source ?? item.source
            flight = AudioOpenFlight { try await opening.open() }
            if source == nil { openingAudio[item.id] = flight }
        }
        // A failed or abandoned open must not be joined by the next caller, which would be handed
        // the same error without ever trying.
        defer { if openingAudio[item.id] === flight { openingAudio[item.id] = nil } }
        let opened = try await withTaskCancellationHandler {
            try await flight.task.value
        } onCancel: {
            flight.leave()
        }
        openedAudio[item.id] = opened
        pruneCaches()
        return opened
    }

    /// Keeps assets and silence maps only for items still in play.
    func pruneCaches() {
        var keep: Set<String> = []
        if let id = currentItem?.id { keep.insert(id) }
        if let id = upcomingItem?.id { keep.insert(id) }
        if let id = crossfade.armedIncomingID { keep.insert(id) }
        for entry in [active.current, active.queued, standby.current].compactMap({ $0 }) { keep.insert(entry.item.id) }
        if openedAudio.count > 4 {
            for key in openedAudio.keys where !keep.contains(key) { openedAudio[key] = nil }
        }
        if silenceMaps.count > 16 {
            for key in silenceMaps.keys where !keep.contains(key) { silenceMaps[key] = nil }
        }
        for (key, task) in silenceScans where !keep.contains(key) {
            task.cancel()
            silenceScans[key] = nil
        }
    }

    // MARK: - Becoming current

    /// Everything that happens when a different item becomes current, whichever way it got there:
    /// a load, a gapless advance, a crossfade handoff, a skip past an unplayable track.
    func itemBecameCurrent(_ item: PlayableItem, reason: ItemChangeReason) {
        endLiveSkip()
        shortEnd = nil
        let previousItemID = currentItem?.id
        currentItem = item
        duration = item.duration ?? 0
        hasEnded = false
        lastError = nil
        stats = nil
        signalPath = nil
        // A resolved clip never carries over to the next item: a stale clip under a changed
        // track is the one wrong thing the animated artwork could show, so it drops here and the
        // resolving side re-adds a new clip only once it really has it. The same item again
        // (repeat, a reload) keeps its clip: its resolver was not asked anything new and will
        // not run again.
        if previousItemID != item.id {
            storedAnimatedArtworks = []
            artwork.forgetFailure()
        }
        recovery.itemBecameCurrent(item.id)
        if reason == .crossfade {
            // A crossfaded track has been audible since before it was current, so "playing" never
            // flips for it; without this it would look like a track that never started.
            recovery.itemBecameAudible(item.id)
        }
        // "Sleep after this track": the queue moving on by itself is the moment the track the
        // listener meant has finished. Repeat counts too, or the timer never fires on repeat-one.
        if reason.previousEnded, sleepTimer?.afterTrack == true {
            cancelSleepTimer()
            setPlayWhenReady(false)
            active.pause()
            crossfade.syncTransport()
        }
        upcomingItem = nil
        TrackLog.trackStarted(item.trackID)
        PlaybackLog.debug("current: \(item.id) (\(reason))", about: item.trackID)
        publishNowPlaying()
        delegate?.audioPlayerEngine(self, didChangeItemTo: item, reason: reason)
        refreshUpcoming()
        checkpoint()
    }

    /// The part of becoming current that needs the loaded entry.
    func entryBecameCurrent(_ entry: DeckEntry) {
        guard entry.item.id == currentItem?.id else { return }
        if let length = entry.duration { duration = length }
        position = active.position
        signalPath = entry.signalPath
        publishPipelineFacts(for: entry)
        #if os(iOS)
        if entry.content == .dolbyAtmos { audioSession?.allowMultichannelContent() }
        // Gapless and crossfade advances ask here, as nothing runs before them; after `openItem`,
        // which asked before play, it is the same rate and a no-op.
        audioSession?.trackSampleRate = entry.trackFormat.sampleRate
        #endif
        if skipSilence {
            applySilenceMap(to: entry)
            skipIntroIfNeeded(entry, on: active)
        }
        preloadUpcoming()
        sampleStats()
        updatePlayingState()
        publishNowPlaying()
    }

    /// Publishes what the engine knows about the pipeline as an item becomes current: the decoder it
    /// names from the track's format, the rate it hands to Core Audio (the track's own), the DSP
    /// stage's format — the tap's measured one, an unmeasured one until the tap reports, or
    /// "Bypassed" for a tap-less item — and the loudness normalization readout. The Audio Pipeline
    /// sheet reads these; without them it fell back to the hardware rate and printed "—" for the
    /// decoder.
    ///
    /// Called from the "item became current" path and again from ``sampleStats()``, which is what
    /// refreshes the DSP row once the tap has prepared: the tap's format is not known yet when the
    /// item becomes current (and must never be read from the tap's prepare callback, which runs
    /// early for the queued next item).
    ///
    /// Every fact is published on every call, including the unknowns: leaving one out would keep the
    /// previous item's value on the sheet for up to the five-second sample interval.
    func publishPipelineFacts(for entry: DeckEntry) {
        let status = AudioOutputStatus.shared
        // A nonpositive rate reads as unknown, so an item with no readable track format (HLS) clears
        // the previous track's rate instead of describing the track that just ended.
        status.publishRender(sampleRateHz: entry.trackFormat.sampleRate.map { Int($0.rounded()) } ?? 0)
        status.publishDecoder(entry.trackFormat.formatID.flatMap(AudioContentKind.decoderDescription))
        switch entry.signalPath {
        case .processed:
            if let format = entry.tap?.currentFormat {
                status.publishDsp(decoderOutputFormat: format.measurementDescription, dspFormat: format.pcmDescription)
            } else {
                // The tap has not prepared yet: publish nothing measured rather than leave the
                // previous item's DSP facts on the sheet until the next sample.
                status.publishDsp(decoderOutputFormat: nil, dspFormat: nil)
            }
        case .bitTransparent:
            // The chain is available but would not change this item, so it plays with no tap.
            status.publishDsp(decoderOutputFormat: nil, dspFormat: "Bypassed")
        case .spatialPassthrough, .unprocessed:
            // No tap is possible here, so the DSP chain cannot run on this item at all.
            status.publishDsp(decoderOutputFormat: nil, dspFormat: "Bypassed", dspAvailable: false)
        }
        // Only a processed item has a tap, so only it can apply a normalization gain.
        if entry.signalPath == .processed,
           let readout = active.binding.processor?.loudnessReadout(for: entry.item, loudnessDb: entry.loudnessDb),
           readout.isActive {
            status.publishLoudness(gainDb: readout.gainDb, lufs: readout.loudnessDb)
        } else {
            status.publishLoudness(gainDb: nil, lufs: nil)
        }
    }

    // MARK: - The next item

    /// Asks the delegate what follows and preloads it for a gapless advance.
    func refreshUpcoming() {
        guard let current = currentItem else {
            upcomingItem = nil
            active.removeQueued()
            return
        }
        let next = delegate?.audioPlayerEngine(self, itemAfter: current)
        upcomingItem = next
        crossfade.onUpcomingChanged(to: next?.id)
        preloadUpcoming()
    }

    /// Queues the upcoming item on the session deck. Deferred until the current item's entry is on
    /// the deck; called again from there.
    func preloadUpcoming() {
        guard let next = upcomingItem else {
            preloadTask?.cancel()
            active.removeQueued()
            return
        }
        guard let currentEntry = active.current, currentEntry.item.id == currentItem?.id else { return }
        if let queued = active.queued, queued.item.id == next.id { return }
        // Every refresh of the queue asks again; restarting an open that is already under way for
        // this very item would only throw its resolve away and start another.
        if let running = preloadTask, !running.isCancelled, preloadingItemID == next.id { return }
        preloadTask?.cancel()
        active.removeQueued()
        let deck = active
        preloadingItemID = next.id
        preloadGeneration += 1
        let generation = preloadGeneration
        preloadTask = Task { [weak self] in
            guard let self else { return }
            // Done, one way or another: the next refresh may start it again (a failed open is retried).
            defer { if generation == self.preloadGeneration { self.preloadingItemID = nil } }
            do {
                let entry = try await self.makeEntry(for: next, on: deck)
                guard self.upcomingItem?.id == next.id, deck === self.active, deck.current === currentEntry else { return }
                if self.skipSilence, let target = self.silenceMaps[next.id]?.startPosition(policy: self.configuration.skipSilencePolicy) {
                    // Pre-seeked while queued, so the gapless advance lands past the silent intro.
                    await entry.playerItem.seek(to: CMTime(seconds: target, preferredTimescale: 1_000), toleranceBefore: .zero, toleranceAfter: .zero)
                    guard self.upcomingItem?.id == next.id, deck === self.active, deck.current === currentEntry else { return }
                }
                deck.enqueue(entry)
            } catch is CancellationError {
                return
            } catch {
                // Surfaced when the item is reached: it is opened then, and fails into recovery.
                PlaybackLog.warning("preloading \(next.id) failed: \(error)", about: next.trackID, error: error)
            }
        }
    }

    // MARK: - Deck events

    func handle(_ event: DeckEvent, from deck: PlaybackDeck) {
        switch event {
        case .advanced(let from, let to):
            guard deck === active else { return }
            itemEnded(from) { [self] in
                crossfade.onActiveAdvanced()
                itemBecameCurrent(to.item, reason: to.item.id == from.item.id ? .repeated : .ended)
                entryBecameCurrent(to)
            }
        case .endedWithoutAdvancing(let entry):
            // The outgoing deck of a crossfade ending is the controller's business.
            guard deck === active, entry === deck.current else { return }
            itemEnded(entry) { [self] in currentEnded(entry) }
        case .itemReady(let entry):
            guard deck === active, entry === deck.current else { return }
            if let length = entry.duration { duration = length }
            sampleStats()
            updatePlayingState()
            publishNowPlaying()
        case .itemFailed(let entry, let error):
            // Any deck's, any entry's: the reset took all of them.
            if RecoveryLedger.isMediaServicesReset(error) {
                mediaServicesFailed(error)
            } else if deck === active {
                if entry === deck.current {
                    handleFailure(itemID: entry.item.id, error: error)
                } else if entry === deck.queued {
                    deck.removeQueued()
                    PlaybackLog.warning("queued \(entry.item.id) failed: \(error)", about: entry.item.trackID, error: error)
                }
            } else if crossfade.armedIncomingID == entry.item.id {
                crossfade.onArmFailed(itemID: entry.item.id)
            }
        case .timeControlChanged, .stalled:
            guard deck === active else { return }
            updatePlayingState()
        case .bytesArrivedWhileHeld(let entry):
            bytesArrivedWhileHeld(entry, on: deck)
        }
    }

    /// The session deck stopped at the end of its item.
    func currentEnded(_ entry: DeckEntry) {
        if sleepTimer?.afterTrack == true {
            cancelSleepTimer()
            setPlayWhenReady(false)
            active.pause()
        }
        if active.queued != nil, let next = active.advanceToQueued() {
            if !playWhenReady { active.pause() }
            itemBecameCurrent(next.item, reason: next.item.id == entry.item.id ? .repeated : .ended)
            entryBecameCurrent(next)
            return
        }
        if let upcoming = upcomingItem {
            // The next item couldn't be queued in time (a slow resolve, or a preload that failed):
            // open it now, keeping the intent.
            openItem(upcoming, at: 0, reason: upcoming.id == entry.item.id ? .repeated : .ended)
            return
        }
        // The queue ran dry.
        hasEnded = true
        setPlayWhenReady(false)
        cancelSleepTimer()
        position = active.position
        updatePlayingState()
        publishNowPlaying()
        checkpoint()
        delegate?.audioPlayerEngine(self, didFinishQueueAfter: entry.item)
    }

    func positionTick(_ deck: PlaybackDeck) {
        guard deck === active, let entry = deck.current, entry.item.id == currentItem?.id else { return }
        position = deck.position
        logClockStarted(on: deck)
        if let length = entry.duration, abs(length - duration) > 0.01 {
            duration = length
            publishNowPlaying()
        }
        updatePlayingState()
        if skipSilence { enforceSkipSilence(on: deck, entry: entry) }
    }
}

// MARK: - What the player's clock says

extension AudioPlayerEngine {
    /// The player's clock and what stands between it and the listener, at a start or after a seek.
    /// Then, once the clock moves, how long the player said it was playing before it did.
    func logClock(_ moment: String, on deck: PlaybackDeck) {
        guard let entry = deck.current else { return }
        let timebase = entry.playerItem.timebase.map { String(format: "%.3f", CMTimebaseGetTime($0).seconds) } ?? "none"
        var line = "clock at \(moment): player \(String(format: "%.3f", deck.player.currentTime().seconds))s, timebase \(timebase)s"
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: "+")
        line += ", output latency \(Int((session.outputLatency * 1_000).rounded()))ms on \(route)"
        #endif
        let reading = line
        let asset = entry.asset
        let track = entry.item.trackID
        Task {
            let precise = (try? await asset.load(.providesPreciseDurationAndTiming)).map { $0 ? "on" : "off" } ?? "unknown"
            PlaybackLog.info(reading + ", precise timing \(precise)", about: track)
        }
        clockWatch = deck.isPlaying ? (entry: entry, from: deck.position, since: ContinuousClock.now, after: moment) : nil
    }

    func logClockStarted(on deck: PlaybackDeck) {
        guard let watch = clockWatch, deck.position != watch.from else { return }
        clockWatch = nil
        guard watch.entry === deck.current else { return }
        let waited = TrackLog.ms(since: watch.since) - Int64(((deck.position - watch.from) * 1_000).rounded())
        PlaybackLog.info("clock started \(max(waited, 0))ms after the player said it was playing, at \(watch.after)", about: watch.entry.item.trackID)
    }
}
