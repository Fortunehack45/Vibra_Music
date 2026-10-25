package com.fortune.vibramusic.ui.lyrics

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import androidx.core.content.res.ResourcesCompat
import androidx.core.graphics.ColorUtils
import androidx.palette.graphics.Palette
import coil3.SingletonImageLoader
import coil3.request.ImageRequest
import coil3.request.SuccessResult
import coil3.request.allowHardware
import coil3.toBitmap
import com.fortune.vibramusic.R
import com.fortune.vibramusic.data.model.artworkAt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

object LyricPosterRenderer {

    const val POSTER_WIDTH = 1080
    const val POSTER_HEIGHT = 1080

    suspend fun render(
        context: Context,
        config: LyricShareConfig,
    ): Bitmap = withContext(Dispatchers.IO) {
        val mainTypeface = resolveTypeface(context, config.font)

        val posterWidth = config.ratio.width
        val posterHeight = config.ratio.height

        val bitmap = Bitmap.createBitmap(posterWidth, posterHeight, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)

        val artSource = config.song.thumbnailUrl ?: config.song.localUri
        val coverArt = artSource?.let { loadBitmap(context, it) }?.let { ensureSoftwareBitmap(it) }

        val (topColor, bottomColor) = resolveColors(config.palette, coverArt)

        when (config.cardStyle) {
            LyricCardStyle.LYRICS_CARD -> drawLyricsCard(
                context = context,
                canvas = canvas,
                config = config,
                coverArt = coverArt,
                typeface = mainTypeface,
                posterWidth = posterWidth,
                posterHeight = posterHeight,
                topColor = topColor,
                bottomColor = bottomColor,
            )
            LyricCardStyle.SONG_CARD -> {
                // Background for song card
                val bgTop = ColorUtils.blendARGB(topColor, Color.BLACK, 0.28f)
                val bgBottom = ColorUtils.blendARGB(bottomColor, Color.BLACK, 0.42f)
                val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    shader = LinearGradient(
                        0f, 0f, 0f, posterHeight.toFloat(),
                        intArrayOf(
                            bgTop,
                            ColorUtils.blendARGB(bgTop, bgBottom, 0.55f),
                            bgBottom,
                        ),
                        floatArrayOf(0f, 0.58f, 1f),
                        Shader.TileMode.CLAMP,
                    )
                }
                canvas.drawRect(0f, 0f, posterWidth.toFloat(), posterHeight.toFloat(), bgPaint)

                drawSongCard(
                    context = context,
                    canvas = canvas,
                    config = config,
                    coverArt = coverArt,
                    typeface = mainTypeface,
                    posterWidth = posterWidth,
                    posterHeight = posterHeight,
                )
            }
        }

