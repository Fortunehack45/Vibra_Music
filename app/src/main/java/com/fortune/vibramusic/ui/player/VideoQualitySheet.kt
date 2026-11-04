package com.fortune.vibramusic.ui.player

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Fullscreen
import androidx.compose.material.icons.rounded.FullscreenExit
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.request.ImageRequest
import com.fortune.vibramusic.R
import com.fortune.vibramusic.data.model.Song
import com.fortune.vibramusic.ui.haptics.Haptic
import com.fortune.vibramusic.ui.haptics.rememberHaptics
import com.fortune.vibramusic.ui.theme.HideSystemBars
import dev.chrisbanes.haze.HazeState
import kotlinx.coroutines.delay

/** How long the controls stay over a playing video untouched. */
private const val VIDEO_CONTROLS_IDLE_MS = 3_500L

/**
 * State representing video quality renditions and selection.
 */
data class VideoQualityUi(
    val heights: List<Int> = listOf(1080, 720, 480, 360, 240, 144),
    val held: Int? = null,
    val activeHeight: Int? = 480,
) {
    fun selected(): Int? = if (held == null || held !in heights) activeHeight else held
}

/**
 * Marketing name for resolution heights, matching BitChord specification.
 */
fun videoQualityLabel(height: Int): String = when {
    height >= 4320 -> "8K"
    height >= 2160 -> "4K"
    height >= 1440 -> "2K"
    height >= 1080 -> "FullHD"
    height >= 720 -> "HD"
    else -> "${height}p"
}

/** What the quality box and drawer say is playing: the held height, else the one on screen. */
fun MusicVideoQualityUi.selected(): Int? =
    if (held == null || held !in heights) activeHeight else held

/**
 * What stands in for a music video until its first frame lands: black, with a
 * spinner, rather than the still artwork. Shared by the portrait card and the
 * fullscreen landscape player.
 */
@Composable
fun VideoLoadingBackdrop(modifier: Modifier = Modifier) {
    Box(modifier.background(Color.Black), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(
            color = Color.White,
            strokeWidth = 3.dp,
            modifier = Modifier.size(36.dp),
        )
    }
}

/**
 * Corner controls overlaying the video: Quality badge button + Fullscreen toggle.
 */
@Composable
fun VideoCornerControls(
    fullscreen: Boolean,
    onToggleFullscreen: () -> Unit,
    onOpenQuality: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val engineQuality by MusicVideoEngine.quality.collectAsStateWithLifecycle()
    val label = engineQuality.selected()?.let(::videoQualityLabel) ?: "Auto"

    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .height(30.dp)
                .widthIn(min = 44.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(Color.Black.copy(alpha = 0.38f))
                .clickable(onClick = onOpenQuality)
                .padding(horizontal = 8.dp),
            contentAlignment = Alignment.Center,
        ) {
            AnimatedContent(
                targetState = label,
                transitionSpec = { fadeIn(tween(180)) togetherWith fadeOut(tween(180)) },
                label = "videoQualityBadge",
            ) { text ->
                Text(
                    text = text,
                    color = Color.White.copy(alpha = 0.95f),
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 0.4.sp,
                    maxLines = 1,
                )
            }
        }

        Box(
            modifier = Modifier
                .size(30.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(Color.Black.copy(alpha = 0.38f))
                .clickable(onClick = onToggleFullscreen),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = if (fullscreen) Icons.Rounded.FullscreenExit else Icons.Rounded.Fullscreen,
                contentDescription = if (fullscreen) "Exit Fullscreen" else "Fullscreen",
                tint = Color.White,
                modifier = Modifier.size(20.dp),
            )
        }
    }
}

