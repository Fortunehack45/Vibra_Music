package com.fortune.vibramusic.playback.mix

/**
 * Option definition models and standard presets catalog for the 5 automation lanes.
 */
data class OutInCurves(
    val out: List<Point>,
    val `in`: List<Point>,
)

data class OutInBandCurves(
    val out: BandCurves,
    val `in`: BandCurves,
)

data class VolumeOption(
    val id: String,
    val label: String,
    val build: (bars: Int) -> OutInCurves,
)

data class EqOption(
    val id: String,
    val label: String,
    val build: (bars: Int) -> OutInBandCurves,
)

data class FilterOption(
    val id: String,
    val label: String,
    val build: (bars: Int) -> OutInCurves,
)

data class EffectsOption(
    val id: String,
    val label: String,
    val type: EffectType?,
    val echoBeats: Float?,
    val tail: TailMode,
    val curve: List<Point>,
)

data class LoopingOption(
    val id: String,
    val label: String,
    val beats: Int,
)

object MixOptions {

    private fun pt(t: Float, v: Float, curve: CurveType = CurveType.LINEAR): Point =
        Point(id = Curves.newPointId(), t = t, v = v, curve = curve)

    private fun flat(v: Float): List<Point> = listOf(
        pt(0f, v),
        pt(1f, v),
    )

    // -------------------------------------------------------------------------
    // Volume Options (Blue #3B82F6)
    // -------------------------------------------------------------------------
    val volumeOptions: List<VolumeOption> = listOf(
        VolumeOption(
            id = "smooth-crossfade",
            label = "Smooth crossfade",
            build = {
                OutInCurves(
                    out = listOf(pt(0f, 1f, CurveType.SMOOTH), pt(1f, 0f)),
                    `in` = listOf(pt(0f, 0f, CurveType.SMOOTH), pt(1f, 1f)),
                )
            },
        ),
        VolumeOption(
            id = "overlap",
            label = "Overlap",
            build = {
                OutInCurves(
                    out = listOf(pt(0f, 1f), pt(1f, 1f), pt(1f, 0f)),
                    `in` = listOf(pt(0f, 0f), pt(0f, 1f), pt(1f, 1f)),
                )
            },
        ),
        VolumeOption(
            id = "fade-in-fade-out",
            label = "Fade in fade out",
            build = {
                OutInCurves(
                    out = listOf(pt(0f, 1f), pt(0.45f, 1f), pt(1f, 0f)),
                    `in` = listOf(pt(0f, 0f), pt(0.55f, 1f), pt(1f, 1f)),
                )
            },
        ),
        VolumeOption(
            id = "cut-in-fade-out",
            label = "Cut in fade out",
            build = {
                OutInCurves(
                    out = listOf(pt(0f, 1f), pt(1f, 0f)),
                    `in` = listOf(pt(0f, 0f), pt(0f, 1f), pt(1f, 1f)),
                )
            },
        ),
        VolumeOption(
            id = "fade-in-cut-out",
            label = "Fade in cut out",
            build = {
                OutInCurves(
                    out = listOf(pt(0f, 1f), pt(1f, 1f), pt(1f, 0f)),
                    `in` = listOf(pt(0f, 0f), pt(1f, 1f)),
                )
            },
        ),
        VolumeOption(
            id = "center-cut",
            label = "Center cut",
            build = {
                OutInCurves(
                    out = listOf(pt(0f, 1f), pt(0.5f, 1f), pt(0.5f, 0f), pt(1f, 0f)),
                    `in` = listOf(pt(0f, 0f), pt(0.5f, 0f), pt(0.5f, 1f), pt(1f, 1f)),
                )
            },
        ),
        VolumeOption(
            id = "crossfade",
            label = "Crossfade",
            build = {
                OutInCurves(
                    out = listOf(pt(0f, 1f), pt(1f, 0f)),
                    `in` = listOf(pt(0f, 0f), pt(1f, 1f)),
                )
            },
        ),
        VolumeOption(
            id = "fade-in-fast-out",
            label = "Fade in fast out",
            build = {
                OutInCurves(
                    out = listOf(pt(0f, 1f), pt(0.25f, 0f), pt(1f, 0f)),
                    `in` = listOf(pt(0f, 0f), pt(1f, 1f)),
                )
            },
        ),
        VolumeOption(
            id = "fade-in-1-bar-cut-out",
            label = "Fade in 1 bar cut out",
            build = { bars ->
                val oneBar = (1f / bars.coerceAtLeast(1).toFloat()).coerceIn(0.05f, 0.95f)
                OutInCurves(
                    out = listOf(pt(0f, 1f), pt(1f, 1f), pt(1f, 0f)),
                    `in` = listOf(pt(0f, 0f), pt(oneBar, 1f), pt(1f, 1f)),
                )
            },
        ),
        VolumeOption(
            id = "overlap-1-bar-cut-out",
            label = "Overlap 1 bar cut out",
            build = { bars ->
                val oneBar = (1f / bars.coerceAtLeast(1).toFloat()).coerceIn(0.05f, 0.95f)
                OutInCurves(
                    out = listOf(pt(0f, 1f), pt(oneBar, 1f), pt(oneBar, 0f), pt(1f, 0f)),
                    `in` = listOf(pt(0f, 0f), pt(0f, 1f), pt(1f, 1f)),
                )
            },
        ),
    )

