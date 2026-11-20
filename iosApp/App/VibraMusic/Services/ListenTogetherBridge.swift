import VibraMusicCore
import Foundation
import InnerTube
import ListenTogether
import PlaybackQueue

// Ports the player half of playback/PartySync.kt: ListenTogether's sync coordinator drives this
// device's player through PartyPlayerBridge, and reads it back to publish what the host does.

/// PlayerController as ListenTogether's view of the player.
///
/// Party edits arrive as programmatic queue edits (never refused, never reported back as the
/// listener's own), so the party's broadcast and this queue can't echo each other.
final class PartyPlaybackBridge: PartyPlayerBridge, @unchecked Sendable {
    private weak var player: PlayerController?

    @MainActor
    init(player: PlayerController) {
        self.player = player
    }

    func snapshot() async -> PartyPlayerSnapshot? {
        await MainActor.run {
            guard let player else { return nil }
            let state = player.queueState
            return PartyPlayerSnapshot(
                songs: state.songs,
                currentIndex: state.isEmpty ? -1 : state.currentIndex,
                positionMs: Int64(player.position * 1_000),
                currentDurationMs: Int64(player.duration * 1_000),
                isPlaying: player.playWhenReady,
                isReady: !player.isBuffering,
                audioSuppressed: false
            )
        }
    }

    func load(tracks: [PartyTrack], index: Int, positionMs: Int64, startPlaying: Bool) async -> Bool {
        await MainActor.run { () -> Bool in
            guard let player else { return false }
            // Transitions would start the next song at a different moment on every device.
            player.engine.transitionsSuspended = true
            player.queue.setItems(tracks.map(PartyTrackMapping.toSong), startIndex: index, startPositionMs: positionMs,
                                  playback: startPlaying ? .play : .pause)
            return true
        }
    }

    func play() async {
        await MainActor.run { player?.engine.play() }
    }

    func pause() async {
        await MainActor.run { player?.engine.pause() }
    }

    func seek(to positionMs: Int64) async {
        await MainActor.run { player?.engine.seek(to: TimeInterval(positionMs) / 1_000) }
    }

    func setUpcoming(_ tracks: [PartyTrack]) async {
        await MainActor.run {
            guard let player else { return }
            let state = player.queueState
            let from = min(state.currentIndex + 1, state.songs.count)
            player.queue.replaceItems(in: from..<state.songs.count, with: tracks.map(PartyTrackMapping.toSong))
        }
    }

    func appendUpcoming(_ tracks: [PartyTrack]) async {
        await MainActor.run { player?.queue.appendItems(tracks.map(PartyTrackMapping.toSong)) }
    }

    func trimUpcoming(toCount count: Int) async {
        await MainActor.run {
            guard let player else { return }
            let state = player.queueState
            let keepUntil = min(state.currentIndex + 1 + max(count, 0), state.songs.count)
            guard keepUntil < state.songs.count else { return }
            player.queue.removeItems(in: keepUntil..<state.songs.count)
        }
    }

    func moveUpcoming(from: Int, to: Int) async {
        await MainActor.run {
            guard let player else { return }
            let base = player.queueState.currentIndex + 1
            player.queue.moveItem(from: base + from, to: base + to)
        }
    }
}

/// The personal queue put aside while in a party lives in PlaybackQueue's stash; the coordinator
/// reaches it through the queue controller so the restart snapshot stays consistent.
final class PartyQueueStashAdapter: PartyQueueStashing, @unchecked Sendable {
    private weak var queue: PlaybackQueueController?

    @MainActor
    init(queue: PlaybackQueueController) {
        self.queue = queue
    }

    func stash(songs: [Song], index: Int, positionMs: Int64, isPlaying: Bool) async {
        await MainActor.run { _ = queue?.stashPersonalQueueForParty(positionMs: positionMs, isPlaying: isPlaying) }
    }

    func loadStash() async -> PartyStashedQueue? {
        // The queue restores its own stash (restorePersonalQueueAfterParty); nothing to hand over.
        nil
    }

    func clearStash() async {
        await MainActor.run {
            guard let queue else { return }
            queue.party = .solo
            _ = queue.restorePersonalQueueAfterParty()
        }
    }
}

/// Who this device is in a party: the signed-in account's name and picture, else the nickname the
/// listener typed; the device id from the party store.
struct PartyIdentityFromAccount: PartyIdentityProvider {
    let accounts: YouTubeAccountManager
    let store: PartyServerStore

    func partyIdentity() async -> PartyIdentity? {
        let (key, name, avatar) = await MainActor.run {
            (accounts.listenerKey, accounts.account?.name, accounts.account?.thumbnailUrl)
        }
        let nickname = store.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = !nickname.isEmpty ? nickname : (name ?? "")
        return PartyIdentity(
            userId: key ?? store.deviceId,
            deviceId: store.deviceId,
            displayName: displayName.isEmpty ? L10n.listenTogetherJamUnnamed : displayName,
            avatarUrl: avatar
        )
    }
}
