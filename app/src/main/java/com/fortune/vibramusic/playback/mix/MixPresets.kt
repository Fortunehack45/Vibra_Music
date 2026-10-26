package com.fortune.vibramusic.playback.mix

import kotlinx.serialization.Serializable

/**
 * A cohesive bundle defining settings across all 5 lanes.
 */
@Serializable
data class Preset(
    val id: String,
    val label: String,
    val lengthBars: Int,
    val volumeOptionId: String,
    val eqOptionId: String,
    val filterOptionId: String,
    val effectsOptionId: String,
    val loopBeats: Int,
    val beatmatching: Boolean,
)

object MixPresets {
    val presets: List<Preset> = listOf(
        Preset(
            id = "fade",
            label = "Fade",
            lengthBars = 4,
            volumeOptionId = "fade-in-fade-out",
            eqOptionId = "end-bass-swap",
            filterOptionId = "none",
            effectsOptionId = "none",
            loopBeats = 0,
            beatmatching = true,
        ),
        Preset(
            id = "rise",
            label = "Rise",
            lengthBars = 4,
            volumeOptionId = "fade-in-cut-out",
            eqOptionId = "center-bass-swap",
            filterOptionId = "hpf-in",
            effectsOptionId = "none",
            loopBeats = 0,
            beatmatching = true,
        ),
        Preset(
            id = "blend",
            label = "Blend",
            lengthBars = 8,
            volumeOptionId = "overlap",
            eqOptionId = "center-bass-swap",
            filterOptionId = "none",
            effectsOptionId = "none",
            loopBeats = 0,
            beatmatching = true,
        ),
        Preset(
            id = "wave",
            label = "Wave",
            lengthBars = 8,
            volumeOptionId = "smooth-crossfade",
            eqOptionId = "3-band-fade",
            filterOptionId = "lpf-in-hpf-out",
            effectsOptionId = "none",
            loopBeats = 0,
            beatmatching = true,
        ),
        Preset(
            id = "melt",
            label = "Melt",
            lengthBars = 4,
            volumeOptionId = "fade-in-fast-out",
            eqOptionId = "quick-bass-cut",
            filterOptionId = "lpf-out",
            effectsOptionId = "reverb-out-end",
            loopBeats = 0,
            beatmatching = false,
        ),
        Preset(
            id = "dissolve",
            label = "Dissolve",
            lengthBars = 4,
            volumeOptionId = "smooth-crossfade",
            eqOptionId = "bass-fade-out",
            filterOptionId = "lpf-out",
            effectsOptionId = "reverb-out-center",
            loopBeats = 0,
            beatmatching = true,
        ),
        Preset(
            id = "surge",
            label = "Surge",
            lengthBars = 2,
            volumeOptionId = "cut-in-fade-out",
            eqOptionId = "start-bass-swap",
            filterOptionId = "hpf-in-hpf-out",
            effectsOptionId = "echo-half-cut-end",
            loopBeats = 2,
            beatmatching = true,
        ),
        Preset(
            id = "afterglow",
            label = "Afterglow",
            lengthBars = 4,
            volumeOptionId = "fade-in-cut-out",
            eqOptionId = "bass-fade-out",
            filterOptionId = "none",
            effectsOptionId = "echo-1-out-end",
            loopBeats = 0,
            beatmatching = true,
        ),
        Preset(
            id = "no-transition",
            label = "No transition",
            lengthBars = 2,
            volumeOptionId = "center-cut",
            eqOptionId = "none",
            filterOptionId = "none",
            effectsOptionId = "none",
            loopBeats = 0,
            beatmatching = false,
        ),
    )

    fun find(id: String): Preset =
        presets.firstOrNull { it.id == id } ?: presets[0]
}
