import Foundation
import XCTest

/// A VOD HLS rendition of fMP4 AAC segments on an in-process HTTP server (AVFoundation fetches
/// with its own stack, so a `URLProtocol` stub can't stand in). Shared by the tests that need an
/// item whose asset has no asset-level audio track.
enum HLSFixture {
    /// Serves `seconds` of audio and returns the server (stop it when done) and the playlist URL.
    static func serve(seconds: Double, segmentSeconds: Double = 2) async throws -> (server: LocalHTTPServer, playlist: URL) {
        let (initialization, segments) = try await FragmentedAAC.make(seconds: seconds, segmentSeconds: segmentSeconds)
        XCTAssertGreaterThanOrEqual(segments.count, 2, "the HLS tests need a real multi-segment VOD rendition")
        let server = try LocalHTTPServer()
        try await server.start()
        server.serve("/hls/init.mp4", initialization, contentType: "audio/mp4")
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(Int((segments.map(\.duration).max() ?? 2).rounded(.up)))",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            #"#EXT-X-MAP:URI="init.mp4""#,
        ]
        for (index, segment) in segments.enumerated() {
            server.serve("/hls/seg-\(index).m4s", segment.data, contentType: "audio/mp4")
            lines.append(String(format: "#EXTINF:%.5f,", segment.duration))
            lines.append("seg-\(index).m4s")
        }
        lines.append("#EXT-X-ENDLIST")
        server.serve("/hls/index.m3u8", Data((lines.joined(separator: "\n") + "\n").utf8), contentType: "application/vnd.apple.mpegurl")
        return (server, server.baseURL.appending(path: "hls/index.m3u8"))
    }
}
