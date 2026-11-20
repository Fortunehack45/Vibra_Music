import XCTest
@testable import StreamResolution

/// Telling "never" from "not just now" — the difference between one failed track and a request
/// storm (Android's `permanentReason`).
final class PlayabilityVerdictTests: XCTestCase {
    private func status(_ code: String, _ reason: String? = nil, subreason: String? = nil) throws -> PlayerResponse.PlayabilityStatus {
        var object: [String: Any] = ["status": code]
        if let reason { object["reason"] = reason }
        if let subreason {
            object["errorScreen"] = ["playerErrorMessageRenderer": ["subreason": ["runs": [["text": subreason]]]]]
        }
        let data = try JSONSerialization.data(withJSONObject: ["playabilityStatus": object])
        return try XCTUnwrap(PlayerResponse.decode(data).playabilityStatus)
    }

    func testRecordedAnswersClassify() throws {
        XCTAssertEqual(PlayabilityVerdict.classify(try StreamFixture.playerResponse("player_visionos_ok.json").playabilityStatus), .playable)
        XCTAssertEqual(
            PlayabilityVerdict.classify(try StreamFixture.playerResponse("player_visionos_age_restricted.json").playabilityStatus),
            .permanent(.ageRestricted)
        )
        XCTAssertEqual(
            PlayabilityVerdict.classify(try StreamFixture.playerResponse("player_visionos_unavailable.json").playabilityStatus),
            .permanent(.removed)
        )
        // WEB_REMIX's answer for an age-gated music video is a client refusal, not a verdict.
        guard case .refused = PlayabilityVerdict.classify(try StreamFixture.playerResponse("player_web_remix_age_unplayable.json").playabilityStatus) else {
            return XCTFail("UNPLAYABLE Video unavailable must not be permanent")
        }
    }

    func testBotCheckIsItsOwnVerdict() throws {
        XCTAssertEqual(PlayabilityVerdict.classify(try status("LOGIN_REQUIRED", "Sign in to confirm you’re not a bot")), .botCheck)
        XCTAssertEqual(PlayabilityVerdict.classify(try status("LOGIN_REQUIRED", "Sign in to confirm you're not a bot")), .botCheck)
    }

    func testPermanentReasonsAreRecognised() throws {
        XCTAssertEqual(PlayabilityVerdict.classify(try status("UNPLAYABLE", "The uploader has not made this video available in your country")), .permanent(.geoBlocked))
        XCTAssertEqual(PlayabilityVerdict.classify(try status("LOGIN_REQUIRED", "This video is private")), .permanent(.privateVideo))
        XCTAssertEqual(PlayabilityVerdict.classify(try status("UNPLAYABLE", "This video is only available to Music Premium members")), .permanent(.premiumOnly))
        XCTAssertEqual(PlayabilityVerdict.classify(try status("UNPLAYABLE", "This video requires payment to watch")), .permanent(.paidContent))
        XCTAssertEqual(
            PlayabilityVerdict.classify(try status("ERROR", "This video is no longer available because the YouTube account associated with this video has been terminated.")),
            .permanent(.channelTerminated)
        )
        XCTAssertEqual(PlayabilityVerdict.classify(try status("LOGIN_REQUIRED", "Sign in", subreason: "This video may be inappropriate for some users.")), .permanent(.ageRestricted))
    }

    func testClientSpecificRefusalsAreNotPermanent() throws {
        for answer in [try status("UNPLAYABLE", "The page needs to be reloaded."), try status("LOGIN_REQUIRED", "Please sign in"), try status("UNPLAYABLE", "Video unavailable")] {
            guard case .refused = PlayabilityVerdict.classify(answer) else { return XCTFail("\(answer)") }
        }
        guard case .refused = PlayabilityVerdict.classify(nil) else { return XCTFail() }
    }

    /// Age gates outrank vaguer refusals; "removed" needs every client to agree.
    func testWalkVerdictNeedsSupport() {
        XCTAssertEqual(InnerTubeStreamExtractor.verdict([.ageRestricted], answers: 4), .ageRestricted)
        XCTAssertEqual(InnerTubeStreamExtractor.verdict([.geoBlocked, .ageRestricted], answers: 2), .ageRestricted)
        XCTAssertEqual(InnerTubeStreamExtractor.verdict([.removed, .removed], answers: 2), .removed)
        XCTAssertNil(InnerTubeStreamExtractor.verdict([.removed], answers: 3))
        XCTAssertNil(InnerTubeStreamExtractor.verdict([], answers: 5))
        XCTAssertEqual(InnerTubeStreamExtractor.verdict([.removed, .geoBlocked], answers: 5), .geoBlocked)
    }

    func testMessagesMatchAndroid() {
        XCTAssertEqual(PermanentReason.ageRestricted.message(signedIn: false), "This track is age-restricted. Sign in to YouTube to play it.")
        XCTAssertEqual(PermanentReason.ageRestricted.message(signedIn: true), "YouTube will not serve this age-restricted track to this app.")
        XCTAssertEqual(PermanentReason.geoBlocked.message(signedIn: false), "This track isn't available in your country")
        XCTAssertEqual(PermanentReason.premiumOnly.message(signedIn: true), "This track needs YouTube Music Premium")
        XCTAssertEqual(PermanentReason.privateVideo.message(signedIn: true), "This track is private")
        XCTAssertEqual(PermanentReason.paidContent.message(signedIn: true), "This track is paid content")
        XCTAssertEqual(PermanentReason.channelTerminated.message(signedIn: true), "The channel behind this track was terminated")
    }
}
