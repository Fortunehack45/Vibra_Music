package com.fortune.vibramusic.ui.lyrics

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.widget.Toast
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.IosShare
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import com.fortune.vibramusic.R
import com.fortune.vibramusic.data.model.Song
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import java.util.Locale

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LyricShareSheet(
    song: Song,
    selectedLines: List<String>,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var cardStyle by remember { mutableStateOf(LyricCardStyle.LYRICS_CARD) }
    var palette by remember { mutableStateOf(LyricCardPalette.ARTWORK) }
    var font by remember { mutableStateOf(LyricCardFont.SF_PRO) }
    var showArtwork by remember { mutableStateOf(true) }

    var poster by remember { mutableStateOf<Bitmap?>(null) }
    var isRendering by remember { mutableStateOf(true) }
    var isSaved by remember { mutableStateOf(false) }

    val config = remember(song, selectedLines, cardStyle, palette, font, showArtwork) {
        LyricShareConfig(
            song = song,
            selectedLines = selectedLines,
            cardStyle = cardStyle,
            palette = palette,
            font = font,
            showArtwork = showArtwork,
        )
    }

    LaunchedEffect(config) {
        isRendering = true
        poster = runCatching {
            LyricPosterRenderer.render(context, config)
        }.getOrNull()
        isRendering = false
    }

    val maxSheetHeight = LocalConfiguration.current.screenHeightDp.dp * 0.92f

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.surface,
        contentColor = MaterialTheme.colorScheme.onSurface,
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
        dragHandle = {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 10.dp),
                contentAlignment = Alignment.Center,
            ) {
                Box(
                    modifier = Modifier
                        .size(width = 36.dp, height = 4.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f)),
                )
            }
        },
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = maxSheetHeight)
                .navigationBarsPadding()
                .padding(horizontal = 20.dp)
                .verticalScroll(rememberScrollState()),
        ) {
            // Header
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column {
                    Text(
                        text = stringResource(R.string.share_lyrics),
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold,
                    )
                    Text(
                        text = stringResource(R.string.lyrics_selected, selectedLines.size, 5),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                IconButton(onClick = onDismiss) {
                    Icon(
                        imageVector = Icons.Rounded.Close,
                        contentDescription = stringResource(R.string.cancel),
                    )
                }
            }

            Spacer(Modifier.height(14.dp))

            // 9:16 Aspect Ratio Live Card Preview
            Box(
                modifier = Modifier
                    .fillMaxWidth(0.52f)
                    .align(Alignment.CenterHorizontally)
                    .aspectRatio(9f / 16f)
                    .clip(RoundedCornerShape(20.dp))
                    .border(
                        1.dp,
                        MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f),
                        RoundedCornerShape(20.dp),
                    )
                    .background(MaterialTheme.colorScheme.surfaceVariant),
                contentAlignment = Alignment.Center,
            ) {
                val image = poster
                if (image != null) {
                    Image(
                        bitmap = image.asImageBitmap(),
                        contentDescription = stringResource(R.string.share_lyrics),
                        contentScale = ContentScale.Fit,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                if (isRendering) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(36.dp),
                        strokeWidth = 3.dp,
                    )
                }
            }

            Spacer(Modifier.height(20.dp))

            // Style Switcher (Lyrics Card vs Song Card)
            SegmentedStyleSelector(
                selectedStyle = cardStyle,
                onStyleSelected = { cardStyle = it },
            )

            Spacer(Modifier.height(18.dp))

            // Color Palette Selector
            Text(
                text = "Card Theme",
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(bottom = 8.dp),
            )
            PaletteSelector(
                current = palette,
                onSelect = { palette = it },
            )

            Spacer(Modifier.height(18.dp))

            // Font Selector
            Text(
                text = "Typography",
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(bottom = 8.dp),
            )
            FontSelector(
                current = font,
                onSelect = { font = it },
            )

            if (cardStyle == LyricCardStyle.LYRICS_CARD) {
                Spacer(Modifier.height(14.dp))
                // Toggle Show Artwork
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(14.dp))
                        .clickable { showArtwork = !showArtwork }
                        .padding(vertical = 4.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = "Show cover artwork",
                        style = MaterialTheme.typography.bodyMedium,
                        fontWeight = FontWeight.Medium,
                    )
                    Switch(
                        checked = showArtwork,
                        onCheckedChange = { showArtwork = it },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Color.White,
                            checkedTrackColor = Color(0xFFE50914),
                        ),
                    )
                }
            }

            Spacer(Modifier.height(22.dp))

            // Action Buttons: Save & Share
            val ready = poster != null && !isRendering
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                // Save to Photos
                ActionButton(
                    label = if (isSaved) stringResource(R.string.image_saved) else stringResource(R.string.save_image),
                    icon = if (isSaved) Icons.Rounded.Check else Icons.Rounded.Download,
                    accent = false,
                    enabled = ready,
                    modifier = Modifier.weight(1f),
                ) {
                    val bitmap = poster ?: return@ActionButton
                    scope.launch {
                        val saved = savePosterToGallery(context, bitmap, song.title)
                        isSaved = saved
                        if (saved) {
                            Toast.makeText(context, R.string.image_saved, Toast.LENGTH_SHORT).show()
                        }
                    }
                }

                // Share Poster
                ActionButton(
                    label = stringResource(R.string.share),
                    icon = Icons.Rounded.IosShare,
                    accent = true,
                    enabled = ready,
                    modifier = Modifier.weight(1f),
                ) {
                    val bitmap = poster ?: return@ActionButton
                    scope.launch {
                        val uri = cachePosterForSharing(context, bitmap) ?: return@launch
                        val shareIntent = buildShareIntent(context, uri, song, selectedLines)
                        context.startActivity(
                            Intent.createChooser(shareIntent, context.getString(R.string.share_lyrics)),
                        )
                        onDismiss()
                    }
                }
            }

            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun SegmentedStyleSelector(
    selectedStyle: LyricCardStyle,
    onStyleSelected: (LyricCardStyle) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f))
            .padding(4.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        LyricCardStyle.entries.forEach { style ->
            val selected = selectedStyle == style
            val bg by animateColorAsState(
                targetValue = if (selected) MaterialTheme.colorScheme.surface else Color.Transparent,
                animationSpec = tween(200),
                label = "segBg",
            )
            val fg = if (selected) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant

            Box(
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(10.dp))
                    .background(bg)
                    .clickable { onStyleSelected(style) }
                    .padding(vertical = 10.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = stringResource(style.labelRes),
                    style = MaterialTheme.typography.labelLarge,
                    fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
                    color = fg,
                )
            }
        }
    }
}

