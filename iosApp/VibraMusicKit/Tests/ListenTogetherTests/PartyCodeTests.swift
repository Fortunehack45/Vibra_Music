import XCTest
@testable import ListenTogether

/// Party codes: the server's `codes` package contract, mirrored on the client so junk is
/// refused before a round trip.
final class PartyCodeTests: XCTestCase {
    func testRandomCodesAreValid() {
        for _ in 0 ..< 50 {
            XCTAssertTrue(PartyCode.isValid(PartyCode.makeRandom()))
        }
    }

    func testValidatesAlphabetOnly() {
        XCTAssertTrue(PartyCode.isValid("A1B2C3"))
        XCTAssertTrue(PartyCode.isValid("012345"))
        // I, L and O are not in the alphabet — they are only ever typed, never minted.
        XCTAssertFalse(PartyCode.isValid("ABCIL0"))
        XCTAssertFalse(PartyCode.isValid("ABCO12"))
        XCTAssertFalse(PartyCode.isValid("ABC12"))
        XCTAssertFalse(PartyCode.isValid("ABC1234"))
        XCTAssertFalse(PartyCode.isValid("abc123"))
    }

    func testNormaliseIsCharitableLikeTheServer() {
        XCTAssertEqual("A1B2C3", PartyCode.normalize("a1b2c3"))
        XCTAssertEqual("A11C30", PartyCode.normalize("A IL C3O"))
        XCTAssertEqual("ABC123", PartyCode.normalize("abc-123"))
        XCTAssertEqual("ABC123", PartyCode.normalize("  abc123  "))
    }

    func testCleanInviteCodeDoesNotRemap() {
        XCTAssertEqual("ABC123", PartyCode.cleanInviteCode("abc123"))
        XCTAssertNil(PartyCode.cleanInviteCode("abc12"))
        XCTAssertNil(PartyCode.cleanInviteCode("abc1234"))
        XCTAssertNil(PartyCode.cleanInviteCode("ab!@#12"))
    }
}
