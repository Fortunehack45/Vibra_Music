package com.fortune.vibramusic.ui.player

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.AnimationVector1D
import androidx.compose.runtime.Composable
import androidx.compose.runtime.MutableFloatState
import androidx.compose.runtime.MutableIntState
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.State
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.geometry.lerp
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.layer.GraphicsLayer
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.lerp
import com.fortune.vibramusic.data.canvas.CanvasArtwork
import com.fortune.vibramusic.data.lyrics.LyricLine
import com.fortune.vibramusic.data.lyrics.LyricsSource
import com.fortune.vibramusic.data.model.LikeStatus
import com.fortune.vibramusic.data.model.QueueEntryIdentity
import com.fortune.vibramusic.data.model.Song
import com.fortune.vibramusic.data.settings.LastPlayerScreen
import com.fortune.vibramusic.data.settings.PlayerTheme
import com.fortune.vibramusic.playback.PlaybackPosition
import com.fortune.vibramusic.ui.LyricsProviderState
import com.fortune.vibramusic.ui.haptics.Haptics
import dev.chrisbanes.haze.HazeState
import kotlin.math.roundToInt

internal class NowPlayingTrackParams(
    val song: Song,
    val playedBy: String?,
    val isPlaying: Boolean,
    val isLoading: Boolean,
    val position: PlaybackPosition,
    val durationMs: Long,
    val audioVersionSwitching: Boolean,
    val qualityUpgraded: Boolean,
    val queue: List<Song>,
    val queueIndex: Int,
    val hasPrevious: Boolean,
    val hasNext: Boolean,
    val repeatMode: Int,
    val shuffleEnabled: Boolean,
    val autoplayEnabled: Boolean,
    val signedIn: Boolean,
    val accountName: String?,
    val likeStatus: LikeStatus,
)

internal class NowPlayingTransportParams(
    val onToggleLike: () -> Unit,
    val onPlayPause: () -> Unit,
    val onNext: () -> Unit,
    val onPrevious: () -> Unit,
    val previousRestarts: () -> Boolean,
    val currentPlaybackSong: () -> Song?,
    val onBlockedControl: () -> Unit,
    val onSeek: (Long) -> Unit,
    val onSeekFraction: (Float) -> Unit,
    val onToggleShuffle: () -> Unit,
    val onCycleRepeat: () -> Unit,
    val onToggleAutoplay: () -> Unit,
    val onJumpTo: (Int) -> Unit,
    val onRemoveFromQueue: (Int) -> Unit,
    val onMoveInQueue: (Int, Int) -> Unit,
    val onQueueDragActiveChange: (Boolean) -> Unit,
    val onClearQueue: () -> Unit,
    val onQueueSongMenu: (Int, Song) -> Unit,
    val onQueueSwipeToQueue: suspend (Int, Song) -> Boolean,
    val queueUndoNotice: @Composable (HazeState) -> Unit,
    val onQueueBulkAction: suspend (List<Song>, QueueBulkAction) -> Boolean,
    val onQueueRemoveEntries: suspend (List<QueueEntryIdentity>) -> Unit,
    val onQueueAddAllToPlaylist: (List<Song>) -> Unit,
)

internal class NowPlayingWindowParams(
    val onOpenMenu: () -> Unit,
    val onOpenAlbum: (String) -> Unit,
    val onOpenArtist: (browseId: String?, name: String) -> Unit,
    val onOpenPlaybackSource: () -> Unit,
    val onListenTogether: () -> Unit,
    val lyrics: List<LyricLine>?,
    val lyricsSource: LyricsSource?,
    val lyricsProviderStates: Map<LyricsSource, LyricsProviderState>,
    val onSelectLyricsProvider: (LyricsSource) -> Unit,
    val lyricsUnavailable: Boolean,
    val lyricsOffsetOpen: Boolean,
    val onDismissLyricsOffset: () -> Unit,
    val windowWidth: Dp,
    val windowHeight: Dp,
    val menuOpen: () -> Boolean,
    val onLiveCanvasChanged: (Boolean) -> Unit,
)

internal class NowPlayingParams(
    val track: NowPlayingTrackParams,
    val transport: NowPlayingTransportParams,
    val window: NowPlayingWindowParams,
)

