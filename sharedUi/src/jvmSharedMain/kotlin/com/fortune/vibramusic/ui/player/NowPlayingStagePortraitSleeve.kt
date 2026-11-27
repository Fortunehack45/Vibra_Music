package com.fortune.vibramusic.ui.player

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.constrain
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.fortune.vibramusic.data.canvas.CanvasSource
import com.fortune.vibramusic.ui.icons.VibraMusicIcons
import dev.chrisbanes.haze.hazeSource
import kotlin.math.roundToInt

@Composable
internal fun NowPlayingStagePortraitSleeve(
    env: NowPlayingEnv,
    geo: PortraitSleeveGeometry,
) {
    val sheets = env.sheets
    val panels = env.panels
    val collapse = env.collapse
    val media = env.media
    val interaction = env.interaction
    val pair = media.pair

    Box(
        modifier = Modifier
            .layout { measurable, constraints ->
                val mini = geo.miniInBox()
                val open = geo.sleeveRect()
                if (mini != null) env.dockFrame.ride = geo.dockRide(open, mini)
                val rect = geo.towardsDock(open, mini)
                env.dockFrame.miniInBox = mini
                env.dockFrame.sleeve = rect
                val placeable = measurable.measure(
                    Constraints.fixed(rect.width.roundToInt(), rect.height.roundToInt()),
                )
                layout(constraints.maxWidth, 0) {
                    val x = rect.left.roundToInt()
                    val y = rect.top.roundToInt()
                    env.dockFrame.portalLeft = (geo.boxLeftPx + x).toFloat()
                    env.dockFrame.portalScale = 1f
                    env.dockFrame.portalTop = (y - geo.bannerTopPx).toFloat()
                    placeable.place(x, y)
                }
            }
            .drawWithContent {
                if (env.docking()) {
                    env.sleeveLayer.record { this@drawWithContent.drawContent() }
                } else {
                    drawContent()
                }
            }
            .graphicsLayer {
                val share = geo.bannerShare()
                val idle = geo.cardScale()
                val t = env.dockT()
                val open = idle + (1f - idle) * share
                val scale = if (t >= 1f) open else 1f + (open - 1f) * t
                scaleX = scale
                scaleY = scale
                translationX = interaction.swipeSettle.value * (1f - collapse.p()) * (1f - share) * t
            }
            .hazeSource(sheets.playerHaze)
            .graphicsLayer {
                alpha = (
                    if (env.gesturePair != null || env.stillTakesOver()) 1f
                    else if (media.canvasRetiring) media.canvasRetire.value
                    else if (env.staticHeroUnderlay != null) 0f
                    else if (media.heroMode && pair?.liveOutgoing == true) 1f
                    else if ((media.heroMode || media.incomingFullWindow) && pair?.liveIncoming == true) 1f - pair.standbyOpacity()
                    else if (media.staticCanvasMix) 1f
                    else if (media.heroClip != null) 1f - media.canvasCover.floatValue
                    else 1f
                    ) *
                    (if (!media.videoMode || env.docking()) 1f else (collapse.p() * 2f - 1f).coerceIn(0f, 1f))
            }
            .graphicsLayer {
                val shown = geo.sleeveShown()
                shadowElevation = if (media.coverLoaded()) {
                    10.dp.toPx() * (1f - 2f * shown).coerceAtLeast(0f) * env.dockT()
                } else {
                    0f
                }
                shape = env.dockFrame.cornerShape(geo.sleeveCorner())
                clip = media.coverLoaded()
            }
            .graphicsLayer {
                shape = env.dockFrame.cornerShape(geo.sleeveCorner())
                clip = true
                compositingStrategy = if (geo.sleeveShown() > 0f) {
                    CompositingStrategy.Offscreen
                } else {
                    CompositingStrategy.Auto
                }
            }
            .artworkBottomFade({ geo.sleeveShown() }, { env.stillFadeFraction() }),
    ) {
        Box(
            modifier = Modifier
                .layout { measurable, constraints ->
                    val card = geo.towardsDock(geo.cardRect(), env.dockFrame.miniInBox)
                    val sleeve = env.dockFrame.sleeve
                    val placeable = measurable.measure(
                        Constraints.fixed(card.width.roundToInt(), card.height.roundToInt()),
                    )
                    layout(constraints.maxWidth, 0) {
                        placeable.place(
                            (card.left - sleeve.left).roundToInt(),
                            (card.top - sleeve.top).roundToInt(),
                        )
                    }
                }
                .graphicsLayer {
                    val share = geo.bannerShare()
                    val idle = geo.cardScale()
                    val t = env.dockT()
                    val scale = if (t >= 1f) {
                        idle / (idle + (1f - idle) * share)
                    } else {
                        (1f + (idle - 1f) * t) / (1f + (idle + (1f - idle) * share - 1f) * t)
                    }
                    scaleX = scale
                    scaleY = scale
                    translationX = interaction.swipeSettle.value * (1f - collapse.p()) * share * t
                    shape = TileShape
                    clip = share > 0f
                }
                .drawWithContent {
                    if (!media.heroMode || pair?.liveOutgoing != true || env.stillTakesOver() || env.gesturePair != null) {
                        drawRect(Color.Black.copy(alpha = 0.18f))
                        drawContent()
                    }
                },
            contentAlignment = Alignment.Center,
        ) {
            if (!media.coverLoaded() && (!media.canvasRendered || env.gesturePair != null)) {
                Icon(
                    imageVector = VibraMusicIcons.MusicNote,
                    contentDescription = null,
                    tint = Color.White.copy(alpha = 0.35f),
                    modifier = Modifier
                        .size(40.dp)
                        .graphicsLayer {
                            val scale = 1f - 0.5f * collapse.p()
                            scaleX = scale
                            scaleY = scale
                        },
                )
            }
        }
        if (env.gesturePair != null) {
            AutoMixGestureCover(media.art, media.autoMixFrames, env.gesturePair) {
                env.gesturePair.gestureOutgoing?.image ?: env.still()?.takeIf { CanvasStills.fresh }?.image
            }
        } else if (media.heroIncomingStill != null && pair != null) {
            AutoMixIncomingStill(
                media.heroIncomingStill,
                pair::reveal,
                pair.generation,
                polish = !env.stillMoving,
            )
        } else {
            AutoMixPlayerCover(
                art = media.art,
                frames = media.autoMixFrames.baseUnderCanvas(pair),
                modifier = Modifier
                    .fillMaxSize()
                    .drawWithContent {
                        if (media.heroMode && pair?.liveOutgoing == true && !env.stillTakesOver()) return@drawWithContent
                        if (media.staticCanvasMix) {
                            drawContent()
                            return@drawWithContent
                        }
                        val frame = env.still()
                        if (frame == null) {
                            if (media.coverLoaded() || !media.canvasRendered) drawContent()
                        } else if (
                            env.stillTakesOver() || !media.canvasRendered ||
                            (media.heroMode && media.canvasCover.floatValue < 1f)
                        ) {
                            if (media.canvas?.source == CanvasSource.APPLE && env.stillTakesOver() && media.coverLoaded()) {
                                drawContent()
                                drawCropped(frame.image, alpha = env.clipTransitionAlpha())
                            } else {
                                drawCropped(frame.image)
                            }
                        }
                    },
            )
        }

        if (!media.heroMode) {
            WhileShown({ !collapse.collapsePastHalf || (env.gestureArtwork && !collapse.collapseDone && pair?.incomingClip != null) }) {
                CanvasPresentationHost(
                    media.canvas.takeUnless { collapse.collapsePastHalf },
                    pair?.incomingClip.takeUnless { media.incomingFullWindow },
                ) { clip, standby ->
                    val stillStart = remember(clip.url) { if (standby) null else env.stillAtMount() }
                    CanvasArtworkPlayer(
                        canvas = clip,
                        isPlaying = env.params.track.isPlaying,
                        pausedForTransition = panels.lyricsOpen || panels.queueOpen || panels.queueDragging ||
                            collapse.collapseStarted || env.dockMoving || interaction.overlayOpen.value ||
                            (standby && pair?.started != true) || (!standby && media.freezeOutgoingCanvas),
                        presentationAlpha = {
                            if (env.gesturePair != null || env.stillTakesOver()) 0f
                            else if (standby) 1f
                            else if (media.staticCanvasMix) {
                                if (clip.url == media.retiringCanvas?.url) media.retiringCanvasAlpha() else 0f
                            } else if (media.incomingFullWindow && pair != null) 1f - pair.standbyOpacity()
                            else if (clip.source == CanvasSource.APPLE && media.coverLoaded()) env.clipTransitionAlpha()
                            else 1f
                        },
                        startPositionMs = stillStart?.positionMs ?: 0L,
                        revealInstantly = standby || stillStart != null,
                        captureStill = if (standby) env.captureStandby(clip) else !media.staticCanvasMix && env.stillMoving,
                        onStillCaptured = { image, position ->
                            if (standby) env.retainGestureStill(clip, true, image, position)
                            else env.onStillCaptured(image, position)
                        },
                        onResumed = { if (standby) pair?.gestureIncoming = null else env.onClipResumed() },
                        onRenderedChanged = {
                            if (standby) pair?.reportIncoming(it) else {
                                media.canvasSurfaceRendered = it
                                pair?.reportOutgoing(it)
                            }
                        },
                        nowPlaying = true,
                        organicReveal = if (standby) pair?.standbyReveal(!env.stillMoving) else null,
                        frameCapturePx = if (!standby && media.canvasOwnsAmbient && media.tintsOffClip && !env.tabletArtworkBackdrop) {
                            CANVAS_FRAME_CAPTURE_PX
                        } else 0,
                        onFrameCaptured = {
                            if (!standby && media.canvasOwnsAmbient && !env.tabletArtworkBackdrop && !panels.lyricsOpen && !panels.queueOpen) {
                                media.canvasFrame = it
                            }
                        },
                        refreshFrameEveryMs = if (
                            standby || !media.canvasOwnsAmbient || env.tabletArtworkBackdrop ||
                            panels.lyricsOpen || panels.queueOpen || env.dockMoving
                        ) null else media.meshRefreshMs,
                        modifier = Modifier.fillMaxSize(),
                    )
                }
                val incoming = media.autoMixFrames?.incoming
                if (env.gesturePair == null && incoming != null && pair?.liveOutgoing == true && !pair.liveIncoming) {
                    AutoMixIncomingStill(incoming, pair::reveal, pair.generation)
                }
            }
        }
    }
}

