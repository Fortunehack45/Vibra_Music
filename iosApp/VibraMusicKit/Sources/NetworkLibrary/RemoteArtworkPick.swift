import Foundation

// Ports data/remote/RemoteArtwork.kt: picking a track's cover from the
// pictures filed beside it. Shared by the SMB and WebDAV libraries.

/// A track's cover, chosen from the pictures filed beside it.
///
/// `cover.*` and friends win over a stray `IMG_1234.jpg`, because a folder a
/// download manager drops is full of exactly those; with nothing filed there
/// is no cover rather than a wrong one. Grouping siblings by directory is the
/// caller's job — only it knows what a "directory" is on its protocol.
public enum RemoteArtwork {
    private static let preferredStems = ["cover", "folder", "front", "albumart", "album", "artwork"]

    /// The best cover URL in `siblingUrls`, or nil when there are no siblings.
    public static func pick(_ siblingUrls: [String]) -> String? {
        guard !siblingUrls.isEmpty else { return nil }
        return siblingUrls.sorted {
            let left = rank(of: $0), right = rank(of: $1)
            if left != right { return left < right }
            return stem(of: $0) < stem(of: $1)
        }.first
    }

    private static func rank(of fileUrl: String) -> Int {
        let name = stem(of: fileUrl)
        return preferredStems.firstIndex(where: { name.hasPrefix($0) }) ?? Int.max
    }

    private static func stem(of fileUrl: String) -> String {
        let last = fileUrl.split(separator: "/").last.map(String.init) ?? fileUrl
        let decoded = last.removingPercentEncoding ?? last
        let stem = decoded.split(separator: ".").dropLast().joined(separator: ".")
        return (stem.isEmpty ? decoded : stem).lowercased()
    }
}
