import XCTest
import VibraMusicCore
@testable import Sources

/// The cross-source matcher: the one piece of the source layer whose failure isn't visible — a bad
/// match doesn't crash, it plays a different recording under the right title. Ported from the
/// matching half of Android's SourcesTest and from TrackIdentityMismatchTest.
final class TrackMatcherTests: XCTestCase {

    private func song(_ title: String, _ artist: String, _ duration: String? = nil) -> Song {
        Song(videoId: "x", title: title, artist: artist, durationText: duration)
    }

    private func matches(_ candidate: Song, _ title: String, _ artist: String, _ durationSec: Int? = nil) -> Bool {
        TrackMatcher.matches(candidate, title: title, artist: artist, durationSec: durationSec)
    }

    func testMatchesTheSameRecordingAcrossDifferingCatalogueTitles() {
        XCTAssertTrue(matches(song("Bohemian Rhapsody (Remastered 2011)", "Queen"), "Bohemian Rhapsody", "Queen"))
        XCTAssertTrue(matches(song("Sunflower", "Post Malone, Swae Lee"), "Sunflower (feat. Swae Lee)", "Post Malone"))
        // Punctuation and case are not identity.
        XCTAssertTrue(matches(song("Don't Stop Me Now", "QUEEN"), "Dont Stop Me Now", "Queen"))
    }

    /// YouTube files the track under its film and credits the lead singer; the catalogue holds the
    /// bare title credited to the duet.
    func testMatchesAFilmCreditAgainstABareCatalogueListing() {
        XCTAssertTrue(matches(song("Paniyon Sa", "Atif Aslam, Tulsi Kumar", "4:07"), "Paniyon Sa (From \"Satyameva Jayate\")", "Atif Aslam", 247))
        XCTAssertTrue(matches(song("Paniyon Sa (From \"Satyameva Jayate\")", "Atif Aslam"), "Paniyon Sa", "Atif Aslam, Tulsi Kumar"))
    }

    func testStripsUploadLabellingFromEitherSide() {
        XCTAssertTrue(matches(song("Tum Hi Ho", "Arijit Singh"), "Tum Hi Ho Full Song", "Arijit Singh"))
        XCTAssertTrue(matches(song("Kesariya", "Arijit Singh"), "Kesariya - Brahmastra | Official Video", "Arijit Singh"))
        // "Artist - Title" uploads: the head is the credit, not the song.
        XCTAssertTrue(matches(song("Believer", "Imagine Dragons"), "Imagine Dragons - Believer", "Imagine Dragons"))
    }

    func testRefusesADifferentSongBySameArtist() {
        XCTAssertFalse(matches(song("The Show Must Go On", "Queen"), "Bohemian Rhapsody", "Queen"))
    }

    func testRefusesACoverByADifferentArtist() {
        XCTAssertFalse(matches(song("Hurt", "Johnny Cash"), "Hurt", "Nine Inch Nails"))
    }

    func testAcceptsASharedArtistWhenCataloguesCreditDifferently() {
        XCTAssertTrue(matches(song("Numb / Encore", "Jay-Z & Linkin Park"), "Numb / Encore", "Linkin Park"))
    }

    /// Composer credit on one side, singer on the other, nothing shared: an exact runtime says they
    /// are one master; the remix and the cover from the same results don't agree on length.
    func testAcceptsAComposerCreditAgainstASingerCreditOnAnExactRuntime() {
        XCTAssertTrue(matches(song("Jhak Maar Ke", "Neeraj Shridhar", "3:53"), "Jhak Maar Ke", "Pritam", 233))
        XCTAssertFalse(matches(song("Jhak Maar Ke", "Leo Lz Mix", "4:01"), "Jhak Maar Ke", "Pritam", 233))
    }

    func testWillNotWaiveTheCreditCheckWithoutARuntimeToBackIt() {
        XCTAssertFalse(matches(song("Jhak Maar Ke", "Neeraj Shridhar"), "Jhak Maar Ke", "Pritam"))
        XCTAssertFalse(matches(song("Jhak Maar Ke", "Neeraj Shridhar", "3:53"), "Jhak Maar Ke", "Pritam", nil))
    }

