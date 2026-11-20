import XCTest
@testable import NetworkLibrary

/// Ports RemoteListingTest.kt against RemoteListing and Core's LoadState.
final class RemoteListingStateTests: XCTestCase {
    struct Denied: LocalizedError {
        var errorDescription: String? { "STATUS_ACCESS_DENIED (0xc0000022): Could not connect to \\\\nas\\Music" }
    }

    struct Blank: LocalizedError {
        var errorDescription: String? { "  " }
    }

    func testListsWhatTheServerReturned() {
        XCTAssertEqual(
            RemoteListing.state(for: .success(["a", "b"]), emptyMessage: "empty"),
            .success(["a", "b"])
        )
    }

    func testEmptyListingReadsAsEmpty() {
        XCTAssertEqual(
            RemoteListing.state(for: .success([String]()), emptyMessage: "empty"),
            .error("empty")
        )
    }

    func testFailedListingNamesItsCause() {
        XCTAssertEqual(
            RemoteListing.state(for: Result<[String], Error>.failure(Denied()), emptyMessage: "empty"),
            .error("STATUS_ACCESS_DENIED (0xc0000022): Could not connect to \\\\nas\\Music")
        )
    }

    func testFailureWithoutMessageNamesItsType() {
        XCTAssertEqual(
            RemoteListing.state(for: Result<[String], Error>.failure(Blank()), emptyMessage: "empty"),
            .error("Blank")
        )
    }
}
