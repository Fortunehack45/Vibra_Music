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

import AutomixAnalyzer
import Foundation
import os

// Swift faces of the native analyzer (TrackFeatures.kt, MelSpectrogram.kt and the
// VocalSpectrogram object in VocalTracker.kt). On Android these wrap JNI and carry an
// `available` flag for a library that may fail to load; here the C++ is linked into the module,
// so it is always present and the flag is gone.

/// Whole-track envelope, structure and key analysis from the native DSP analyzer
/// (`AutomixAnalyzer/analyzer/audio_analysis.cpp`).
///
/// This answers "where does the music actually end, where can a transition enter and leave, how
/// loud is it there, and is anyone singing" — plus a beat grid from autocorrelation, which the
/// model pass refines where it can.
enum TrackFeatures {
    private static let logger = Logger(subsystem: "com.fortune.vibramusic.ios", category: "Automix")

    /// The rate the analyzer's window and hop constants assume, deliberately low, because envelope
    /// and structure work needs time resolution rather than bandwidth, and an eighth of the
    /// samples is an eighth of the work.
    static let sampleRate: Double = bc_automix_analysis_sample_rate()

    /// Analyses `samples`, which must be mono float PCM at ``sampleRate``.
    ///
    /// Nil when the analyzer declined the input or its output did not parse. Callers treat that as
    /// "no evidence", which the policy already degrades on.
    static func analyze(_ samples: [Float], durationSeconds: Double) -> Features? {
        if samples.isEmpty { return nil }
        let pointer = samples.withUnsafeBufferPointer { buffer in
            bc_automix_analyze_json(buffer.baseAddress, buffer.count, sampleRate, durationSeconds)
        }
        guard let pointer else { return nil }
        defer { bc_automix_free(pointer) }
        let data = Data(bytes: pointer, count: strlen(pointer))
        guard let features = parse(data) else {
            logger.warning("Could not parse analysis output")
            return nil
        }
        return features
    }

    /// The subset of the analyzer's output the transition policy reads.
    struct Features: Sendable, Equatable {
        var duration: Double
        var bpm: Double
        var beatInterval: Double
        var firstBeat: Double
        var beatConfidence: Double
        var key: String
        var keyConfidence: Double
        var audibleStartTime: Double
        var pickupTime: Double
        var introEndTime: Double
        var outroStartTime: Double
        var contentEndTime: Double
        var mixInTime: Double
        var mixOutTime: Double
        var vocalProbability: Double
        var downbeats: [Double]
        var phraseBoundaries: [Double]
        var vocalActivityMask: [Double]
        var energyCurve: [EnergySample]
        var lowEnergyCurve: [EnergySample]
        var mixInCandidates: [MixCandidate]
        var mixOutCandidates: [MixCandidate]
    }

    /// Parses the bridge's JSON with the same forgiveness as `JSONObject.optDouble`: a missing,
    /// null or non-finite scalar reads as 0, and array entries that are not finite are skipped.
    static func parse(_ data: Data) -> Features? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }

        func number(_ value: Any?) -> Double? {
            guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            return value.doubleValue
        }
        func scalar(_ name: String) -> Double { number(root[name])?.orZero ?? 0 }
        func doubles(_ name: String) -> [Double] {
            guard let array = root[name] as? [Any] else { return [] }
            return array.compactMap { number($0) }.filter(\.isFinite)
        }
        func energyCurve(_ name: String) -> [EnergySample] {
            guard let array = root[name] as? [Any] else { return [] }
            return array.compactMap { entry in
                guard let point = entry as? [String: Any],
                      let time = number(point["t"]), let energy = number(point["e"]),
                      time.isFinite, energy.isFinite else { return nil }
                return EnergySample(time: time, energy: energy)
            }
        }
        func cuePoints(_ name: String) -> [MixCandidate] {
            guard let array = root[name] as? [Any] else { return [] }
            return array.compactMap { entry in
                guard let point = entry as? [String: Any], let time = number(point["t"]), time.isFinite else {
                    return nil
                }
                return MixCandidate(
                    time: time,
                    score: number(point["s"])?.orZero ?? 0,
                    type: point["y"] as? String ?? ""
                )
            }
        }

        return Features(
            duration: scalar("duration"),
            bpm: scalar("bpm"),
            beatInterval: scalar("beatInterval"),
            firstBeat: scalar("firstBeat"),
            beatConfidence: scalar("beatConfidence"),
            key: root["key"] as? String ?? "",
            keyConfidence: scalar("keyConfidence"),
            audibleStartTime: scalar("audibleStartTime"),
            pickupTime: scalar("pickupTime"),
            introEndTime: scalar("introEndTime"),
            outroStartTime: scalar("outroStartTime"),
            contentEndTime: scalar("contentEndTime"),
            mixInTime: scalar("mixInTime"),
            mixOutTime: scalar("mixOutTime"),
            vocalProbability: scalar("vocalProbability"),
            downbeats: doubles("downbeats"),
            phraseBoundaries: doubles("phraseBoundaries"),
            vocalActivityMask: doubles("vocalActivityMask"),
            energyCurve: energyCurve("energyCurve"),
            lowEnergyCurve: energyCurve("lowEnergyCurve"),
            mixInCandidates: cuePoints("mixInCandidates"),
            mixOutCandidates: cuePoints("mixOutCandidates")
        )
    }
}