    // -------------------------------------------------------------------------
    // EQ Options (Yellow #F59E0B)
    // -------------------------------------------------------------------------
    private fun bassSwapAt(tSwap: Float): OutInBandCurves {
        val s = Curves.clamp01(tSwap)
        return OutInBandCurves(
            out = BandCurves(
                low = listOf(pt(0f, 1f), pt(s, 1f), pt(s, 0f), pt(1f, 0f)),
                mid = flat(1f),
                high = flat(1f),
            ),
            `in` = BandCurves(
                low = listOf(pt(0f, 0f), pt(s, 0f), pt(s, 1f), pt(1f, 1f)),
                mid = flat(1f),
                high = flat(1f),
            ),
        )
    }

    val eqOptions: List<EqOption> = listOf(
        EqOption(
            id = "center-bass-swap",
            label = "Center bass swap",
            build = { bassSwapAt(0.5f) },
        ),
        EqOption(
            id = "end-bass-swap",
            label = "End bass swap",
            build = { bassSwapAt(0.97f) },
        ),
        EqOption(
            id = "start-bass-swap",
            label = "Start bass swap",
            build = { bassSwapAt(0.03f) },
        ),
        EqOption(
            id = "3-band-fade",
            label = "3-band fade",
            build = {
                OutInBandCurves(
                    out = BandCurves(
                        low = listOf(pt(0f, 1f), pt(0.33f, 0f), pt(1f, 0f)),
                        mid = listOf(pt(0f, 1f), pt(0.33f, 1f), pt(0.66f, 0f), pt(1f, 0f)),
                        high = listOf(pt(0f, 1f), pt(0.66f, 1f), pt(1f, 0f)),
                    ),
                    `in` = BandCurves(
                        low = listOf(pt(0f, 0f), pt(0.66f, 0f), pt(1f, 1f)),
                        mid = listOf(pt(0f, 0f), pt(0.33f, 0f), pt(0.66f, 1f), pt(1f, 1f)),
                        high = listOf(pt(0f, 0f), pt(0.33f, 1f), pt(1f, 1f)),
                    ),
                )
            },
        ),
        EqOption(
            id = "quick-bass-cut",
            label = "Quick bass cut",
            build = {
                OutInBandCurves(
                    out = BandCurves(
                        low = listOf(pt(0f, 1f), pt(0.15f, 0f), pt(1f, 0f)),
                        mid = flat(1f),
                        high = flat(1f),
                    ),
                    `in` = BandCurves(low = flat(1f), mid = flat(1f), high = flat(1f)),
                )
            },
        ),
        EqOption(
            id = "long-bass-cut",
            label = "Long bass cut",
            build = {
                OutInBandCurves(
                    out = BandCurves(
                        low = listOf(pt(0f, 1f), pt(0.5f, 0f), pt(1f, 0f)),
                        mid = flat(1f),
                        high = flat(1f),
                    ),
                    `in` = BandCurves(low = flat(1f), mid = flat(1f), high = flat(1f)),
                )
            },
        ),
        EqOption(
            id = "bass-fade-out",
            label = "Bass fade out",
            build = {
                OutInBandCurves(
                    out = BandCurves(
                        low = listOf(pt(0f, 1f), pt(1f, 0f)),
                        mid = flat(1f),
                        high = flat(1f),
                    ),
                    `in` = BandCurves(low = flat(1f), mid = flat(1f), high = flat(1f)),
                )
            },
        ),
        EqOption(
            id = "none",
            label = "None",
            build = {
                OutInBandCurves(
                    out = BandCurves(low = flat(1f), mid = flat(1f), high = flat(1f)),
                    `in` = BandCurves(low = flat(1f), mid = flat(1f), high = flat(1f)),
                )
            },
        ),
    )

