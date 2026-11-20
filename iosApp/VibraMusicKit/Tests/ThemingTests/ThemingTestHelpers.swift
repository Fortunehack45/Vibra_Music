import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Theming

// MARK: - Synthetic images

func argb(_ red: Int, _ green: Int, _ blue: Int, alpha: Int = 255) -> UInt32 {
    (UInt32(alpha) << 24) | (UInt32(red) << 16) | (UInt32(green) << 8) | UInt32(blue)
}

/// A `width × height` image whose pixel at (x, y) is `color(x, y)`.
func makePixels(width: Int, height: Int, _ color: (_ x: Int, _ y: Int) -> UInt32) -> ArtworkPixels {
    var out = [UInt32]()
    out.reserveCapacity(width * height)
    for y in 0..<height {
        for x in 0..<width {
            out.append(color(x, y))
        }
    }
    return ArtworkPixels(width: width, height: height, argb: out)
}

func solidPixels(width: Int = 64, height: Int = 64, _ color: UInt32) -> ArtworkPixels {
    ArtworkPixels(width: width, height: height, argb: Array(repeating: color, count: width * height))
}

/// A `CGImage` drawn with Core Graphics (not through `ArtworkPixels`), so decode
/// tests exercise the real colour-matched path.
func makeCGImage(
    width: Int,
    height: Int,
    space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
    draw: (CGContext) -> Void
) -> CGImage {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    draw(context)
    return context.makeImage()!
}

func pngData(_ image: CGImage) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
    return data as Data
}

// MARK: - Fixtures

enum ThemingFixtures {
    /// Daft Punk — Random Access Memories, as YouTube Music serves it at w240-h240.
    /// Nine-tenths black, with a silver and a gold helmet.
    static let randomAccessMemories = "ram-w240.jpg"
    /// Tame Impala — Currents, at w240-h240. Purple and black op-art stripes, a
    /// red-orange streak, a chrome ball.
    static let currents = "currents-w240.jpg"

    static func data(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil), "missing fixture \(name)")
        return try Data(contentsOf: url)
    }

    static func pixels(_ name: String, side: Int) throws -> ArtworkPixels {
        try XCTUnwrap(ArtworkPixels(imageData: data(name), fittingLongestSide: side))
    }
}

// MARK: - Loader stub

/// An in-memory `ArtworkImageLoading` that records what was asked of it and can
/// be told to fail a number of times first.
final class StubArtworkLoader: ArtworkImageLoading, @unchecked Sendable {
    struct Request: Equatable {
        var url: URL
        var side: Int
    }

    private let lock = NSLock()
    private var images: [URL: ArtworkPixels] = [:]
    private var failuresRemaining: [URL: Int] = [:]
    private var log: [Request] = []
    var delay: TimeInterval = 0

    func serve(_ pixels: ArtworkPixels, at url: URL, failingFirst failures: Int = 0) {
        lock.withLock {
            images[url] = pixels
            failuresRemaining[url] = failures
        }
    }

    var requests: [Request] {
        lock.withLock { log }
    }

    func image(for url: URL) -> ArtworkPixels? {
        lock.withLock { images[url] }
    }

    func loadArtwork(from url: URL, fittingLongestSide side: Int) async throws -> ArtworkPixels {
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        let outcome: Result<ArtworkPixels, Error> = lock.withLock {
            log.append(Request(url: url, side: side))
            if let remaining = failuresRemaining[url], remaining > 0 {
                failuresRemaining[url] = remaining - 1
                return .failure(URLError(.networkConnectionLost))
            }
            guard let image = images[url] else { return .failure(ArtworkLoadingError.badStatus(404)) }
            return .success(image)
        }
        let image = try outcome.get()
        // Scale like the real loader, so decode sizes can be asserted on.
        guard let cgImage = image.makeCGImage(),
              let fitted = ArtworkPixels(image: cgImage, fittingLongestSide: side)
        else { throw ArtworkLoadingError.undecodable }
        return fitted
    }
}

// MARK: - URLProtocol stub

/// Serves canned responses to a `URLSession` built with ``session()``.
final class StubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> (status: Int, body: Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var hits: [String: Int] = [:]

    /// Routes every request to `host` through `handler`.
    static func register(host: String, handler: @escaping Handler) {
        lock.withLock {
            handlers[host] = handler
            hits[host] = 0
        }
    }

    static func hitCount(host: String) -> Int {
        lock.withLock { hits[host] ?? 0 }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let handler: Handler? = Self.lock.withLock {
            Self.hits[host, default: 0] += 1
            return Self.handlers[host]
        }
        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Assertions

func assertColor(
    _ color: ThemeColor,
    _ expected: UInt32,
    tolerance: Int = 0,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let actual = color.argb
    let channels: [(Int, Int)] = [
        (Int(actual >> 24), Int(expected >> 24)),
        (Int((actual >> 16) & 0xFF), Int((expected >> 16) & 0xFF)),
        (Int((actual >> 8) & 0xFF), Int((expected >> 8) & 0xFF)),
        (Int(actual & 0xFF), Int(expected & 0xFF)),
    ]
    let within = channels.allSatisfy { abs($0.0 - $0.1) <= tolerance }
    XCTAssertTrue(
        within,
        "\(String(format: "#%08X", actual)) is not \(String(format: "#%08X", expected)) ±\(tolerance). \(message())",
        file: file,
        line: line
    )
}

extension ThemeColor {
    var isNeutral: Bool {
        let value = argb
        return (value >> 16) & 0xFF == (value >> 8) & 0xFF && (value >> 8) & 0xFF == value & 0xFF
    }
}