internal class PlayerSheetsState {
    val playerHaze = HazeState()
    val queueHaze = HazeState()
    var showAudioPipeline by mutableStateOf(false)
    var showCast by mutableStateOf(false)
    var showAudioOutput by mutableStateOf(false)
    var showVideoQuality by mutableStateOf(false)
    var showLyricsProviders by mutableStateOf(false)
    var showListenTogetherMembers by mutableStateOf(false)
    var lyricsShare by mutableStateOf<LyricsShareRequest?>(null)
    val openListenTogetherMembers: () -> Unit = { showListenTogetherMembers = true }
}

internal class PlayerPanelsState(restoredPlayerScreen: LastPlayerScreen) {
    var queueOpen by mutableStateOf(restoredPlayerScreen == LastPlayerScreen.QUEUE)
    val queueSelection = QueueSelectionState()
    var lyricsOpen by mutableStateOf(restoredPlayerScreen == LastPlayerScreen.LYRICS)
    val queueSlide = mutableFloatStateOf(0f)
    var lyricsScrolling by mutableStateOf(false)
    var queueScrolling by mutableStateOf(false)
    val panelScrolling: Boolean get() = lyricsScrolling || queueScrolling
    var lyricsControlsOpen by mutableStateOf(restoredPlayerScreen == LastPlayerScreen.LYRICS)
    var queueControlsOpen by mutableStateOf(true)
    var queuePaneMounted by mutableStateOf(false)
    val playerDeckReveal = Animatable(1f)
    val playerDeckSettledOpen by derivedStateOf { playerDeckReveal.value >= 0.999f }
    var queueDragging by mutableStateOf(false)
    var queueReleased by mutableIntStateOf(0)
    var heroSettled by mutableStateOf(lastHeroSettled)
    var heroHeight by mutableStateOf(0.dp)
    var playerBounds by mutableStateOf(IntSize.Zero)
    var expandedSquare by mutableStateOf(Rect.Zero)
    var dismissBandTop by mutableFloatStateOf(0f)
    var dismissBandBottom by mutableFloatStateOf(0f)
    var dismissBandSpace by mutableStateOf<LayoutCoordinates?>(null)
    var controlSpread by mutableStateOf(lastControlSpread)
    var fullscreenRequested by mutableStateOf(false)

    val openLyrics: () -> Unit = {
        lyricsControlsOpen = true
        lyricsOpen = true
        queueOpen = false
    }
    val closeLyrics: () -> Unit = {
        lyricsControlsOpen = false
        lyricsOpen = false
    }
    val toggleLyrics: () -> Unit = {
        if (lyricsOpen) closeLyrics() else openLyrics()
    }
    val toggleQueue: () -> Unit = {
        val opening = !queueOpen
        if (opening && lyricsOpen) queueSlide.floatValue = 1f
        if (opening) queueControlsOpen = true
        queueOpen = opening
        if (opening) closeLyrics()
    }
}

internal class PlayerCollapseState(
    panels: PlayerPanelsState,
    animatedCollapse: State<Float>,
) {
    val p: () -> Float = {
        val queueOwnsCollapse = !panels.lyricsOpen &&
            (panels.queueOpen || panels.queueDragging || panels.queueSlide.floatValue > 0.001f)
        if (queueOwnsCollapse) panels.queueSlide.floatValue else animatedCollapse.value
    }
    val collapseStarted by derivedStateOf { p() > 0f }
    val collapseAtRest by derivedStateOf { p() == 0f }
    val collapsePastSettling by derivedStateOf { p() >= 0.01f }
    val collapsePastHalf by derivedStateOf { p() >= 0.5f }
    val collapseAlmostDone by derivedStateOf { p() >= 0.999f }
    val collapseDone by derivedStateOf { p() >= 1f }
    val queueShowing by derivedStateOf { panels.queueSlide.floatValue > 0.01f }
    val queueArtworkMoving by derivedStateOf { panels.queueSlide.floatValue > 0f }
    val panelFade = Animatable(if (Snapshot.withoutReadObservation { collapseDone }) 1f else 0f)
}

