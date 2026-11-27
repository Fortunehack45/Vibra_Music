package com.fortune.vibramusic.ui.player

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Undo
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.IosShare
import androidx.compose.material.icons.rounded.MoreHoriz
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.constrainHeight
import androidx.compose.ui.unit.constrainWidth
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.lerp
import androidx.compose.ui.unit.offset
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.fortune.vibramusic.data.model.LikeStatus
import com.fortune.vibramusic.sharedui.resources.*
import com.fortune.vibramusic.ui.components.ExplicitBadge
import com.fortune.vibramusic.ui.components.menuAnchor
import com.fortune.vibramusic.ui.haptics.Haptic
import com.fortune.vibramusic.ui.icons.VibraMusicIcons
import dev.chrisbanes.haze.hazeSource
import org.jetbrains.compose.resources.stringResource

@Composable
internal fun NowPlayingStagePortraitTitleRow(
    env: NowPlayingEnv,
    geo: PortraitSleeveGeometry,
) {
    val track = env.params.track
    val transport = env.params.transport
    val window = env.params.window
    val sheets = env.sheets
    val panels = env.panels
    val collapse = env.collapse
    val interaction = env.interaction

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .offset {
                IntOffset(
                    x = 0,
                    y = (
                        geo.currentTitleTop() -
                            lerp(0.dp, (HEADER_HEIGHT - THUMB_SIZE) / 2, collapse.p())
                        ).roundToPx(),
                )
            }
            .layout { measurable, constraints ->
                val start = geo.titleStart().roundToPx()
                val placeable = measurable.measure(constraints.offset(horizontal = -start))
                layout(
                    constraints.constrainWidth(placeable.width + start),
                    constraints.constrainHeight(placeable.height),
                ) { placeable.placeRelative(start, 0) }
            }
            .height(HEADER_HEIGHT)
            .onGloballyPositioned { panels.dismissBandBottom = it.boundsInRoot().bottom },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(
            Modifier
                .weight(1f)
                .graphicsLayer {
                    val scale = 1f - 0.2f * collapse.p()
                    scaleX = scale
                    scaleY = scale
                    transformOrigin = TransformOrigin(0f, 0.5f)
                },
        ) {
            val scrolls = {
                !(panels.lyricsOpen || panels.queueOpen || panels.queueDragging) && !collapse.collapsePastSettling
            }
            SlidingSongInfo(
                song = track.song,
                transition = interaction.infoTransition,
                modifier = Modifier.additiveChrome(LocalPlayerChrome.current),
            ) { infoSong ->
                var titleOverflowing by remember { mutableStateOf(false) }
                val scrolling = scrolls()
                val artistColor = chromeWhite(0.55f)
                Column {
                    MarqueeText(
                        text = infoSong.title,
                        style = MaterialTheme.typography.titleLarge.copy(fontSize = 20.sp),
                        color = Color.White,
                        enabled = scrolling,
                        leading = if (infoSong.isExplicit == true) {
                            { ExplicitBadge(color = artistColor) }
                        } else {
                            null
                        },
                        onOverflowChange = { titleOverflowing = it },
                        modifier = Modifier.opensPage(infoSong.albumId, window.onOpenAlbum),
                    )
                    ArtistCreditsMarquee(
                        text = infoSong.artist,
                        credits = remember(infoSong.artist, infoSong.artists, infoSong.artistId) {
                            artistCredits(infoSong.artist, infoSong.artists, infoSong.artistId)
                        },
                        style = MaterialTheme.typography.titleLarge.copy(
                            fontWeight = FontWeight.W500,
                            fontSize = 20.sp,
                        ),
                        color = artistColor,
                        enabled = scrolling,
                        startDelayMillis = if (titleOverflowing) MARQUEE_ARTIST_STAGGER_MS else 0L,
                        onOpenArtist = window.onOpenArtist,
                    )
                }
            }
        }
        Spacer(Modifier.width(10.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (track.signedIn || track.song.localUri != null) {
                val liked = track.likeStatus == LikeStatus.LIKE
                CircleGlyph(
                    icon = if (liked) VibraMusicIcons.HeartFilled else VibraMusicIcons.Heart,
                    contentDescription = stringResource(
                        if (liked) Res.string.remove_from_liked else Res.string.like,
                    ),
                    onClick = transport.onToggleLike,
                    active = liked,
                    haptic = if (liked) Haptic.ToggleOff else Haptic.ToggleOn,
                    hazeState = sheets.playerHaze,
                )
                Spacer(Modifier.width(8.dp))
            }
            val lyricsShareGlyphVisible = panels.lyricsOpen && collapse.collapseDone && interaction.lyricsShareEnabled &&
                !window.lyrics.isNullOrEmpty() && (!panels.lyricsControlsOpen || interaction.lyricPicker.picking)
            CircleGlyph(
                icon = when {
                    interaction.showRevertCue -> Icons.AutoMirrored.Rounded.Undo
                    lyricsShareGlyphVisible && interaction.lyricPicker.picking -> Icons.Rounded.Close
                    lyricsShareGlyphVisible -> Icons.Rounded.IosShare
                    else -> Icons.Rounded.MoreHoriz
                },
                contentDescription = stringResource(
                    when {
                        interaction.showRevertCue -> Res.string.more
                        lyricsShareGlyphVisible && interaction.lyricPicker.picking -> Res.string.cancel
                        lyricsShareGlyphVisible -> Res.string.share
                        else -> Res.string.more
                    },
                ),
                onClick = when {
                    interaction.showRevertCue -> window.onOpenMenu
                    lyricsShareGlyphVisible && interaction.lyricPicker.picking -> interaction.lyricPicker.cancel
                    lyricsShareGlyphVisible -> interaction.lyricPicker.beginPicking
                    else -> window.onOpenMenu
                },
                haptic = if (lyricsShareGlyphVisible && !interaction.showRevertCue) {
                    Haptic.Select
                } else {
                    Haptic.Tap
                },
                hazeState = sheets.playerHaze,
                modifier = Modifier.menuAnchor(),
            )
        }
    }
}

