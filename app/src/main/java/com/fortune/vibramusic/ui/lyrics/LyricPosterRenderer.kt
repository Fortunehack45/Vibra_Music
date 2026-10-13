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
    const val POSTER_HEIGHT = 1440

    private const val MARGIN = 88f

    suspend fun render(
        context: Context,
        config: LyricShareConfig,
    ): Bitmap = withContext(Dispatchers.IO) {
        // Resolve typography font first so full-bleed lyrics cards can size their height to the text
        val mainTypeface = resolveTypeface(context, config.font)

        val isFullBleedLyrics =
            config.cardStyle == LyricCardStyle.LYRICS_CARD && config.ratio == LyricCardRatio.CARD_3_4

        val posterWidth = config.ratio.width
        val posterHeight = if (isFullBleedLyrics) {
            measureFullBleedLyricsHeight(config, mainTypeface, posterWidth)
        } else {
            config.ratio.height
        }

        val bitmap = Bitmap.createBitmap(posterWidth, posterHeight, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)

        // Load artwork if present (support remote thumbnailUrl, localUri, or fallback)
        val artSource = config.song.thumbnailUrl ?: config.song.localUri
        val coverArt = artSource?.let { loadBitmap(context, it) }?.let { ensureSoftwareBitmap(it) }

        // Determine theme colors from palette or population-weighted album cover theme
        val (topColor, bottomColor) = resolveColors(config.palette, coverArt)

        if (isFullBleedLyrics && config.useCoverBackground && coverArt != null) {
            drawDarkenedCoverSurface(
                canvas = canvas,
                coverArt = coverArt,
                rect = RectF(0f, 0f, posterWidth.toFloat(), posterHeight.toFloat()),
                cornerRadius = 0f,
            )
        } else {
            val bgTop = if (!isFullBleedLyrics && config.cardStyle == LyricCardStyle.LYRICS_CARD) {
                ColorUtils.blendARGB(topColor, Color.BLACK, 0.28f)
            } else {
                topColor
            }
            val bgBottom = if (!isFullBleedLyrics && config.cardStyle == LyricCardStyle.LYRICS_CARD) {
                ColorUtils.blendARGB(bottomColor, Color.BLACK, 0.42f)
            } else {
                bottomColor
            }
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

            // Subtle specular glow on top
            val glowHeight = (posterHeight * 0.35f).coerceAtMost(440f)
            val glowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                shader = LinearGradient(
                    0f, 0f, 0f, glowHeight,
                    Color.argb(26, 255, 255, 255),
                    Color.TRANSPARENT,
                    Shader.TileMode.CLAMP,
                )
            }
            canvas.drawRect(0f, 0f, posterWidth.toFloat(), glowHeight, glowPaint)
        }

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
            LyricCardStyle.SONG_CARD -> drawSongCard(
                context = context,
                canvas = canvas,
                config = config,
                coverArt = coverArt,
                typeface = mainTypeface,
                posterWidth = posterWidth,
                posterHeight = posterHeight,
            )
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

        // Multi-stop darkened scrim so cover art is rich yet lyrics are high-contrast
        val scrimPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.shader = LinearGradient(
                0f, rect.top, 0f, rect.bottom,
                intArrayOf(
                    Color.argb(185, 6, 6, 10),
                    Color.argb(148, 8, 8, 12),
                    Color.argb(156, 8, 8, 12),
                    Color.argb(198, 6, 6, 10),
                ),
                floatArrayOf(0f, 0.28f, 0.72f, 1f),
                Shader.TileMode.CLAMP,
            )
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
        alpha: Int = 220,
    ) {
        val logo = runCatching {
            ResourcesCompat.getDrawable(context.resources, R.drawable.ic_logo, null)
        }.getOrNull()

        if (logo != null) {
            logo.setTint(Color.argb(alpha, 255, 255, 255))
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
            this.color = Color.argb(alpha, 255, 255, 255)
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

        if (config.ratio == LyricCardRatio.CARD_3_4) {
            drawFullBleedLyricsCard(
                context = context,
                canvas = canvas,
                config = config,
                lines = lines,
                coverArt = coverArt,
                typeface = typeface,
                posterWidth = posterWidth,
                posterHeight = posterHeight,
            )
            return
        }

        // Story (9:16): centered Spotify-style card inside the vertical story canvas
        val cardWidth = 900f
        val cardLeft = (posterWidth - cardWidth) / 2f
        val cardPadding = 60f
        val innerWidth = cardWidth - (cardPadding * 2f)

        val thumbSize = 108f
        val headerHeight = if (config.showArtwork) thumbSize else 88f

        val (baseFontSize, lineSpacingMult) = when (lines.size) {
            1 -> Pair(72f, 1.14f)
            2 -> Pair(64f, 1.14f)
            3 -> Pair(56f, 1.14f)
            4 -> Pair(50f, 1.13f)
            else -> Pair(46f, 1.12f)
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
            color = Color.WHITE
            letterSpacing = -0.015f
            if (config.useCoverBackground && coverArt != null) {
                setShadowLayer(14f, 0f, 4f, Color.argb(130, 0, 0, 0))
            }
        }

        var textLayout = StaticLayout.Builder.obtain(
            fullLyricsText, 0, fullLyricsText.length, textPaint, innerWidth.toInt()
        )
            .setAlignment(staticAlignment)
            .setLineSpacing(0f, lineSpacingMult)
            .setIncludePad(false)
            .build()

        val gapBeforeLyrics = 38f
        val gapAfterLyrics = 40f
        val footerHeight = 38f
        val maxCardHeight = posterHeight - 240f
        val maxLyricsHeight = maxCardHeight - (cardPadding * 2f + headerHeight + gapBeforeLyrics + gapAfterLyrics + footerHeight)
        var currentFontSize = baseFontSize
        while (textLayout.height > maxLyricsHeight && currentFontSize > 34f) {
            currentFontSize -= 3f
            textPaint.textSize = currentFontSize
            textLayout = StaticLayout.Builder.obtain(
                fullLyricsText, 0, fullLyricsText.length, textPaint, innerWidth.toInt()
            )
                .setAlignment(staticAlignment)
                .setLineSpacing(0f, lineSpacingMult)
                .setIncludePad(false)
                .build()
        }

        val contentHeight = cardPadding + headerHeight + gapBeforeLyrics + textLayout.height + gapAfterLyrics + footerHeight + cardPadding
        val cardHeight = contentHeight.coerceAtMost(maxCardHeight)

        val cardTop = (posterHeight - cardHeight) / 2f
        val cardRect = RectF(cardLeft, cardTop, cardLeft + cardWidth, cardTop + cardHeight)

        // Drop shadow behind story card
        val shadowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(85, 0, 0, 0)
            setShadowLayer(48f, 0f, 22f, Color.argb(120, 0, 0, 0))
        }
        canvas.drawRoundRect(cardRect, 44f, 44f, shadowPaint)

        if (config.useCoverBackground && coverArt != null) {
            drawDarkenedCoverSurface(canvas, coverArt, cardRect, 44f)
        } else {
            val cardBgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                shader = LinearGradient(
                    0f, cardRect.top, 0f, cardRect.bottom,
                    topColor,
                    bottomColor,
                    Shader.TileMode.CLAMP,
                )
            }
            canvas.drawRoundRect(cardRect, 44f, 44f, cardBgPaint)
        }

        // Specular highlight border
        val cardBorderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 2.5f
            color = Color.argb(48, 255, 255, 255)
        }
        canvas.drawRoundRect(cardRect, 44f, 44f, cardBorderPaint)

        val headerY = cardTop + cardPadding
        val titlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.typeface = typeface
            textSize = 40f
            color = Color.WHITE
        }
        val artistPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.typeface = typeface
            textSize = 28f
            color = Color.argb(205, 255, 255, 255)
        }

        val headerBottom: Float
        if (config.showArtwork) {
            val thumbX = cardLeft + cardPadding
            if (coverArt != null) {
                drawSquircleArtwork(canvas, coverArt, thumbX, headerY, thumbSize, cornerRadius = 22f)
            } else {
                drawFallbackArtwork(canvas, config.song.title, thumbX, headerY, thumbSize, cornerRadius = 22f)
            }
            val textLeft = thumbX + thumbSize + 24f
            val maxTextWidth = cardWidth - (cardPadding * 2f) - thumbSize - 24f

            canvas.drawText(ellipsised(config.song.title, titlePaint, maxTextWidth), textLeft, headerY + 46f, titlePaint)
            canvas.drawText(ellipsised(config.song.artist, artistPaint, maxTextWidth), textLeft, headerY + 86f, artistPaint)
            headerBottom = headerY + thumbSize
        } else {
            val textLeft = cardLeft + cardPadding
            val maxTextWidth = cardWidth - (cardPadding * 2f)

            canvas.drawText(ellipsised(config.song.title, titlePaint, maxTextWidth), textLeft, headerY + 40f, titlePaint)
            canvas.drawText(ellipsised(config.song.artist, artistPaint, maxTextWidth), textLeft, headerY + 78f, artistPaint)
            headerBottom = headerY + 88f
        }

        val lyricsTop = headerBottom + gapBeforeLyrics
        canvas.save()
        canvas.translate(cardLeft + cardPadding, lyricsTop)
        textLayout.draw(canvas)
        canvas.restore()

        val footerY = lyricsTop + textLayout.height + gapAfterLyrics
        drawBrandBadge(context, canvas, typeface, cardLeft + cardPadding, footerY, iconSize = 38f, textSize = 27f, alpha = 235)
    }

    private const val FULL_BLEED_PAD = 64f
    private const val FULL_BLEED_THUMB_SIZE = 112f
    private const val FULL_BLEED_HEADER_NO_ART = 92f
    private const val FULL_BLEED_GAP_BEFORE_LYRICS = 38f
    private const val FULL_BLEED_GAP_AFTER_LYRICS = 40f
    private const val FULL_BLEED_FOOTER_ICON = 40f

    private fun buildFullBleedLyricsLayout(
        config: LyricShareConfig,
        lines: List<String>,
        typeface: Typeface,
        innerWidth: Float,
        withShadow: Boolean,
    ): StaticLayout {
        val (initialFontSize, lineSpacingMult) = when (lines.size) {
            1 -> Pair(74f, 1.14f)
            2 -> Pair(66f, 1.14f)
            3 -> Pair(58f, 1.13f)
            4 -> Pair(52f, 1.12f)
            else -> Pair(48f, 1.12f)
        }

        val fullLyricsText = lines.joinToString("\n")
        val staticAlignment = when (config.alignment) {
            LyricCardAlignment.LEFT -> Layout.Alignment.ALIGN_NORMAL
            LyricCardAlignment.CENTER -> Layout.Alignment.ALIGN_CENTER
            LyricCardAlignment.RIGHT -> Layout.Alignment.ALIGN_OPPOSITE
        }

        val textPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            this.typeface = typeface
            textSize = initialFontSize
            color = Color.WHITE
            letterSpacing = -0.015f
            if (withShadow) {
                setShadowLayer(16f, 0f, 4f, Color.argb(145, 0, 0, 0))
            }
        }

        var fontSize = initialFontSize
        var textLayout = StaticLayout.Builder.obtain(
            fullLyricsText, 0, fullLyricsText.length, textPaint, innerWidth.toInt()
        )
            .setAlignment(staticAlignment)
            .setLineSpacing(0f, lineSpacingMult)
            .setIncludePad(false)
            .build()

        val maxLyricsHeight = 960f
        while (textLayout.height > maxLyricsHeight && fontSize > 34f) {
            fontSize -= 3f
            textPaint.textSize = fontSize
            textLayout = StaticLayout.Builder.obtain(
                fullLyricsText, 0, fullLyricsText.length, textPaint, innerWidth.toInt()
            )
                .setAlignment(staticAlignment)
                .setLineSpacing(0f, lineSpacingMult)
                .setIncludePad(false)
                .build()
        }
        return textLayout
    }

    private fun measureFullBleedLyricsHeight(
        config: LyricShareConfig,
        typeface: Typeface,
        posterWidth: Int,
    ): Int {
        val lines = config.selectedLines.take(5).ifEmpty { listOf(config.song.title) }
        val innerWidth = posterWidth - (FULL_BLEED_PAD * 2f)
        val headerHeight = if (config.showArtwork) FULL_BLEED_THUMB_SIZE else FULL_BLEED_HEADER_NO_ART
        val textLayout = buildFullBleedLyricsLayout(
            config = config,
            lines = lines,
            typeface = typeface,
            innerWidth = innerWidth,
            withShadow = false,
        )
        val total = FULL_BLEED_PAD +
            headerHeight +
            FULL_BLEED_GAP_BEFORE_LYRICS +
            textLayout.height +
            FULL_BLEED_GAP_AFTER_LYRICS +
            FULL_BLEED_FOOTER_ICON +
            FULL_BLEED_PAD
        return total.toInt().coerceAtLeast(420)
    }

    /**
     * Spotify-style full-bleed Lyrics Card:
     * The card fills the entire canvas edge-to-edge and wraps the header, lyrics, and footer
     * tightly with no excess blank space above or below the lyrics.
     */
    private fun drawFullBleedLyricsCard(
        context: Context,
        canvas: Canvas,
        config: LyricShareConfig,
        lines: List<String>,
        coverArt: Bitmap?,
        typeface: Typeface,
        posterWidth: Int,
        posterHeight: Int,
    ) {
        val pad = FULL_BLEED_PAD
        val innerWidth = posterWidth - (pad * 2f)

        // 1. Header at top-left: cover art thumbnail + bold Song Title + Artist
        val headerY = pad
        val thumbSize = FULL_BLEED_THUMB_SIZE
        val titlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.typeface = typeface
            textSize = 42f
            color = Color.WHITE
            if (config.useCoverBackground && coverArt != null) {
                setShadowLayer(10f, 0f, 3f, Color.argb(115, 0, 0, 0))
            }
        }
        val artistPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.typeface = typeface
            textSize = 30f
            color = Color.argb(210, 255, 255, 255)
            if (config.useCoverBackground && coverArt != null) {
                setShadowLayer(10f, 0f, 3f, Color.argb(115, 0, 0, 0))
            }
        }

        val headerBottom: Float
        if (config.showArtwork) {
            if (coverArt != null) {
                drawSquircleArtwork(canvas, coverArt, pad, headerY, thumbSize, cornerRadius = 22f)
            } else {
                drawFallbackArtwork(canvas, config.song.title, pad, headerY, thumbSize, cornerRadius = 22f)
            }
            val textLeft = pad + thumbSize + 26f
            val maxTextWidth = innerWidth - thumbSize - 26f

            canvas.drawText(ellipsised(config.song.title, titlePaint, maxTextWidth), textLeft, headerY + 48f, titlePaint)
            canvas.drawText(ellipsised(config.song.artist, artistPaint, maxTextWidth), textLeft, headerY + 90f, artistPaint)
            headerBottom = headerY + thumbSize
        } else {
            canvas.drawText(ellipsised(config.song.title, titlePaint, innerWidth), pad, headerY + 42f, titlePaint)
            canvas.drawText(ellipsised(config.song.artist, artistPaint, innerWidth), pad, headerY + 84f, artistPaint)
            headerBottom = headerY + FULL_BLEED_HEADER_NO_ART
        }

        // 2. Lyrics placed directly below header with a clean 38px gap
        val textLayout = buildFullBleedLyricsLayout(
            config = config,
            lines = lines,
            typeface = typeface,
            innerWidth = innerWidth,
            withShadow = config.useCoverBackground && coverArt != null,
        )
        val lyricsTop = headerBottom + FULL_BLEED_GAP_BEFORE_LYRICS

        canvas.save()
        canvas.translate(pad, lyricsTop)
        textLayout.draw(canvas)
        canvas.restore()

        // 3. Footer placed directly below lyrics with a clean 40px gap
        val footerY = (lyricsTop + textLayout.height + FULL_BLEED_GAP_AFTER_LYRICS)
            .coerceAtMost(posterHeight - pad - FULL_BLEED_FOOTER_ICON)
        drawBrandBadge(
            context = context,
            canvas = canvas,
            typeface = typeface,
            x = pad,
            y = footerY,
            iconSize = FULL_BLEED_FOOTER_ICON,
            textSize = 28f,
            alpha = 238,
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

        // Dimensions of the centered floating card
        val cardWidth = if (isCompact) 760f else 820f
        val cardPadding = if (isCompact) 48f else 52f
        val artSize = cardWidth - (cardPadding * 2f)
        val titleSize = if (isCompact) 46f else 52f
        val artistSize = if (isCompact) 32f else 36f
        val badgeSize = if (isCompact) 34f else 38f
        val badgeTextSize = if (isCompact) 25f else 28f

        val titleSpacing = if (isCompact) 36f else 40f
        val artistSpacing = if (isCompact) 12f else 14f
        val badgeSpacing = if (isCompact) 34f else 38f

        val cardHeight = cardPadding + artSize + titleSpacing + titleSize + artistSpacing + artistSize + badgeSpacing + badgeSize + cardPadding
        val cardLeft = (posterWidth - cardWidth) / 2f
        val cardTop = (posterHeight - cardHeight) / 2f
        val cardRect = RectF(cardLeft, cardTop, cardLeft + cardWidth, cardTop + cardHeight)

        // Drop shadow behind floating card
        val shadowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(70, 0, 0, 0)
            setShadowLayer(45f, 0f, 22f, Color.argb(110, 0, 0, 0))
        }
        canvas.drawRoundRect(cardRect, 44f, 44f, shadowPaint)

        // Frosted dark card surface
        val cardBgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(140, 16, 16, 20)
        }
        canvas.drawRoundRect(cardRect, 44f, 44f, cardBgPaint)

        // Specular highlight border
        val cardBorderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 2.5f
            color = Color.argb(45, 255, 255, 255)
        }
        canvas.drawRoundRect(cardRect, 44f, 44f, cardBorderPaint)

        // Large Square Artwork inside the card
        val artX = cardLeft + cardPadding
        val artY = cardTop + cardPadding
        if (coverArt != null) {
            drawSquircleArtwork(canvas, coverArt, artX, artY, artSize, cornerRadius = 32f)
        } else {
            drawFallbackArtwork(canvas, config.song.title, artX, artY, artSize, cornerRadius = 32f)
        }

        // Title and Artist (Left-aligned under artwork, matching Spotify layout)
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

        // Vibra Music Brand Badge at bottom-left of card
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

        // Subtle specular highlight on edge
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

                // Compute population-weighted saturation across the main body of the cover (top 85% of pixels)
                var accPop = 0
                var weightedSat = 0f
                for (sw in swatches) {
                    val hsl = sw.hsl
                    weightedSat += hsl[1] * sw.population
                    accPop += sw.population
                    if (accPop >= totalPop * 0.85f) break
                }
                val avgBodySat = weightedSat / accPop.coerceAtLeast(1).toFloat()

                // Only pick a chromatic swatch if it represents a meaningful area of the cover (>= 10% of pixels),
                // preventing tiny 1% details (like a red badge on a monochrome cover) from hijacking the theme.
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

                // Find a secondary swatch that represents a real secondary area (>= 8% pop) or derive from theme
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

