/*
 * Modeled on Orchard's own AudioDecoder (https://github.com/SFG5453/Orchard)
 * by way of Vibra Music's Android AudioDecoder, with AVAssetReader standing in
 * for the platform MediaCodec path.
 *
 * Copyright (C) 2026 Kushagra Singh
 *
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation, either version 3 of the License, or (at your
 * option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
 * Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AVFoundation
import VibraMusicCore
import Foundation
import os
import UniformTypeIdentifiers

/// Decodes a region of a track to float PCM, for ``TrackAnalyzer`` and ``VersionAudioAligner``.
///
/// Only a region: a transition only ever reads the tail of the outgoing track and the head of the
/// incoming one, and decoding a whole album's worth of audio to analyse thirty seconds of it would
/// cost battery for nothing.
///
/// A partially written file (a cached head still downloading) decodes up to within about a second
/// of where its bytes stop; see ``read(asset:track:start:end:sink:abort:)`` for why that takes a
/// second pass on iOS.
///
/// Everything here is best-effort. A container AVFoundation cannot parse (WebM/Opus among them —
/// the rendition provider should hand over an AAC/M4A, MP3, FLAC or ALAC copy), a region past the
/// end, a file that vanished — all return nil, and the caller falls back to no analysis, which the
/// transition policy already handles as its bottom rung.
///
/// Remote URLs work too: `AVAssetReader` refuses non-local assets, so a remote asset is fetched to
/// a temporary file first (see ``AutomixRemoteAudioFetcher``) and deleted after decoding.
public enum AutomixAudioDecoder {
    private static let logger = Logger(subsystem: "com.fortune.vibramusic.ios", category: "Automix")

    /// Where decode loops run. `copyNextSampleBuffer` decodes synchronously, so it belongs on a
    /// thread of its own rather than blocking Swift's cooperative pool for seconds at a time.
    private static let decodeQueue = DispatchQueue(
        label: "com.fortune.vibramusic.ios.automix.decode",
        qos: .utility,
        attributes: .concurrent
    )

    /// Decoded mono PCM. `startSeconds` is where the first sample really sits on the track's
    /// timeline, which can be slightly before what was asked for.
    public struct MonoPCM: Sendable, Equatable {
        public var samples: [Float]
        public var sampleRate: Double
        public var startSeconds: Double

        public var durationSeconds: Double { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }
    }

    /// Decoded planar stereo PCM. A mono source is widened by sharing the same samples on both
    /// sides, which is what the vocal model was trained to see for centre-panned material; more
    /// than two channels keep only the first two, because a downmix would put the centre channel —
    /// where the vocal usually is — into both sides at half level.
    public struct StereoPCM: Sendable, Equatable {
        public var left: [Float]
        public var right: [Float]
        public var sampleRate: Double
        public var startSeconds: Double

        public var durationSeconds: Double { sampleRate > 0 ? Double(left.count) / sampleRate : 0 }
    }

    /// The audio duration the container advertises, without decoding it. Queue metadata isn't
    /// always trustworthy, so this is the fallback when a track's own duration is missing.
    public static func containerDuration(
        of url: URL,
        fetcher: AutomixRemoteAudioFetcher = AutomixRemoteAudioFetcher()
    ) async -> Double? {
        await withLocalCopy(of: url, fetcher: fetcher) { local in
            let asset = AVURLAsset(url: local)
            do {
                guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { return nil }
                let seconds = try await asset.load(.duration).seconds
                return seconds.isFinite && seconds > 0 ? seconds : nil
            } catch {
                logger.debug("No readable duration in \(local.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    /// Decodes `start` to `end` seconds of `url`, downmixed to mono.
    ///
    /// With `sampleRate` nil the PCM comes back at the container's own rate. With a rate — the
    /// analyzer's 11,025 Hz is ``analysisSampleRate`` — it is converted with the analyzer's own
    /// windowed-sinc resampler rather than Core Audio's, so the numbers match Android's exactly.
    ///
    /// `abort` is polled once per decoded buffer; answering true abandons the decode as if it had
    /// failed. A whole-track decode is the longest single thing analysis does and holds tens of
    /// megabytes while it runs, so a caller that no longer wants the answer wants it stopped.
    public static func decodeMono(
        _ url: URL,
        from start: Double = 0,
        to end: Double = .infinity,
        sampleRate: Double? = nil,
        fetcher: AutomixRemoteAudioFetcher = AutomixRemoteAudioFetcher(),
        abort: @escaping @Sendable () -> Bool = { false }
    ) async -> MonoPCM? {
        let sink = MonoSink()
        guard let format = await decode(url, from: start, to: end, into: sink, fetcher: fetcher, abort: abort) else {
            return nil
        }
        var pcm = MonoPCM(samples: sink.samples, sampleRate: format.sampleRate, startSeconds: format.startSeconds)
        if let target = sampleRate, abs(target - format.sampleRate) > 1.0 {
            guard let converted = AutomixResampler.resample(pcm.samples, from: format.sampleRate, to: target) else {
                return nil
            }
            pcm = MonoPCM(samples: converted, sampleRate: target, startSeconds: format.startSeconds)
        }
        return pcm
    }

    /// As ``decodeMono(_:from:to:sampleRate:fetcher:abort:)`` at the container's rate, but keeping
    /// the two channels apart. Only the vocal front end needs this: open-unmix was trained on
    /// stereo, and a duplicated mono mix throws away the information it uses to tell a centred
    /// vocal from the instruments around it.
    public static func decodeStereo(
        _ url: URL,
        from start: Double = 0,
        to end: Double = .infinity,
        fetcher: AutomixRemoteAudioFetcher = AutomixRemoteAudioFetcher(),
        abort: @escaping @Sendable () -> Bool = { false }
    ) async -> StereoPCM? {
        let sink = StereoSink()
        guard let format = await decode(url, from: start, to: end, into: sink, fetcher: fetcher, abort: abort) else {
            return nil
        }
        return StereoPCM(left: sink.left, right: sink.right, sampleRate: format.sampleRate, startSeconds: format.startSeconds)
    }

    /// The analyzer's own rate, 11,025 Hz (see `audio_analysis.h`).
    public static var analysisSampleRate: Double { TrackFeatures.sampleRate }

    // MARK: - Decode loop

    /// What a decode learned about its output, once it has run.
    struct DecodedFormat {
        var sampleRate: Double
        var startSeconds: Double
    }

    /// Reduces each decoded buffer as it arrives, so a whole-track decode never holds the
    /// interleaved multichannel audio at once — only what the caller actually keeps.
    class PCMSink: @unchecked Sendable {
        func consume(_ interleaved: UnsafeBufferPointer<Float>, channels: Int) {}
        /// Frames consumed so far.
        var frames: Int { 0 }
        var isEmpty: Bool { frames == 0 }
        /// How many AVAssetReaders this decode has constructed for a range. Constructing one
        /// parses the container and re-resolves the track — the cost the recovery pass bounds —
        /// and nothing else exposes it; the recovery tests are its only reader. Written and read
        /// on the decode queue, one decode per sink.
        var readerStarts = 0
    }

    /// Downmixes to mono: the mean of every channel.
    final class MonoSink: PCMSink, @unchecked Sendable {
        var samples: [Float] = []

        override func consume(_ interleaved: UnsafeBufferPointer<Float>, channels: Int) {
            let frames = interleaved.count / channels
            for frame in 0..<frames {
                var sum: Float = 0
                let base = frame * channels
                for channel in 0..<channels { sum += interleaved[base + channel] }
                samples.append(sum / Float(channels))
            }
        }

        override var frames: Int { samples.count }
    }

    /// Keeps the first two channels apart; a mono source is duplicated onto both sides.
    final class StereoSink: PCMSink, @unchecked Sendable {
        var left: [Float] = []
        var right: [Float] = []

        override func consume(_ interleaved: UnsafeBufferPointer<Float>, channels: Int) {
            let frames = interleaved.count / channels
            for frame in 0..<frames {
                let base = frame * channels
                left.append(interleaved[base])
                right.append(channels > 1 ? interleaved[base + 1] : interleaved[base])
            }
        }

        override var frames: Int { left.count }
    }

    /// Whether AVAssetReader can open `url` in place. `ipod-library://` asset URLs from the media
    /// library count as local; they are not network resources.
    static func isReadableInPlace(_ url: URL) -> Bool {
        url.isFileURL || url.scheme?.lowercased() == "ipod-library"
    }

    private static func withLocalCopy<T>(
        of url: URL,
        fetcher: AutomixRemoteAudioFetcher,
        _ body: (URL) async -> T?
    ) async -> T? {
        if isReadableInPlace(url) { return await body(url) }
        let local: URL
        do {
            local = try await fetcher.localCopy(of: url)
        } catch {
            logger.debug("Could not fetch a remote asset for decoding: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        defer { try? FileManager.default.removeItem(at: local) }
        return await body(local)
    }

    /// Shared by the mono and stereo entry points so there is one read loop to get right rather
    /// than two that can drift apart; all that differs between them is the sink.
    static func decode(
        _ url: URL,
        from start: Double,
        to end: Double,
        into sink: PCMSink,
        fetcher: AutomixRemoteAudioFetcher = AutomixRemoteAudioFetcher(),
        abort: @escaping @Sendable () -> Bool
    ) async -> DecodedFormat? {
        if !(end > start) { return nil }
        return await withLocalCopy(of: url, fetcher: fetcher) { local in
            let asset = AVURLAsset(url: local)
            let track: AVAssetTrack
            do {
                guard let first = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
                track = first
            } catch {
                logger.debug("Could not open \(local.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
            let job = UncheckedSendable((asset, track, sink))
            return await withCheckedContinuation { continuation in
                decodeQueue.async {
                    let (asset, track, sink) = job.value
                    continuation.resume(returning: read(asset: asset, track: track, start: start, end: end, sink: sink, abort: abort))
                }
            }
        }
    }

    /// Length the recovery re-reads start at, and the ceiling they double up to. A range that
    /// decodes in full doubles the next one; one that stops partway drops back to the start.
    /// Reaching a cut `n` seconds past the first failed read costs O(log n) reader start-ups
    /// instead of one for every second of missing audio.
    static let recoveryInitialChunkSeconds = 1.0
    static let recoveryMaxChunkSeconds = 16.0

    /// A recovery re-read that adds less than this much audio is the decoder's last partial
    /// buffer at the cut, not audio worth opening another reader for. It matters: in the
    /// simulator AVAssetReader hands back a *single frame* per start right at the truncation, so
    /// without a floor the loop walks the last few milliseconds one reader at a time — measured,
    /// thousands of reader start-ups for one truncated file.
    static let recoveryMinAdvanceSeconds = 0.01

    /// Floor for ``recoveryReaderBudget(from:to:)``: the start-ups a recovery pass may use before
    /// its range is even counted. A file that stops partway once is reached in a dozen or so, so
    /// this is what bounds a file that is broken throughout and would otherwise fall back to the
    /// old one-reader-per-second walk (or worse). Best-effort, like everything else here.
    static let recoveryMaxReaders = 64

    /// The most reader start-ups one recovery pass may use for `start..<end`. The range term
    /// matters because chunks stop doubling at ``recoveryMaxChunkSeconds``: without it, a long
    /// range would need one reader per chunk and the floor would cut off its tail.
    ///
    /// It is a compromise, not a bound on the walk: a range that keeps stopping partway is reset
    /// to ``recoveryInitialChunkSeconds`` each time, so a file broken throughout can still exhaust
    /// the budget before the range does — it just fails slowly and loudly rather than silently.
    ///
    /// An infinite `end` — what ``decodeMono(_:from:to:sampleRate:fetcher:abort:)`` and
    /// ``decodeStereo(_:from:to:fetcher:abort:)`` default to — cannot be measured, so such a
    /// whole-track recovery gets the flat floor: it is capped at ``recoveryMaxReaders`` readers
    /// whatever the track's length. The bounded internal call sites scale with their range.
    static func recoveryReaderBudget(from start: Double, to end: Double) -> Int {
        guard end.isFinite else { return recoveryMaxReaders }
        let range = max(0, end - start)
        // A finite but absurd `end` — a corrupt duration — must only widen the budget, not trap.
        let chunks = range / recoveryMaxChunkSeconds
        return chunks < Double(Int.max - recoveryMaxReaders) ? recoveryMaxReaders + Int(chunks) : Int.max
    }

    /// What one recovery re-read returned, reduced to what the schedule needs.
    struct RecoveryRead: Equatable {
        /// The caller's `abort` answered true during the read.
        var aborted = false
        /// The reader decoded its whole range, so the next range may be longer.
        var finished = false
        /// Frames this range appended to the sink.
        var framesAdded = 0
        /// Where the audio this range delivered ends, on the track's timeline.
        var decodedEnd: Double?
    }

    /// Walks the re-read ranges for a read that failed partway, calling `read` one range at a time
    /// until a range adds no meaningful audio, the reader budget is reached, or the caller aborts.
    /// Returns whether the caller's `abort` ended it.
    ///
    /// Separate from ``read(asset:track:start:end:sink:abort:)`` so the schedule — the doubling,
    /// the drop-back, the stop — is one piece a test can drive without AVFoundation.
    @discardableResult
    static func recover(
        from start: Double,
        to end: Double,
        sampleRate: Double,
        read: (_ start: Double, _ end: Double) -> RecoveryRead
    ) -> Bool {
        guard sampleRate > 0 else { return false }
        let budget = recoveryReaderBudget(from: start, to: end)
        var cursor = start
        var chunk = recoveryInitialChunkSeconds
        var readers = 0
        while cursor < end - recoveryMinAdvanceSeconds, readers < budget {
            readers += 1
            let result = read(cursor, min(end, cursor + chunk))
            if result.aborted { return true }
            let advance = Double(result.framesAdded) / sampleRate
            // `decodedEnd` is where the sink actually got to. The next range must not start past
            // it or audio in between would be skipped; only fall back to what the frames implied
            // when the reader gave no timeline at all.
            let reached = result.decodedEnd ?? (cursor + advance)
            if advance < recoveryMinAdvanceSeconds {
                // Nothing, or only the cut's own fragment, came back. A longer range can trip the
                // truncation before the decoder reaches bytes that are there, so retry once from
                // where the audio actually got to, with the shortest range. It must not retry
                // from the stale cursor: the fragment is already in the sink and would be decoded
                // twice.
                guard chunk > recoveryInitialChunkSeconds else { return false }
                cursor = max(reached, cursor)
                chunk = recoveryInitialChunkSeconds
                continue
            }
            // The cursor must pass where it was, or the loop re-reads the same place forever; it
            // never needed to start past `reached`, so stopping is the honest outcome when a
            // reader only ever hands back audio behind its own seek.
            guard reached > cursor else { return false }
            cursor = reached
            chunk = result.finished
                ? min(chunk * 2, recoveryMaxChunkSeconds)
                : recoveryInitialChunkSeconds
        }
        if readers >= budget, cursor < end - recoveryMinAdvanceSeconds {
            logger.debug("Recovery stopped at its \(budget, privacy: .public)-reader budget")
        }
        return false
    }

    /// Reads `start..<end` into `sink`, recovering the tail of a file that stops partway.
    ///
    /// AVAssetReader decodes ahead in batches, and when it runs into the end of a partially
    /// written file it fails the whole batch in flight — measured, up to ten seconds of audio that
    /// *is* on disk never reaches the caller. MediaExtractor on Android hands back everything up
    /// to the missing byte, and the head pass is sized around that: it wants twelve seconds of a
    /// cached opening, not twenty-two. So when a read fails, ``recover(from:to:sampleRate:read:)``
    /// re-reads the rest from where the audio stopped, in ranges that double until one stops
    /// partway and then shrink back. It ends when a range adds no meaningful audio, when it hits
    /// its reader budget (``recoveryReaderBudget(from:to:)``), or when the caller aborts — every
    /// reader start-up re-parses the container and re-seeks, so the number of them has to stay
    /// small.
    private static func read(
        asset: AVAsset,
        track: AVAssetTrack,
        start: Double,
        end: Double,
        sink: PCMSink,
        abort: () -> Bool
    ) -> DecodedFormat? {
        var state = ReadState()
        let outcome = readRange(asset: asset, track: track, start: start, end: end, sink: sink, state: &state, abort: abort)
        if outcome == .failed {
            let aborted = Self.recover(from: state.decodedEnd ?? max(0, start), to: end, sampleRate: state.sampleRate) { rangeStart, rangeEnd in
                let before = sink.frames
                let result = readRange(asset: asset, track: track, start: rangeStart, end: rangeEnd, sink: sink, state: &state, abort: abort)
                return RecoveryRead(
                    aborted: result == .aborted,
                    finished: result == .finished,
                    framesAdded: sink.frames - before,
                    decodedEnd: state.decodedEnd
                )
            }
            if aborted { return nil }
        }
        if outcome == .aborted { return nil }
        guard !sink.isEmpty, state.sampleRate > 0, let actualStart = state.actualStart else { return nil }
        return DecodedFormat(sampleRate: state.sampleRate, startSeconds: actualStart)
    }

    /// What the reads of one decode have learned so far.
    private struct ReadState {
        var channels = 0
        var sampleRate = 0.0
        /// Where the first sample of the whole decode sits on the track's timeline.
        var actualStart: Double?
        /// Where the audio handed to the sink so far ends, on the track's timeline.
        var decodedEnd: Double?
    }

    private enum RangeOutcome { case finished, failed, aborted, unopened }

    /// Frames at the front of a decoded buffer that the sink already holds, because the reader
    /// primed before its seek point or a coarse seek landed early. Dropping them keeps the sink a
    /// single gapless timeline and keeps a recovery range — which starts where the sink's audio
    /// ended — from decoding those frames a second time.
    static func leadingOverlapFrames(
        presentation: Double,
        decodedEnd: Double?,
        sampleRate: Double,
        frames: Int
    ) -> Int {
        guard presentation.isFinite, let decodedEnd, presentation < decodedEnd, sampleRate > 0 else { return 0 }
        // Compare before converting: a corrupt container can make the product overflow to +∞, and
        // `Int(_: Double)` traps on anything outside its range.
        let overlap = (decodedEnd - presentation) * sampleRate
        if overlap >= Double(frames) { return frames }
        return overlap > 0 ? Int(overlap.rounded()) : 0
    }

    private static func readRange(
        asset: AVAsset,
        track: AVAssetTrack,
        start: Double,
        end: Double,
        sink: PCMSink,
        state: inout ReadState,
        abort: () -> Bool
    ) -> RangeOutcome {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            logger.debug("No reader: \(error.localizedDescription, privacy: .public)")
            return .unopened
        }
        // Counted once the reader exists, before it can fail to open: constructing it parses the
        // container and re-resolves the track, which is the cost the recovery bound is about.
        sink.readerStarts += 1
        let startTime = CMTime(seconds: max(0, start), preferredTimescale: 1_000_000)
        let duration = end.isFinite
            ? CMTime(seconds: end - max(0, start), preferredTimescale: 1_000_000)
            : CMTime.positiveInfinity
        reader.timeRange = CMTimeRange(start: startTime, duration: duration)

        // Float32 interleaved at the track's own rate and channel count: the sink decides how to
        // reduce channels, and resampling is done by the analyzer's filter, not here.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return .unopened }
        reader.add(output)
        guard reader.startReading() else {
            logger.debug("Reader would not start: \(reader.error?.localizedDescription ?? "unknown", privacy: .public)")
            return .unopened
        }

        var scratch: [Float] = []
        while true {
            // Polled per buffer: everything decoded so far goes with the abort, and on a long
            // track that is most of what the analysis costs in both time and memory.
            if abort() {
                reader.cancelReading()
                return .aborted
            }
            guard let buffer = output.copyNextSampleBuffer() else { break }
            if let format = CMSampleBufferGetFormatDescription(buffer),
               let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                if state.channels == 0 {
                    state.channels = Int(description.mChannelsPerFrame)
                    state.sampleRate = description.mSampleRate
                } else if Int(description.mChannelsPerFrame) != state.channels {
                    // A mid-stream layout change would scramble the interleave; stop here.
                    break
                }
            }
            let channels = state.channels
            if channels <= 0 { continue }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let floats = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.stride
            let usable = floats - floats % channels
            if usable == 0 { continue }
            if scratch.count < floats { scratch = [Float](repeating: 0, count: floats) }
            let status = scratch.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(
                    block,
                    atOffset: 0,
                    dataLength: usable * MemoryLayout<Float>.stride,
                    destination: bytes.baseAddress!
                )
            }
            if status != kCMBlockBufferNoErr { continue }
            let presentation = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            if state.actualStart == nil {
                state.actualStart = presentation.isFinite ? presentation : max(0, start)
            }
            // A re-read can hand back audio already in the sink: the decoder primes before the
            // seek point and a coarse seek lands early. Drop the overlap so the sink stays one
            // gapless timeline and the next range — which starts at `decodedEnd` — does not decode
            // those frames a second time.
            let frames = usable / channels
            let leading = leadingOverlapFrames(
                presentation: presentation,
                decodedEnd: state.decodedEnd,
                sampleRate: state.sampleRate,
                frames: frames
            )
            let kept = usable - leading * channels
            if kept > 0 {
                scratch.withUnsafeBufferPointer { pointer in
                    sink.consume(UnsafeBufferPointer(rebasing: pointer[(leading * channels)..<usable]), channels: channels)
                }
            }
            if presentation.isFinite {
                // `max` because a buffer wholly behind the seek point leaves `decodedEnd` where it
                // was rather than moving it back.
                let end = presentation + Double(frames) / state.sampleRate
                state.decodedEnd = max(state.decodedEnd ?? end, end)
            } else if let decodedEnd = state.decodedEnd {
                state.decodedEnd = decodedEnd + Double(frames) / state.sampleRate
            }
        }

        if reader.status == .failed {
            // A file that stops partway — a cached head, a truncated download — fails the reader
            // near the first missing byte. What decoded before that is still the track's audio;
            // the whole-track pass has its own short-decode guard against mistaking it for the
            // complete track.
            logger.debug("Reader stopped early: \(reader.error?.localizedDescription ?? "unknown", privacy: .public)")
            return .failed
        }
        return .finished
    }
}

/// Carries a value the compiler cannot prove Sendable across a queue hop whose ownership is
/// already exclusive: the decode loop is the only thing touching the reader, track and sink.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Fetches a remote audio asset to a temporary file so AVAssetReader, which refuses non-local
/// URLs, can decode it.
///
/// Networking goes through the injected `URLSession`, so tests can stub it. `maxBytes` bounds the
/// download to the opening of the file — enough for a head region of any container that keeps its
/// index up front (MP3, ADTS, fast-start M4A, YouTube's fragmented M4A).
///
/// A resolved YouTube stream needs two things from its caller that this module cannot know:
/// `headers`, the resolver's `mediaHeaders`, which have to go out on every media request or the
/// server refuses or truncates the response; and `patchHead`, which the app wires to
/// StreamResolution's `YouTubeMP4InitSegment.patchDurations(in:)`, because AVFoundation reports
/// YouTube's fragmented AAC at twice its real length unless the `moov` durations are zeroed. The
/// patch is applied to the opening of the downloaded copy before anything reads it.
public struct AutomixRemoteAudioFetcher: Sendable {
    /// How much of the opening ``patchHead`` is handed: a fragmented `moov` is well under this.
    public static let patchWindowBytes = 1_024 * 1_024

    public var session: URLSession
    public var directory: URL
    public var maxBytes: Int64?
    public var headers: [String: String]
    public var patchHead: (@Sendable (inout Data) -> Void)?

    public init(
        session: URLSession = VibraMusicHTTP.session,
        directory: URL = FileManager.default.temporaryDirectory,
        maxBytes: Int64? = nil,
        headers: [String: String] = [:],
        patchHead: (@Sendable (inout Data) -> Void)? = nil
    ) {
        self.session = session
        self.directory = directory
        self.maxBytes = maxBytes
        self.headers = headers
        self.patchHead = patchHead
    }

    public enum FetchError: Error, Equatable {
        case httpStatus(Int)
        case empty
    }

    /// Downloads `url` (or its first ``maxBytes``) and returns the local file. The caller deletes it.
    public func localCopy(of url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let maxBytes, maxBytes > 0 {
            request.setValue("bytes=0-\(maxBytes - 1)", forHTTPHeaderField: "Range")
        }
        let (downloaded, response) = try await session.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: downloaded)
            throw FetchError.httpStatus(http.statusCode)
        }
        // AVFoundation picks a parser from the extension, so the copy keeps the remote one, or
        // takes one from the response's MIME type when the URL has none (googlevideo's
        // `/videoplayback` has none).
        var fileExtension = url.pathExtension
        if fileExtension.isEmpty, let mime = response.mimeType,
           let type = UTType(mimeType: mime), let preferred = type.preferredFilenameExtension {
            fileExtension = preferred
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var destination = directory.appendingPathComponent("automix-\(UUID().uuidString)")
        if !fileExtension.isEmpty { destination.appendPathExtension(fileExtension) }
        try FileManager.default.moveItem(at: downloaded, to: destination)
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        if size <= 0 {
            try? FileManager.default.removeItem(at: destination)
            throw FetchError.empty
        }
        if let patchHead {
            do {
                try Self.patchOpening(of: destination, with: patchHead)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }
        return destination
    }

    /// Hands the opening of `file` to `patch` and writes it back in place when it changed. The
    /// patch only rewrites header fields, so the length never changes.
    static func patchOpening(of file: URL, with patch: (inout Data) -> Void) throws {
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        let original = try handle.read(upToCount: patchWindowBytes) ?? Data()
        var patched = original
        patch(&patched)
        guard patched != original, patched.count == original.count else { return }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: patched)
    }
}
