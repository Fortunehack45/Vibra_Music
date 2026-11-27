package com.fortune.vibramusic.ui.player

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.AnimationVector1D
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.VectorConverter
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.gestures.awaitVerticalTouchSlopOrCancellation
import androidx.compose.foundation.gestures.verticalDrag
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableFloatState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.layer.GraphicsLayer
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.input.pointer.AwaitPointerEventScope
import androidx.compose.ui.input.pointer.PointerInputChange
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.input.pointer.util.addPointerInputChange
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.layout
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.fortune.vibramusic.data.lyrics.LyricLine
import com.fortune.vibramusic.data.lyrics.LyricsSource
import com.fortune.vibramusic.data.model.LikeStatus
import com.fortune.vibramusic.data.model.PLAYER_ART_PX
import com.fortune.vibramusic.data.model.QueueEntryIdentity
import com.fortune.vibramusic.data.model.Song
import com.fortune.vibramusic.data.settings.PlayerTheme
import com.fortune.vibramusic.playback.PlaybackPosition
import com.fortune.vibramusic.ui.LyricsProviderState
import com.fortune.vibramusic.ui.graphics.FADE_CURVE_STOPS
import com.fortune.vibramusic.ui.graphics.smootherStep
import com.fortune.vibramusic.ui.theme.HideStatusBar
import com.fortune.vibramusic.ui.theme.StatusBarIcons
import dev.chrisbanes.haze.ExperimentalHazeApi
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.materials.ExperimentalHazeMaterialsApi
import kotlinx.coroutines.flow.collectLatest
import kotlin.math.roundToInt

internal const val ART_PX = PLAYER_ART_PX
internal const val ART_RETRIES = 3
internal const val ART_RETRY_DELAY_MS = 1_500L
internal const val ALBUM_SETTLE_MS = 700L
internal const val REVERT_CUE_MS = 2_600L
internal const val SEEK_SETTLE_TOLERANCE_MS = 1_500L
internal const val SEEK_SETTLE_TIMEOUT_MS = 4_000L

internal val THUMB_SIZE = 54.dp
internal val HEADER_HEIGHT = 60.dp
internal val ART_TITLE_GAP = 20.dp
internal val BANNER_FOOT_DROP = 26.dp
internal const val QUEUE_TRAVEL_MS = 420
internal const val QUEUE_CARRY_FRACTION = 0.3f
internal const val QUEUE_FLICK_VELOCITY = 450f
internal val DISMISS_STRIP_HEIGHT = 32.dp
internal val ART_BOX_TOP_PAD = 8.dp
internal val VERSION_PILL_ART_INSET = 12.dp
internal const val HERO_FADE_FRACTION = 0.42f
internal const val SUBVIEW_STATUS_SCRIM_MIN_ALPHA = 0.40f
internal const val MESH_REFRESH_MS = 3_000L
internal const val MESH_SEAM_MOVE_MS = 320
internal const val PORTRAIT_SCRIM_MAX_ASPECT = 0.7f

internal val PortraitClipScrim = Brush.verticalGradient(
    0f to Color.Transparent,
    0.40f to Color.Transparent,
    1f to Color.Black.copy(alpha = 0.70f),
)

