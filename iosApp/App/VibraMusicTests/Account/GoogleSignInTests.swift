import VibraMusicCore
import InnerTube
import SwiftUI
import XCTest
@testable import Vibra Music

/// PORTING §2.2 "Google sign-in": Google's real page in a web view, confirmed with "Use this
/// profile" once YouTube Music has loaded; nothing is stored until the account manager accepts the
/// captured session, and a refusal keeps the page open.
@MainActor
final class GoogleSignInTests: XCTestCase {
    private func captured() -> CapturedSession {
        CapturedSession(cookie: "SAPISID=x", pageId: nil, dataSyncId: "ds", authUser: "0",
                        visitorData: nil, clientVersion: nil, loggedIn: true)
    }

    func testTheSignInPageIsGooglesOwnAndReturnsToYouTubeMusic() {
        let controller = YouTubeLoginWebController(mode: .signIn, dataStore: .nonPersistent())
        let model = GoogleSignInModel(controller: controller)
        XCTAssertEqual(YouTubeWebLogin.startURL(for: .signIn).host(), "accounts.google.com")
        XCTAssertTrue(YouTubeWebLogin.startURL(for: .signIn).absoluteString.contains("continue=https%3A%2F%2Fmusic.youtube.com"))
        // "Use this profile" only once YouTube Music itself has loaded.
        XCTAssertFalse(model.pageReady)
        controller.onPageReadyChange?(true)
        XCTAssertTrue(model.pageReady)
    }

    func testConfirmingBeforeThePageHoldsASessionLeavesTheScreenOpenAndSaysSo() async {
        let model = GoogleSignInModel(controller: YouTubeLoginWebController(mode: .signIn, dataStore: .nonPersistent()))
        let accepted = await model.confirm(capture: { .failure(.notSignedIn) }) { _ in
            XCTFail("nothing to hand over")
            return true
        }
        XCTAssertFalse(accepted)
        XCTAssertTrue(model.captureFailed)
        XCTAssertFalse(model.confirming)
    }

    func testASessionTheAccountManagerRefusesKeepsThePageOpen() async {
        let model = GoogleSignInModel(controller: YouTubeLoginWebController(mode: .signIn, dataStore: .nonPersistent()))
        var handedOver: CapturedSession?
        let accepted = await model.confirm(capture: { .success(self.captured()) }) { session in
            handedOver = session
            return false
        }
        XCTAssertFalse(accepted)
        XCTAssertEqual(handedOver?.dataSyncId, "ds")
        XCTAssertTrue(model.captureFailed)
    }

    func testAnAcceptedSignInLandsOnLibraryWithTheAccountPagesClosed() async {
        let model = GoogleSignInModel(controller: YouTubeLoginWebController(mode: .signIn, dataStore: .nonPersistent()))
        let accepted = await model.confirm(capture: { .success(self.captured()) }) { _ in true }
        XCTAssertTrue(accepted)
        XCTAssertFalse(model.captureFailed)

        let router = AppRouter()
        router.select(.home)
        router.open(.album(browseId: "MPREb_1", seed: nil))
        router.open(.settings)
        router.open(.account)
        GoogleSignInModel.closeAccountPages(router)
        XCTAssertEqual(router.path(for: .home), [.album(browseId: "MPREb_1", seed: nil)])
        GoogleSignInModel.landAfterSignIn(router)
        XCTAssertEqual(router.selectedTab, .library)
    }

    /// A captured session is only stored once the account menu answers as it — offline it can't,
    /// so nothing is written and nobody is signed in.
    func testAnUnverifiableSessionIsNotStored() async {
        let manager = await makeAccountTestManager([])
        let accepted = await manager.handleWebSession(captured(), mode: .signIn)
        XCTAssertFalse(accepted)
        XCTAssertFalse(manager.isSignedIn)
        XCTAssertTrue(manager.accounts.isEmpty)
    }

    func testTheSignInScreenRenders() {
        let app = makeAccountTestApp()
        accountHostAndLayOut(GoogleSignInScreen(startsLoading: false).accountTestEnvironment(app))
    }
}
