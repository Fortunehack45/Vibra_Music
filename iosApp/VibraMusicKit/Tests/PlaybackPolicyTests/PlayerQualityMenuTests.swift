import XCTest
import VibraMusicCore
@testable import PlaybackPolicy

/// Which of the two quality rows the player menu leads with (ports PlayerQualityMenuTest, plus the
/// row decision MainActivity makes from it).
///
/// "Revert to original" for a track playing a substituted copy, "Upgrade quality" for one held on
/// YouTube's own. Choosing between them used to read the revert pin alone, so an upgrade that was
/// swapped in and then failed to prove itself — which reverts automatically and pins nothing — left
/// the menu offering to revert a track already playing YouTube's Opus.
final class PlayerQualityMenuTests: XCTestCase {
    private let videoId = "i1o1p_DD6TU"
    private var choice: StreamChoice!
    private var pins: OriginalVersion!
    private var stats: NerdStats!

    override func setUp() {
        super.setUp()
        choice = StreamChoice()
        pins = OriginalVersion(defaults: nil)
        stats = NerdStats()
    }

    private func stream(_ url: String) -> ResolvedStream {
        ResolvedStream(url: URL(string: url)!, origin: .youtube)
    }

    private var song: Song { Song(videoId: videoId, title: "Gehra Hua", artist: "Arijit Singh") }

    private func row(uri: String? = nil, song: Song? = nil, fromPlayer: Bool = true, current: String? = nil) -> PlayerQualityMenu.Row? {
        let song = song ?? self.song
        let item = PlayerQualityMenu.CurrentItem(
            mediaId: current ?? song.videoId,
            playbackURI: uri ?? "vibramusic://watch?v=\(song.videoId)&n=Gehra%20Hua"
        )
        return PlayerQualityMenu.row(
            for: song,
            openedFromPlayer: fromPlayer,
            currentItem: item,
            originalVersion: pins,
            streamChoice: choice,
            nerdStats: stats
        )
    }

    // MARK: Ported

    /// The reported case: reverted after a failed upgrade, back on YouTube's Opus.
    func testATrackBackOnYouTubesOwnStreamIsOfferedAnUpgrade() {
        choice.remember(stream("https://yt/opus"), for: videoId, substituted: false)

        // The revert put the pre-upgrade URI back, so there is no marker on it.
        XCTAssertTrue(QualityUpgrade.isKnownToBePlayingYouTubesOwn(videoId, rendition: nil, streamChoice: choice))
        XCTAssertEqual(row(), .upgradeQuality(enabled: true))
    }

    /// A track actually playing a substitute is the one the revert row is for.
    func testATrackPlayingASubstitutedCopyIsNotOfferedAnUpgrade() {
        choice.remember(stream("https://tidal/flac"), for: videoId, substituted: true)

        XCTAssertFalse(QualityUpgrade.isKnownToBePlayingYouTubesOwn(videoId, rendition: nil, streamChoice: choice))
        XCTAssertEqual(row(), .revertToOriginal)
    }

    /// StreamChoice records what the *first* resolve settled on and is not cleared when an upgrade
    /// swaps a better copy in, so on an upgraded track it still names YouTube — and that track is
    /// exactly the one that should keep the revert row.
    func testAnUpgradedTrackKeepsItsRevertRowDespiteTheStaleYouTubeChoice() {
        choice.remember(stream("https://yt/opus"), for: videoId, substituted: false)

        XCTAssertFalse(QualityUpgrade.isKnownToBePlayingYouTubesOwn(videoId, rendition: "hifi", streamChoice: choice))
        XCTAssertEqual(row(uri: "vibramusic://watch?v=\(videoId)&n=Gehra%20Hua&q=hifi"), .revertToOriginal)
    }