@Composable
internal fun BoxScope.NowPlayingStagePortraitLyricsOverlay(env: NowPlayingEnv) {
    val track = env.params.track
    val window = env.params.window
    val sheets = env.sheets
    val panels = env.panels
    val collapse = env.collapse
    val interaction = env.interaction

    val lyricsPanelVisible = panels.lyricsOpen && collapse.collapseDone
    if (lyricsPanelVisible || interaction.playerPrewarmStage >= 2) {
        LyricsTranslationMotion(
            trigger = interaction.lyricsTranslation.transition,
            reduceMotion = interaction.lyricsTranslation.reduceMotion,
            modifier = Modifier
                .fillMaxSize()
                .padding(top = HEADER_HEIGHT)
                .offset {
                    if (lyricsPanelVisible) IntOffset.Zero else IntOffset(100_000, 0)
                }
                .graphicsLayer { alpha = if (lyricsPanelVisible) collapse.panelFade.value else 0f }
                .then(if (!env.frostOff) Modifier.hazeSource(sheets.queueHaze, zIndex = 1f) else Modifier),
        ) { particleProgress ->
            LyricsPanel(
                lines = window.lyrics.orEmpty(),
                subLines = interaction.lyricsTranslation.subLines,
                trackKey = track.song.videoId,
                playhead = interaction.lyricsPlayhead,
                looking = !window.lyricsUnavailable,
                isPlaying = track.isPlaying && track.position.advancing,
                active = lyricsPanelVisible,
                onSeekToLine = interaction.seekToLyric,
                controlsOpen = panels.lyricsControlsOpen,
                onRevealControls = { panels.lyricsControlsOpen = true },
                onHideControls = { panels.lyricsControlsOpen = false },
                translationProgress = particleProgress,
                onScrollingChange = { panels.lyricsScrolling = it },
                canPick = interaction.lyricsShareEnabled,
                picking = interaction.lyricPicker.picking,
                picked = interaction.lyricPicker.picks,
                onPickLine = interaction.lyricPicker.pick,
                onTogglePick = interaction.lyricPicker.toggle,
                modifier = Modifier.fillMaxSize(),
            )
        }

        val translateShown = lyricsPanelVisible && panels.lyricsControlsOpen
        val translateFade by animateFloatAsState(
            targetValue = if (translateShown) 1f else 0f,
            animationSpec = tween(if (translateShown) 220 else 160),
            label = "translateFade",
        )
        if (translateFade > 0.01f && !interaction.lyricPicker.picking) {
            Box(
                modifier = Modifier
                    .align(Alignment.BottomStart)
                    .graphicsLayer { alpha = translateFade },
            ) {
                RomanizationToggleButton(
                    state = interaction.lyricsTranslation.romanizationState,
                    showingRomanization = interaction.lyricsTranslation.showingRomanization,
                    enabled = translateShown && !window.lyrics.isNullOrEmpty(),
                    onClick = interaction.lyricsTranslation.toggleRomanization,
                )
            }
            Box(
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .graphicsLayer { alpha = translateFade },
            ) {
                TranslationToggleButton(
                    state = interaction.lyricsTranslation.translationState,
                    showingTranslation = interaction.lyricsTranslation.showingTranslation,
                    enabled = translateShown && !window.lyrics.isNullOrEmpty(),
                    onClick = interaction.lyricsTranslation.toggleTranslation,
                )
            }
        }
        if (interaction.lyricPicker.picking) {
            LyricsPickBar(
                shareEnabled = interaction.lyricPicker.picks.isNotEmpty() &&
                    !interaction.lyricPicker.overBudget,
                onCancel = interaction.lyricPicker.cancel,
                onShare = interaction.lyricPicker.share,
                hazeState = sheets.queueHaze,
                modifier = Modifier.align(Alignment.BottomCenter),
            )
        }
    }
}

