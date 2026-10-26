package com.fortune.vibramusic.playback.mix

import kotlinx.serialization.Serializable

/**
 * Interpolation mode for the segment starting at a point and extending to the next point.
 */
@Serializable
enum class CurveType {
    LINEAR,
    SMOOTH,
}

/**
 * An immutable point on a lane's automation curve.
 *
 * @property id Stable identifier so dragging preserves identity even during re-sorting.
 * @property t Normalized position across the transition window in range [0.0, 1.0].
 * @property v Normalized lane parameter value in range [0.0, 1.0].
 * @property curve Interpolation mode for the segment starting at this point.
 */
@Serializable
data class Point(
    val id: String,
    val t: Float,
    val v: Float,
    val curve: CurveType = CurveType.LINEAR,
)

/**
 * Three-band curves for an equalizer lane (Low, Mid, High).
 */
@Serializable
data class BandCurves(
    val low: List<Point>,
    val mid: List<Point>,
    val high: List<Point>,
)

/**
 * The five interactive automation lanes in the Mix system.
 */
@Serializable
enum class LaneId(val wireKey: String) {
    VOLUME("volume"),
    EQ("eq"),
    FILTER("filter"),
    EFFECTS("effects"),
    LOOPING("looping"),
}

@Serializable
enum class EffectType {
    REVERB,
    ECHO,
}

@Serializable
enum class TailMode {
    CUT,
    RING,
}
