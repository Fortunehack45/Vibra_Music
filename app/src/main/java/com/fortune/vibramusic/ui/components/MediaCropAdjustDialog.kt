package com.fortune.vibramusic.ui.components

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.net.Uri
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
import androidx.compose.foundation.layout.aspectRatio
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.roundToInt

@Composable
fun MediaCropAdjustDialog(
    imageUri: Uri,
    targetAspectRatio: Float = 1f,
    title: String = "Adjust Media",
    onDismiss: () -> Unit,
    onConfirm: (Bitmap) -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var sourceBitmap by remember { mutableStateOf<Bitmap?>(null) }
    var isLoading by remember { mutableStateOf(true) }
    var scale by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    var rotationAngle by remember { mutableFloatStateOf(0f) }

    LaunchedEffect(imageUri) {
        withContext(Dispatchers.IO) {
            runCatching {
                context.contentResolver.openInputStream(imageUri)?.use { input ->
                    BitmapFactory.decodeStream(input)
                }
            }.onSuccess { bmp ->
                sourceBitmap = bmp
                isLoading = false
            }.onFailure {
                isLoading = false
            }
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
                // Header
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
                            .clip(CircleShape)
                            .background(Color.White.copy(alpha = 0.12f)),
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
                            val bmp = sourceBitmap ?: return@IconButton
                            scope.launch(Dispatchers.Default) {
                                val cropped = cropBitmap(
                                    source = bmp,
                                    targetAspect = targetAspectRatio,
                                    scale = scale,
                                    offset = offset,
                                    rotation = rotationAngle,
                                )
                                withContext(Dispatchers.Main) {
                                    onConfirm(cropped)
                                }
                            }
                        },
                        enabled = !isLoading && sourceBitmap != null,
                        modifier = Modifier
                            .size(40.dp)
                            .clip(CircleShape)
                            .background(MaterialTheme.colorScheme.primary),
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.Check,
                            contentDescription = "Done",
                            tint = MaterialTheme.colorScheme.onPrimary,
                        )
                    }
                }

                // Viewport & Crop Frame
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth()
                        .padding(16.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    if (isLoading) {
                        CircularProgressIndicator(
                            color = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.size(48.dp),
                        )
                    } else if (sourceBitmap != null) {
                        val bmp = sourceBitmap!!
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

                            // Interactive Viewport
                            Box(
                                modifier = Modifier
                                    .size(frameW, frameH)
                                    .clipToBounds()
                                    .border(2.dp, MaterialTheme.colorScheme.primary, RoundedCornerShape(12.dp))
                                    .pointerInput(Unit) {
                                        detectTransformGestures { _, pan, zoom, _ ->
                                            scale = (scale * zoom).coerceIn(1f, 5f)
                                            offset = Offset(
                                                x = offset.x + pan.x,
                                                y = offset.y + pan.y,
                                            )
                                        }
                                    },
                                contentAlignment = Alignment.Center,
                            ) {
                                androidx.compose.foundation.Image(
                                    bitmap = bmp.asImageBitmap(),
                                    contentDescription = null,
                                    contentScale = ContentScale.Fit,
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

                                // Rule of thirds grid lines
                                ComposeCanvas(modifier = Modifier.fillMaxSize()) {
                                    val strokeWidth = 1.dp.toPx()
                                    val gridColor = Color.White.copy(alpha = 0.35f)
                                    val colW = size.width / 3f
                                    val rowH = size.height / 3f

                                    // Vertical lines
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

                                    // Horizontal lines
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
                    } else {
                        Text(
                            text = "Failed to load image",
                            color = Color.White.copy(alpha = 0.6f),
                            style = MaterialTheme.typography.bodyMedium,
                        )
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
                            valueRange = 1f..5f,
                            colors = SliderDefaults.colors(
                                thumbColor = MaterialTheme.colorScheme.primary,
                                activeTrackColor = MaterialTheme.colorScheme.primary,
                                inactiveTrackColor = Color.White.copy(alpha = 0.2f),
                            ),
                            modifier = Modifier.weight(1f),
                        )
                    }

                    Spacer(Modifier.height(8.dp))

                    // Buttons: Reset & Rotate 90
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
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
                                tint = Color.White.copy(alpha = 0.8f),
                                modifier = Modifier.size(18.dp),
                            )
                            Spacer(Modifier.width(6.dp))
                            Text(
                                text = "Reset",
                                color = Color.White.copy(alpha = 0.8f),
                                style = MaterialTheme.typography.labelMedium,
                            )
                        }

                        IconButton(
                            onClick = {
                                rotationAngle = (rotationAngle + 90f) % 360f
                            },
                            modifier = Modifier
                                .size(42.dp)
                                .clip(CircleShape)
                                .background(Color.White.copy(alpha = 0.12f)),
                        ) {
                            Icon(
                                imageVector = Icons.AutoMirrored.Rounded.RotateRight,
                                contentDescription = "Rotate 90 degrees",
                                tint = Color.White,
                            )
                        }
                    }
                }
            }
        }
    }
}

private fun cropBitmap(
    source: Bitmap,
    targetAspect: Float,
    scale: Float,
    offset: Offset,
    rotation: Float,
): Bitmap {
    val targetWidth = if (targetAspect >= 1f) 1080 else (1080 * targetAspect).roundToInt()
    val targetHeight = (targetWidth / targetAspect).roundToInt().coerceAtLeast(1)

    val outBitmap = Bitmap.createBitmap(targetWidth, targetHeight, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(outBitmap)
    val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)

    val matrix = Matrix()
    // Center source on origin
    matrix.postTranslate(-source.width / 2f, -source.height / 2f)
    // Rotate
    matrix.postRotate(rotation)
    // Scale to fit viewport frame with user zoom
    val baseScale = maxOf(
        targetWidth.toFloat() / source.width.toFloat(),
        targetHeight.toFloat() / source.height.toFloat(),
    )
    val totalScale = baseScale * scale
    matrix.postScale(totalScale, totalScale)
    // Apply user translation offset
    matrix.postTranslate(targetWidth / 2f + offset.x, targetHeight / 2f + offset.y)

    canvas.drawBitmap(source, matrix, paint)
    return outBitmap
}
