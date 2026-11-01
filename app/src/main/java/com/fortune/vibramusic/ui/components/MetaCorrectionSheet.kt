package com.fortune.vibramusic.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.fortune.vibramusic.playback.smart.CamelotKey
import com.fortune.vibramusic.playback.smart.Field
import com.fortune.vibramusic.playback.smart.MetaSchedulerHolder
import com.fortune.vibramusic.playback.smart.MetaSource
import com.fortune.vibramusic.playback.smart.TrackMeta
import com.fortune.vibramusic.playback.smart.TrackMetaRepository
import com.fortune.vibramusic.ui.haptics.Haptic
import com.fortune.vibramusic.ui.haptics.rememberHaptics
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

class TapTempo {
    private val taps = ArrayDeque<Long>()
    fun tap(nowMs: Long = System.currentTimeMillis()): Double? {
        if (taps.isNotEmpty() && nowMs - taps.last() > 2000L) taps.clear()
        taps.addLast(nowMs)
        if (taps.size > 8) taps.removeFirst()
        if (taps.size < 4) return null
        val gaps = taps.zipWithNext { a, b -> (b - a).toDouble() }.sorted()
        return 60000.0 / gaps[gaps.size / 2]
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MetaCorrectionSheet(
    trackId: String,
    title: String,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val haptics = rememberHaptics()
    val meta = TrackMetaRepository.peek(trackId)

    var currentBpm by remember { mutableDoubleStateOf(meta?.bpm?.value ?: 120.0) }
    var currentKey by remember { mutableStateOf(meta?.key?.value ?: CamelotKey.parse("8A")!!) }
    val tapTempo = remember { TapTempo() }

    val allKeys = remember {
        // Camelot 1 to 12 for both B (Major) and A (Minor)
        (1..12).map { "${it}B" } + (1..12).map { "${it}A" }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = MaterialTheme.colorScheme.surface,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 24.dp, vertical = 16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                text = "Adjust BPM & Key",
                style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold),
            )
            Text(
                text = title,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            Spacer(modifier = Modifier.height(20.dp))

            // BPM Controls
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                OutlinedButton(
                    onClick = {
                        currentBpm = (currentBpm / 2.0).coerceAtLeast(40.0)
                        haptics.play(Haptic.Select)
                    },
                    shape = RoundedCornerShape(8.dp),
                ) {
                    Text("/2")
                }

                Text(
                    text = "${currentBpm.roundToInt()} BPM",
                    style = MaterialTheme.typography.headlineMedium.copy(fontWeight = FontWeight.Bold),
                )

                OutlinedButton(
                    onClick = {
                        currentBpm = (currentBpm * 2.0).coerceAtMost(240.0)
                        haptics.play(Haptic.Select)
                    },
                    shape = RoundedCornerShape(8.dp),
                ) {
                    Text("x2")
                }
            }

            Spacer(modifier = Modifier.height(12.dp))

            // Tap Tempo Button
            OutlinedButton(
                onClick = {
                    haptics.play(Haptic.Select)
                    tapTempo.tap()?.let { currentBpm = it }
                },
                modifier = Modifier.fillMaxWidth(0.6f),
                shape = RoundedCornerShape(12.dp),
            ) {
                Text("Tap Tempo", style = MaterialTheme.typography.labelLarge)
            }

            Spacer(modifier = Modifier.height(24.dp))

            // Key Wheel Grid
            Text(
                text = "Camelot Key (${currentKey.code})",
                style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.SemiBold),
            )
            Spacer(modifier = Modifier.height(8.dp))

            LazyVerticalGrid(
                columns = GridCells.Fixed(6),
                modifier = Modifier
                    .fillMaxWidth()
                    .height(120.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                items(allKeys) { keyCode ->
                    val isSelected = currentKey.code.equals(keyCode, ignoreCase = true)
                    val isMajor = keyCode.endsWith("B", ignoreCase = true)
                    Box(
                        modifier = Modifier
                            .height(32.dp)
                            .clip(RoundedCornerShape(6.dp))
                            .background(
                                if (isSelected) {
                                    MaterialTheme.colorScheme.primary
                                } else if (isMajor) {
                                    Color(0xFFD97706).copy(alpha = 0.2f)
                                } else {
                                    Color(0xFF2563EB).copy(alpha = 0.2f)
                                }
                            )
                            .clickable {
                                CamelotKey.parse(keyCode)?.let { currentKey = it }
                                haptics.play(Haptic.Select)
                            },
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            text = keyCode,
                            style = MaterialTheme.typography.labelSmall.copy(
                                fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Normal,
                                color = if (isSelected) Color.White else MaterialTheme.colorScheme.onSurface,
                            ),
                        )
                    }
                }
            }

            Spacer(modifier = Modifier.height(24.dp))

            // Save / Apply Button
            OutlinedButton(
                onClick = {
                    scope.launch {
                        val dao = MetaSchedulerHolder.getDao(context)
                        TrackMetaRepository.ingest(
                            TrackMeta(
                                trackId = trackId,
                                bpm = Field(currentBpm, 1.0f, MetaSource.USER),
                                key = Field(currentKey, 1.0f, MetaSource.USER),
                                updatedAt = System.currentTimeMillis(),
                            ),
                            dao,
                        )
                    }
                    onDismiss()
                },
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(12.dp),
                colors = ButtonDefaults.outlinedButtonColors(
                    containerColor = MaterialTheme.colorScheme.primary,
                    contentColor = Color.White,
                ),
            ) {
                Text("Save Changes", style = MaterialTheme.typography.titleSmall)
            }

            Spacer(modifier = Modifier.height(16.dp))
        }
    }
}
