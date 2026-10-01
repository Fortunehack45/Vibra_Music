package com.fortune.vibramusic.desktop.glass

import androidx.compose.ui.graphics.asComposeRenderEffect
import org.jetbrains.skia.FilterTileMode
import org.jetbrains.skia.ImageFilter
import org.jetbrains.skia.RuntimeEffect
import org.jetbrains.skia.RuntimeShaderBuilder

object DesktopGlassEngine {
    private const val ShaderCode = """
        uniform shader content;
        uniform float2 size;
        half4 main(float2 coord) {
            return content.eval(coord);
        }
    """

    fun testRuntimeShader(): Boolean {
        return try {
            val effect = RuntimeEffect.makeForShader(ShaderCode)
            val builder = RuntimeShaderBuilder(effect)
            builder.uniform("size", 100f, 100f)
            val blur = ImageFilter.makeBlur(8f, 8f, FilterTileMode.CLAMP)
            val shaderFilter = ImageFilter.makeRuntimeShader(builder, "content", blur)
            val renderEffect = shaderFilter.asComposeRenderEffect()
            renderEffect != null
        } catch (e: Throwable) {
            e.printStackTrace()
            false
        }
    }
}
