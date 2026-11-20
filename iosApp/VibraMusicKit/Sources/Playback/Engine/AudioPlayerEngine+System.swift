import AVFoundation
import VibraMusicCore
import MediaPlayer

extension AudioPlayerEngine {
    // MARK: - Now Playing

    /// Publishes the current item, position and rate to the lock screen. Called on every change
    /// that the system can't extrapolate (item, play/pause, seek, rate) and every sample interval.
    func publishNowPlaying() {
        guard let publisher = nowPlaying else { return }
        guard let item = currentItem else {
            artwork.cancel()
            publisher.publish(nil)
            publisher.publishPlaybackState(isPlaying: false, hasItem: false)
            return
        }
        artwork.load(item.artworkURL) { [weak self] _ in self?.publishNowPlaying() }
        let art = artwork.loadedURL == item.artworkURL ? artwork.artwork : nil
        let info = NowPlayingInfoBuilder.info(.init(
            item: item,
            position: position,
            duration: duration,
            isPlaying: isPlaying,
            rate: rate,
            subtitleOverride: nowPlayingSubtitle,
            artwork: art,
            // The system re-reads the preview only behind a changed artworkID, and the id
            // already counted the cover it was resolved with — so the first offer to the system
            // must not go out while the still cover is still loading: that would lock a nil
            // preview behind an id that never changes. The load's own re-publish below lands it
            // the moment the still is there. A track with no cover, or whose cover failed to load,
            // has no still left to wait for.
            animatedArtworks: (art != nil || item.artworkURL == nil || artwork.failedURL == item.artworkURL)
                ? storedAnimatedArtworks.filter { $0.itemID == nil || $0.itemID == item.id } : []
        ))
        publisher.publish(info)
        publisher.publishPlaybackState(isPlaying: playWhenReady, hasItem: true)
    }

    // MARK: - Remote commands

    /// Routes a remote command to the delegate, or performs the default when there is none.
    func dispatchRemoteCommand(_ command: RemoteCommand) -> RemoteCommandResult {
        if let delegate { return delegate.audioPlayerEngine(self, handle: command) }
        return performDefault(command)
    }

    /// What a remote command does when the app doesn't handle it: transport on the engine. Next
    /// goes to ``upcomingItem``; previous restarts the track (going back one is the queue's call).
    /// Like and dislike need the app, so they fail here.
    @discardableResult
    public func performDefault(_ command: RemoteCommand) -> RemoteCommandResult {
        guard currentItem != nil else { return .noActionableNowPlayingItem }
        switch command {
        case .play:
            play()
        case .pause, .stop:
            pause()
        case .togglePlayPause:
            togglePlayPause()
        case .nextTrack:
            return skipToNext() ? .success : .noSuchContent
        case .previousTrack:
            seek(to: 0)
        case .changePlaybackPosition(let time):
            seek(to: time)
        case .skipForward(let interval):
            skip(by: interval)
        case .skipBackward(let interval):
            skip(by: -interval)
        case .changePlaybackRate(let value):
            rate = value
        case .like, .dislike:
            return .commandFailed
        }
        return .success
    }

    // MARK: - Audio session

    /// Reacts to an audio-session event. The engine feeds these itself on iOS.
    public func handleAudioSessionEvent(_ event: AudioSessionEvent) {
        defer { onAudioSessionEvent?(event) }
        switch event {
        case .interruptionBegan:
            // The system has already silenced us; remember whether to come back.
            resumeAfterInterruption = playWhenReady
            if playWhenReady { pausePlayback() }
        case .interruptionEnded(let shouldResume):
            if shouldResume, resumeAfterInterruption { play() }
            resumeAfterInterruption = false
        case .outputDeviceUnavailable:
            // Headphones out: pause, and don't come back on our own.
            resumeAfterInterruption = false
            if playWhenReady {
                PlaybackLog.info("output went away; pausing", about: currentItem?.trackID)
                pausePlayback()
            }
        case .mediaServicesReset:
            PlaybackLog.warning("media services were reset; rebuilding the players", about: currentItem?.trackID)
            recovery.mediaServicesCameBack()
            rebuildAfterMediaServicesReset()
        }
    }

    /// Every AVFoundation object is dead after a media-services reset, whichever way the engine
    /// heard of it: build new players and a set-up audio session, and reopen the current item, on
    /// the copy it was playing, where it was. New players make new taps as the item opens, and the
    /// next item is queued again once this one is on the deck. The reset was not the item's doing,
    /// so its retries are left as they were.
    func rebuildAfterMediaServicesReset() {
        let item = currentItem
        let wasPlaying = playWhenReady
        cancelSwap()
        endLiveSkip()
        crossfade.release()
        [loadTask, preloadTask, armTask, statsTask].forEach { $0?.cancel() }
        deckA.invalidate()
        deckB.invalidate()
        deckA = PlaybackDeck(id: .a, processor: processors[.a])
        deckB = PlaybackDeck(id: .b, processor: processors[.b])
        wire(deckA)
        wire(deckB)
        active = deckA
        standby = deckB
        standby.rate = rate
        let latency = crossfade.startLatency
        crossfade = CrossfadeController(host: self)
        crossfade.startLatency = latency
        openedAudio.removeAll()
        // Opens under way hold assets from before the reset: nothing joins them.
        openingAudio.removeAll()
        updateAdvancePolicy()
        #if os(iOS)
        audioSession?.mediaServicesWereReset()
        #endif
        guard let item else { return }
        setPlayWhenReady(wasPlaying)
        isLoadingItem = true
        updatePlayingState()
        let sourceRecovery = self.sourceRecovery
        // As a load: skipping on, which opens another item, cancels this.
        loadTask = Task { [weak self] in
            let sameCopy = try? await sourceRecovery?(item, .systemFault)
            guard !Task.isCancelled, let self, self.currentItem?.id == item.id else { return }
            var reopened = item
            if let sameCopy { reopened.source = sameCopy }
            self.recovery.retryingItemID = item.id
            self.openItem(reopened, at: self.position, reason: nil)
        }
    }
}
