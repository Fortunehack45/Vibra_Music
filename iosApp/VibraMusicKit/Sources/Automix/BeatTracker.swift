/*
 * Ported from Orchard (https://github.com/SFG5453/Orchard).
 *
 * Copyright (C) 2026 SFG545 (original Orchard implementation)
 * Copyright (C) 2026 Kushagra Singh (Vibra Music adaptation)
 *
 * Orchard's original source is licensed under the GNU Affero General Public
 * License, version 3 or later. Per AGPLv3 section 13, this file is combined
 * here into Vibra Music -- a work licensed under the GNU General Public
 * License, version 3 or later -- and remains itself governed by the AGPLv3
 * as part of that combination.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero
 * General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation
import os

/// Beat and downbeat tracking with the Beat This! model (CPJKU, ISMIR 2024).
///
/// Why a model at all: tempo and *meter* are different problems. Autocorrelation reads tempo
/// well, but nothing in an autocorrelation says which of four beats is beat one, and a mix that
/// enters on beat three sounds wrong even when every beat lines up.
///
/// Beat This! is the one that can be shipped: both its code and its trained weights are MIT.
///
/// Everything here is optional. A missing model, an unreadable graph, a rate mismatch, too few
/// peaks, all resolve to nil, and the caller keeps whatever it had.
final class BeatTracker: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.fortune.vibramusic.ios", category: "Automix")

    /// A tracked grid on the analysed audio's own timeline, in seconds.
    struct Grid: Sendable, Equatable {
        var beats: [Double]
        var downbeats: [Double]
        var bpm: Double
        var beatInterval: Double
        var firstBeat: Double
        var beatConfidence: Double
    }

    /// The window the model was trained on, and the margin discarded from each chunk's edges.
    static let chunkFrames = 1500
    static let borderFrames = 6

    /// Window length that costs exactly one inference. A longer window splits into two chunks
    /// that mostly overlap, paying twice for barely more audio.
    static let windowSeconds = Double(chunkFrames - 2 * borderFrames) / 50.0

    /// A frame is a beat when it is the maximum of a seven-frame window and its logit positive.
    private static let peakWindow = 7
    private static let minBeats = 8

    /// Plausible musical tempo, used only to reject a grid the model clearly did not find.
    private static let minTempo = 40.0
    private static let maxTempo = 220.0

    private let model: AutomixModelSession

    init(modelURL: URL? = AutomixModel.beatThis.bundledURL, threads: @escaping @Sendable () -> Int) {
        model = AutomixModelSession(modelURL: modelURL, threads: threads)
    }

    /// Tracks `pcm`, which must already be mono at ``MelSpectrogram/sampleRate``.
    ///
    /// `offsetSeconds` is added to every returned time, so a grid tracked on a decoded region maps
    /// back onto the full track's timeline rather than starting at zero.
    func track(_ pcm: [Float], offsetSeconds: Double = 0) -> Grid? {
        guard model.isConfigured else { return nil }
        let melStarted = Date()
        guard let spectrogram = MelSpectrogram.compute(pcm) else { return nil }
        let melMs = Int(Date().timeIntervalSince(melStarted) * 1000)

        var beatLogits = [Float](repeating: 0, count: spectrogram.frames)
        var downbeatLogits = [Float](repeating: 0, count: spectrogram.frames)
        let inferStarted = Date()
        if !infer(spectrogram, beatLogits: &beatLogits, downbeatLogits: &downbeatLogits) { return nil }
        Self.logger.debug("mel \(melMs)ms (\(spectrogram.frames) frames) infer \(Int(Date().timeIntervalSince(inferStarted) * 1000))ms")

        return Self.grid(beatLogits: beatLogits, downbeatLogits: downbeatLogits, offsetSeconds: offsetSeconds)
    }

    /// Turns the model's two logit curves into a grid. Separate from ``track(_:offsetSeconds:)`` so
    /// the post-processing can be tested without running the model.
    static func grid(beatLogits: [Float], downbeatLogits: [Float], offsetSeconds: Double) -> Grid? {
        let fps = MelSpectrogram.frameRate
        let beatFrames = pickPeaks(beatLogits)
        let beats = beatFrames.map { $0 / fps + offsetSeconds }
        if beats.count < minBeats { return nil }

        let bpm = tempoFromBeats(beats)
        if bpm <= 0 { return nil }

        // Every downbeat is a beat. The two heads are predicted independently, so their peaks can
        // land a frame apart; snapping each downbeat onto the nearest beat keeps the bar grid a
        // strict subset of the beat grid, which is what the planner assumes when it snaps a
        // transition to a downbeat.
        let snapped = pickPeaks(downbeatLogits)
            .map { $0 / fps + offsetSeconds }
            .map { time in beats.min { abs($0 - time) < abs($1 - time) } ?? beats[0] }
        let downbeats = Array(Set(snapped)).sorted()

        return Grid(
            beats: beats,
            downbeats: downbeats,
            bpm: bpm,
            beatInterval: 60 / bpm,
            firstBeat: beats[0],
            beatConfidence: gridConfidence(
                beats,
                peakLogits: beatFrames.map { frame in
                    let index = kotlinRound(frame)
                    return beatLogits.indices.contains(index) ? Double(beatLogits[index]) : 0
                }
            )
        )
    }

    /// Runs the model over the spectrogram in chunks, writing logits into the output arrays.
    ///
    /// The model reads 1500-frame chunks and has no context at their edges, so ``borderFrames``
    /// are discarded from each side and chunks advance by the difference. The first and last
    /// chunk keep their outer border, since there is no neighbouring chunk to supply it.
    private func infer(
        _ spectrogram: MelSpectrogram.Spectrogram,
        beatLogits: inout [Float],
        downbeatLogits: inout [Float]
    ) -> Bool {
        let mels = spectrogram.mels
        let frames = spectrogram.frames
        let stride = Self.chunkFrames - 2 * Self.borderFrames

        var start = 0
        while start < frames {
            let length = min(Self.chunkFrames, frames - start)
            // A chunk shorter than the border padding carries no usable centre.
            if length <= 2 * Self.borderFrames && start > 0 { break }

            let chunkStart = start
            let ran: Bool? = model.run(
                shape: [1, length, mels],
                fill: { input in
                    spectrogram.values.withUnsafeBufferPointer { values in
                        _ = input.update(fromContentsOf: values[(chunkStart * mels)..<((chunkStart + length) * mels)])
                    }
                },
                read: { outputs, _ in
                    guard outputs.count >= 2 else { return nil }
                    let beat = outputs[0]
                    let downbeat = outputs[1]
                    let keepFrom = chunkStart == 0 ? 0 : Self.borderFrames
                    let keepTo = chunkStart + length >= frames ? length : length - Self.borderFrames
                    var index = keepFrom
                    while index < keepTo {
                        let target = chunkStart + index
                        if target >= beatLogits.count || index >= beat.count || index >= downbeat.count { break }
                        beatLogits[target] = beat[index]
                        downbeatLogits[target] = downbeat[index]
                        index += 1
                    }
                    return true
                }
            )
            if ran != true { return false }

            if start + length >= frames { break }
            start += stride
        }
        return true
    }

    func release() { model.release() }

    /// Whether the model can run in this build and on this device.
    var isAvailable: Bool { model.isAvailable }

    /// Whether there is a model to run at all, without parsing it.
    var isConfigured: Bool { model.isConfigured }

    // MARK: - Post-processing (pure)

    private static func median(_ values: [Double]) -> Double {
        if values.isEmpty { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// Frame indices that are local maxima over ``peakWindow`` and positive, with runs of adjacent
    /// peaks collapsed to their mean, then refined to sub-frame resolution.
    ///
    /// The refinement is not upstream's. The model's frame rate is 50 Hz, so an integer peak
    /// quantizes every beat to 20 ms, fine for drawing a grid, but a large share of the flam budget
    /// when beat-matching two tracks. Fitting a parabola through the peak and its neighbours
    /// recovers where the maximum actually sits.
    static func pickPeaks(_ logits: [Float]) -> [Double] {
        let half = peakWindow / 2
        var peaks: [Int] = []
        for index in logits.indices {
            if logits[index] <= 0 { continue }
            var isMaximum = true
            for offset in -half...half {
                let neighbour = index + offset
                if neighbour < 0 || neighbour >= logits.count { continue }
                if logits[neighbour] > logits[index] {
                    isMaximum = false
                    break
                }
            }
            if isMaximum { peaks.append(index) }
        }

        // Collapse adjacent frames that tied for the maximum onto their mean.
        var deduped: [Int] = []
        var index = 0
        while index < peaks.count {
            var mean = Double(peaks[index])
            var count = 1
            while index + 1 < peaks.count && Double(peaks[index + 1]) - mean <= 1 {
                index += 1
                count += 1
                mean += (Double(peaks[index]) - mean) / Double(count)
            }
            deduped.append(kotlinRound(mean))
            index += 1
        }

        return deduped.map { frame in
            if frame <= 0 || frame + 1 >= logits.count { return Double(frame) }
            let left = Double(logits[frame - 1])
            let centre = Double(logits[frame])
            let right = Double(logits[frame + 1])
            let denominator = left - 2 * centre + right
            if abs(denominator) <= 1e-9 { return Double(frame) }
            return Double(frame) + (0.5 * (left - right) / denominator).coerced(-0.5, 0.5)
        }
    }

    /// Median inter-beat interval as a tempo, or 0 when it is not a plausible one.
    static func tempoFromBeats(_ beats: [Double]) -> Double {
        if beats.count < minBeats { return 0 }
        let gaps = zip(beats, beats.dropFirst()).map { $1 - $0 }
        let rough = median(gaps)
        if rough <= 0 { return 0 }
        // A second pass over gaps close to the first estimate, so a few dropped beats do not drag
        // the interval.
        let kept = gaps.filter { abs($0 - rough) <= rough * 0.2 }
        let interval = median(kept.count >= 4 ? kept : gaps)
        if interval <= 0 { return 0 }
        let bpm = 60 / interval
        return (minTempo...maxTempo).contains(bpm) ? bpm : 0
    }

    /// How far the grid can be trusted, 0...1: regularity of the spacing and decisiveness of the
    /// peaks. This is the number the whole transition policy gates on, so it is deliberately capped
    /// below 1: a model is evidence, not proof.
    static func gridConfidence(_ beats: [Double], peakLogits: [Double]) -> Double {
        if beats.count < minBeats { return 0 }
        let gaps = zip(beats, beats.dropFirst()).map { $1 - $0 }
        let interval = median(gaps)
        if interval <= 0 { return 0 }

        // Fraction of gaps that are one beat rather than a hole in the grid.
        let regular = Double(gaps.filter { abs($0 - interval) <= interval * 0.1 }.count) / Double(gaps.count)
        // Logits are unbounded; a median around 2 is a decisive peak, around 0 is not.
        let strength = 1 / (1 + exp(-(median(peakLogits) - 0.5)))
        return max(0, min(0.95, 0.35 + 0.4 * regular + 0.25 * strength))
    }
}

/// Kotlin's `Double.roundToInt()` (`Math.round`): halves round up, towards positive infinity.
func kotlinRound(_ value: Double) -> Int { Int((value + 0.5).rounded(.down)) }
