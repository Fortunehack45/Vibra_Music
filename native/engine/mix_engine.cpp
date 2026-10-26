#include "mix_engine.h"
#include <cmath>
#include <algorithm>
#include <cstring>

namespace vibra {

MixEngine::MixEngine() {
    init(44100.0f, 2);
}

MixEngine::~MixEngine() {
    reset();
}

void MixEngine::init(float sr, int ch) {
    std::lock_guard<std::mutex> lock(engineMutex);
    sampleRate = sr;
    channels = ch;

    // Buffer 4 seconds per deck
    size_t fifoCapacity = static_cast<size_t>(sr * 4.0f);

    for (int i = 0; i < 2; ++i) {
        decks[i].deckId = i;
        decks[i].ringBuffer.init(fifoCapacity, channels);
        decks[i].eq.init(sr, 200.0f, 2500.0f);
        decks[i].filter.init(sr);
        decks[i].stretcher.presetDefault(channels, sr);

        decks[i].volume.store(1.0f, std::memory_order_relaxed);
        decks[i].lowGain.store(1.0f, std::memory_order_relaxed);
        decks[i].midGain.store(1.0f, std::memory_order_relaxed);
        decks[i].highGain.store(1.0f, std::memory_order_relaxed);
        decks[i].filterParam.store(0.5f, std::memory_order_relaxed);
        decks[i].stretchRatio.store(1.0f, std::memory_order_relaxed);

        decks[i].isArmed.store(false, std::memory_order_relaxed);
        decks[i].isPlaying.store(i == 0, std::memory_order_relaxed); // Deck 0 defaults to active
        decks[i].startSampleCountdown.store(0, std::memory_order_relaxed);

        decks[i].planarInL.resize(8192, 0.0f);
        decks[i].planarInR.resize(8192, 0.0f);
        decks[i].planarOutL.resize(8192, 0.0f);
        decks[i].planarOutR.resize(8192, 0.0f);
        decks[i].scratchInterleaved.resize(16384, 0.0f);
    }

    limiter.init(sr, -0.5f, 3.0f, 50.0f);
    effectsBus.init(sr);
    masterBuffer.resize(16384, 0.0f);
    deckBuffer.resize(16384, 0.0f);
}

void MixEngine::reset() {
    std::lock_guard<std::mutex> lock(engineMutex);
    for (int i = 0; i < 2; ++i) {
        decks[i].ringBuffer.reset();
        decks[i].eq.reset();
        decks[i].filter.reset();
        decks[i].stretcher.reset();
        decks[i].volume.store(1.0f, std::memory_order_relaxed);
        decks[i].lowGain.store(1.0f, std::memory_order_relaxed);
        decks[i].midGain.store(1.0f, std::memory_order_relaxed);
        decks[i].highGain.store(1.0f, std::memory_order_relaxed);
        decks[i].filterParam.store(0.5f, std::memory_order_relaxed);
        decks[i].stretchRatio.store(1.0f, std::memory_order_relaxed);
        decks[i].isArmed.store(false, std::memory_order_relaxed);
        decks[i].isPlaying.store(i == 0, std::memory_order_relaxed);
        decks[i].startSampleCountdown.store(0, std::memory_order_relaxed);
    }
    effectsBus.reset();
    limiter.reset();
}

size_t MixEngine::writeDeckPcm(int deckId, const float* pcm, size_t numFrames) {
    if (deckId < 0 || deckId > 1 || !pcm || numFrames == 0) return 0;
    return decks[deckId].ringBuffer.write(pcm, numFrames);
}

size_t MixEngine::getDeckBufferedFrames(int deckId) const {
    if (deckId < 0 || deckId > 1) return 0;
    return decks[deckId].ringBuffer.availableRead();
}

void MixEngine::flushDeck(int deckId) {
    if (deckId < 0 || deckId > 1) return;
    decks[deckId].ringBuffer.reset();
    decks[deckId].eq.reset();
    decks[deckId].stretcher.reset();
    decks[deckId].isArmed.store(false, std::memory_order_release);
    decks[deckId].isPlaying.store(false, std::memory_order_release);
    decks[deckId].startSampleCountdown.store(0, std::memory_order_release);
}

void MixEngine::armDeck(int deckId, int64_t triggerCountdownFrames, float initialStretch) {
    if (deckId < 0 || deckId > 1) return;
    decks[deckId].startSampleCountdown.store(std::max<int64_t>(0, triggerCountdownFrames), std::memory_order_release);
    decks[deckId].stretchRatio.store(initialStretch, std::memory_order_release);
    decks[deckId].isArmed.store(true, std::memory_order_release);
    decks[deckId].isPlaying.store(triggerCountdownFrames <= 0, std::memory_order_release);
}

void MixEngine::setDeckParameters(int deckId, float volume, float lowGain, float midGain, float highGain, float filterParam, float stretchRatio) {
    if (deckId < 0 || deckId > 1) return;
    decks[deckId].volume.store(std::clamp(volume, 0.0f, 2.0f), std::memory_order_release);
    decks[deckId].lowGain.store(std::clamp(lowGain, 0.0f, 2.0f), std::memory_order_release);
    decks[deckId].midGain.store(std::clamp(midGain, 0.0f, 2.0f), std::memory_order_release);
    decks[deckId].highGain.store(std::clamp(highGain, 0.0f, 2.0f), std::memory_order_release);
    float clampedFilter = std::clamp(filterParam, 0.0f, 1.0f);
    decks[deckId].filterParam.store(clampedFilter, std::memory_order_release);
    decks[deckId].filter.setNormalizedParam(clampedFilter);
    decks[deckId].stretchRatio.store(std::clamp(stretchRatio, 0.5f, 2.0f), std::memory_order_release);
}

void MixEngine::configureEffects(int fxType, float sendAmount, int tailMode, float echoBeats, float bpm) {
    std::lock_guard<std::mutex> lock(engineMutex);
    effectsBus.configure(
        static_cast<EffectsBus::EffectType>(fxType),
        sendAmount,
        static_cast<EffectsBus::TailMode>(tailMode),
        echoBeats,
        bpm
    );
}

void MixEngine::setDeckPlaying(int deckId, bool playing) {
    if (deckId < 0 || deckId > 1) return;
    decks[deckId].isPlaying.store(playing, std::memory_order_release);
}

size_t MixEngine::render(float* output, size_t numFrames) {
    if (!output || numFrames == 0) return 0;

    std::lock_guard<std::mutex> lock(engineMutex);

    size_t samplesNeeded = numFrames * channels;
    if (masterBuffer.size() < samplesNeeded) {
        masterBuffer.resize(samplesNeeded);
    }
    if (deckBuffer.size() < samplesNeeded) {
        deckBuffer.resize(samplesNeeded);
    }

    std::fill(masterBuffer.begin(), masterBuffer.begin() + samplesNeeded, 0.0f);

    for (int d = 0; d < 2; ++d) {
        DeckState& deck = decks[d];
        bool playing = deck.isPlaying.load(std::memory_order_acquire);
        bool armed = deck.isArmed.load(std::memory_order_acquire);

        if (!playing && !armed) continue;

        int64_t countdown = deck.startSampleCountdown.load(std::memory_order_acquire);
        size_t offsetFrames = 0;
        size_t framesToProcess = numFrames;

        if (countdown > 0) {
            if (countdown >= static_cast<int64_t>(numFrames)) {
                deck.startSampleCountdown.store(countdown - numFrames, std::memory_order_release);
                continue; // Entire block is before trigger downbeat
            } else {
                // Trigger happens mid-block!
                offsetFrames = static_cast<size_t>(countdown);
                framesToProcess = numFrames - offsetFrames;
                deck.startSampleCountdown.store(0, std::memory_order_release);
                deck.isPlaying.store(true, std::memory_order_release);
                deck.isArmed.store(false, std::memory_order_release);
            }
        }

        if (framesToProcess == 0) continue;

        float ratio = deck.stretchRatio.load(std::memory_order_acquire);
        float vol = deck.volume.load(std::memory_order_acquire);
        float low = deck.lowGain.load(std::memory_order_acquire);
        float mid = deck.midGain.load(std::memory_order_acquire);
        float high = deck.highGain.load(std::memory_order_acquire);

        float* deckDest = deckBuffer.data();

        if (std::abs(ratio - 1.0f) < 0.001f) {
            // Direct 1:1 playback
            size_t read = deck.ringBuffer.read(deckDest, framesToProcess);
            if (read < framesToProcess) {
                // Underrun: zero remainder
                std::fill(deckDest + (read * channels), deckDest + (framesToProcess * channels), 0.0f);
            }
        } else {
            // Signalsmith Stretch time conforming
            int inFramesNeeded = std::max<int>(1, static_cast<int>(std::round(framesToProcess * ratio)));

            if (deck.scratchInterleaved.size() < static_cast<size_t>(inFramesNeeded * channels)) {
                deck.scratchInterleaved.resize(inFramesNeeded * channels);
            }
            if (deck.planarInL.size() < static_cast<size_t>(inFramesNeeded)) {
                deck.planarInL.resize(inFramesNeeded);
                deck.planarInR.resize(inFramesNeeded);
            }
            if (deck.planarOutL.size() < framesToProcess) {
                deck.planarOutL.resize(framesToProcess);
                deck.planarOutR.resize(framesToProcess);
            }

            size_t read = deck.ringBuffer.read(deck.scratchInterleaved.data(), inFramesNeeded);
            if (read < static_cast<size_t>(inFramesNeeded)) {
                std::fill(deck.scratchInterleaved.data() + (read * channels),
                          deck.scratchInterleaved.data() + (inFramesNeeded * channels), 0.0f);
            }

            // De-interleave
            for (int i = 0; i < inFramesNeeded; ++i) {
                deck.planarInL[i] = deck.scratchInterleaved[i * 2];
                deck.planarInR[i] = deck.scratchInterleaved[i * 2 + 1];
            }

            float* inputs[2] = { deck.planarInL.data(), deck.planarInR.data() };
            float* outputs[2] = { deck.planarOutL.data(), deck.planarOutR.data() };

            deck.stretcher.process(inputs, inFramesNeeded, outputs, static_cast<int>(framesToProcess));

            // Re-interleave
            for (size_t i = 0; i < framesToProcess; ++i) {
                deckDest[i * 2] = deck.planarOutL[i];
                deckDest[i * 2 + 1] = deck.planarOutR[i];
            }
        }

        // Apply 3-band LR4 crossover filter
        deck.eq.process(deckDest, deckDest, static_cast<int>(framesToProcess), low, mid, high);

        // Apply Biquad LPF / HPF sweep
        for (size_t i = 0; i < framesToProcess; ++i) {
            deck.filter.process(deckDest[i * 2], deckDest[i * 2 + 1]);
        }

        // Accumulate into masterBuffer with deck volume and effects
        float* masterDest = masterBuffer.data() + (offsetFrames * channels);
        for (size_t i = 0; i < framesToProcess; ++i) {
            float left = deckDest[i * 2];
            float right = deckDest[i * 2 + 1];

            if (d == 0) {
                float wetL = 0.0f, wetR = 0.0f;
                effectsBus.process(left, right, wetL, wetR);
                masterDest[i * 2] += left * vol + wetL;
                masterDest[i * 2 + 1] += right * vol + wetR;
            } else {
                masterDest[i * 2] += left * vol;
                masterDest[i * 2 + 1] += right * vol;
            }
        }
    }

    // Apply lookahead true-peak limiter on master sum
    limiter.process(masterBuffer.data(), output, static_cast<int>(numFrames));

    return numFrames;
}

} // namespace vibra
