#ifndef VIBRA_LR4_CROSSOVER_H
#define VIBRA_LR4_CROSSOVER_H

#include <cmath>
#include <algorithm>
#include <vector>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

namespace vibra {

/**
 * 2nd-order IIR Biquad Filter (Direct Form II Transposed).
 */
class Biquad {
public:
    float b0 = 1.0f, b1 = 0.0f, b2 = 0.0f;
    float a1 = 0.0f, a2 = 0.0f;
    float s1 = 0.0f, s2 = 0.0f;

    void reset() {
        s1 = 0.0f;
        s2 = 0.0f;
    }

    inline float process(float in) {
        float out = b0 * in + s1;
        s1 = b1 * in - a1 * out + s2;
        s2 = b2 * in - a2 * out;
        return out;
    }
};

/**
 * 4th-order Linkwitz-Riley Crossover Filter (cascaded Butterworth biquads).
 */
class LR4Filter {
public:
    enum Type { LOWPASS, HIGHPASS, ALLPASS };

    Biquad stage1;
    Biquad stage2;

    void reset() {
        stage1.reset();
        stage2.reset();
    }

    void configure(Type type, float cutoffHz, float sampleRate) {
        float omega = 2.0f * static_cast<float>(M_PI) * cutoffHz / sampleRate;
        float cosOmega = std::cos(omega);
        float sinOmega = std::sin(omega);
        // Butterworth Q = 1 / sqrt(2)
        float alpha = sinOmega / (2.0f * 0.70710678f);

        float a0 = 1.0f + alpha;
        float invA0 = 1.0f / a0;

        float b0 = 1.0f, b1 = 0.0f, b2 = 0.0f;
        float a1 = -2.0f * cosOmega * invA0;
        float a2 = (1.0f - alpha) * invA0;

        switch (type) {
            case LOWPASS:
                b0 = ((1.0f - cosOmega) * 0.5f) * invA0;
                b1 = (1.0f - cosOmega) * invA0;
                b2 = ((1.0f - cosOmega) * 0.5f) * invA0;
                break;
            case HIGHPASS:
                b0 = ((1.0f + cosOmega) * 0.5f) * invA0;
                b1 = -(1.0f + cosOmega) * invA0;
                b2 = ((1.0f + cosOmega) * 0.5f) * invA0;
                break;
            case ALLPASS:
                b0 = (1.0f - alpha) * invA0;
                b1 = -2.0f * cosOmega * invA0;
                b2 = (1.0f + alpha) * invA0;
                break;
        }

        stage1.b0 = b0; stage1.b1 = b1; stage1.b2 = b2;
        stage1.a1 = a1; stage1.a2 = a2;

        stage2.b0 = b0; stage2.b1 = b1; stage2.b2 = b2;
        stage2.a1 = a1; stage2.a2 = a2;
    }

    inline float process(float in) {
        return stage2.process(stage1.process(in));
    }
};

/**
 * 3-Band Linkwitz-Riley Crossover Network (Stereo).
 * Crossover frequencies: fc1 = 200 Hz (Low/Mid), fc2 = 2500 Hz (Mid/High).
 * Perfect magnitude reconstruction: Low + Mid + High = Unity when gains are 1.0.
 */
class LR4ThreeBand {
public:
    struct ChannelFilters {
        LR4Filter lp1; // Low-pass at fc1
        LR4Filter ap2; // All-pass at fc2 (phase aligns Low with Mid/High)
        LR4Filter hp1; // High-pass at fc1
        LR4Filter lp2; // Low-pass at fc2
        LR4Filter hp2; // High-pass at fc2

        void reset() {
            lp1.reset();
            ap2.reset();
            hp1.reset();
            lp2.reset();
            hp2.reset();
        }

        void configure(float fc1, float fc2, float sampleRate) {
            lp1.configure(LR4Filter::LOWPASS, fc1, sampleRate);
            ap2.configure(LR4Filter::ALLPASS, fc2, sampleRate);
            hp1.configure(LR4Filter::HIGHPASS, fc1, sampleRate);
            lp2.configure(LR4Filter::LOWPASS, fc2, sampleRate);
            hp2.configure(LR4Filter::HIGHPASS, fc2, sampleRate);
        }

        inline void split(float in, float &outLow, float &outMid, float &outHigh) {
            // Low band: LP1 followed by AP2
            float lowSplit = lp1.process(in);
            outLow = ap2.process(lowSplit);

            // High split from fc1
            float highSplit1 = hp1.process(in);

            // Mid band: HP1 followed by LP2
            outMid = lp2.process(highSplit1);

            // High band: HP1 followed by HP2
            outHigh = hp2.process(highSplit1);
        }
    };

    ChannelFilters channels[2];
    float sampleRate = 44100.0f;
    float fc1 = 200.0f;
    float fc2 = 2500.0f;

    void init(float sr = 44100.0f, float fLow = 200.0f, float fHigh = 2500.0f) {
        sampleRate = sr;
        fc1 = fLow;
        fc2 = fHigh;
        for (int ch = 0; ch < 2; ++ch) {
            channels[ch].configure(fc1, fc2, sampleRate);
            channels[ch].reset();
        }
    }

    void reset() {
        for (int ch = 0; ch < 2; ++ch) {
            channels[ch].reset();
        }
    }

    /**
     * Process stereo interleaved audio with 3-band gains.
     */
    void process(const float* input, float* output, int numFrames, float lowGain, float midGain, float highGain) {
        for (int i = 0; i < numFrames; ++i) {
            for (int ch = 0; ch < 2; ++ch) {
                float in = input[i * 2 + ch];
                float low = 0.0f, mid = 0.0f, high = 0.0f;
                channels[ch].split(in, low, mid, high);
                output[i * 2 + ch] = (low * lowGain) + (mid * midGain) + (high * highGain);
            }
        }
    }
};

} // namespace vibra

#endif // VIBRA_LR4_CROSSOVER_H
