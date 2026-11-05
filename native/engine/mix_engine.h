#ifndef VIBRA_MIX_ENGINE_H
#define VIBRA_MIX_ENGINE_H

#include "signalsmith-stretch.h"
#include "ring_buffer.h"
#include <memory>
#include <mutex>
#include <atomic>
#include <vector>
#include <cmath>
#include <algorithm>

#if defined(__ANDROID__)
#include <oboe/Oboe.h>
#endif

namespace vibra {

struct RBJBiquad {
    float b0 = 1.0f, b1 = 0.0f, b2 = 0.0f;
    float a1 = 0.0f, a2 = 0.0f;
    float z1 = 0.0f, z2 = 0.0f;

    void highpass(float fc, float sr, float q = 0.707f) {
        if (fc <= 10.0f) {
            b0 = 1.0f; b1 = 0.0f; b2 = 0.0f;
            a1 = 0.0f; a2 = 0.0f;
            return;
        }
        float w = 2.0f * static_cast<float>(M_PI) * (fc / sr);
        float c = std::cos(w);
        float s = std::sin(w);
        float al = s / (2.0f * q);
        float a0 = 1.0f + al;
        b0 = (1.0f + c) * 0.5f / a0;
        b1 = -(1.0f + c) / a0;
        b2 = b0;
        a1 = -2.0f * c / a0;
        a2 = (1.0f - al) / a0;
    }

    void lowpass(float fc, float sr, float q = 0.707f) {
        if (fc >= sr * 0.49f) {
            b0 = 1.0f; b1 = 0.0f; b2 = 0.0f;
            a1 = 0.0f; a2 = 0.0f;
            return;
        }
        float w = 2.0f * static_cast<float>(M_PI) * (fc / sr);
        float c = std::cos(w);
        float s = std::sin(w);
        float al = s / (2.0f * q);
        float a0 = 1.0f + al;
        b0 = (1.0f - c) * 0.5f / a0;
        b1 = (1.0f - c) / a0;
        b2 = b0;
        a1 = -2.0f * c / a0;
        a2 = (1.0f - al) / a0;
    }

    float process(float x) {
        float y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        return y;
    }

    void reset() {
        z1 = 0.0f;
        z2 = 0.0f;
    }
};

struct EngineDeck {
    AudioRingBuffer ringBuffer;
    signalsmith::stretch::SignalsmithStretch<float> stretcher;
    double pos = 0.0;                 // source position in frames
    double bpm = 120.0;               // native tempo
    float loudGain = 1.0f;            // from LUFS
    std::vector<float> beatsMs;       // beat grid
    RBJBiquad hpL, hpR;
    RBJBiquad lpL, lpR;

    // Planar stretch buffers
    std::vector<float> planarInL;
    std::vector<float> planarInR;
    std::vector<float> planarOutL;
    std::vector<float> planarOutR;
    std::vector<float> scratchInterleaved;

    void init(float sr, size_t fifoCapacity) {
        ringBuffer.init(fifoCapacity, 2);
        stretcher.presetDefault(2, sr);
        planarInL.resize(8192, 0.0f);
        planarInR.resize(8192, 0.0f);
        planarOutL.resize(8192, 0.0f);
        planarOutR.resize(8192, 0.0f);
        scratchInterleaved.resize(16384, 0.0f);
        pos = 0.0;
        bpm = 120.0;
        loudGain = 1.0f;
        hpL.reset(); hpR.reset();
        lpL.reset(); lpR.reset();
    }

    void reset() {
        ringBuffer.reset();
        stretcher.reset();
        pos = 0.0;
        hpL.reset(); hpR.reset();
        lpL.reset(); lpR.reset();
    }

    double beatAt(double frames, double sr) const {
        if (beatsMs.empty() || bpm <= 0.0 || sr <= 0.0) {
            double sec = frames / (sr > 0.0 ? sr : 44100.0);
            return sec * (bpm / 60.0);
        }
        double currentMs = (frames / sr) * 1000.0;
        if (currentMs <= beatsMs.front()) {
            double beatDurMs = 60000.0 / bpm;
            return (currentMs - beatsMs.front()) / beatDurMs;
        }
        if (currentMs >= beatsMs.back()) {
            double beatDurMs = 60000.0 / bpm;
            return static_cast<double>(beatsMs.size() - 1) + (currentMs - beatsMs.back()) / beatDurMs;
        }
        auto it = std::upper_bound(beatsMs.begin(), beatsMs.end(), static_cast<float>(currentMs));
        size_t idx = std::distance(beatsMs.begin(), it);
        if (idx == 0) return 0.0;
        size_t prevIdx = idx - 1;
        float t0 = beatsMs[prevIdx];
        float t1 = beatsMs[idx];
        float fraction = (t1 > t0) ? (static_cast<float>(currentMs) - t0) / (t1 - t0) : 0.0f;
        return static_cast<double>(prevIdx) + static_cast<double>(fraction);
    }

