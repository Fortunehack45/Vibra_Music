import AudioCache
import AVFoundation
import VibraMusicCore

extension AudioPlayerEngine {
    /// Puts a failed item back on its feet, or moves past it (port of the Android `recoverFrom`).
    ///
    /// The position is kept: a retry should sound like a hiccup, not the song starting over.
    func handleFailure(itemID: String, error: Error) {
        guard let item = currentItem, item.id == itemID else { return }
        if RecoveryLedger.isMediaServicesReset(error) {
            mediaServicesFailed(error)
            return
        }
        crossfade.onError()
        let at = max(position, 0)
        PlaybackLog.warning("playback failed for \(item.id) at \(at)s: \(error)", about: item.trackID, error: error)
        openedAudio[item.id] = nil

        // A local file that isn't there is the one failure retrying can't touch: the path is baked
        // into the item, so reopening it fails identically. Switching to a stream is a different
        // source, not an attempt spent.
        if let missing = Self.missingFile(in: error, item: item), let sourceRecovery, !restreamedMissingFiles.contains(item.id) {
            restreamedMissingFiles.insert(item.id)
            Task { [weak self] in
                let replacement = try? await sourceRecovery(item, .missingLocalFile(missing))
                guard let self, self.currentItem?.id == item.id else { return }
                guard let replacement else {
                    PlaybackLog.warning("\(item.id) is a local file that is gone and has no stream behind it", about: item.trackID)
                    self.recordFailure(item: item, error: error, at: at)
                    return
                }
                PlaybackLog.warning("\(item.id) was downloaded but \(missing.lastPathComponent) is gone; streaming it instead", about: item.trackID)
                var restreamed = item
                restreamed.source = replacement
                self.recovery.forgetAttempts(for: item.id)
                self.recovery.retryingItemID = item.id
                self.openItem(restreamed, at: at, reason: nil)
            }
            return
        }
        recordFailure(item: item, error: error, at: at)
    }