@Composable
fun VideoCornerControls(
    quality: VideoQualityUi,
    fullscreen: Boolean,
    onToggleFullscreen: () -> Unit,
    onOpenQuality: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val label = quality.selected()?.let(::videoQualityLabel) ?: "Auto"
    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .height(30.dp)
                .widthIn(min = 44.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(Color.Black.copy(alpha = 0.38f))
                .clickable(onClick = onOpenQuality)
                .padding(horizontal = 8.dp),
            contentAlignment = Alignment.Center,
        ) {
            AnimatedContent(
                targetState = label,
                transitionSpec = { fadeIn(tween(180)) togetherWith fadeOut(tween(180)) },
                label = "videoQualityBadge",
            ) { text ->
                Text(
                    text = text,
                    color = Color.White.copy(alpha = 0.95f),
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 0.4.sp,
                    maxLines = 1,
                )
            }
        }

        Box(
            modifier = Modifier
                .size(30.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(Color.Black.copy(alpha = 0.38f))
                .clickable(onClick = onToggleFullscreen),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = if (fullscreen) Icons.Rounded.FullscreenExit else Icons.Rounded.Fullscreen,
                contentDescription = if (fullscreen) "Exit Fullscreen" else "Fullscreen",
                tint = Color.White,
                modifier = Modifier.size(20.dp),
            )
        }
    }
}

/**
 * A music video on a phone held sideways: the picture is the whole screen,
 * letterboxed in black, with the system bars away. A tap brings the controls
 * up over it — the title, the scrubber and the transport — and they stand
 * down again a few seconds after the last touch while it plays, as in every
 * video player. [onExitFullscreen] goes back to the ordinary landscape player.
 */
@Composable
fun FullscreenVideoPlayer(
    song: Song,
    isPlaying: Boolean,
    artRequest: ImageRequest,
    onRenderedChanged: (Boolean) -> Unit,
    rendered: Boolean,
    onExitFullscreen: () -> Unit,
    onOpenQuality: () -> Unit,
    scrubber: @Composable () -> Unit,
    transport: @Composable () -> Unit,
    modifier: Modifier = Modifier,
) {
    HideSystemBars(true)
    var controlsShown by remember { mutableStateOf(true) }
    var touches by remember { mutableIntStateOf(0) }
    LaunchedEffect(controlsShown, isPlaying, touches) {
        if (controlsShown && isPlaying) {
            delay(VIDEO_CONTROLS_IDLE_MS)
            controlsShown = false
        }
    }

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(Color.Black)
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
            ) { controlsShown = !controlsShown },
    ) {
        if (!rendered) {
            VideoLoadingBackdrop(Modifier.fillMaxSize())
        }
        AndroidMusicVideo(
            videoId = song.videoId,
            fit = true,
            onRenderedChanged = onRenderedChanged,
            modifier = Modifier.fillMaxSize(),
            priority = 2,
        )

        AnimatedVisibility(
            visible = controlsShown,
            enter = fadeIn(tween(200)),
            exit = fadeOut(tween(300)),
            modifier = Modifier.fillMaxSize(),
        ) {
            Box(
                Modifier
                    .fillMaxSize()
                    .background(
                        Brush.verticalGradient(
                            0f to Color.Black.copy(alpha = 0.62f),
                            0.30f to Color.Transparent,
                            0.55f to Color.Transparent,
                            1f to Color.Black.copy(alpha = 0.78f),
                        ),
                    )
                    .pointerInput(Unit) {
                        awaitPointerEventScope {
                            while (true) {
                                awaitPointerEvent(PointerEventPass.Initial)
                                touches++
                            }
                        }
                    }
                    .windowInsetsPadding(WindowInsets.displayCutout)
                    .padding(horizontal = 24.dp, vertical = 16.dp),
            ) {
                Row(
                    modifier = Modifier
                        .align(Alignment.TopStart)
                        .fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(
                            text = song.title,
                            color = Color.White,
                            fontSize = 18.sp,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Text(
                            text = song.artist,
                            color = Color.White.copy(alpha = 0.7f),
                            fontSize = 14.sp,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    VideoCornerControls(
                        fullscreen = true,
                        onToggleFullscreen = onExitFullscreen,
                        onOpenQuality = onOpenQuality,
                    )
                }

                Box(
                    Modifier
                        .align(Alignment.Center)
                        .widthIn(max = 420.dp),
                ) {
                    transport()
                }

                Column(
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .fillMaxWidth(),
                    verticalArrangement = Arrangement.Bottom,
                ) {
                    scrubber()
                }
            }
        }
    }
}

/**
 * Liquid Glass Video Quality Bottom Sheet matching BitChord design (Image 5).
 * Implemented using [PlayerDrawer] with frosted backdrop and [ROW_SHAPE] capsules.
 */
@Composable
fun VideoQualitySheet(
    hazeState: HazeState,
    onDismiss: () -> Unit,
) {
    val quality by MusicVideoEngine.quality.collectAsStateWithLifecycle()
    val selected = quality.selected()

    PlayerDrawer(
        hazeState = hazeState,
        title = stringResource(R.string.video_quality),
        onDismiss = onDismiss,
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            // Auto Option
            QualityRow(
                name = stringResource(R.string.video_quality_auto),
                detail = if (quality.held == null) selected?.let(::videoQualityLabel) else null,
                active = quality.held == null,
            ) {
                MusicVideoEngine.setQuality(null)
                onDismiss()
            }

            // Heights available
            quality.heights.forEach { height ->
                QualityRow(
                    name = videoQualityLabel(height),
                    detail = "${height}p",
                    active = quality.held != null && selected == height,
                ) {
                    MusicVideoEngine.setQuality(height)
                    onDismiss()
                }
            }
        }
    }
}