@Composable
internal fun NowPlayingStagePortraitQueueOverlay(
    env: NowPlayingEnv,
    queueContentHeight: Dp,
    queueDeckInset: Dp,
) {
    val track = env.params.track
    val transport = env.params.transport
    val panels = env.panels
    val collapse = env.collapse
    val interaction = env.interaction

    val queuePanelVisible = !panels.lyricsOpen &&
        (panels.queueDragging || (panels.queueOpen && collapse.queueShowing && collapse.collapseDone))
    if (queuePanelVisible || interaction.playerPrewarmStage >= 3 || panels.queuePaneMounted) {
        SideEffect { panels.queuePaneMounted = true }
        Column(
            modifier = Modifier
                .fillMaxSize()
                .layout { measurable, constraints ->
                    val height = queueContentHeight.roundToPx()
                    val placeable = measurable.measure(
                        constraints.copy(minHeight = height, maxHeight = height),
                    )
                    layout(placeable.width, constraints.maxHeight) {
                        placeable.placeRelative(0, 0)
                    }
                }
                .padding(top = HEADER_HEIGHT)
                .offset {
                    if (queuePanelVisible) IntOffset.Zero else IntOffset(100_000, 0)
                }
                .graphicsLayer {
                    alpha = if (!queuePanelVisible) {
                        0f
                    } else if (panels.queueDragging) {
                        ((panels.queueSlide.floatValue - 0.45f) / 0.55f).coerceIn(0f, 1f)
                    } else {
                        collapse.panelFade.value
                    }
                    translationY = if (queuePanelVisible) {
                        (1f - panels.queueSlide.floatValue) * 26.dp.toPx()
                    } else {
                        0f
                    }
                },
        ) {
            InlineQueue(
                queue = track.queue,
                currentIndex = track.queueIndex,
                autoplayEnabled = track.autoplayEnabled,
                controlsLocked = interaction.controlsLocked,
                hazeState = env.sheets.queueHaze,
                onJumpTo = transport.onJumpTo,
                onRemove = transport.onRemoveFromQueue,
                onMove = transport.onMoveInQueue,
                onClear = transport.onClearQueue,
                onSongMenu = transport.onQueueSongMenu,
                onScrollingChange = { panels.queueScrolling = it },
                onSwipeToQueue = transport.onQueueSwipeToQueue,
                gesturesEnabled = queuePanelVisible && panels.queueOpen && !panels.queueDragging,
                undoNotice = transport.queueUndoNotice,
                selection = panels.queueSelection,
                onBulkAction = transport.onQueueBulkAction,
                onRemoveSelected = transport.onQueueRemoveEntries,
                onDragActiveChange = transport.onQueueDragActiveChange,
                onAddAllToPlaylist = transport.onQueueAddAllToPlaylist,
                playerDeckInset = queueDeckInset,
                collapsePlayerOnScroll = true,
                onRevealPlayer = { if (!panels.queueSelection.active) panels.queueControlsOpen = true },
                onHidePlayer = { panels.queueControlsOpen = false },
                modifier = Modifier.weight(1f),
            )
        }
    }
}

