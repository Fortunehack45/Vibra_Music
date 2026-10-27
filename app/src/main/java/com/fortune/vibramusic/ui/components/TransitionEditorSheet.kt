package com.fortune.vibramusic.ui.components

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.runtime.collectAsState
import com.fortune.vibramusic.data.settings.AppSettings
import com.fortune.vibramusic.playback.previewTransition
import com.fortune.vibramusic.playback.rememberMediaController
import com.fortune.vibramusic.playback.stopPreviewTransition
import kotlin.math.hypot
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Repeat
import androidx.compose.material.icons.rounded.Stop
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material.icons.automirrored.rounded.VolumeUp
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.material3.SheetState
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
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
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.Locale
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.sin

private val VibraPurple = Color(0xFF8B5CF6)
private val VolumeBlue = Color(0xFF38BDF8)
private val EqYellow = Color(0xFFFACC15)
private val FilterPink = Color(0xFFEC4899)
private val EffectsWhite = Color(0xFFFFFFFF)
private val LoopingOrange = Color(0xFFF97316)

/**
 * Full interactive Transition Editor Sheet matching Spotify's Mix editor parity,
 * styled in Vibra Music's liquid-glass aesthetic.
 * Renders in a full-screen Dialog covering the entire screen.
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
    val context = LocalContext.current
    val haptics = rememberHaptics()
    val scope = rememberCoroutineScope()

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
    var playheadProgress by remember { mutableFloatStateOf(0f) }
    var isDraggingPoint by remember { mutableStateOf(false) }
    var focusedLane by remember { mutableStateOf<LaneId?>(null) }
    var showLoopingSheet by remember { mutableStateOf(false) }
    var showLengthMenu by remember { mutableStateOf(false) }

    val controller = rememberMediaController()
    val servicePreviewPlaying by AppSettings.transitionPreviewPlaying.collectAsState()
    val servicePreviewProgress by AppSettings.transitionPreviewProgress.collectAsState()

    val effectiveIsPlaying = servicePreviewPlaying || isPreviewPlaying
    val effectivePlayhead = if (servicePreviewPlaying) servicePreviewProgress else playheadProgress

    val durationA = remember(fromSong, fromAnalysis) { getSongDurationSeconds(fromSong, fromAnalysis) }
    val durationB = remember(toSong, toAnalysis) { getSongDurationSeconds(toSong, toAnalysis) }

    // Audio Focus Manager for Real Audio Preview
    val audioManager = remember { context.getSystemService(Context.AUDIO_SERVICE) as AudioManager }
    var audioFocusRequest: AudioFocusRequest? by remember { mutableStateOf(null) }

    fun stopPreview() {
        isPreviewPlaying = false
        playheadProgress = 0f
        controller?.stopPreviewTransition()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(null)
        }
        audioFocusRequest = null
    }

    fun startPreview() {
        if (controller != null) {
            controller.previewTransition(fromSong, toSong, plan)
            return
        }

        isPreviewPlaying = true
        playheadProgress = 0f

        // Request transient audio focus to cleanly pause background music
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build()
                )
                .build()
            audioFocusRequest = req
            audioManager.requestAudioFocus(req)
        } else {
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(null, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
        }

        // Animate playhead and evaluate blend progression
        scope.launch {
            val totalDurationMs = (plan.durationSeconds * 1000.0).toLong().coerceAtLeast(2000L)
            val startTime = System.currentTimeMillis()
            while (isPreviewPlaying) {
                val elapsed = System.currentTimeMillis() - startTime
                val progress = (elapsed.toFloat() / totalDurationMs.toFloat()).coerceIn(0f, 1f)
                playheadProgress = progress
                if (progress >= 1f) {
                    stopPreview()
                    break
                }
                delay(30L)
            }
        }
    }

    DisposableEffect(Unit) {
        onDispose {
            stopPreview()
        }
    }

    Dialog(
        onDismissRequest = {
            stopPreview()
            onDismiss()
        },
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
                    if (focusedLane != null) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .clip(RoundedCornerShape(8.dp))
                                .clickable { focusedLane = null }
                                .padding(horizontal = 4.dp, vertical = 4.dp),
                        ) {
                            Icon(
                                imageVector = Icons.AutoMirrored.Rounded.ArrowBack,
                                contentDescription = "Back",
                                tint = Color.White,
                                modifier = Modifier.size(22.dp),
                            )
                            Spacer(Modifier.width(8.dp))
                            Text(
                                text = focusedLane?.name?.lowercase()?.replaceFirstChar { it.uppercase() } ?: "",
                                style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                                color = Color.White,
                            )
                        }
                    } else {
                        IconButton(onClick = {
                            stopPreview()
                            onDismiss()
                        }) {
                            Icon(
                                imageVector = Icons.Rounded.Close,
                                contentDescription = "Close",
                                tint = Color.White,
                                modifier = Modifier.size(24.dp),
                            )
                        }
                    }

                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        if (focusedLane == null) {
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
                                },
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.Refresh,
                                    contentDescription = "Reset to Auto",
                                    tint = Color.White.copy(alpha = 0.7f),
                                    modifier = Modifier.size(20.dp),
                                )
                            }
                        }

                        // Save / Done Button (Vibra Purple pill)
                        Box(
                            modifier = Modifier
                                .height(34.dp)
                                .clip(RoundedCornerShape(17.dp))
                                .background(VibraPurple)
                                .clickable {
                                    haptics.play(Haptic.Select)
                                    if (focusedLane != null) {
                                        focusedLane = null
                                    } else {
                                        stopPreview()
                                        onSave(plan.copy(updatedAt = System.currentTimeMillis()))
                                        onDismiss()
                                    }
                                }
                                .padding(horizontal = 18.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(
                                text = if (focusedLane != null) "Done" else "Save",
                                style = MaterialTheme.typography.labelMedium.copy(
                                    fontWeight = FontWeight.Bold,
                                    color = Color.White,
                                ),
                            )
                        }
                    }
                }

                val scrollState = rememberScrollState()
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .verticalScroll(scrollState, enabled = !isDraggingPoint),
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

                    // Dual Waveform Canvas with Spotify-Parity Multi-Lane Curves & Looping Block
                    DualWaveformEditor(
                        plan = plan,
                        fromAnalysis = fromAnalysis,
                        toAnalysis = toAnalysis,
                        fromSongId = fromSong.videoId,
                        toSongId = toSong.videoId,
                        durationA = durationA,
                        focusedLane = focusedLane,
                        playhead = effectivePlayhead,
                        isPlaying = effectiveIsPlaying,
                        onPlayToggle = {
                            haptics.play(Haptic.Resume)
                            if (effectiveIsPlaying) {
                                stopPreview()
                            } else {
                                startPreview()
                            }
                        },
                        onDragPointActive = { active ->
                            isDraggingPoint = active
                        },
                        onPointsChanged = { updatedOut, updatedIn ->
                            plan = when (focusedLane) {
                                LaneId.VOLUME -> plan.copy(
                                    mode = TransitionMode.CUSTOM,
                                    presetId = null,
                                    volume = plan.volume.copy(option = "custom", out = updatedOut, `in` = updatedIn),
                                )
                                LaneId.EQ -> plan.copy(
                                    mode = TransitionMode.CUSTOM,
                                    presetId = null,
                                    eq = plan.eq.copy(
                                        option = "custom",
                                        out = plan.eq.out.copy(low = updatedOut),
                                        `in` = plan.eq.`in`.copy(low = updatedIn),
                                    ),
                                )
                                LaneId.FILTER -> plan.copy(
                                    mode = TransitionMode.CUSTOM,
                                    presetId = null,
                                    filter = plan.filter.copy(option = "custom", out = updatedOut, `in` = updatedIn),
                                )
                                LaneId.EFFECTS -> plan.copy(
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

                    if (focusedLane == null) {
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
                            val isAuto = plan.mode == TransitionMode.AUTO
                            PresetPill(
                                label = "Auto",
                                icon = Icons.Rounded.AutoAwesome,
                                isSelected = isAuto,
                                onClick = {
                                    haptics.play(Haptic.Select)
                                    val auto = MixAutoPlanner.autoPlan(fromAnalysis, toAnalysis, fromSong.videoId, toSong.videoId)
                                    plan = auto
                                    if (effectiveIsPlaying) {
                                        controller?.previewTransition(fromSong, toSong, auto)
                                    }
                                },
                            )

                            val isCustom = plan.mode == TransitionMode.CUSTOM
                            PresetPill(
                                label = "Custom",
                                isSelected = isCustom,
                                onClick = {
                                    haptics.play(Haptic.Select)
                                    plan = plan.copy(mode = TransitionMode.CUSTOM, presetId = null)
                                },
                            )

                            MixPresets.presets.forEach { preset ->
                                val isSelected = plan.mode == TransitionMode.PRESET && plan.presetId == preset.id
                                PresetPill(
                                    label = preset.label,
                                    isSelected = isSelected,
                                    onClick = {
                                        haptics.play(Haptic.Select)
                                        val updated = TransitionPlan.applyPreset(plan, preset)
                                        plan = updated
                                        if (effectiveIsPlaying) {
                                            controller?.previewTransition(fromSong, toSong, updated)
                                        }
                                    },
                                )
                            }
                        }

                        Spacer(Modifier.height(14.dp))

                        // Vertical Lanes List matching Spotify
                        Text(
                            text = "Mix Parameters",
                            style = MaterialTheme.typography.titleSmall.copy(
                                fontWeight = FontWeight.SemiBold,
                                fontSize = 13.sp,
                            ),
                            color = Color.White.copy(alpha = 0.65f),
                            modifier = Modifier.padding(horizontal = 18.dp),
                        )

                        Spacer(Modifier.height(8.dp))

                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 16.dp),
                            verticalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            // Volume Lane Row
                            SpotifyLaneRow(
                                title = "Volume",
                                subtitle = plan.volume.option.replaceFirstChar { it.uppercase() },
                                color = VolumeBlue,
                                icon = Icons.AutoMirrored.Rounded.VolumeUp,
                                onClick = { focusedLane = LaneId.VOLUME },
                            )

                            // EQ Low Lane Row
                            SpotifyLaneRow(
                                title = "EQ Low",
                                subtitle = plan.eq.option.replaceFirstChar { it.uppercase() },
                                color = EqYellow,
                                icon = Icons.Rounded.GraphicEq,
                                onClick = { focusedLane = LaneId.EQ },
                            )

                            // Filter Lane Row
                            SpotifyLaneRow(
                                title = "Filter",
                                subtitle = plan.filter.option.replaceFirstChar { it.uppercase() },
                                color = FilterPink,
                                icon = Icons.Rounded.Tune,
                                onClick = { focusedLane = LaneId.FILTER },
                            )

                            // Effects Lane Row
                            SpotifyLaneRow(
                                title = "Effects",
                                subtitle = plan.effects.option.replaceFirstChar { it.uppercase() },
                                color = EffectsWhite,
                                icon = Icons.Rounded.AutoAwesome,
                                onClick = { focusedLane = LaneId.EFFECTS },
                            )

                            // Looping Lane Row
                            val loopText = if (plan.looping.beats > 0) "${plan.looping.beats} beat loop" else "None"
                            SpotifyLaneRow(
                                title = "Looping",
                                subtitle = loopText,
                                color = LoopingOrange,
                                icon = Icons.Rounded.Repeat,
                                onClick = { showLoopingSheet = true },
                            )

                            // Beatmatching Row
                            val toggleBeatmatching = {
                                val next = !plan.beatmatching
                                haptics.play(if (next) Haptic.ToggleOn else Haptic.ToggleOff)
                                plan = plan.copy(beatmatching = next)
                            }
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(Color.White.copy(alpha = 0.06f))
                                    .clickable(onClick = toggleBeatmatching)
                                    .padding(horizontal = 14.dp, vertical = 10.dp),
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
                                        tint = if (plan.beatmatching) VibraPurple else Color.White.copy(alpha = 0.4f),
                                        modifier = Modifier.size(20.dp),
                                    )
                                    Spacer(Modifier.width(12.dp))
                                    Column {
                                        Text(
                                            text = "Beatmatching",
                                            style = MaterialTheme.typography.labelMedium.copy(
                                                fontWeight = FontWeight.SemiBold,
                                                fontSize = 14.sp,
                                            ),
                                            color = if (plan.beatmatching) Color.White else Color.White.copy(alpha = 0.7f),
                                        )
                                        Text(
                                            text = "Lock tempo and align downbeats across transition",
                                            style = MaterialTheme.typography.labelSmall.copy(fontSize = 11.sp),
                                            color = Color.White.copy(alpha = 0.5f),
                                        )
                                    }
                                }
                                Switch(
                                    checked = plan.beatmatching,
                                    onCheckedChange = { toggleBeatmatching() },
                                    colors = SwitchDefaults.colors(
                                        checkedTrackColor = VibraPurple,
                                        checkedThumbColor = Color.White,
                                        checkedBorderColor = Color.Transparent,
                                        uncheckedTrackColor = Color(0xFF27272A),
                                        uncheckedThumbColor = Color(0xFFA1A1AA),
                                        uncheckedBorderColor = Color(0xFF3F3F46),
                                    ),
                                )
                            }
                        }
                    } else {
                        // Lane-Specific Customization Options when a lane is focused
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 16.dp, vertical = 6.dp),
                        ) {
                            when (focusedLane) {
                                LaneId.VOLUME -> VolumeLaneCard(
                                    plan = plan,
                                    color = VolumeBlue,
                                    isCustomizing = true,
                                    onCustomizeToggle = {},
                                    onOptionSelected = { optId ->
                                        val opt = MixOptions.findVolumeOption(optId)
                                        val curves = opt.build(plan.lengthBars)
                                        plan = plan.copy(
                                            volume = plan.volume.copy(option = optId, out = curves.out, `in` = curves.`in`),
                                        )
                                    },
                                )
                                LaneId.EQ -> EqLaneCard(
                                    plan = plan,
                                    color = EqYellow,
                                    isCustomizing = true,
                                    onCustomizeToggle = {},
                                    onOptionSelected = { optId ->
                                        val opt = MixOptions.findEqOption(optId)
                                        val bands = opt.build(plan.lengthBars)
                                        plan = plan.copy(
                                            eq = plan.eq.copy(option = optId, out = bands.out, `in` = bands.`in`),
                                        )
                                    },
                                )
                                LaneId.FILTER -> FilterLaneCard(
                                    plan = plan,
                                    color = FilterPink,
                                    isCustomizing = true,
                                    onCustomizeToggle = {},
                                    onOptionSelected = { optId ->
                                        val opt = MixOptions.findFilterOption(optId)
                                        val curves = opt.build(plan.lengthBars)
                                        plan = plan.copy(
                                            filter = plan.filter.copy(option = optId, out = curves.out, `in` = curves.`in`),
                                        )
                                    },
                                )
                                LaneId.EFFECTS -> EffectsLaneCard(
                                    plan = plan,
                                    color = EffectsWhite,
                                    isCustomizing = true,
                                    onCustomizeToggle = {},
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
                                else -> {}
                            }
                        }
                    }
                }
            }

            // Looping Discrete Bottom Sheet
            if (showLoopingSheet) {
                ModalBottomSheet(
                    onDismissRequest = { showLoopingSheet = false },
                    containerColor = Color(0xFF18181B),
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 20.dp, vertical = 12.dp),
                    ) {
                        Text(
                            text = "Looping",
                            style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold),
                            color = Color.White,
                        )
                        Spacer(Modifier.height(4.dp))
                        Text(
                            text = "Select loop length for track transition",
                            style = MaterialTheme.typography.bodySmall,
                            color = Color.White.copy(alpha = 0.6f),
                        )
                        Spacer(Modifier.height(16.dp))

                        val loopingOptions = listOf(
                            0 to "None",
                            1 to "1 beat loop",
                            2 to "2 beat loop",
                            4 to "4 beat loop",
                            8 to "8 beat loop",
                            16 to "16 beat loop",
                        )

                        loopingOptions.forEach { (beats, label) ->
                            val isSelected = plan.looping.beats == beats
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(8.dp))
                                    .clickable {
                                        haptics.play(Haptic.Select)
                                        val optId = if (beats == 0) "none" else "${beats}_beats"
                                        plan = plan.copy(
                                            looping = plan.looping.copy(option = optId, beats = beats),
                                        )
                                        showLoopingSheet = false
                                    }
                                    .padding(vertical = 12.dp, horizontal = 8.dp),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(
                                    text = label,
                                    style = MaterialTheme.typography.bodyLarge.copy(
                                        fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                                    ),
                                    color = if (isSelected) Color.White else Color.White.copy(alpha = 0.8f),
                                )
                                if (isSelected) {
                                    Icon(
                                        imageVector = Icons.Rounded.Check,
                                        contentDescription = "Selected",
                                        tint = LoopingOrange,
                                        modifier = Modifier.size(20.dp),
                                    )
                                }
                            }
                        }
                        Spacer(Modifier.height(24.dp))
                    }
                }
            }
        }
    }
}

// Sub-components

@Composable
private fun SpotifyLaneRow(
    title: String,
    subtitle: String,
    color: Color,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(Color.White.copy(alpha = 0.06f))
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.weight(1f),
        ) {
            Box(
                modifier = Modifier
                    .size(32.dp)
                    .clip(CircleShape)
                    .background(color.copy(alpha = 0.18f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    tint = color,
                    modifier = Modifier.size(18.dp),
                )
            }
            Spacer(Modifier.width(14.dp))
            Column {
                Text(
                    text = title,
                    style = MaterialTheme.typography.labelMedium.copy(
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 15.sp,
                    ),
                    color = Color.White,
                )
                Text(
                    text = subtitle,
                    style = MaterialTheme.typography.labelSmall.copy(fontSize = 12.sp),
                    color = Color.White.copy(alpha = 0.65f),
                )
            }
        }
        Icon(
            imageVector = Icons.AutoMirrored.Rounded.KeyboardArrowRight,
            contentDescription = null,
            tint = Color.White.copy(alpha = 0.45f),
            modifier = Modifier.size(18.dp),
        )
    }
}

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
    focusedLane: LaneId?,
    playhead: Float,
    isPlaying: Boolean,
    onPlayToggle: () -> Unit,
    onDragPointActive: (Boolean) -> Unit,
    onPointsChanged: (outPoints: List<Point>, inPoints: List<Point>) -> Unit,
    modifier: Modifier = Modifier,
) {
    var selectedPointId by remember { mutableStateOf<String?>(null) }

    val activeOutPoints = when (focusedLane) {
        LaneId.VOLUME -> plan.volume.out
        LaneId.EQ -> plan.eq.out.low
        LaneId.FILTER -> plan.filter.out
        LaneId.EFFECTS -> plan.effects.curve
        else -> emptyList()
    }

    val activeInPoints = when (focusedLane) {
        LaneId.VOLUME -> plan.volume.`in`
        LaneId.EQ -> plan.eq.`in`.low
        LaneId.FILTER -> plan.filter.`in`
        else -> emptyList()
    }

    val currentOutPoints by rememberUpdatedState(activeOutPoints)
    val currentInPoints by rememberUpdatedState(activeInPoints)
    val currentOnPointsChanged by rememberUpdatedState(onPointsChanged)
    val currentOnDragPointActive by rememberUpdatedState(onDragPointActive)

    Box(
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .background(Color(0xFF18181B)),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(
            modifier = Modifier
                .fillMaxSize()
                .pointerInput(focusedLane) {
                    if (focusedLane == null) return@pointerInput
                    awaitEachGesture {
                        val down = awaitFirstDown(requireUnconsumed = false)
                        val w = size.width.toFloat()
                        val h = size.height.toFloat()
                        val halfH = h * 0.5f

                        var runningOut = currentOutPoints
                        var runningIn = currentInPoints

                        // Check if down landed on an existing point (80px radius for finger precision)
                        var targetPointId: String? = null
                        var isTargetOut = false

                        for (p in runningOut) {
                            val px = p.t * w
                            val py = (1f - p.v) * halfH
                            if (hypot(down.position.x - px, down.position.y - py) < 80f) {
                                targetPointId = p.id
                                isTargetOut = true
                                break
                            }
                        }
                        if (targetPointId == null) {
                            for (p in runningIn) {
                                val px = p.t * w
                                val py = halfH + (1f - p.v) * halfH
                                if (hypot(down.position.x - px, down.position.y - py) < 80f) {
                                    targetPointId = p.id
                                    isTargetOut = false
                                    break
                                }
                            }
                        }

                        // If not on an existing point, check if touch is within 60px of the curve line.
                        // If near the curve, immediately create and insert a new point, and start dragging it right away!
                        if (targetPointId == null) {
                            if (down.position.y <= halfH && runningOut.isNotEmpty()) {
                                val (dist, t) = Curves.distanceToCurvePx(runningOut, w, halfH, down.position.x, down.position.y)
                                if (dist < 60f) {
                                    val next = Curves.addPointOnLine(runningOut, t)
                                    val newPt = next.firstOrNull { np -> runningOut.none { it.id == np.id } }
                                    if (newPt != null) {
                                        targetPointId = newPt.id
                                        isTargetOut = true
                                        runningOut = next
                                        currentOnPointsChanged(runningOut, runningIn)
                                    }
                                }
                            } else if (down.position.y > halfH && runningIn.isNotEmpty()) {
                                val localY = down.position.y - halfH
                                val (dist, t) = Curves.distanceToCurvePx(runningIn, w, halfH, down.position.x, localY)
                                if (dist < 60f) {
                                    val next = Curves.addPointOnLine(runningIn, t)
                                    val newPt = next.firstOrNull { np -> runningIn.none { it.id == np.id } }
                                    if (newPt != null) {
                                        targetPointId = newPt.id
                                        isTargetOut = false
                                        runningIn = next
                                        currentOnPointsChanged(runningOut, runningIn)
                                    }
                                }
                            }
                        }

                        // If a point is targeted (either preexisting or newly created in this touch), drag it immediately in that single gesture!
                        if (targetPointId != null) {
                            down.consume()
                            selectedPointId = targetPointId
                            currentOnDragPointActive(true)

                            // Continuous drag loop
                            while (true) {
                                val event = awaitPointerEvent()
                                val change = event.changes.firstOrNull { it.id == down.id } ?: break
                                if (!change.pressed) {
                                    change.consume()
                                    break
                                }
                                change.consume()
                                val currentPos = change.position
                                val normT = (currentPos.x / w).coerceIn(0.015f, 0.985f)

                                if (isTargetOut) {
                                    val normV = (1f - (currentPos.y / halfH)).coerceIn(0f, 1f)
                                    runningOut = Curves.movePoint(runningOut, targetPointId, normT, normV)
                                    currentOnPointsChanged(runningOut, runningIn)
                                } else {
                                    val normV = (1f - ((currentPos.y - halfH) / halfH)).coerceIn(0f, 1f)
                                    runningIn = Curves.movePoint(runningIn, targetPointId, normT, normV)
                                    currentOnPointsChanged(runningOut, runningIn)
                                }
                            }
                            selectedPointId = null
                            currentOnDragPointActive(false)
                        }
                    }
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

            // Real Multi-Band Waveform Rendering with Dynamic Time Translation
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
                    val time = if (isOutgoing) startSecA + normX * windowSecA else cueB + normX * windowSecB

                    val (highEnergy, bassEnergy, coreEnergy) = if (isOutgoing) {
                        if (hasRealAnalysisA && fromAnalysis != null) {
                            val core = sampleEnergyAt(fromAnalysis.energyCurve, time).toFloat().coerceIn(0.08f, 1f)
                            val bass = if (fromAnalysis.lowEnergyCurve.isNotEmpty()) {
                                sampleEnergyAt(fromAnalysis.lowEnergyCurve, time).toFloat().coerceIn(0.04f, 1f)
                            } else core * 0.7f
                            val high = (core - bass).coerceAtLeast(0.05f)
                            Triple(high, bass, core)
                        } else {
                            fallbackWaveformEnergy(time, seed)
                        }
                    } else {
                        if (hasRealAnalysisB && toAnalysis != null) {
                            val core = sampleEnergyAt(toAnalysis.energyCurve, time).toFloat().coerceIn(0.08f, 1f)
                            val bass = if (toAnalysis.lowEnergyCurve.isNotEmpty()) {
                                sampleEnergyAt(toAnalysis.lowEnergyCurve, time).toFloat().coerceIn(0.04f, 1f)
                            } else core * 0.7f
                            val high = (core - bass).coerceAtLeast(0.05f)
                            Triple(high, bass, core)
                        } else {
                            fallbackWaveformEnergy(time, seed)
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

            // Looping Amber Region on Deck A (matching Spotify screenshot)
            if (plan.looping.beats > 0) {
                val totalBeats = (plan.lengthBars * 4).toFloat().coerceAtLeast(4f)
                val loopWidthFraction = (plan.looping.beats.toFloat() / totalBeats).coerceIn(0.05f, 0.95f)
                val loopStartX = w * (1f - loopWidthFraction)
                val loopWidth = w * loopWidthFraction

                drawRect(
                    color = LoopingOrange.copy(alpha = 0.28f),
                    topLeft = Offset(loopStartX, 0f),
                    size = Size(loopWidth, halfH),
                )
                drawLine(
                    color = LoopingOrange,
                    start = Offset(loopStartX, 0f),
                    end = Offset(loopStartX, halfH),
                    strokeWidth = 3f,
                )
                drawLine(
                    color = LoopingOrange,
                    start = Offset(loopStartX, 0f),
                    end = Offset(w, 0f),
                    strokeWidth = 2f,
                )
                drawLine(
                    color = LoopingOrange,
                    start = Offset(loopStartX, halfH),
                    end = Offset(w, halfH),
                    strokeWidth = 2f,
                )
            }

            // Draw Automation Curves with 3.5f stroke thickness
            fun drawSingleCurve(
                points: List<Point>,
                topOffset: Float,
                color: Color,
                showPoints: Boolean,
            ) {
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

                // Outer soft glow stroke
                drawPath(path, color = color.copy(alpha = 0.35f), style = Stroke(width = 7f, cap = StrokeCap.Round))
                // Solid main curve stroke (thick 3.5f)
                drawPath(path, color = color, style = Stroke(width = 3.5f, cap = StrokeCap.Round))

                if (showPoints) {
                    for (p in sorted) {
                        val px = p.t * w
                        val py = topOffset + (1f - p.v) * halfH
                        drawCircle(color = color, radius = 9f, center = Offset(px, py))
                        drawCircle(color = Color.White, radius = 4f, center = Offset(px, py))
                    }
                }
            }

            if (focusedLane == null) {
                // Overview Mode: Overlay all active automation curves simultaneously!
                // 1. Volume (Cyan/Blue)
                drawSingleCurve(plan.volume.out, 0f, VolumeBlue, showPoints = false)
                drawSingleCurve(plan.volume.`in`, halfH, VolumeBlue, showPoints = false)

                // 2. EQ Low (Yellow)
                drawSingleCurve(plan.eq.out.low, 0f, EqYellow, showPoints = false)
                drawSingleCurve(plan.eq.`in`.low, halfH, EqYellow, showPoints = false)

                // 3. Filter (Pink)
                drawSingleCurve(plan.filter.out, 0f, FilterPink, showPoints = false)
                drawSingleCurve(plan.filter.`in`, halfH, FilterPink, showPoints = false)
            } else {
                // Focused Lane Mode: Render only focused lane with interactive draggable points
                val color = when (focusedLane) {
                    LaneId.VOLUME -> VolumeBlue
                    LaneId.EQ -> EqYellow
                    LaneId.FILTER -> FilterPink
                    LaneId.EFFECTS -> EffectsWhite
                    else -> LoopingOrange
                }
                drawSingleCurve(activeOutPoints, 0f, color, showPoints = true)
                if (focusedLane != LaneId.EFFECTS) {
                    drawSingleCurve(activeInPoints, halfH, color, showPoints = true)
                }
            }

            // Draw Moving Playhead (Vibra Purple vertical bar)
            if (isPlaying || playhead > 0f) {
                val clamped = playhead.coerceIn(0f, 1f)
                val phX = clamped * w
                drawLine(
                    color = if (playhead < 0f) VibraPurple.copy(alpha = 0.5f) else VibraPurple,
                    start = Offset(phX, 0f),
                    end = Offset(phX, h),
                    strokeWidth = 3f,
                )
            }
        }

        // Center Play / Stop toggle button
        val isBuffering = isPlaying && playhead < 0f
        Box(
            modifier = Modifier
                .size(40.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(Color(0xFF27272A).copy(alpha = 0.95f))
                .clickable(onClick = onPlayToggle),
            contentAlignment = Alignment.Center,
        ) {
            if (isBuffering) {
                CircularProgressIndicator(
                    modifier = Modifier.size(20.dp),
                    color = VibraPurple,
                    strokeWidth = 2.dp,
                )
            } else {
                Icon(
                    imageVector = if (isPlaying) Icons.Rounded.Stop else Icons.Rounded.PlayArrow,
                    contentDescription = if (isPlaying) "Stop" else "Play",
                    tint = Color.White,
                    modifier = Modifier.size(22.dp),
                )
            }
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
private fun LaneContainer(
    title: String,
    color: Color,
    content: @Composable () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(Color(0xFF1C1C1E))
            .padding(16.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
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

        Spacer(Modifier.height(12.dp))

        Column(
            modifier = Modifier.fillMaxWidth(),
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

private fun fallbackWaveformEnergy(time: Double, seed: Float): Triple<Float, Float, Float> {
    val t = time.toFloat()
    val s1 = sin((t * 2.5f) + seed) * 0.45f + 0.5f
    val s2 = sin((t * 6.2f) + seed * 1.7f) * 0.3f
    val s3 = sin((t * 14.1f) + seed * 2.9f) * 0.2f
    val total = (s1 + s2 + s3).coerceIn(0.12f, 1.0f)
    val bass = (sin((t * 1.8f) + seed) * 0.4f + 0.6f) * total
    val high = (abs(sin(t * 8.5f)) * 0.5f + 0.5f) * total
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
