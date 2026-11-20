import CryptoKit
import Foundation
import VibraMusicCore

/// Turns an addon's DASH manifest into something AVFoundation plays.
///
/// PORTING §4: `AVPlayer` has no DASH. Two shapes cover what addons serve:
/// - **One file** (`SegmentBase`, or a representation with no segment information): the
///   representation's `BaseURL` is an ordinary progressive file and is played as one.
/// - **Segments** (`SegmentTemplate`, with or without a `SegmentTimeline`, or `SegmentList`): the
///   segments are fragmented MP4, which HLS accepts as-is since protocol version 7
///   (`EXT-X-MAP` names the initialization segment). So the conversion is a rewrite of the index,
///   not of the media: an HLS media playlist listing the same absolute segment URLs.
///
/// How the app serves it: the playlist is written to a file (``SourceManifestFiles``) and the
/// stream's URL becomes `vibramusic-hls://playlist/<name>.m3u8`, typed `application/x-mpegURL`. The
/// player opens that URL with ``SourcePlaylistLoader`` as the asset's resource-loader delegate,
/// which answers the playlist request from the file; AVFoundation then fetches the (absolute,
/// remote) init segment and media segments itself. A plain `file://` playlist is *not* an option:
/// measured on macOS 14+/Xcode 27, AVFoundation refuses a local media playlist whose segments are
/// remote (`-11800` / `-16913`) while playing the identical text served over HTTP — see
/// `DashPlaybackTests`. A download can't be one HLS file: concatenating `EXT-X-MAP` and every
/// segment in order yields a valid fragmented MP4 (``SourceManifestFiles/playlistText(for:)``
/// gives the Downloads module the list).
public enum DashToHLS {

    /// What a manifest becomes.
    public enum Conversion: Hashable, Sendable {
        /// One file, played progressively.
        case progressive(url: URL, track: DashAudioTrack)
        /// Segments, as an HLS media playlist.
        case playlist(text: String, track: DashAudioTrack)

        public var track: DashAudioTrack {
            switch self {
            case .progressive(_, let track), .playlist(_, let track): return track
            }
        }
    }

    /// Picks the audio representation to play and converts it.
    ///
    /// The highest-bandwidth representation wins, except that an E-AC-3 one is passed over on a
    /// device without the decoder (``DeviceCodecs``) or when the listener turned Atmos off — the
    /// same gate ``ModuleSource/unplayable(_:atmosAllowed:)`` applies to a whole stream.
    public static func convert(_ manifest: DashManifest, atmosAllowed: Bool) throws -> Conversion {
        guard !manifest.isDynamic else { throw DashManifestError.unsupported("a live (dynamic) presentation") }
        let playable = manifest.tracks.filter { atmosAllowed || !$0.isDolby }
        guard let track = playable.max(by: { rank($0) < rank($1) }) else {
            throw DashManifestError.unsupported("only an immersive mix this device may not play")
        }
        if let single = track.singleFileURL { return .progressive(url: single, track: track) }
        return .playlist(text: playlist(for: track), track: track)
    }

    /// Immersive first when allowed (it only survives the filter above when it is), then bandwidth.
    private static func rank(_ track: DashAudioTrack) -> (Int, Int) {
        (track.isDolby ? 1 : 0, track.bandwidth ?? 0)
    }