@Composable
internal fun NowPlayingStagePortraitBottomDeck(
    env: NowPlayingEnv,
    versionSwitching: Boolean,
) {
    val track = env.params.track
    val transport = env.params.transport
    val window = env.params.window
    val sheets = env.sheets
    val panels = env.panels
    val collapse = env.collapse
    val media = env.media
    val interaction = env.interaction

    SlidingPlayerDeck(
        visible = !interaction.lyricPicker.picking &&
            (!panels.lyricsOpen || panels.lyricsControlsOpen) &&
            (!panels.queueOpen || (panels.queueControlsOpen && !panels.queueSelection.active)) &&
            (!media.spotifyCanvasPresentation || media.spotifyCanvasControlsOpen || media.mixing),
        reveal = panels.playerDeckReveal,
        fadeIn = { !panels.lyricsOpen && !panels.queueOpen && collapse.p() > 0f },
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.onSizeChanged { size ->
                if (media.spotifyCanvasPresentation) {
                    val measuredHeight = with(media.density) { size.height.toDp() }
                    if (measuredHeight != media.spotifyCanvasDeckHeight) {
                        media.spotifyCanvasDeckHeight = measuredHeight
                    }
                }
            },
        ) {
            Column(
                modifier = Modifier
                    .widthIn(max = PLAYER_MAX_WIDTH)
                    .fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(interaction.lyricSlotHeight),
                    contentAlignment = Alignment.CenterStart,
                ) {
                    if (!panels.lyricsOpen && interaction.syncedLyricsEnabled && !interaction.hideLyricsPreview) {
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
                    if (!panels.lyricsOpen && !interaction.syncedLyricsEnabled) {
                        Text(
                            text = "\u00A0",
                            style = MaterialTheme.typography.titleMedium,
                            maxLines = 1,
                            modifier = Modifier
                                .fillMaxWidth()
                                .offset(y = 6.dp)
                                .padding(vertical = 4.dp),
                        )
                    }
                    if (panels.lyricsOpen) {
                        LyricsStatusWithChange(
                            status = interaction.lyricsTranslation.status,
                            onStatusClick = { sheets.showLyricsProviders = true },
                            modifier = Modifier
                                .fillMaxWidth()
                                .offset(y = 6.dp)
                                .padding(vertical = 4.dp),
                        )
                    }
                }
                val transitionWindow by PlayerSettings.smartTransitionWindow.collectAsStateWithLifecycle()
                PlayerScrubber(
                    shown = interaction.shown,
                    durationMs = track.durationMs,
                    loading = versionSwitching,
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

                val transportRowContent: @Composable () -> Unit = {
                    TransportRow(
                        isPlaying = track.isPlaying,
                        isLoading = track.isLoading || track.audioVersionSwitching,
                        previousEnabled = !interaction.controlsLocked &&
                            (track.hasPrevious || interaction.pastRestartPoint),
                        nextEnabled = !interaction.controlsLocked && track.hasNext,
                        onPrevious = transport.onPrevious,
                        onPlayPause = transport.onPlayPause,
                        onNext = transport.onNext,
                        animationsActive = !interaction.lyricPicker.picking &&
                            (!panels.lyricsOpen || panels.lyricsControlsOpen) &&
                            (!panels.queueOpen || panels.queueControlsOpen) &&
                            (!media.spotifyCanvasPresentation || media.spotifyCanvasControlsOpen || media.mixing),
                    )
                }
                if (!interaction.hideVolumeBar) {
                    Spacer(Modifier.height(8.dp + panels.controlSpread / 2))
                    transportRowContent()
                    Spacer(Modifier.height(12.dp + panels.controlSpread / 2))
                    VolumeRow(
                        value = { interaction.volume.level.value },
                        onValueChange = interaction.onVolumeChange,
                        onValueChangeFinished = interaction.onVolumeChangeFinished,
                    )
                    Spacer(Modifier.height(6.dp))
                } else {
                    val run = 8.dp + 12.dp + 6.dp + panels.controlSpread + VOLUME_ROW_HEIGHT
                    val lift = SCRUBBER_LABEL_LIFT / 2
                    Spacer(Modifier.height(run / 2 - lift))
                    transportRowContent()
                    Spacer(Modifier.height(run / 2 + lift))
                }

                env.playerActions()
                Spacer(Modifier.height(18.dp))
            }
        }
    }
}
