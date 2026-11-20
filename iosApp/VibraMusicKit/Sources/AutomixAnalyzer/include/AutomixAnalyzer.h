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

// Plain C face of the native Automix analyzer (analyzer/*.cpp, kept as the
// Android build compiles it).
//
// This is the iOS counterpart of app/src/main/cpp/jni/*.cpp. It is C rather
// than C++ on purpose: Swift imports a C header as an ordinary Clang module,
// so nothing that depends on the Automix module has to turn on Swift/C++
// interoperability to use it.
//
// Ownership: every pointer returned here is allocated with malloc and must be
// released with bc_automix_free. A NULL return always means "no result" (the
// analyzer declined the input, or allocation failed), never an error to throw;
// the Swift side reads it as "no evidence", which is what the transition
// policy already degrades on.
//
// Every call borrows its input only until it returns and is reentrant. The
// work is O(n) to O(n log n) and allocates, so it belongs on a worker thread,
// never on a real-time audio thread.

#ifndef VIBRAMUSIC_AUTOMIX_ANALYZER_H
#define VIBRAMUSIC_AUTOMIX_ANALYZER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// The rate the whole-track analyzer's window and hop constants assume (11,025 Hz).
double bc_automix_analysis_sample_rate(void);

/// Runs the whole-track DSP analysis over mono float PCM at `sample_rate`.
///
/// Returns a NUL-terminated UTF-8 JSON object carrying the subset of the
/// analysis the transition policy reads, in the same shape the Android JNI
/// bridge produces (see TrackFeatures.swift for the keys). Non-finite numbers
/// are written as `null`. Free with bc_automix_free.
char *bc_automix_analyze_json(const float *samples,
                              size_t count,
                              double sample_rate,
                              double duration_seconds);

/// Windowed-sinc conversion of mono float PCM from `input_rate` to
/// `output_rate`. Returns NULL (and 0 in `out_count`) when the input is empty
/// or either rate is not positive. Free with bc_automix_free.
float *bc_automix_resample(const float *samples,
                           size_t count,
                           double input_rate,
                           double output_rate,
                           size_t *out_count);

/// The Beat This! log-mel front end. Returns a flattened row-major
/// [frames][mels] buffer and the frame count in `out_frames`, or NULL when the
/// rate is not bc_automix_beat_spectrogram_sample_rate() or the input is
/// shorter than one padded frame. Free with bc_automix_free.
float *bc_automix_beat_spectrogram(const float *samples,
                                   size_t count,
                                   double sample_rate,
                                   size_t *out_frames);

size_t bc_automix_beat_spectrogram_mels(void);
double bc_automix_beat_spectrogram_sample_rate(void);
size_t bc_automix_beat_spectrogram_hop(void);

/// The open-unmix linear STFT magnitude front end over planar stereo.
/// Returns a flattened [channel][bin][frame] buffer and the frame count in
/// `out_frames`, or NULL when the rate is wrong, the channels differ in
/// length, or the input is shorter than one padded frame. Free with
/// bc_automix_free.
float *bc_automix_vocal_spectrogram(const float *left,
                                    const float *right,
                                    size_t count,
                                    double sample_rate,
                                    size_t *out_frames);

size_t bc_automix_vocal_spectrogram_bins(void);
double bc_automix_vocal_spectrogram_sample_rate(void);
size_t bc_automix_vocal_spectrogram_hop(void);
size_t bc_automix_vocal_spectrogram_fft_size(void);

/// Releases anything returned by the functions above. NULL is ignored.
void bc_automix_free(void *pointer);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // VIBRAMUSIC_AUTOMIX_ANALYZER_H
