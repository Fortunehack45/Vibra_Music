package com.fortune.vibramusic.ui.player

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.awaitVerticalTouchSlopOrCancellation
import androidx.compose.foundation.gestures.verticalDrag
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.lerp
import androidx.compose.ui.zIndex
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.fortune.vibramusic.data.canvas.CanvasSource
import com.fortune.vibramusic.data.settings.PlayerTheme
import com.fortune.vibramusic.ui.components.optimizedHazeEffect
import com.fortune.vibramusic.ui.haptics.Haptic
import com.fortune.vibramusic.ui.theme.stableStatusBarInsets
import dev.chrisbanes.haze.ExperimentalHazeApi
import dev.chrisbanes.haze.HazeInputScale
import dev.chrisbanes.haze.HazeStyle
import dev.chrisbanes.haze.HazeTint
import dev.chrisbanes.haze.hazeSource
import kotlin.math.pow
import kotlin.math.roundToInt

@Composable
internal fun NowPlayingStagePortrait(env: NowPlayingEnv) {
    val sheets = env.sheets
    val panels = env.panels
    val media = env.media
    val interaction = env.interaction

    Box(
        modifier = Modifier
            .fillMaxSize()
            .onSizeChanged { panels.playerBounds = it }
            .then(env.dockHost)
            .background(Color.Black),
    ) {
        val artworkMeshBackdrop = !env.tabletArtworkBackdrop && media.playerTheme == PlayerTheme.DEFAULT

        NowPlayingStagePortraitBackdrop(env, artworkMeshBackdrop)
        NowPlayingStagePortraitHeroCanvas(env)

        val playerSubviewOpen = panels.lyricsOpen || panels.queueOpen || env.params.window.lyricsOffsetOpen ||
            sheets.showAudioPipeline || sheets.showCast || sheets.showAudioOutput ||
            sheets.showVideoQuality || sheets.showLyricsProviders || sheets.lyricsShare != null
        val topGradientAlpha = if (playerSubviewOpen) {
            maxOf(media.artworkStatusScrimAlpha, SUBVIEW_STATUS_SCRIM_MIN_ALPHA)
        } else {
            media.artworkStatusScrimAlpha
        }
        val steps = 8
        val gradientColors = remember(topGradientAlpha) {
            List(steps) { index ->
                val progress = index / (steps - 1).toFloat()
                val factor = (1f - progress).toDouble().pow(1.5).toFloat()
                Color.Black.copy(alpha = topGradientAlpha * factor)
            }
        }
        val topScrimBrush = remember(gradientColors) {
            Brush.verticalGradient(gradientColors)
        }

        if (artworkMeshBackdrop && media.clipPortrait && media.canvasAspect < PORTRAIT_SCRIM_MAX_ASPECT) {
            Box(
                Modifier.matchParentSize()
                    .graphicsLayer {
                        alpha = media.canvasCover.floatValue *
                            (1f - 2f * env.collapse.p()).coerceIn(0f, 1f) * env.dockFade()
                    }
                    .background(PortraitClipScrim),
            )
        }

        NowPlayingStagePortraitSpotifyDeckGlass(env)

        val spotifyCanvasDim = animateFloatAsState(
            targetValue = if (media.spotifyCanvasPresentation && media.spotifyCanvasControlsOpen) 0.5f else 0f,
            animationSpec = tween(SPOTIFY_CANVAS_CONTROLS_ANIMATION_MS),
            label = "spotifyCanvasDim",
        )
        val spotifyCanvasDimShowing by remember { derivedStateOf { spotifyCanvasDim.value > 0f } }
        if (media.spotifyCanvasPresentation || spotifyCanvasDimShowing) {
            Box(
                Modifier.matchParentSize()
                    .graphicsLayer { alpha = spotifyCanvasDim.value }
                    .background(Color.Black),
            )
        }

        Column(
            modifier = Modifier
                .fillMaxSize()
                .windowInsetsPadding(stableStatusBarInsets())
                .navigationBarsPadding()
                .toggleSpotifyCanvasControlsOnTap(
                    enabled = media.spotifyCanvasPresentation && !media.mixing,
                    onToggle = { media.spotifyCanvasControlsOpen = !media.spotifyCanvasControlsOpen },
                )
                .then(interaction.skipSwipeGesture),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            NowPlayingStagePortraitTopStrip(env, topScrimBrush)

            BoxWithConstraints(Modifier.weight(1f).fillMaxWidth()) {
                val queueHostHeight = maxHeight
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .onGloballyPositioned { panels.dismissBandSpace = it }
                        .pointerInput(sheets.showAudioPipeline, sheets.showCast, panels.panelScrolling) {
                            if (sheets.showAudioPipeline || sheets.showCast || panels.panelScrolling) return@pointerInput
                            awaitEachGesture {
                                val down = awaitFirstDown(requireUnconsumed = false)
                                val space = panels.dismissBandSpace
                                val y = space?.localToRoot(down.position)?.y ?: down.position.y
                                val panelUp = panels.queueOpen || panels.lyricsOpen ||
                                    panels.queueSlide.floatValue > 0.01f
                                val bandTop: Float
                                val bandBottom: Float
                                if (panelUp) {
                                    bandTop = space?.positionInRoot()?.y ?: 0f
                                    bandBottom = bandTop + (ART_BOX_TOP_PAD + HEADER_HEIGHT).toPx()
                                } else {
                                    bandTop = panels.dismissBandTop
                                    bandBottom = panels.dismissBandBottom
                                }
                                if (y >= bandTop && y <= bandBottom) {
                                    if (!panelUp) {
                                        dragQueueIn(
                                            down = down,
                                            travel = bandBottom - bandTop - HEADER_HEIGHT.toPx(),
                                            slide = panels.queueSlide,
                                            onHold = { panels.queueDragging = it },
                                            onSettle = { open ->
                                                if (open != panels.queueOpen) {
                                                    interaction.haptics.play(
                                                        if (open) Haptic.Expand else Haptic.Tap,
                                                    )
                                                    if (open) panels.queueControlsOpen = true
                                                    panels.queueOpen = open
                                                }
                                                panels.queueReleased++
                                            },
                                        )
                                    }
                                    return@awaitEachGesture
                                }
                                if (down.isConsumed) return@awaitEachGesture
                                val drag = awaitVerticalTouchSlopOrCancellation(down.id) { change, _ ->
                                    change.consume()
                                }
                                if (drag != null) verticalDrag(drag.id) { it.consume() }
                            }
                        }
                        .padding(horizontal = PLAYER_GUTTER),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    val versionAligning by PlayerSettings.versionAlignmentInProgress.collectAsStateWithLifecycle()
                    val versionSwitching = versionAligning || env.params.track.audioVersionSwitching
                    NowPlayingStagePortraitUpperDeck(
                        env = env,
                        queueHostHeight = queueHostHeight,
                        modifier = Modifier.weight(1f),
                    )
                    NowPlayingStagePortraitBottomDeck(
                        env = env,
                        versionSwitching = versionSwitching,
                    )
                }
            }
        }
    }
}

