/*
 * Ported from Orchard (https://github.com/SFG5453/Orchard).
 *
 * Copyright (C) 2026 SFG545 (original Orchard implementation)
 * Copyright (C) 2026 Kushagra Singh (BitChord adaptation)
 *
 * Orchard's original source is licensed under the GNU Affero General Public
 * License, version 3 or later. Per AGPLv3 section 13, this file is combined
 * here into BitChord -- a work licensed under the GNU General Public
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

// C bridge to the analyzer, standing in for the Android JNI glue in
// app/src/main/cpp/jni/{analysis,mel,vocal}_jni.cpp.
//
// AnalysisResult carries about twenty fields including strings, which is more
// than is worth marshalling field by field across a language boundary. It is
// serialized to JSON instead, exactly as the JNI bridge does: analysis runs
// once per track, so the cost is irrelevant beside the decode around it, and a
// string is far easier to log and to test against than a hand-packed struct.
//
// Only the subset the transition policy actually reads is emitted. Chroma, the
// mid and high energy curves, loudness, peak and dynamic range are computed by
// the analyzer but nothing downstream consumes them.

#include "AutomixAnalyzer.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "analyzer/audio_analysis.h"
#include "analyzer/mel_spectrogram.h"
#include "analyzer/resampler.h"
#include "analyzer/vocal_spectrogram.h"

namespace {

// The analyzer's strings are its own literals -- key names like "Câ™¯ minor"
// and candidate types like "main_drop". The JNI bridge kept only printable
// ASCII, which silently turned "Câ™¯ minor" into "C minor" and "Eâ™­ major" into
// "E major" before the planner's key table (which spells the accidentals)
// ever saw them. Here the UTF-8 is passed through and only what JSON requires
// is escaped, so the key the analyzer measured is the key the planner reads.
void AppendString(std::string& out, const std::string& value) {
  out += '"';
  for (const char character : value) {
    const unsigned char byte = static_cast<unsigned char>(character);
    if (character == '"' || character == '\\') {
      out += '\\';
      out += character;
    } else if (byte < 0x20) {
      // Control characters never appear in the analyzer's literals; dropped
      // rather than escaped so a surprise cannot produce invalid JSON.
      continue;
    } else {
      out += character;
    }
  }
  out += '"';
}

void AppendNumber(std::string& out, double value) {
  // Not finite means the field never got a defensible value; null reads as
  // absent on the Swift side, which is what every consumer already handles.
  if (!(value == value) || value > 1e308 || value < -1e308) {
    out += "null";
    return;
  }
  char buffer[32];
  std::snprintf(buffer, sizeof(buffer), "%.6g", value);
  out += buffer;
}

void AppendDoubles(std::string& out, const std::vector<double>& values) {
  out += '[';
  for (size_t index = 0; index < values.size(); ++index) {
    if (index > 0) out += ',';
    AppendNumber(out, values[index]);
  }
  out += ']';
}

void AppendEnergyCurve(std::string& out, const std::vector<vibramusic::smart::EnergyPoint>& points) {
  out += '[';
  for (size_t index = 0; index < points.size(); ++index) {
    if (index > 0) out += ',';
    out += "{\"t\":";
    AppendNumber(out, points[index].time);
    out += ",\"e\":";
    AppendNumber(out, points[index].energy);
    out += '}';
  }
  out += ']';
}

void AppendCuePoints(std::string& out, const std::vector<vibramusic::smart::MixCuePoint>& points) {
  out += '[';
  for (size_t index = 0; index < points.size(); ++index) {
    if (index > 0) out += ',';
    out += "{\"t\":";
    AppendNumber(out, points[index].time);
    out += ",\"s\":";
    AppendNumber(out, points[index].score);
    out += ",\"y\":";
    AppendString(out, points[index].type);
    out += '}';
  }
  out += ']';
}

void AppendField(std::string& out, const char* name, double value, bool first = false) {
  if (!first) out += ',';
  out += '"';
  out += name;
  out += "\":";
  AppendNumber(out, value);
}

// Hands a vector's contents to C as a malloc'd buffer the Swift side frees
// with bc_automix_free. Empty means "declined", which C states as NULL.
float* CopyOut(const std::vector<float>& values, size_t* out_count) {
  if (out_count != nullptr) *out_count = 0;
  if (values.empty()) return nullptr;
  auto* buffer = static_cast<float*>(std::malloc(values.size() * sizeof(float)));
  if (buffer == nullptr) return nullptr;
  std::memcpy(buffer, values.data(), values.size() * sizeof(float));
  if (out_count != nullptr) *out_count = values.size();
  return buffer;
}

std::vector<float> CopyIn(const float* samples, size_t count) {
  if (samples == nullptr || count == 0) return {};
  return std::vector<float>(samples, samples + count);
}

}  // namespace

extern "C" {

double bc_automix_analysis_sample_rate(void) {
  // The rate the analyzer's window and hop constants assume; the Android
  // bridge hard-codes the same number.
  return 11025.0;
}

char* bc_automix_analyze_json(const float* samples,
                              size_t count,
                              double sample_rate,
                              double duration_seconds) {
  // Nothing may unwind across the C boundary: a C++ exception reaching Swift terminates the
  // process, for work whose whole failure mode is meant to be "this track goes unanalysed".
  try {
    const std::vector<float> input = CopyIn(samples, count);
    const vibramusic::smart::AnalysisResult result =
        vibramusic::smart::AnalyzeAudio(input, sample_rate, duration_seconds);

    std::string json;
    // A whole-track energy curve dominates the output; reserving up front keeps
    // this from repeatedly reallocating a string that reaches tens of kilobytes.
    json.reserve(8192 + result.energy_curve.size() * 24);

    json += '{';
    AppendField(json, "duration", result.duration, true);
    AppendField(json, "bpm", result.bpm);
    AppendField(json, "beatInterval", result.beat_interval);
    AppendField(json, "firstBeat", result.first_beat);
    AppendField(json, "beatConfidence", result.beat_confidence);
    AppendField(json, "keyConfidence", result.key_confidence);
    AppendField(json, "audibleStartTime", result.audible_start_time);
    AppendField(json, "pickupTime", result.pickup_time);
    AppendField(json, "introEndTime", result.intro_end_time);
    AppendField(json, "outroStartTime", result.outro_start_time);
    AppendField(json, "contentEndTime", result.content_end_time);
    AppendField(json, "mixInTime", result.mix_in_time);
    AppendField(json, "mixOutTime", result.mix_out_time);
    AppendField(json, "vocalProbability", result.vocal_probability);

    json += ",\"key\":";
    AppendString(json, result.key);
    json += ",\"downbeats\":";
    AppendDoubles(json, result.downbeats);
    json += ",\"phraseBoundaries\":";
    AppendDoubles(json, result.phrase_boundaries);
    json += ",\"vocalActivityMask\":";
    AppendDoubles(json, result.vocal_activity_mask);
    json += ",\"energyCurve\":";
    AppendEnergyCurve(json, result.energy_curve);
    json += ",\"lowEnergyCurve\":";
    AppendEnergyCurve(json, result.low_energy_curve);
    json += ",\"mixInCandidates\":";
    AppendCuePoints(json, result.mix_in_candidates);
    json += ",\"mixOutCandidates\":";
    AppendCuePoints(json, result.mix_out_candidates);
    json += '}';

    auto* buffer = static_cast<char*>(std::malloc(json.size() + 1));
    if (buffer == nullptr) return nullptr;
    std::memcpy(buffer, json.c_str(), json.size() + 1);
    return buffer;
  } catch (...) {
    return nullptr;
  }
}

float* bc_automix_resample(const float* samples,
                           size_t count,
                           double input_rate,
                           double output_rate,
                           size_t* out_count) {
  if (out_count != nullptr) *out_count = 0;
  try {
    const std::vector<float> resampled =
        vibramusic::smart::Resample(CopyIn(samples, count), input_rate, output_rate);
    return CopyOut(resampled, out_count);
  } catch (...) {
    return nullptr;
  }
}

float* bc_automix_beat_spectrogram(const float* samples,
                                   size_t count,
                                   double sample_rate,
                                   size_t* out_frames) {
  if (out_frames != nullptr) *out_frames = 0;
  try {
    const vibramusic::smart::BeatSpectrogram spectrogram =
        vibramusic::smart::ComputeBeatSpectrogram(CopyIn(samples, count), sample_rate);
    size_t produced = 0;
    float* buffer = CopyOut(spectrogram.values, &produced);
    if (buffer != nullptr && out_frames != nullptr) *out_frames = spectrogram.frames;
    return buffer;
  } catch (...) {
    return nullptr;
  }
}

size_t bc_automix_beat_spectrogram_mels(void) {
  return vibramusic::smart::kBeatSpectrogramMels;
}

double bc_automix_beat_spectrogram_sample_rate(void) {
  return vibramusic::smart::kBeatSpectrogramSampleRate;
}

size_t bc_automix_beat_spectrogram_hop(void) {
  return vibramusic::smart::kBeatSpectrogramHop;
}

float* bc_automix_vocal_spectrogram(const float* left,
                                    const float* right,
                                    size_t count,
                                    double sample_rate,
                                    size_t* out_frames) {
  if (out_frames != nullptr) *out_frames = 0;
  // Planar in, planar out: the front end wants one vector per channel, and the
  // caller already holds them apart, so there is no interleave on either side.
  try {
    std::vector<std::vector<float>> channels(2);
    channels[0] = CopyIn(left, count);
    channels[1] = CopyIn(right, count);
    const vibramusic::smart::VocalSpectrogram spectrogram =
        vibramusic::smart::ComputeVocalSpectrogram(channels, sample_rate);
    size_t produced = 0;
    float* buffer = CopyOut(spectrogram.values, &produced);
    if (buffer != nullptr && out_frames != nullptr) *out_frames = spectrogram.frames;
    return buffer;
  } catch (...) {
    return nullptr;
  }
}

size_t bc_automix_vocal_spectrogram_bins(void) {
  return vibramusic::smart::kVocalSpectrogramBins;
}

double bc_automix_vocal_spectrogram_sample_rate(void) {
  return vibramusic::smart::kVocalSpectrogramSampleRate;
}

size_t bc_automix_vocal_spectrogram_hop(void) {
  return vibramusic::smart::kVocalSpectrogramHop;
}

size_t bc_automix_vocal_spectrogram_fft_size(void) {
  return vibramusic::smart::kVocalSpectrogramFft;
}

void bc_automix_free(void* pointer) {
  std::free(pointer);
}

}  // extern "C"
