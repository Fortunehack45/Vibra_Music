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
    const val POSTER_HEIGHT = 1920

    private const val MARGIN = 88f
    private const val CONTENT_WIDTH = POSTER_WIDTH - (MARGIN * 2f)

    suspend fun render(
        context: Context,
        config: LyricShareConfig,
    ): Bitmap = withContext(Dispatchers.IO) {
        val bitmap = Bitmap.createBitmap(POSTER_WIDTH, POSTER_HEIGHT, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)

        // Load artwork if present (support remote thumbnailUrl, localUri, or fallback)
        val artSource = config.song.thumbnailUrl ?: config.song.localUri
        val coverArt = artSource?.let { loadBitmap(context, it) }

        // Determine background colors
        val (topColor, bottomColor) = resolveColors(config.palette, coverArt)

        // Draw background gradient
        val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = LinearGradient(
                0f, 0f, 0f, POSTER_HEIGHT.toFloat(),
                topColor, bottomColor,
                Shader.TileMode.CLAMP
            )
        }
        canvas.drawRect(0f, 0f, POSTER_WIDTH.toFloat(), POSTER_HEIGHT.toFloat(), bgPaint)

        // Subtle specular glow on top
        val glowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = LinearGradient(
                0f, 0f, 0f, 440f,
                Color.argb(32, 255, 255, 255),
                Color.TRANSPARENT,
                Shader.TileMode.CLAMP
            )
        }
        canvas.drawRect(0f, 0f, POSTER_WIDTH.toFloat(), 440f, glowPaint)

        // Resolve typography font
        val mainTypeface = resolveTypeface(context, config.font)

        // Draw brand watermark at top using Replay card aesthetic with official ic_logo
        drawWatermark(context, canvas, mainTypeface)

        when (config.cardStyle) {
            LyricCardStyle.LYRICS_CARD -> drawLyricsCard(context, canvas, config, coverArt, mainTypeface)
            LyricCardStyle.SONG_CARD -> drawSongCard(canvas, config, coverArt, mainTypeface)
        }

        bitmap
    }

    private fun drawWatermark(context: Context, canvas: Canvas, typeface: Typeface) {
        val logo = runCatching {
            ResourcesCompat.getDrawable(context.resources, R.drawable.ic_logo, null)
        }.getOrNull()

        val logoSize = 48f
        val logoX = MARGIN
        val logoY = 96f

        if (logo != null) {
            logo.setTint(Color.WHITE)
            logo.setBounds(
                logoX.toInt(),
                logoY.toInt(),
                (logoX + logoSize).toInt(),
                (logoY + logoSize).toInt()
            )
            logo.draw(canvas)
        }

        val brandPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.typeface = typeface
            textSize = 34f
            color = Color.WHITE
            letterSpacing = 0.05f
        }

        canvas.drawText("Vibra Music", logoX + logoSize + 18f, logoY + 36f, brandPaint)
    }

    private fun drawLyricsCard(
        context: Context,
        canvas: Canvas,
        config: LyricShareConfig,
        coverArt: Bitmap?,
        typeface: Typeface,
    ) {
        val lines = config.selectedLines.take(5)
        if (lines.isEmpty()) return

        // Dynamic typography sizing based on line count so the card fills the 9:16 poster gracefully
        val (fontSize, lineSpacingExtra, lineSpacingMult) = when (lines.size) {
            1 -> Triple(78f, 26f, 1.40f)
            2 -> Triple(70f, 22f, 1.35f)
            3 -> Triple(60f, 18f, 1.30f)
            4 -> Triple(54f, 16f, 1.25f)
            else -> Triple(48f, 14f, 1.20f)
        }

        val textPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            this.typeface = typeface
            textSize = fontSize
            color = Color.WHITE
            letterSpacing = -0.015f
        }

        val fullLyricsText = lines.joinToString("\n\n")
        val textLayout = StaticLayout.Builder.obtain(
            fullLyricsText, 0, fullLyricsText.length, textPaint, CONTENT_WIDTH.toInt()
        )
            .setAlignment(Layout.Alignment.ALIGN_NORMAL)
            .setLineSpacing(lineSpacingExtra, lineSpacingMult)
            .setIncludePad(false)
            .build()

        // Available vertical space between top watermark and footer
        val headerBottom = 190f
        val footerY = POSTER_HEIGHT - 240f
        val availableHeight = footerY - headerBottom
        val totalBlockHeight = textLayout.height

        // Vertically center the lyrics in the poster so there is never an awkward dead space below
        val lyricsTop = (headerBottom + (availableHeight - totalBlockHeight) / 2f)
            .coerceAtLeast(headerBottom + 40f)

        // Opening decorative quotation mark placed elegantly above the text
        val quotePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.typeface = typeface
            textSize = (fontSize * 1.5f).coerceAtMost(105f)
            color = Color.argb(140, 255, 255, 255)
        }
        canvas.drawText("“", MARGIN, lyricsTop - 24f, quotePaint)

        canvas.save()
        canvas.translate(MARGIN, lyricsTop)
        textLayout.draw(canvas)
        canvas.restore()

        // Bottom Footer: Song details & artwork
        val artSize = 136f

        if (config.showArtwork) {
            if (coverArt != null) {
                drawSquircleArtwork(canvas, coverArt, MARGIN, footerY, artSize, cornerRadius = 26f)
            } else {
                drawFallbackArtwork(canvas, config.song.title, MARGIN, footerY, artSize, cornerRadius = 26f)
            }
        }

        val metaX = if (config.showArtwork) MARGIN + artSize + 32f else MARGIN
        val metaWidth = POSTER_WIDTH - MARGIN - metaX

        val titlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.typeface = typeface
            textSize = 48f
            color = Color.WHITE
        }
        val artistPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.typeface = typeface
            textSize = 34f
            color = Color.argb(180, 255, 255, 255)
        }

        val title = ellipsised(config.song.title, titlePaint, metaWidth)
        val artist = ellipsised(config.song.artist, artistPaint, metaWidth)

        canvas.drawText(title, metaX, footerY + 56f, titlePaint)
        canvas.drawText(artist, metaX, footerY + 108f, artistPaint)
    }

    private fun drawSongCard(
        canvas: Canvas,
        config: LyricShareConfig,
        coverArt: Bitmap?,
        typeface: Typeface,
    ) {
        val heroArtSize = 620f
        val artX = (POSTER_WIDTH - heroArtSize) / 2f
        val artY = 220f

        // Draw Large Centered Artwork
        if (coverArt != null) {
            // Shadow behind artwork
            val shadowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.argb(60, 0, 0, 0)
                setShadowLayer(40f, 0f, 20f, Color.argb(90, 0, 0, 0))
            }
            canvas.drawRoundRect(
                RectF(artX, artY + 10f, artX + heroArtSize, artY + heroArtSize + 10f),
                40f, 40f, shadowPaint
            )
            drawSquircleArtwork(canvas, coverArt, artX, artY, heroArtSize, cornerRadius = 40f)
        } else {
            drawFallbackArtwork(canvas, config.song.title, artX, artY, heroArtSize, cornerRadius = 40f)
        }

        // Song Title and Artist (Centered)
        val titlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.typeface = typeface
            textSize = 58f
            color = Color.WHITE
            textAlign = Paint.Align.CENTER
        }
        val artistPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.typeface = typeface
            textSize = 38f
            color = Color.argb(200, 255, 255, 255)
            textAlign = Paint.Align.CENTER
        }

        val titleY = artY + heroArtSize + 85f
        val artistY = titleY + 55f
        val centerX = POSTER_WIDTH / 2f

        canvas.drawText(ellipsised(config.song.title, titlePaint, CONTENT_WIDTH), centerX, titleY, titlePaint)
        canvas.drawText(ellipsised(config.song.artist, artistPaint, CONTENT_WIDTH), centerX, artistY, artistPaint)

        // Glass lyrics card at bottom
        val lines = config.selectedLines.take(5)
        if (lines.isNotEmpty()) {
            val cardTop = artistY + 50f
            val cardBottom = POSTER_HEIGHT - 120f
            val cardRect = RectF(MARGIN, cardTop, POSTER_WIDTH - MARGIN, cardBottom)

            // Frosted pill container
            val glassPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.argb(45, 255, 255, 255)
            }
            val borderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeWidth = 2.5f
                color = Color.argb(60, 255, 255, 255)
            }
            canvas.drawRoundRect(cardRect, 32f, 32f, glassPaint)
            canvas.drawRoundRect(cardRect, 32f, 32f, borderPaint)

            // Lyrics lines inside glass card
            val lyricPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
                this.typeface = typeface
                textSize = if (lines.size <= 2) 48f else 40f
                color = Color.WHITE
                textAlign = Paint.Align.CENTER
            }

            val lyricsText = lines.joinToString("\n")
            val lyricsLayout = StaticLayout.Builder.obtain(
                lyricsText, 0, lyricsText.length, lyricPaint, (cardRect.width() - 80f).toInt()
            )
                .setAlignment(Layout.Alignment.ALIGN_CENTER)
                .setLineSpacing(8f, 1.25f)
                .build()

            val textY = cardTop + ((cardRect.height() - lyricsLayout.height) / 2f)
            canvas.save()
            canvas.translate(centerX, textY)
            lyricsLayout.draw(canvas)
            canvas.restore()
        }
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

        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.shader = shader
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
            val dominant = p.getVibrantColor(p.getDominantColor(Color.parseColor("#E50914")))
            val darkMuted = p.getDarkMutedColor(Color.parseColor("#121216"))
            return dominant to darkMuted
        }
        return when (palette) {
            LyricCardPalette.ARTWORK -> Color.parseColor("#E50914") to Color.parseColor("#16161A")
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
        val model = rawUrlOrUri.artworkAt(800) ?: rawUrlOrUri
        val request = ImageRequest.Builder(context)
            .data(model)
            .allowHardware(false)
            .build()
        (SingletonImageLoader.get(context).execute(request) as? SuccessResult)?.image?.toBitmap()
    }.getOrNull()
}