    // -------------------------------------------------------------------------
    // Filter Options (Pink #EC4899)
    // 0.5 = flat/neutral, <0.5 = low-pass closes down, >0.5 = high-pass opens up
    // -------------------------------------------------------------------------
    val filterOptions: List<FilterOption> = listOf(
        FilterOption(
            id = "none",
            label = "None",
            build = { OutInCurves(out = flat(0.5f), `in` = flat(0.5f)) },
        ),
        FilterOption(
            id = "lpf-out",
            label = "LPF out",
            build = {
                OutInCurves(
                    out = listOf(pt(0f, 0.5f), pt(1f, 0.1f)),
                    `in` = flat(0.5f),
                )
            },
        ),
        FilterOption(
            id = "lpf-in",
            label = "LPF in",
            build = {
                OutInCurves(
                    out = flat(0.5f),
                    `in` = listOf(pt(0f, 0.1f), pt(1f, 0.5f)),
                )
            },
        ),
        FilterOption(
            id = "lpf-in-lpf-out",
            label = "LPF in LPF out",
            build = {
                OutInCurves(
                    out = listOf(pt(0f, 0.5f), pt(1f, 0.1f)),
                    `in` = listOf(pt(0f, 0.1f), pt(1f, 0.5f)),
                )
            },
        ),
        FilterOption(
            id = "lpf-in-hpf-out",
            label = "LPF in HPF out",
            build = {
                OutInCurves(
                    out = listOf(pt(0f, 0.5f), pt(0.5f, 0.5f), pt(1f, 0.95f)),
                    `in` = listOf(pt(0f, 0.05f), pt(0.5f, 0.5f), pt(1f, 0.5f)),
                )
            },
        ),
        FilterOption(
            id = "hpf-out",
            label = "HPF out",
            build = {
                OutInCurves(
                    out = listOf(pt(0f, 0.5f), pt(1f, 0.9f)),
                    `in` = flat(0.5f),
                )
            },
        ),
        FilterOption(
            id = "hpf-in",
            label = "HPF in",
            build = {
                OutInCurves(
                    out = flat(0.5f),
                    `in` = listOf(pt(0f, 0.9f), pt(1f, 0.5f)),
                )
            },
        ),
        FilterOption(
            id = "hpf-in-hpf-out",
            label = "HPF in HPF out",
            build = {
                OutInCurves(
                    out = listOf(pt(0f, 0.5f), pt(1f, 0.9f)),
                    `in` = listOf(pt(0f, 0.9f), pt(1f, 0.5f)),
                )
            },
        ),
        FilterOption(
            id = "hpf-in-lpf-out",
            label = "HPF in LPF out",
            build = {
                OutInCurves(
                    out = listOf(pt(0f, 0.5f), pt(1f, 0.1f)),
                    `in` = listOf(pt(0f, 0.9f), pt(1f, 0.5f)),
                )
            },
        ),
        FilterOption(
            id = "hpf-half-out",
            label = "HPF half out",
            build = {
                OutInCurves(
                    out = listOf(pt(0f, 0.5f), pt(0.5f, 0.5f), pt(1f, 0.8f)),
                    `in` = flat(0.5f),
                )
            },
        ),
        FilterOption(
            id = "noise-out-end",
            label = "Noise out end",
            build = {
                OutInCurves(
                    out = listOf(pt(0f, 0.5f), pt(0.75f, 0.5f), pt(1f, 0.98f)),
                    `in` = flat(0.5f),
                )
            },
        ),
    )