    /// An HLS (version 7) VOD media playlist for `track`'s segments.
    public static func playlist(for track: DashAudioTrack) -> String {
        let target = Int((track.segments.map(\.duration).max() ?? 1).rounded(.up))
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(max(target, 1))",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-INDEPENDENT-SEGMENTS",
        ]
        if let initialization = track.initialization {
            var map = "#EXT-X-MAP:URI=\"\(quoted(initialization.url))\""
            if let range = initialization.byteRange {
                map += ",BYTERANGE=\"\(range.upperBound - range.lowerBound + 1)@\(range.lowerBound)\""
            }
            lines.append(map)
        }
        for segment in track.segments {
            lines.append("#EXTINF:\(String(format: "%.3f", segment.duration)),")
            if let range = segment.byteRange {
                lines.append("#EXT-X-BYTERANGE:\(range.upperBound - range.lowerBound + 1)@\(range.lowerBound)")
            }
            lines.append(segment.url.absoluteString)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    /// A quoted-string attribute can't hold `"` or a line break; percent-encode them.
    private static func quoted(_ url: URL) -> String {
        url.absoluteString
            .replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\n", with: "%0A")
    }

    /// Fetches the MPD at `stream.url` and returns the stream AVPlayer can open instead: the single
    /// file, or a local HLS playlist. Nil when the manifest can't be read or converted, which the
    /// source reports as a miss so another source can be heard.
    static func playable(_ stream: ResolvedStream, environment: SourceEnvironment, atmosAllowed: Bool, label: String) async -> ResolvedStream? {
        let manifestURL = stream.url
        do {
            var request = URLRequest(url: manifestURL)
            request.timeoutInterval = AddonClient.callTimeout
            request.setValue("application/dash+xml, */*", forHTTPHeaderField: "Accept")
            for (name, value) in stream.headers { request.setValue(value, forHTTPHeaderField: name) }
            let (data, response) = try await environment.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            guard (200..<300).contains(status) else { throw AddonError.unavailable("HTTP \(status)") }
            let manifest = try DashManifest.parse(data, url: response.url ?? manifestURL)
            let conversion = try convert(manifest, atmosAllowed: atmosAllowed)
            var converted = stream
            let track = conversion.track
            // The representation states what the source's free text only hinted at.
            converted.format = refine(stream.format, with: track)
            switch conversion {
            case .progressive(let url, _):
                converted.url = url
                converted.mimeType = track.mimeType ?? "audio/mp4"
                SourcesLog.d("\(label): DASH is one file — playing it progressively")
            case .playlist(let text, _):
                converted.url = SourceManifestFiles.playlistURL(for: try environment.manifestFiles.write(text, for: manifestURL))
                converted.mimeType = AddonTransport.hls.mimeType
                SourcesLog.d("\(label): DASH → HLS, \(track.segments.count) segments of \(track.codecs ?? "?")")
            }
            return converted
        } catch {
            SourcesLog.w("\(label): could not play the DASH manifest — \(error.localizedDescription)")
            return nil
        }
    }

    /// What the chosen representation states, over what the source's answer guessed.
    static func refine(_ format: StreamFormat, with track: DashAudioTrack) -> StreamFormat {
        var refined = format
        if let codecs = track.codecs?.lowercased() {
            if codecs.hasPrefix("flac") || codecs.hasPrefix("fla") {
                refined.codec = "flac"
            } else if codecs.hasPrefix("alac") {
                refined.codec = "alac"
            } else if track.isDolby {
                refined.codec = "eac3-joc"
            } else if codecs.hasPrefix("mp4a") {
                refined.codec = "aac"
            }
        }
        if refined.sampleRateHz == nil { refined.sampleRateHz = track.sampleRate }
        if refined.kbps == nil, refined.isLossless != true, let bandwidth = track.bandwidth { refined.kbps = bandwidth / 1_000 }
        return refined
    }

    /// Whether a URL or declared type looks like a DASH manifest.
    static func looksLikeDash(url: String, mimeType: String?) -> Bool {
        if mimeType?.lowercased().contains("dash+xml") == true { return true }
        return url.before("?").before("#").lowercased().hasSuffix(".mpd")
    }
}

/// Where converted playlists are written, and the `vibramusic-hls://` URLs that name them.
///
/// One file per manifest URL (hashed), rewritten on every conversion because segment tokens expire
/// with the manifest. Files older than a day are swept on each write; a playlist lives as long as
/// the signed URLs inside it, which is hours at most.
public struct SourceManifestFiles: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `Caches/Vibra Music/SourceManifests`: re-derivable, never backed up.
    public static var standard: SourceManifestFiles {
        SourceManifestFiles(
            directory: URL.cachesDirectory
                .appending(path: "Vibra Music", directoryHint: .isDirectory)
                .appending(path: "SourceManifests", directoryHint: .isDirectory)
        )
    }

    /// Writes `playlist` for the manifest at `manifestURL` and returns the file's URL.
    public func write(_ playlist: String, for manifestURL: URL) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        sweep(olderThan: 24 * 60 * 60)
        let digest = SHA256.hash(data: Data(manifestURL.absoluteString.utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        let file = directory.appending(path: "\(digest).m3u8", directoryHint: .notDirectory)
        try Data(playlist.utf8).write(to: file, options: [.atomic])
        return file
    }

    /// The scheme ``SourcePlaylistLoader`` answers.
    public static let playlistScheme = "vibramusic-hls"

    /// `vibramusic-hls://playlist/<file name>` for a playlist file written here.
    public static func playlistURL(for file: URL) -> URL {
        URL(string: "\(playlistScheme)://playlist/\(file.lastPathComponent)")!
    }

    /// The file a `vibramusic-hls://` URL names, when it is one of this directory's.
    public func file(for playlistURL: URL) -> URL? {
        guard playlistURL.scheme == Self.playlistScheme else { return nil }
        let name = playlistURL.lastPathComponent
        guard name.hasSuffix(".m3u8"), !name.contains("/"), !name.hasPrefix(".") else { return nil }
        return directory.appending(path: name, directoryHint: .notDirectory)
    }

    /// The playlist text behind a `vibramusic-hls://` URL — what a downloader walks to fetch the
    /// init segment and media segments. Nil when the URL isn't one or the file has been swept.
    public func playlistText(for playlistURL: URL) -> String? {
        guard let file = file(for: playlistURL), let data = try? Data(contentsOf: file) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func sweep(olderThan age: TimeInterval) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? fileManager.removeItem(at: file) }
        }
    }
}