@Composable
fun VideoQualitySheet(
    onDismiss: () -> Unit,
) {
    val quality by MusicVideoEngine.quality.collectAsStateWithLifecycle()
    val selected = quality.selected()

    PlayerDrawer(
        hazeState = HazeState(),
        title = stringResource(R.string.video_quality),
        onDismiss = onDismiss,
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            QualityRow(
                name = stringResource(R.string.video_quality_auto),
                detail = if (quality.held == null) selected?.let(::videoQualityLabel) else null,
                active = quality.held == null,
            ) {
                MusicVideoEngine.setQuality(null)
                onDismiss()
            }
            quality.heights.forEach { height ->
                QualityRow(
                    name = videoQualityLabel(height),
                    detail = "${height}p",
                    active = quality.held != null && selected == height,
                ) {
                    MusicVideoEngine.setQuality(height)
                    onDismiss()
                }
            }
        }
    }
}

@Composable
private fun QualityRow(
    name: String,
    detail: String?,
    active: Boolean,
    onSelect: () -> Unit,
) {
    val haptics = rememberHaptics()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(ROW_SHAPE)
            .background(Color.White.copy(alpha = if (active) 0.10f else 0.05f))
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                enabled = !active,
            ) {
                haptics.play(Haptic.Select)
                onSelect()
            }
            .padding(horizontal = 16.dp, vertical = 15.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = name,
            style = MaterialTheme.typography.bodyLarge.copy(
                fontWeight = if (active) FontWeight.SemiBold else FontWeight.Normal,
            ),
            color = Color.White.copy(alpha = if (active) 1f else 0.85f),
            maxLines = 1,
            modifier = Modifier.weight(1f),
        )

        if (detail != null) {
            Text(
                text = detail,
                style = MaterialTheme.typography.labelMedium,
                color = Color.White.copy(alpha = 0.55f),
                modifier = Modifier.padding(horizontal = 10.dp),
            )
        }

        Box(
            modifier = Modifier.size(20.dp),
            contentAlignment = Alignment.Center,
        ) {
            if (active) {
                Icon(
                    imageVector = Icons.Rounded.Check,
                    contentDescription = null,
                    tint = Color.White,
                    modifier = Modifier.size(20.dp),
                )
            }
        }
    }
}
