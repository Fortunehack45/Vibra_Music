package com.fortune.vibramusic.ui.player

import androidx.compose.runtime.Stable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.toSize

/**
 * The mini player the expanded player docks into.
 *
 * Opening and closing the player is one movement on screen: the sheet's
 * artwork travels between its own place and the mini player's cover while the
 * rest of the player fades.
 */
@Stable
class PlayerDock {
    private var miniArt: LayoutCoordinates? = null
    private var miniArtCorner: Dp = 8.dp

    /**
     * How far the player sheet sits below fully open, in pixels. Set by the
     * host while the sheet is up, null while it is not.
     */
    var sheetOffset: (() -> Float)? by mutableStateOf(null)

    /** How far the sheet travels from fully open to gone, in pixels. */
    var sheetTravel by mutableFloatStateOf(0f)

    /** Whether the player on screen takes part in docking. */
    var attached by mutableStateOf(false)
        internal set

    /** Reported by the mini player's cover whenever it is placed. */
    fun reportMiniArt(coordinates: LayoutCoordinates, corner: Dp) {
        miniArt = coordinates
        miniArtCorner = corner
    }

    /** From the cover leaving composition, so a stale rect is never flown to. */
    fun releaseMiniArt(coordinates: LayoutCoordinates) {
        if (miniArt === coordinates) miniArt = null
    }

    internal fun hasMiniArt(): Boolean = miniArt?.isAttached == true

    internal fun miniArtOnScreen(): Rect? {
        val coordinates = miniArt?.takeIf { it.isAttached } ?: return null
        val size = coordinates.size.toSize()
        return Rect(
            coordinates.localToScreen(Offset.Zero),
            coordinates.localToScreen(Offset(size.width, size.height)),
        )
    }

    internal fun miniArtCorner(): Dp = miniArtCorner

    internal fun offset(): Float? = sheetOffset?.invoke()?.takeUnless { it.isNaN() }

    /**
     * 1 with the player fully open, 0 down on the mini player.
     */
    fun openFraction(): Float {
        val travel = sheetTravel
        val offset = offset() ?: return 0f
        if (travel <= 0f) return 0f
        return (1f - offset / travel).coerceIn(0f, 1f)
    }

    /**
     * Whether the mini player's own cover should stand aside while the player
     * is moving to/from it.
     */
    val coversMiniArt: Boolean
        get() = coversMiniArtState.value

    private val coversMiniArtState = derivedStateOf { attached && openFraction() > 0f }
}

val LocalPlayerDock = staticCompositionLocalOf<PlayerDock?> { null }