@Composable
internal fun PlayerMeshBackdrop(
    trackKey: String,
    imageUrl: String?,
    canvasFrame: () -> ImageBitmap?,
    canvasKey: Any?,
    seamTarget: () -> Dp,
    alpha: () -> Float,
    modifier: Modifier = Modifier,
    ambient: AutoMixAmbient,
    entry: QueueEntryIdentity?,
) {
    val seed = ambient.incoming?.mesh
    val snapKey = rememberAmbientSnapKey(ambient.snapKey(seed != null))
    val mix = ambient.mixFor(seed != null)
    val url = imageUrl ?: ambient.incoming?.resolvedUrl
    val frame = canvasFrame()
    val mesh = key(entry ?: trackKey, snapKey) { rememberArtworkMesh(url, frame, ART_PX, seed, canvasKey) }
    val currentSeamTarget by rememberUpdatedState(seamTarget)
    val seam = remember { Animatable(Snapshot.withoutReadObservation { seamTarget() }, Dp.VectorConverter) }
    LaunchedEffect(seam) {
        snapshotFlow { currentSeamTarget() }.collectLatest { target ->
            if (seam.value == 0.dp || target == 0.dp) {
                seam.snapTo(target)
            } else {
                seam.animateTo(target, tween(MESH_SEAM_MOVE_MS, easing = FastOutSlowInEasing))
            }
        }
    }
    key(snapKey) {
        ArtworkMeshBackdrop(
            mesh = mesh,
            seam = { seam.value },
            modifier = modifier.graphicsLayer { this.alpha = alpha() },
            mix = mix,
            currentIsOutgoing = entry == mix?.outgoing,
            directSelection = ambient.direct,
            directStill = ambient.direct != null && frame == null,
        )
    }
}

@Composable
internal fun LegacyMeshBackdrop(
    imageUrl: String?,
    canvasFrame: () -> ImageBitmap?,
    canvasKey: Any?,
    trackKey: String,
    modifier: Modifier,
    ambient: AutoMixAmbient,
    entry: QueueEntryIdentity?,
) {
    val url = imageUrl ?: ambient.incoming?.resolvedUrl
    val settled = ambient.incoming?.palette
    val requestedSnap = ambient.snapKey(settled != null)
    val snapKey = rememberAmbientSnapKey(requestedSnap)
    val seed = settled ?: cachedArtworkPalette(url).takeIf { ambient.cancelled || ambient.direct != null }
    val frame = canvasFrame()
    val palette = key(snapKey) { rememberArtworkColors(url, frame, seed, canvasKey) }
    val mix = ambient.mixFor(settled != null)
    MeshGradientBackground(
        palette = palette,
        trackKey = trackKey,
        modifier = modifier,
        mix = mix,
        snapKey = snapKey,
        settled = requestedSnap != null,
        currentIsOutgoing = entry == mix?.outgoing,
        directStill = ambient.direct != null && frame == null,
    )
}

internal const val SPOTIFY_CANVAS_RESUME_DELAY_MS = 1_000L
internal const val AUTOMIX_CANVAS_RETIRE_MS = 700

internal fun Modifier.recordBackdrop(layer: GraphicsLayer): Modifier = drawWithContent {
    layer.record { this@drawWithContent.drawContent() }
    drawLayer(layer)
}

internal fun DrawScope.drawCropped(image: ImageBitmap, alpha: Float = 1f) {
    if (size.width <= 0f || size.height <= 0f) return
    val scale = maxOf(size.width / image.width, size.height / image.height)
    val srcWidth = (size.width / scale).roundToInt().coerceIn(1, image.width)
    val srcHeight = (size.height / scale).roundToInt().coerceIn(1, image.height)
    drawImage(
        image = image,
        srcOffset = IntOffset((image.width - srcWidth) / 2, (image.height - srcHeight) / 2),
        srcSize = IntSize(srcWidth, srcHeight),
        dstSize = IntSize(size.width.roundToInt(), size.height.roundToInt()),
        alpha = alpha,
    )
}

@Immutable
internal class CanvasStill(val url: String, val image: ImageBitmap, val positionMs: Long)

internal object CanvasStills {
    var current by mutableStateOf<CanvasStill?>(null)
    var fresh by mutableStateOf(false)
}

internal val PLAYER_GUTTER = 30.dp
internal val PLAYER_MAX_WIDTH = 560.dp
private val TABLET_PLAYER_MIN_WIDTH = 700.dp
private val LANDSCAPE_PLAYER_MIN_WIDTH = 560.dp

