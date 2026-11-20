import Theming
import UIKit
import XCTest
@testable import VibraMusic

/// Tint, mesh and blur read their colours from the bytes the artwork cache draws, so a cover is
/// downloaded once. On Android one Coil cache serves the cover and its palette reads.
final class ArtworkColourReadTests: XCTestCase {
    func testACoverDrawnAndColouredIsDownloadedOnce() async throws {
        let cover = URL(string: "https://covers.test/\(UUID().uuidString)/cover.png")!
        let images = ArtworkImageCache(directory: makeTemporaryDirectory(self), session: CoverServer.session())
        let palettes = ArtworkPaletteCache(loader: ArtworkCacheLoader(cache: images))

        // A track change: the player draws the cover and reads its mesh at the same time.
        async let drawn = images.image(for: cover)
        async let mesh = palettes.mesh(for: cover)
        let (image, _) = await (drawn, mesh)
        XCTAssertNotNil(image)
        // The page tint and the blurred backdrop come later, from the cover already on screen.
        _ = await palettes.seed(for: cover)
        let blur = await palettes.blurredArtwork(for: cover)
        XCTAssertNotNil(blur, "the colour reads decode the cover")

        XCTAssertEqual(CoverServer.requests(for: cover), 1, "the cover and its colours share one download")
    }
}

/// Answers every request with one small four-colour PNG, or for a path ending `<w>x<h>.jpg` a
/// JPEG that many pixels, or for `broken.jpg` a JPEG's header with no picture after it, or for
/// `portal.jpg` a captive portal's sign-in page, or for `portal-then-cover.jpg` that page once
/// followed by a picture, and counts the requests per URL.
final class CoverServer: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [URL: Int] = [:]
    private static let png = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).pngData { context in
        let colours: [UIColor] = [.systemRed, .systemBlue, .systemGreen, .systemOrange]
        for (index, colour) in colours.enumerated() {
            colour.setFill()
            context.fill(CGRect(x: CGFloat(index % 2) * 32, y: CGFloat(index / 2) * 32, width: 32, height: 32))
        }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoverServer.self]
        return URLSession(configuration: configuration)
    }

    static func requests(for url: URL) -> Int {
        lock.withLock { counts[url] ?? 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let count = Self.lock.withLock {
            Self.counts[url, default: 0] += 1
            return Self.counts[url]!
        }
        if url.lastPathComponent == "portal.jpg" || (url.lastPathComponent == "portal-then-cover.jpg" && count == 1) {
            let page = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"])!
            client?.urlProtocol(self, didReceive: page, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("<!DOCTYPE html><html><body>Sign in to the Wi-Fi</body></html>".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.picture(for: url))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func picture(for url: URL) -> Data {
        if url.lastPathComponent == "broken.jpg" {
            return Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00])
        }
        let sides = url.deletingPathExtension().lastPathComponent.split(separator: "x").compactMap { Int($0) }
        guard url.pathExtension == "jpg", sides.count == 2 else { return png }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: sides[0], height: sides[1])
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