@Composable
internal fun NowPlayingStagePortraitCardSlot(
    env: NowPlayingEnv,
    geo: PortraitSleeveGeometry,
) {
    val panels = env.panels
    val collapse = env.collapse
    val media = env.media
    val track = env.params.track

    Box(
        modifier = Modifier
            .offset { IntOffset(geo.artStart().roundToPx(), geo.artTop().roundToPx()) }
            .layout { measurable, constraints ->
                val side = geo.artSize().roundToPx()
                val placeable = measurable.measure(
                    constraints.constrain(Constraints.fixed(side, side)),
                )
                layout(placeable.width, placeable.height) { placeable.placeRelative(0, 0) }
            }
            .onGloballyPositioned { panels.dismissBandTop = it.boundsInRoot().top }
            .graphicsLayer {
                val idle = geo.cardScale()
                scaleX = idle
                scaleY = idle
                translationX = env.interaction.swipeSettle.value * (1f - collapse.p())
            }
            .then(
                if (panels.queueOpen || panels.lyricsOpen) {
                    Modifier.clickable {
                        panels.queueOpen = false
                        panels.closeLyrics()
                    }
                } else {
                    Modifier
                },
            ),
        contentAlignment = Alignment.Center,
    ) {
        WhileShown({ !collapse.collapsePastHalf }) {
            SleeveNerdStats(
                song = track.song,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(horizontal = 10.dp, vertical = 8.dp)
                    .graphicsLayer {
                        alpha = (1f - collapse.p() * 2f) * media.spotifyChromeAlpha
                        translationY = BANNER_FOOT_DROP.toPx() * if (media.spotifyCanvasPresentation) {
                            1f - collapse.p()
                        } else {
                            geo.bannerShown()
                        }
                    },
                bestPart = {
                    BestPartPill(
                        track.song,
                        track.position,
                        env.sheets.playerHaze,
                        env.params.transport.onSeek,
                        overlayOpen = { env.interaction.overlayOpen.value },
                    )
                },
            )
        }
    }
}