internal const val ARTWORK_EXPANDED_SCALE = 1f
internal const val ARTWORK_PAUSE_SHRINK_SCALE = 0.88f
internal const val ARTWORK_DRAG_SHRINK_SCALE = 0.94f
internal val ArtworkScaleEasing = CubicBezierEasing(0.215f, 0.61f, 0.355f, 1f)
internal const val ARTWORK_SCALE_DURATION_MS = 500

internal val CONTROL_GAP_SPREAD_MAX = 24.dp
internal var lastControlSpread: Dp = 0.dp
internal var lastHeroSettled = false
internal const val DOCK_FADE_LEAD = 0.15f
internal const val DOCK_FADE_FLOOR = 1f / 255f

internal class DockFrame {
    var anchor: Offset? by mutableStateOf(null)
    var anchorFor = IntSize.Zero
    var miniInBox: Rect? = null
    var offset = 0f
    var ride = 0f
    var sleeve: Rect = Rect.Zero

    private var cornerRadius = Dp.Unspecified
    private var corner: Shape = RectangleShape
    fun cornerShape(radius: Dp): Shape {
        if (radius != cornerRadius) {
            cornerRadius = radius
            corner = RoundedCornerShape(radius)
        }
        return corner
    }

    var portalLeft = 0f
    var portalTop = 0f
    var portalScale = 1f
    var host: LayoutCoordinates? = null
    var landscapeArt: LayoutCoordinates? = null
}

internal class LandscapeDockPose(val left: Float, val top: Float, val scale: Float)

internal val TileShape = RoundedCornerShape(8.dp)

internal fun autoMixStaticSleeveShare(fullBleed: Boolean, settledShare: Float, revealing: Boolean): Float =
    if (!revealing) settledShare else if (fullBleed) 1f else 0f

internal fun Modifier.artworkBottomFade(shown: () -> Float, fraction: () -> Float): Modifier = drawWithContent {
    drawContent()
    val share = shown()
    if (share > 0f) {
        drawRect(
            brush = Brush.verticalGradient(
                colorStops = Array(FADE_CURVE_STOPS + 1) { i ->
                    val t = i / FADE_CURVE_STOPS.toFloat()
                    t to Color.Black.copy(alpha = 1f - share * smootherStep(t))
                },
                startY = size.height * (1f - fraction()),
                endY = size.height,
            ),
            blendMode = BlendMode.DstIn,
        )
    }
}

@Composable
internal fun WhileShown(shown: () -> Boolean, content: @Composable () -> Unit) {
    if (shown()) content()
}

fun fullBleedArtworkAvailable(windowWidth: Dp): Boolean =
    playerFillsWindow(windowWidth) || tabletSizedPlayer(windowWidth)

internal fun playerFillsWindow(windowWidth: Dp): Boolean =
    windowWidth <= PLAYER_MAX_WIDTH + PLAYER_GUTTER * 2

internal fun tabletSizedPlayer(windowWidth: Dp): Boolean =
    windowWidth >= TABLET_PLAYER_MIN_WIDTH

fun landscapePlayerAvailable(windowWidth: Dp, windowHeight: Dp): Boolean =
    windowWidth > windowHeight && windowWidth >= LANDSCAPE_PLAYER_MIN_WIDTH

private val IN_PLACE_VIDEO_FULLSCREEN_MIN_SIDE = 600.dp

internal fun videoFullscreenInPlace(windowWidth: Dp, windowHeight: Dp): Boolean =
    minOf(windowWidth, windowHeight) >= IN_PLACE_VIDEO_FULLSCREEN_MIN_SIDE

internal const val LYRICS_CONTROLS_IDLE_MS = 5_000L
internal const val SPOTIFY_CANVAS_CONTROLS_IDLE_MS = 5_000L
internal const val SPOTIFY_CANVAS_CONTROLS_ANIMATION_MS = 420
internal const val PLAYER_DECK_FADE_IN_MS = 700
internal const val SPOTIFY_DECK_TOP_FADE_FRACTION = 0.28f

