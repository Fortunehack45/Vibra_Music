#include <jni.h>
#include "engine/mix_engine.h"

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_fortune_vibramusic_playback_audio_MixEngine_nativeCreate(
    JNIEnv* env, jobject thiz, jfloat sampleRate, jint channels) {
    auto* engine = new vibra::MixEngine();
    engine->init(sampleRate, channels);
    return reinterpret_cast<jlong>(engine);
}

JNIEXPORT void JNICALL
Java_com_fortune_vibramusic_playback_audio_MixEngine_nativeDestroy(
    JNIEnv* env, jobject thiz, jlong handle) {
    if (handle != 0) {
        auto* engine = reinterpret_cast<vibra::MixEngine*>(handle);
        delete engine;
    }
}

JNIEXPORT void JNICALL
Java_com_fortune_vibramusic_playback_audio_MixEngine_nativeReset(
    JNIEnv* env, jobject thiz, jlong handle) {
    if (handle != 0) {
        auto* engine = reinterpret_cast<vibra::MixEngine*>(handle);
        engine->reset();
    }
}

JNIEXPORT jint JNICALL
Java_com_fortune_vibramusic_playback_audio_MixEngine_nativeWriteDeckPcm(
    JNIEnv* env, jobject thiz, jlong handle, jint deckId, jfloatArray pcmArray, jint offset, jint numFrames) {
    if (handle == 0 || !pcmArray || numFrames <= 0) return 0;
    auto* engine = reinterpret_cast<vibra::MixEngine*>(handle);

    jfloat* pcmPtr = env->GetFloatArrayElements(pcmArray, nullptr);
    if (!pcmPtr) return 0;

    size_t written = engine->writeDeckPcm(deckId, pcmPtr + offset, static_cast<size_t>(numFrames));
    env->ReleaseFloatArrayElements(pcmArray, pcmPtr, JNI_ABORT);
    return static_cast<jint>(written);
}

JNIEXPORT jint JNICALL
Java_com_fortune_vibramusic_playback_audio_MixEngine_nativeGetDeckBufferedFrames(
    JNIEnv* env, jobject thiz, jlong handle, jint deckId) {
    if (handle == 0) return 0;
    auto* engine = reinterpret_cast<vibra::MixEngine*>(handle);
    return static_cast<jint>(engine->getDeckBufferedFrames(deckId));
}

JNIEXPORT void JNICALL
Java_com_fortune_vibramusic_playback_audio_MixEngine_nativeFlushDeck(
    JNIEnv* env, jobject thiz, jlong handle, jint deckId) {
    if (handle != 0) {
        auto* engine = reinterpret_cast<vibra::MixEngine*>(handle);
        engine->flushDeck(deckId);
    }
}

JNIEXPORT void JNICALL
Java_com_fortune_vibramusic_playback_audio_MixEngine_nativeArmDeck(
    JNIEnv* env, jobject thiz, jlong handle, jint deckId, jlong triggerCountdownFrames, jfloat initialStretch) {
    if (handle != 0) {
        auto* engine = reinterpret_cast<vibra::MixEngine*>(handle);
        engine->armDeck(deckId, triggerCountdownFrames, initialStretch);
    }
}

JNIEXPORT void JNICALL
Java_com_fortune_vibramusic_playback_audio_MixEngine_nativeSetDeckParameters(
    JNIEnv* env, jobject thiz, jlong handle, jint deckId,
    jfloat volume, jfloat lowGain, jfloat midGain, jfloat highGain, jfloat filterParam, jfloat stretchRatio) {
    if (handle != 0) {
        auto* engine = reinterpret_cast<vibra::MixEngine*>(handle);
        engine->setDeckParameters(deckId, volume, lowGain, midGain, highGain, filterParam, stretchRatio);
    }
}

JNIEXPORT void JNICALL
Java_com_fortune_vibramusic_playback_audio_MixEngine_nativeConfigureEffects(
    JNIEnv* env, jobject thiz, jlong handle,
    jint fxType, jfloat sendAmount, jint tailMode, jfloat echoBeats, jfloat bpm) {
    if (handle != 0) {
        auto* engine = reinterpret_cast<vibra::MixEngine*>(handle);
        engine->configureEffects(fxType, sendAmount, tailMode, echoBeats, bpm);
    }
}

JNIEXPORT void JNICALL
Java_com_fortune_vibramusic_playback_audio_MixEngine_nativeSetDeckPlaying(
    JNIEnv* env, jobject thiz, jlong handle, jint deckId, jboolean playing) {
    if (handle != 0) {
        auto* engine = reinterpret_cast<vibra::MixEngine*>(handle);
        engine->setDeckPlaying(deckId, playing);
    }
}

JNIEXPORT jint JNICALL
Java_com_fortune_vibramusic_playback_audio_MixEngine_nativeRender(
    JNIEnv* env, jobject thiz, jlong handle, jfloatArray outputArray, jint offset, jint numFrames) {
    if (handle == 0 || !outputArray || numFrames <= 0) return 0;
    auto* engine = reinterpret_cast<vibra::MixEngine*>(handle);

    jfloat* outPtr = env->GetFloatArrayElements(outputArray, nullptr);
    if (!outPtr) return 0;

    size_t rendered = engine->render(outPtr + offset, static_cast<size_t>(numFrames));
    env->ReleaseFloatArrayElements(outputArray, outPtr, 0); // 0 copies back results to Java array
    return static_cast<jint>(rendered);
}

} // extern "C"
