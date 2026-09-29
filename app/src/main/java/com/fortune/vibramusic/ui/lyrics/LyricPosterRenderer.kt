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

    private const val MARGIN = 80f
    private const val CONTENT_WIDTH = POSTER_WIDTH - (MARGIN * 2f)

    suspend fun render(
        context: Context,
        config: LyricShareConfig,
    ): Bitmap = withContext(Dispatchers.IO) {
        val bitmap = Bitmap.createBitmap(POSTER_WIDTH, POSTER_HEIGHT, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)

        // Load artwork if present
        val coverArt = config.song.thumbnailUrl?.let { url ->
            loadBitmap(context, url)
        }

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
                0f, 0f, 0f, 400f,
                Color.argb(35, 255, 255, 255),
                Color.TRANSPARENT,
                Shader.TileMode.CLAMP
            )
        }
        canvas.drawRect(0f, 0f, POSTER_WIDTH.toFloat(), 400f, glowPaint)

        // Resolve typography font
        val mainTypeface = resolveTypeface(context, config.font)

        // Draw brand watermark at top
        drawWatermark(context, canvas, mainTypeface)

        when (config.cardStyle) {
            LyricCardStyle.LYRICS_CARD -> drawLyricsCard(canvas, config, coverArt, mainTypeface)
            LyricCardStyle.SONG_CARD -> drawSongCard(canvas, config, coverArt, mainTypeface)
        }

        bitmap
    }

    private fun drawWatermark(context: Context, canvas: Canvas, typeface: Typeface) {
        val brandPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.typeface = typeface
            textSize = 34f
            color = Color.argb(190, 255, 255, 255)
            letterSpacing = 0.08f
        }

        // Draw small red squircle emblem
        val emblemSize = 44f
        val emblemX = MARGIN
        val emblemY = 88f

        val emblemBg = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.parseColor("#E50914")
        }
        canvas.drawRoundRect(
            RectF(emblemX, emblemY, emblemX + emblemSize, emblemY + emblemSize),
            12f, 12f, emblemBg
        )

        // Inner V or note symbol
        val emblemIcon = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            this.typeface = typeface
            textSize = 26f
            textAlign = Paint.Align.CENTER
        }
        canvas.drawText("V", emblemX + (emblemSize / 2f), emblemY + 32f, emblemIcon)

        // "Vibra Music" text
        canvas.drawText("Vibra Music", emblemX + emblemSize + 20f, emblemY + 33f, brandPaint)
    }

    private fun drawLyricsCard(
        canvas: Canvas,
        config: LyricShareConfig,
        coverArt: Bitmap?,
        typeface: Typeface,
    ) {
        val lines = config.selectedLines.take(5)
        if (lines.isEmpty()) return

        // Large opening quote glyph
        val quotePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.typeface = typeface
            textSize = 140f
            color = Color.argb(120, 255, 255, 255)
        }
        canvas.drawText("“", MARGIN, 260f, quotePaint)

        // Lyrics Text Layout
        val textPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            this.typeface = typeface
            textSize = if (lines.size <= 2) 64f else if (lines.size <= 4) 54f else 46f
            color = Color.WHITE
            letterSpacing = -0.01f
        }

        val fullLyricsText = lines.joinToString("\n\n")
        val textLayout = StaticLayout.Builder.obtain(
            fullLyricsText, 0, fullLyricsText.length, textPaint, CONTENT_WIDTH.toInt()
        )
            .setAlignment(Layout.Alignment.ALIGN_NORMAL)
            .setLineSpacing(12f, 1.15f)
            .setIncludePad(false)
            .build()

        canvas.save()
        canvas.translate(MARGIN, 320f)
        textLayout.draw(canvas)
        canvas.restore()

        // Bottom Footer: Song details & artwork
        val footerY = POSTER_HEIGHT - 220f
        val artSize = 130f

        if (coverArt != null && config.showArtwork) {
            drawSquircleArtwork(canvas, coverArt, MARGIN, footerY, artSize, cornerRadius = 24f)
        }

        val metaX = if (coverArt != null && config.showArtwork) MARGIN + artSize + 32f else MARGIN
        val metaWidth = POSTER_WIDTH - MARGIN - metaX

        val titlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.typeface = typeface
            textSize = 46f
            color = Color.WHITE
        }
        val artistPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.typeface = typeface
            textSize = 34f
            color = Color.argb(180, 255, 255, 255)
        }

        val title = ellipsised(config.song.title, titlePaint, metaWidth)
        val artist = ellipsised(config.song.artist, artistPaint, metaWidth)

        canvas.drawText(title, metaX, footerY + 54f, titlePaint)
        canvas.drawText(artist, metaX, footerY + 104f, artistPaint)
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
        val scale = size / bitmap.width.coerceAtMost(bitmap.height).toFloat()
        matrix.setScale(scale, scale)
        val dx = x - (bitmap.width * scale - size) / 2f
        val dy = y - (bitmap.height * scale - size) / 2f
        matrix.postTranslate(dx - x, dy - y)
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

    private suspend fun loadBitmap(context: Context, url: String): Bitmap? = runCatching {
        val request = ImageRequest.Builder(context)
            .data(url.artworkAt(800))
            .allowHardware(false)
            .build()
        (SingletonImageLoader.get(context).execute(request) as? SuccessResult)?.image?.toBitmap()
    }.getOrNull()
}
