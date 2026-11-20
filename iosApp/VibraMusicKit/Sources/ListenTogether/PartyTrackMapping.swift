import VibraMusicCore
import Foundation

/// What the party needs to know about a track: enough to name it and show it.
/// (Ports `Song.toPartyTrack` in `playback/PartySync.kt`.)
public enum PartyTrackMapping {
    /// The player's own duration when it has one (it comes from the decoder); otherwise
    /// what the row that queued the track claimed.
    public static func toPartyTrack(_ song: Song, playerDurationMs: Int64) -> PartyTrack {
        let duration: Int64? = playerDurationMs > 0 ? playerDurationMs : durationMillis(of: song)
        return PartyTrack(
            videoId: song.videoId,
            title: song.title,
            artist: song.artist,
            thumbnailUrl: song.thumbnailUrl,
            durationMs: duration,
            fromAutoplay: song.fromAutoplay)
    }

    /// Not cosmetic: this is what a cross-source match is made on, so a device whose
    /// sources differ from the sender's needs it to find the same recording.
    public static func toSong(_ track: PartyTrack) -> Song {
        Song(
            videoId: track.videoId,
            title: track.title,
            artist: track.artist,
            thumbnailUrl: track.thumbnailUrl,
            durationText: track.durationMs.map { ms in
                let total = ms / 1_000
                return "\(total / 60):\(String(format: "%02d", total % 60))"
            },
            queueTier: track.fromAutoplay ? .autoplay : .userQueue)
    }

    static func durationMillis(of song: Song) -> Int64? {
        // `Song.durationMillis` is 0 when unknown; only a positive reading is a duration.
        let ms = song.durationMillis
        return ms > 0 ? Int64(ms) : nil
    }
}
