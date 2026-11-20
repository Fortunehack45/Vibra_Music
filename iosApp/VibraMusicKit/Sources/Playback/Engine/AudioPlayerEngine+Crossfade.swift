import AVFoundation
import VibraMusicCore

extension AudioPlayerEngine: CrossfadeHost {
    var activeTransitionDeck: TransitionDeck { active }
    var standbyTransitionDeck: TransitionDeck { standby }

    /// The current item, once its entry is on the session deck.
    var transitionCurrentItem: PlayableItem? {
        guard let entry = active.current, entry.item.id == currentItem?.id else { return nil }
        return entry.item
    }

    var transitionUpcomingItem: PlayableItem? { upcomingItem }

    var transitionCurrentEnd: TimeInterval? { active.current?.effectiveEnd }

    var transitionUpcomingDuration: TimeInterval? {
        if let queued = active.queued, queued.item.id == upcomingItem?.id, let length = queued.duration { return length }
        return upcomingItem?.duration
    }

    var crossfadeSeconds: TimeInterval { crossfadeDuration }
    var automixActive: Bool { automixEnabled }
    var sleepsAfterCurrentTrack: Bool { sleepTimer?.afterTrack == true }
    var playbackSpeed: Float { rate }
    var now: TimeInterval { clock.now }

    func armIncoming(_ item: PlayableItem, cue: TimeInterval, rate: Float) {
        let deck = standby
        armTask?.cancel()
        deck.retire(rate: rate)
        deck.volume = 0
        armTask = Task { [weak self] in
            guard let self else { return }
            do {
                let entry = try await self.makeEntry(for: item, on: deck, preciselyTimed: cue > 0.05)
                guard self.crossfade.armedIncomingID == item.id, deck === self.standby else { return }
                var at = cue
                if self.skipSilence, cue <= 0.05, let lead = await self.leadingSkipTarget(for: item.id) { at = lead }
                guard self.crossfade.armedIncomingID == item.id, deck === self.standby else { return }
                deck.pause()
                deck.volume = 0
                deck.rate = rate
                deck.setCurrent(entry, at: at)
                deck.preroll()
            } catch is CancellationError {
                return
            } catch {
                PlaybackLog.warning("arming \(item.id) failed: \(error)", about: item.trackID, error: error)
                self.crossfade.onArmFailed(itemID: item.id)
            }
        }
    }

    func handOffToStandby() {
        let outgoing = active
        let incoming = standby
        active = incoming
        standby = outgoing
        // The outgoing deck runs up to its track's natural end, where the queue player would advance
        // into the next track — the one now playing on the other deck — a second time, on top of
        // itself. With nothing queued it stops there instead, which the controller reads as the tail
        // being spent.
        outgoing.stopAdvancingToQueued()
        updateAdvancePolicy()
        guard let entry = incoming.current else { return }
        PlaybackLog.debug("handoff at cue=\(incoming.position)s out=\(outgoing.position)s", about: entry.item.trackID)
        itemBecameCurrent(entry.item, reason: .crossfade)
        entryBecameCurrent(entry)
    }

    func retire(_ deck: TransitionDeck) {
        guard let deck = deck as? PlaybackDeck else { return }
        if deck === standby { armTask?.cancel() }
        deck.retire(rate: rate)
    }

    func setRate(_ rate: Float, on deck: TransitionDeck) {
        (deck as? PlaybackDeck)?.rate = rate
    }

    func finishSleepFade(on deck: TransitionDeck) {
        deck.playWhenReady = false
        deck.volume = 1
        if (deck as? PlaybackDeck) === active {
            setPlayWhenReady(false)
            updatePlayingState()
            publishNowPlaying()
            checkpoint()
        }
        cancelSleepTimer()
    }

    func transitionStateChanged(isTransitioning: Bool) {
        self.isTransitioning = isTransitioning
        // A speed change that arrived mid-transition lands now.
        if !isTransitioning {
            active.rate = rate
            standby.rate = rate
        }
    }

    func mixInProgressChanged(_ inProgress: Bool) {
        if isSmartMixInProgress != inProgress { isSmartMixInProgress = inProgress }
    }

    func transitionWindowChanged(_ window: TransitionWindow?) {
        if transitionWindow != window { transitionWindow = window }
    }
}
