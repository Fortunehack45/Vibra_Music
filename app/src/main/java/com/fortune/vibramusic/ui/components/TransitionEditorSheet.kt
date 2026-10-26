package com.fortune.vibramusic.ui.components

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Stop
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SheetState
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import coil3.compose.AsyncImage
import com.fortune.vibramusic.data.model.Song
import com.fortune.vibramusic.playback.mix.Curves
import com.fortune.vibramusic.playback.mix.LaneId
import com.fortune.vibramusic.playback.mix.MixAutoPlanner
import com.fortune.vibramusic.playback.mix.MixOptions
import com.fortune.vibramusic.playback.mix.MixPresets
import com.fortune.vibramusic.playback.mix.Point
import com.fortune.vibramusic.playback.mix.TransitionMode
import com.fortune.vibramusic.playback.mix.TransitionPlan
import com.fortune.vibramusic.playback.smart.EnergySample
import com.fortune.vibramusic.playback.smart.TrackAnalysis
import com.fortune.vibramusic.ui.haptics.Haptic
import com.fortune.vibramusic.ui.haptics.rememberHaptics
import java.util.Locale
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.sin

private val VibraPurple = Color(0xFF8B5CF6)

/**
 * Full interactive Transition Editor Sheet matching Spotify's Mix editor parity,
 * styled in Vibra Music's Apple-meets-Spotify dark liquid-glass aesthetic.
 * Renders in a full-screen Dialog covering the mini player and bottom navigation completely.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TransitionEditorSheet(
    fromSong: Song,
    toSong: Song,
    fromAnalysis: TrackAnalysis? = null,
    toAnalysis: TrackAnalysis? = null,
    initialPlan: TransitionPlan?,
    onSave: (TransitionPlan) -> Unit,
    onDismiss: () -> Unit,
    sheetState: SheetState? = null,
) {
    val haptics = rememberHaptics()

    var plan by remember(initialPlan, fromSong.videoId, toSong.videoId) {
        mutableStateOf(
            initialPlan ?: MixAutoPlanner.autoPlan(
                fromAnalysis,
                toAnalysis,
                fromSong.videoId,
                toSong.videoId,
            )
        )
    }

    var isPreviewPlaying by remember { mutableStateOf(false) }
    val pagerState = rememberPagerState(initialPage = 0) { 5 }
    var isCustomizing by remember { mutableStateOf(plan.mode == TransitionMode.CUSTOM) }
    var showLengthMenu by remember { mutableStateOf(false) }

    val durationA = remember(fromSong, fromAnalysis) { getSongDurationSeconds(fromSong, fromAnalysis) }
    val durationB = remember(toSong, toAnalysis) { getSongDurationSeconds(toSong, toAnalysis) }

    // Color definitions for the 5 automation lanes
    val volumeColor = Color(0xFF3B82F6) // Blue
    val eqColor = Color(0xFFF59E0B)     // Yellow
    val filterColor = Color(0xFFEC4899) // Pink
    val effectsColor = Color(0xFFFFFFFF)// White
    val loopingColor = Color(0xFFF97316)// Orange

    val currentLaneColor = when (pagerState.currentPage) {
        0 -> volumeColor
        1 -> eqColor
        2 -> filterColor
        3 -> effectsColor
        else -> loopingColor
    }

    // Playhead animation
    val infiniteTransition = rememberInfiniteTransition(label = "playhead loop")
    val animatedPlayhead by infiniteTransition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 4000, easing = LinearEasing),
        ),
        label = "playhead",
    )
    val playheadProgress = if (isPreviewPlaying) animatedPlayhead else 0f

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            decorFitsSystemWindows = false,
        ),
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color(0xFF09090B))
                .systemBarsPadding(),
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(bottom = 16.dp),
            ) {
                // Top Navigation Bar
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    IconButton(onClick = onDismiss) {
                        Icon(
                            imageVector = Icons.Rounded.Close,
                            contentDescription = "Close",
                            tint = Color.White,
                            modifier = Modifier.size(24.dp),
                        )
                    }

                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(6.dp))
                                .background(Color.White.copy(alpha = 0.12f))
                                .padding(horizontal = 8.dp, vertical = 2.dp),
                        ) {
                            Text(
                                text = "Beta",
                                style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.Bold),
                                color = Color.White.copy(alpha = 0.8f),
                            )
                        }

                        IconButton(
                            onClick = {
                                val reset = MixAutoPlanner.autoPlan(
                                    fromAnalysis,
                                    toAnalysis,
                                    fromSong.videoId,
                                    toSong.videoId,
                                )
                                plan = reset
                                isCustomizing = false
                            },
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.Refresh,
                                contentDescription = "Reset to Auto",
                                tint = Color.White.copy(alpha = 0.7f),
                                modifier = Modifier.size(20.dp),
                            )
                        }

                        // Save Button (Vibra Purple pill)
                        Box(
                            modifier = Modifier
                                .height(34.dp)
                                .clip(RoundedCornerShape(17.dp))
                                .background(VibraPurple)
                                .clickable {
                                    haptics.play(Haptic.Select)
                                    onSave(plan.copy(updatedAt = System.currentTimeMillis()))
                                    onDismiss()
                                }
                                .padding(horizontal = 18.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(
                                text = "Save",
                                style = MaterialTheme.typography.labelMedium.copy(
                                    fontWeight = FontWeight.Bold,
                                    color = Color.White,
                                ),
                            )
                        }
                    }
                }

                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .verticalScroll(rememberScrollState()),
                ) {
                    // Outgoing Track Header & Cut Scrubber (Song Shortening)
                    val minCutA = 15.0
                    val maxCutA = (durationA - plan.durationSeconds).coerceAtLeast(minCutA)
                    val currentCutA = (plan.startCutSeconds ?: maxCutA).coerceIn(minCutA, durationA)

                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 18.dp, vertical = 4.dp),
                    ) {
                        TrackHeaderRow(
                            song = fromSong,
                            bpm = fromAnalysis?.bpm,
                            camelotKey = fromAnalysis?.key,
                            relativeKey = toAnalysis?.key,
                        )
                        Spacer(Modifier.height(4.dp))
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                text = "Mix Out at: ${formatSeconds(currentCutA)} / ${formatSeconds(durationA)}",
                                style = MaterialTheme.typography.labelSmall.copy(
                                    fontWeight = FontWeight.SemiBold,
                                    fontSize = 11.sp,
                                ),
                                color = VibraPurple,
                            )
                            Text(
                                text = "Shorten / Cut point",
                                style = MaterialTheme.typography.labelSmall.copy(fontSize = 10.sp),
                                color = Color.White.copy(alpha = 0.5f),
                            )
                        }
                        Slider(
                            value = currentCutA.toFloat(),
                            onValueChange = { newSec ->
                                plan = plan.copy(
                                    startCutSeconds = newSec.toDouble().coerceIn(minCutA, maxCutA),
                                    mode = TransitionMode.CUSTOM,
                                )
                                isCustomizing = true
                            },
                            valueRange = minCutA.toFloat()..durationA.toFloat().coerceAtLeast(minCutA.toFloat() + 1f),
                            colors = SliderDefaults.colors(
                                thumbColor = VibraPurple,
                                activeTrackColor = VibraPurple,
                                inactiveTrackColor = Color.White.copy(alpha = 0.15f),
                            ),
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(26.dp),
                        )
                    }

                    Spacer(Modifier.height(4.dp))

                    // Dual Waveform Canvas with Curves and Playhead
                    DualWaveformEditor(
                        plan = plan,
                        fromAnalysis = fromAnalysis,
                        toAnalysis = toAnalysis,
                        fromSongId = fromSong.videoId,
                        toSongId = toSong.videoId,
                        durationA = durationA,
                        activeLane = when (pagerState.currentPage) {
                            0 -> LaneId.VOLUME
                            1 -> LaneId.EQ
                            2 -> LaneId.FILTER
                            3 -> LaneId.EFFECTS
                            else -> LaneId.LOOPING
                        },
                        laneColor = currentLaneColor,
                        playhead = playheadProgress,
                        isPlaying = isPreviewPlaying,
                        isCustomizing = isCustomizing,
                        onPlayToggle = {
                            haptics.play(Haptic.Resume)
                            isPreviewPlaying = !isPreviewPlaying
                        },
                        onBeginEditing = {
                            isCustomizing = true
                        },
                        onPointsChanged = { updatedOut, updatedIn ->
                            plan = when (pagerState.currentPage) {
                                0 -> plan.copy(
                                    mode = TransitionMode.CUSTOM,
                                    presetId = null,
                                    volume = plan.volume.copy(option = "custom", out = updatedOut, `in` = updatedIn),
                                )
                                1 -> plan.copy(
                                    mode = TransitionMode.CUSTOM,
                                    presetId = null,
                                    eq = plan.eq.copy(
                                        option = "custom",
                                        out = plan.eq.out.copy(low = updatedOut),
                                        `in` = plan.eq.`in`.copy(low = updatedIn),
                                    ),
                                )
                                2 -> plan.copy(
                                    mode = TransitionMode.CUSTOM,
                                    presetId = null,
                                    filter = plan.filter.copy(option = "custom", out = updatedOut, `in` = updatedIn),
                                )
                                3 -> plan.copy(
                                    mode = TransitionMode.CUSTOM,
                                    presetId = null,
                                    effects = plan.effects.copy(option = "custom", curve = updatedOut),
                                )
                                else -> plan
                            }
                        },
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(180.dp)
                            .padding(horizontal = 16.dp),
                    )

                    // Length selector pill below waveform
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(top = 4.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Row(
                            modifier = Modifier
                                .clip(RoundedCornerShape(12.dp))
                                .background(Color.White.copy(alpha = 0.08f))
                                .clickable { showLengthMenu = true }
                                .padding(horizontal = 12.dp, vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                text = "${plan.lengthBars} bars (${plan.durationSeconds.toInt()}s)",
                                style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.Medium),
                                color = Color.White.copy(alpha = 0.85f),
                            )
                            Icon(
                                imageVector = Icons.Rounded.KeyboardArrowDown,
                                contentDescription = null,
                                tint = Color.White.copy(alpha = 0.6f),
                                modifier = Modifier.size(16.dp),
                            )
                        }

                        DropdownMenu(
                            expanded = showLengthMenu,
                            onDismissRequest = { showLengthMenu = false },
                        ) {
                            listOf(2, 4, 8, 16).forEach { bars ->
                                DropdownMenuItem(
                                    text = { Text("$bars bars") },
                                    onClick = {
                                        showLengthMenu = false
                                        plan = plan.copy(lengthBars = bars)
                                    },
                                )
                            }
                        }
                    }

                    Spacer(Modifier.height(4.dp))

                    // Incoming Track Header & Cue Scrubber
                    val maxCueB = minOf(durationB * 0.45, 60.0).coerceAtLeast(5.0)
                    val currentCueB = plan.mixInSeconds.coerceIn(0.0, maxCueB)

                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 18.dp, vertical = 4.dp),
                    ) {
                        TrackHeaderRow(
                            song = toSong,
                            bpm = toAnalysis?.bpm,
                            camelotKey = toAnalysis?.key,
                            relativeKey = fromAnalysis?.key,
                        )
                        Spacer(Modifier.height(4.dp))
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                text = "Mix In at: ${formatSeconds(currentCueB)} / ${formatSeconds(durationB)}",
                                style = MaterialTheme.typography.labelSmall.copy(
                                    fontWeight = FontWeight.SemiBold,
                                    fontSize = 11.sp,
                                ),
                                color = VibraPurple,
                            )
                            Text(
                                text = "Cue point",
                                style = MaterialTheme.typography.labelSmall.copy(fontSize = 10.sp),
                                color = Color.White.copy(alpha = 0.5f),
                            )
                        }
                        Slider(
                            value = currentCueB.toFloat(),
                            onValueChange = { newSec ->
                                plan = plan.copy(
                                    mixInSeconds = newSec.toDouble().coerceIn(0.0, maxCueB),
                                    mode = TransitionMode.CUSTOM,
                                )
                                isCustomizing = true
                            },
                            valueRange = 0f..maxCueB.toFloat(),
                            colors = SliderDefaults.colors(
                                thumbColor = VibraPurple,
                                activeTrackColor = VibraPurple,
                                inactiveTrackColor = Color.White.copy(alpha = 0.15f),
                            ),
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(26.dp),
                        )
                    }

                    Spacer(Modifier.height(12.dp))

                    // Presets Horizontal Row
                    Text(
                        text = "Presets",
                        style = MaterialTheme.typography.titleSmall.copy(
                            fontWeight = FontWeight.SemiBold,
                            fontSize = 13.sp,
                        ),
                        color = Color.White.copy(alpha = 0.65f),
                        modifier = Modifier.padding(horizontal = 18.dp),
                    )

                    Spacer(Modifier.height(8.dp))

                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .horizontalScroll(rememberScrollState())
                            .padding(horizontal = 16.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        // Auto Preset
                        val isAuto = plan.mode == TransitionMode.AUTO
                        PresetPill(
                            label = "Auto",
                            icon = Icons.Rounded.AutoAwesome,
                            isSelected = isAuto,
                            onClick = {
                                haptics.play(Haptic.Select)
                                plan = MixAutoPlanner.autoPlan(fromAnalysis, toAnalysis, fromSong.videoId, toSong.videoId)
                                isCustomizing = false
                            },
                        )

                        // Custom Indicator
                        val isCustom = plan.mode == TransitionMode.CUSTOM
                        PresetPill(
                            label = "Custom",
                            isSelected = isCustom,
                            onClick = {
                                haptics.play(Haptic.Select)
                                isCustomizing = true
                                plan = plan.copy(mode = TransitionMode.CUSTOM, presetId = null)
                            },
                        )

                        // Standard Presets
                        MixPresets.presets.forEach { preset ->
                            val isSelected = plan.mode == TransitionMode.PRESET && plan.presetId == preset.id
                            PresetPill(
                                label = preset.label,
                                isSelected = isSelected,
                                onClick = {
                                    haptics.play(Haptic.Select)
                                    isCustomizing = false
                                    plan = TransitionPlan.applyPreset(plan, preset)
                                },
                            )
                        }
                    }

                    Spacer(Modifier.height(8.dp))

                    // Beatmatching Row
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 4.dp)
                            .clip(RoundedCornerShape(12.dp))
                            .background(Color.White.copy(alpha = 0.06f))
                            .padding(horizontal = 14.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.weight(1f),
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.Sync,
                                contentDescription = null,
                                tint = VibraPurple,
                                modifier = Modifier.size(20.dp),
                            )
                            Spacer(Modifier.width(10.dp))
                            Column {
                                Text(
                                    text = "Beatmatching",
                                    style = MaterialTheme.typography.labelMedium.copy(
                                        fontWeight = FontWeight.SemiBold,
                                        fontSize = 13.sp,
                                    ),
                                    color = Color.White,
                                )
                                Text(
                                    text = "Lock tempo and align downbeats across transition",
                                    style = MaterialTheme.typography.labelSmall.copy(fontSize = 11.sp),
                                    color = Color.White.copy(alpha = 0.6f),
                                )
                            }
                        }
                        Switch(
                            checked = plan.beatmatching,
                            onCheckedChange = { plan = plan.copy(beatmatching = it) },
                            colors = SwitchDefaults.colors(
                                checkedTrackColor = VibraPurple,
                                checkedThumbColor = Color.White,
                            ),
                        )
                    }

                    Spacer(Modifier.height(12.dp))

                    // 5-Lane Pager
                    HorizontalPager(
                        state = pagerState,
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(260.dp),
                    ) { page ->
                        when (page) {
                            0 -> VolumeLaneCard(
                                plan = plan,
                                color = volumeColor,
                                isCustomizing = isCustomizing,
                                onCustomizeToggle = { isCustomizing = !isCustomizing },
                                onOptionSelected = { optId ->
                                    val opt = MixOptions.findVolumeOption(optId)
                                    val curves = opt.build(plan.lengthBars)
                                    plan = plan.copy(
                                        volume = plan.volume.copy(option = optId, out = curves.out, `in` = curves.`in`),
                                    )
                                },
                            )
                            1 -> EqLaneCard(
                                plan = plan,
                                color = eqColor,
                                isCustomizing = isCustomizing,
                                onCustomizeToggle = { isCustomizing = !isCustomizing },
                                onOptionSelected = { optId ->
                                    val opt = MixOptions.findEqOption(optId)
                                    val bands = opt.build(plan.lengthBars)
                                    plan = plan.copy(
                                        eq = plan.eq.copy(option = optId, out = bands.out, `in` = bands.`in`),
                                    )
                                },
                            )
                            2 -> FilterLaneCard(
                                plan = plan,
                                color = filterColor,
                                isCustomizing = isCustomizing,
                                onCustomizeToggle = { isCustomizing = !isCustomizing },
                                onOptionSelected = { optId ->
                                    val opt = MixOptions.findFilterOption(optId)
                                    val curves = opt.build(plan.lengthBars)
                                    plan = plan.copy(
                                        filter = plan.filter.copy(option = optId, out = curves.out, `in` = curves.`in`),
                                    )
                                },
                            )
                            3 -> EffectsLaneCard(
                                plan = plan,
                                color = effectsColor,
                                isCustomizing = isCustomizing,
                                onCustomizeToggle = { isCustomizing = !isCustomizing },
                                onOptionSelected = { optId ->
                                    val opt = MixOptions.findEffectsOption(optId)
                                    plan = plan.copy(
                                        effects = plan.effects.copy(
                                            option = optId,
                                            type = opt.type,
                                            echoBeats = opt.echoBeats,
                                            tail = opt.tail,
                                            curve = opt.curve,
                                        ),
                                    )
                                },
                            )
                            else -> LoopingLaneCard(
                                plan = plan,
                                color = loopingColor,
                                onOptionSelected = { beats ->
                                    val opt = MixOptions.findLoopingOption(beats)
                                    plan = plan.copy(
                                        looping = plan.looping.copy(option = opt.id, beats = opt.beats),
                                    )
                                },
                            )
                        }
                    }

                    // Pager Dots Indicator
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 10.dp),
                        horizontalArrangement = Arrangement.Center,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        repeat(5) { index ->
                            val isSelected = pagerState.currentPage == index
                            Box(
                                modifier = Modifier
                                    .padding(horizontal = 4.dp)
                                    .size(if (isSelected) 7.dp else 5.dp)
                                    .clip(CircleShape)
                                    .background(if (isSelected) Color.White else Color.White.copy(alpha = 0.25f)),
                            )
                        }
                    }
                }
            }
        }
    }
}

// Sub-components

@Composable
private fun TrackHeaderRow(
    song: Song,
    bpm: Double?,
    camelotKey: String?,
    relativeKey: String?,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.weight(1f),
        ) {
            Box(
                modifier = Modifier
                    .size(36.dp)
                    .clip(RoundedCornerShape(6.dp))
                    .background(Color.DarkGray),
            ) {
                AsyncImage(
                    model = song.thumbnailUrl,
                    contentDescription = null,
                    modifier = Modifier.fillMaxSize(),
                )
            }
            Spacer(Modifier.width(10.dp))
            Column {
                Text(
                    text = song.title,
                    style = MaterialTheme.typography.titleMedium.copy(
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 14.sp,
                    ),
                    color = Color.White,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = song.artist,
                    style = MaterialTheme.typography.bodySmall.copy(
                        fontSize = 12.sp,
                    ),
                    color = Color.White.copy(alpha = 0.6f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }

        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            MixBadge(
                bpm = bpm,
                camelotKey = camelotKey,
                relativeToKey = relativeKey,
            )
            song.durationText?.let {
                Text(
                    text = it,
                    style = MaterialTheme.typography.labelSmall.copy(fontSize = 11.sp),
                    color = Color.White.copy(alpha = 0.6f),
                )
            }
        }
    }
}

@Composable
private fun PresetPill(
    label: String,
    isSelected: Boolean,
    onClick: () -> Unit,
    icon: androidx.compose.ui.graphics.vector.ImageVector? = null,
) {
    Row(
        modifier = Modifier
            .height(34.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(if (isSelected) Color.White else Color.White.copy(alpha = 0.08f))
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        if (icon != null) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = if (isSelected) Color.Black else Color.White,
                modifier = Modifier.size(15.dp),
            )
            Spacer(Modifier.width(6.dp))
        }
        Text(
            text = label,
            style = MaterialTheme.typography.labelMedium.copy(
                fontWeight = FontWeight.SemiBold,
                color = if (isSelected) Color.Black else Color.White,
            ),
        )
    }
}

@Composable
private fun DualWaveformEditor(
    plan: TransitionPlan,
    fromAnalysis: TrackAnalysis?,
    toAnalysis: TrackAnalysis?,
    fromSongId: String,
    toSongId: String,
    durationA: Double,
    activeLane: LaneId,
    laneColor: Color,
    playhead: Float,
    isPlaying: Boolean,
    isCustomizing: Boolean,
    onPlayToggle: () -> Unit,
    onBeginEditing: () -> Unit,
    onPointsChanged: (outPoints: List<Point>, inPoints: List<Point>) -> Unit,
    modifier: Modifier = Modifier,
) {
    var selectedPointId by remember { mutableStateOf<String?>(null) }

    val outPoints = when (activeLane) {
        LaneId.VOLUME -> plan.volume.out
        LaneId.EQ -> plan.eq.out.low
        LaneId.FILTER -> plan.filter.out
        LaneId.EFFECTS -> plan.effects.curve
        LaneId.LOOPING -> emptyList()
    }

    val inPoints = when (activeLane) {
        LaneId.VOLUME -> plan.volume.`in`
        LaneId.EQ -> plan.eq.`in`.low
        LaneId.FILTER -> plan.filter.`in`
        else -> emptyList()
    }

    Box(
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .background(Color(0xFF18181B)),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(
            modifier = Modifier
                .fillMaxSize()
                .pointerInput(outPoints, inPoints) {
                    detectTapGestures { offset ->
                        onBeginEditing()
                        val w = size.width.toFloat()
                        val h = size.height.toFloat()
                        val halfH = h * 0.5f

                        if (offset.y <= halfH && outPoints.isNotEmpty()) {
                            val (dist, t) = Curves.distanceToCurvePx(outPoints, w, halfH, offset.x, offset.y)
                            if (dist < 60f) {
                                val next = Curves.addPointOnLine(outPoints, t)
                                onPointsChanged(next, inPoints)
                            }
                        } else if (offset.y > halfH && inPoints.isNotEmpty()) {
                            val localY = offset.y - halfH
                            val (dist, t) = Curves.distanceToCurvePx(inPoints, w, halfH, offset.x, localY)
                            if (dist < 60f) {
                                val next = Curves.addPointOnLine(inPoints, t)
                                onPointsChanged(outPoints, next)
                            }
                        }
                    }
                }
                .pointerInput(outPoints, inPoints) {
                    detectDragGestures(
                        onDragStart = { offset ->
                            onBeginEditing()
                            val w = size.width.toFloat()
                            val h = size.height.toFloat()
                            val halfH = h * 0.5f

                            var foundId: String? = null
                            // 75f (~28dp) generous touch radius
                            for (p in outPoints) {
                                val px = p.t * w
                                val py = (1f - p.v) * halfH
                                if (hypot(offset.x - px, offset.y - py) < 75f) {
                                    foundId = p.id
                                    break
                                }
                            }
                            if (foundId == null) {
                                for (p in inPoints) {
                                    val px = p.t * w
                                    val py = halfH + (1f - p.v) * halfH
                                    if (hypot(offset.x - px, offset.y - py) < 75f) {
                                        foundId = p.id
                                        break
                                    }
                                }
                            }
                            if (foundId == null) {
                                // If touched near curve line, add point immediately
                                if (offset.y <= halfH && outPoints.isNotEmpty()) {
                                    val (dist, t) = Curves.distanceToCurvePx(outPoints, w, halfH, offset.x, offset.y)
                                    if (dist < 50f) {
                                        val next = Curves.addPointOnLine(outPoints, t)
                                        onPointsChanged(next, inPoints)
                                        foundId = next.minByOrNull { abs(it.t - t) }?.id
                                    }
                                } else if (offset.y > halfH && inPoints.isNotEmpty()) {
                                    val localY = offset.y - halfH
                                    val (dist, t) = Curves.distanceToCurvePx(inPoints, w, halfH, offset.x, localY)
                                    if (dist < 50f) {
                                        val next = Curves.addPointOnLine(inPoints, t)
                                        onPointsChanged(outPoints, next)
                                        foundId = next.minByOrNull { abs(it.t - t) }?.id
                                    }
                                }
                            }
                            selectedPointId = foundId
                        },
                        onDrag = { change, dragAmount ->
                            change.consume()
                            val id = selectedPointId ?: return@detectDragGestures
                            val w = size.width.toFloat()
                            val h = size.height.toFloat()
                            val halfH = h * 0.5f

                            val currentPos = change.position
                            val normT = (currentPos.x / w).coerceIn(0.01f, 0.99f)

                            if (outPoints.any { it.id == id }) {
                                val normV = (1f - (currentPos.y / halfH)).coerceIn(0f, 1f)
                                val updated = Curves.movePoint(outPoints, id, normT, normV)
                                onPointsChanged(updated, inPoints)
                            } else if (inPoints.any { it.id == id }) {
                                val normV = (1f - ((currentPos.y - halfH) / halfH)).coerceIn(0f, 1f)
                                val updated = Curves.movePoint(inPoints, id, normT, normV)
                                onPointsChanged(outPoints, updated)
                            }
                        },
                        onDragEnd = { selectedPointId = null },
                        onDragCancel = { selectedPointId = null },
                    )
                },
        ) {
            val w = size.width
            val h = size.height
            val halfH = h * 0.5f

            // Beat grid vertical lines
            val bars = plan.lengthBars * 4
            val step = w / bars.toFloat()

            for (i in 0..bars) {
                val x = i * step
                drawLine(
                    color = Color.White.copy(alpha = if (i % 4 == 0) 0.15f else 0.06f),
                    start = Offset(x, 0f),
                    end = Offset(x, h),
                    strokeWidth = if (i % 4 == 0) 1.5f else 0.75f,
                )
            }

            // Real Multi-Band Waveform Rendering
            val cutA = plan.startCutSeconds ?: (durationA - plan.durationSeconds)
            val startSecA = (cutA - plan.durationSeconds).coerceAtLeast(0.0)
            val windowSecA = plan.durationSeconds

            val cueB = plan.mixInSeconds
            val windowSecB = plan.durationSeconds

            val hasRealAnalysisA = fromAnalysis?.energyCurve?.isNotEmpty() == true
            val hasRealAnalysisB = toAnalysis?.energyCurve?.isNotEmpty() == true

            fun drawRealWaveform(
                topOffset: Float,
                isOutgoing: Boolean,
            ) {
                val midY = topOffset + halfH * 0.5f
                val seed = if (isOutgoing) fromSongId.hashCode().toFloat() else toSongId.hashCode().toFloat()

                for (x in 0 until w.toInt() step 4) {
                    val xf = x.toFloat()
                    val normX = xf / w

                    val (highEnergy, bassEnergy, coreEnergy) = if (isOutgoing) {
                        if (hasRealAnalysisA) {
                            val time = startSecA + normX * windowSecA
                            val core = sampleEnergyAt(fromAnalysis!!.energyCurve, time).toFloat().coerceIn(0.08f, 1f)
                            val bass = if (fromAnalysis.lowEnergyCurve.isNotEmpty()) {
                                sampleEnergyAt(fromAnalysis.lowEnergyCurve, time).toFloat().coerceIn(0.04f, 1f)
                            } else core * 0.7f
                            val high = (core - bass).coerceAtLeast(0.05f)
                            Triple(high, bass, core)
                        } else {
                            fallbackWaveformEnergy(xf, seed)
                        }
                    } else {
                        if (hasRealAnalysisB) {
                            val time = cueB + normX * windowSecB
                            val core = sampleEnergyAt(toAnalysis!!.energyCurve, time).toFloat().coerceIn(0.08f, 1f)
                            val bass = if (toAnalysis.lowEnergyCurve.isNotEmpty()) {
                                sampleEnergyAt(toAnalysis.lowEnergyCurve, time).toFloat().coerceIn(0.04f, 1f)
                            } else core * 0.7f
                            val high = (core - bass).coerceAtLeast(0.05f)
                            Triple(high, bass, core)
                        } else {
                            fallbackWaveformEnergy(xf, seed)
                        }
                    }

                    val maxAmp = halfH * 0.44f

                    // High transients / upper frequencies (Cyan/Blue)
                    drawLine(
                        color = Color(0xFF38BDF8),
                        start = Offset(xf, midY - highEnergy * maxAmp * 1.1f),
                        end = Offset(xf, midY + highEnergy * maxAmp * 1.1f),
                        strokeWidth = 2f,
                    )
                    // Low frequencies / bass energy (Amber/Orange)
                    drawLine(
                        color = Color(0xFFF59E0B),
                        start = Offset(xf, midY - bassEnergy * maxAmp * 0.75f),
                        end = Offset(xf, midY + bassEnergy * maxAmp * 0.75f),
                        strokeWidth = 2f,
                    )
                    // Core RMS center body (Light White)
                    drawLine(
                        color = Color(0xFFE2E8F0),
                        start = Offset(xf, midY - coreEnergy * maxAmp * 0.3f),
                        end = Offset(xf, midY + coreEnergy * maxAmp * 0.3f),
                        strokeWidth = 1.5f,
                    )
                }
            }

            drawRealWaveform(0f, isOutgoing = true)
            drawRealWaveform(halfH, isOutgoing = false)

            // Divider between outgoing and incoming tracks
            drawLine(
                color = Color.White.copy(alpha = 0.12f),
                start = Offset(0f, halfH),
                end = Offset(w, halfH),
                strokeWidth = 1f,
            )

            // Draw Automation Curves
            fun drawCurvePoints(points: List<Point>, topOffset: Float) {
                if (points.size < 2) return
                val sorted = Curves.sortPoints(points)

                val path = Path()
                for (i in 0 until 100) {
                    val t = i / 99f
                    val v = Curves.evaluate(sorted, t)
                    val x = t * w
                    val y = topOffset + (1f - v) * halfH
                    if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
                }
                drawPath(path, color = laneColor, style = Stroke(width = 2.5f, cap = StrokeCap.Round))

                // Draw Control Points
                for (p in sorted) {
                    val px = p.t * w
                    val py = topOffset + (1f - p.v) * halfH
                    drawCircle(color = laneColor, radius = 8f, center = Offset(px, py))
                    drawCircle(color = Color.White, radius = 3.5f, center = Offset(px, py))
                }
            }

            drawCurvePoints(outPoints, 0f)
            if (activeLane != LaneId.EFFECTS) {
                drawCurvePoints(inPoints, halfH)
            }

            // Draw Moving Playhead (Vibra Purple vertical bar)
            if (playhead > 0f) {
                val phX = playhead * w
                drawLine(
                    color = VibraPurple,
                    start = Offset(phX, 0f),
                    end = Offset(phX, h),
                    strokeWidth = 2.5f,
                )
            }
        }

        // Center Play / Stop toggle button
        Box(
            modifier = Modifier
                .size(36.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(Color(0xFF27272A).copy(alpha = 0.9f))
                .clickable(onClick = onPlayToggle),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = if (isPlaying) Icons.Rounded.Stop else Icons.Rounded.PlayArrow,
                contentDescription = if (isPlaying) "Stop" else "Play",
                tint = Color.White,
                modifier = Modifier.size(20.dp),
            )
        }
    }
}

// Lane Cards

@Composable
private fun VolumeLaneCard(
    plan: TransitionPlan,
    color: Color,
    isCustomizing: Boolean,
    onCustomizeToggle: () -> Unit,
    onOptionSelected: (String) -> Unit,
) {
    LaneContainer(
        title = "Volume",
        color = color,
        isCustomizing = isCustomizing,
        onCustomizeToggle = onCustomizeToggle,
    ) {
        MixOptions.volumeOptions.forEach { opt ->
            val isSelected = plan.volume.option == opt.id
            LaneOptionRow(label = opt.label, isSelected = isSelected) {
                onOptionSelected(opt.id)
            }
        }
    }
}

@Composable
private fun EqLaneCard(
    plan: TransitionPlan,
    color: Color,
    isCustomizing: Boolean,
    onCustomizeToggle: () -> Unit,
    onOptionSelected: (String) -> Unit,
) {
    LaneContainer(
        title = "EQ",
        color = color,
        isCustomizing = isCustomizing,
        onCustomizeToggle = onCustomizeToggle,
    ) {
        MixOptions.eqOptions.forEach { opt ->
            val isSelected = plan.eq.option == opt.id
            LaneOptionRow(label = opt.label, isSelected = isSelected) {
                onOptionSelected(opt.id)
            }
        }
    }
}

@Composable
private fun FilterLaneCard(
    plan: TransitionPlan,
    color: Color,
    isCustomizing: Boolean,
    onCustomizeToggle: () -> Unit,
    onOptionSelected: (String) -> Unit,
) {
    LaneContainer(
        title = "Filter",
        color = color,
        isCustomizing = isCustomizing,
        onCustomizeToggle = onCustomizeToggle,
    ) {
        MixOptions.filterOptions.forEach { opt ->
            val isSelected = plan.filter.option == opt.id
            LaneOptionRow(label = opt.label, isSelected = isSelected) {
                onOptionSelected(opt.id)
            }
        }
    }
}

@Composable
private fun EffectsLaneCard(
    plan: TransitionPlan,
    color: Color,
    isCustomizing: Boolean,
    onCustomizeToggle: () -> Unit,
    onOptionSelected: (String) -> Unit,
) {
    LaneContainer(
        title = "Effects",
        color = color,
        isCustomizing = isCustomizing,
        onCustomizeToggle = onCustomizeToggle,
    ) {
        MixOptions.effectsOptions.forEach { opt ->
            val isSelected = plan.effects.option == opt.id
            LaneOptionRow(label = opt.label, isSelected = isSelected) {
                onOptionSelected(opt.id)
            }
        }
    }
}

@Composable
private fun LoopingLaneCard(
    plan: TransitionPlan,
    color: Color,
    onOptionSelected: (Int) -> Unit,
) {
    LaneContainer(
        title = "Looping",
        color = color,
        isCustomizing = false,
        onCustomizeToggle = {},
    ) {
        MixOptions.loopingOptions.forEach { opt ->
            val isSelected = plan.looping.beats == opt.beats
            LaneOptionRow(label = opt.label, isSelected = isSelected) {
                onOptionSelected(opt.beats)
            }
        }
    }
}

@Composable
private fun LaneContainer(
    title: String,
    color: Color,
    isCustomizing: Boolean,
    onCustomizeToggle: () -> Unit,
    content: @Composable () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 16.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(Color(0xFF1C1C1E))
            .padding(16.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .width(4.dp)
                        .height(18.dp)
                        .clip(RoundedCornerShape(2.dp))
                        .background(color),
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    text = title,
                    style = MaterialTheme.typography.titleMedium.copy(
                        fontWeight = FontWeight.Bold,
                        fontSize = 17.sp,
                    ),
                    color = Color.White,
                )
            }

            Text(
                text = if (isCustomizing) "Editing" else "Customize",
                style = MaterialTheme.typography.labelMedium.copy(
                    fontWeight = FontWeight.Bold,
                    color = VibraPurple,
                ),
                modifier = Modifier
                    .clip(RoundedCornerShape(6.dp))
                    .clickable(onClick = onCustomizeToggle)
                    .padding(horizontal = 6.dp, vertical = 2.dp),
            )
        }

        Spacer(Modifier.height(12.dp))

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState()),
        ) {
            content()
        }
    }
}

@Composable
private fun LaneOptionRow(
    label: String,
    isSelected: Boolean,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .clickable(onClick = onClick)
            .padding(vertical = 10.dp, horizontal = 4.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.bodyMedium.copy(
                fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                fontSize = 15.sp,
            ),
            color = Color.White,
        )

        if (isSelected) {
            Icon(
                imageVector = Icons.Rounded.Check,
                contentDescription = "Selected",
                tint = VibraPurple,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

// Helpers

private fun sampleEnergyAt(
    energyList: List<EnergySample>,
    timeSec: Double,
): Double {
    if (energyList.isEmpty()) return 0.5
    var low = 0
    var high = energyList.size - 1
    while (low <= high) {
        val mid = (low + high) ushr 1
        val sample = energyList[mid]
        if (sample.time < timeSec) low = mid + 1
        else if (sample.time > timeSec) high = mid - 1
        else return sample.energy
    }
    val idx = low.coerceIn(0, energyList.size - 1)
    return energyList[idx].energy
}

private fun fallbackWaveformEnergy(xf: Float, seed: Float): Triple<Float, Float, Float> {
    val s1 = sin((xf * 0.08f) + seed) * 0.5f + 0.5f
    val s2 = sin((xf * 0.22f) + seed * 2f) * 0.3f
    val s3 = sin((xf * 0.55f) + seed * 3f) * 0.2f
    val total = (s1 + s2 + s3).coerceIn(0.1f, 1.0f)
    val bass = (sin((xf * 0.04f) + seed) * 0.4f + 0.6f) * total
    val high = (abs(sin(xf * 0.35f)) * 0.5f + 0.5f) * total
    return Triple(high, bass, total)
}

private fun getSongDurationSeconds(song: Song, analysis: TrackAnalysis?): Double {
    if (analysis != null && analysis.duration > 0.0) return analysis.duration
    val text = song.durationText ?: return 180.0
    val parts = text.split(":").mapNotNull { it.trim().toIntOrNull() }
    return when (parts.size) {
        2 -> (parts[0] * 60 + parts[1]).toDouble()
        3 -> (parts[0] * 3600 + parts[1] * 60 + parts[2]).toDouble()
        else -> 180.0
    }
}

private fun formatSeconds(seconds: Double): String {
    val totalSec = seconds.toInt().coerceAtLeast(0)
    val m = totalSec / 60
    val s = totalSec % 60
    return "%d:%02d".format(Locale.ROOT, m, s)
}
