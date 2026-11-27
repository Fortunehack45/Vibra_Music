package com.fortune.vibramusic.ui.player

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.geometry.lerp
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.lerp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.fortune.vibramusic.sharedui.resources.*
import dev.chrisbanes.haze.hazeSource
import org.jetbrains.compose.resources.stringResource

@Composable
internal fun NowPlayingStageOverlays(env: NowPlayingEnv) {
    val sheets = env.sheets
    val params = env.params
    if (sheets.showVideoQuality) {
        VideoQualitySheet(
            hazeState = sheets.playerHaze,
            onDismiss = { sheets.showVideoQuality = false },
        )
    }
    if (sheets.showAudioOutput) {
        AudioOutputSheet(
            hazeState = sheets.playerHaze,
            accountName = params.track.accountName,
            onDismiss = { sheets.showAudioOutput = false },
            onOpenPipeline = { sheets.showAudioPipeline = true },
            onOpenCast = { sheets.showCast = true },
        )
    }
    if (sheets.showLyricsProviders) {
        LyricsProviderSheet(
            hazeState = sheets.playerHaze,
            currentSource = params.window.lyricsSource,
            states = params.window.lyricsProviderStates,
            onSelect = params.window.onSelectLyricsProvider,
            onDismiss = { sheets.showLyricsProviders = false },
        )
    }
    if (sheets.showAudioPipeline) {
        AudioPipelineDialog(
            hazeState = sheets.playerHaze,
            isPlaying = params.track.isPlaying,
            onDismiss = { sheets.showAudioPipeline = false },
        )
    }
    if (sheets.showCast) {
        PlayerPlatform.host.CastDialog(
            hazeState = sheets.playerHaze,
            onDismiss = { sheets.showCast = false },
        )
    }
    if (sheets.showListenTogetherMembers) {
        ListenTogetherMembersSheet(
            hazeState = sheets.playerHaze,
            onDismiss = { sheets.showListenTogetherMembers = false },
            onManage = {
                sheets.showListenTogetherMembers = false
                params.window.onListenTogether()
            },
        )
    }
    if (params.window.lyricsOffsetOpen) {
        LyricsOffsetSheet(
            hazeState = sheets.playerHaze,
            onDismiss = params.window.onDismissLyricsOffset,
        )
    }
    sheets.lyricsShare?.let { request ->
        PlayerPlatform.host.LyricsShareSheet(
            hazeState = sheets.playerHaze,
            request = request,
            onDismiss = { sheets.lyricsShare = null },
        )
    }
    MixViewOverlay(hazeState = sheets.playerHaze)
}

@Composable
internal fun NowPlayingStageFullscreenVideo(env: NowPlayingEnv) {
    val track = env.params.track
    val transport = env.params.transport
    val media = env.media
    val interaction = env.interaction
    val versionAligning by PlayerSettings.versionAlignmentInProgress.collectAsStateWithLifecycle()
    val transitionWindow by PlayerSettings.smartTransitionWindow.collectAsStateWithLifecycle()
    Box(modifier = Modifier.fillMaxSize().then(env.dockHost)) {
        FullscreenVideoPlayer(
            song = track.song,
            isPlaying = track.isPlaying,
            artRequest = media.art.request,
            rendered = media.videoRendered,
            onRenderedChanged = { media.videoRendered = it },
            onExitFullscreen = media.exitFullscreen,
            onOpenQuality = { env.sheets.showVideoQuality = true },
            scrubber = {
                PlayerScrubber(
                    shown = interaction.shown,
                    durationMs = track.durationMs,
                    loading = versionAligning || track.audioVersionSwitching,
                    mixing = media.mixing && !interaction.scrub.scrubbing,
                    transitionWindow = transitionWindow
                        ?.takeIf { !interaction.scrub.scrubbing && it.end > it.start }
                        ?.let { it.start..it.end },
                    onScrub = interaction.onScrub,
                    onScrubFinished = interaction.onScrubFinished,
                ) {
                    PlaybackQualityLabel(
                        song = track.song,
                        isLoading = track.isLoading,
                        modifier = Modifier
                            .align(Alignment.Center)
                            .padding(horizontal = 8.dp),
                    )
                }
            },
            transport = {
                TransportRow(
                    isPlaying = track.isPlaying,
                    isLoading = track.isLoading || track.audioVersionSwitching,
                    previousEnabled = !interaction.controlsLocked && (track.hasPrevious || interaction.pastRestartPoint),
                    nextEnabled = !interaction.controlsLocked && track.hasNext,
                    onPrevious = transport.onPrevious,
                    onPlayPause = transport.onPlayPause,
                    onNext = transport.onNext,
                    compact = true,
                )
            },
        )
    }
}

