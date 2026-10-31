package com.fortune.vibramusic.ui.components

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onPlaced

/**
 * Records where the three-dots button sits in window coordinates so the floating
 * Liquid Glass popover menu can hang directly off that button.
 */
object MenuAnchor {
    private var bounds: Rect? = null
    private var recordedAt = 0L

    internal fun record(bounds: Rect) {
        this.bounds = bounds
        recordedAt = System.nanoTime()
    }

    /** The button this opening was a tap on, in window coordinates, or null. */
    fun consume(): Rect? {
        val anchor = bounds?.takeIf { System.nanoTime() - recordedAt < FRESH_NANOS }
        bounds = null
        return anchor
    }

    private const val FRESH_NANOS = 3_000_000_000L
}

/**
 * Marks a button as the anchor for a floating menu.
 */
@Composable
fun Modifier.menuAnchor(): Modifier {
    val anchor = remember { AnchorCoordinates() }
    return this
        .onPlaced { anchor.coordinates = it }
        .pointerInput(Unit) {
            awaitEachGesture {
                awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                anchor.coordinates?.takeIf { it.isAttached }?.let { MenuAnchor.record(it.boundsInWindow()) }
            }
        }
}

private class AnchorCoordinates {
    var coordinates: LayoutCoordinates? = null
}
