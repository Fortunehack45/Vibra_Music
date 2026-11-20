import VibraMusicCore
import Foundation

/// Fetches and decodes artwork for the colour readers.
///
/// The default, ``URLSessionArtworkLoader``, goes to the network (or disk, for a
/// `file:` URL). The app can wire in something that shares its image pipeline's
/// cache instead — on Android the colour reads come out of Coil's cache, so a
/// cover on screen is never downloaded twice.
public protocol ArtworkImageLoading: Sendable {
    /// The image at `url`, scaled so its longer side is `side` pixels.
    func loadArtwork(from url: URL, fittingLongestSide side: Int) async throws -> ArtworkPixels
}

public enum ArtworkLoadingError: Error, Equatable, Sendable {
    /// The server answered with a non-2xx status.
    case badStatus(Int)
    /// The bytes weren't an image ImageIO could read.
    case undecodable
}

/// Loads artwork through a `URLSession` and decodes it with ImageIO, straight to
/// a thumbnail — the full-size bitmap is never held.
public struct URLSessionArtworkLoader: ArtworkImageLoading {
    public let session: URLSession

    public init(session: URLSession = VibraMusicHTTP.session) {
        self.session = session
    }

    public func loadArtwork(from url: URL, fittingLongestSide side: Int) async throws -> ArtworkPixels {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ArtworkLoadingError.badStatus(http.statusCode)
        }
        guard let pixels = ArtworkPixels(imageData: data, fittingLongestSide: side) else {
            throw ArtworkLoadingError.undecodable
        }
        return pixels
    }
}

/// Asks the artwork host for the size a surface actually shows.
public enum ArtworkSizing {
    /// YouTube Music artwork URLs carry their size as a `w<px>-h<px>` hint
    /// (`…=w544-h544-l90-rj`); every such hint is rewritten to `px` square, which
    /// is what Core's `artworkAt(px)` does. URLs without one (video thumbnails,
    /// local files) come back unchanged.
    ///
    /// Asking for the size a surface already has on screen is what makes a colour
    /// read come out of the image cache rather than off the network.
    public static let youTubeMusic: ArtworkPaletteCache.Sizing = { url, pixels in
        resizedYouTubeMusicURL(url, pixels: pixels)
    }

    /// Leaves every URL as it is.
    public static let unchanged: ArtworkPaletteCache.Sizing = { url, _ in url }

    static func resizedYouTubeMusicURL(_ url: URL, pixels: Int) -> URL {
        let string = url.absoluteString
        let resized = string.replacingOccurrences(
            of: "w\\d+-h\\d+",
            with: "w\(pixels)-h\(pixels)",
            options: .regularExpression
        )
        if resized == string { return url }
        return URL(string: resized) ?? url
    }
}