@Composable
internal fun NowPlayingStagePortraitBackdrop(
    env: NowPlayingEnv,
    artworkMeshBackdrop: Boolean,
) {
    val sheets = env.sheets
    val panels = env.panels
    val media = env.media
    val interaction = env.interaction

    val legacyMeshBackdrop = !env.tabletArtworkBackdrop && !media.spotifyCanvasPresentation &&
        media.playerTheme == PlayerTheme.LEGACY
    val fullArtworkBackdropAlpha by animateFloatAsState(
        targetValue = if (
            !legacyMeshBackdrop &&
            (env.tabletArtworkBackdrop || env.blurAvailable) &&
            (!media.spotifyCanvasPresentation || panels.lyricsOpen || panels.queueOpen) &&
            (!artworkMeshBackdrop || panels.lyricsOpen || panels.queueOpen)
        ) 1f else 0f,
        animationSpec = tween(durationMillis = 360, easing = FastOutSlowInEasing),
        label = "fullArtworkBackdropCrossfade",
    )

    Box(
        Modifier
            .fillMaxSize()
            .recordBackdrop(interaction.backdropLayer)
            .hazeSource(sheets.playerHaze, zIndex = -1f),
    ) {
        if (legacyMeshBackdrop) {
            LegacyMeshBackdrop(
                ambient = env.ambient,
                entry = media.coverEntry,
                imageUrl = media.remoteArt,
                canvasFrame = { media.canvasFrame.takeIf { media.canvasOwnsAmbient } },
                canvasKey = media.ambientCanvasKey,
                trackKey = env.params.track.song.videoId,
                modifier = Modifier
                    .then(if (!env.frostOff) Modifier.hazeSource(sheets.queueHaze, zIndex = -1f) else Modifier)
                    .graphicsLayer { alpha = 1f - fullArtworkBackdropAlpha },
            )
        }
        if (artworkMeshBackdrop) {
            PlayerMeshBackdrop(
                ambient = env.ambient,
                entry = media.coverEntry,
                trackKey = env.params.track.song.videoId,
                imageUrl = media.remoteArt,
                canvasFrame = { media.canvasFrame.takeIf { media.canvasOwnsAmbient } },
                canvasKey = media.ambientCanvasKey,
                modifier = if (!env.frostOff) Modifier.hazeSource(sheets.queueHaze, zIndex = -1f) else Modifier,
                seamTarget = {
                    val stillBottom = env.stillBottomPx()
                    when {
                        media.clipPortrait -> media.clipBottom
                        stillBottom > 0f -> with(media.density) { stillBottom.toDp() }
                        media.heroMode -> panels.heroHeight
                        else -> 0.dp
                    }
                },
                alpha = {
                    if (media.spotifyCanvasPresentation || fullArtworkBackdropAlpha >= 1f) 0f else 1f
                },
            )
        }
        env.fullArtworkBlurContent(
            Modifier
                .then(if (!env.frostOff) Modifier.hazeSource(sheets.queueHaze, zIndex = -1f) else Modifier)
                .graphicsLayer { alpha = fullArtworkBackdropAlpha },
        )
    }
}

