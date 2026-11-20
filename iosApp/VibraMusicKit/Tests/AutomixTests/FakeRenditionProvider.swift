import Foundation
@testable import Automix

/// An in-memory playback cache: renditions per video id, and a record of what was asked of it.
final class FakeRenditionProvider: AutomixRenditionProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var byVideo: [String: [AutomixRendition]] = [:]
    private(set) var requestedHeads: [URL] = []
    private(set) var discarded: [String] = []
    var allowsDiscard = true

    func set(_ renditions: [AutomixRendition], for videoId: String) {
        lock.lock()
        byVideo[videoId] = renditions
        lock.unlock()
    }

    func renditions(of uri: URL) -> [AutomixRendition] {
        lock.lock()
        defer { lock.unlock() }
        return byVideo[uri.automixQueryParameter("v") ?? ""] ?? []
    }

    func cacheKey(of uri: URL) -> String { uri.automixQueryParameter("v") ?? uri.absoluteString }

    func requestAnalysisHead(for uri: URL) {
        lock.lock()
        requestedHeads.append(uri)
        lock.unlock()
    }

    func discardBadRendition(for uri: URL, key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        discarded.append(key)
        return allowsDiscard
    }

    /// A rendition backed by `file`, holding `fraction` of it.
    static func rendition(key: String, file: URL, cachedFraction: Double = 1) throws -> AutomixRendition {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        return AutomixRendition(key: key, contentLength: size, cachedPrefix: Int64(Double(size) * cachedFraction), fileURL: file)
    }
}

/// Resolves every source URI to one fixed YouTube id.
struct FixedCatalogMatcher: AutomixCatalogMatcher {
    var videoId: String?
    func youTubeVideoId(forSourceURI sourceURI: URL) async -> String? { videoId }
}
