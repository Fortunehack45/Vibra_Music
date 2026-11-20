import XCTest
@testable import InnerTube

/// Whether a captured cookie header carries a secret Innertube requests can be signed with
/// (Android's AuthCookieTest), which of them signs, and the SAPISIDHASH it produces.
///
/// The failure these replace was silent in both directions and cost users their listening history:
/// the old test was `contains("SAPISID")`, which `__Secure-3PAPISID` satisfies, so a jar holding only
/// the `__Secure-` forms was "signed in" and yet every request went out unsigned.
final class SigningCookieTests: XCTestCase {

    func testPlainSAPISIDIsAccepted() {
        XCTAssertTrue(YouTubeAuthStore.hasApiSid("SID=abc; SAPISID=secret; HSID=def"))
    }

    func testAJarWithOnlyTheSecureFormsIsAccepted() {
        XCTAssertTrue(YouTubeAuthStore.hasApiSid("SID=abc; __Secure-3PAPISID=secret"))
        XCTAssertTrue(YouTubeAuthStore.hasApiSid("SID=abc; __Secure-1PAPISID=secret"))
    }

    func testLeadingAndTrailingWhitespaceDoesNotHideACookie() {
        XCTAssertTrue(YouTubeAuthStore.hasApiSid("SID=abc;SAPISID=secret;HSID=def"))
        XCTAssertTrue(YouTubeAuthStore.hasApiSid("  SAPISID = secret  "))
    }

    func testAJarWithNoSigningSecretIsRejected() {
        XCTAssertFalse(YouTubeAuthStore.hasApiSid("SID=abc; HSID=def; SSID=ghi; APISID=jkl"))
        XCTAssertFalse(YouTubeAuthStore.hasApiSid(""))
    }

    func testAPresentButEmptyValueIsRejected() {
        // A cleared cookie is not a credential; signing with "" gives a digest Google refuses.
        XCTAssertFalse(YouTubeAuthStore.hasApiSid("SID=abc; SAPISID=; HSID=def"))
    }

    func testTheNameHasToBeTheWholeName() {
        XCTAssertFalse(YouTubeAuthStore.hasApiSid("APISID=secret"))
        XCTAssertFalse(YouTubeAuthStore.hasApiSid("NOT-SAPISID=secret"))
        XCTAssertFalse(YouTubeAuthStore.hasApiSid("PREF=tz=SAPISID"))
    }

    // MARK: - Which secret signs

    func testThePlainFormSignsWhenPresentThenTheThirdPartyThenTheFirstParty() {
        XCTAssertEqual(SAPISIDAuth.sapisid(fromCookieHeader: "__Secure-1PAPISID=one; __Secure-3PAPISID=three; SAPISID=plain"), "plain")
        XCTAssertEqual(SAPISIDAuth.sapisid(fromCookieHeader: "__Secure-1PAPISID=one; __Secure-3PAPISID=three"), "three")
        XCTAssertEqual(SAPISIDAuth.sapisid(fromCookieHeader: "__Secure-1PAPISID=one"), "one")
        XCTAssertNil(SAPISIDAuth.sapisid(fromCookieHeader: "SID=1; APISID=2"))
    }

    func testACookieValueMayItselfContainEqualsSigns() {
        XCTAssertEqual(SAPISIDAuth.sapisid(fromCookieHeader: "SAPISID=abc/def=="), "abc/def==")
    }

    // MARK: - SAPISIDHASH

    func testAuthorizationIsTheTimestampAndSHA1OfTimestampSecretAndOrigin() {
        // sha1("1700000000 secret https://music.youtube.com")
        XCTAssertEqual(
            SAPISIDAuth.authorization(sapisid: "secret", origin: "https://music.youtube.com", timestamp: 1_700_000_000),
            "SAPISIDHASH 1700000000_d2a0deeb95ea263a68778d9e9ac8840dce59d800"
        )
        // The origin is part of what is signed: youtube.com's switcher gets its own digest.
        XCTAssertEqual(
            SAPISIDAuth.authorization(sapisid: "secret", origin: "https://www.youtube.com", timestamp: 1_700_000_000),
            "SAPISIDHASH 1700000000_8826f35e8fadc232ceb4c889bdb7a3a586eb7379"
        )
    }
}
