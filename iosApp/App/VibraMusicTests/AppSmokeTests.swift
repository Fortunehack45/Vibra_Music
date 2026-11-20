import SwiftUI
import XCTest
@testable import Vibra Music

@MainActor
final class AppSmokeTests: XCTestCase {
    func testRootViewBuilds() {
        // Hosted rather than `RootView().body`: reading a view's @State outside a view hierarchy
        // makes SwiftUI warn and hand back a fresh value each time.
        let host = UIHostingController(rootView: RootView())
        host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        host.view.layoutIfNeeded()
        XCTAssertEqual(host.view.bounds.size, CGSize(width: 393, height: 852))
    }
}
