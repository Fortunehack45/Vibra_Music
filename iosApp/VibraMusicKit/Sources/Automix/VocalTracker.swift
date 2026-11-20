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

/// Vocal-presence tracking with open-unmix's "vocals" target (Stöter & Liutkus, Inria/SigSep).
///
/// The transition policy uses this to avoid mixing two vocals over each other: a blend where both
/// tracks are singing is the one case that reliably sounds wrong however well the beats line up.
///
/// Chosen because its **weights** are MIT. Meta's htdemucs separates better but releases its
/// pretrained weights under CC-BY-NC-4.0, which a distributed application cannot ship. Only the
/// vocals target is used: Vibra Music needs to know how much vocal content is present at an instant,
/// not to reconstruct four stems.
final class VocalTracker: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.fortune.vibramusic.ios", category: "Automix")

    /// The model's fixed input width, ~22.3 s, chosen upstream to cover a transition overlap.
    static let fixedFrames = 960

    /// The band a vocal actually occupies; below and above it the mask says little.
    private static let lowHz = 200.0
    private static let highHz = 4000.0

    private let model: AutomixModelSession

    init(modelURL: URL? = AutomixModel.vocals.bundledURL, threads: @escaping @Sendable () -> Int) {
        model = AutomixModelSession(modelURL: modelURL, threads: threads)
    }

    /// One vocal-presence value per STFT frame in 0...1, or nil when unavailable.
    ///
    /// The model's input width is fixed at ``fixedFrames``. Shorter input is zero-padded; longer is
    /// refused rather than chunked, because a transition never needs more than one window.
    func track(left: [Float], right: [Float], sampleRate: Double) -> [Float]? {
        // Before the resampling and the STFT, which are most of the cost when there is no model
        // to hand them to.
        guard model.isConfigured else { return nil }
        guard let resampledLeft = AutomixResampler.resample(left, from: sampleRate, to: VocalSpectrogram.sampleRate),
              let resampledRight = AutomixResampler.resample(right, from: sampleRate, to: VocalSpectrogram.sampleRate)
        else { return nil }

        let started = Date()
        guard let spectrogram = VocalSpectrogram.compute(left: resampledLeft, right: resampledRight) else { return nil }
        if spectrogram.frames > Self.fixedFrames {
            Self.logger.debug("Window of \(spectrogram.frames) frames exceeds the model's \(Self.fixedFrames)")
            return nil
        }
        let bins = spectrogram.bins
        let curve: [Float]? = model.run(
            shape: [1, VocalSpectrogram.channels, bins, Self.fixedFrames],
            fill: { input in Self.fillFixedFrames(input, values: spectrogram.values, bins: bins, frames: spectrogram.frames) },
            read: { outputs, mix in
                guard let target = outputs.first, target.count == mix.count else { return nil }
                return Self.reduceToBandCurve(mix: mix, target: target, bins: bins, usableFrames: spectrogram.frames)
            }
        )
        if curve != nil {
            Self.logger.debug("vocal mask \(spectrogram.frames) frames in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        }
        return curve
    }

    func release() { model.release() }

    /// Whether the model can run in this build and on this device.
    var isAvailable: Bool { model.isAvailable }

    /// Whether there is a model to run at all, without parsing it.
    var isConfigured: Bool { model.isConfigured }

    /// Writes the spectrogram into the model's fixed width, zero-padding each bin's tail.
    ///
    /// The stride changes as well as the length: the source is stored at `frames` per bin and the
    /// model wants ``fixedFrames``, so this is a re-stride rather than an append.
    static func fillFixedFrames(_ into: UnsafeMutableBufferPointer<Float>, values: [Float], bins: Int, frames: Int) {
        if frames == fixedFrames {
            _ = into.update(fromContentsOf: values)
            return
        }
        into.update(repeating: 0)
        values.withUnsafeBufferPointer { source in
            for channel in 0..<VocalSpectrogram.channels {
                for bin in 0..<bins {
                    let row = channel * bins + bin
                    let from = row * frames
                    let to = row * fixedFrames
                    for frame in 0..<frames { into[to + frame] = source[from + frame] }
                }
            }
        }
    }

    /// Averages `mask = target / (mix + eps)` across a frequency band, then across channels.
    ///
    /// Band-averaging rather than a full per-bin mask: the only consumer is a single number per
    /// instant (how vocal this moment is). Only the frames carrying real audio are reduced; the
    /// padded tail's mask is meaningless and folding it in would drag every short window toward
    /// silence.
    static func reduceToBandCurve(
        mix: UnsafeBufferPointer<Float>,
        target: UnsafeBufferPointer<Float>,
        bins: Int,
        usableFrames: Int
    ) -> [Float] {
        let lowBin = max(0, Int((lowHz * Double(VocalSpectrogram.fftSize) / VocalSpectrogram.sampleRate).rounded(.down)))
        let highBin = min(bins - 1, Int((highHz * Double(VocalSpectrogram.fftSize) / VocalSpectrogram.sampleRate).rounded(.up)))
        if highBin <= lowBin || usableFrames <= 0 { return [] }

        var curve = [Float](repeating: 0, count: usableFrames)
        for frame in 0..<usableFrames {
            var sum = 0.0
            var count = 0
            for channel in 0..<VocalSpectrogram.channels {
                for bin in lowBin...highBin {
                    // Both buffers carry the model's [1, 2, bins, fixedFrames] layout, so one index
                    // reads the same cell of each.
                    let index = (channel * bins + bin) * fixedFrames + frame
                    let mixValue = mix[index]
                    if mixValue <= 1e-6 { continue }
                    let ratio = target[index] / mixValue
                    sum += Double(min(max(ratio, 0), 1))
                    count += 1
                }
            }
            curve[frame] = count > 0 ? Float(sum / Double(count)) : 0
        }
        return curve
    }
}