@Composable
internal fun NowPlayingStageLandscape(env: NowPlayingEnv) {
    val track = env.params.track
    val transport = env.params.transport
    val window = env.params.window
    val sheets = env.sheets
    val panels = env.panels
    val media = env.media
    val interaction = env.interaction

    val landscapeArtScale by animateFloatAsState(
        targetValue = when {
            !track.isPlaying -> ARTWORK_PAUSE_SHRINK_SCALE
            interaction.scrub.scrubbing -> ARTWORK_DRAG_SHRINK_SCALE
            else -> ARTWORK_EXPANDED_SCALE
        },
        animationSpec = tween(durationMillis = ARTWORK_SCALE_DURATION_MS, easing = ArtworkScaleEasing),
        label = "landscapeArtworkScale",
    )
    val versionAligning by PlayerSettings.versionAlignmentInProgress.collectAsStateWithLifecycle()
    val transitionWindow by PlayerSettings.smartTransitionWindow.collectAsStateWithLifecycle()
    val panelOpen = panels.lyricsOpen || panels.queueOpen

    fun landscapeDockPose(): LandscapeDockPose? {
        val dock = env.dock ?: return null
        val t = env.dockT()
        val mini = dock.miniArtOnScreen() ?: return null
        val anchor = env.dockFrame.anchor ?: return null
        val host = env.dockFrame.host?.takeIf { it.isAttached } ?: return null
        val sleeve = env.dockFrame.landscapeArt?.takeIf { it.isAttached } ?: return null
        val offset = (dock.offset() ?: return null).toInt().toFloat()
        val travel = dock.sheetTravel.takeIf { it > 0f } ?: return null
        if (sleeve.size.width <= 0) return null
        val open = Rect(
            offset = anchor + host.localPositionOf(sleeve, Offset.Zero),
            size = Size(sleeve.size.width.toFloat(), sleeve.size.height.toFloat()),
        )
        val ride = ((mini.top - open.top) / travel).coerceIn(0f, 1f)
        val rect = lerp(mini, open.translate(0f, offset * ride), t)
        return LandscapeDockPose(
            left = rect.left - anchor.x,
            top = rect.top - anchor.y - offset,
            scale = rect.width / open.width,
        )
    }

    val landscapeArtShape: () -> Shape = {
        val t = env.dockT()
        val dock = env.dock
        if (dock == null || t >= 1f) {
            env.dockFrame.cornerShape(LANDSCAPE_ART_CORNER)
        } else {
            val scale = landscapeDockPose()?.scale?.takeIf { it > 0f } ?: 1f
            env.dockFrame.cornerShape(lerp(dock.miniArtCorner(), LANDSCAPE_ART_CORNER, t) / scale)
        }
    }

    Box(modifier = Modifier.fillMaxSize().then(env.dockHost)) {
        LandscapePlayerLayout(
            pane = when {
                panels.lyricsOpen -> PlayerPane.Lyrics
                panels.queueOpen -> PlayerPane.Queue
                else -> PlayerPane.Main
            },
            background = { backgroundModifier ->
                env.fullArtworkBlurContent(
                    backgroundModifier
                        .recordBackdrop(interaction.backdropLayer)
                        .hazeSource(sheets.playerHaze)
                        .then(if (!env.frostOff) Modifier.hazeSource(sheets.queueHaze, zIndex = -1f) else Modifier),
                )
            },
            artwork = { artworkModifier ->
                LandscapeArtwork(
                    art = media.art,
                    autoMixFrames = media.autoMixFrames,
                    artLoaded = media.coverLoaded(),
                    canvas = media.canvas,
                    canvasPair = media.pair,
                    canvasRendered = media.canvasRendered,
                    isPlaying = track.isPlaying,
                    onCanvasRenderedChange = { media.canvasSurfaceRendered = it },
                    hideCanvas = media.staticCanvasMix,
                    hiddenCanvasAlpha = { if (media.canvasRetiring) media.retiringCanvasAlpha() else 0f },
                    freezeCanvas = media.freezeOutgoingCanvas,
                    transitionAlpha = env.dockFade,
                    transitionStill = { env.still()?.image },
                    transitionStillVisible = { env.dockMoving && env.stillTakesOver() },
                    captureStill = env.dockMoving,
                    onStillCaptured = env.onStillCaptured,
                    onClipResumed = env.onClipResumed,
                    pausedForTransition = env.dockMoving || interaction.overlayOpen.value,
                    sleeveShape = landscapeArtShape,
                    shadowFraction = env.dockT,
                    modifier = artworkModifier
                        .then(
                            if (env.dock != null) {
                                Modifier.onGloballyPositioned { env.dockFrame.landscapeArt = it }
                            } else {
                                Modifier
                            },
                        )
                        .drawWithContent {
                            val pose = if (env.docking()) landscapeDockPose() else null
                            if (pose != null) {
                                env.dockFrame.portalLeft = pose.left
                                env.dockFrame.portalTop = pose.top
                                env.dockFrame.portalScale = pose.scale
                                env.sleeveLayer.record { this@drawWithContent.drawContent() }
                            } else {
                                if (env.docking()) {
                                    env.dockFrame.portalScale = 0f
                                }
                                drawContent()
                            }
                        }
                        .then(interaction.skipSwipeGesture)
                        .graphicsLayer {
                            val t = env.dockT()
                            val scale = if (t >= 1f) landscapeArtScale else 1f + (landscapeArtScale - 1f) * t
                            scaleX = scale
                            scaleY = scale
                            translationX = if (t >= 1f) interaction.swipeSettle.value else interaction.swipeSettle.value * t
                        }
                        .clickable(
                            enabled = panelOpen,
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                        ) {
                            panels.queueOpen = false
                            panels.closeLyrics()
                        },
                ) {
                    if (media.videoMode) {
                        WhileShown({ !env.docking() }) {
                            Box(
                                modifier = Modifier
                                    .fillMaxSize()
                                    .graphicsLayer {
                                        shape = landscapeArtShape()
                                        clip = true
                                    }
                                    .background(Color.Black),
                            ) {
                                if (!media.videoRendered) VideoLoadingBackdrop(Modifier.fillMaxSize())
                                MusicVideoSurface(
                                    videoId = track.song.videoId,
                                    fit = !media.squareVideo,
                                    onRenderedChanged = { media.videoRendered = it },
                                    modifier = Modifier.fillMaxSize(),
                                )
                                if (!panelOpen) {
                                    VideoCornerControls(
                                        fullscreen = false,
                                        onToggleFullscreen = media.enterFullscreen,
                                        onOpenQuality = { sheets.showVideoQuality = true },
                                        modifier = Modifier
                                            .align(Alignment.TopEnd)
                                            .padding(8.dp),
                                    )
                                }
                            }
                        }
                    }
                    SleeveNerdStats(
                        song = track.song,
                        modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .padding(horizontal = 10.dp, vertical = 8.dp)
                            .graphicsLayer { alpha = if (panelOpen) 0f else env.dockFade() },
                        bestPart = {
                            BestPartPill(
                                track.song,
                                track.position,
                                sheets.playerHaze,
                                transport.onSeek,
                                overlayOpen = { interaction.overlayOpen.value },
                            )
                        },
                    )
                }
            },
            actions = env.playerActions,
            mainPane = { compact ->
                LandscapeMainPane(
                    compact = compact,
                    caption = if (interaction.hideSongStatus) null else playbackOriginText(track.song, track.playedBy),
                    onOpenCaption = interaction.openPlaybackOrigin,
                    credits = {
                        LandscapeCredits(
                            song = track.song,
                            infoTransition = interaction.infoTransition,
                            signedIn = track.signedIn,
                            likeStatus = track.likeStatus,
                            showRevertCue = interaction.showRevertCue,
                            onToggleLike = transport.onToggleLike,
                            onOpenMenu = window.onOpenMenu,
                            onOpenAlbum = window.onOpenAlbum,
                            onOpenArtist = window.onOpenArtist,
                            hazeState = sheets.playerHaze,
                            overlayOpen = { interaction.overlayOpen.value },
                        )
                    },
                    lyricStrip = if (interaction.syncedLyricsEnabled && !interaction.hideLyricsPreview) {
                        {
                            CurrentLyricStrip(
                                lines = interaction.lyricsTranslation.displayedLyrics,
                                trackKey = track.song.videoId,
                                playhead = interaction.lyricsPlayhead,
                                isPlaying = track.isPlaying && track.position.advancing,
                                durationMs = track.durationMs,
                                lyricsUnavailable = window.lyricsUnavailable,
                                loadingText = interaction.lyricsLoadingText,
                                onClick = panels.openLyrics,
                            )
                        }
                    } else {
                        null
                    },
                    scrubber = {
                        PlayerScrubber(
                            shown = interaction.shown,
                            durationMs = track.durationMs,
                            loading = versionAligning || track.audioVersionSwitching,
                            mixing = media.mixing && !interaction.scrub.scrubbing,
                            transitionWindow = transitionWindow
                                ?.takeIf { !interaction.scrub.scrubbing && it.end > it.start }
                                ?.let { it.start..it.end },
                            onScrub = interaction.onScrub,
                            onScrubFinished = interaction.onScrubFinished,
                        ) {
                            PlaybackQualityLabel(
                                song = track.song,
                                isLoading = track.isLoading,
                                modifier = Modifier
                                    .align(Alignment.Center)
                                    .padding(horizontal = 8.dp),
                            )
                        }
                    },
                    transport = {
                        TransportRow(
                            isPlaying = track.isPlaying,
                            isLoading = track.isLoading || track.audioVersionSwitching,
                            previousEnabled = !interaction.controlsLocked &&
                                (track.hasPrevious || interaction.pastRestartPoint),
                            nextEnabled = !interaction.controlsLocked && track.hasNext,
                            onPrevious = transport.onPrevious,
                            onPlayPause = transport.onPlayPause,
                            onNext = transport.onNext,
                            compact = compact,
                            animationsActive = !panelOpen,
                        )
                    },
                    volume = if (interaction.hideVolumeBar) {
                        null
                    } else {
                        {
                            VolumeRow(
                                value = { interaction.volume.level.value },
                                onValueChange = interaction.onVolumeChange,
                                onValueChangeFinished = interaction.onVolumeChangeFinished,
                            )
                        }
                    },
                )
            },
            lyricsPane = {
                LandscapeLyricsPane(
                    hasLyrics = interaction.lyricsTranslation.displayedLyrics.isNotEmpty(),
                    placeholder = if (window.lyricsUnavailable) {
                        stringResource(Res.string.lyrics_not_available)
                    } else {
                        interaction.lyricsLoadingText
                    },
                    status = interaction.lyricsTranslation.status,
                    onStatusClick = { sheets.showLyricsProviders = true },
                    picking = interaction.lyricPicker.picking,
                    pickBar = {
                        LyricsPickBar(
                            shareEnabled = interaction.lyricPicker.picks.isNotEmpty() &&
                                !interaction.lyricPicker.overBudget,
                            onCancel = interaction.lyricPicker.cancel,
                            onShare = interaction.lyricPicker.share,
                            hazeState = sheets.queueHaze,
                        )
                    },
                    romanizationToggle = {
                        RomanizationToggleButton(
                            state = interaction.lyricsTranslation.romanizationState,
                            showingRomanization = interaction.lyricsTranslation.showingRomanization,
                            enabled = !window.lyrics.isNullOrEmpty(),
                            onClick = interaction.lyricsTranslation.toggleRomanization,
                        )
                    },
                    translationToggle = {
                        TranslationToggleButton(
                            state = interaction.lyricsTranslation.translationState,
                            showingTranslation = interaction.lyricsTranslation.showingTranslation,
                            enabled = !window.lyrics.isNullOrEmpty(),
                            onClick = interaction.lyricsTranslation.toggleTranslation,
                        )
                    },
                ) { panelModifier ->
                    LyricsTranslationMotion(
                        trigger = interaction.lyricsTranslation.transition,
                        reduceMotion = interaction.lyricsTranslation.reduceMotion,
                        modifier = panelModifier,
                    ) { particleProgress ->
                        LyricsPanel(
                            lines = window.lyrics.orEmpty(),
                            subLines = interaction.lyricsTranslation.subLines,
                            trackKey = track.song.videoId,
                            playhead = interaction.lyricsPlayhead,
                            looking = !window.lyricsUnavailable,
                            isPlaying = track.isPlaying && track.position.advancing,
                            onSeekToLine = interaction.seekToLyric,
                            controlsOpen = true,
                            onRevealControls = {},
                            onHideControls = {},
                            translationProgress = particleProgress,
                            canPick = interaction.lyricsShareEnabled,
                            picking = interaction.lyricPicker.picking,
                            picked = interaction.lyricPicker.picks,
                            onPickLine = interaction.lyricPicker.pick,
                            onTogglePick = interaction.lyricPicker.toggle,
                            centerFocus = true,
                            modifier = Modifier.fillMaxSize(),
                        )
                    }
                }
            },
            queuePane = {
                InlineQueue(
                    queue = track.queue,
                    currentIndex = track.queueIndex,
                    autoplayEnabled = track.autoplayEnabled,
                    controlsLocked = interaction.controlsLocked,
                    hazeState = sheets.queueHaze,
                    onJumpTo = transport.onJumpTo,
                    onRemove = transport.onRemoveFromQueue,
                    onMove = transport.onMoveInQueue,
                    onClear = transport.onClearQueue,
                    onSongMenu = transport.onQueueSongMenu,
                    onDragActiveChange = transport.onQueueDragActiveChange,
                    onSwipeToQueue = transport.onQueueSwipeToQueue,
                    gesturesEnabled = panels.queueOpen && !panels.lyricsOpen && !panels.queueDragging,
                    undoNotice = transport.queueUndoNotice,
                    selection = panels.queueSelection,
                    onBulkAction = transport.onQueueBulkAction,
                    onRemoveSelected = transport.onQueueRemoveEntries,
                    modifier = Modifier.fillMaxSize(),
                    onAddAllToPlaylist = transport.onQueueAddAllToPlaylist,
                )
            },
        )
    }
}
