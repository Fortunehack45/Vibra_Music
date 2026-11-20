import AVFoundation
import VibraMusicCore

extension AudioPlayerEngine {
    /// How far ahead of the playhead a copy being swapped in is cued: room to open it and buffer
    /// there while the playing copy carries on. Doubled each time the playhead gets there first.
    static let swapLead: TimeInterval = 2
    /// The longest a swap holds the standby deck before it falls back to a cut.
    static let swapDeadline: Duration = .seconds(8)
    /// The crossover between the two copies once both are sounding: short enough to hide nothing,
    /// long enough not to click.
    static let swapFade: TimeInterval = 0.08
    /// How late past its cue the copy may still start: the two then sound this far apart for the
    /// crossover, where any more would be heard as a repeat.
    static let swapSlack: TimeInterval = 0.05
    /// How far ahead of the cue the handover begins at least, so its synchronized start has time to
    /// be scheduled.
    static let swapSyncLead: TimeInterval = 0.25
    /// The least time ahead a synchronized start is scheduled in; with less, the copy starts plainly.
    static let swapSyncMargin: TimeInterval = 0.1

    /// Moves the current track onto `item`, another copy of the same recording on the same
    /// timeline (a quality upgrade, a revert to YouTube's own), with no gap in the audio.
    ///
    /// ``load(_:startingAt:playWhenReady:)`` cuts first: it empties the session deck, then opens
    /// the copy and buffers at the playhead in silence, which for a remote lossless copy was a
    /// second or two. Here the copy opens on the standby deck, cued ``swapLead`` ahead of
    /// the playhead and prerolled there while the current copy plays on. When the playhead reaches
    /// the cue the standby starts, the two cross over in ``swapFade``, and the session moves onto
    /// it. Transitions are held meanwhile (``transitionsSuspended``), so a crossfade can't take
    /// the standby deck from under it.
    ///
    /// Paused, or mid-transition, it reopens as `load` does: there is nothing to hear, or the
    /// standby deck is the blend's. A copy that isn't ready within ``swapDeadline`` (a dead server,
    /// a playhead stuck buffering) is cut over to the same way; if the queue moves on first, the
    /// copy is dropped.
    public func replaceCurrent(with item: PlayableItem) {
        cancelSwap()
        lastSwap = nil
        guard let replacing = currentItem?.id, isPlaying, active.current?.item.id == replacing, !crossfade.isTransitioning else {
            load(item, startingAt: position, playWhenReady: nil)
            return
        }
        swapGeneration += 1
        let generation = swapGeneration
        let deck = standby
        swapTask = Task { [weak self] in
            guard let self else { return }
            let started = ContinuousClock.now
            let crossed = await self.crossOver(to: item, on: deck, replacing: replacing)
            guard !Task.isCancelled, self.swapGeneration == generation else { return }
            self.swapTask = nil
            if crossed {
                PlaybackLog.info("swapped \(replacing) for \(item.id) with no gap, \(TrackLog.ms(since: started))ms after it was asked for",
                                 about: item.trackID)
                return
            }
            if deck === self.standby { deck.retire(rate: self.rate) }
            guard self.currentItem?.id == replacing else { return }
            PlaybackLog.warning("\(item.id) wasn't ready to swap in after \(TrackLog.ms(since: started))ms; cutting over", about: item.trackID)
            self.load(item, startingAt: self.position, playWhenReady: nil)
        }
    }

    /// Drops a swap in flight (for a new one, a load, a stop): the standby deck it held is emptied
    /// and the session deck back at full volume, whatever point the crossover had reached.
    func cancelSwap() {
        guard let task = swapTask else { return }
        task.cancel()
        swapTask = nil
        standby.retire(rate: rate)
        active.volume = 1
    }

    /// Opens `item` on `deck`, cues it ahead of the playhead until it's ready there in time, then
    /// starts it and hands the session over. False when it never got there, or the session left
    /// `replacing` (a skip, a stop) on the way.
    private func crossOver(to item: PlayableItem, on deck: PlaybackDeck, replacing: String) async -> Bool {
        let deadline = ContinuousClock.now + Self.swapDeadline
        deck.retire(rate: rate)
        deck.volume = 0
        // Precisely timed: the copy is cued mid-song, and the two have to meet on the same moment.
        guard let entry = try? await makeEntry(for: item, on: deck, preciselyTimed: true) else { return false }
        var lead = Self.swapLead
        var cue: TimeInterval?
        while ContinuousClock.now < deadline {
            guard !Task.isCancelled, currentItem?.id == replacing, deck === standby else { return false }
            // Paused (nothing to hear: the cut is as good), or the copy failed to load: no point
            // waiting out the deadline.
            if !playWhenReady || (cue != nil && deck.isIdle) { return false }
            let session = active
            let at = session.position
            // A deck told to play is heard this long after, in the track's own seconds; and no less
            // than the time a synchronized start needs to be scheduled in (see `handOver`).
            let latency = max(crossfade.startLatency, Self.swapSyncLead) * Double(rate)
            if let target = cue, deck.current === entry, target - at <= lead + 1 {
                let late = at - (target - latency)
                if late >= Self.swapSlack || (late >= 0 && !deck.isReadyToPlay) {
                    // The playhead got there first: cue further ahead.
                    lead = min(lead * 2, 6)
                    cue = nil
                    continue
                }
                if late >= 0, playWhenReady {
                    return await handOver(to: entry, on: deck, at: target, from: session, replacing: replacing)
                }
            } else {
                // Not cued yet, or a seek moved the playhead away from the cue.
                let next = at + lead
                // Too near the end to cue ahead of the playhead: the cut, now, rather than a cue
                // past the end that never gets ready while transitions are held.
                if let end = entry.effectiveEnd, next >= end - 1 { return false }
                cue = next
                deck.pause()
                deck.volume = 0
                deck.rate = rate
                if deck.current === entry { deck.seek(to: next) } else { deck.setCurrent(entry, at: next) }
                deck.preroll()
            }
            guard (try? await Task.sleep(for: .milliseconds(10))) != nil else { return false }
        }
        return false
    }