    func testPrefersACreditedMatchOverARuntimeVouchedOne() {
        let target = TrackMatcher.Target("Jhak Maar Ke", "Pritam, Neeraj Shridhar", durationSec: 233)
        let vouched = song("Jhak Maar Ke", "Some Uploader", "3:53")
        let credited = song("Jhak Maar Ke", "Neeraj Shridhar", "3:53")
        XCTAssertEqual(TrackMatcher.best([vouched, credited], target), credited)
    }

    func testRefusesAnArtistWhoseNameMerelyContainsTheOneAskedFor() {
        XCTAssertFalse(matches(song("No One Knows", "Queens of the Stone Age"), "No One Knows", "Queen"))
    }

    func testRefusesADifferentTakeOfTheSameSong() {
        XCTAssertFalse(matches(song("Shape of You (Acoustic)", "Ed Sheeran"), "Shape of You", "Ed Sheeran"))
        XCTAssertFalse(matches(song("Shape of You", "Ed Sheeran"), "Shape of You (Acoustic)", "Ed Sheeran"))
        XCTAssertFalse(matches(song("Creep (Live)", "Radiohead"), "Creep", "Radiohead"))
        XCTAssertFalse(matches(song("Faded", "Alan Walker"), "Faded (Slowed + Reverb)", "Alan Walker"))
        // A stem carries the right title and artist and is not the song.
        XCTAssertFalse(matches(
            song("Apna Bana Le - Arijit Singh Vocals Only", "Arijit Singh, Sachin-Jigar"),
            "Apna Bana Le (From \"Bhediya\")", "Arijit Singh"
        ))
        XCTAssertFalse(matches(song("Kesariya (Instrumental)", "Arijit Singh"), "Kesariya", "Arijit Singh"))
        // Both sides saying the same thing is still a match.
        XCTAssertTrue(matches(song("Creep (Live)", "Radiohead"), "Creep [Live]", "Radiohead"))
    }

    func testTreatsAnAlbumOrRadioVersionAsThePlainTrack() {
        XCTAssertTrue(matches(song("Africa", "Toto"), "Africa (Album Version)", "Toto"))
        XCTAssertTrue(matches(song("Clocks", "Coldplay"), "Clocks (Radio Edit)", "Coldplay"))
    }

    func testRefusesACandidateWhoseRuntimeIsNowhereNear() {
        XCTAssertFalse(matches(song("Levitating", "Dua Lipa", "1:00:12"), "Levitating", "Dua Lipa", 203))
        XCTAssertTrue(matches(song("Levitating", "Dua Lipa", "3:25"), "Levitating", "Dua Lipa", 203))
    }

    func testFallsBackToTitleAloneWhenNoArtistIsKnown() {
        XCTAssertTrue(matches(song("Clair de Lune", "Debussy"), "Clair de Lune", ""))
        XCTAssertFalse(matches(song("Reverie", "Debussy"), "Clair de Lune", ""))
    }

    func testJackAndJillWithAnAmpersandIsTheSameTitle() {
        XCTAssertTrue(matches(song("Jack & Jill", "Nursery"), "Jack and Jill", "Nursery"))
    }

    // MARK: Choosing between candidates

    func testPicksTheClosestCandidateRatherThanTheFirstAcceptableOne() {
        let target = TrackMatcher.Target("Paniyon Sa", "Atif Aslam", durationSec: 247)
        let wrongLength = song("Paniyon Sa", "Atif Aslam", "4:32")
        let right = song("Paniyon Sa", "Atif Aslam, Tulsi Kumar", "4:06")
        XCTAssertEqual(TrackMatcher.best([wrongLength, right], target), right)
    }