internal fun playerDeckSlideIn() = slideInVertically(
    animationSpec = tween(
        SPOTIFY_CANVAS_CONTROLS_ANIMATION_MS,
        easing = FastOutSlowInEasing,
    ),
    initialOffsetY = { it },
)

internal fun playerDeckSlideOut() = slideOutVertically(
    animationSpec = tween(
        SPOTIFY_CANVAS_CONTROLS_ANIMATION_MS,
        easing = FastOutSlowInEasing,
    ),
    targetOffsetY = { it },
)

@Composable
internal fun SlidingPlayerDeck(
    visible: Boolean,
    reveal: Animatable<Float, AnimationVector1D>,
    modifier: Modifier = Modifier,
    fadeIn: () -> Boolean = { false },
    content: @Composable () -> Unit,
) {
    var mounted by remember { mutableStateOf(visible) }
    val alpha = remember { Animatable(1f) }

    LaunchedEffect(visible) {
        if (visible) {
            if (fadeIn() && reveal.value < 1f) {
                alpha.snapTo(0f)
                reveal.snapTo(1f)
                mounted = true
                alpha.animateTo(
                    1f,
                    tween(PLAYER_DECK_FADE_IN_MS, easing = LinearEasing),
                )
            } else {
                alpha.snapTo(1f)
                mounted = true
                reveal.animateTo(
                    1f,
                    tween(
                        SPOTIFY_CANVAS_CONTROLS_ANIMATION_MS,
                        easing = FastOutSlowInEasing,
                    ),
                )
            }
        } else {
            reveal.animateTo(
                0f,
                tween(
                    SPOTIFY_CANVAS_CONTROLS_ANIMATION_MS,
                    easing = FastOutSlowInEasing,
                ),
            )
            mounted = false
        }
    }

    if (mounted) {
        Box(
            modifier = modifier
                .graphicsLayer {
                    this.alpha = alpha.value
                    compositingStrategy = CompositingStrategy.ModulateAlpha
                }
                .layout { measurable, constraints ->
                    val placeable = measurable.measure(constraints.copy(minHeight = 0))
                    val animatedHeight = (placeable.height * reveal.value)
                        .roundToInt()
                        .coerceIn(constraints.minHeight, constraints.maxHeight)
                    layout(placeable.width, animatedHeight) {
                        placeable.placeRelative(0, 0)
                    }
                }
                .pointerInput(Unit) {
                    awaitPointerEventScope {
                        while (true) awaitPointerEvent()
                    }
                },
        ) {
            content()
        }
    }
}