@Composable
internal fun NowPlayingStagePortraitVideoCard(
    env: NowPlayingEnv,
    geo: PortraitSleeveGeometry,
) {
    val media = env.media
    val collapse = env.collapse
    WhileShown({ !collapse.collapsePastHalf && !env.docking() }) {
        val videoAspect by PlayerPlatform.host.musicVideoAspect.collectAsStateWithLifecycle()
        val aspect = videoAspect.coerceIn(1f, 2.4f)
        Box(
            modifier = Modifier
                .offset {
                    if (media.squareVideo) {
                        val side = geo.artSize().roundToPx()
                        return@offset IntOffset(
                            geo.fromStart(geo.artStart().roundToPx().toFloat(), side.toFloat()).roundToInt(),
                            geo.artTop().roundToPx(),
                        )
                    }
                    val height = (geo.boxWidthPx / aspect).roundToInt()
                    val centre = (geo.artTop() + geo.artSize() / 2).roundToPx()
                    IntOffset(0, centre - height / 2)
                }
                .layout { measurable, _ ->
                    val width = if (media.squareVideo) geo.artSize().roundToPx() else geo.boxWidthPx
                    val height = if (media.squareVideo) width else (geo.boxWidthPx / aspect).roundToInt()
                    val placeable = measurable.measure(Constraints.fixed(width, height))
                    layout(width, height) { placeable.placeRelative(0, 0) }
                }
                .graphicsLayer {
                    alpha = (1f - collapse.p() * 2f).coerceIn(0f, 1f)
                    translationX = env.interaction.swipeSettle.value * (1f - collapse.p())
                },
        ) {
            if (!media.videoRendered) {
                VideoLoadingBackdrop(
                    Modifier
                        .fillMaxSize()
                        .clip(RoundedCornerShape(10.dp)),
                )
            }
            MusicVideoSurface(
                videoId = env.params.track.song.videoId,
                fit = !media.squareVideo,
                onRenderedChanged = { media.videoRendered = it },
                modifier = Modifier
                    .fillMaxSize()
                    .clip(RoundedCornerShape(10.dp)),
            )
            VideoCornerControls(
                fullscreen = false,
                onToggleFullscreen = media.enterFullscreen,
                onOpenQuality = { env.sheets.showVideoQuality = true },
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(8.dp),
            )
        }
    }
}
