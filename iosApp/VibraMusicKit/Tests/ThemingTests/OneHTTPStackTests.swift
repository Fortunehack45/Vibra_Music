import Foundation
import XCTest
@testable import Theming

/// Every network client defaults to the app's one HTTP stack
/// (``VibraMusicHTTP/session``), the way Android uses one OkHttp client.
/// `URLSession.shared` carries its own cookie jar and URL cache, so traffic
/// through a defaulted client would keep cookies the rest of the app refuses
/// and cache responses the app's policy says are not reusable.
final class OneHTTPStackTests: XCTestCase {
    func testDefaultLoaderCarriesNoCookiesAndNoURLCache() {
        let configuration = URLSessionArtworkLoader().session.configuration
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCache)
    }
}