@Composable
@OptIn(ExperimentalHazeApi::class, ExperimentalHazeMaterialsApi::class)
fun NowPlayingScreen(
    song: Song,
    playedBy: String? = null,
    isPlaying: Boolean,
    isLoading: Boolean,
    position: PlaybackPosition,
    durationMs: Long,
    audioVersionSwitching: Boolean,
    qualityUpgraded: Boolean,
    queue: List<Song>,
    queueIndex: Int,
    hasPrevious: Boolean,
    hasNext: Boolean,
    repeatMode: Int,
    shuffleEnabled: Boolean,
    autoplayEnabled: Boolean,
    signedIn: Boolean,
    accountName: String?,
    likeStatus: LikeStatus,
    onToggleLike: () -> Unit,
    onPlayPause: () -> Unit,
    onNext: () -> Unit,
    onPrevious: () -> Unit,
    previousRestarts: () -> Boolean,
    currentPlaybackSong: () -> Song?,
    onBlockedControl: () -> Unit,
    onSeek: (Long) -> Unit,
    onSeekFraction: (Float) -> Unit,
    onToggleShuffle: () -> Unit,
    onCycleRepeat: () -> Unit,
    onToggleAutoplay: () -> Unit,
    onJumpTo: (Int) -> Unit,
    onRemoveFromQueue: (Int) -> Unit,
    onMoveInQueue: (Int, Int) -> Unit,
    onQueueDragActiveChange: (Boolean) -> Unit = {},
    onClearQueue: () -> Unit,
    onQueueSongMenu: (Int, Song) -> Unit = { _, _ -> },
    onQueueSwipeToQueue: suspend (Int, Song) -> Boolean = { _, _ -> false },
    queueUndoNotice: @Composable (HazeState) -> Unit = {},
    onQueueBulkAction: suspend (List<Song>, QueueBulkAction) -> Boolean = { _, _ -> false },
    onQueueRemoveEntries: suspend (List<QueueEntryIdentity>) -> Unit = {},
    onQueueAddAllToPlaylist: (List<Song>) -> Unit = {},
    onOpenMenu: () -> Unit,
    onOpenAlbum: (String) -> Unit,
    onOpenArtist: (browseId: String?, name: String) -> Unit,
    onOpenPlaybackSource: () -> Unit,
    onListenTogether: () -> Unit,
    lyrics: List<LyricLine>?,
    lyricsSource: LyricsSource?,
    lyricsProviderStates: Map<LyricsSource, LyricsProviderState>,
    onSelectLyricsProvider: (LyricsSource) -> Unit,
    lyricsUnavailable: Boolean,
    lyricsOffsetOpen: Boolean,
    onDismissLyricsOffset: () -> Unit,
    windowWidth: Dp,
    windowHeight: Dp,
    menuOpen: () -> Boolean = { false },
    onLiveCanvasChanged: (Boolean) -> Unit = {},
    modifier: Modifier = Modifier,
) {
    val trackParams = NowPlayingTrackParams(
        song = song,
        playedBy = playedBy,
        isPlaying = isPlaying,
        isLoading = isLoading,
        position = position,
        durationMs = durationMs,
        audioVersionSwitching = audioVersionSwitching,
        qualityUpgraded = qualityUpgraded,
        queue = queue,
        queueIndex = queueIndex,
        hasPrevious = hasPrevious,
        hasNext = hasNext,
        repeatMode = repeatMode,
        shuffleEnabled = shuffleEnabled,
        autoplayEnabled = autoplayEnabled,
        signedIn = signedIn,
        accountName = accountName,
        likeStatus = likeStatus,
    )
    val transportParams = NowPlayingTransportParams(
        onToggleLike = onToggleLike,
        onPlayPause = onPlayPause,
        onNext = onNext,
        onPrevious = onPrevious,
        previousRestarts = previousRestarts,
        currentPlaybackSong = currentPlaybackSong,
        onBlockedControl = onBlockedControl,
        onSeek = onSeek,
        onSeekFraction = onSeekFraction,
        onToggleShuffle = onToggleShuffle,
        onCycleRepeat = onCycleRepeat,
        onToggleAutoplay = onToggleAutoplay,
        onJumpTo = onJumpTo,
        onRemoveFromQueue = onRemoveFromQueue,
        onMoveInQueue = onMoveInQueue,
        onQueueDragActiveChange = onQueueDragActiveChange,
        onClearQueue = onClearQueue,
        onQueueSongMenu = onQueueSongMenu,
        onQueueSwipeToQueue = onQueueSwipeToQueue,
        queueUndoNotice = queueUndoNotice,
        onQueueBulkAction = onQueueBulkAction,
        onQueueRemoveEntries = onQueueRemoveEntries,
        onQueueAddAllToPlaylist = onQueueAddAllToPlaylist,
    )
    val windowParams = NowPlayingWindowParams(
        onOpenMenu = onOpenMenu,
        onOpenAlbum = onOpenAlbum,
        onOpenArtist = onOpenArtist,
        onOpenPlaybackSource = onOpenPlaybackSource,
        onListenTogether = onListenTogether,
        lyrics = lyrics,
        lyricsSource = lyricsSource,
        lyricsProviderStates = lyricsProviderStates,
        onSelectLyricsProvider = onSelectLyricsProvider,
        lyricsUnavailable = lyricsUnavailable,
        lyricsOffsetOpen = lyricsOffsetOpen,
        onDismissLyricsOffset = onDismissLyricsOffset,
        windowWidth = windowWidth,
        windowHeight = windowHeight,
        menuOpen = menuOpen,
        onLiveCanvasChanged = onLiveCanvasChanged,
    )
    NowPlayingStageBody(
        params = NowPlayingParams(trackParams, transportParams, windowParams),
        modifier = modifier,
    )
}