    /// Nothing resolved it in this process — it is playing off the disk cache and what is in that
    /// entry is unknown. The revert stays on offer: the escape hatch for a substitution nothing
    /// announced.
    func testAnUnresolvedCachedTrackKeepsItsRevertRow() {
        XCTAssertFalse(QualityUpgrade.isKnownToBePlayingYouTubesOwn(videoId, rendition: nil, streamChoice: choice))
        XCTAssertEqual(row(), .revertToOriginal)
    }

    // MARK: The rest of the decision

    /// The way back from a revert, and for a pinned track the only one.
    func testAPinnedTrackIsOfferedAnUpgrade() {
        pins.pin(videoId)
        XCTAssertEqual(row(uri: "vibramusic://watch?v=\(videoId)&direct_youtube=1&q=original"), .upgradeQuality(enabled: true))
    }

    /// Kept visible but untappable while its lookup is running.
    func testTheUpgradeRowIsDisabledWhileThisTracksLookupRuns() {
        pins.pin(videoId)
        stats.onLosslessRaceStart(videoId)
        let offered = row()
        XCTAssertEqual(offered, .upgradeQuality(enabled: false))
        XCTAssertEqual(offered?.isEnabled, false)
        XCTAssertEqual(offered?.label, "Upgrade quality")

        stats.onLosslessRaceStart("some-other-track")
        stats.onLosslessRaceEnd(videoId)
        XCTAssertEqual(row(), .upgradeQuality(enabled: true), "another track's search does not disable this one")
    }

    /// Nothing to revert *from*, and nothing to upgrade: the listener is hearing a file they saved.
    func testALocalFileGetsNeitherRow() {
        let saved = Song(videoId: videoId, title: "Gehra Hua", artist: "Arijit Singh", localUri: "file:///Downloads/gehra.m4a")
        XCTAssertNil(row(song: saved))
        pins.pin(videoId)
        XCTAssertNil(row(song: saved), "the pin is only waiting for the day it is streamed again")
    }

    /// Every rule is about the stream playing now, so only the player's copy of the playing track
    /// gets a row.
    func testOnlyThePlayersCopyOfThePlayingTrackGetsARow() {
        XCTAssertNil(row(fromPlayer: false))
        XCTAssertNil(row(current: "another-track"))
        XCTAssertNil(PlayerQualityMenu.row(for: song, openedFromPlayer: true, currentItem: nil, originalVersion: pins, streamChoice: choice, nerdStats: stats))
    }

    /// A music video *is* the YouTube upload; a source track has none behind it.
    func testTracksWithNoYouTubeUploadAreNotOfferedARevert() {
        let video = Song(videoId: "2kjolTLZ_Mg", title: "São Paulo", artist: "The Weeknd", isVideo: true)
        XCTAssertNil(row(song: video))
        let sourceTrack = Song(videoId: "src:addon-1::3919244", title: "Bin Tere", artist: "Vishal & Shekhar")
        XCTAssertNil(row(uri: "vibramusic://source?s=addon-1&t=3919244", song: sourceTrack))
    }

    func testRowLabels() {
        XCTAssertEqual(PlayerQualityMenu.Row.revertToOriginal.label, "Revert to original")
        XCTAssertTrue(PlayerQualityMenu.Row.revertToOriginal.isEnabled)
    }

    /// CarPlay's single button: offered for a streamed track with an upload behind it, until pinned.
    func testCarPlayOffersRevertUntilTheTrackIsPinned() {
        XCTAssertTrue(PlayerQualityMenu.carPlayOffersRevert(song, originalVersion: pins))
        pins.pin(videoId)
        XCTAssertFalse(PlayerQualityMenu.carPlayOffersRevert(song, originalVersion: pins))
        XCTAssertFalse(PlayerQualityMenu.carPlayOffersRevert(nil, originalVersion: pins))
        let saved = Song(videoId: "x", title: "t", artist: "a", localUri: "file:///x.m4a")
        XCTAssertFalse(PlayerQualityMenu.carPlayOffersRevert(saved, originalVersion: pins))
    }
}