internal class NowPlayingMediaState(
    val density: Density,
    val remoteArt: String?,
    val artworkStatusScrimAlpha: Float,
    val mixing: Boolean,
    val videoMode: Boolean,
    val squareVideo: Boolean,
    val fullCanvasWindow: Boolean,
    val fullBleedArt: Boolean,
    val coverEntry: QueueEntryIdentity?,
    videoRenderedState: MutableState<Boolean>,
    val videoAspectState: State<Float>,
    val sideways: Boolean,
    val artworkGate: AutoMixArtworkGate,
    val canvasPair: AutoMixCanvasPair,
    val pair: AutoMixCanvasTracks?,
    val promotedCanvas: AutoMixCanvasTracks?,
    val retiringCanvas: CanvasArtwork?,
    val canvasRetire: Animatable<Float, AnimationVector1D>,
    val canvasRetiring: Boolean,
    val retiringCanvasAlpha: () -> Float,
    val canvas: CanvasArtwork?,
    val staticCanvasMix: Boolean,
    val freezeOutgoingCanvas: Boolean,
    val incomingFullWindow: Boolean,
    val fullscreenInPlace: Boolean,
    val videoFullscreen: Boolean,
    val enterFullscreen: () -> Unit,
    val exitFullscreen: () -> Unit,
    canvasAspectState: MutableFloatState,
    val canvasRenderedState: MutableState<Boolean>,
    val canvasRendered: Boolean,
    canvasFrameState: MutableState<ImageBitmap?>,
    val canvasOwnsAmbient: Boolean,
    val ambientCanvasKey: Any?,
    spotifyCanvasControlsOpenState: MutableState<Boolean>,
    spotifyCanvasDeckHeightState: MutableState<Dp>,
    spotifyCanvasExpandedTopHeightState: MutableState<Dp>,
    val canvasCover: MutableFloatState,
    val playerTheme: PlayerTheme,
    val tintsOffClip: Boolean,
    val meshRefreshMs: Long?,
    val spotifyCanvasOnPhone: Boolean,
    val heroMode: Boolean,
    val art: PlayerArtwork,
    val autoMixFrames: AutoMixCoverFrames?,
    val heroIncomingStill: DecodedAutoMixCover?,
    val heroClip: CanvasArtwork?,
    val spotifyCanvasPresentation: Boolean,
    val heroClipMounted: CanvasArtwork?,
    val clipFullscreen: Boolean,
    val clipPortrait: Boolean,
    val heroT: State<Float>,
    spotifyChromeAlphaState: State<Float>,
    val clipBottom: Dp,
    val statusBarTop: Dp,
    val topStrip: Dp,
) {
    var videoRendered by videoRenderedState
    var canvasAspect by canvasAspectState
    var canvasSurfaceRendered by canvasRenderedState
    var canvasFrame by canvasFrameState
    var spotifyCanvasControlsOpen by spotifyCanvasControlsOpenState
    var spotifyCanvasDeckHeight by spotifyCanvasDeckHeightState
    var spotifyCanvasExpandedTopHeight by spotifyCanvasExpandedTopHeightState
    val spotifyChromeAlpha by spotifyChromeAlphaState

    fun coverLoaded(): Boolean = autoMixFrames != null || art.loaded

    fun canvasBottom(aspect: Float, playerBounds: IntSize): Dp =
        if (aspect > 0f && aspect < 1f && playerBounds.width > 0 && playerBounds.height > 0) {
            val viewAspect = playerBounds.width.toFloat() / playerBounds.height
            val videoHeight = if (aspect >= viewAspect) playerBounds.width / aspect
            else playerBounds.height.toFloat()
            with(density) { videoHeight.toDp() }
        } else 0.dp

    fun clipFadeFraction(bottom: Dp, heroHeight: Dp): Float = if (bottom > 0.dp) {
        (heroHeight.value * HERO_FADE_FRACTION / bottom.value).coerceIn(0f, 1f)
    } else 0f
}

internal class NowPlayingInteractionState(
    val haptics: Haptics,
    val openAudioOutput: () -> Unit,
    val controlsLocked: Boolean,
    val syncedLyricsEnabled: Boolean,
    val hideLyricsPreview: Boolean,
    val lyricsPlayhead: LyricPlayhead,
    val seekToLyric: (Long) -> Unit,
    val hideVolumeBar: Boolean,
    val disableBlendEffects: Boolean,
    val lyricSlotHeight: Dp,
    val hideSongStatus: Boolean,
    val scrub: PlayerScrub,
    val volume: PlayerVolume,
    val shown: () -> Float,
    pastRestartPointState: State<Boolean>,
    playerPrewarmStageState: MutableIntState,
    val lyricsLoadingText: String,
    val lyricsTranslation: LyricsTranslationUi,
    val backdropLayer: GraphicsLayer,
    val currentMenuOpen: State<() -> Boolean>,
    val overlayOpen: State<Boolean>,
    val lyricsShareEnabled: Boolean,
    val lyricPicker: LyricsPicker,
    showRevertCueState: MutableState<Boolean>,
    val infoTransition: SongInfoTransition,
    val swipeSettle: Animatable<Float, AnimationVector1D>,
    artScaleState: State<Float>,
    val openPlaybackOrigin: () -> Unit,
    val skipSwipeGesture: Modifier,
    val onScrub: (Float) -> Unit,
    val onScrubFinished: () -> Unit,
    val onVolumeChange: (Float) -> Unit,
    val onVolumeChangeFinished: () -> Unit,
) {
    val pastRestartPoint by pastRestartPointState
    var playerPrewarmStage by playerPrewarmStageState
    var showRevertCue by showRevertCueState
    val artScale by artScaleState
}