@Composable
internal fun NowPlayingStageBody(
    params: NowPlayingParams,
    modifier: Modifier,
) {
    StatusBarIcons(dark = false)
    val hideStatusBar by PlayerSettings.hideStatusBar.collectAsStateWithLifecycle()
    HideStatusBar(hideStatusBar)

    val sheets = remember { PlayerSheetsState() }
    val panels = remember { PlayerPanelsState(PlayerSettings.lastPlayerScreen.value) }
    val animatedCollapse = animateFloatAsState(
        targetValue = if (panels.lyricsOpen || panels.queueOpen) 1f else 0f,
        animationSpec = tween(durationMillis = 420, easing = FastOutSlowInEasing),
        label = "sleeveCollapse",
    )
    val collapse = remember(panels, animatedCollapse) { PlayerCollapseState(panels, animatedCollapse) }
    val scrub = rememberPlayerScrub(params.track.song.videoId, params.track.position, params.track.durationMs)
    val volume = rememberPlayerVolume()

    val media = NowPlayingStageMediaState(params, panels, collapse, scrub, volume)
    val interaction = NowPlayingStageInteractionState(params, sheets, panels, collapse, media, scrub, volume)
    val env = NowPlayingStageBuildEnv(params, sheets, panels, collapse, media, interaction)

    FrostedPlayerFrame(
        modifier = modifier,
        chrome = !interaction.disableBlendEffects && !media.videoFullscreen,
        softened = !media.spotifyCanvasPresentation &&
            (media.playerTheme == PlayerTheme.DEFAULT || media.playerTheme == PlayerTheme.LEGACY),
        frost = env.frost,
        live = media.spotifyCanvasPresentation,
        overlayOpen = { interaction.overlayOpen.value && !interaction.currentMenuOpen.value() },
        overlays = { NowPlayingStageOverlays(env) },
    ) {
        when {
            media.videoFullscreen -> NowPlayingStageFullscreenVideo(env)
            env.landscape -> NowPlayingStageLandscape(env)
            else -> NowPlayingStagePortrait(env)
        }
    }
}

internal suspend fun AwaitPointerEventScope.dragQueueIn(
    down: PointerInputChange,
    travel: Float,
    slide: MutableFloatState,
    onHold: (Boolean) -> Unit,
    onSettle: (Boolean) -> Unit,
) {
    if (travel < 1f) return

    var pulled = 0f
    val drag = awaitVerticalTouchSlopOrCancellation(down.id) { change, overSlop ->
        if (overSlop < 0f) {
            pulled = -overSlop
            change.consume()
        }
    }
    if (drag == null || pulled <= 0f) return

    onHold(true)
    val velocity = VelocityTracker()
    velocity.addPointerInputChange(drag)
    slide.floatValue = (pulled / travel).coerceIn(0f, 1f)
    verticalDrag(drag.id) { change ->
        velocity.addPointerInputChange(change)
        pulled -= change.positionChange().y
        slide.floatValue = (pulled / travel).coerceIn(0f, 1f)
        change.consume()
    }

    val flick = -velocity.calculateVelocity().y
    val open = when {
        flick >= QUEUE_FLICK_VELOCITY -> true
        flick <= -QUEUE_FLICK_VELOCITY -> false
        else -> slide.floatValue >= QUEUE_CARRY_FRACTION
    }
    onHold(false)
    onSettle(open)
}
