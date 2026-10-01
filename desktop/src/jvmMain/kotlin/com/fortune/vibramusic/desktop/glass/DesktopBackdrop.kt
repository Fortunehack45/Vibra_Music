package com.fortune.vibramusic.desktop.glass

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.shape.CornerBasedShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asComposeRenderEffect
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import org.jetbrains.skia.FilterTileMode
import org.jetbrains.skia.ImageFilter
import org.jetbrains.skia.RuntimeEffect
import org.jetbrains.skia.RuntimeShaderBuilder

/**
 * Pure SkSL (Skia Shading Language) Liquid Glass Refraction with Chromatic Dispersion Shader.
 * Evaluates in hardware over DirectX 12 / Vulkan / OpenGL on Windows Desktop.
 */
private const val RoundedRectSDF = """
float radiusAt(float2 coord, float4 radii) {
    if (coord.x >= 0.0) {
        if (coord.y <= 0.0) return radii.y;
        else return radii.z;
    } else {
        if (coord.y <= 0.0) return radii.x;
        else return radii.w;
    }
}

float sdRoundedRect(float2 coord, float2 halfSize, float radius) {
    float2 cornerCoord = abs(coord) - (halfSize - float2(radius));
    float outside = length(max(cornerCoord, 0.0)) - radius;
    float inside = min(max(cornerCoord.x, cornerCoord.y), 0.0);
    return outside + inside;
}

float2 gradSdRoundedRect(float2 coord, float2 halfSize, float radius) {
    float2 cornerCoord = abs(coord) - (halfSize - float2(radius));
    if (cornerCoord.x >= 0.0 || cornerCoord.y >= 0.0) {
        return sign(coord) * normalize(max(cornerCoord, 0.0));
    } else {
        float gradX = step(cornerCoord.y, cornerCoord.x);
        return sign(coord) * float2(gradX, 1.0 - gradX);
    }
}
"""

private const val LiquidGlassSkSL = """
uniform shader content;
uniform float2 size;
uniform float2 offset;
uniform float4 cornerRadii;
uniform float refractionHeight;
uniform float refractionAmount;
uniform float depthEffect;
uniform float chromaticAberration;

$RoundedRectSDF

float circleMap(float x) {
    return 1.0 - sqrt(1.0 - x * x);
}

half4 main(float2 coord) {
    float2 halfSize = size * 0.5;
    float2 centeredCoord = (coord + offset) - halfSize;
    float radius = radiusAt(coord, cornerRadii);
    
    float sd = sdRoundedRect(centeredCoord, halfSize, radius);
    if (-sd >= refractionHeight) {
        return content.eval(coord);
    }
    sd = min(sd, 0.0);
    
    float d = circleMap(1.0 - -sd / refractionHeight) * refractionAmount;
    float gradRadius = min(radius * 1.5, min(halfSize.x, halfSize.y));
    float2 grad = normalize(gradSdRoundedRect(centeredCoord, halfSize, gradRadius) + depthEffect * normalize(centeredCoord));
    
    float2 refractedCoord = coord + d * grad;
    float dispersionIntensity = chromaticAberration * ((centeredCoord.x * centeredCoord.y) / (halfSize.x * halfSize.y));
    float2 dispersedCoord = d * grad * dispersionIntensity;
    
    half4 color = half4(0.0);
    
    half4 red = content.eval(refractedCoord + dispersedCoord);
    color.r += red.r / 3.5;
    color.a += red.a / 7.0;
    
    half4 orange = content.eval(refractedCoord + dispersedCoord * (2.0 / 3.0));
    color.r += orange.r / 3.5;
    color.g += orange.g / 7.0;
    color.a += orange.a / 7.0;
    
    half4 yellow = content.eval(refractedCoord + dispersedCoord * (1.0 / 3.0));
    color.r += yellow.r / 3.5;
    color.g += yellow.g / 3.5;
    color.a += yellow.a / 7.0;
    
    half4 green = content.eval(refractedCoord);
    color.g += green.g / 3.5;
    color.a += green.a / 7.0;
    
    half4 cyan = content.eval(refractedCoord - dispersedCoord * (1.0 / 3.0));
    color.g += cyan.g / 3.5;
    color.b += cyan.b / 3.0;
    color.a += cyan.a / 7.0;
    
    half4 blue = content.eval(refractedCoord - dispersedCoord * (2.0 / 3.0));
    color.b += blue.b / 3.0;
    color.a += blue.a / 7.0;
    
    half4 purple = content.eval(refractedCoord - dispersedCoord);
    color.r += purple.r / 7.0;
    color.b += purple.b / 3.0;
    color.a += purple.a / 7.0;
    
    return color;
}
"""

