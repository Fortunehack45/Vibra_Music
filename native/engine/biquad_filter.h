#ifndef VIBRA_BIQUAD_FILTER_H
#define VIBRA_BIQUAD_FILTER_H

#include <cmath>
#include <algorithm>

namespace vibra {

class BiquadFilter {
public:
    enum class Type {
        BYPASS,
        LOW_PASS,
        HIGH_PASS
    };

private:
    Type type = Type::BYPASS;
    float sampleRate = 44100.0f;
    float cutoffHz = 1000.0f;
    float q = 0.7071f;

    // Normalized coefficients (divided by a0)
    float b0 = 1.0f, b1 = 0.0f, b2 = 0.0f;
    float a1 = 0.0f, a2 = 0.0f;

    // Transposed direct form II states for 2 channels
    float z1[2] = {0.0f, 0.0f};
    float z2[2] = {0.0f, 0.0f};

    void calculateCoefficients() {
        if (type == Type::BYPASS || cutoffHz <= 10.0f || cutoffHz >= sampleRate * 0.49f) {
            b0 = 1.0f; b1 = 0.0f; b2 = 0.0f;
            a1 = 0.0f; a2 = 0.0f;
            return;
        }

        const float pi = 3.14159265358979323846f;
        float omega = 2.0f * pi * (cutoffHz / sampleRate);
        float sinOmega = std::sin(omega);
        float cosOmega = std::cos(omega);
        float alpha = sinOmega / (2.0f * q);

        float a0 = 1.0f + alpha;

        if (type == Type::LOW_PASS) {
            b0 = ((1.0f - cosOmega) * 0.5f) / a0;
            b1 = (1.0f - cosOmega) / a0;
            b2 = ((1.0f - cosOmega) * 0.5f) / a0;
        } else { // HIGH_PASS
            b0 = ((1.0f + cosOmega) * 0.5f) / a0;
            b1 = (-(1.0f + cosOmega)) / a0;
            b2 = ((1.0f + cosOmega) * 0.5f) / a0;
        }

        a1 = (-2.0f * cosOmega) / a0;
        a2 = (1.0f - alpha) / a0;
    }

public:
    BiquadFilter() = default;

    void init(float sr) {
        sampleRate = sr;
        reset();
    }

    void reset() {
        z1[0] = z1[1] = 0.0f;
        z2[0] = z2[1] = 0.0f;
        calculateCoefficients();
    }

    /**
     * Maps normalized parameter v in [0.0, 1.0] to filter cutoff:
     * 0.5 is neutral / bypass.
     * < 0.5: Low-pass sweep from 20000 Hz down to 200 Hz.
     * > 0.5: High-pass sweep from 20 Hz up to 2000 Hz.
     */
    void setNormalizedParam(float v) {
        v = std::max(0.0f, std::min(1.0f, v));
        if (v < 0.495f) {
            type = Type::LOW_PASS;
            float norm = (0.5f - v) * 2.0f; // 0..1
            cutoffHz = 20000.0f * std::pow(200.0f / 20000.0f, norm);
        } else if (v > 0.505f) {
            type = Type::HIGH_PASS;
            float norm = (v - 0.5f) * 2.0f; // 0..1
            cutoffHz = 20.0f * std::pow(2000.0f / 20.0f, norm);
        } else {
            type = Type::BYPASS;
        }
        calculateCoefficients();
    }

    inline void process(float& left, float& right) {
        if (type == Type::BYPASS) return;

        // Process Left
        float outL = b0 * left + z1[0];
        z1[0] = b1 * left - a1 * outL + z2[0];
        z2[0] = b2 * left - a2 * outL;
        left = outL;

        // Process Right
        float outR = b0 * right + z1[1];
        z1[1] = b1 * right - a1 * outR + z2[1];
        z2[1] = b2 * right - a2 * outR;
        right = outR;
    }
};

} // namespace vibra

#endif // VIBRA_BIQUAD_FILTER_H