@Composable
internal fun BoxScope.NowPlayingStagePortraitHeroCanvas(env: NowPlayingEnv) {
    val sheets = env.sheets
    val panels = env.panels
    val collapse = env.collapse
    val media = env.media
    val interaction = env.interaction
    val pair = media.pair

    if ((media.heroMode && panels.heroHeight > 0.dp) || media.incomingFullWindow || media.clipFullscreen) {
        val standbyClip = pair?.incomingClip?.takeIf { !(panels.lyricsOpen || panels.queueOpen) || !collapse.collapseDone }
        val matchedLiveHero = pair?.liveOutgoing == true && pair.liveIncoming &&
            sharesHeroRevealFootprint(media.clipFullscreen, media.incomingFullWindow, media.canvasAspect, pair.incomingAspect)
        if (env.staticHeroUnderlay != null && pair != null) {
            val frame = if (media.heroMode) {
                Modifier.fillMaxWidth().height(panels.heroHeight)
            } else {
                Modifier.layout { measurable, constraints ->
                    val rect = panels.expandedSquare
                    val placeable = measurable.measure(Constraints.fixed(rect.width.roundToInt(), rect.height.roundToInt()))
                    layout(constraints.maxWidth, 0) { placeable.place(rect.left.roundToInt(), rect.top.roundToInt()) }
                }
            }
            DecodedCover(
                env.staticHeroUnderlay,
                frame
                    .graphicsLayer {
                        alpha = outgoingArtworkTailAlpha(pair.standbyOpacity())
                        if (media.heroMode) {
                            compositingStrategy = CompositingStrategy.Offscreen
                        } else {
                            scaleX = interaction.artScale
                            scaleY = interaction.artScale
                            translationX = interaction.swipeSettle.value
                            shadowElevation = 10.dp.toPx()
                            shape = TileShape
                            clip = true
                        }
                    }
                    .then(if (media.heroMode) Modifier.artworkBottomFade({ 1f }, { HERO_FADE_FRACTION }) else Modifier)
                    .hazeSource(sheets.playerHaze),
            )
        }
        CanvasPresentationHost(media.heroClipMounted, standbyClip) { clip, standby ->
            val stillStart = remember(clip.url) { if (standby) null else env.stillAtMount() }
            var slotAspect by remember { mutableFloatStateOf(0f) }
            val fullscreen = media.fullCanvasWindow && clip.source == CanvasSource.SPOTIFY
            val portrait = !fullscreen && slotAspect > 0f && slotAspect < 1f
            val bottom = if (portrait) media.canvasBottom(slotAspect, panels.playerBounds) else 0.dp

            CanvasArtworkPlayer(
                canvas = clip,
                isPlaying = env.params.track.isPlaying,
                pausedForTransition = panels.lyricsOpen || panels.queueOpen || panels.queueDragging ||
                    collapse.collapseStarted || env.dockMoving || (interaction.overlayOpen.value && !fullscreen) ||
                    (standby && pair?.started != true) || (!standby && media.freezeOutgoingCanvas),
                contentMode = if (fullscreen) CanvasContentMode.CROP else CanvasContentMode.FIT_PORTRAIT,
                alignPortraitTop = portrait,
                onAspectRatioChanged = {
                    slotAspect = it
                    if (standby) pair?.incomingAspect = it else media.canvasAspect = it
                },
                portraitRevealBounds = panels.playerBounds,
                presentationAlpha = {
                    if (env.gesturePair != null || env.stillTakesOver()) 0f
                    else if (standby) env.clipTransitionAlpha()
                    else if (media.staticCanvasMix) {
                        if (clip.url == media.retiringCanvas?.url) media.retiringCanvasAlpha() * env.clipTransitionAlpha() else 0f
                    } else if (matchedLiveHero && !pair.sharesClip && !fullscreen) {
                        outgoingArtworkTailAlpha(pair.reveal()) * env.clipTransitionAlpha()
                    } else if (pair?.liveOutgoing == true && !pair.liveIncoming && media.autoMixFrames?.incoming != null && !env.stillMoving) {
                        outgoingArtworkTailAlpha(pair.reveal()) * env.clipTransitionAlpha()
                    } else if (pair != null && !pair.sharesClip && (portrait || fullscreen) &&
                        pair.incomingClip?.source != CanvasSource.SPOTIFY &&
                        (pair.liveIncoming || media.autoMixFrames?.incoming != null)
                    ) (1f - pair.reveal()) * env.clipTransitionAlpha()
                    else env.clipTransitionAlpha()
                },
                resumeDelayMs = if (!standby && fullscreen) SPOTIFY_CANVAS_RESUME_DELAY_MS else 0L,
                startPositionMs = stillStart?.positionMs ?: 0L,
                revealInstantly = standby || stillStart != null,
                captureStill = if (standby) env.captureStandby(clip) else
                    !media.staticCanvasMix && env.stillMoving && (!fullscreen || (env.gesturePair != null && env.gesturePair.gestureOutgoing == null)),
                onStillCaptured = { image, position ->
                    if (standby || fullscreen) env.retainGestureStill(clip, standby, image, position)
                    else env.onStillCaptured(image, position)
                },
                onResumed = {
                    if (standby) pair?.gestureIncoming = null
                    else if (fullscreen) pair?.gestureOutgoing = null
                    else env.onClipResumed()
                },
                onRenderedChanged = {
                    if (standby) pair?.reportIncoming(it) else {
                        media.canvasSurfaceRendered = it
                        pair?.reportOutgoing(it)
                    }
                },
                nowPlaying = true,
                organicReveal = if (standby) {
                    pair?.standbyReveal(env.staticHeroUnderlay != null || (matchedLiveHero && !env.stillMoving))
                } else if (media.fullBleedArt && media.heroIncomingStill != null && !env.stillMoving && env.gesturePair == null) {
                    pair?.outgoingStillBannerReveal(
                        media.autoMixFrames,
                        IntSize(panels.playerBounds.width, with(media.density) { panels.heroHeight.roundToPx() }),
                        HERO_FADE_FRACTION,
                        env.clipTransitionAlpha,
                    )
                } else null,
                frameCapturePx = if (!standby && media.canvasOwnsAmbient && media.tintsOffClip && !fullscreen && !env.tabletArtworkBackdrop) {
                    CANVAS_FRAME_CAPTURE_PX
                } else {
                    0
                },
                onFrameCaptured = {
                    if (!standby && media.canvasOwnsAmbient && !fullscreen && !env.tabletArtworkBackdrop &&
                        !panels.lyricsOpen && !panels.queueOpen && !panels.queueDragging
                    ) media.canvasFrame = it
                },
                refreshFrameEveryMs = if (
                    standby || !media.canvasOwnsAmbient || fullscreen || env.tabletArtworkBackdrop ||
                    panels.lyricsOpen || panels.queueOpen || panels.queueDragging || env.dockMoving
                ) {
                    null
                } else {
                    media.meshRefreshMs
                },
                onCoverChanged = { if (!standby) media.canvasCover.floatValue = it },
                bottomFade = when {
                    fullscreen -> 0f
                    portrait -> media.clipFadeFraction(bottom, panels.heroHeight)
                    else -> HERO_FADE_FRACTION
                },
                bottomFadeEndPx = if (portrait) with(media.density) { bottom.toPx() } else null,
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .then(
                        if (fullscreen || portrait) Modifier.fillMaxSize()
                        else Modifier.fillMaxWidth().height(panels.heroHeight),
                    )
                    .hazeSource(sheets.playerHaze),
            )
        }
    }
}