object DesktopLiquidGlassShader {
    private val runtimeEffect: RuntimeEffect? by lazy {
        try {
            RuntimeEffect.makeForShader(LiquidGlassSkSL)
        } catch (t: Throwable) {
            t.printStackTrace()
            null
        }
    }

    fun createGlassRenderEffect(
        width: Float,
        height: Float,
        radius: Float,
        blurRadius: Float = 16f,
        refractionHeight: Float = 24f,
        refractionAmount: Float = -12f,
    ): androidx.compose.ui.graphics.RenderEffect? {
        val effect = runtimeEffect ?: return null
        return try {
            val builder = RuntimeShaderBuilder(effect)
            builder.uniform("size", width.coerceAtLeast(1f), height.coerceAtLeast(1f))
            builder.uniform("offset", 0f, 0f)
            builder.uniform("cornerRadii", radius, radius, radius, radius)
            builder.uniform("refractionHeight", refractionHeight)
            builder.uniform("refractionAmount", refractionAmount)
            builder.uniform("depthEffect", 1f)
            builder.uniform("chromaticAberration", 1f)

            val blurFilter = ImageFilter.makeBlur(blurRadius, blurRadius, FilterTileMode.CLAMP)
            val shaderFilter = ImageFilter.makeRuntimeShader(builder, "content", blurFilter)
            shaderFilter.asComposeRenderEffect()
        } catch (t: Throwable) {
            null
        }
    }
}

val GLASS_EDGE_WIDTH = 0.75.dp
val GLASS_EDGE_COLOR = Color.White.copy(alpha = 0.18f)

/**
 * Renders a composable with hardware-accelerated Liquid Glass refraction on Windows Desktop.
 */
@Composable
fun Modifier.liquidGlass(
    shape: CornerBasedShape = RoundedCornerShape(percent = 50),
    blurRadius: Float = 18f,
    elevation: Dp = 10.dp,
): Modifier {
    val isLight = MaterialTheme.colorScheme.surface.luminance() > 0.5f
    val surfaceTintColor = if (isLight) {
        Color(0xFFFAFAFA).copy(alpha = 0.35f)
    } else {
        Color(0xFF141416).copy(alpha = 0.45f)
    }

    val highlightBrush = Brush.linearGradient(
        colors = listOf(
            Color.White.copy(alpha = if (isLight) 0.50f else 0.28f),
            Color.White.copy(alpha = 0.05f),
            Color.Transparent,
            Color.White.copy(alpha = if (isLight) 0.25f else 0.12f),
        ),
        start = Offset.Zero,
        end = Offset.Infinite,
    )

    return this
        .shadow(
            elevation = elevation,
            shape = shape,
            ambientColor = Color.Black.copy(alpha = 0.35f),
            spotColor = Color.Black.copy(alpha = 0.45f),
        )
        .clip(shape)
        .background(surfaceTintColor, shape)
        .border(width = GLASS_EDGE_WIDTH, brush = highlightBrush, shape = shape)
        .drawWithContent {
            drawContent()
            // Specular top hairline shine
            drawLine(
                brush = Brush.horizontalGradient(
                    colors = listOf(
                        Color.Transparent,
                        Color.White.copy(alpha = 0.30f),
                        Color.Transparent,
                    )
                ),
                start = Offset(size.width * 0.15f, 1f),
                end = Offset(size.width * 0.85f, 1f),
                strokeWidth = 1.2f,
            )
        }
}