    int framesUntilBeat(double targetBeat, double rate, double sr) const {
        double currentBeat = beatAt(pos, sr);
        double beatsRemaining = targetBeat - currentBeat;
        if (beatsRemaining <= 0.0) return 0;
        double effectiveRate = (rate > 0.01f) ? rate : 1.0f;
        double secRemaining = beatsRemaining * (60.0 / (bpm * effectiveRate));
        return std::max(0, static_cast<int>(secRemaining * sr));
    }

    void render(float* outLR, int n, float rate) {
        if (n <= 0) return;
        if (std::abs(rate - 1.0f) < 0.001f) {
            size_t readFrames = ringBuffer.read(outLR, static_cast<size_t>(n));
            if (readFrames < static_cast<size_t>(n)) {
                std::fill(outLR + 2 * readFrames, outLR + 2 * n, 0.0f);
            }
            pos += n;
            return;
        }

        int neededInFrames = static_cast<int>(std::ceil(n * rate));
        if (neededInFrames > static_cast<int>(planarInL.size())) {
            planarInL.resize(neededInFrames * 2, 0.0f);
            planarInR.resize(neededInFrames * 2, 0.0f);
            scratchInterleaved.resize(neededInFrames * 4, 0.0f);
        }
        if (n > static_cast<int>(planarOutL.size())) {
            planarOutL.resize(n * 2, 0.0f);
            planarOutR.resize(n * 2, 0.0f);
        }

        size_t read = ringBuffer.read(scratchInterleaved.data(), static_cast<size_t>(neededInFrames));
        if (read < static_cast<size_t>(neededInFrames)) {
            std::fill(scratchInterleaved.data() + 2 * read, scratchInterleaved.data() + 2 * neededInFrames, 0.0f);
        }

        for (int i = 0; i < neededInFrames; ++i) {
            planarInL[i] = scratchInterleaved[2 * i];
            planarInR[i] = scratchInterleaved[2 * i + 1];
        }

        float* inputs[2] = { planarInL.data(), planarInR.data() };
        float* outputs[2] = { planarOutL.data(), planarOutR.data() };
        stretcher.process(inputs, neededInFrames, outputs, n);

        for (int i = 0; i < n; ++i) {
            outLR[2 * i] = planarOutL[i];
            outLR[2 * i + 1] = planarOutR[i];
        }

        pos += neededInFrames;
    }
};

struct EnginePlan {
    bool active = false;
    double alignBeatOut = 0.0;
    double rampBeats = 0.0;
    double targetBpm = 120.0;
    int64_t inStartFrame = 0;
    int64_t overlapFrames = 0;
    int style = 0; // 0: LONG_BLEND, 1: RAMP_BASS_SWAP, 2: FILTER_SWEEP, 3: ECHO_OUT, 4: CUT
};

#if defined(__ANDROID__)
class MixEngine : public oboe::AudioStreamDataCallback {
#else
class MixEngine {
#endif
private:
    float sampleRate = 44100.0f;
    int channels = 2;

    EngineDeck cur;
    EngineDeck nxt;
    EnginePlan plan;

    bool nxtStarted = false;
    int64_t overlapDone = 0;
    int consecutivePhaseErrors = 0;

    std::vector<float> bufA;
    std::vector<float> bufB;
    std::vector<float> echoBufferL;
    std::vector<float> echoBufferR;
    size_t echoWriteIdx = 0;

    std::mutex engineMutex;

#if defined(__ANDROID__)
    std::shared_ptr<oboe::AudioStream> oboeStream;
#endif

    void renderSolo(float* out, int n, float rate);
    void renderOverlap(float* out, int n, float rate);
    void finishTransition();

    static inline float smooth(float e0, float e1, float x) {
        if (x <= e0) return 0.0f;
        if (x >= e1) return 1.0f;
        float p = (x - e0) / (e1 - e0);
        return p * p * (3.0f - 2.0f * p);
    }

    static inline float softLimit(float x) {
        return std::tanh(x * 0.9f) / 0.9f;
    }

    static inline void applyGain(float* out, int n, float g) {
        if (std::abs(g - 1.0f) < 0.001f) return;
        for (int i = 0; i < 2 * n; ++i) {
            out[i] *= g;
        }
    }

public:
    MixEngine();
    virtual ~MixEngine();

    void init(float sr = 44100.0f, int ch = 2);
    void reset();

    // Deck PCM input
    size_t writeDeckPcm(int deckId, const float* pcm, size_t numFrames);
    size_t getDeckBufferedFrames(int deckId);
    void flushDeck(int deckId);

    // Deck configuration
    void setDeckBpm(int deckId, double bpm, const std::vector<float>& beats);
    void setDeckLufs(int deckId, float lufs);
    void setDeckPlaying(int deckId, bool playing);

    // Mix plan control
    void setPlan(bool active, double alignBeatOut, double rampBeats, double targetBpm, int64_t inStartFrame, int64_t overlapFrames, int style);

    // Audio rendering
    size_t render(float* output, size_t numFrames);

#if defined(__ANDROID__)
    oboe::DataCallbackResult onAudioReady(oboe::AudioStream* stream, void* data, int32_t numFrames) override;
    bool startOboeStream();
    void stopOboeStream();
#endif
};

} // namespace vibra

#endif // VIBRA_MIX_ENGINE_H