internal class NowPlayingEnv(
    val params: NowPlayingParams,
    val sheets: PlayerSheetsState,
    val panels: PlayerPanelsState,
    val collapse: PlayerCollapseState,
    val media: NowPlayingMediaState,
    val interaction: NowPlayingInteractionState,
    val landscape: Boolean,
    val tabletArtworkBackdrop: Boolean,
    val ambient: AutoMixAmbient,
    val blurAvailable: Boolean,
    val fullArtworkBlurContent: @Composable (Modifier) -> Unit,
    val dock: PlayerDock?,
    val dockFrame: DockFrame,
    val dockT: () -> Float,
    val docking: () -> Boolean,
    dockMovingState: State<Boolean>,
    val dockFade: () -> Float,
    val clipTransitionAlpha: () -> Float,
    val stillUrl: String?,
    val stillMoving: Boolean,
    val gestureArtwork: Boolean,
    val gesturePair: AutoMixCanvasTracks?,
    val staticHeroUnderlay: DecodedAutoMixCover?,
    val onStillCaptured: (ImageBitmap?, Long) -> Unit,
    val onClipResumed: () -> Unit,
    val sleeveLayer: GraphicsLayer,
    val dockHost: Modifier,
    val frostOff: Boolean,
    val frost: PlayerFrost?,
    val playerActions: @Composable () -> Unit,
) {
    val dockMoving by dockMovingState

    fun still(): CanvasStill? = CanvasStills.current?.takeIf { it.url == stillUrl }

    fun captureStandby(clip: CanvasArtwork): Boolean {
        val tracks = media.pair ?: return false
        return gestureArtwork && !collapse.collapseDone && tracks.incomingClip?.url == clip.url &&
            tracks.incomingReady && tracks.gestureIncoming == null
    }

    fun retainGestureStill(clip: CanvasArtwork, standby: Boolean, image: ImageBitmap?, position: Long) {
        val tracks = media.pair ?: return
        if (image == null || media.canvasPair.visual !== tracks) return
        val still = CanvasStill(clip.url, image, position)
        if (standby) {
            if (tracks.incomingClip?.url == clip.url && tracks.incomingReady) tracks.gestureIncoming = still
        } else if (tracks.pinnedClip?.url == clip.url) {
            tracks.gestureOutgoing = still
        }
    }

    fun stillTakesOver(): Boolean = still() != null && CanvasStills.fresh &&
        (collapse.collapseStarted || dockMoving || panels.lyricsOpen || panels.queueOpen || panels.queueDragging || !media.canvasRendered)

    fun stillBottomPx(): Float {
        val image = still()?.image ?: return 0f
        if (!media.heroMode || image.width >= image.height || panels.playerBounds.width <= 0) return 0f
        return minOf(
            panels.playerBounds.width * image.height / image.width.toFloat(),
            panels.playerBounds.height.toFloat(),
        )
    }

    fun sleeveStillBottomPx(): Float =
        if (media.heroIncomingStill != null || gesturePair != null) 0f else stillBottomPx()

    fun stillFadeFraction(): Float {
        val bottom = sleeveStillBottomPx()
        if (bottom <= 0f) return HERO_FADE_FRACTION
        return (with(media.density) { panels.heroHeight.toPx() } * HERO_FADE_FRACTION / bottom).coerceIn(0f, 1f)
    }

    fun stillAtMount(): CanvasStill? = Snapshot.withoutReadObservation { still() }
}

