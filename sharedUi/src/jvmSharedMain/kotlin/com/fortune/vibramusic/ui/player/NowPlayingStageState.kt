package com.fortune.vibramusic.ui.player

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.movableContentOf
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.graphics.rememberGraphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionOnScreen
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.isSpecified
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.fortune.vibramusic.data.canvas.CanvasSource
import com.fortune.vibramusic.data.model.PlaybackSourceType
import com.fortune.vibramusic.data.settings.LastPlayerScreen
import com.fortune.vibramusic.data.settings.PlayerTheme
import com.fortune.vibramusic.playback.BACK_RESTARTS_AFTER_MS
import com.fortune.vibramusic.sharedui.resources.*
import com.fortune.vibramusic.ui.components.VideoThumbnails
import com.fortune.vibramusic.ui.haptics.Haptic
import com.fortune.vibramusic.ui.haptics.rememberHaptics
import com.fortune.vibramusic.ui.theme.rememberArtworkTopBandLuminance
import com.fortune.vibramusic.ui.theme.rememberScreenOrientation
import com.fortune.vibramusic.ui.theme.stableStatusBarInsets
import com.fortune.vibramusic.ui.theme.topBandScrimAlpha
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import org.jetbrains.compose.resources.stringArrayResource
import kotlin.math.abs
import kotlin.math.roundToInt