    /// JioSaavn lists these under the same title and artist though they are different recordings.
    func testUsesTheAlbumToSeparateDuplicateJioSaavnRecordings() {
        let target = TrackMatcher.Target("Brown Rang", "Yo Yo Honey Singh", durationSec: 175, album: "International Villager")
        var wanted = song("Brown Rang", "Yo Yo Honey Singh", "2:59")
        wanted.albumName = "International Villager"
        var wrongButCloser = song("Brown Rang", "Yo Yo Honey Singh", "2:54")
        wrongButCloser.albumName = "Chaar Ikke"
        XCTAssertEqual(TrackMatcher.best([wrongButCloser, wanted], target), wanted)
    }

    func testDetectsConflictingReleasesWhenTheRequestedAlbumIsUnknown() {
        let target = TrackMatcher.Target("Brown Rang", "Yo Yo Honey Singh", durationSec: 175)
        var villager = song("Brown Rang", "Yo Yo Honey Singh", "2:59")
        villager.albumName = "International Villager"
        var chaarIkke = song("Brown Rang", "Yo Yo Honey Singh", "2:54")
        chaarIkke.albumName = "Chaar Ikke"
        var deluxe = villager
        deluxe.albumName = "International Villager (Deluxe Edition)"

        XCTAssertTrue(TrackMatcher.hasConflictingAlbums([villager, chaarIkke], target))
        XCTAssertFalse(TrackMatcher.hasConflictingAlbums([villager, deluxe], target))
        var withAlbum = target
        withAlbum.album = "International Villager"
        XCTAssertFalse(TrackMatcher.hasConflictingAlbums([villager, chaarIkke], withAlbum))
    }

    func testUsesTheUniquelyFullestCreditToResolveAJioSaavnReleaseCollision() {
        let target = TrackMatcher.Target("Ek Dil Ek Jaan", "Shivam Pathak", durationSec: 220)
        var original = song("Ek Dil Ek Jaan", "Shivam Pathak, Mujtaba Aziz Naza, Kunal Pandit, Farhan Sabri", "3:40")
        original.albumName = "Padmaavat"
        var compilation = song("Ek Dil Ek Jaan", "Shivam Pathak", "3:39")
        compilation.albumName = "Top 20 - Romantic Songs 2018"
        var fromCompilation = song("Ek Dil Ek Jaan (From Padmaavat)", "Shivam Pathak, Sanjay Leela Bhansali, A.M. Turaz", "3:39")
        fromCompilation.albumName = "Bollywood Magic Mix"
        XCTAssertEqual(TrackMatcher.uniquelyMostCreditedCloseMatch([original, compilation, fromCompilation], target), original)
    }

    func testRetainsJioSaavnRefusalWhenConflictingReleasesTieOnCreditCoverage() {
        let target = TrackMatcher.Target("Mere Bina", "Pritam, Nikhil D'Souza", durationSec: 290)
        var first = song("Mere Bina", "Pritam, Nikhil D'Souza", "4:49")
        first.albumName = "Crook"
        var second = song("Mere Bina", "Pritam, Nikhil D'Souza", "4:51")
        second.albumName = "Sad Love Hits"
        XCTAssertNil(TrackMatcher.uniquelyMostCreditedCloseMatch([first, second], target))
    }

    func testTargetKeepsTheQueuedAlbumIdentity() {
        var queued = song("Brown Rang", "Yo Yo Honey Singh", "2:59")
        queued.albumName = "International Villager"
        queued.isExplicit = true
        let target = TrackMatcher.targetOf(queued)
        XCTAssertEqual(target.album, "International Villager")
        XCTAssertEqual(target.durationSec, 179)
        XCTAssertEqual(target.isExplicit, true)
    }

    func testExplicitYouTubeTrackCannotMatchTheCensoredEdition() {
        let target = TrackMatcher.Target("Starboy", "The Weeknd", durationSec: 230, album: "Starboy", isExplicit: true)
        var clean = song("Starboy", "The Weeknd", "3:50")
        clean.albumName = "Starboy"
        clean.isExplicit = false
        var uncensored = clean
        uncensored.videoId = "uncensored"
        uncensored.isExplicit = true
        XCTAssertEqual(TrackMatcher.best([clean, uncensored], target), uncensored)
        XCTAssertNil(TrackMatcher.score(clean, target))
    }

