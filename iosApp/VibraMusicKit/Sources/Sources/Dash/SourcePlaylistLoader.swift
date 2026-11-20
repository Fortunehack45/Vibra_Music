import AVFoundation
import Foundation
import VibraMusicCore

/// Serves converted DASH playlists (`vibramusic-hls://playlist/…`) to AVFoundation.
///
/// AVFoundation hands any URL whose scheme it doesn't know to the asset's resource-loader delegate.
/// This one answers the playlist request from ``SourceManifestFiles``; everything the playlist
/// names (the `EXT-X-MAP` and the segments) is an absolute `https` URL AVFoundation fetches itself.
///
/// The Playback module wires it when it builds an asset for a stream whose URL has this scheme:
/// ```swift
/// let asset = AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": stream.headers])
/// if SourcePlaylistLoader.handles(stream.url) { SourcePlaylistLoader.shared.attach(to: asset) }
/// ```
public final class SourcePlaylistLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    public static let shared = SourcePlaylistLoader(files: .standard)

    private let files: SourceManifestFiles
    private let queue = DispatchQueue(label: "com.fortune.vibramusic.ios.SourcePlaylistLoader")

    public init(files: SourceManifestFiles) {
        self.files = files
    }

    /// Whether `url` is one of the converted playlists this loader serves.
    public static func handles(_ url: URL) -> Bool {
        url.scheme == SourceManifestFiles.playlistScheme
    }

    /// Makes this loader answer `asset`'s custom-scheme requests. The asset holds the delegate
    /// weakly; `shared` (or the caller) keeps it alive.
    public func attach(to asset: AVURLAsset) {
        asset.resourceLoader.setDelegate(self, queue: queue)
    }

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url, Self.handles(url) else { return false }
        guard let text = files.playlistText(for: url) else {
            SourcesLog.w("no converted playlist for \(url.lastPathComponent); it may have been swept")
            loadingRequest.finishLoading(with: URLError(.fileDoesNotExist))
            return true
        }
        let data = Data(text.utf8)
        if let information = loadingRequest.contentInformationRequest {
            information.contentType = "public.m3u-playlist"
            information.contentLength = Int64(data.count)
            information.isByteRangeAccessSupported = false
        }
        if let dataRequest = loadingRequest.dataRequest {
            let start = Int(max(0, dataRequest.currentOffset))
            if start < data.count {
                let end = dataRequest.requestsAllDataToEndOfResource
                    ? data.count
                    : min(data.count, start + dataRequest.requestedLength)
                dataRequest.respond(with: data.subdata(in: start..<end))
            }
        }
        loadingRequest.finishLoading()
        return true
    }
}