@Composable
private fun PaletteSelector(
    current: LyricCardPalette,
    onSelect: (LyricCardPalette) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        LyricCardPalette.entries.forEach { palette ->
            val selected = current == palette
            val gradient = Brush.linearGradient(
                listOf(palette.primaryColor, palette.secondaryColor),
            )
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier
                    .clip(RoundedCornerShape(12.dp))
                    .clickable { onSelect(palette) }
                    .padding(4.dp),
            ) {
                Box(
                    modifier = Modifier
                        .size(44.dp)
                        .clip(CircleShape)
                        .background(gradient)
                        .border(
                            width = if (selected) 2.5.dp else 1.dp,
                            color = if (selected) Color(0xFFE50914) else Color.White.copy(alpha = 0.25f),
                            shape = CircleShape,
                        ),
                    contentAlignment = Alignment.Center,
                ) {
                    if (selected) {
                        Icon(
                            imageVector = Icons.Rounded.Check,
                            contentDescription = null,
                            tint = Color.White,
                            modifier = Modifier.size(20.dp),
                        )
                    }
                }
                Spacer(Modifier.height(4.dp))
                Text(
                    text = palette.label,
                    style = MaterialTheme.typography.labelSmall,
                    fontSize = 11.sp,
                    fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal,
                    color = if (selected) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun FontSelector(
    current: LyricCardFont,
    onSelect: (LyricCardFont) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        LyricCardFont.entries.forEach { font ->
            val selected = current == font
            val bg = if (selected) Color(0xFFE50914).copy(alpha = 0.15f) else MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
            val border = if (selected) Color(0xFFE50914) else Color.Transparent

            Box(
                modifier = Modifier
                    .clip(RoundedCornerShape(12.dp))
                    .background(bg)
                    .border(1.dp, border, RoundedCornerShape(12.dp))
                    .clickable { onSelect(font) }
                    .padding(horizontal = 14.dp, vertical = 9.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = font.label,
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
                    color = if (selected) Color(0xFFE50914) else MaterialTheme.colorScheme.onSurface,
                )
            }
        }
    }
}

@Composable
private fun ActionButton(
    label: String,
    icon: ImageVector,
    accent: Boolean,
    enabled: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val background = when {
        accent -> Color(0xFFE50914)
        else -> MaterialTheme.colorScheme.surfaceVariant
    }
    val foreground = when {
        accent -> Color.White
        else -> MaterialTheme.colorScheme.onSurface
    }
    Row(
        modifier = modifier
            .clip(RoundedCornerShape(16.dp))
            .background(background.copy(alpha = if (enabled) 1f else 0.4f))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(vertical = 15.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = foreground,
            modifier = Modifier.size(20.dp),
        )
        Spacer(Modifier.width(8.dp))
        Text(
            text = label,
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.Bold,
            color = foreground,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

private fun buildShareIntent(
    context: Context,
    uri: Uri,
    song: Song,
    lines: List<String>,
): Intent {
    val lyricSnippet = lines.take(3).joinToString("\n") { "“$it”" }
    val caption = buildString {
        append(lyricSnippet)
        append("\n\n")
        append(song.title)
        append(" — ")
        append(song.artist)
        append("\n")
        append("Shared via Vibra Music: https://fortuneadebayo.space/")
    }

    return Intent(Intent.ACTION_SEND).apply {
        type = "image/png"
        putExtra(Intent.EXTRA_STREAM, uri)
        putExtra(Intent.EXTRA_TEXT, caption)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
}

private suspend fun cachePosterForSharing(context: Context, bitmap: Bitmap): Uri? =
    withContext(Dispatchers.IO) {
        runCatching {
            val folder = File(context.cacheDir, "shared").apply { mkdirs() }
            val file = File(folder, "vibra-lyrics.png")
            FileOutputStream(file).use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        }.getOrNull()
    }

private suspend fun savePosterToGallery(
    context: Context,
    bitmap: Bitmap,
    label: String,
): Boolean = withContext(Dispatchers.IO) {
    val safeLabel = label.replace(Regex("[^a-zA-Z0-9.-]"), "_").lowercase(Locale.ROOT)
    val name = "vibra-lyrics-$safeLabel-${System.currentTimeMillis()}.png"
    runCatching {
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, name)
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(
                    MediaStore.Images.Media.RELATIVE_PATH,
                    "${Environment.DIRECTORY_PICTURES}/Vibra Music",
                )
            }
        }
        val uri = context.contentResolver
            .insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
            ?: error("no row")
        context.contentResolver.openOutputStream(uri)?.use {
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
        } ?: error("no stream")
        true
    }.getOrDefault(false)
}
