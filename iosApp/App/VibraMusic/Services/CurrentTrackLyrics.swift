import VibraMusicCore
import Foundation
import Lyrics
import Observation

/// The lyrics for whatever is playing, owned by the app rather than by the player screen
/// (Android: the lyrics state in `MainViewModel`, fed by the `LaunchedEffect` in MainActivity's
/// app composable).
///
/// The lookup starts when the *track* changes, not when the player opens: by the time the
/// listener opens Now Playing the lines are usually there already, and closing and reopening the
/// player finds the same session with the same lines, instead of a new one showing the loading
/// placeholder again. One session per track: it is replaced when the track changes (so nothing of
/// the last track's lookup, provider choice or manual fetches can reach the new one) and kept for
/// as long as the track is current. The Now Playing strip, the lyrics panel and the provider sheet
/// all read ``session``.
@MainActor
@Observable
final class CurrentTrackLyrics {
    /// The current track's lyrics.
    private(set) var session: LyricsSession
    /// Which track ``session`` belongs to.
    @ObservationIgnored private(set) var trackId: String?

    @ObservationIgnored private let makeSession: @MainActor () -> LyricsSession
    @ObservationIgnored private var tracker: ChangeTracker?

    /// What re-runs the lookup, as in Android's `LaunchedEffect(song.videoId, player.durationMs,
    /// syncedLyrics, lyricsSources)`: the track, the player's own length (it lands a beat after
    /// the track), and the two lyric settings — so turning a source on or off applies to the
    /// track already playing, not only the next one.
    struct Key: Equatable {
        var videoId: String?
        var playerDurationMs: Int
        var syncedLyrics: Bool
        var lyricsSources: [String]
    }

    init(makeSession: @escaping @MainActor () -> LyricsSession) {
        self.makeSession = makeSession
        session = makeSession()
    }

    convenience init(repository: LyricsRepository) {
        self.init { LyricsSession(repository: repository) }
    }

    /// Follows `player` and `settings` from now on, loading as the key changes (and once now).
    func follow(player: PlayerController, settings: AppSettings) {
        tracker?.cancel()
        tracker = ChangeTracker.track({ [weak player] in
            Self.key(song: player?.currentSong, playerDuration: player?.duration ?? 0, settings: settings)
        }) { [weak self, weak player] _ in
            guard let self, let player else { return }
            self.update(song: player.currentSong, playerDuration: player.duration, settings: settings)
        }
    }

    func stopFollowing() {
        tracker?.cancel()
        tracker = nil
    }

    static func key(song: Song?, playerDuration: TimeInterval, settings: AppSettings) -> Key {
        Key(
            videoId: song?.videoId,
            playerDurationMs: playerDuration > 0 ? Int(playerDuration * 1_000) : 0,
            syncedLyrics: settings.syncedLyrics,
            lyricsSources: settings.lyricsSources.map(\.rawValue).sorted()
        )
    }

    /// Android's `MainViewModel.loadLyrics` call site: the player's length, and the catalogue's
    /// where it has none yet (a paused track the engine never finished preparing reports no
    /// duration at all, and a lookup that waited for one would wait for ever); a downloaded or
    /// imported file is read for its own lyrics first. Loading what is already loaded is a
    /// cheap no-op inside the session.
    func update(song: Song?, playerDuration: TimeInterval, settings: AppSettings) {
        guard let song else {
            if trackId != nil {
                trackId = nil
                session = makeSession()
            }
            return
        }
        if song.videoId != trackId {
            trackId = song.videoId
            session = makeSession()
        }
        let durationMs = playerDuration > 0 ? Int(playerDuration * 1_000) : song.durationMillis
        session.load(
            LyricsTrack(videoId: song.videoId, title: song.title, artist: song.artist, album: song.albumName,
                        durationMs: durationMs, localFileURL: PlaybackSourceFactory.localFileURL(of: song)),
            preferences: LyricsPreferences(settings: settings)
        )
    }
}