@Composable
internal fun NowPlayingStageMediaState(
    params: NowPlayingParams,
    panels: PlayerPanelsState,
    collapse: PlayerCollapseState,
    scrub: PlayerScrub,
    volume: PlayerVolume,
): NowPlayingMediaState {
    val density = LocalDensity.current
    val track = params.track
    val window = params.window
    val song = track.song

    val remoteArt = rememberRemoteArtworkUrl(song)
    val artTopLuminance = rememberArtworkTopBandLuminance(remoteArt, ART_PX)
    val artworkStatusScrimAlpha = topBandScrimAlpha(artTopLuminance)

    val spotifyCanvasAutoHide by PlayerSettings.spotifyCanvasAutoHide.collectAsStateWithLifecycle()
    val mixing by PlayerSettings.smartMixInProgress.collectAsStateWithLifecycle()
    val videoMode = showsMusicVideo(song)
    val squareVideo = videoMode && VideoThumbnails.square
    val fullCanvasWindow = playerFillsWindow(window.windowWidth)
    val fullBleedArt by PlayerSettings.fullBleedArtwork.collectAsStateWithLifecycle()
    val sessionCanvas = rememberCanvasArtwork(song)?.takeUnless { videoMode }
        ?.nowPlayingRendition(fullCanvasWindow)
    val coverEntry = remember(song.videoId, song.queueEntryId, track.queue, track.queueIndex) {
        coverOccurrence(song, track.queue, track.queueIndex)
    }
    val videoRenderedState = remember(song.videoId) { mutableStateOf(false) }
    val videoAspectState = PlayerPlatform.host.musicVideoAspect.collectAsStateWithLifecycle()
    val screenOrientation = rememberScreenOrientation()
    val sideways = landscapePlayerAvailable(window.windowWidth, window.windowHeight)
    val artworkGate = autoMixArtworkGate()
    val canvasPair = rememberAutoMixCanvasPair(
        coverEntry,
        track.queue,
        track.isPlaying,
        sideways,
        fullCanvasWindow,
        fullBleedArt,
        artworkGate,
    )
    val pair = canvasPair.visual?.takeIf { artworkGate.allows(it.generation) && it.contains(coverEntry) }
    val promotedCanvas = canvasPair.promoted?.takeIf { it.incoming == coverEntry && !videoMode }
    val retiringCanvas = pair?.retiringClip?.takeIf { pair.started }
    val canvasRetire = remember { Animatable(0f) }
    LaunchedEffect(retiringCanvas?.url) {
        canvasRetire.snapTo(0f)
        if (retiringCanvas != null) {
            canvasRetire.animateTo(1f, tween(AUTOMIX_CANVAS_RETIRE_MS, easing = FastOutSlowInEasing))
        }
    }
    val canvasRetired by remember { derivedStateOf { canvasRetire.value >= 1f } }
    val canvasRetiring = retiringCanvas != null && !canvasRetired
    val retiringCanvasAlpha: () -> Float = { 1f - canvasRetire.value }
    val canvas = if (pair?.started == true) {
        pair.pinnedClip ?: retiringCanvas.takeIf { canvasRetiring }
    } else promotedCanvas?.incomingClip ?: sessionCanvas
    val staticCanvasMix = pair?.started == true && !pair.liveOutgoing
    val freezeOutgoingCanvas = pair?.liveOutgoing == true && pair.freezeOutgoing
    val incomingFullWindow = !sideways && fullCanvasWindow && pair?.incomingClip?.source == CanvasSource.SPOTIFY
    LaunchedEffect(sideways) { if (!sideways) panels.fullscreenRequested = false }

    val fullscreenInPlace = videoFullscreenInPlace(window.windowWidth, window.windowHeight)
    var inPlaceFullscreen by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(fullscreenInPlace, videoMode) {
        if (!fullscreenInPlace || !videoMode) inPlaceFullscreen = false
    }
    val videoFullscreen = videoMode && if (fullscreenInPlace) inPlaceFullscreen else sideways
    val enterFullscreen = {
        if (fullscreenInPlace) {
            inPlaceFullscreen = true
        } else {
            panels.fullscreenRequested = true
            screenOrientation.landscape()
        }
    }
    val exitFullscreen = {
        if (fullscreenInPlace) {
            inPlaceFullscreen = false
        } else {
            panels.fullscreenRequested = false
            screenOrientation.portrait()
        }
    }

    val canvasAspectState = remember(canvas?.url) { mutableFloatStateOf(promotedCanvas?.incomingAspect ?: 0f) }
    val canvasRenderedState = remember(canvas?.url) { mutableStateOf(promotedCanvas?.incomingReady == true) }
    val canvasRendered = canvasRenderedState.value && !staticCanvasMix
    RememberDisplayedAutoMixCanvas(canvasPair, coverEntry, canvas, canvasRendered)
    val canvasFrameState = remember(coverEntry, remoteArt, canvas?.url) { mutableStateOf<ImageBitmap?>(null) }
    val canvasOwnsAmbient = pair?.started != true
    val ambientCanvasKey = canvas?.url?.takeIf { canvasOwnsAmbient }?.let { Triple(coverEntry, remoteArt, it) }
    val spotifyCanvasControlsOpenState = remember(canvas?.url) { mutableStateOf(true) }
    val spotifyCanvasDeckHeightState = remember(canvas?.url) { mutableStateOf(0.dp) }
    val spotifyCanvasExpandedTopHeightState = remember(canvas?.url) { mutableStateOf(0.dp) }
    val canvasCover = remember(canvas?.url) { mutableFloatStateOf(if (promotedCanvas?.incomingReady == true) 1f else 0f) }
    val playerTheme by PlayerSettings.playerTheme.collectAsStateWithLifecycle()
    val tintsOffClip = playerTheme != PlayerTheme.SIMPLE
    val meshRefreshMs = MESH_REFRESH_MS.takeIf { tintsOffClip }

    val spotifyCanvasOnPhone = canvas?.source == CanvasSource.SPOTIFY && fullCanvasWindow
    val heroMode = !videoMode && (spotifyCanvasOnPhone || (fullBleedArt && fullCanvasWindow))

    val art = rememberPlayerArtwork(remoteArt)
    val autoMixCover = rememberAutoMixCover(coverEntry, art, artworkGate)
    val autoMixFrames = autoMixCover.framesFor(coverEntry, artworkGate)
    val heroIncomingStill = autoMixFrames?.incoming.takeIf {
        heroMode && pair?.liveOutgoing == true && !pair.liveIncoming
    }
    val coverLoadedNow = autoMixFrames != null || art.loaded

    LaunchedEffect(art, coverEntry, canvasRenderedState, artworkGate) {
        if (panels.heroSettled) return@LaunchedEffect
        snapshotFlow {
            autoMixCover.framesFor(coverEntry, artworkGate) != null || art.loaded || canvasRenderedState.value
        }.first { it }
        panels.heroSettled = true
        lastHeroSettled = true
    }

    val heroClip = canvas?.takeIf { heroMode && !collapse.collapsePastHalf }
    val spotifyCanvasFullscreen = spotifyCanvasOnPhone && heroClip?.source == CanvasSource.SPOTIFY
    val spotifyCanvasPresentation = spotifyCanvasFullscreen && canvasRendered
    val heroClipMounted = canvas?.takeIf {
        heroMode && (!(panels.lyricsOpen || panels.queueOpen) || !collapse.collapseDone)
    }
    val clipFullscreen = spotifyCanvasOnPhone && heroClipMounted?.source == CanvasSource.SPOTIFY
    val canvasAspect = canvasAspectState.floatValue
    val clipPortrait = !clipFullscreen && heroClipMounted != null && canvasAspect > 0f && canvasAspect < 1f

    LaunchedEffect(
        spotifyCanvasPresentation,
        spotifyCanvasControlsOpenState.value,
        spotifyCanvasAutoHide,
        track.isPlaying,
        scrub.scrubbing,
        volume.dragging,
        panels.lyricsOpen,
        panels.queueOpen,
        mixing,
    ) {
        if (!spotifyCanvasPresentation || !spotifyCanvasControlsOpenState.value ||
            !spotifyCanvasAutoHide || !track.isPlaying || scrub.scrubbing || volume.dragging ||
            panels.lyricsOpen || panels.queueOpen || mixing
        ) return@LaunchedEffect
        delay(SPOTIFY_CANVAS_CONTROLS_IDLE_MS)
        spotifyCanvasControlsOpenState.value = false
    }

    LaunchedEffect(spotifyCanvasPresentation, panels.lyricsOpen, panels.queueOpen) {
        if (spotifyCanvasPresentation && !panels.lyricsOpen && !panels.queueOpen) {
            spotifyCanvasControlsOpenState.value = true
        }
    }

    LaunchedEffect(spotifyCanvasPresentation, mixing) {
        if (spotifyCanvasPresentation && mixing) spotifyCanvasControlsOpenState.value = true
    }

    val settlingToSquare = !fullBleedArt && pair?.selectedStill == true && heroIncomingStill != null
    val heroT = animateFloatAsState(
        targetValue = if (
            heroMode && (panels.heroSettled || coverLoadedNow || canvasRendered) && !settlingToSquare
        ) 1f else 0f,
        animationSpec = if (settlingToSquare) snap() else tween(durationMillis = 420, easing = FastOutSlowInEasing),
        label = "heroCanvas",
    )
    val spotifyChromeAlphaState = animateFloatAsState(
        targetValue = if (!spotifyCanvasPresentation || spotifyCanvasControlsOpenState.value) 1f else 0f,
        animationSpec = tween(durationMillis = 180, easing = FastOutSlowInEasing),
        label = "spotifyCanvasChrome",
    )

    val clipBottom = if (clipPortrait && panels.playerBounds.width > 0 && panels.playerBounds.height > 0) {
        val viewAspect = panels.playerBounds.width.toFloat() / panels.playerBounds.height
        val videoHeight = if (canvasAspect >= viewAspect) panels.playerBounds.width / canvasAspect
        else panels.playerBounds.height.toFloat()
        with(density) { videoHeight.toDp() }
    } else 0.dp
    val statusBarTop = stableStatusBarInsets().asPaddingValues().calculateTopPadding()

    return NowPlayingMediaState(
        density = density,
        remoteArt = remoteArt,
        artworkStatusScrimAlpha = artworkStatusScrimAlpha,
        mixing = mixing,
        videoMode = videoMode,
        squareVideo = squareVideo,
        fullCanvasWindow = fullCanvasWindow,
        fullBleedArt = fullBleedArt,
        coverEntry = coverEntry,
        videoRenderedState = videoRenderedState,
        videoAspectState = videoAspectState,
        sideways = sideways,
        artworkGate = artworkGate,
        canvasPair = canvasPair,
        pair = pair,
        promotedCanvas = promotedCanvas,
        retiringCanvas = retiringCanvas,
        canvasRetire = canvasRetire,
        canvasRetiring = canvasRetiring,
        retiringCanvasAlpha = retiringCanvasAlpha,
        canvas = canvas,
        staticCanvasMix = staticCanvasMix,
        freezeOutgoingCanvas = freezeOutgoingCanvas,
        incomingFullWindow = incomingFullWindow,
        fullscreenInPlace = fullscreenInPlace,
        videoFullscreen = videoFullscreen,
        enterFullscreen = enterFullscreen,
        exitFullscreen = exitFullscreen,
        canvasAspectState = canvasAspectState,
        canvasRenderedState = canvasRenderedState,
        canvasRendered = canvasRendered,
        canvasFrameState = canvasFrameState,
        canvasOwnsAmbient = canvasOwnsAmbient,
        ambientCanvasKey = ambientCanvasKey,
        spotifyCanvasControlsOpenState = spotifyCanvasControlsOpenState,
        spotifyCanvasDeckHeightState = spotifyCanvasDeckHeightState,
        spotifyCanvasExpandedTopHeightState = spotifyCanvasExpandedTopHeightState,
        canvasCover = canvasCover,
        playerTheme = playerTheme,
        tintsOffClip = tintsOffClip,
        meshRefreshMs = meshRefreshMs,
        spotifyCanvasOnPhone = spotifyCanvasOnPhone,
        heroMode = heroMode,
        art = art,
        autoMixFrames = autoMixFrames,
        heroIncomingStill = heroIncomingStill,
        heroClip = heroClip,
        spotifyCanvasPresentation = spotifyCanvasPresentation,
        heroClipMounted = heroClipMounted,
        clipFullscreen = clipFullscreen,
        clipPortrait = clipPortrait,
        heroT = heroT,
        spotifyChromeAlphaState = spotifyChromeAlphaState,
        clipBottom = clipBottom,
        statusBarTop = statusBarTop,
        topStrip = DISMISS_STRIP_HEIGHT,
    )
}

