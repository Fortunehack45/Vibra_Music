/*
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

import VibraMusicCore
import Foundation
import os

/// One version of a recording the aligner can measure: a song or its music video. Maps from
/// Core's `Song` (videoId, title, localUri).
public struct VersionAlignmentTrack: Sendable, Equatable {
    public var videoId: String
    public var title: String
    /// A file on the device (`Song.localUri`), read in place when present.
    public var localURL: URL?
    /// A directly fetchable audio URL, used only when neither a local file nor a cached rendition
    /// is available: its opening is downloaded to a temporary file and measured from there.
    public var remoteAudioURL: URL?
    /// Headers every request for ``remoteAudioURL`` must carry: a resolved YouTube stream's
    /// `mediaHeaders`.
    public var remoteAudioHeaders: [String: String]

    public init(
        videoId: String,
        title: String = "",
        localURL: URL? = nil,
        remoteAudioURL: URL? = nil,
        remoteAudioHeaders: [String: String] = [:]
    ) {
        self.videoId = videoId
        self.title = title
        self.localURL = localURL
        self.remoteAudioURL = remoteAudioURL
        self.remoteAudioHeaders = remoteAudioHeaders
    }
}

/// Finds the time offset between two versions of the same track — a music video with an intro
/// skit and the studio release, say — from their audio energy envelopes, so switching between them
/// carries on from about the same spot: `target position = source position + offset`.
///
/// Feature "Switch between song and music video". Offsets are cached per pair (both directions),
/// so a second switch is instantaneous. ``status`` walks fetching → measuring → aligned/failed so
/// stats for nerds can say which happened and what the shift came out as.
public final class VersionAudioAligner: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.fortune.vibramusic.ios", category: "Automix")

    /// Envelope hop: 100 frames per second.
    public static let hopMs = 10.0
    static let windowMs = 40.0
    /// Search up to ±40 s of drift or intro.
    public static let maxLagSeconds = 40.0
    /// Minimum normalized correlation to believe.
    static let minConfidence = 0.40
    /// How much of each version's opening is decoded.
    static let regionSeconds = 45.0
    /// The largest same-source opening is preferred once it holds at least this much; below it,
    /// any copy with more bytes wins (Android's `AudioCache.MIN_ALIGNMENT_PREFIX_BYTES`).
    public static let minAlignmentPrefixBytes: Int64 = 800 * 1024
    /// How much of a remote asset to fetch: comfortably more than ``regionSeconds`` at 256 kbps.
    static let remoteFetchBytes: Int64 = 2 * 1024 * 1024

    /// How far a switch to the other cut has got.
    public enum CutPhase: String, Sendable, Equatable {
        case fetching, measuring, aligned, failed
    }

    /// What the switch to the other cut currently knows: that the other version has been fetched,
    /// that it has been measured, and what shift the transition is going to apply. Kept after the
    /// swap lands, scoped to the pair, so the UI can ignore a record naming another track.
    public struct AlignmentStatus: Sendable, Equatable {
        /// The cut playing when the switch started.
        public var sourceId: String
        /// The cut being switched to.
        public var targetId: String
        public var phase: CutPhase
        /// The shift that will be — or was — applied, once it is known.
        public var offsetMs: Int64?
        /// True when the figure came out of the cache instead of a fresh pass.
        public var fromCache: Bool

        public init(sourceId: String, targetId: String, phase: CutPhase, offsetMs: Int64? = nil, fromCache: Bool = false) {
            self.sourceId = sourceId
            self.targetId = targetId
            self.phase = phase
            self.offsetMs = offsetMs
            self.fromCache = fromCache
        }
    }

    /// A peak found by ``crossCorrelate(_:_:hopMs:maxLagSeconds:)``, with the lag range it was
    /// found in. The range is carried out because it is the only way to tell a measured lag from a
    /// lag the window was too small to move past.
    public struct Correlation: Sendable, Equatable {
        public var lagFrames: Int
        public var confidence: Double
        public var floor: Int
        public var ceiling: Int

        public init(lagFrames: Int, confidence: Double, floor: Int, ceiling: Int) {
            self.lagFrames = lagFrames
            self.confidence = confidence
            self.floor = floor
            self.ceiling = ceiling
        }
    }

    /// The app-wide instance. Wire ``renditions`` once Playback's cache exists.
    public static let shared = VersionAudioAligner()

    private let lock = NSLock()
    private var offsetCache: [String: Int64] = [:]
    private var currentStatus: AlignmentStatus?
    private var observers: [UUID: AsyncStream<AlignmentStatus?>.Continuation] = [:]
    private var attempt: Int64 = 0
    private var renditionProvider: AutomixRenditionProvider?
    private let session: URLSession
    private let remoteHeadPatch: (@Sendable (inout Data) -> Void)?

    /// - Parameters:
    ///   - remoteHeadPatch: applied to the opening of a fetched remote copy before it is decoded;
    ///     the app passes StreamResolution's `YouTubeMP4InitSegment.patchDurations(in:)`. See
    ///     ``AutomixRemoteAudioFetcher``.
    public init(
        renditions: AutomixRenditionProvider? = nil,
        session: URLSession = VibraMusicHTTP.session,
        remoteHeadPatch: (@Sendable (inout Data) -> Void)? = nil
    ) {
        self.renditionProvider = renditions
        self.session = session
        self.remoteHeadPatch = remoteHeadPatch
    }

    private func fetcher(headers: [String: String] = [:]) -> AutomixRemoteAudioFetcher {
        AutomixRemoteAudioFetcher(session: session, maxBytes: Self.remoteFetchBytes, headers: headers, patchHead: remoteHeadPatch)
    }

    /// The playback cache the aligner reads openings from.
    public var renditions: AutomixRenditionProvider? {
        get { withLock { renditionProvider } }
        set { withLock { renditionProvider = newValue } }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private static func cacheKey(_ source: String, _ target: String) -> String { "\(source)\u{1F}\(target)" }

    // MARK: - Status

    /// The latest status, or nil before any switch.
    public var status: AlignmentStatus? { withLock { currentStatus } }

    /// The current status and every change after it, for a view's `.task { for await ... }`.
    public func statusUpdates() -> AsyncStream<AlignmentStatus?> {
        AsyncStream { continuation in
            let id = UUID()
            let current = withLock { () -> AlignmentStatus? in
                observers[id] = continuation
                return currentStatus
            }
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                _ = self.withLock { self.observers.removeValue(forKey: id) }
            }
        }
    }

    private func publish(_ status: AlignmentStatus?) {
        let targets = withLock { () -> [AsyncStream<AlignmentStatus?>.Continuation] in
            currentStatus = status
            return Array(observers.values)
        }
        for observer in targets { observer.yield(status) }
    }

    /// Opens a switch's status at fetching and returns the token later phases must present.
    ///
    /// A switch is only cancelled at its next suspension point, so the pass that already lost can
    /// still publish; the token is what stops it describing the replacement's switch.
    public func beginAttempt(sourceId: String, targetId: String) -> Int64 {
        let token = withLock { () -> Int64 in
            attempt += 1
            return attempt
        }
        publish(AlignmentStatus(sourceId: sourceId, targetId: targetId, phase: .fetching))
        return token
    }

    /// Moves the attempt named by `token` on to `phase`; does nothing if a later attempt has
    /// taken over since. Non-suspending, so a cancelled task can still record its outcome.
    public func publishPhase(_ token: Int64, phase: CutPhase, offsetMs: Int64? = nil, fromCache: Bool = false) {
        let next = withLock { () -> AlignmentStatus? in
            guard attempt == token, var status = currentStatus else { return nil }
            status.phase = phase
            status.offsetMs = offsetMs
            status.fromCache = fromCache
            return status
        }
        if let next { publish(next) }
    }

    // MARK: - Offsets

    /// The cached offset in milliseconds, 0 for the same id, or nil if never measured.
    public func cachedOffsetMs(sourceVideoId: String, targetVideoId: String) -> Int64? {
        if sourceVideoId == targetVideoId { return 0 }
        return withLock { offsetCache[Self.cacheKey(sourceVideoId, targetVideoId)] }
    }

    /// Where to start `target` so it carries on from `sourcePositionMs` of the source version.
    public static func targetPositionMs(sourcePositionMs: Int64, offsetMs: Int64) -> Int64 {
        max(0, sourcePositionMs + offsetMs)
    }

    /// Measures (or recalls) the offset from `source` to `target`, in milliseconds:
    /// `target timestamp = source timestamp + offset`.
    ///
    /// **Nil means it could not be measured** — no audio to read, a container that would not
    /// decode, a correlation too weak to believe, a peak pinned to the searchable edge. Callers must
    /// not fold that into 0, which is a real answer meaning both cuts open on the same second.
    public func findOffsetMs(source: VersionAlignmentTrack, target: VersionAlignmentTrack) async -> Int64? {
        if source.videoId == target.videoId { return 0 }
        if let cached = cachedOffsetMs(sourceVideoId: source.videoId, targetVideoId: target.videoId) { return cached }
        guard let sourceURL = audioURL(for: source), let targetURL = audioURL(for: target) else {
            Self.logger.warning("Alignment for '\(source.title, privacy: .public)': no audio to measure against")
            return nil
        }
        // Headers belong to the remote copy only; a cached or local file ignores them.
        return await measure(
            sourceURL: sourceURL,
            targetURL: targetURL,
            sourceFetcher: fetcher(headers: sourceURL == source.remoteAudioURL ? source.remoteAudioHeaders : [:]),
            targetFetcher: fetcher(headers: targetURL == target.remoteAudioURL ? target.remoteAudioHeaders : [:]),
            sourceId: source.videoId,
            targetId: target.videoId,
            label: source.title
        )
    }

    /// The measurement itself, over two audio URLs (local files, or remote assets whose openings
    /// are fetched first). Caches the result under the two ids on success.
    public func findOffsetMs(sourceURL: URL, targetURL: URL, sourceId: String, targetId: String, label: String = "") async -> Int64? {
        if sourceId == targetId { return 0 }
        return await measure(
            sourceURL: sourceURL,
            targetURL: targetURL,
            sourceFetcher: fetcher(),
            targetFetcher: fetcher(),
            sourceId: sourceId,
            targetId: targetId,
            label: label
        )
    }

    private func measure(
        sourceURL: URL,
        targetURL: URL,
        sourceFetcher: AutomixRemoteAudioFetcher,
        targetFetcher: AutomixRemoteAudioFetcher,
        sourceId: String,
        targetId: String,
        label: String
    ) async -> Int64? {
        // Both decodes at once rather than one after the other: the measurement runs against the
        // switch's deadline, and a result landing past it is discarded as if it never happened.
        let started = Date()
        async let sourceDecode = AutomixLocalAudioSource.withAccess(to: sourceURL) {
            await AutomixAudioDecoder.decodeMono(sourceURL, from: 0, to: Self.regionSeconds, fetcher: sourceFetcher)
        }
        async let targetDecode = AutomixLocalAudioSource.withAccess(to: targetURL) {
            await AutomixAudioDecoder.decodeMono(targetURL, from: 0, to: Self.regionSeconds, fetcher: targetFetcher)
        }
        guard let sourcePCM = await sourceDecode, let targetPCM = await targetDecode,
              !sourcePCM.samples.isEmpty, !targetPCM.samples.isEmpty else { return nil }
        let decodeMs = Int(Date().timeIntervalSince(started) * 1000)

        let correlation = await Task.detached(priority: .userInitiated) {
            Self.crossCorrelate(
                Self.energyEnvelope(sourcePCM.samples, sampleRate: sourcePCM.sampleRate),
                Self.energyEnvelope(targetPCM.samples, sampleRate: targetPCM.sampleRate)
            )
        }.value
        Self.logger.debug("Alignment for '\(label, privacy: .public)': decode=\(decodeMs)ms lagFrames=\(correlation.lagFrames) conf=\(correlation.confidence) range=\(correlation.floor)..\(correlation.ceiling)")

        guard let lagFrames = Self.acceptedLag(correlation) else {
            Self.logger.warning("Alignment for '\(label, privacy: .public)': no believable peak (conf \(correlation.confidence), lag \(correlation.lagFrames) of \(correlation.floor)..\(correlation.ceiling)) — no shift measured")
            return nil
        }

        let lagMs = Int64(Double(lagFrames) * Self.hopMs)
        let startDifferenceMs = Int64((targetPCM.startSeconds - sourcePCM.startSeconds) * 1000)
        let offset = lagMs + startDifferenceMs
        withLock {
            offsetCache[Self.cacheKey(sourceId, targetId)] = offset
            offsetCache[Self.cacheKey(targetId, sourceId)] = -offset
        }
        return offset
    }

    /// The copy of `track` worth measuring: its local file (when it can still be read, since a
    /// stale `Song.localUri` must not shut out a cached or remote copy), else the largest
    /// same-source opening in the cache (a substitute `#alt` only when nothing else is there), else its remote audio.
    ///
    /// Ordered by bytes because neither URI names a particular copy, and a stub a second long can
    /// only correlate to garbage.
    func audioURL(for track: VersionAlignmentTrack) -> URL? {
        if let local = track.localURL, AutomixLocalAudioSource.isReadable(local) { return local }
        if let provider = renditions,
           let watch = URL(string: "vibramusic://watch?v=\(track.videoId)") {
            let onDisk = provider.renditions(of: watch)
            let sameSource = onDisk.filter { !$0.key.hasSuffix("#alt") }.max { $0.cachedPrefix < $1.cachedPrefix }
            let pick = sameSource.flatMap { $0.cachedPrefix >= Self.minAlignmentPrefixBytes ? $0 : nil }
                ?? onDisk.max { $0.cachedPrefix < $1.cachedPrefix }
            if let pick { return pick.fileURL }
        }
        return track.remoteAudioURL
    }

    /// The lag a correlation measured, or nil when it measured nothing believable: a confidence
    /// under ``minConfidence``, or a peak sitting on the edge of the searchable range. The second
    /// is what a truncated head looks like from here — the true lag is further out than the bytes
    /// reach, and the best the window can do is pin itself to its limit and report that.
    static func acceptedLag(_ correlation: Correlation) -> Int? {
        guard correlation.confidence >= minConfidence else { return nil }
        if correlation.lagFrames == correlation.floor || correlation.lagFrames == correlation.ceiling { return nil }
        return correlation.lagFrames
    }

    // MARK: - Signal

    /// RMS energy over sliding windows (40 ms every 10 ms).
    static func energyEnvelope(
        _ samples: [Float],
        sampleRate: Double,
        hopMs: Double = VersionAudioAligner.hopMs,
        windowMs: Double = VersionAudioAligner.windowMs
    ) -> [Float] {
        let hop = max(1, Int(sampleRate * (hopMs / 1000)))
        let window = max(hop, Int(sampleRate * (windowMs / 1000)))
        let frames = max(0, (samples.count - window) / hop)
        if frames <= 0 { return [] }
        var envelope = [Float](repeating: 0, count: frames)
        samples.withUnsafeBufferPointer { source in
            for frame in 0..<frames {
                let start = frame * hop
                let end = min(source.count, start + window)
                var sumSquares = 0.0
                for index in start..<end {
                    let value = Double(source[index])
                    sumSquares += value * value
                }
                envelope[frame] = Float((sumSquares / Double(end - start)).squareRoot())
            }
        }
        return envelope
    }

    /// Normalized cross-correlation between the source and target envelopes. Positive lag means
    /// the target's events happen later (target = source + lag).
    ///
    /// Per-lag means and variances come from prefix sums and the cross terms from one FFT pass, so
    /// the cost is two O(n log n) transforms and a linear scan rather than ~70M multiply-adds per
    /// pair of 45 s windows. The numbers are the brute-force loop's exactly (see the tests).
    public static func crossCorrelate(
        _ sourceEnvelope: [Float],
        _ targetEnvelope: [Float],
        hopMs: Double = VersionAudioAligner.hopMs,
        maxLagSeconds: Double = VersionAudioAligner.maxLagSeconds
    ) -> Correlation {
        if sourceEnvelope.isEmpty || targetEnvelope.isEmpty {
            return Correlation(lagFrames: 0, confidence: 0, floor: 0, ceiling: 0)
        }
        let maxLagFrames = Int(maxLagSeconds * 1000 / hopMs)
        let minOverlapFrames = Int(3.0 * 1000 / hopMs) // at least 3 seconds of overlap

        var bestLag = 0
        var bestCorrelation = -1.0

        // lag d means target[i + d] corresponds to source[i]
        let minLag = max(-maxLagFrames, -(sourceEnvelope.count - minOverlapFrames))
        let maxLag = min(maxLagFrames, targetEnvelope.count - minOverlapFrames)

        let crossTerms = crossTermsByLag(sourceEnvelope, targetEnvelope)

        var sourcePrefix = [Double](repeating: 0, count: sourceEnvelope.count + 1)
        var sourceSquarePrefix = [Double](repeating: 0, count: sourceEnvelope.count + 1)
        for index in sourceEnvelope.indices {
            let value = Double(sourceEnvelope[index])
            sourcePrefix[index + 1] = sourcePrefix[index] + value
            sourceSquarePrefix[index + 1] = sourceSquarePrefix[index] + value * value
        }
        var targetPrefix = [Double](repeating: 0, count: targetEnvelope.count + 1)
        var targetSquarePrefix = [Double](repeating: 0, count: targetEnvelope.count + 1)
        for index in targetEnvelope.indices {
            let value = Double(targetEnvelope[index])
            targetPrefix[index + 1] = targetPrefix[index] + value
            targetSquarePrefix[index + 1] = targetSquarePrefix[index] + value * value
        }

        if minLag <= maxLag {
            for lag in minLag...maxLag {
                let sourceStart = max(0, -lag)
                let targetStart = max(0, lag)
                let overlap = min(sourceEnvelope.count - sourceStart, targetEnvelope.count - targetStart)
                if overlap < minOverlapFrames { continue }
                let n = Double(overlap)

                let sumSource = sourcePrefix[sourceStart + overlap] - sourcePrefix[sourceStart]
                let sumTarget = targetPrefix[targetStart + overlap] - targetPrefix[targetStart]
                let sumSourceSquares = sourceSquarePrefix[sourceStart + overlap] - sourceSquarePrefix[sourceStart]
                let sumTargetSquares = targetSquarePrefix[targetStart + overlap] - targetSquarePrefix[targetStart]

                // The FFT hands back the raw Σx·y; the centred numerator the variances expect is
                // Σ(x−x̄)(y−ȳ) = Σxy − (Σx)(Σy)/n. Without this the confidence is uncentred and
                // can exceed 1 — a meaningless threshold.
                let numerator = crossTerms[lag + sourceEnvelope.count - 1] - sumSource * sumTarget / n
                let sourceVariance = sumSourceSquares - sumSource * sumSource / n
                let targetVariance = sumTargetSquares - sumTarget * sumTarget / n

                let denominator = (sourceVariance * targetVariance).squareRoot()
                if denominator > 1e-6 {
                    let r = numerator / denominator
                    if r > bestCorrelation {
                        bestCorrelation = r
                        bestLag = lag
                    }
                }
            }
        }
        return Correlation(lagFrames: bestLag, confidence: bestCorrelation, floor: minLag, ceiling: maxLag)
    }

    /// Σ source[i]·target[i+lag] for every lag, indexed as `result[lag + source.count - 1]`:
    /// `IFFT(conj(FFT(source)) · FFT(target))`, zero-padded past source + target samples so the
    /// circular wrap stays out of the linear range.
    private static func crossTermsByLag(_ source: [Float], _ target: [Float]) -> [Double] {
        let n = source.count
        let m = target.count
        var length = 1
        while length < n + m { length <<= 1 }

        var sourceReal = [Double](repeating: 0, count: length)
        var sourceImaginary = [Double](repeating: 0, count: length)
        for index in 0..<n { sourceReal[index] = Double(source[index]) }
        var targetReal = [Double](repeating: 0, count: length)
        var targetImaginary = [Double](repeating: 0, count: length)
        for index in 0..<m { targetReal[index] = Double(target[index]) }

        fft(&sourceReal, &sourceImaginary)
        fft(&targetReal, &targetImaginary)

        // conj(X) · Y — the transform of the cross-correlation rather than the convolution: the
        // conjugate is what keeps the lag sign as written.
        for index in 0..<length {
            let a = sourceReal[index]
            let b = -sourceImaginary[index]
            let c = targetReal[index]
            let d = targetImaginary[index]
            sourceReal[index] = a * c - b * d
            sourceImaginary[index] = a * d + b * c
        }
        fft(&sourceReal, &sourceImaginary, inverse: true)

        var result = [Double](repeating: 0, count: n + m - 1)
        for lag in -(n - 1)..<m {
            let bin = ((lag % length) + length) % length
            result[lag + n - 1] = sourceReal[bin]
        }
        return result
    }

    /// In-place iterative radix-2 FFT over a power-of-two length; `inverse` divides by the length.
    private static func fft(_ real: inout [Double], _ imaginary: inout [Double], inverse: Bool = false) {
        let n = real.count
        var j = 0
        if n > 1 {
            for i in 1..<n {
                var bit = n >> 1
                while j & bit != 0 {
                    j ^= bit
                    bit >>= 1
                }
                j |= bit
                if i < j {
                    real.swapAt(i, j)
                    imaginary.swapAt(i, j)
                }
            }
        }

        var length = 2
        while length <= n {
            let angle = 2 * Double.pi / Double(length) * (inverse ? 1 : -1)
            let stepReal = cos(angle)
            let stepImaginary = sin(angle)
            var start = 0
            while start < n {
                var twiddleReal = 1.0
                var twiddleImaginary = 0.0
                for k in 0..<(length / 2) {
                    let even = start + k
                    let odd = even + length / 2
                    let evenReal = real[even]
                    let evenImaginary = imaginary[even]
                    let oddReal = real[odd] * twiddleReal - imaginary[odd] * twiddleImaginary
                    let oddImaginary = real[odd] * twiddleImaginary + imaginary[odd] * twiddleReal
                    real[even] = evenReal + oddReal
                    imaginary[even] = evenImaginary + oddImaginary
                    real[odd] = evenReal - oddReal
                    imaginary[odd] = evenImaginary - oddImaginary
                    let nextReal = twiddleReal * stepReal - twiddleImaginary * stepImaginary
                    twiddleImaginary = twiddleReal * stepImaginary + twiddleImaginary * stepReal
                    twiddleReal = nextReal
                }
                start += length
            }
            length <<= 1
        }

        if inverse {
            let scale = Double(n)
            for index in 0..<n {
                real[index] /= scale
                imaginary[index] /= scale
            }
        }
    }
}
