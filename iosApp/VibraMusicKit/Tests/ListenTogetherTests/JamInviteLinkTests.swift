import XCTest
@testable import ListenTogether

/// Ports `JamInviteLinkTest` (invite halves) — invite parsing, share-URL building, and the
/// server-routing invariants that keep deep-link switches on the right server.
final class JamInviteLinkTests: XCTestCase {
    func testParsesAndNormalizesPublicInvite() {
        XCTAssertEqual("A1B2C3", JamInviteLink.parse("https://vibramusic.kushagrasingh.in/invite/a1b2c3"))
    }

    func testAcceptsQueryParametersWithoutMakingThemPartOfTheCode() {
        XCTAssertEqual("ABC123", JamInviteLink.parse("https://vibramusic.kushagrasingh.in/invite/ABC123?from=share"))
    }

    func testRejectsOtherHostsSchemesPathsAndMalformedCodes() {
        XCTAssertNil(JamInviteLink.parse("http://vibramusic.kushagrasingh.in/invite/ABC123"))
        XCTAssertNil(JamInviteLink.parse("https://example.com/invite/ABC123"))
        XCTAssertNil(JamInviteLink.parse("https://vibramusic.kushagrasingh.in/"))
        XCTAssertNil(JamInviteLink.parse("https://vibramusic.kushagrasingh.in/download"))
        XCTAssertNil(JamInviteLink.parse("https://vibramusic.kushagrasingh.in/invite/ABC123/"))
        XCTAssertNil(JamInviteLink.parse("https://vibramusic.kushagrasingh.in/invite/ABC123/extra"))
        XCTAssertNil(JamInviteLink.parse("https://vibramusic.kushagrasingh.in/invite/TOO-LONG"))
        XCTAssertNil(JamInviteLink.parse(nil))
        XCTAssertNil(JamInviteLink.parse("not a url at all"))
    }

    func testBuildsCanonicalShareURL() {
        XCTAssertEqual(
            "https://vibramusic.kushagrasingh.in/invite/ABC123",
            JamInviteLink.url(code: "abc123"))
    }

    func testBuildsCustomServerShareURL() {
        XCTAssertEqual(
            "https://my-party.onrender.com/invite/ABC123",
            JamInviteLink.url(code: "abc123", customServer: "https://my-party.onrender.com"))
        XCTAssertEqual(
            "https://my-party.onrender.com/invite/ABC123",
            JamInviteLink.url(code: "abc123", customServer: "https://my-party.onrender.com/"))
        XCTAssertEqual(
            "https://vibramusic.kushagrasingh.in/invite/ABC123",
            JamInviteLink.url(code: "abc123", customServer: ""))
        XCTAssertEqual(
            "https://vibramusic.kushagrasingh.in/invite/ABC123",
            JamInviteLink.url(code: "abc123", customServer: nil))
    }

    func testBuildsCustomSchemeURL() {
        XCTAssertEqual(
            "vibramusic://party/ABC123?server=https%3A%2F%2Fmy-party.onrender.com",
            JamInviteLink.schemeUrl(code: "abc123", customServer: "https://my-party.onrender.com"))
        XCTAssertEqual(
            "vibramusic://party/ABC123",
            JamInviteLink.schemeUrl(code: "abc123", customServer: nil))
    }

    func testParsesCustomSchemeInviteWithServer() {
        let invite = JamInviteLink.parseInvite("vibramusic://party/a1b2c3?server=https%3A%2F%2Fmy-party.onrender.com")
        XCTAssertEqual("A1B2C3", invite?.code)
        XCTAssertEqual("https://my-party.onrender.com", invite?.serverUrl)
    }

    func testParsesCustomSchemeInviteWithoutServer() {
        let invite = JamInviteLink.parseInvite("vibramusic://party/XYZ789")
        XCTAssertEqual("XYZ789", invite?.code)
        XCTAssertNil(invite?.serverUrl)
    }

    func testParsesCustomSchemeInviteWithCodeQuery() {
        let invite = JamInviteLink.parseInvite("vibramusic://party?code=abc123")
        XCTAssertEqual("ABC123", invite?.code)
    }

    func testParsesWebInviteWithServerParameter() {
        let invite = JamInviteLink.parseInvite(
            "https://vibramusic.kushagrasingh.in/invite/ABC123?server=https%3A%2F%2Fcustom.example.com")
        XCTAssertEqual("ABC123", invite?.code)
        XCTAssertEqual("https://custom.example.com", invite?.serverUrl)
    }

    func testSchemeRoundTrip() {
        // A built scheme URL parses back to the same code and server.
        let built = JamInviteLink.schemeUrl(code: "J4M001", customServer: "https://my-party.onrender.com")
        let parsed = JamInviteLink.parseInvite(built)
        XCTAssertEqual("J4M001", parsed?.code)
        XCTAssertEqual("https://my-party.onrender.com", parsed?.serverUrl)
    }

    func testSwitchResultHierarchyHoldsExpectedProperties() {
        let success = PartySwitchResult.success(partyCode: "ABC123")
        let recovered = PartySwitchResult.targetFailedRecovered(partyCode: "OLD123", targetError: "Party full")
        let noParty = PartySwitchResult.targetFailedNoParty(targetError: "Connection refused")
        if case .success(let code) = success { XCTAssertEqual("ABC123", code) } else { XCTFail() }
        if case .targetFailedRecovered(let code, let error) = recovered {
            XCTAssertEqual("OLD123", code)
            XCTAssertEqual("Party full", error)
        } else { XCTFail() }
        if case .targetFailedNoParty(let error) = noParty {
            XCTAssertEqual("Connection refused", error)
        } else { XCTFail() }
    }

    @MainActor
    func testInviteInboxRelaysDeepLinkToUI() {
        let inbox = PartyInviteInbox()
        XCTAssertNil(inbox.pending)
        XCTAssertFalse(inbox.consume(url: URL(string: "https://example.com/nope")!))
        XCTAssertNil(inbox.pending)
        XCTAssertTrue(inbox.consume(url: URL(string: "vibramusic://party/ABC123")!))
        XCTAssertEqual("ABC123", inbox.pending?.code)
        inbox.handled()
        XCTAssertNil(inbox.pending)
    }
}