        bitmap
    }

    private fun drawDarkenedCoverSurface(
        canvas: Canvas,
        coverArt: Bitmap,
        rect: RectF,
        cornerRadius: Float,
    ) {
        val shader = BitmapShader(coverArt, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
        val matrix = Matrix()
        val scale = maxOf(
            rect.width() / coverArt.width.toFloat().coerceAtLeast(1f),
            rect.height() / coverArt.height.toFloat().coerceAtLeast(1f),
        )
        matrix.setScale(scale, scale)
        val transX = rect.left - (coverArt.width * scale - rect.width()) / 2f
        val transY = rect.top - (coverArt.height * scale - rect.height()) / 2f
        matrix.postTranslate(transX, transY)
        shader.setLocalMatrix(matrix)

        val artPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG).apply {
            this.shader = shader
            isFilterBitmap = true
            isDither = true
        }
        if (cornerRadius > 0f) {
            canvas.drawRoundRect(rect, cornerRadius, cornerRadius, artPaint)
        } else {
            canvas.drawRect(rect, artPaint)
        }

        val scrimPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(175, 12, 12, 16)
        }
        if (cornerRadius > 0f) {
            canvas.drawRoundRect(rect, cornerRadius, cornerRadius, scrimPaint)
        } else {
            canvas.drawRect(rect, scrimPaint)
        }
    }

    private fun drawBrandBadge(
        context: Context,
        canvas: Canvas,
        typeface: Typeface,
        x: Float,
        y: Float,
        iconSize: Float = 36f,
        textSize: Float = 26f,
        color: Int = Color.WHITE,
        alpha: Int = 220,
    ) {
        val logo = runCatching {
            ResourcesCompat.getDrawable(context.resources, R.drawable.ic_logo, null)
        }.getOrNull()

        val r = Color.red(color)
        val g = Color.green(color)
        val b = Color.blue(color)

        if (logo != null) {
            logo.setTint(Color.argb(alpha, r, g, b))
            logo.setBounds(
                x.toInt(),
                y.toInt(),
                (x + iconSize).toInt(),
                (y + iconSize).toInt(),
            )
            logo.draw(canvas)
        }

        val brandPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.typeface = typeface
            this.textSize = textSize
            this.color = Color.argb(alpha, r, g, b)
            letterSpacing = 0.04f
        }
        val fontMetrics = brandPaint.fontMetrics
        val textY = y + (iconSize / 2f) - ((fontMetrics.ascent + fontMetrics.descent) / 2f)
        canvas.drawText("Vibra Music", x + iconSize + 14f, textY, brandPaint)
    }

    private fun drawLyricsCard(
        context: Context,
        canvas: Canvas,
        config: LyricShareConfig,
        coverArt: Bitmap?,
        typeface: Typeface,
        posterWidth: Int,
        posterHeight: Int,
        topColor: Int,
        bottomColor: Int,
    ) {
        val lines = config.selectedLines.take(5)
        if (lines.isEmpty()) return

        if (config.ratio == LyricCardRatio.SQUARE_1_1) {
            drawSquareLyricsCard(
                context = context,
                canvas = canvas,
                config = config,
                lines = lines,
                coverArt = coverArt,
                typeface = typeface,
                posterWidth = posterWidth,
                posterHeight = posterHeight,
                topColor = topColor,
                bottomColor = bottomColor,
            )
        } else {
            drawStoryLyricsCard(
                context = context,
                canvas = canvas,
                config = config,
                lines = lines,
                coverArt = coverArt,
                typeface = typeface,
                posterWidth = posterWidth,
                posterHeight = posterHeight,
                topColor = topColor,
                bottomColor = bottomColor,
            )
        }
    }

    /**
     * 1:1 Square Lyrics Card (1080x1080) with balanced vertical centering,
     * matching the clean square format.
     */
    private fun drawSquareLyricsCard(
        context: Context,
        canvas: Canvas,
        config: LyricShareConfig,
        lines: List<String>,
        coverArt: Bitmap?,
        typeface: Typeface,
        posterWidth: Int,
        posterHeight: Int,
        topColor: Int,
        bottomColor: Int,
    ) {
        val cardRect = RectF(0f, 0f, posterWidth.toFloat(), posterHeight.toFloat())
        val cornerRadius = 56f

        // 1. Draw Card Surface
        if (config.useCoverBackground && coverArt != null) {
            drawDarkenedCoverSurface(canvas, coverArt, cardRect, cornerRadius)
        } else {
            val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                shader = LinearGradient(
                    0f, 0f, 0f, posterHeight.toFloat(),
                    intArrayOf(
                        topColor,
                        ColorUtils.blendARGB(topColor, bottomColor, 0.55f),
                        bottomColor,
                    ),
                    floatArrayOf(0f, 0.58f, 1f),
                    Shader.TileMode.CLAMP,
                )
            }
            canvas.drawRoundRect(cardRect, cornerRadius, cornerRadius, bgPaint)

            // Subtle specular glow on top
            val glowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                shader = LinearGradient(
                    0f, 0f, 0f, 380f,
                    Color.argb(22, 255, 255, 255),
                    Color.TRANSPARENT,
                    Shader.TileMode.CLAMP,
                )
            }
            canvas.drawRoundRect(cardRect, cornerRadius, cornerRadius, glowPaint)
        }

        // Card Border highlight
        val borderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 2.5f
            color = Color.argb(40, 255, 255, 255)
        }
        canvas.drawRoundRect(cardRect, cornerRadius, cornerRadius, borderPaint)

        // 2. Luminance-adaptive text color
        val isLightBg = !config.useCoverBackground && ColorUtils.calculateLuminance(topColor) > 0.45
        val textColor = if (isLightBg) Color.parseColor("#101216") else Color.WHITE
        val subtitleColor = if (isLightBg) Color.argb(190, 16, 18, 22) else Color.argb(205, 255, 255, 255)
        val brandColor = if (isLightBg) Color.parseColor("#101216") else Color.WHITE
        val brandAlpha = if (isLightBg) 220 else 238

        val pad = 80f
        val innerWidth = posterWidth - (pad * 2f)

        // 3. Header (Top)
        val headerY = pad
        val thumbSize = 116f
        val titlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.typeface = typeface
            textSize = 44f
            color = textColor
            if (!isLightBg && config.useCoverBackground) {
                setShadowLayer(10f, 0f, 3f, Color.argb(120, 0, 0, 0))
            }
        }
        val artistPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.typeface = typeface
            textSize = 30f
            color = subtitleColor
            if (!isLightBg && config.useCoverBackground) {
                setShadowLayer(10f, 0f, 3f, Color.argb(120, 0, 0, 0))
            }
        }

        val headerBottom: Float
        if (config.showArtwork) {
            if (coverArt != null) {
                drawSquircleArtwork(canvas, coverArt, pad, headerY, thumbSize, cornerRadius = 24f)
            } else {
                drawFallbackArtwork(canvas, config.song.title, pad, headerY, thumbSize, cornerRadius = 24f)
            }
            val textLeft = pad + thumbSize + 26f
            val maxTextWidth = innerWidth - thumbSize - 26f

            canvas.drawText(ellipsised(config.song.title, titlePaint, maxTextWidth), textLeft, headerY + 48f, titlePaint)
            canvas.drawText(ellipsised(config.song.artist, artistPaint, maxTextWidth), textLeft, headerY + 92f, artistPaint)
            headerBottom = headerY + thumbSize
        } else {
            val textLeft = pad
            val maxTextWidth = innerWidth

            canvas.drawText(ellipsised(config.song.title, titlePaint, maxTextWidth), textLeft, headerY + 42f, titlePaint)
            canvas.drawText(ellipsised(config.song.artist, artistPaint, maxTextWidth), textLeft, headerY + 84f, artistPaint)
            headerBottom = headerY + 90f
        }

        // 4. Footer (Bottom)
        val footerIconSize = 42f
        val footerY = posterHeight - pad - footerIconSize

        // 5. Middle Lyrics - Vertically Centered in Square
        val availableSpace = footerY - headerBottom
        val (baseFontSize, lineSpacingMult) = when (lines.size) {
            1 -> Pair(72f, 1.16f)
            2 -> Pair(64f, 1.15f)
            3 -> Pair(56f, 1.14f)
            4 -> Pair(50f, 1.13f)
            else -> Pair(44f, 1.12f)
        }

        val fullLyricsText = lines.joinToString("\n")
        val staticAlignment = when (config.alignment) {
            LyricCardAlignment.LEFT -> Layout.Alignment.ALIGN_NORMAL
            LyricCardAlignment.CENTER -> Layout.Alignment.ALIGN_CENTER
            LyricCardAlignment.RIGHT -> Layout.Alignment.ALIGN_OPPOSITE
        }

        val textPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            this.typeface = typeface
            textSize = baseFontSize
            color = textColor
            letterSpacing = -0.015f
            if (!isLightBg && config.useCoverBackground && coverArt != null) {
                setShadowLayer(14f, 0f, 4f, Color.argb(135, 0, 0, 0))
            }
        }

        var fontSize = baseFontSize
        var textLayout = StaticLayout.Builder.obtain(
            fullLyricsText, 0, fullLyricsText.length, textPaint, innerWidth.toInt()
        )
            .setAlignment(staticAlignment)
            .setLineSpacing(0f, lineSpacingMult)
            .setIncludePad(false)
            .build()

        val maxAllowedLyricsHeight = availableSpace - 50f
        while (textLayout.height > maxAllowedLyricsHeight && fontSize > 30f) {
            fontSize -= 2f
            textPaint.textSize = fontSize
            textLayout = StaticLayout.Builder.obtain(
                fullLyricsText, 0, fullLyricsText.length, textPaint, innerWidth.toInt()
            )
                .setAlignment(staticAlignment)
                .setLineSpacing(0f, lineSpacingMult)
                .setIncludePad(false)
                .build()
        }

        val lyricsTop = headerBottom + (availableSpace - textLayout.height) / 2f
        canvas.save()
        canvas.translate(pad, lyricsTop)
        textLayout.draw(canvas)
        canvas.restore()

        drawBrandBadge(
            context = context,
            canvas = canvas,
            typeface = typeface,
            x = pad,
            y = footerY,
            iconSize = footerIconSize,
            textSize = 28f,
            color = brandColor,
            alpha = brandAlpha,
        )
    }

    /**
     * Story (9:16) format with a centered SQUARE card (920x920) inside the vertical canvas.
     */
    private fun drawStoryLyricsCard(
        context: Context,
        canvas: Canvas,
        config: LyricShareConfig,
        lines: List<String>,
        coverArt: Bitmap?,
        typeface: Typeface,
        posterWidth: Int,
        posterHeight: Int,
        topColor: Int,
        bottomColor: Int,
    ) {
        val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = LinearGradient(
                0f, 0f, 0f, posterHeight.toFloat(),
                intArrayOf(
                    ColorUtils.blendARGB(topColor, Color.BLACK, 0.28f),
                    ColorUtils.blendARGB(bottomColor, Color.BLACK, 0.42f),
                ),
                floatArrayOf(0f, 1f),
                Shader.TileMode.CLAMP,
            )
        }
        canvas.drawRect(0f, 0f, posterWidth.toFloat(), posterHeight.toFloat(), bgPaint)

        // Centered SQUARE card inside the 9:16 canvas: 920x920
        val cardSize = 920f
        val cardLeft = (posterWidth - cardSize) / 2f
        val cardTop = (posterHeight - cardSize) / 2f
        val cardRect = RectF(cardLeft, cardTop, cardLeft + cardSize, cardTop + cardSize)
        val cornerRadius = 48f

        val shadowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(85, 0, 0, 0)
            setShadowLayer(48f, 0f, 22f, Color.argb(120, 0, 0, 0))
        }
        canvas.drawRoundRect(cardRect, cornerRadius, cornerRadius, shadowPaint)

        if (config.useCoverBackground && coverArt != null) {
            drawDarkenedCoverSurface(canvas, coverArt, cardRect, cornerRadius)
        } else {
            val cardBgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                shader = LinearGradient(
                    0f, cardRect.top, 0f, cardRect.bottom,
                    topColor,
                    bottomColor,
                    Shader.TileMode.CLAMP,
                )
            }
            canvas.drawRoundRect(cardRect, cornerRadius, cornerRadius, cardBgPaint)
        }

        val borderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 2.5f
            color = Color.argb(48, 255, 255, 255)
        }
        canvas.drawRoundRect(cardRect, cornerRadius, cornerRadius, borderPaint)

        val isLightBg = !config.useCoverBackground && ColorUtils.calculateLuminance(topColor) > 0.45
        val textColor = if (isLightBg) Color.parseColor("#101216") else Color.WHITE
        val subtitleColor = if (isLightBg) Color.argb(190, 16, 18, 22) else Color.argb(205, 255, 255, 255)
        val brandColor = if (isLightBg) Color.parseColor("#101216") else Color.WHITE
        val brandAlpha = if (isLightBg) 220 else 238

        val cardPad = 64f
        val innerWidth = cardSize - (cardPad * 2f)

        // Header
        val headerY = cardTop + cardPad
        val thumbSize = 104f
        val titlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.typeface = typeface
            textSize = 40f
            color = textColor
            if (!isLightBg && config.useCoverBackground) {
                setShadowLayer(10f, 0f, 3f, Color.argb(120, 0, 0, 0))
            }
        }
        val artistPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.typeface = typeface
            textSize = 28f
            color = subtitleColor
            if (!isLightBg && config.useCoverBackground) {
                setShadowLayer(10f, 0f, 3f, Color.argb(120, 0, 0, 0))
            }
        }

        val headerBottom: Float
        if (config.showArtwork) {
            val thumbX = cardLeft + cardPad
            if (coverArt != null) {
                drawSquircleArtwork(canvas, coverArt, thumbX, headerY, thumbSize, cornerRadius = 22f)
            } else {
                drawFallbackArtwork(canvas, config.song.title, thumbX, headerY, thumbSize, cornerRadius = 22f)
            }
            val textLeft = thumbX + thumbSize + 24f
            val maxTextWidth = innerWidth - thumbSize - 24f

            canvas.drawText(ellipsised(config.song.title, titlePaint, maxTextWidth), textLeft, headerY + 44f, titlePaint)
            canvas.drawText(ellipsised(config.song.artist, artistPaint, maxTextWidth), textLeft, headerY + 84f, artistPaint)
            headerBottom = headerY + thumbSize
        } else {
            val textLeft = cardLeft + cardPad
            val maxTextWidth = innerWidth

            canvas.drawText(ellipsised(config.song.title, titlePaint, maxTextWidth), textLeft, headerY + 38f, titlePaint)
            canvas.drawText(ellipsised(config.song.artist, artistPaint, maxTextWidth), textLeft, headerY + 76f, artistPaint)
            headerBottom = headerY + 82f
        }

        val footerIconSize = 38f
        val footerY = cardTop + cardSize - cardPad - footerIconSize

        val availableSpace = footerY - headerBottom
        val (baseFontSize, lineSpacingMult) = when (lines.size) {
            1 -> Pair(68f, 1.15f)
            2 -> Pair(60f, 1.14f)
            3 -> Pair(52f, 1.13f)
            4 -> Pair(46f, 1.12f)
            else -> Pair(42f, 1.12f)
        }

        val fullLyricsText = lines.joinToString("\n")
        val staticAlignment = when (config.alignment) {
            LyricCardAlignment.LEFT -> Layout.Alignment.ALIGN_NORMAL
            LyricCardAlignment.CENTER -> Layout.Alignment.ALIGN_CENTER
            LyricCardAlignment.RIGHT -> Layout.Alignment.ALIGN_OPPOSITE
        }

        val textPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            this.typeface = typeface
            textSize = baseFontSize
            color = textColor
            letterSpacing = -0.015f
            if (!isLightBg && config.useCoverBackground && coverArt != null) {
                setShadowLayer(14f, 0f, 4f, Color.argb(135, 0, 0, 0))
            }
        }

        var fontSize = baseFontSize
        var textLayout = StaticLayout.Builder.obtain(
            fullLyricsText, 0, fullLyricsText.length, textPaint, innerWidth.toInt()
        )
            .setAlignment(staticAlignment)
            .setLineSpacing(0f, lineSpacingMult)
            .setIncludePad(false)
            .build()

        val maxAllowedLyricsHeight = availableSpace - 40f
        while (textLayout.height > maxAllowedLyricsHeight && fontSize > 28f) {
            fontSize -= 2f
            textPaint.textSize = fontSize
            textLayout = StaticLayout.Builder.obtain(
                fullLyricsText, 0, fullLyricsText.length, textPaint, innerWidth.toInt()
            )
                .setAlignment(staticAlignment)
                .setLineSpacing(0f, lineSpacingMult)
                .setIncludePad(false)
                .build()
        }

        val lyricsTop = headerBottom + (availableSpace - textLayout.height) / 2f
        canvas.save()
        canvas.translate(cardLeft + cardPad, lyricsTop)
        textLayout.draw(canvas)
        canvas.restore()

        drawBrandBadge(
            context = context,
            canvas = canvas,
            typeface = typeface,
            x = cardLeft + cardPad,
            y = footerY,
            iconSize = footerIconSize,
            textSize = 26f,
            color = brandColor,
            alpha = brandAlpha,
        )
    }

    private fun drawSongCard(
        context: Context,
        canvas: Canvas,
        config: LyricShareConfig,
        coverArt: Bitmap?,
        typeface: Typeface,
        posterWidth: Int,
        posterHeight: Int,
    ) {
        val isCompact = posterHeight < 1600

        val cardWidth = if (isCompact) 720f else 820f
        val cardPadding = if (isCompact) 44f else 52f
        val artSize = cardWidth - (cardPadding * 2f)
        val titleSize = if (isCompact) 44f else 52f
        val artistSize = if (isCompact) 30f else 36f
        val badgeSize = if (isCompact) 32f else 38f
        val badgeTextSize = if (isCompact) 24f else 28f

        val titleSpacing = if (isCompact) 32f else 40f
        val artistSpacing = if (isCompact) 10f else 14f
        val badgeSpacing = if (isCompact) 28f else 38f

        val cardHeight = cardPadding + artSize + titleSpacing + titleSize + artistSpacing + artistSize + badgeSpacing + badgeSize + cardPadding
        val cardLeft = (posterWidth - cardWidth) / 2f
        val cardTop = (posterHeight - cardHeight) / 2f
        val cardRect = RectF(cardLeft, cardTop, cardLeft + cardWidth, cardTop + cardHeight)

        val shadowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(70, 0, 0, 0)
            setShadowLayer(45f, 0f, 22f, Color.argb(110, 0, 0, 0))
        }
        canvas.drawRoundRect(cardRect, 44f, 44f, shadowPaint)

        val cardBgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(140, 16, 16, 20)
        }
        canvas.drawRoundRect(cardRect, 44f, 44f, cardBgPaint)

        val cardBorderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 2.5f
            color = Color.argb(45, 255, 255, 255)
        }
        canvas.drawRoundRect(cardRect, 44f, 44f, cardBorderPaint)

        val artX = cardLeft + cardPadding
        val artY = cardTop + cardPadding
        if (coverArt != null) {
            drawSquircleArtwork(canvas, coverArt, artX, artY, artSize, cornerRadius = 32f)
        } else {
            drawFallbackArtwork(canvas, config.song.title, artX, artY, artSize, cornerRadius = 32f)
        }

        val titlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.typeface = typeface
            textSize = titleSize
            color = Color.WHITE
        }
        val artistPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.typeface = typeface
            textSize = artistSize
            color = Color.argb(200, 255, 255, 255)
        }

        val titleY = artY + artSize + titleSpacing + (titleSize * 0.75f)
        val artistY = titleY + artistSpacing + (artistSize * 0.85f)
        val maxTextWidth = artSize

        canvas.drawText(ellipsised(config.song.title, titlePaint, maxTextWidth), artX, titleY, titlePaint)
        canvas.drawText(ellipsised(config.song.artist, artistPaint, maxTextWidth), artX, artistY, artistPaint)

        val badgeY = artistY + badgeSpacing
        drawBrandBadge(context, canvas, typeface, artX, badgeY, iconSize = badgeSize, textSize = badgeTextSize)
    }

    private fun drawSquircleArtwork(
        canvas: Canvas,
        bitmap: Bitmap,
        x: Float,
        y: Float,
        size: Float,
        cornerRadius: Float,
    ) {
        val shader = BitmapShader(bitmap, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
        val matrix = Matrix()
        val minDim = bitmap.width.coerceAtMost(bitmap.height).toFloat().coerceAtLeast(1f)
        val scale = size / minDim
        matrix.setScale(scale, scale)
        val transX = x - (bitmap.width * scale - size) / 2f
        val transY = y - (bitmap.height * scale - size) / 2f
        matrix.postTranslate(transX, transY)
        shader.setLocalMatrix(matrix)

        val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG).apply {
            this.shader = shader
            isFilterBitmap = true
            isDither = true
        }
        val rect = RectF(x, y, x + size, y + size)
        canvas.drawRoundRect(rect, cornerRadius, cornerRadius, paint)

        val borderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 2f
            color = Color.argb(40, 255, 255, 255)
        }
        canvas.drawRoundRect(rect, cornerRadius, cornerRadius, borderPaint)
    }

    private fun drawFallbackArtwork(
        canvas: Canvas,
        title: String,
        x: Float,
        y: Float,
        size: Float,
        cornerRadius: Float,
    ) {
        val rect = RectF(x, y, x + size, y + size)
        val hue = (title.hashCode().toFloat() % 360f + 360f) % 360f
        val color1 = ColorUtils.HSLToColor(floatArrayOf(hue, 0.6f, 0.35f))
        val color2 = ColorUtils.HSLToColor(floatArrayOf((hue + 40f) % 360f, 0.6f, 0.20f))

        val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = LinearGradient(x, y, x + size, y + size, color1, color2, Shader.TileMode.CLAMP)
        }
        canvas.drawRoundRect(rect, cornerRadius, cornerRadius, bgPaint)

        val letter = title.firstOrNull()?.uppercaseChar()?.toString() ?: "V"
        val letterPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textSize = size * 0.45f
            textAlign = Paint.Align.CENTER
            typeface = Typeface.DEFAULT_BOLD
        }
        val fontMetrics = letterPaint.fontMetrics
        val baseline = y + (size - fontMetrics.bottom - fontMetrics.top) / 2f
        canvas.drawText(letter, x + (size / 2f), baseline, letterPaint)
    }

    private fun resolveColors(palette: LyricCardPalette, art: Bitmap?): Pair<Int, Int> {
        if (palette == LyricCardPalette.ARTWORK && art != null) {
            val safeArt = ensureSoftwareBitmap(art)
            val p = runCatching {
                Palette.from(safeArt)
                    .clearFilters()
                    .maximumColorCount(24)
                    .generate()
            }.getOrNull()

            val swatches = p?.swatches?.sortedByDescending { it.population }.orEmpty()
            if (swatches.isNotEmpty()) {
                val totalPop = swatches.sumOf { it.population }.coerceAtLeast(1)
                val primary = swatches.first()

                var accPop = 0
                var weightedSat = 0f
                for (sw in swatches) {
                    val hsl = sw.hsl
                    weightedSat += hsl[1] * sw.population
                    accPop += sw.population
                    if (accPop >= totalPop * 0.85f) break
                }
                val avgBodySat = weightedSat / accPop.coerceAtLeast(1).toFloat()

                val meaningfulChromatic = swatches
                    .filter { it.population >= totalPop * 0.10f && it.hsl[1] >= 0.16f }
                    .maxByOrNull { sw ->
                        val popShare = sw.population.toFloat() / totalPop.toFloat()
                        val satBonus = sw.hsl[1].coerceIn(0f, 0.85f) * 0.45f
                        popShare + satBonus
                    }

                val isMonochromeCover = avgBodySat < 0.10f && meaningfulChromatic == null
                if (isMonochromeCover) {
                    val baseHsl = primary.hsl.copyOf()
                    val hue = baseHsl[0]
                    val sat = baseHsl[1].coerceAtMost(0.08f)
                    val topLightness = baseHsl[2].coerceIn(0.24f, 0.34f)
                    val bottomLightness = (topLightness * 0.48f).coerceIn(0.10f, 0.16f)
                    val top = ColorUtils.HSLToColor(floatArrayOf(hue, sat, topLightness))
                    val bottom = ColorUtils.HSLToColor(floatArrayOf(hue, sat, bottomLightness))
                    return top to bottom
                }

                val chosen = meaningfulChromatic ?: primary
                val chosenHsl = chosen.hsl.copyOf()
                val hue = chosenHsl[0]
                val topSat = chosenHsl[1].coerceIn(0.22f, 0.72f)
                val topLight = chosenHsl[2].coerceIn(0.25f, 0.42f)

                val secondarySwatch = swatches
                    .firstOrNull { it !== chosen && it.population >= totalPop * 0.08f }
                val bottomHue = if (secondarySwatch != null && secondarySwatch.hsl[1] >= 0.12f) {
                    secondarySwatch.hsl[0]
                } else {
                    hue
                }
                val bottomSat = (topSat * 0.82f).coerceIn(0.16f, 0.60f)
                val bottomLight = (topLight * 0.46f).coerceIn(0.10f, 0.20f)

                val top = ColorUtils.HSLToColor(floatArrayOf(hue, topSat, topLight))
                val bottom = ColorUtils.HSLToColor(floatArrayOf(bottomHue, bottomSat, bottomLight))
                return top to bottom
            }
        }
        return when (palette) {
            LyricCardPalette.ARTWORK -> Color.parseColor("#383C46") to Color.parseColor("#14151A")
            LyricCardPalette.OBSIDIAN -> Color.parseColor("#26292E") to Color.parseColor("#0B0B0E")
            LyricCardPalette.SUNSET -> Color.parseColor("#D64550") to Color.parseColor("#2B1654")
            LyricCardPalette.OCEAN -> Color.parseColor("#0088C2") to Color.parseColor("#150A3A")
            LyricCardPalette.ROSE -> Color.parseColor("#C81D4E") to Color.parseColor("#280E18")
            LyricCardPalette.GLASS -> Color.parseColor("#383C45") to Color.parseColor("#17181C")
        }
    }

    private fun ensureSoftwareBitmap(bitmap: Bitmap): Bitmap {
        return if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O &&
            bitmap.config == Bitmap.Config.HARDWARE
        ) {
            bitmap.copy(Bitmap.Config.ARGB_8888, false) ?: bitmap
        } else {
            bitmap
        }
    }

    private fun resolveTypeface(context: Context, font: LyricCardFont): Typeface {
        return when (font) {
            LyricCardFont.SF_PRO -> ResourcesCompat.getFont(context, R.font.sf_pro_display_bold)
                ?: Typeface.DEFAULT_BOLD
            LyricCardFont.SERIF -> Typeface.SERIF
            LyricCardFont.MONO -> Typeface.MONOSPACE
            LyricCardFont.SANS -> Typeface.SANS_SERIF
        }
    }

    private fun ellipsised(text: String, paint: Paint, maxWidth: Float): String {
        if (paint.measureText(text) <= maxWidth) return text
        var end = text.length
        while (end > 1 && paint.measureText(text.take(end) + "…") > maxWidth) end--
        return text.take(end).trimEnd() + "…"
    }

    private suspend fun loadBitmap(context: Context, rawUrlOrUri: String): Bitmap? = runCatching {
        val model = rawUrlOrUri.artworkAt(1200) ?: rawUrlOrUri
        val request = ImageRequest.Builder(context)
            .data(model)
            .allowHardware(false)
            .build()
        (SingletonImageLoader.get(context).execute(request) as? SuccessResult)?.image?.toBitmap()
    }.getOrNull()
}
