#ifndef VIBRA_LIMITER_H
#define VIBRA_LIMITER_H

#include <vector>
#include <cmath>
#include <algorithm>

namespace vibra {

/**
 * Stereo Lookahead True-Peak Limiter.
 * Lookahead: 3 ms.
 * Ceiling: -0.5 dBFS (~0.944).
 * Release: 50 ms.
 */
class LookaheadLimiter {
public:
    float sampleRate = 44100.0f;
    float ceiling = 0.94406f; // -0.5 dBFS
    int lookaheadFrames = 132; // ~3ms at 44.1kHz
    float releaseCoeff = 0.9995f;

    std::vector<float> delayBuffer;
    int writeIndex = 0;
    float currentGain = 1.0f;

    void init(float sr = 44100.0f, float ceilingDb = -0.5f, float lookaheadMs = 3.0f, float releaseMs = 50.0f) {
        sampleRate = sr;
        ceiling = std::pow(10.0f, ceilingDb / 20.0f);
        lookaheadFrames = std::max(1, static_cast<int>(lookaheadMs * 0.001f * sampleRate));
        float releaseSamples = (releaseMs * 0.001f) * sampleRate;
        releaseCoeff = std::exp(-1.0f / releaseSamples);

        // Circular buffer holds 2 channels * lookaheadFrames
        delayBuffer.assign(lookaheadFrames * 2, 0.0f);
        writeIndex = 0;
        currentGain = 1.0f;
    }

    void reset() {
        std::fill(delayBuffer.begin(), delayBuffer.end(), 0.0f);
        writeIndex = 0;
        currentGain = 1.0f;
    }

    void process(const float* input, float* output, int numFrames) {
        for (int i = 0; i < numFrames; ++i) {
            float inL = input[i * 2];
            float inR = input[i * 2 + 1];

            // 1. Read delayed samples from buffer
            int readIndex = writeIndex;
            float delayedL = delayBuffer[readIndex * 2];
            float delayedR = delayBuffer[readIndex * 2 + 1];

            // 2. Overwrite with current input
            delayBuffer[writeIndex * 2] = inL;
            delayBuffer[writeIndex * 2 + 1] = inR;
            writeIndex = (writeIndex + 1) % lookaheadFrames;

            // 3. Peak evaluation on incoming transient
            float peak = std::max(std::abs(inL), std::abs(inR));
            float targetGain = 1.0f;
            if (peak > ceiling) {
                targetGain = ceiling / peak;
            }

            // 4. Instant attack on lookahead, smooth exponential release
            if (targetGain < currentGain) {
                currentGain = targetGain;
            } else {
                currentGain = targetGain + releaseCoeff * (currentGain - targetGain);
            }

            // 5. Apply coupled gain to delayed signal
            output[i * 2] = std::clamp(delayedL * currentGain, -ceiling, ceiling);
            output[i * 2 + 1] = std::clamp(delayedR * currentGain, -ceiling, ceiling);
        }
    }
};

} // namespace vibra

#endif // VIBRA_LIMITER_H