    /// Starts `deck` (silent), waits for it to be heard at `cue`, crosses the two over and moves the
    /// session onto it.
    private func handOver(to entry: DeckEntry, on deck: PlaybackDeck, at cue: TimeInterval, from session: PlaybackDeck,
                          replacing: String) async -> Bool {
        // Still the swap it began as: playing, on the same item and decks, and the two copies
        // still at the same point. They differ by at most the start latency plus the crossover;
        // more is a seek that moved only the session deck, and the fallback cut then lands where
        // the listener sought.
        let agreement = max(crossfade.startLatency, Self.swapSyncLead) * Double(rate) + Self.swapFade + 0.15
        func stillOn() -> Bool {
            !Task.isCancelled && playWhenReady && currentItem?.id == replacing && active === session && standby === deck
                && abs(session.position - deck.position) < agreement
        }
        // In step with the session deck by the host clock, so the copy is heard at the cue exactly
        // when the session is, whatever each deck's or the route's latency. Timed off the measured
        // latency instead, a copy that took longer to sound (a Bluetooth route) came in behind the
        // playhead and a moment was heard twice. A playlist starts the old way.
        // Stall-waiting, which a synchronized start has to switch off, is back on however this ends.
        defer { deck.player.automaticallyWaitsToMinimizeStalling = true }
        let inStep = deck.start(inStepWith: session, at: cue, margin: Self.swapSyncMargin)
        if !inStep {
            // Timed off the measured latency, as before, not the scheduling lead the trigger allows.
            let measured = crossfade.startLatency * Double(rate)
            let due = ContinuousClock.now + .seconds(1) + .seconds(max(cue - session.position, 0) / Double(rate))
            while session.position < cue - measured {
                guard ContinuousClock.now < due, stillOn(), (try? await Task.sleep(for: .milliseconds(5))) != nil else { return false }
            }
            deck.play()
        }
        let sounding = ContinuousClock.now + .seconds(1) + .seconds(max(cue - session.position, 0) / Double(rate))
        while !(deck.isPlaying && deck.position > cue) {
            guard ContinuousClock.now < sounding, stillOn(), (try? await Task.sleep(for: .milliseconds(5))) != nil else {
                deck.pause()
                return false
            }
        }
        // Sounding: stall-waiting back on now, not only once the handover returns.
        deck.player.automaticallyWaitsToMinimizeStalling = true
        // Where the copy stands against the playing one as the fade begins: the swap's position,
        // pinned by the tests and the first thing to read in the log when a swap is heard to repeat.
        let skew = deck.position - session.position
        PlaybackLog.info("swap crossover: the copy is \(Int((abs(skew) * 1_000).rounded()))ms \(skew < 0 ? "behind" : "ahead of") the playing one, "
            + (inStep ? "started in step by the host clock" : "started by the measured latency"), about: entry.item.trackID)
        logClock("the swap's crossover", on: deck)
        defer { session.volume = 1 }
        let steps = 8
        for step in 1...steps {
            let progress = Double(step) / Double(steps)
            deck.volume = TransitionGainCurve.equalPowerRise.gain(at: progress)
            session.volume = TransitionGainCurve.equalPowerFall.gain(at: progress)
            guard (try? await Task.sleep(for: .seconds(Self.swapFade / Double(steps)))) != nil, stillOn() else {
                // Whoever interrupted (a skip, a stop, another swap) has the decks now; the copy
                // goes quiet and the session deck, whatever it holds, back to full volume.
                deck.pause()
                return false
            }
        }
        active = deck
        standby = session
        lastSwap = (skew, inStep)
        deck.volume = 1
        session.retire(rate: rate)
        updateAdvancePolicy()
        itemBecameCurrent(entry.item, reason: .requested)
        recovery.itemBecameAudible(entry.item.id)
        entryBecameCurrent(entry)
        return true
    }
}
