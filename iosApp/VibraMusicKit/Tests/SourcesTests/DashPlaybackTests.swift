import AVFoundation
import XCTest
import VibraMusicCore
@testable import Sources

/// The claim the DASH conversion rests on, checked against AVFoundation itself: an HLS playlist
/// written by ``DashToHLS`` from a DASH SegmentTemplate, served through ``SourcePlaylistLoader``
/// under the `vibramusic-hls` scheme, whose `EXT-X-MAP` and segments are remote fragmented-MP4 URLs,
/// opens and plays for its full length. (The same playlist as a `file://` URL is refused by
/// AVFoundation — see ``testALocalFilePlaylistWithRemoteSegmentsIsRefusedByAVFoundation()``.)
///
/// The segments are real fMP4 made by `AVAssetWriter`'s HLS segment output (AAC, 2 s fragments),
/// served over HTTP by an in-process server — AVFoundation fetches with its own stack, which a
/// `URLProtocol` stub can't intercept.
final class DashPlaybackTests: XCTestCase {

    /// The fMP4 segments on a local HTTP server, the DASH an addon would hand over for them, and
    /// the playlist ``DashToHLS`` wrote from it.
    private struct Served {
        var server: LocalHTTPServer
        var text: String
        var files: SourceManifestFiles
        var playlist: URL
        var duration: Double
    }

    private func serveConvertedDash() async throws -> Served {
        let (initialization, segments) = try await Self.makeFragmentedAAC(seconds: 9, segmentSeconds: 2)
        XCTAssertGreaterThanOrEqual(segments.count, 4)

        let server = try LocalHTTPServer()
        try await server.start()
        server.serve("/track/init.mp4", initialization, contentType: "audio/mp4")
        for (index, segment) in segments.enumerated() {
            server.serve("/track/seg-\(index + 1).m4s", segment.data, contentType: "audio/mp4")
        }
        let timescale = 44_100
        let timeline = segments.map { #"<S d="\#(Int(($0.duration * Double(timescale)).rounded()))"/>"# }.joined()
        let mpd = """
        <?xml version="1.0"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT9S">
          <Period><AdaptationSet contentType="audio" mimeType="audio/mp4">
            <Representation id="aac" codecs="mp4a.40.2" bandwidth="128000" audioSamplingRate="44100">
              <SegmentTemplate timescale="\(timescale)" startNumber="1" initialization="init.mp4" media="seg-$Number$.m4s">
                <SegmentTimeline>\(timeline)</SegmentTimeline>
              </SegmentTemplate>
            </Representation>
          </AdaptationSet></Period>
        </MPD>
        """
        let manifestURL = server.baseURL.appending(path: "track/manifest.mpd")
        let parsed = try DashManifest.parse(Data(mpd.utf8), url: manifestURL)
        guard case .playlist(let text, _) = try DashToHLS.convert(parsed, atmosAllowed: false) else {
            throw DashManifestError.unsupported("expected a playlist")
        }
        let files = SourceManifestFiles(directory: try makeTemporaryDirectory())
        let playlist = try files.write(text, for: manifestURL)
        return Served(server: server, text: text, files: files, playlist: playlist, duration: segments.reduce(0) { $0 + $1.duration })
    }

    /// Why the loader exists: AVFoundation refuses the same playlist as a `file://` URL
    /// (`-11800`/`-16913`, measured on macOS 14+ with Xcode 27) while playing it over HTTP. Non-strict,
    /// so an OS that starts accepting it doesn't break the gate — it only means the loader could go.
    func testALocalFilePlaylistWithRemoteSegmentsIsRefusedByAVFoundation() async throws {
        let served = try await serveConvertedDash()
        defer { served.server.stop() }
        let refused: Bool
        do {
            refused = try await !AVURLAsset(url: served.playlist).load(.isPlayable)
        } catch {
            refused = true
        }
        XCTExpectFailure("AVFoundation now plays a local playlist over remote segments", options: .nonStrict())
        XCTAssertFalse(refused)
    }

    func testAConvertedDashTemplatePlaysThroughThePlaylistLoaderOverRemoteSegments() async throws {
        let served = try await serveConvertedDash()
        let (server, text, files, playlist) = (served.server, served.text, served.files, served.playlist)
        defer { server.stop() }

        let streamURL = SourceManifestFiles.playlistURL(for: playlist)
        XCTAssertEqual(streamURL.scheme, "vibramusic-hls")
        let loader = SourcePlaylistLoader(files: files)
        XCTAssertTrue(SourcePlaylistLoader.handles(streamURL))
        let asset = AVURLAsset(url: streamURL)
        loader.attach(to: asset)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable, "AVFoundation refused the playlist:\n\(text)")
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, served.duration, accuracy: 0.25)
        XCTAssertEqual(files.playlistText(for: streamURL), text)

