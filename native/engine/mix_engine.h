#ifndef VIBRA_MIX_ENGINE_H
#define VIBRA_MIX_ENGINE_H

#include "signalsmith-stretch.h"
#include "lr4_crossover.h"
#include "limiter.h"
#include "ring_buffer.h"
#include "biquad_filter.h"
#include "effects_bus.h"
#include <memory>
#include <mutex>
#include <atomic>
#include <vector>

namespace vibra {

struct DeckState {
    int deckId = 0;
    AudioRingBuffer ringBuffer;
    LR4ThreeBand eq;
    BiquadFilter filter;
    signalsmith::stretch::SignalsmithStretch<float> stretcher;

    std::atomic<float> volume{1.0f};
    std::atomic<float> lowGain{1.0f};
    std::atomic<float> midGain{1.0f};
    std::atomic<float> highGain{1.0f};
    std::atomic<float> filterParam{0.5f};
    std::atomic<float> stretchRatio{1.0f};

    std::atomic<bool> isArmed{false};
    std::atomic<bool> isPlaying{false};
    std::atomic<int64_t> startSampleCountdown{0};

    // Scratch buffers for planar stretch processing
    std::vector<float> planarInL;
    std::vector<float> planarInR;
    std::vector<float> planarOutL;
    std::vector<float> planarOutR;
    std::vector<float> scratchInterleaved;
};

class MixEngine {
private:
    float sampleRate = 44100.0f;
    int channels = 2;

    DeckState decks[2];
    EffectsBus effectsBus;
    LookaheadLimiter limiter;

    std::vector<float> masterBuffer;
    std::vector<float> deckBuffer;
    std::mutex engineMutex;

public:
    MixEngine();
    ~MixEngine();

    void init(float sr = 44100.0f, int ch = 2);
    void reset();

    // Deck writing
    size_t writeDeckPcm(int deckId, const float* pcm, size_t numFrames);
    size_t getDeckBufferedFrames(int deckId) const;
    void flushDeck(int deckId);

    // Transition arming & parameters
    void armDeck(int deckId, int64_t triggerCountdownFrames, float initialStretch = 1.0f);
    void setDeckParameters(int deckId, float volume, float lowGain, float midGain, float highGain, float filterParam, float stretchRatio);
    void configureEffects(int fxType, float sendAmount, int tailMode, float echoBeats = 0.5f, float bpm = 120.0f);
    void setDeckPlaying(int deckId, bool playing);

    // Rendering
    size_t render(float* output, size_t numFrames);
};

} // namespace vibra

#endif // VIBRA_MIX_ENGINE_H