internal class PortraitSleeveGeometry(
    val env: NowPlayingEnv,
    val rtl: Boolean,
    val maxWidth: Dp,
    val fullArt: Dp,
    val groupTop: Dp,
    val spotifyTitleRange: Dp?,
    val thumbWidth: Dp,
    val bannerTopPx: Int,
    val boxWidthPx: Int,
    val boxLeftPx: Int,
) {
    private val p: () -> Float get() = env.collapse.p

    fun artSize(): Dp = lerp(fullArt, THUMB_SIZE, p())
    fun artTop(): Dp = lerp(groupTop, 0.dp, p())
    fun artStart(): Dp = lerp((maxWidth - fullArt) / 2, 0.dp, p())
    fun regularTitleTop(): Dp = lerp(groupTop + fullArt + ART_TITLE_GAP, 0.dp, p())

    fun currentTitleTop(): Dp = spotifyTitleRange?.let { collapsedTitleTop ->
        lerp(collapsedTitleTop, regularTitleTop(), env.panels.playerDeckReveal.value)
    } ?: regularTitleTop()

    fun titleStart(): Dp = lerp(0.dp, thumbWidth + 12.dp, p())

    fun fromStart(start: Float, width: Float): Float =
        if (rtl) boxWidthPx - start - width else start

    fun bannerShare(): Float = if (env.panels.heroHeight > 0.dp && env.panels.playerBounds.width > 0) {
        autoMixStaticSleeveShare(
            env.media.fullBleedArt,
            env.media.heroT.value,
            env.media.heroIncomingStill != null,
        )
    } else 0f

    fun bannerShown(): Float = bannerShare() * (1f - p())

    fun cardScale(): Float =
        if (env.media.videoMode) 1f else env.interaction.artScale + (1f - env.interaction.artScale) * p()

    fun cardRect(): Rect = with(env.media.density) {
        val side = artSize().roundToPx().toFloat()
        val square = Rect(
            offset = Offset(
                fromStart(artStart().roundToPx().toFloat(), side),
                artTop().roundToPx().toFloat(),
            ),
            size = Size(side, side),
        )
        if (!env.media.videoMode || env.media.squareVideo) return@with square
        val height = boxWidthPx / env.media.videoAspectState.value.coerceIn(1f, 2.4f)
        val video = Rect(
            offset = Offset(0f, square.center.y - height / 2f),
            size = Size(boxWidthPx.toFloat(), height),
        )
        val thumbW = thumbWidth.roundToPx().toFloat()
        val thumbH = THUMB_SIZE.roundToPx().toFloat()
        val thumb = Rect(Offset(fromStart(0f, thumbW), 0f), Size(thumbW, thumbH))
        lerp(video, thumb, p())
    }

    fun sleeveRect(): Rect {
        val card = cardRect()
        val share = bannerShare()
        if (share == 0f) return card
        val banner = with(env.media.density) {
            Rect(
                offset = Offset(-(env.panels.playerBounds.width - boxWidthPx) / 2f, bannerTopPx.toFloat()),
                size = Size(
                    env.panels.playerBounds.width.toFloat(),
                    env.sleeveStillBottomPx().takeIf { it > 0f } ?: env.panels.heroHeight.roundToPx().toFloat(),
                ),
            )
        }
        val thumbSide = with(env.media.density) { THUMB_SIZE.roundToPx().toFloat() }
        val thumb = Rect(Offset(fromStart(0f, thumbSide), 0f), Size(thumbSide, thumbSide))
        return lerp(card, lerp(banner, thumb, p()), share)
    }

    fun miniInBox(): Rect? {
        val dock = env.dock ?: return null
        if (!env.docking()) return null
        val mini = dock.miniArtOnScreen() ?: return null
        val anchor = env.dockFrame.anchor ?: return null
        val offset = dock.offset() ?: return null
        env.dockFrame.offset = offset.toInt().toFloat()
        return mini.translate(
            -(anchor.x + boxLeftPx),
            -(anchor.y + env.dockFrame.offset - bannerTopPx),
        )
    }

    fun dockRide(sleeve: Rect, mini: Rect): Float {
        val travel = env.dock?.sheetTravel ?: return 0f
        if (travel <= 0f) return 0f
        return ((mini.top + env.dockFrame.offset - sleeve.top) / travel).coerceIn(0f, 1f)
    }

    fun towardsDock(rect: Rect, mini: Rect?): Rect {
        if (mini == null) return rect
        val unridden = env.dockFrame.offset * (1f - env.dockFrame.ride)
        return lerp(mini, rect.translate(0f, -unridden), env.dockT())
    }

    fun sleeveShown(): Float = bannerShown() * env.dockT()

    fun sleeveCorner(): Dp {
        val corner = 8.dp * (1f - sleeveShown())
        val t = env.dockT()
        val dock = env.dock
        return if (dock == null || t >= 1f) corner else lerp(dock.miniArtCorner(), corner, t)
    }
}
