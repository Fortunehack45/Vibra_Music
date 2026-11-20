import XCTest
@testable import NetworkLibrary

/// Ports the WebDavCoilAuth cases: the credential attaches only to the
/// configured server, and never overrides a request's own credential.
final class WebDavArtworkAuthTests: XCTestCase {
    private var credentials: WebDavCredentials!

    override func setUp() {
        super.setUp()
        credentials = WebDavCredentials(url: "https://cloud.example.com/music", username: "user", password: "pass")
    }

    func testAttachesCredentialOnlyForTheServer() {
        XCTAssertEqual(
            WebDavArtworkAuth.authHeaderFor("https://cloud.example.com/Music/Album/cover.jpg", credentials: credentials),
            "Basic dXNlcjpwYXNz"
        )
        XCTAssertNil(WebDavArtworkAuth.authHeaderFor("https://other.example.com/cover.jpg", credentials: credentials))
        XCTAssertNil(WebDavArtworkAuth.authHeaderFor("not a url", credentials: credentials))
        XCTAssertNil(WebDavArtworkAuth.authHeaderFor(nil, credentials: credentials))
        XCTAssertNil(
            WebDavArtworkAuth.authHeaderFor(
                "https://cloud.example.com/Music/Album/cover.jpg",
                credentials: credentials,
                existingAuthorization: "Bearer x"
            )
        )
    }

    func testStaysQuietWhenUnconfigured() {
        let blank = WebDavCredentials(url: "", username: "", password: "")
        XCTAssertNil(
            WebDavArtworkAuth.authHeaderFor("https://cloud.example.com/Music/Album/cover.jpg", credentials: blank)
        )
    }

    func testAuthorizedRequest() {
        let request = WebDavArtworkAuth.authorizedRequest(for: "https://cloud.example.com/Music/cover.jpg", credentials: credentials)
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Basic dXNlcjpwYXNz")
        let foreign = WebDavArtworkAuth.authorizedRequest(for: "https://other.example.com/cover.jpg", credentials: credentials)
        XCTAssertNil(foreign?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(WebDavArtworkAuth.authorizedRequest(for: "://bad", credentials: credentials))
    }
}
