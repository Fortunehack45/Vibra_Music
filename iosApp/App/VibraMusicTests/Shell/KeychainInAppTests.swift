import VibraMusicCore
import XCTest

/// Package test bundles run without entitlements, so they can't reach the Keychain on the
/// simulator. These run inside the signed app, which is where credentials really live.
final class KeychainInAppTests: XCTestCase {
    private let store = KeychainStore(service: "com.fortune.vibramusic.ios.tests.\(UUID().uuidString)")

    override func tearDown() {
        try? store.removeAll()
        super.tearDown()
    }

    func testCredentialsRoundTripInTheAppProcess() throws {
        try store.setString("secret-token", forKey: "lastfm_session_key")
        XCTAssertEqual(try store.string(forKey: "lastfm_session_key"), "secret-token")
        try store.setString(nil, forKey: "lastfm_session_key")
        XCTAssertNil(try store.string(forKey: "lastfm_session_key"))
    }
}
