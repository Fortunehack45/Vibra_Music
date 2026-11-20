import Foundation

// Ports AudioCache.CacheMediaDataSource over a NoUpstream factory.

/// Random access to one entry's cached bytes that never fetches: for decoders that read a file
/// themselves (Automix's analyzer) rather than through AVFoundation.
///
/// A read that reaches a region that isn't cached ends there, like the end of a file, so a
/// partially cached rendition presents itself as a short file that stops where the cache does,
/// which is exactly what a head-only decode wants. ``size`` is still the real length, so a
/// container whose header describes the whole track parses normally.
public final class AudioCacheReader: Sendable {
    public let key: AudioCacheKey
    /// The rendition's full length, or -1 when it was never recorded.
    public let size: Int64
    private let store: AudioCacheStore

    init(key: AudioCacheKey, store: AudioCacheStore, size: Int64) {
        self.key = key
        self.store = store
        self.size = size
    }

    /// Up to `count` bytes from `position`, stopping early at a hole or the end. Empty means end
    /// of stream.
    public func read(at position: Int64, count: Int) async -> Data {
        guard count > 0, position >= 0 else { return Data() }
        var data = Data()
        var cursor = position
        let end = position + Int64(count)
        while cursor < end, let piece = await store.read(key, at: cursor, maxLength: end - cursor) {
            data.append(piece)
            cursor += Int64(piece.count)
        }
        return data
    }
}