@Composable
internal fun NowPlayingStageInteractionState(
    params: NowPlayingParams,
    sheets: PlayerSheetsState,
    panels: PlayerPanelsState,
    collapse: PlayerCollapseState,
    media: NowPlayingMediaState,
    scrub: PlayerScrub,
    volume: PlayerVolume,
): NowPlayingInteractionState {
    val track = params.track
    val transport = params.transport
    val window = params.window
    val song = track.song
    val haptics = rememberHaptics()

    val openAudioOutput = rememberOutputPicker { sheets.showAudioOutput = true }
    val controlsLocked = rememberControlsLocked()

    val syncedLyricsEnabled by PlayerSettings.syncedLyrics.collectAsStateWithLifecycle()
    val hideLyricsPreview by PlayerSettings.hideLyricsPreview.collectAsStateWithLifecycle()
    val lyricsOffsetMs by PlayerSettings.lyricsOffsetMs.collectAsStateWithLifecycle()
    val lyricsPlayhead = rememberLyricPlayhead(track.position)
    val seekToLyric: (Long) -> Unit = { lineTimeMs ->
        transport.onSeek(adjustedLyricsSeekTarget(lineTimeMs, lyricsOffsetMs))
    }
    val hideVolumeBar by PlayerSettings.hideVolumeBar.collectAsStateWithLifecycle()
    val disableBlendEffects by PlayerSettings.disableBlendEffects.collectAsStateWithLifecycle()
    val lyricSlotHeight = with(media.density) {
        MaterialTheme.typography.titleMedium.lineHeight.takeIf { it.isSpecified }?.toDp() ?: 24.dp
    } + 8.dp
    val hideSongStatus by PlayerSettings.hideSongStatus.collectAsStateWithLifecycle()

    val shown: () -> Float = { scrub.shown(track.position.positionMs, track.durationMs) }
    val pastRestartPointState = remember(track.position) {
        derivedStateOf { track.position.positionMs > BACK_RESTARTS_AFTER_MS }
    }

    LaunchedEffect(panels.queueOpen, controlsLocked) {
        if (!panels.queueOpen || controlsLocked) panels.queueSelection.clear()
    }

    val playerPrewarmStageState = remember(song.videoId) { mutableIntStateOf(0) }
    LaunchedEffect(song.videoId) {
        delay(600)
        playerPrewarmStageState.intValue = 1
        delay(650)
        playerPrewarmStageState.intValue = 2
        delay(650)
        playerPrewarmStageState.intValue = 3
    }

    LaunchedEffect(panels.lyricsOpen) { if (!panels.lyricsOpen) panels.lyricsScrolling = false }
    LaunchedEffect(panels.queueOpen) { if (!panels.queueOpen) panels.queueScrolling = false }
    LaunchedEffect(panels.queueSelection.active) {
        if (panels.queueSelection.active) panels.queueControlsOpen = false
    }
    LaunchedEffect(panels.lyricsOpen, panels.queueOpen) {
        PlayerSettings.setLastPlayerScreen(
            when {
                panels.lyricsOpen -> LastPlayerScreen.LYRICS
                panels.queueOpen -> LastPlayerScreen.QUEUE
                else -> LastPlayerScreen.MAIN
            },
        )
        if (panels.queueOpen) panels.queueControlsOpen = true
    }

    val lyricsLoadingLines = stringArrayResource(Res.array.lyrics_loading_lines)
    val lyricsLoadingText = remember(song.videoId) { lyricsLoadingLines.random() }
    val lyricsTranslation = rememberLyricsTranslation(
        trackId = song.videoId,
        lyrics = window.lyrics,
        lyricsSource = window.lyricsSource,
        lyricsUnavailable = window.lyricsUnavailable,
        loadingText = lyricsLoadingText,
        haptics = haptics,
    )
    val backdropLayer = rememberGraphicsLayer()
    val shareScope = rememberCoroutineScope()
    val currentMenuOpen = rememberUpdatedState(window.menuOpen)
    val currentLyricsOffsetOpen = rememberUpdatedState(window.lyricsOffsetOpen)
    val overlayOpen = remember {
        derivedStateOf {
            currentMenuOpen.value() || sheets.showAudioPipeline || sheets.showCast ||
                sheets.showAudioOutput || sheets.showVideoQuality || sheets.showLyricsProviders ||
                sheets.showListenTogetherMembers || sheets.lyricsShare != null || currentLyricsOffsetOpen.value
        }
    }
    val lyricsShareEnabled = lyricsShareAvailable
    val lyricPicker = rememberLyricsPicker(
        song = song,
        lines = window.lyrics,
        subLines = lyricsTranslation.subLines,
        artworkUrl = media.remoteArt,
        haptics = haptics,
        onCard = { request ->
            shareScope.launch {
                val backdrop = runCatching { backdropLayer.toImageBitmap() }.getOrNull()
                sheets.lyricsShare = request.copy(backdrop = backdrop)
            }
        },
    )
    LaunchedEffect(panels.lyricsOpen) {
        if (!panels.lyricsOpen && lyricPicker.picking) lyricPicker.cancel()
    }

    val showRevertCueState = remember(song.videoId) { mutableStateOf(false) }
    LaunchedEffect(song.videoId, track.qualityUpgraded) {
        if (!track.qualityUpgraded) {
            showRevertCueState.value = false
            return@LaunchedEffect
        }
        showRevertCueState.value = true
        delay(REVERT_CUE_MS)
        showRevertCueState.value = false
    }

    KeepScreenOn(enabled = panels.lyricsOpen)

    PlayerBackHandler(
        enabled = if (media.fullscreenInPlace) media.videoFullscreen else media.sideways && (media.videoMode || panels.fullscreenRequested),
        onBack = media.exitFullscreen,
    )
    PlayerBackHandler(enabled = panels.lyricsOpen, onBack = panels.closeLyrics)
    PlayerBackHandler(enabled = panels.queueOpen) {
        if (panels.queueSelection.active) panels.queueSelection.clear() else panels.queueOpen = false
    }
    PlayerBackHandler(enabled = sheets.showAudioOutput) { sheets.showAudioOutput = false }
    PlayerBackHandler(enabled = sheets.showVideoQuality) { sheets.showVideoQuality = false }
    PlayerBackHandler(enabled = sheets.showLyricsProviders) { sheets.showLyricsProviders = false }
    PlayerBackHandler(enabled = sheets.showListenTogetherMembers) { sheets.showListenTogetherMembers = false }
    PlayerBackHandler(enabled = sheets.showAudioPipeline) { sheets.showAudioPipeline = false }
    PlayerBackHandler(enabled = sheets.showCast) { sheets.showCast = false }
    PlayerBackHandler(enabled = window.lyricsOffsetOpen, onBack = window.onDismissLyricsOffset)
    PlayerBackHandler(enabled = sheets.lyricsShare != null) { sheets.lyricsShare = null }
    PlayerBackHandler(enabled = lyricPicker.picking) { lyricPicker.cancel() }

    LaunchedEffect(panels.queueOpen, panels.queueDragging, panels.queueReleased) {
        if (panels.queueDragging) return@LaunchedEffect
        val target = if (panels.queueOpen) 1f else 0f
        val from = panels.queueSlide.floatValue
        if (from == target) return@LaunchedEffect
        animate(
            initialValue = from,
            targetValue = target,
            animationSpec = tween(
                durationMillis = (QUEUE_TRAVEL_MS * abs(target - from)).roundToInt(),
                easing = FastOutSlowInEasing,
            ),
        ) { value, _ -> panels.queueSlide.floatValue = value }
    }

    val swipeThreshold = with(media.density) { 72.dp.toPx() }
    val infoScope = rememberCoroutineScope()
    val infoTransition = remember(infoScope) { SongInfoTransition(infoScope) }
    SideEffect { infoTransition.observe(song) }
    DisposableEffect(infoTransition) { onDispose { infoTransition.clear() } }

    val swipeSettle = remember { Animatable(0f) }
    val swipeTargets = remember { Channel<Float>(Channel.CONFLATED) }
    LaunchedEffect(swipeTargets) {
        for (target in swipeTargets) {
            val newest = swipeTargets.tryReceive().getOrNull() ?: target
            launch {
                if (newest != swipeSettle.targetValue) {
                    swipeSettle.animateTo(newest, spring(stiffness = Spring.StiffnessMediumLow))
                }
            }
        }
    }
    val setSwipeOffset: (Float) -> Unit = { swipeTargets.trySend(it) }

    val artScaleState = animateFloatAsState(
        targetValue = if (track.isPlaying) 1f else 0.86f,
        animationSpec = spring(
            dampingRatio = Spring.DampingRatioLowBouncy,
            stiffness = Spring.StiffnessLow,
        ),
        label = "artScale",
    )

    LaunchedEffect(panels.lyricsOpen, panels.lyricsControlsOpen, scrub.scrubbing, volume.dragging) {
        if (panels.lyricsOpen && panels.lyricsControlsOpen && !scrub.scrubbing && !volume.dragging) {
            delay(LYRICS_CONTROLS_IDLE_MS)
            panels.lyricsControlsOpen = false
        }
    }

    LaunchedEffect(Unit) {
        snapshotFlow { collapse.collapseDone }.collectLatest { settled ->
            collapse.panelFade.animateTo(
                if (settled) 1f else 0f,
                tween(durationMillis = 200, easing = FastOutSlowInEasing),
            )
        }
    }

    val openPlaybackOrigin: () -> Unit = {
        if (track.playedBy != null) {
            window.onListenTogether()
        } else if (song.playbackSourceType == PlaybackSourceType.QUEUE) {
            panels.queueOpen = true
            panels.closeLyrics()
        } else {
            window.onOpenPlaybackSource()
        }
    }

    val startInfoDrag by rememberUpdatedState {
        infoTransition.beginDrag(
            song = song,
            next = songInfoNeighbour(track.queue, track.queueIndex, next = true, available = track.hasNext && !controlsLocked),
            previous = songInfoNeighbour(
                track.queue,
                track.queueIndex,
                next = false,
                available = !controlsLocked && !transport.previousRestarts(),
            ),
        )
    }
    val releaseInfoDrag by rememberUpdatedState { total: Float ->
        val crossed = total <= -swipeThreshold || total >= swipeThreshold
        when {
            controlsLocked -> {
                infoTransition.cancelDrag()
                if (crossed) transport.onBlockedControl()
            }
            total <= -swipeThreshold -> {
                haptics.play(Haptic.SkipNext)
                infoTransition.finishDrag(
                    next = true,
                    currentSong = transport.currentPlaybackSong,
                    canSlide = { true },
                    action = transport.onNext,
                )
            }
            total >= swipeThreshold -> {
                haptics.play(Haptic.SkipPrevious)
                infoTransition.finishDrag(
                    next = false,
                    currentSong = transport.currentPlaybackSong,
                    canSlide = { !transport.previousRestarts() },
                    action = transport.onPrevious,
                )
            }
            else -> infoTransition.cancelDrag()
        }
    }
    val skipSwipeGesture = Modifier.pointerInput(
        sheets.showAudioPipeline,
        sheets.showCast,
        panels.panelScrolling,
        controlsLocked,
        panels.queueOpen,
    ) {
        if (sheets.showAudioPipeline || sheets.showCast || panels.panelScrolling || panels.queueOpen) return@pointerInput
        var total = 0f
        var acceptsDrag = false
        detectHorizontalDragGestures(
            onDragStart = {
                total = 0f
                acceptsDrag = startInfoDrag()
            },
            onDragCancel = {
                if (!acceptsDrag) return@detectHorizontalDragGestures
                setSwipeOffset(0f)
                infoTransition.cancelDrag()
            },
            onDragEnd = {
                if (!acceptsDrag) return@detectHorizontalDragGestures
                releaseInfoDrag(total)
                setSwipeOffset(0f)
            },
            onHorizontalDrag = { _, delta ->
                if (!acceptsDrag) return@detectHorizontalDragGestures
                total += delta
                setSwipeOffset(total * 0.35f)
                infoTransition.dragBy(total)
            },
        )
    }

    val scrubControlsLocked = rememberUpdatedState(controlsLocked)
    val onScrub: (Float) -> Unit = { fraction ->
        if (!scrubControlsLocked.value) PlayerPlatform.host.onAutoMixScrubIntent()
        scrub.drag(fraction)
    }
    val onScrubFinished: () -> Unit = {
        haptics.play(Haptic.Select)
        scrub.release(transport.onSeekFraction)
    }

    return NowPlayingInteractionState(
        haptics = haptics,
        openAudioOutput = openAudioOutput,
        controlsLocked = controlsLocked,
        syncedLyricsEnabled = syncedLyricsEnabled,
        hideLyricsPreview = hideLyricsPreview,
        lyricsPlayhead = lyricsPlayhead,
        seekToLyric = seekToLyric,
        hideVolumeBar = hideVolumeBar,
        disableBlendEffects = disableBlendEffects,
        lyricSlotHeight = lyricSlotHeight,
        hideSongStatus = hideSongStatus,
        scrub = scrub,
        volume = volume,
        shown = shown,
        pastRestartPointState = pastRestartPointState,
        playerPrewarmStageState = playerPrewarmStageState,
        lyricsLoadingText = lyricsLoadingText,
        lyricsTranslation = lyricsTranslation,
        backdropLayer = backdropLayer,
        currentMenuOpen = currentMenuOpen,
        overlayOpen = overlayOpen,
        lyricsShareEnabled = lyricsShareEnabled,
        lyricPicker = lyricPicker,
        showRevertCueState = showRevertCueState,
        infoTransition = infoTransition,
        swipeSettle = swipeSettle,
        artScaleState = artScaleState,
        openPlaybackOrigin = openPlaybackOrigin,
        skipSwipeGesture = skipSwipeGesture,
        onScrub = onScrub,
        onScrubFinished = onScrubFinished,
        onVolumeChange = volume::drag,
        onVolumeChangeFinished = volume::release,
    )
}

