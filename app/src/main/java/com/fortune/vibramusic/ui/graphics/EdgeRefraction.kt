package com.fortune.vibramusic.ui.graphics

import android.graphics.RenderEffect
import android.graphics.RuntimeShader
import android.os.Build
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asComposeRenderEffect
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.fortune.vibramusic.data.settings.AppSettings

private const val EDGE_REFRACTION_SHADER = """
    uniform shader content;
    uniform float2 size;
    uniform float edge;
    uniform float pull;
    uniform float lift;
    uniform float chroma;
    uniform float smear;
    uniform float leftOn;
    uniform float rightOn;

    half4 main(float2 p) {
        if (p.x < 0.0 || p.x > size.x || p.y < 0.0 || p.y > size.y) {
            return half4(0.0);
        }
        float w = size.x;
        float tl = (1.0 - clamp(p.x / edge, 0.0, 1.0)) * leftOn;
        float tr = (1.0 - clamp((w - p.x) / edge, 0.0, 1.0)) * rightOn;
        float t = max(tl, tr);
        if (t <= 0.0) { return content.eval(p); }
        float dir = tl > tr ? 1.0 : -1.0;
        float k = t * t * (3.0 - 2.0 * t);
        float inner = dir > 0.0 ? edge : w - edge;
        float2 q = float2(mix(p.x, inner, k * pull), 0.0);
        float cy = size.y * 0.5;
        q.y = cy + (p.y - cy) / (1.0 + lift * k);
        float ca = chroma * k * dir;
        float bl = smear * k;
        half4 acc = half4(0.0);
        for (int i = -2; i <= 2; i++) {
            acc += content.eval(q + float2(float(i) * bl * 0.5, 0.0));
        }
        acc *= 0.2;
        acc.r = mix(acc.r, content.eval(q + float2(ca, 0.0)).r, 0.2);
        acc.b = mix(acc.b, content.eval(q - float2(ca, 0.0)).b, 0.2);
        acc.rgb += half3(0.05 * k * k) * acc.a;
        return acc;
    }
"""

/**
 * Optical edge refraction for horizontal lists: creates a curved, liquid glass effect
 * at the screen edges as items scroll in or out.
 *
 * Items passing the active edges are gently pulled inward, magnified vertically, smeared,
 * and subtly split with chromatic aberration. When an edge has reached the end of its list,
 * it stays clear so items at rest remain crisp and distortion-free.
 */
@Composable
fun Modifier.edgeRefraction(
    state: LazyListState? = null,
    edgeFraction: Float = 0.18f,
    pull: Float = 0.62f,
    liftFraction: Float = 0.16f,
    chromaDp: Float = 3.5f,
    smearDp: Float = 6f,
): Modifier {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return this

    val enabled by AppSettings.horizontalScrollRefraction.collectAsStateWithLifecycle()
    val reduceAnimation by AppSettings.reduceAnimation.collectAsStateWithLifecycle()
    if (!enabled || reduceAnimation) return this

    val density = LocalDensity.current.density
    val left by animateFloatAsState(
        targetValue = if (state == null || state.canScrollBackward) 1f else 0f,
        animationSpec = tween(260),
        label = "edgeRefractionLeft",
    )
    val right by animateFloatAsState(
        targetValue = if (state == null || state.canScrollForward) 1f else 0f,
        animationSpec = tween(260),
        label = "edgeRefractionRight",
    )

    val shader = remember { RuntimeShader(EDGE_REFRACTION_SHADER) }
    val cache = remember { arrayOfNulls<Any>(2) }

    return this.graphicsLayer {
        clip = true
        val s = size
        if (s.width <= 0f || s.height <= 0f) return@graphicsLayer
        if (left <= 0.001f && right <= 0.001f) {
            renderEffect = null
            return@graphicsLayer
        }

        val key = listOf(s.width, s.height, left, right)
        if (cache[0] != key) {
            shader.setFloatUniform("size", s.width, s.height)
            shader.setFloatUniform("edge", s.width * edgeFraction)
            shader.setFloatUniform("pull", pull)
            shader.setFloatUniform("lift", liftFraction)
            shader.setFloatUniform("chroma", chromaDp * density)
            shader.setFloatUniform("smear", smearDp * density)
            shader.setFloatUniform("leftOn", left)
            shader.setFloatUniform("rightOn", right)
            cache[0] = key
            cache[1] = RenderEffect.createRuntimeShaderEffect(shader, "content").asComposeRenderEffect()
        }

        renderEffect = cache[1] as? androidx.compose.ui.graphics.RenderEffect
    }
}

/**
 * A gentler edge glass refraction with approximately half the distortion strength.
 */
@Composable
fun Modifier.gentleEdgeRefraction(state: LazyListState?): Modifier =
    edgeRefraction(
        state = state,
        edgeFraction = 0.13f,
        pull = 0.38f,
        liftFraction = 0.08f,
        chromaDp = 2f,
        smearDp = 3f,
    )
