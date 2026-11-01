package com.fortune.vibramusic.ui.player

import android.view.Window
import android.view.WindowManager
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.spring
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.SheetState
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.platform.WindowInfo
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import com.fortune.vibramusic.ui.components.MiniPlayerPull
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.math.abs

/** M3's own scrim strength, which the player's dim stands in for. */
const val PLAYER_SCRIM_ALPHA = 0.32f

/**
 * The player sheet's shape: square, reaching a whole sheet's height above the sheet's top edge.
 */
object PlayerSheetShape : Shape {
    override fun createOutline(size: Size, layoutDirection: LayoutDirection, density: Density): Outline =
        Outline.Rectangle(Rect(0f, -size.height, size.width, size.height))
}

/**
 * The spring every open and close runs on: critically damped, so it never
 * bounces, with about 0.45s of response.
 */
private const val SLIDE_STIFFNESS = 195f
private const val SLIDE_SETTLED_PX = 0.5f
private const val SHEET_VELOCITY_FRESH_MS = 80f
private const val LAYOUT_WAIT_MS = 300L
private const val WINDOW_ENTER_MS = 600L

@OptIn(ExperimentalMaterial3Api::class)
@Stable
class PlayerSheetMotion(
    private val scope: CoroutineScope,
    private val dock: PlayerDock,
    private val shown: () -> Boolean,
    private val setShown: (Boolean) -> Unit,
) : MiniPlayerPull {
    /** NaN while the sheet stands where M3 put it. */
    var held by mutableFloatStateOf(Float.NaN)
        private set

    val holding: Boolean get() = !held.isNaN()

    /** The sheet, while it is up. Set by the host. */
    var sheet: SheetState? = null

    private var window: Window? = null
    private var windowAnimations = 0
    private var windowRestore: Job? = null

    private var pullStartNanos = 0L
    private var pullStartAt = 0f

    private var sheetSampleAt = Float.NaN
    private var sheetSampleNanos = 0L
    private var sheetVelocity = 0f

    /** Set by the host once the sheet has been laid out at all. */
    var laidOut by mutableStateOf(false)

    var windowInfo: WindowInfo? = null
    var flingVelocity = 0f

    private var settle: Job? = null
    private var closing = false

    private fun travel(): Float =
        dock.sheetTravel.takeIf { it > 0f } ?: (windowInfo?.containerSize?.height ?: 0).toFloat()

    private fun sheetOffset(): Float = try {
        sheet?.requireOffset() ?: Float.NaN
    } catch (_: IllegalStateException) {
        Float.NaN
    }

    fun position(): Float = if (holding) held else sheetOffset()

    fun contentOffsetPx(): Int {
        val target = held
        val sheetAt = sheetOffset().takeUnless { it.isNaN() } ?: 0f
        if (target.isNaN()) {
            sampleSheet(sheetAt)
            return 0
        }
        return target.toInt() - sheetAt.toInt()
    }

    private fun sampleSheet(at: Float) {
        val now = System.nanoTime()
        if (!sheetSampleAt.isNaN()) {
            val seconds = (now - sheetSampleNanos) / 1e9f
            if (seconds > 0f) {
                val instant = (at - sheetSampleAt) / seconds
                sheetVelocity = sheetVelocity * 0.4f + instant * 0.6f
            }
        }
        sheetSampleAt = at
        sheetSampleNanos = now
    }

    private fun recentSheetVelocity(): Float =
        if ((System.nanoTime() - sheetSampleNanos) / 1e6f < SHEET_VELOCITY_FRESH_MS) sheetVelocity else 0f

    fun open() {
        if (shown()) {
            if (closing && holding) {
                settle?.cancel()
                reopening()
                val from = held
                settle = scope.launch {
                    slide(from = from, to = 0f)
                    held = Float.NaN
                }
            }
            return
        }
        settle?.cancel()
        closing = false
        val travel = travel()
        held = travel
        setShown(true)
        settle = scope.launch {
            withTimeoutOrNull(LAYOUT_WAIT_MS) { snapshotFlow { laidOut }.first { it } }
            slide(from = travel, to = 0f)
            held = Float.NaN
        }
    }

    fun attachWindow(window: Window?) {
        this.window = window ?: return
        windowAnimations = window.attributes.windowAnimations
        window.setWindowAnimations(0)
        windowRestore?.cancel()
        windowRestore = scope.launch {
            delay(WINDOW_ENTER_MS)
            window.setWindowAnimations(windowAnimations)
        }
    }

    private fun quietWindow() {
        windowRestore?.cancel()
        window?.setWindowAnimations(0)
    }

    private fun passTouchesThrough(pass: Boolean) {
        val window = window ?: return
        if (pass) {
            window.addFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE)
        }
    }

    private fun reopening() {
        closing = false
        passTouchesThrough(false)
        window?.setWindowAnimations(windowAnimations)
    }

    fun close() {
        if (!shown() || closing) return
        closing = true
        quietWindow()
        passTouchesThrough(true)
        settle?.cancel()
        val from = position().takeUnless { it.isNaN() } ?: run {
            dismissQuietly()
            return
        }
        val velocity = if (holding) 0f else recentSheetVelocity()
        held = from
        settle = scope.launch {
            slide(from = from, to = travel(), velocity = velocity.coerceAtLeast(0f))
            dismissQuietly()
        }
    }

    override fun drag(delta: Float) {
        if (!holding) {
            if (delta >= 0f || shown()) return
            settle?.cancel()
            closing = false
            held = travel()
            pullStartAt = held
            pullStartNanos = System.nanoTime()
            setShown(true)
        }
        settle?.cancel()
        held = (held + delta).coerceIn(0f, travel())
    }

    override fun release(velocity: Float) {
        if (!holding) return
        val travel = travel()
        val seconds = (System.nanoTime() - pullStartNanos) / 1e9f
        val average = if (seconds > 0f) (held - pullStartAt) / seconds else 0f
        val speed = if (abs(average) > abs(velocity)) average else velocity
        val flick = abs(speed) >= flingVelocity
        val open = if (flick) speed < 0f else held < travel / 2f
        if (!open) {
            closing = true
            quietWindow()
            passTouchesThrough(true)
        } else if (closing) {
            reopening()
        }
        val from = held
        settle = scope.launch {
            slide(from = from, to = if (open) 0f else travel, velocity = speed)
            if (open) held = Float.NaN else dismissQuietly()
        }
    }

    fun onSheetGone() {
        closing = false
        sheetSampleAt = Float.NaN
        sheetVelocity = 0f
        settle?.cancel()
        windowRestore?.cancel()
        held = Float.NaN
        laidOut = false
        sheet = null
        window = null
    }

    private suspend fun slide(from: Float, to: Float, velocity: Float = 0f) {
        val travel = travel()
        animate(
            initialValue = from,
            targetValue = to,
            initialVelocity = velocity,
            animationSpec = spring(
                dampingRatio = Spring.DampingRatioNoBouncy,
                stiffness = SLIDE_STIFFNESS,
                visibilityThreshold = SLIDE_SETTLED_PX,
            ),
        ) { value, _ ->
            held = value.coerceIn(0f, travel)
        }
    }

    private fun dismissQuietly() {
        quietWindow()
        setShown(false)
    }
}
