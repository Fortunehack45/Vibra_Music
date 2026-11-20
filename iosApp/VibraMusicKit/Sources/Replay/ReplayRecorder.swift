import Foundation
import VibraMusicCore

// Ports data/stats/ListeningRecorder.kt: turns the player's ticking into the numbers
// ReplayListeningStats keeps.
//
// ## Why it samples rather than measures
//
// The tempting implementation reads the track's position when it ends and calls that the
// listening. It is wrong in every direction that matters: a track skipped at 0:20 reports twenty
// seconds it did play, a track seeked back over reports less than it played, a track left paused
// for an hour reports the same as one played through, and a track the process is killed under
// reports nothing at all.
//
// So this is fed from the player's existing progress sampler, which only ticks while audio is
// actually coming out, and each tick contributes the *wall-clock* time since the last one. Seeking
// cannot inflate it because position is never consulted. Pausing cannot inflate it because no tick
// happens. The gap either side of a pause is capped at `maxStepMs`, which is what stops an hour on
// the lock screen from arriving as an hour of listening on the first tick after resume.
//
// The cost is that the few seconds before the first tick of each track are not counted — a
// systematic undercount of at most one sample interval per track, and the right way to be wrong:
// every alternative overcounts, and a Replay that flatters is worth less than one that is a
// little shy.
//
// ## Minutes and plays are different questions
//
// Minutes accumulate continuously. A *play* is counted once, when enough of the track has gone by
// to call it listened to — the same half-or-four-minutes rule the scrobbler uses, so the two never
// disagree about what a play is.

public final class ReplayListeningRecorder: @unchecked Sendable {
    /// The most a single tick may contribute: a shade over the sampler's interval, so an ordinary
    /// tick that arrived late — a busy thread, a device coming out of doze — is still counted in
    /// full, while the unbounded gap across a pause is not.
    public static let maxStepMs: Int64 = 8_000
    /// Under half a minute is not a listen, however it ended.
    public static let playFloorMs: Int64 = 30_000
    /// Past four minutes, half a track is more listening than anyone disputes.
    public static let playCeilingMs: Int64 = 4 * 60 * 1_000
    /// Six ticks — about half a minute of listening between disk writes.
    public static let flushEvery = 6

    private let sink: any ReplayListeningSink
    private let nowMillis: () -> Int64
    private let lock = NSLock()
    private var currentId: String?
    private var lastSampleAt: Int64 = 0
    private var playedThisTrack: Int64 = 0
    private var playCounted = false
    private var samplesSinceFlush = 0

    /// - `sink`: where samples land (a `ReplayListeningStats`, or a spy in tests).
    /// - `nowMillis`: wall-clock milliseconds. Tests fix it for determinism.
    public init(sink: any ReplayListeningSink, nowMillis: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.sink = sink
        self.nowMillis = nowMillis
    }

    /// How much of a track of `trackLengthMs` must play before it counts as a listen.
    ///
    /// Half the track, clamped to the thirty-second floor and the four-minute ceiling; a track
    /// with no known length simply has to clear the floor. `trackLengthMs <= 0` means unknown.
    public static func playThresholdMs(trackLengthMs: Int64) -> Int64 {
        guard trackLengthMs > 0 else { return playFloorMs }
        return min(trackLengthMs / 2, playCeilingMs).clamped(atLeast: playFloorMs)
    }

    /// One tick of the player's sampler.
    ///
    /// `durationMs` is the decoder's figure when it has one; the row's stated runtime stands in
    /// until it does, and a track with neither simply has to clear the thirty-second floor.
    public func onSample(_ song: Song, durationMs: Int64) {
        let now = nowMillis()
        lock.withLock {
            if song.videoId != currentId {
                // A new track anchors the clock and contributes nothing yet — see the file note
                // on undercounting.
                currentId = song.videoId
                lastSampleAt = now
                playedThisTrack = 0
                playCounted = false
                return
            }
            let step = min(max(now - lastSampleAt, 0), Self.maxStepMs)
            lastSampleAt = now
            if step <= 0 { return }
            playedThisTrack += step

            let length = durationMs > 0 ? durationMs : Int64(song.durationMillis)
            let counts = !playCounted && playedThisTrack >= Self.playThresholdMs(trackLengthMs: length)
            if counts { playCounted = true }

            sink.replayRecord(song, playedMs: step, countsAsPlay: counts, at: Date(timeIntervalSince1970: Double(now) / 1000))
            samplesSinceFlush += 1
            if samplesSinceFlush >= Self.flushEvery {
                samplesSinceFlush = 0
                sink.replayFlush()
            }
        }
    }

    /// Playback stopped, paused, or moved on.
    ///
    /// Forgetting the current track is what makes the *next* tick anchor rather than contribute:
    /// without it, a player paused for an afternoon would hand `maxStepMs` of listening to
    /// whatever was on screen when it resumed.
    public func onStopped() {
        lock.withLock {
            currentId = nil
            playedThisTrack = 0
            playCounted = false
            samplesSinceFlush = 0
        }
        sink.replayFlush()
    }
}

private extension Int64 {
    func clamped(atLeast floor: Int64) -> Int64 { Swift.max(self, floor) }
}
