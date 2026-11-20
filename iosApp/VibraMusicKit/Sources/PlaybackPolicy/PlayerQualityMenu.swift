import Foundation
import VibraMusicCore

// Ports the quality rows of the player's song menu: MainActivity.kt's `onRollbackToOriginal` /
// `onUpgradeQuality` / `upgradeQualityInProgress` wiring and `playingYouTubesOwn`,
// SongActionsSheet.kt's choice of row, and PlaybackService.carButtons' revert button.

/// Which of the two quality rows the player menu leads with, if either.
///
/// They are the same row in the same place: "Revert to original" for a track playing a substituted
/// copy, "Upgrade quality" for one held on YouTube's own. Choosing between them used to read the
/// listener's revert pin and nothing else, so an upgrade that was swapped in and then failed to
/// prove itself — which reverts automatically and pins nothing — left the menu offering to revert
/// a track already playing YouTube's copy. The row did nothing, and the row that would have helped
/// was the one it stood in front of.
public enum PlayerQualityMenu {
    public enum Row: Hashable, Sendable {
        /// Send the playing track back to YouTube's own upload, and keep it there
        /// (``OriginalVersion/revert(_:)``).
        case revertToOriginal
        /// Look for a better copy now (``QualityUpgrade/requestByHand(_:nowMs:upgradeRunning:originalVersion:)``).
        /// Kept visible but disabled while this track's lookup is already running.
        case upgradeQuality(enabled: Bool)

        public var label: String {
            switch self {
            case .revertToOriginal: return "Revert to original"
            case .upgradeQuality: return "Upgrade quality"
            }
        }

        public var isEnabled: Bool {
            switch self {
            case .revertToOriginal: return true
            case .upgradeQuality(let enabled): return enabled
            }
        }
    }

    /// The player's current item, as far as the menu needs it.
    public struct CurrentItem: Hashable, Sendable {
        public var mediaId: String
        /// The item's `vibramusic://` URI, when the player still has it (a remote controller's copy
        /// may not).
        public var playbackURI: String?

        public init(mediaId: String, playbackURI: String?) {
            self.mediaId = mediaId
            self.playbackURI = playbackURI
        }
    }

    /// The quality row for `song`'s menu, or nil when neither applies.
    ///
    /// Only the player's own copy of the playing track gets one: every rule here is about the stream
    /// the listener is hearing now, and a row opened from a list is about a song, not a stream.
    ///
    /// - "Revert to original" needs a YouTube upload behind the song
    ///   (``PlaybackFallback/hasYouTubeOriginal(_:)``), no local file (nothing to revert *from*),
    ///   no pin already (the menu says so with the other row), and not to be *known* to be playing
    ///   YouTube's own copy (``QualityUpgrade/isKnownToBePlayingYouTubesOwn(_:rendition:streamChoice:)``).
    /// - "Upgrade quality" is the way back: for a pinned track, and for one that got back onto
    ///   YouTube's copy without the listener asking — a broken upgrade takes the track off the
    ///   automatic path for the session, and only this clears that. Never for a local file.
    public static func row(
        for song: Song,
        openedFromPlayer: Bool,
        currentItem: CurrentItem?,
        originalVersion: OriginalVersion = .shared,
        streamChoice: StreamChoice = .shared,
        nerdStats: NerdStats = .shared
    ) -> Row? {
        guard openedFromPlayer, let currentItem, currentItem.mediaId == song.videoId else { return nil }
        let pinned = originalVersion.isPinned(song.videoId)
        let playingYouTubesOwn = playingYouTubesOwn(song.videoId, currentItem: currentItem, streamChoice: streamChoice)

        let offersRevert = PlaybackFallback.hasYouTubeOriginal(song) &&
            song.localUri == nil &&
            !pinned &&
            !playingYouTubesOwn
        if offersRevert { return .revertToOriginal }

        let offersUpgrade = (pinned || playingYouTubesOwn) && song.localUri == nil
        if offersUpgrade {
            return .upgradeQuality(enabled: !nerdStats.isRacing(song.videoId))
        }
        return nil
    }

    /// Whether `videoId` is the track playing, and is known to be playing YouTube's own copy.
    /// An unresolved track playing off the disk cache answers false, which keeps the revert on
    /// offer.
    public static func playingYouTubesOwn(
        _ videoId: String,
        currentItem: CurrentItem?,
        streamChoice: StreamChoice = .shared
    ) -> Bool {
        guard let currentItem, currentItem.mediaId == videoId else { return false }
        return QualityUpgrade.isKnownToBePlayingYouTubesOwn(
            videoId,
            rendition: currentItem.playbackURI.flatMap(QualityUpgrade.cacheTag),
            streamChoice: streamChoice
        )
    }

    /// Whether CarPlay's now-playing template should carry a "Revert to original" button for the
    /// playing `song` (Android Auto's custom layout did). Deliberately simpler than the phone menu:
    /// the car has room for one button and no "Upgrade quality".
    public static func carPlayOffersRevert(_ song: Song?, originalVersion: OriginalVersion = .shared) -> Bool {
        guard let song else { return false }
        return PlaybackFallback.hasYouTubeOriginal(song) &&
            song.localUri == nil &&
            !originalVersion.isPinned(song.videoId)
    }
}