/// Sample-rate conversion with the analyzer's anti-aliasing windowed-sinc filter
/// (`analyzer/resampler.cpp`).
///
/// A windowed-sinc conversion rather than decimation: dropping samples would fold everything
/// above the target Nyquist back into the band the analysis reads, and an aliased spectrum yields
/// a *wrong* tempo, key or beat grid rather than a noisy one, which the planner would then trust.
enum AutomixResampler {
    /// `samples` converted from `inputRate` to `outputRate`; the input unchanged when the rates
    /// already match, and nil when the input is empty or a rate is unusable.
    static func resample(_ samples: [Float], from inputRate: Double, to outputRate: Double) -> [Float]? {
        if samples.isEmpty || !(inputRate > 0) || !(outputRate > 0) { return nil }
        if abs(inputRate - outputRate) < 1e-6 { return samples }
        var produced = 0
        let pointer = samples.withUnsafeBufferPointer { buffer in
            bc_automix_resample(buffer.baseAddress, buffer.count, inputRate, outputRate, &produced)
        }
        guard let pointer, produced > 0 else { return nil }
        defer { bc_automix_free(pointer) }
        return Array(UnsafeBufferPointer(start: pointer, count: produced))
    }
}

/// The log-mel front end the Beat This! model expects (`analyzer/mel_spectrogram.cpp`).
///
/// Every constant is dictated by the trained network rather than chosen: torchaudio's
/// MelSpectrogram at 22,050 Hz, n_fft 1024, hop 441 (exactly 50 frames per second), 128 Slaney
/// mel bands from 30 Hz to 11 kHz, and `log1p(1000 · magnitude)`. Audio at any other rate is
/// refused rather than resampled here, because resampling belongs upstream where full-bandwidth
/// samples still exist.
enum MelSpectrogram {
    /// Mel bands per frame; the model's input width.
    static let mels = Int(bc_automix_beat_spectrogram_mels())
    /// The only sample rate the front end accepts.
    static let sampleRate = bc_automix_beat_spectrogram_sample_rate()
    /// Samples between frame starts; 441 at 22,050 Hz is exactly 20 ms.
    static let hop = Int(bc_automix_beat_spectrogram_hop())
    /// Frames per second of output, which is what beat times are derived from.
    static var frameRate: Double { sampleRate / Double(hop) }

    /// A flattened spectrogram, row-major over frames: frame `f` band `b` is at `f * mels + b`.
    /// Flat because the only consumer hands it straight to a `[1, frames, mels]` tensor.
    struct Spectrogram: Equatable {
        var values: [Float]
        var frames: Int
        var mels: Int
        var durationSeconds: Double { Double(frames) / MelSpectrogram.frameRate }
    }

    /// Nil when the rate is wrong or the input is shorter than one padded frame: "no model
    /// prediction available", which the policy already degrades on.
    static func compute(_ samples: [Float], sampleRate: Double = MelSpectrogram.sampleRate) -> Spectrogram? {
        if samples.isEmpty { return nil }
        var frames = 0
        let pointer = samples.withUnsafeBufferPointer { buffer in
            bc_automix_beat_spectrogram(buffer.baseAddress, buffer.count, sampleRate, &frames)
        }
        guard let pointer, frames > 0 else { return nil }
        defer { bc_automix_free(pointer) }
        return Spectrogram(values: Array(UnsafeBufferPointer(start: pointer, count: frames * mels)), frames: frames, mels: mels)
    }
}

/// The linear-frequency STFT front end open-unmix was trained on (`analyzer/vocal_spectrogram.cpp`).
enum VocalSpectrogram {
    static let channels = 2
    static let bins = Int(bc_automix_vocal_spectrogram_bins())
    static let sampleRate = bc_automix_vocal_spectrogram_sample_rate()
    static let hop = Int(bc_automix_vocal_spectrogram_hop())
    static let fftSize = Int(bc_automix_vocal_spectrogram_fft_size())
    static var frameRate: Double { sampleRate / Double(hop) }

    /// Bin-major, flattened: channel c, bin b, frame f is at `(c * bins + b) * frames + f`, chosen
    /// to match the model's `[1, 2, bins, frames]` tensor exactly, so nothing has to transpose.
    struct Spectrogram: Equatable {
        var values: [Float]
        var frames: Int
        var bins: Int
    }

    /// Nil when the rate is wrong, the channels differ in length, or the input is shorter than one
    /// padded frame — all of which mean "no mask available" rather than an error.
    static func compute(left: [Float], right: [Float], sampleRate: Double = VocalSpectrogram.sampleRate) -> Spectrogram? {
        if left.isEmpty || left.count != right.count { return nil }
        var frames = 0
        let pointer = left.withUnsafeBufferPointer { leftBuffer in
            right.withUnsafeBufferPointer { rightBuffer in
                bc_automix_vocal_spectrogram(leftBuffer.baseAddress, rightBuffer.baseAddress, leftBuffer.count, sampleRate, &frames)
            }
        }
        guard let pointer, frames > 0 else { return nil }
        defer { bc_automix_free(pointer) }
        return Spectrogram(
            values: Array(UnsafeBufferPointer(start: pointer, count: channels * bins * frames)),
            frames: frames,
            bins: bins
        )
    }
}
