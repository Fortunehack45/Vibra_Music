#ifndef VIBRA_EFFECTS_BUS_H
#define VIBRA_EFFECTS_BUS_H

#include <vector>
#include <cmath>
#include <algorithm>

namespace vibra {

class EffectsBus {
public:
    enum class EffectType {
        NONE,
        REVERB,
        ECHO
    };

    enum class TailMode {
        CUT,
        RING
    };

private:
    float sampleRate = 44100.0f;
    EffectType type = EffectType::NONE;
    TailMode tail = TailMode.CUT;
    float sendAmount = 0.0f;

    // Echo delay buffer (stereo, max 2 seconds)
    std::vector<float> echoBufferL;
    std::vector<float> echoBufferR;
    size_t echoWritePos = 0;
    size_t echoDelaySamples = 22050; // default 0.5s
    float echoFeedback = 0.45f;

    // Simple Schroeder reverb comb filters
    static const int NUM_COMBS = 4;
    std::vector<float> combBuffer[NUM_COMBS];
    size_t combIndex[NUM_COMBS] = {0};
    size_t combLengths[NUM_COMBS] = {1116, 1188, 1277, 1356};
    float combFeedback = 0.75f;

public:
    EffectsBus() = default;

    void init(float sr) {
        sampleRate = sr;
        size_t maxEcho = static_cast<size_t>(sr * 2.0f);
        echoBufferL.assign(maxEcho, 0.0f);
        echoBufferR.assign(maxEcho, 0.0f);
        echoWritePos = 0;

        for (int i = 0; i < NUM_COMBS; ++i) {
            combBuffer[i].assign(combLengths[i], 0.0f);
            combIndex[i] = 0;
        }
    }

    void reset() {
        std::fill(echoBufferL.begin(), echoBufferL.end(), 0.0f);
        std::fill(echoBufferR.begin(), echoBufferR.end(), 0.0f);
        echoWritePos = 0;
        for (int i = 0; i < NUM_COMBS; ++i) {
            std::fill(combBuffer[i].begin(), combBuffer[i].end(), 0.0f);
            combIndex[i] = 0;
        }
    }

    void configure(EffectType fxType, float send, TailMode tailMode, float echoBeats = 0.5f, float bpm = 120.0f) {
        type = fxType;
        sendAmount = std::max(0.0f, std::min(1.0f, send));
        tail = tailMode;

        if (type == EffectType::ECHO && bpm > 20.0f) {
            float beatSec = (60.0f / bpm) * echoBeats;
            size_t delay = static_cast<size_t>(beatSec * sampleRate);
            echoDelaySamples = std::max<size_t>(100, std::min(delay, echoBufferL.size() - 1));
        }
    }

    void onTransitionEnd() {
        if (tail == TailMode::CUT) {
            reset();
        }
        // If RING, buffers naturally decay over time without being reset.
    }

    inline void process(float inL, float inR, float& wetL, float& wetR) {
        if (type == EffectType::NONE || sendAmount <= 0.001f) {
            wetL = 0.0f;
            wetR = 0.0f;
            return;
        }

        if (type == EffectType::ECHO) {
            // Read delayed sample
            size_t readPos = (echoWritePos + echoBufferL.size() - echoDelaySamples) % echoBufferL.size();
            float delL = echoBufferL[readPos];
            float delR = echoBufferR[readPos];

            // Write input + feedback into ring buffer
            echoBufferL[echoWritePos] = inL * sendAmount + delL * echoFeedback;
            echoBufferR[echoWritePos] = inR * sendAmount + delR * echoFeedback;

            echoWritePos = (echoWritePos + 1) % echoBufferL.size();

            wetL = delL * sendAmount;
            wetR = delR * sendAmount;
        } else if (type == EffectType::REVERB) {
            float monoIn = (inL + inR) * 0.5f * sendAmount;
            float sum = 0.0f;

            for (int i = 0; i < NUM_COMBS; ++i) {
                float out = combBuffer[i][combIndex[i]];
                combBuffer[i][combIndex[i]] = monoIn + out * combFeedback;
                combIndex[i] = (combIndex[i] + 1) % combLengths[i];
                sum += out;
            }

            float wet = (sum / NUM_COMBS) * sendAmount;
            wetL = wet;
            wetR = wet;
        }
    }
};

} // namespace vibra

#endif // VIBRA_EFFECTS_BUS_H