@Composable
@OptIn(ExperimentalHazeApi::class)
internal fun BoxScope.NowPlayingStagePortraitSpotifyDeckGlass(env: NowPlayingEnv) {
    val media = env.media
    AnimatedVisibility(
        visible = media.spotifyCanvasPresentation && media.spotifyCanvasControlsOpen,
        modifier = Modifier
            .align(Alignment.BottomCenter)
            .fillMaxWidth()
            .fillMaxHeight(0.56f),
        enter = fadeIn(tween(SPOTIFY_CANVAS_CONTROLS_ANIMATION_MS)) + playerDeckSlideIn(),
        exit = fadeOut(tween(SPOTIFY_CANVAS_CONTROLS_ANIMATION_MS)) + playerDeckSlideOut(),
    ) {
        val reduceDynamicBlur by PlayerSettings.reduceDynamicBlur.collectAsStateWithLifecycle()
        Box(
            modifier = Modifier
                .fillMaxSize()
                .then(
                    if (reduceDynamicBlur || !renderEffectBlurSupported || env.interaction.overlayOpen.value) {
                        Modifier.background(
                            Brush.verticalGradient(
                                0.00f to Color.Transparent,
                                SPOTIFY_DECK_TOP_FADE_FRACTION to Color.Black.copy(alpha = 0.40f),
                                1.00f to Color.Black.copy(alpha = 0.40f),
                            ),
                        )
                    } else {
                        Modifier.optimizedHazeEffect(
                            state = env.sheets.playerHaze,
                            style = HazeStyle(
                                backgroundColor = Color.Transparent,
                                tints = emptyList(),
                                blurRadius = 48.dp,
                                noiseFactor = 0f,
                                fallbackTint = HazeTint(Color.Transparent),
                            ),
                        ) {
                            inputScale = HazeInputScale.Fixed(0.18f)
                            canDrawArea = { true }
                            mask = Brush.verticalGradient(
                                0.00f to Color.Transparent,
                                SPOTIFY_DECK_TOP_FADE_FRACTION to Color.Black,
                                1.00f to Color.Black,
                            )
                        }
                    },
                ),
        )
    }
}