        // And a player item gets to ready, having fetched the init segment and media over HTTP.
        // Wait on the two real conditions AVPlayer exposes — the item's status, then its clock
        // actually moving — rather than a fixed sleep, with a deadline generous enough to survive
        // a loaded machine. A stream that never becomes ready, or is ready but never advances,
        // still fails; the waits only shorten how long a failure takes to surface.
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.volume = 0
        let ready = await Self.wait(upTo: 20) { item.status != .unknown }
        XCTAssertTrue(ready, "player item was still .unknown after 20s: \(String(describing: item.error))")
        XCTAssertEqual(item.status, .readyToPlay, "item failed: \(String(describing: item.error))")
        player.play()
        let advanced = await Self.wait(upTo: 20) { player.currentTime().seconds > 0.5 }
        XCTAssertGreaterThan(player.currentTime().seconds, 0.5, "playback didn't advance within 20s (advanced=\(advanced))")
        player.pause()
        XCTAssertTrue(server.requestedPaths.contains("/track/init.mp4"), "\(server.requestedPaths)")
        XCTAssertTrue(server.requestedPaths.contains("/track/seg-1.m4s"), "\(server.requestedPaths)")
    }

    /// Polls `condition` every 50 ms until it holds or `timeout` seconds pass, then returns whether
    /// it held. Callers keep their own assertion, so a condition that never holds is a failure, not
    /// a silently skipped check. Polling (rather than KVO) keeps the wait self-contained; the
    /// generous deadline, not the sleep, is what absorbs a loaded machine.
    private static func wait(upTo timeout: TimeInterval, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    // MARK: fMP4 from AVAssetWriter

    private struct Segment {
        var data: Data
        var duration: Double
    }

    private final class SegmentCollector: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
        var initialization = Data()
        var segments: [Segment] = []
        func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType,
                         segmentReport: AVAssetSegmentReport?) {
            switch segmentType {
            case .initialization:
                initialization = segmentData
            case .separable:
                let duration = segmentReport?.trackReports.first?.duration.seconds ?? 0
                segments.append(Segment(data: segmentData, duration: duration))
            @unknown default:
                break
            }
        }
    }

    /// `seconds` of a 440 Hz tone as AAC in fragmented MP4, cut into ~`segmentSeconds` fragments.
    private static func makeFragmentedAAC(seconds: Double, segmentSeconds: Double) async throws -> (Data, [Segment]) {
        let sampleRate = 44_100.0
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: segmentSeconds, preferredTimescale: 1)
        writer.initialSegmentStartTime = .zero
        let collector = SegmentCollector()
        writer.delegate = collector
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? URLError(.cannotCreateFile) }
        writer.startSession(atSourceTime: .zero)

        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let totalFrames = Int(seconds * sampleRate)
        let chunk = 4_096
        var written = 0
        while written < totalFrames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            let frames = min(chunk, totalFrames - written)
            var samples = [Float](repeating: 0, count: frames * 2)
            for frame in 0..<frames {
                let value = Float(sin(2 * Double.pi * 440 * Double(written + frame) / sampleRate)) * 0.2
                samples[frame * 2] = value
                samples[frame * 2 + 1] = value
            }
            var block: CMBlockBuffer?
            let bytes = frames * 8
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                               customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
            samples.withUnsafeBytes { raw in
                _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes)
            }
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: frames,
                presentationTimeStamp: CMTime(value: CMTimeValue(written), timescale: CMTimeScale(sampleRate)),
                packetDescriptions: nil, sampleBufferOut: &sample
            )
            guard let sample, input.append(sample) else { throw writer.error ?? URLError(.cannotWriteToFile) }
            written += frames
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
        return (collector.initialization, collector.segments)
    }
}