    /// An item reported that media services were reset (`-11819`). Nothing is wrong with any copy, so
    /// nothing here spends a retry or asks for a fresh source; the same copy goes back on new players
    /// at the position it had (see ``rebuildAfterMediaServicesReset()``).
    ///
    /// The items can report this before the session posts its notification: on an iPad, a reopen
    /// with no announcement, which only that notification makes, came 1.5 s and 4.6 s after them.
    /// Waiting for it would be that much silence, and it may not come, so the players are
    /// rebuilt after a moment and again when it does. Should they still be dead, they report this
    /// again and wait longer, up to ``RecoveryLedger/maxResetReopens``.
    func mediaServicesFailed(_ error: Error) {
        guard let item = currentItem else { return }
        // Every item says so in the same millisecond.
        if let resetWait, resetWait == loadTask, !resetWait.isCancelled { return }
        PlaybackLog.warning("media services were reset under \(item.id) at \(position)s; reopening the same copy", about: item.trackID, error: error)
        crossfade.onError()
        cancelSwap()
        // Off the dead player, whose clock can't be trusted to keep the position until the reopen.
        active.clear()
        loadGeneration += 1
        loadTask?.cancel()
        preloadTask?.cancel()
        guard let wait = recovery.recordReset() else {
            PlaybackLog.warning("media services are still down; \(item.id) waits for them or for play", about: item.trackID)
            lastError = PlaybackError(itemID: item.id, message: "Playback failed: \(Self.describe(error))", attempt: recovery.attemptCount(for: item.id))
            delegate?.audioPlayerEngine(self, didFail: lastError!, willRetry: false)
            isLoadingItem = false
            updatePlayingState()
            return
        }
        isLoadingItem = true
        updatePlayingState()
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.rebuildAfterMediaServicesReset()
        }
        resetWait = task
        loadTask = task
    }

    private func recordFailure(item: PlayableItem, error: Error, at position: TimeInterval) {
        let verdict = RecoveryLedger.permanentVerdict(in: error)
        let decision = recovery.recordFailure(itemID: item.id, verdict: verdict)
        let message = "Playback failed: \(verdict ?? Self.describe(error))"
        switch decision {
        case .retry(let attempt):
            lastError = PlaybackError(itemID: item.id, message: message, isPermanent: false, attempt: attempt)
            delegate?.audioPlayerEngine(self, didFail: lastError!, willRetry: true)
            let sourceRecovery = self.sourceRecovery
            // Read now, not after the delay: it describes this failure.
            let networkFault = RecoveryLedger.isNetworkFault(error)
            let reason: RecoveryReason = RecoveryLedger.isSystemFault(error) ? .systemFault : .retry(attempt: attempt, networkFault: networkFault)
            Task { [weak self] in
                // Long enough for the failed source to let go of its cache entry.
                try? await Task.sleep(for: .seconds(RecoveryLedger.recoveryDelay))
                // Play in the meantime already reopened it (see `play()`): that open stands.
                guard let self, self.currentItem?.id == item.id, !self.isLoadingItem, !self.active.isPlaying else { return }
                let replacement = try? await sourceRecovery?(item, reason)
                guard self.currentItem?.id == item.id else { return }
                PlaybackLog.debug("retrying \(item.id) from \(position)s (attempt \(attempt))", about: item.trackID)
                var reopened = item
                if let replacement { reopened.source = replacement }
                // Claimed before reopening, so the reopen isn't read as a fresh start with a fresh
                // attempt budget — the loop that made one unplayable track resolve dozens of times.
                self.recovery.retryingItemID = item.id
                self.openItem(reopened, at: position, reason: nil)
            }
        case .giveUp(let skipReason, let attempt):
            lastError = PlaybackError(itemID: item.id, message: message, isPermanent: verdict != nil, attempt: attempt)
            delegate?.audioPlayerEngine(self, didFail: lastError!, willRetry: false)
            if let verdict {
                PlaybackLog.warning("\(item.id) cannot be played: \(verdict)", about: item.trackID)
            } else {
                PlaybackLog.warning("\(item.id) has failed \(attempt) times; leaving it alone", about: item.trackID)
            }
            isLoadingItem = false
            updatePlayingState()
            guard let skipReason else { return }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(RecoveryLedger.recoveryDelay))
                guard let self, self.currentItem?.id == item.id else { return }
                self.skipPastUnplayable(item, reason: skipReason)
            }
        }
    }

    /// An item reported its end, on the session deck. `genuine` is what follows a real one.
    ///
    /// One well short of what's known about the item's length isn't believed. With the whole copy on
    /// disk and only the catalogue's figure against it, the decoder had everything and the catalogue
    /// is what's wrong; a playlist's stated length is the file's own, and an item that stopped reading
    /// its fragments while it waited ends short of it with every byte there. Otherwise the next bytes
    /// are fetched and the item is opened afresh over them at its position, keeping every byte it has
    /// (a failure's recovery would throw a partial copy away and park the track if it ran out of
    /// retries). AVPlayer does this when a copy's bytes run out (see ``PlaybackDeck/holdForBytes()``),
    /// which ExoPlayer on Android doesn't, so this goes beyond the port. An end that comes back at the
    /// same place with nothing new on disk is taken as real: each reopen has to have gained position
    /// or bytes, so a wrong length can't send it round for ever.
    func itemEnded(_ entry: DeckEntry, genuine: @escaping @MainActor () -> Void) {
        let at = position
        guard let known = entry.lengthBeyondEnd(at: at) else {
            genuine()
            return
        }
        let generation = loadGeneration
        Task { [weak self] in
            let whole = await AudioStreamCache.isWhole(entry.asset)
            let bytes = await AudioStreamCache.bytesOnDisk(of: entry.asset)
            let reads = await AudioStreamCache.readReport(of: entry.asset) ?? "not through the cache"
            guard let self, generation == self.loadGeneration, self.currentItem?.id == entry.item.id else { return }
            let report = "\(entry.item.id) reported its end at \(String(format: "%.1f", at))s of \(String(format: "%.1f", known))s "
                + "with [\(entry.loadedDescription)] loaded; \(reads)"
            let catalogueIsWrong = whole && entry.knownLength == nil
            let nothingGained = self.gainedNothing(entry, at: at, bytes: bytes)
            guard !catalogueIsWrong, !nothingGained else {
                PlaybackLog.info(report + (catalogueIsWrong ? "; whole on disk, so that is its end" : "; again with nothing new, so that is its end"), about: entry.item.trackID)
                self.shortEnd = nil
                genuine()
                return
            }
            PlaybackLog.warning(report + "; opening it again there once the next bytes are in", about: entry.item.trackID)
            // Off the deck now: with a next track queued, that track is what's sounding.
            self.crossfade.onError()
            self.cancelSwap()
            self.active.clear()
            self.isLoadingItem = true
            self.updatePlayingState()
            // As a load: skipping on, which opens another item, cancels this.
            self.loadTask?.cancel()
            self.loadTask = Task { [weak self] in
                do {
                    try await AudioStreamCache.fetchAhead(of: entry.asset, at: at, of: known, ahead: PlaybackDeck.fetchAhead, stallLimit: PlaybackDeck.stallLimit)
                } catch {
                    guard !Task.isCancelled, let self else { return }
                    self.isLoadingItem = false
                    self.updatePlayingState()
                    self.handleFailure(itemID: entry.item.id, error: error)
                    return
                }
                let bytes = await AudioStreamCache.bytesOnDisk(of: entry.asset)
                guard !Task.isCancelled, let self else { return }
                self.reopen(entry.item, at: at, bytes: bytes)
            }
        }
    }

    /// The deck held `entry` for bytes, they're on disk and its player hasn't taken them up: a new
    /// asset reads them from the top. Not when one already has, with nothing more to read since.
    func bytesArrivedWhileHeld(_ entry: DeckEntry, on deck: PlaybackDeck) {
        guard deck === active, entry === deck.current else {
            deck.letGo(of: entry)
            return
        }
        let at = position
        Task { [weak self] in
            let bytes = await AudioStreamCache.bytesOnDisk(of: entry.asset)
            guard let self, deck === self.active, entry === deck.current, deck.isHeldForBytes else { return }
            if self.gainedNothing(entry, at: at, bytes: bytes) {
                PlaybackLog.info("\(entry.item.id): opening it again at \(String(format: "%.1f", at))s gained nothing; playing what it has", about: entry.item.trackID)
                deck.letGo(of: entry)
            } else {
                PlaybackLog.info("\(entry.item.id): the bytes are in; opening it again at \(String(format: "%.1f", at))s", about: entry.item.trackID)
                self.reopen(entry.item, at: at, bytes: bytes)
            }
        }
    }

    /// Whether `entry` was already reopened about here, with these same bytes on disk.
    private func gainedNothing(_ entry: DeckEntry, at: TimeInterval, bytes: Int64) -> Bool {
        guard let last = shortEnd, last.itemID == entry.item.id else { return false }
        return at <= last.at + 1 && bytes <= last.bytes
    }

    /// Opens `item` afresh at `at`: a new asset, as AVFoundation won't read past what the old one
    /// knew, over the same cache entry, so nothing on disk is fetched again.
    private func reopen(_ item: PlayableItem, at: TimeInterval, bytes: Int64) {
        shortEnd = (item.id, at, bytes)
        crossfade.onError()
        cancelSwap()
        // As a retry does: the reopen isn't a fresh start with a fresh budget.
        recovery.retryingItemID = item.id
        openedAudio[item.id] = nil
        openItem(item, at: at, reason: nil)
    }

    /// Leaves a track that can't be played and carries on down the queue. With nothing after it
    /// there is nowhere to go: the error stays up, which is what puts a message in front of the
    /// listener. An error doesn't clear the intent to play, so the next track resumes exactly as
    /// far as the listener had asked.
    func skipPastUnplayable(_ item: PlayableItem, reason: String) {
        guard let next = upcomingItem else {
            PlaybackLog.warning("\(reason) — and nothing after it in the queue", about: item.trackID)
            return
        }
        PlaybackLog.warning("\(reason) — skipping to the next track", about: item.trackID)
        let error = lastError
        openItem(next, at: 0, reason: .skippedUnplayable(reason: reason))
        // Keep the reason visible until the next track actually plays.
        if lastError == nil { lastError = error }
    }

    static func missingFile(in error: Error, item: PlayableItem) -> URL? {
        if case PlaybackSourceError.missingLocalFile(let url) = error { return url }
        guard let url = item.fileURL, !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return url
    }

    static func describe(_ error: Error) -> String {
        if let source = error as? PlaybackSourceError { return source.description }
        let ns = error as NSError
        return ns.localizedFailureReason ?? ns.localizedDescription
    }
}
