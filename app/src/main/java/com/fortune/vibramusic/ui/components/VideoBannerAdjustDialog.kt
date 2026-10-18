package com.fortune.vibramusic.ui.components

import android.net.Uri
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.compose.foundation.Canvas as ComposeCanvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.RotateRight
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView

@Composable
fun VideoBannerAdjustDialog(
    videoUri: Uri,
    targetAspectRatio: Float = 16f / 9f,
    title: String = "Adjust Video Banner",
    onDismiss: () -> Unit,
    onConfirm: (adjustedUri: Uri, rotation: Float, scale: Float, panX: Float, panY: Float) -> Unit,
) {
    val context = LocalContext.current

    var scale by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    var rotationAngle by remember { mutableFloatStateOf(0f) }

    val exoPlayer = remember(videoUri) {
        ExoPlayer.Builder(context.applicationContext).build().apply {
            repeatMode = Player.REPEAT_MODE_ALL
            volume = 0f
            setMediaItem(MediaItem.fromUri(videoUri))
            prepare()
            playWhenReady = true
        }
    }

    DisposableEffect(exoPlayer) {
        onDispose {
            exoPlayer.release()
        }
    }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            decorFitsSystemWindows = false,
        ),
    ) {
        Surface(
            modifier = Modifier
                .fillMaxSize()
                .background(Color.Black),
            color = Color.Black,
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .statusBarsPadding()
                    .navigationBarsPadding(),
            ) {
                // Header Bar
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 12.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconButton(
                        onClick = onDismiss,
                        modifier = Modifier
                            .size(40.dp)
                            .background(Color.White.copy(alpha = 0.12f), CircleShape),
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.Close,
                            contentDescription = "Cancel",
                            tint = Color.White,
                        )
                    }

                    Text(
                        text = title,
                        style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                        color = Color.White,
                    )

                    IconButton(
                        onClick = {
                            val adjusted = videoUri.buildUpon()
                                .appendQueryParameter("rot", rotationAngle.toInt().toString())
                                .appendQueryParameter("scale", "%.2f".format(java.util.Locale.US, scale))
                                .appendQueryParameter("panX", "%.1f".format(java.util.Locale.US, offset.x))
                                .appendQueryParameter("panY", "%.1f".format(java.util.Locale.US, offset.y))
                                .build()
                            onConfirm(adjusted, rotationAngle, scale, offset.x, offset.y)
                        },
                        modifier = Modifier
                            .size(40.dp)
                            .background(MaterialTheme.colorScheme.primary, CircleShape),
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.Check,
                            contentDescription = "Done",
                            tint = MaterialTheme.colorScheme.onPrimary,
                        )
                    }
                }

                // Interactive Video Viewport
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth()
                        .padding(16.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    BoxWithConstraints(
                        modifier = Modifier.fillMaxSize(),
                        contentAlignment = Alignment.Center,
                    ) {
                        val maxW = maxWidth
                        val maxH = maxHeight

                        val (frameW, frameH) = if (targetAspectRatio >= 1f) {
                            val w = maxW
                            val h = (maxW.value / targetAspectRatio).coerceAtMost(maxH.value).dp
                            Pair(w, h)
                        } else {
                            val h = maxH
                            val w = (maxH.value * targetAspectRatio).coerceAtMost(maxW.value).dp
                            Pair(w, h)
                        }

                        Box(
                            modifier = Modifier
                                .size(frameW, frameH)
                                .clipToBounds()
                                .border(2.dp, MaterialTheme.colorScheme.primary, RoundedCornerShape(12.dp))
                                .pointerInput(Unit) {
                                    detectTransformGestures { _, pan, zoom, _ ->
                                        scale = (scale * zoom).coerceIn(1f, 4f)
                                        offset = Offset(
                                            x = offset.x + pan.x,
                                            y = offset.y + pan.y,
                                        )
                                    }
                                },
                            contentAlignment = Alignment.Center,
                        ) {
                            AndroidView(
                                factory = { ctx ->
                                    PlayerView(ctx).apply {
                                        player = exoPlayer
                                        useController = false
                                        resizeMode = androidx.media3.ui.AspectRatioFrameLayout.RESIZE_MODE_ZOOM
                                        layoutParams = FrameLayout.LayoutParams(
                                            ViewGroup.LayoutParams.MATCH_PARENT,
                                            ViewGroup.LayoutParams.MATCH_PARENT,
                                        )
                                    }
                                },
                                modifier = Modifier
                                    .fillMaxSize()
                                    .graphicsLayer {
                                        scaleX = scale
                                        scaleY = scale
                                        translationX = offset.x
                                        translationY = offset.y
                                        rotationZ = rotationAngle
                                    },
                            )

                            // Composition Grid Lines
                            ComposeCanvas(modifier = Modifier.fillMaxSize()) {
                                val strokeWidth = 1.dp.toPx()
                                val gridColor = Color.White.copy(alpha = 0.35f)
                                val colW = size.width / 3f
                                val rowH = size.height / 3f

                                drawLine(
                                    color = gridColor,
                                    start = Offset(colW, 0f),
                                    end = Offset(colW, size.height),
                                    strokeWidth = strokeWidth,
                                )
                                drawLine(
                                    color = gridColor,
                                    start = Offset(colW * 2, 0f),
                                    end = Offset(colW * 2, size.height),
                                    strokeWidth = strokeWidth,
                                )
                                drawLine(
                                    color = gridColor,
                                    start = Offset(0f, rowH),
                                    end = Offset(size.width, rowH),
                                    strokeWidth = strokeWidth,
                                )
                                drawLine(
                                    color = gridColor,
                                    start = Offset(0f, rowH * 2),
                                    end = Offset(size.width, rowH * 2),
                                    strokeWidth = strokeWidth,
                                )
                            }
                        }
                    }
                }

                // Controls Footer
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(Color.White.copy(alpha = 0.05f))
                        .padding(horizontal = 24.dp, vertical = 16.dp),
                ) {
                    // Zoom Slider
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            text = "Zoom",
                            style = MaterialTheme.typography.labelMedium,
                            color = Color.White.copy(alpha = 0.7f),
                            modifier = Modifier.width(52.dp),
                        )
                        Slider(
                            value = scale,
                            onValueChange = { scale = it },
                            valueRange = 1f..4f,
                            colors = SliderDefaults.colors(
                                thumbColor = MaterialTheme.colorScheme.primary,
                                activeTrackColor = MaterialTheme.colorScheme.primary,
                                inactiveTrackColor = Color.White.copy(alpha = 0.2f),
                            ),
                            modifier = Modifier.weight(1f),
                        )
                        Text(
                            text = "%.1fx".format(java.util.Locale.US, scale),
                            style = MaterialTheme.typography.labelSmall,
                            color = Color.White.copy(alpha = 0.7f),
                            modifier = Modifier
                                .width(40.dp)
                                .padding(start = 8.dp),
                        )
                    }

                    Spacer(Modifier.height(8.dp))

                    // Action Buttons (Rotate & Reset)
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        IconButton(
                            onClick = {
                                rotationAngle = (rotationAngle + 90f) % 360f
                            },
                            modifier = Modifier
                                .size(44.dp)
                                .background(Color.White.copy(alpha = 0.12f), CircleShape),
                        ) {
                            Icon(
                                imageVector = Icons.AutoMirrored.Rounded.RotateRight,
                                contentDescription = "Rotate 90 degrees",
                                tint = Color.White,
                            )
                        }

                        Text(
                            text = "${rotationAngle.toInt()}°",
                            style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                            color = Color.White.copy(alpha = 0.8f),
                        )

                        TextButton(
                            onClick = {
                                scale = 1f
                                offset = Offset.Zero
                                rotationAngle = 0f
                            },
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.Refresh,
                                contentDescription = null,
                                tint = Color.White.copy(alpha = 0.7f),
                                modifier = Modifier.size(16.dp),
                            )
                            Spacer(Modifier.width(6.dp))
                            Text(
                                text = "Reset",
                                color = Color.White.copy(alpha = 0.7f),
                                style = MaterialTheme.typography.labelMedium,
                            )
                        }
                    }
                }
            }
        }
    }
}