    // -------------------------------------------------------------------------
    // Effects Options (White #FFFFFF)
    // Applied to the outgoing track wet send
    // -------------------------------------------------------------------------
    val effectsOptions: List<EffectsOption> = listOf(
        EffectsOption(
            id = "none",
            label = "None",
            type = null,
            echoBeats = null,
            tail = TailMode.CUT,
            curve = flat(0f),
        ),
        EffectsOption(
            id = "reverb-out-center",
            label = "Reverb out center",
            type = EffectType.REVERB,
            echoBeats = null,
            tail = TailMode.RING,
            curve = listOf(pt(0f, 0f), pt(0.5f, 1f), pt(1f, 0f)),
        ),
        EffectsOption(
            id = "reverb-cut-end",
            label = "Reverb cut end",
            type = EffectType.REVERB,
            echoBeats = null,
            tail = TailMode.CUT,
            curve = listOf(pt(0f, 0f), pt(1f, 1f)),
        ),
        EffectsOption(
            id = "reverb-out-end",
            label = "Reverb out end",
            type = EffectType.REVERB,
            echoBeats = null,
            tail = TailMode.RING,
            curve = listOf(pt(0f, 0f), pt(0.8f, 1f), pt(1f, 0f)),
        ),
        EffectsOption(
            id = "echo-half-cut-end",
            label = "Echo 1/2 cut end",
            type = EffectType.ECHO,
            echoBeats = 0.5f,
            tail = TailMode.CUT,
            curve = listOf(pt(0f, 0f), pt(1f, 1f)),
        ),
        EffectsOption(
            id = "echo-half-out-end",
            label = "Echo 1/2 out end",
            type = EffectType.ECHO,
            echoBeats = 0.5f,
            tail = TailMode.RING,
            curve = listOf(pt(0f, 0f), pt(0.75f, 0.9f), pt(1f, 0f)),
        ),
        EffectsOption(
            id = "echo-3q-cut-end",
            label = "Echo 3/4 cut end",
            type = EffectType.ECHO,
            echoBeats = 0.75f,
            tail = TailMode.CUT,
            curve = listOf(pt(0f, 0f), pt(1f, 1f)),
        ),
        EffectsOption(
            id = "echo-3q-out-end",
            label = "Echo 3/4 out end",
            type = EffectType.ECHO,
            echoBeats = 0.75f,
            tail = TailMode.RING,
            curve = listOf(pt(0f, 0f), pt(0.75f, 0.9f), pt(1f, 0f)),
        ),
        EffectsOption(
            id = "echo-1-cut-end",
            label = "Echo 1 cut end",
            type = EffectType.ECHO,
            echoBeats = 1.0f,
            tail = TailMode.CUT,
            curve = listOf(pt(0f, 0f), pt(1f, 1f)),
        ),
        EffectsOption(
            id = "echo-1-out-end",
            label = "Echo 1 out end",
            type = EffectType.ECHO,
            echoBeats = 1.0f,
            tail = TailMode.RING,
            curve = listOf(pt(0f, 0f), pt(0.75f, 0.9f), pt(1f, 0f)),
        ),
    )

    // -------------------------------------------------------------------------
    // Looping Options (Orange #F97316)
    // -------------------------------------------------------------------------
    val loopingOptions: List<LoopingOption> = listOf(
        LoopingOption(id = "none", label = "None", beats = 0),
        LoopingOption(id = "1-beat", label = "1 beat", beats = 1),
        LoopingOption(id = "2-beat", label = "2 beats", beats = 2),
        LoopingOption(id = "4-beat", label = "4 beats", beats = 4),
        LoopingOption(id = "8-beat", label = "8 beats", beats = 8),
        LoopingOption(id = "16-beat", label = "16 beats", beats = 16),
    )

    fun findVolumeOption(id: String): VolumeOption =
        volumeOptions.firstOrNull { it.id == id } ?: volumeOptions[0]

    fun findEqOption(id: String): EqOption =
        eqOptions.firstOrNull { it.id == id } ?: eqOptions[0]

    fun findFilterOption(id: String): FilterOption =
        filterOptions.firstOrNull { it.id == id } ?: filterOptions[0]

    fun findEffectsOption(id: String): EffectsOption =
        effectsOptions.firstOrNull { it.id == id } ?: effectsOptions[0]

    fun findLoopingOption(beats: Int): LoopingOption =
        loopingOptions.firstOrNull { it.beats == beats } ?: loopingOptions[0]
}
