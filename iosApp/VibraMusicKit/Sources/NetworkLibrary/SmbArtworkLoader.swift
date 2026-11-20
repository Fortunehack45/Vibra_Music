import Foundation

// Ports data/smb/SmbCoverFetcher.kt: covers off the share for the app's
// image loading. Reads the whole picture — covers are kilobytes, and
// listings already cap what can be one — then hands the loader bytes it
// decodes and caches exactly like any network image.
//
// The app's image pipeline routes `smb://` artwork URLs here; anything that
// isn't `smb://` falls straight through to the default loader.

/// Cover bytes off the SMB share for the app's image loading.
public struct SmbArtworkLoader: Sendable {
    private let client: SmbClient

    public init(client: SmbClient) {
        self.client = client
    }

    public func supports(_ urlString: String) -> Bool {
        SmbConfig.isSmbUrl(urlString)
    }

    /// The picture bytes and its MIME type for an `smb://` artwork URL.
    public func load(_ urlString: String) async throws -> (data: Data, mimeType: String?) {
        let bytes = try await client.readFully(streamUrl: urlString)
        return (bytes, Self.mimeType(for: urlString))
    }

    static func mimeType(for urlString: String) -> String? {
        switch urlString.split(separator: ".").last.map({ $0.lowercased() }) ?? "" {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        default: return nil
        }
    }
}
