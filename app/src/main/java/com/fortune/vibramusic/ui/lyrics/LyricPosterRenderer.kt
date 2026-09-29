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
        val posterWidth = config.ratio.width
        val posterHeight = config.ratio.height
        val bitmap = Bitmap.createBitmap(posterWidth, posterHeight, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)

        // Load artwork if present (support remote thumbnailUrl, localUri, or fallback)
        val artSource = config.song.thumbnailUrl ?: config.song.localUri
        val coverArt = artSource?.let { loadBitmap(context, it) }

        // Determine background colors
        val (topColor, bottomColor) = resolveColors(config.palette, coverArt)

        // Draw background gradient
        val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = LinearGradient(
                0f, 0f, 0f, posterHeight.toFloat(),
                topColor, bottomColor,
                Shader.TileMode.CLAMP
            )
        }
        canvas.drawRect(0f, 0f, posterWidth.toFloat(), posterHeight.toFloat(), bgPaint)

        // Subtle specular glow on top
        val glowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = LinearGradient(
                0f, 0f, 0f, 440f,
                Color.argb(32, 255, 255, 255),
                Color.TRANSPARENT,
                Shader.TileMode.CLAMP
            )
        }
        canvas.drawRect(0f, 0f, posterWidth.toFloat(), 440f, glowPaint)

        // Resolve typography font
        val mainTypeface = resolveTypeface(context, config.font)

        when (config.cardStyle) {
            LyricCardStyle.LYRICS_CARD -> drawLyricsCard(context, canvas, config, coverArt, mainTypeface, posterWidth, posterHeight)
            LyricCardStyle.SONG_CARD -> drawSongCard(context, canvas, config, coverArt, mainTypeface, posterWidth, posterHeight)
        }

        bitmap
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
    ) {
        val lines = config.selectedLines.take(5)
        if (lines.isEmpty()) return

        val isCompact = posterHeight < 1600
        val cardWidth = 880f
        val cardLeft = (posterWidth - cardWidth) / 2f
        val cardPadding = 56f

        val cardHeight = if (isCompact) 1160f else 1400f
        val cardTop = (posterHeight - cardHeight) / 2f
        val cardRect = RectF(cardLeft, cardTop, cardLeft + cardWidth, cardTop + cardHeight)

        // Drop shadow behind floating card
        val shadowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(70, 0, 0, 0)
            setShadowLayer(45f, 0f, 20f, Color.argb(110, 0, 0, 0))
        }
        canvas.drawRoundRect(cardRect, 44f, 44f, shadowPaint)

        // Frosted card surface
        val cardBgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(135, 16, 16, 20)
        }
        canvas.drawRoundRect(cardRect, 44f, 44f, cardBgPaint)

        // Specular highlight border
        val cardBorderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 2.5f
            color = Color.argb(45, 255, 255, 255)
        }
        canvas.drawRoundRect(cardRect, 44f, 44f, cardBorderPaint)

        // Header: Thumbnail + Song Title + "Song • [Artist]"
        val headerY = cardTop + cardPadding
        val titlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.typeface = typeface
            textSize = 38f
            color = Color.WHITE
        }
        val artistPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.typeface = typeface
            textSize = 26f
            color = Color.argb(190, 255, 255, 255)
        }

        val headerBottom: Float
        if (config.showArtwork) {
            val thumbSize = 104f
            val thumbX = cardLeft + cardPadding
            if (coverArt != null) {
                drawSquircleArtwork(canvas, coverArt, thumbX, headerY, thumbSize, cornerRadius = 22f)
            } else {
                drawFallbackArtwork(canvas, config.song.title, thumbX, headerY, thumbSize, cornerRadius = 22f)
            }
            val textLeft = thumbX + thumbSize + 22f
            val maxTextWidth = cardWidth - (cardPadding * 2f) - thumbSize - 22f

            canvas.drawText(ellipsised(config.song.title, titlePaint, maxTextWidth), textLeft, headerY + 44f, titlePaint)
            canvas.drawText(ellipsised("Song • ${config.song.artist}", artistPaint, maxTextWidth), textLeft, headerY + 84f, artistPaint)
            headerBottom = headerY + thumbSize
        } else {
            val textLeft = cardLeft + cardPadding
            val maxTextWidth = cardWidth - (cardPadding * 2f)

            canvas.drawText(ellipsised(config.song.title, titlePaint, maxTextWidth), textLeft, headerY + 38f, titlePaint)
            canvas.drawText(ellipsised("Song • ${config.song.artist}", artistPaint, maxTextWidth), textLeft, headerY + 76f, artistPaint)
            headerBottom = headerY + 84f
        }

        // Footer: Brand badge at bottom-left of card
        val footerY = cardTop + cardHeight - cardPadding - 36f
        drawBrandBadge(context, canvas, typeface, cardLeft + cardPadding, footerY, iconSize = 36f, textSize = 26f)

        // Lyrics Block: Positioned in the middle between header and footer
        val innerWidth = cardWidth - (cardPadding * 2f)
        val lyricsSpaceTop = headerBottom + 36f
        val lyricsSpaceBottom = footerY - 24f
        val availableLyricsHeight = lyricsSpaceBottom - lyricsSpaceTop

        val (fontSize, lineSpacingExtra, lineSpacingMult) = when (lines.size) {
            1 -> Triple(if (isCompact) 66f else 74f, 14f, 1.25f)
            2 -> Triple(if (isCompact) 58f else 64f, 12f, 1.24f)
            3 -> Triple(if (isCompact) 50f else 56f, 10f, 1.22f)
            4 -> Triple(if (isCompact) 44f else 48f, 8f, 1.20f)
            else -> Triple(if (isCompact) 40f else 44f, 6f, 1.18f)
        }

        val textPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            this.typeface = typeface
            textSize = fontSize
            color = Color.WHITE
            letterSpacing = -0.015f
        }

        val fullLyricsText = lines.joinToString("\n")
        val staticAlignment = when (config.alignment) {
            LyricCardAlignment.LEFT -> Layout.Alignment.ALIGN_NORMAL
            LyricCardAlignment.CENTER -> Layout.Alignment.ALIGN_CENTER
            LyricCardAlignment.RIGHT -> Layout.Alignment.ALIGN_OPPOSITE
        }

        val textLayout = StaticLayout.Builder.obtain(
            fullLyricsText, 0, fullLyricsText.length, textPaint, innerWidth.toInt()
        )
            .setAlignment(staticAlignment)
            .setLineSpacing(lineSpacingExtra, lineSpacingMult)
            .setIncludePad(false)
            .build()

        val lyricsTop = (lyricsSpaceTop + (availableLyricsHeight - textLayout.height) / 2f)
            .coerceAtLeast(lyricsSpaceTop)

        canvas.save()
        canvas.translate(cardLeft + cardPadding, lyricsTop)
        textLayout.draw(canvas)
        canvas.restore()
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

        // No lyrics drawn on the song card
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
        val minDim = bitmap.width.coerceAtMost(bitmap.height).toFloat()
        val scale = size / minDim
        matrix.setScale(scale, scale)
        // Correctly translate the shader to align with the drawn rectangle (x, y)
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

        // Draw letter in center
        val letter = title.firstOrNull()?.uppercaseChar()?.toString() ?: "♪"
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
            val p = Palette.from(art).generate()
            val dominant = p.getVibrantColor(p.getDominantColor(Color.parseColor("#4A4E5A")))
            val darkMuted = p.getDarkMutedColor(Color.parseColor("#121216"))
            return dominant to darkMuted
        }
        return when (palette) {
            LyricCardPalette.ARTWORK -> Color.parseColor("#4A4E5A") to Color.parseColor("#16161A")
            LyricCardPalette.OBSIDIAN -> Color.parseColor("#26292E") to Color.parseColor("#0B0B0E")
            LyricCardPalette.SUNSET -> Color.parseColor("#FF5E62") to Color.parseColor("#3A1C71")
            LyricCardPalette.OCEAN -> Color.parseColor("#00C0FF") to Color.parseColor("#1E0855")
            LyricCardPalette.ROSE -> Color.parseColor("#FF0844") to Color.parseColor("#301018")
            LyricCardPalette.GLASS -> Color.parseColor("#383C45") to Color.parseColor("#17181C")
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