    func testUnknownYouTubeExplicitStateDoesNotRejectTheCreditedJioSaavnTrack() {
        let target = TrackMatcher.Target("For A Reason", "Karan Aujla, IKKY", durationSec: 180, isExplicit: nil)
        var wanted = song("For A Reason", "Karan Aujla, IKKY, Ikwinder Sahota, Milan D'Agostini", "3:00")
        wanted.videoId = "vLSaC03b"
        wanted.albumName = "P-POP CULTURE"
        wanted.isExplicit = true
        var remix = song("For A Reason", "Aye Manny", "3:00")
        remix.videoId = "sN24LH3L"
        remix.albumName = "For A Reason (Remix)"
        remix.isExplicit = false
        XCTAssertEqual(TrackMatcher.best([remix, wanted], target), wanted)
        XCTAssertEqual(TrackMatcher.ranked([remix, wanted], target), [wanted])
    }

    func testMissingYouTubeBadgeDoesNotRejectExplicitIReallyDo() {
        let target = TrackMatcher.Target("I Really Do...", "Karan Aujla", durationSec: 193)
        var wanted = song("I Really Do...", "Karan Aujla, IKKY, Ikwinder Sahota, Jamal Europe", "3:13")
        wanted.videoId = "1vja2Ptl"
        wanted.isExplicit = true
        var other = song("I Really Do...", "Arjun Viraat, Shefali Alvares", "3:02")
        other.videoId = "WeCT149y"
        other.isExplicit = false
        XCTAssertEqual(TrackMatcher.best([other, wanted], target), wanted)
    }

    /// YouTube presented the official video as a song row (isVideo false), 211 s against the 179 s
    /// audio; a 3:30 track by other artists must not win on runtime.
    func testUnlabelledMusicVideoTimingCannotMakeAnotherArtistTheBrownRangMatch() {
        let target = TrackMatcher.Target("Brown Rang", "Yo Yo Honey Singh", durationSec: 211, isVideo: false)
        var wantedAudio = song("Brown Rang", "Yo Yo Honey Singh", "2:59")
        wantedAudio.videoId = "vj2tW1iy"
        wantedAudio.albumName = "International Villager"
        var wrongExactRuntime = song("Brown Rang", "Lovely, Jais Rikhi, Love Sagar", "3:30")
        wrongExactRuntime.videoId = "UgOpg53G"
        wrongExactRuntime.albumName = "Brown Rang"
        XCTAssertEqual(TrackMatcher.best([wrongExactRuntime, wantedAudio], target), wantedAudio)
        XCTAssertEqual(TrackMatcher.ranked([wrongExactRuntime, wantedAudio], target), [wantedAudio])
        XCTAssertFalse(TrackMatcher.hasConflictingAlbums([wantedAudio], target))
    }

    func testManualVideoAudioSwitchAcceptsTheOfficialSongDespiteALongVisualIntro() {
        let target = TrackMatcher.Target("Big Dawgs", "Hanumankind, Kalmi", durationSec: 391, isVideo: true)
        var officialAudio = song("Big Dawgs", "Hanumankind, Kalmi", "3:11")
        officialAudio.videoId = "official-audio"
        var cover = song("Big Dawgs", "Unrelated Cover Artist", "6:31")
        cover.videoId = "cover"
        XCTAssertNil(TrackMatcher.best([officialAudio, cover], target))
        XCTAssertEqual(TrackMatcher.bestOfficialAudioForVideo([cover, officialAudio], target), officialAudio)
    }

    func testHasNothingToOfferWhenNoCandidateIsTheRecording() {
        let target = TrackMatcher.Target("Paniyon Sa", "Atif Aslam")
        XCTAssertNil(TrackMatcher.best([song("Paniyon Sa", "Some Cover Band")], target))
        XCTAssertNil(TrackMatcher.best([], target))
    }

    // MARK: Asking