@Composable
internal fun NowPlayingStagePortraitTopStrip(
    env: NowPlayingEnv,
    topScrimBrush: Brush,
) {
    val media = env.media
    val collapse = env.collapse
    val track = env.params.track
    Box(
        modifier = Modifier
            .zIndex(1f)
            .fillMaxWidth()
            .height(media.topStrip)
            .drawBehind {
                val above = media.statusBarTop.toPx()
                translate(top = -above) {
                    drawRect(
                        brush = topScrimBrush,
                        size = Size(size.width, size.height + above),
                    )
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier
                .align(Alignment.TopCenter)
                .offset {
                    IntOffset(
                        x = 0,
                        y = lerp(
                            6.dp,
                            (media.topStrip - 5.dp).coerceAtLeast(0.dp) / 2,
                            collapse.p(),
                        ).roundToPx(),
                    )
                }
                .width(38.dp)
                .height(5.dp)
                .graphicsLayer { alpha = media.spotifyChromeAlpha }
                .shadow(2.dp, RoundedCornerShape(3.dp), clip = false)
                .clip(RoundedCornerShape(3.dp))
                .additiveChrome(LocalPlayerChrome.current)
                .background(chromeWhite(0.70f)),
        )
        if (!env.interaction.hideSongStatus) {
            WhileShown({ !collapse.collapseAlmostDone }) {
                PlaybackOriginCaption(
                    text = playbackOriginText(track.song, track.playedBy),
                    onClick = env.interaction.openPlaybackOrigin,
                    textAlign = TextAlign.Center,
                    contentPadding = PaddingValues(start = PLAYER_GUTTER, end = PLAYER_GUTTER, bottom = 1.dp),
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .graphicsLayer { alpha = (1f - collapse.p()) * media.spotifyChromeAlpha },
                )
            }
        }
    }
}

@Composable
internal fun NowPlayingStagePortraitUpperDeck(
    env: NowPlayingEnv,
    queueHostHeight: Dp,
    modifier: Modifier = Modifier,
) {
    val panels = env.panels
    val collapse = env.collapse
    val media = env.media

    BoxWithConstraints(
        modifier = modifier
            .widthIn(max = PLAYER_MAX_WIDTH)
            .fillMaxWidth()
            .padding(top = ART_BOX_TOP_PAD, bottom = 18.dp),
    ) {
        if (media.spotifyCanvasPresentation && panels.playerDeckSettledOpen &&
            maxHeight != media.spotifyCanvasExpandedTopHeight
        ) {
            SideEffect { media.spotifyCanvasExpandedTopHeight = maxHeight }
        }
        val roomy = maxHeight + panels.controlSpread
        val wantArt = minOf(maxWidth, roomy - ART_TITLE_GAP - HEADER_HEIGHT)
        val fullArt = minOf(wantArt, maxHeight - ART_TITLE_GAP - HEADER_HEIGHT)
            .coerceAtLeast(THUMB_SIZE)
        val slack = (roomy - wantArt - ART_TITLE_GAP - HEADER_HEIGHT)
            .coerceAtLeast(0.dp)
        val controlDeckIsMeasured = !media.spotifyCanvasPresentation || panels.playerDeckSettledOpen
        if (!panels.lyricsOpen && !panels.queueOpen && !panels.queueDragging && collapse.collapseAtRest && controlDeckIsMeasured) {
            val target = with(media.density) {
                val half = slack
                    .coerceAtMost(CONTROL_GAP_SPREAD_MAX * 2)
                    .toPx()
                    .div(2f)
                    .roundToInt()
                (half * 2).toDp()
            }
            val granted = with(media.density) {
                val steppedPx = (panels.controlSpread.toPx() +
                    (target.toPx() - panels.controlSpread.toPx()) * 0.4f)
                    .roundToInt()
                steppedPx.toDp()
            }
            if (granted != panels.controlSpread) {
                SideEffect {
                    panels.controlSpread = granted
                    lastControlSpread = granted
                }
            }
        }

        val groupTop = (maxHeight - fullArt - ART_TITLE_GAP - HEADER_HEIGHT)
            .coerceAtLeast(0.dp) / 2
        val spotifyTitleRange = if (media.spotifyCanvasPresentation) {
            val expandedTopHeight = media.spotifyCanvasExpandedTopHeight
                .takeIf { it > 0.dp }
                ?: maxHeight
            (expandedTopHeight + media.spotifyCanvasDeckHeight - HEADER_HEIGHT).coerceAtLeast(0.dp)
        } else {
            null
        }
        val thumbWidth = if (media.videoMode && !media.squareVideo) THUMB_SIZE * (16f / 9f) else THUMB_SIZE
        val bannerBottom = media.statusBarTop + media.topStrip + ART_BOX_TOP_PAD +
            groupTop + fullArt + ART_TITLE_GAP / 2
        val bannerSettled = !panels.lyricsOpen || panels.heroHeight == 0.dp
        if (bannerSettled && bannerBottom != panels.heroHeight) {
            SideEffect { panels.heroHeight = bannerBottom }
        }

        val bannerTopPx = with(media.density) {
            -(media.statusBarTop.roundToPx() + media.topStrip.roundToPx() + ART_BOX_TOP_PAD.roundToPx())
        }
        val boxWidthPx = constraints.maxWidth
        val rtl = LocalLayoutDirection.current == LayoutDirection.Rtl
        val square = with(media.density) {
            val side = fullArt.roundToPx()
            val start = ((maxWidth - fullArt) / 2).roundToPx()
            val left = if (rtl) boxWidthPx - start - side else start
            val x = ((panels.playerBounds.width - boxWidthPx) / 2f).roundToInt() + left
            val y = groupTop.roundToPx() - bannerTopPx
            Rect(Offset(x.toFloat(), y.toFloat()), Size(side.toFloat(), side.toFloat()))
        }
        if (square != panels.expandedSquare) SideEffect { panels.expandedSquare = square }
        val boxLeftPx = ((panels.playerBounds.width - boxWidthPx) / 2f).roundToInt()

        val geo = PortraitSleeveGeometry(
            env = env,
            rtl = rtl,
            maxWidth = maxWidth,
            fullArt = fullArt,
            groupTop = groupTop,
            spotifyTitleRange = spotifyTitleRange,
            thumbWidth = thumbWidth,
            bannerTopPx = bannerTopPx,
            boxWidthPx = boxWidthPx,
            boxLeftPx = boxLeftPx,
        )

        NowPlayingStagePortraitSleeve(env, geo)
        NowPlayingStagePortraitCardSlot(env, geo)
        if (media.videoMode) {
            NowPlayingStagePortraitVideoCard(env, geo)
        }
        NowPlayingStagePortraitTitleRow(env, geo)
        NowPlayingStagePortraitLyricsOverlay(env)

        val queueContentHeight = (queueHostHeight - ART_BOX_TOP_PAD - 18.dp).coerceAtLeast(0.dp)
        val queueDeckInset = (queueContentHeight - maxHeight).coerceAtLeast(0.dp)
        NowPlayingStagePortraitQueueOverlay(env, queueContentHeight, queueDeckInset)
    }
}