@Composable
internal fun NowPlayingStageBuildEnv(
    params: NowPlayingParams,
    sheets: PlayerSheetsState,
    panels: PlayerPanelsState,
    collapse: PlayerCollapseState,
    media: NowPlayingMediaState,
    interaction: NowPlayingInteractionState,
): NowPlayingEnv {
    val track = params.track
    val transport = params.transport
    val window = params.window

    val playerActions: @Composable () -> Unit = {
        PlayerActionRow(
            lyricsOpen = panels.lyricsOpen,
            queueOpen = panels.queueOpen,
            shuffleEnabled = track.shuffleEnabled,
            repeatMode = track.repeatMode,
            autoplayEnabled = track.autoplayEnabled,
            onToggleLyrics = panels.toggleLyrics,
            onToggleQueue = panels.toggleQueue,
            onToggleShuffle = transport.onToggleShuffle,
            onCycleRepeat = transport.onCycleRepeat,
            onToggleAutoplay = transport.onToggleAutoplay,
            onOpenOutput = interaction.openAudioOutput,
            onListenTogether = window.onListenTogether,
            onOpenListenTogetherMembers = sheets.openListenTogetherMembers,
        )
        if (!(media.sideways && !media.fullscreenInPlace)) {
            Spacer(Modifier.height(18.dp))
            Box(
                modifier = Modifier.fillMaxWidth().height(20.dp),
                contentAlignment = Alignment.TopCenter,
            ) {
                OutputCaption(
                    accountName = track.accountName,
                    onOpenOutput = interaction.openAudioOutput,
                    onOpenMembers = sheets.openListenTogetherMembers,
                )
            }
        }
    }

    val landscape = media.sideways
    val tabletArtworkBackdrop = tabletSizedPlayer(window.windowWidth)
    val ambient = rememberAutoMixAmbient(media.coverEntry, media.remoteArt, media.artworkGate)
    val ambientBlurUrl = media.remoteArt ?: ambient.incoming?.resolvedUrl
    val blurSeed = ambient.incoming?.blur
    val blurSnapKey = rememberAmbientSnapKey(ambient.snapKey(blurSeed != null))
    val fullArtworkBlurImage = rememberFullArtworkBlurImage(
        imageUrl = ambientBlurUrl,
        artPx = ART_PX,
        seed = blurSeed,
        currentSelectionOnly = ambient.direct != null,
        prepare = media.playerTheme == PlayerTheme.SIMPLE || landscape || tabletArtworkBackdrop ||
            panels.lyricsOpen || panels.queueOpen || interaction.playerPrewarmStage >= 1,
    )
    val blurMix = ambient.mixFor(blurSeed != null)
    val heldBlurAvailable = remember(blurMix) {
        blurMix != null && (cachedFullArtworkBlur(blurMix.outgoingUrl) != null ||
            (media.coverEntry == blurMix.outgoing && fullArtworkBlurImage != null))
    }
    val blurAvailable = if (blurMix != null) heldBlurAvailable else
        ambient.direct != null || blurSeed != null || fullArtworkBlurImage != null
    val currentFullArtworkBlurImage = rememberUpdatedState(
        blurSeed ?: (if (ambient.cancelled) cachedFullArtworkBlur(ambientBlurUrl) else null) ?: fullArtworkBlurImage,
    )
    val currentBlurMix = rememberUpdatedState(blurMix)
    val currentBlurSnapKey = rememberUpdatedState(blurSnapKey)
    val currentBlurIsOutgoing = rememberUpdatedState(media.coverEntry == blurMix?.outgoing)
    val directBlur = rememberUpdatedState(ambient.direct != null)
    val fullArtworkBlurContent = remember {
        movableContentOf<Modifier> { backdropModifier ->
            key(currentBlurSnapKey.value) {
                FullArtworkBlurBackdrop(
                    currentFullArtworkBlurImage.value,
                    backdropModifier,
                    currentBlurMix.value,
                    currentBlurIsOutgoing.value,
                    immediate = directBlur.value,
                )
            }
        }
    }

    val dock = LocalPlayerDock.current
    if (dock != null) {
        DisposableEffect(dock) {
            onDispose { dock.attached = false }
        }
    }
    val dockFrame = remember { DockFrame() }
    val dockT: () -> Float = {
        if (dock == null) {
            1f
        } else {
            val open = dock.openFraction()
            if (dockFrame.anchor != null && dock.hasMiniArt()) open else 1f
        }
    }
    val docking: () -> Boolean = { dockT() < 1f }
    val dockMovingState = remember { derivedStateOf { docking() } }
    val dockMoving = dockMovingState.value
    val dockFade: () -> Float = { ((dockT() - DOCK_FADE_LEAD) / (1f - DOCK_FADE_LEAD)).coerceIn(0f, 1f) }
    val clipTransitionAlpha: () -> Float = { (1f - 2f * collapse.p()).coerceIn(0f, 1f) * dockFade() }

    val stillClip = media.canvas?.takeIf { !media.clipFullscreen }
    val stillUrl = stillClip?.url
    val stillMoving = collapse.collapseStarted || dockMoving || panels.lyricsOpen || panels.queueOpen || panels.queueDragging
    val gestureArtwork = dockMoving || (!panels.lyricsOpen && (panels.queueDragging || panels.queueOpen || collapse.queueArtworkMoving))
    val gesturePair = media.pair?.takeIf { it.usesGestureSleeve(gestureArtwork) }

    SideEffect {
        val captured = media.promotedCanvas?.gestureIncoming ?: return@SideEffect
        if (gestureArtwork && captured.url == stillUrl) {
            CanvasStills.current = captured
            CanvasStills.fresh = true
        }
        media.promotedCanvas.gestureIncoming = null
    }

    val staticHeroUnderlay = media.autoMixFrames?.takeIf { frames ->
        media.pair?.liveIncoming == true && media.pair.pinnedClip == null && frames.generation == media.pair.generation &&
            !media.canvasRetiring && !stillMoving && !interaction.overlayOpen.value &&
            (if (media.heroMode) panels.heroHeight > 0.dp else media.incomingFullWindow && !panels.expandedSquare.isEmpty)
    }?.base

    val onStillCaptured: (ImageBitmap?, Long) -> Unit = { image, position ->
        val url = stillClip?.url
        if (image != null && url != null) {
            CanvasStills.current = CanvasStill(url, image, position)
            CanvasStills.fresh = true
        } else {
            CanvasStills.current = null
        }
    }
    val onClipResumed: () -> Unit = { CanvasStills.fresh = false }
    val sleeveLayer = rememberGraphicsLayer()

    val dockHost: Modifier = Modifier
        .then(
            if (dock != null) {
                Modifier.onGloballyPositioned { coordinates ->
                    dockFrame.host = coordinates
                    if (dockFrame.anchor != null && dockFrame.anchorFor == coordinates.size) {
                        return@onGloballyPositioned
                    }
                    val offset = dock.offset() ?: return@onGloballyPositioned
                    dockFrame.anchorFor = coordinates.size
                    dockFrame.anchor = coordinates.positionOnScreen() - Offset(0f, offset.toInt().toFloat())
                    if (!dock.attached) dock.attached = true
                }
            } else {
                Modifier
            },
        )
        .drawWithContent {
            drawContent()
            if (docking()) {
                translate(dockFrame.portalLeft, dockFrame.portalTop) {
                    val portalScale = dockFrame.portalScale
                    scale(portalScale, portalScale, pivot = Offset.Zero) { drawLayer(sleeveLayer) }
                }
            }
        }
        .graphicsLayer { alpha = if (docking()) dockFade().coerceAtLeast(DOCK_FADE_FLOOR) else 1f }

    val reportLiveCanvas by rememberUpdatedState(window.onLiveCanvasChanged)
    LaunchedEffect(media.spotifyCanvasPresentation) { reportLiveCanvas(media.spotifyCanvasPresentation) }
    DisposableEffect(Unit) { onDispose { reportLiveCanvas(false) } }
    val frostOff by PlayerSettings.reduceDynamicBlur.collectAsStateWithLifecycle()
    val frost = if (frostOff) null else PlayerPlatform.host.rememberPlayerFrost()

    return NowPlayingEnv(
        params = params,
        sheets = sheets,
        panels = panels,
        collapse = collapse,
        media = media,
        interaction = interaction,
        landscape = landscape,
        tabletArtworkBackdrop = tabletArtworkBackdrop,
        ambient = ambient,
        blurAvailable = blurAvailable,
        fullArtworkBlurContent = fullArtworkBlurContent,
        dock = dock,
        dockFrame = dockFrame,
        dockT = dockT,
        docking = docking,
        dockMovingState = dockMovingState,
        dockFade = dockFade,
        clipTransitionAlpha = clipTransitionAlpha,
        stillUrl = stillUrl,
        stillMoving = stillMoving,
        gestureArtwork = gestureArtwork,
        gesturePair = gesturePair,
        staticHeroUnderlay = staticHeroUnderlay,
        onStillCaptured = onStillCaptured,
        onClipResumed = onClipResumed,
        sleeveLayer = sleeveLayer,
        dockHost = dockHost,
        frostOff = frostOff,
        frost = frost,
        playerActions = playerActions,
    )
}