    func testAsksForTheTitleACatalogueWouldFileTheTrackUnder() {
        let queries = TrackMatcher.queries(
            TrackMatcher.Target("Paniyon Sa (From \"Satyameva Jayate\") | Official Video", "Atif Aslam, Tulsi Kumar")
        )
        XCTAssertEqual(queries, ["paniyon sa atif aslam", "paniyon sa"])
    }

    func testKeepsTheVersionMarkerInTheQuery() {
        XCTAssertEqual(TrackMatcher.queries(TrackMatcher.Target("Shape of You (Acoustic)", "")), ["shape of you acoustic"])
    }

    func testHasNothingToAskForWithoutATitle() {
        XCTAssertTrue(TrackMatcher.queries(TrackMatcher.Target("", "Atif Aslam")).isEmpty)
    }

    // MARK: The mid-track swap guard

    func testOnlySwapsInACopyOfDemonstrablyTheSameLength() {
        let playing = TrackMatcher.Target("Jo Tere Sang", "Jeet Gannguli", durationSec: 306)
        XCTAssertTrue(TrackMatcher.withinSeconds(song("Jo Tere Sang", "x", "5:06"), playing, 2))
        XCTAssertTrue(TrackMatcher.withinSeconds(song("Jo Tere Sang", "x", "5:04"), playing, 2))
        XCTAssertFalse(TrackMatcher.withinSeconds(song("Jo Tere Sang", "x", "5:12"), playing, 2))
        XCTAssertFalse(TrackMatcher.withinSeconds(song("Jo Tere Sang", "x"), playing, 2))
        XCTAssertFalse(TrackMatcher.withinSeconds(song("Jo Tere Sang", "x", "5:06"), TrackMatcher.Target("Jo Tere Sang", "Jeet Gannguli"), 2))
    }

    func testReadsARuntimeOffAQueueRow() {
        XCTAssertEqual(TrackMatcher.secondsOf("3:45"), 225)
        XCTAssertEqual(TrackMatcher.secondsOf("1:02:03"), 3_723)
        XCTAssertNil(TrackMatcher.secondsOf(nil))
        XCTAssertNil(TrackMatcher.secondsOf("live"))
        XCTAssertNil(TrackMatcher.secondsOf("0:00"))
    }

    // MARK: TrackIdentityMismatchTest

    /// A catalogue target of 302 s against a 209 s cached rendition is a different edit; a small
    /// drift or an unknown side is not.
    func testSevereDurationMismatchIsDetectedOnlyPastTheLimit() {
        XCTAssertTrue(TrackMatcher.isSevereMismatch(expectedSec: 302, actualSec: 209))
        XCTAssertFalse(TrackMatcher.isSevereMismatch(expectedSec: 302, actualSec: 296))
        XCTAssertFalse(TrackMatcher.isSevereMismatch(expectedSec: 302, actualSec: 288))
        XCTAssertFalse(TrackMatcher.isSevereMismatch(expectedSec: nil, actualSec: 209))
        XCTAssertFalse(TrackMatcher.isSevereMismatch(expectedSec: 302, actualSec: nil))
    }

    /// The São Paulo regression: a 302 s catalogue track played from a 209 s YouTube video. The
    /// JioSaavn copy agrees with the catalogue runtime, not the video's, and must still match.
    func testSaoPauloRegressionMatchesAgainstTheCatalogueRuntime() {
        let catalogue = TrackMatcher.Target("Sao Paulo", "The Weeknd, Anitta", durationSec: 302)
        let youtubeVideoRuntime = 209
        XCTAssertTrue(TrackMatcher.isSevereMismatch(expectedSec: catalogue.durationSec, actualSec: youtubeVideoRuntime))
        let jioSaavnCandidate = 302
        XCTAssertFalse(SourceResolver.sameRecordingAs(jioSaavnCandidate, youtubeVideoRuntime))
        XCTAssertTrue(SourceResolver.sameRecordingAs(jioSaavnCandidate, catalogue.durationSec))
        XCTAssertTrue(TrackMatcher.withinSeconds(song("Sao Paulo", "The Weeknd, Anitta", "5:02"), catalogue, 2))
    }
}
