package com.fortune.vibramusic.ui.player

import android.content.Context
import android.view.TextureView
import android.view.ViewGroup
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.layout.layout
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.HttpDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import com.metrolist.innertubex.extraction.StreamResolveException
import com.fortune.vibramusic.data.Http
import com.fortune.vibramusic.data.TrackLog
import com.fortune.vibramusic.data.innertube.InnerTubeXResolver
import com.fortune.vibramusic.data.model.Song
import com.fortune.vibramusic.data.settings.AppSettings
import com.fortune.vibramusic.playback.ChunkedDataSource
import com.fortune.vibramusic.playback.toSong
import com.fortune.vibramusic.ui.rememberIsForeground
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.abs
import kotlin.math.roundToInt

data class MusicVideoQualityUi(
    val heights: List<Int> = emptyList(),
    val held: Int? = null,
    val activeHeight: Int? = null,
)

/**
 * A music video's picture: a second ExoPlayer, video only and silent,
 * held to the main player's clock.
 */
@OptIn(UnstableApi::class)
object MusicVideoEngine {

    private const val TAG = "MusicVideo"

    private const val SEEK_DRIFT_MS = 450L
    private const val IGNORE_DRIFT_MS = 25L
    private const val SYNC_EVERY_MS = 250L
    private const val SEEK_COOLDOWN_MS = 1_500L
    private const val RELEASE_GRACE_MS = 4_000L
    private const val CHUNK_BYTES = 1L * 1024 * 1024
    private const val STREAM_TTL_MS = 60 * 60 * 1000L
    private const val MIN_VIDEO_ASPECT = 1.2f
    private const val AUTO_HEIGHT = 1080
    private const val METERED_HEIGHT = 480
    private const val KEY_QUALITY = "quality"
    private const val MAX_REFUSED_CLIENTS = 3

    private val REFUSAL_CODES = setOf(403, 404, 410)
    private val ESCALATED_REASONS = setOf(
        StreamResolveException.Reason.AGE_RESTRICTED,
        StreamResolveException.Reason.NO_PLAYABLE_STREAM,
    )

    private val scope = MainScope()

    private var controller: Player? = null
    private var player: ExoPlayer? = null
    private class Surface(val view: TextureView, val priority: Int)

    private val surfaces = ArrayList<Surface>()

    private fun top(): TextureView? = surfaces.lastOrNull { s -> surfaces.none { it.priority > s.priority } }?.view

    private var loadedId: String? = null
    private var loadJob: Job? = null
    private var syncJob: Job? = null
    private var releaseJob: Job? = null
    private var lastSeekAt = 0L
    private var seekStartedAt = 0L
    private var seekLeadMs = 250L

    private val streams = LinkedHashMap<String, Triple<InnerTubeXResolver.VideoStream, Int, Long>>()
    private val noPicture = HashSet<String>()
    private val ageGated = HashSet<String>()
    private val refused = HashMap<String, MutableSet<String>>()
    private var loadedProfile: String? = null

    private val _shownVideoId = MutableStateFlow<String?>(null)
    val shownVideoId: StateFlow<String?> = _shownVideoId.asStateFlow()

    private val _frameOn = MutableStateFlow<TextureView?>(null)
    internal val frameOn: StateFlow<TextureView?> = _frameOn.asStateFlow()

    private val _quality = MutableStateFlow(MusicVideoQualityUi())
    val quality: StateFlow<MusicVideoQualityUi> = _quality.asStateFlow()

    private var prefs: android.content.SharedPreferences? = null
    private var loadedCap = 0
    private val stepDown = HashSet<String>()

    private val _playing = MutableStateFlow(false)
    val playing: StateFlow<Boolean> = _playing.asStateFlow()

    private val _aspect = MutableStateFlow(16f / 9f)
    val aspect: StateFlow<Float> = _aspect.asStateFlow()

    private val controllerListener = object : Player.Listener {
        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) = refresh()
        override fun onIsPlayingChanged(isPlaying: Boolean) {
            _playing.value = isPlaying
            sync()
        }
        override fun onPlaybackParametersChanged(playbackParameters: PlaybackParameters) = sync()
        override fun onPositionDiscontinuity(
            oldPosition: Player.PositionInfo,
            newPosition: Player.PositionInfo,
            reason: Int,
        ) {
            lastSeekAt = 0L
            sync()
        }
    }

    private val playerListener = object : Player.Listener {
        override fun onRenderedFirstFrame() {
            _frameOn.value = top()
            _shownVideoId.value = loadedId
        }

        override fun onVideoSizeChanged(videoSize: VideoSize) {
            val width = videoSize.width * videoSize.pixelWidthHeightRatio
            if (width > 0f && videoSize.height > 0) {
                _aspect.value = width / videoSize.height
                _quality.value = _quality.value.copy(activeHeight = videoSize.height)
            }
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            if (playbackState == Player.STATE_READY && seekStartedAt > 0L) {
                val took = System.currentTimeMillis() - seekStartedAt
                seekLeadMs = ((seekLeadMs + took) / 2).coerceIn(0L, 1_500L)
                seekStartedAt = 0L
            }
        }

        override fun onPlayerError(error: PlaybackException) {
            val id = loadedId ?: return
            TrackLog.w(TAG, "video: playback failed at ${loadedCap}p (${error.errorCodeName})", about = id)
            streams.remove(id)
            val profile = loadedProfile
            if (profile != null && isRefusal(error)) {
                val skip = refused.getOrPut(id) { HashSet() }
                if (skip.add(profile) && skip.size <= MAX_REFUSED_CLIENTS) {
                    TrackLog.w(TAG, "video: $profile refused; asking the next client", about = id)
                    InnerTubeXResolver.onVideoRefused()
                    load(id)
                    return
                }
            }
            if (loadedCap > AUTO_HEIGHT && stepDown.add(id)) {
                load(id)
                return
            }
            noPicture += id
            unload()
        }
    }

    // ARCHITECTURE GUARD: init runs in declaration order, after all state flows and listeners exist.
    init {
        scope.launch {
            InnerTubeXResolver.sessionGeneration.drop(1).collect {
                noPicture.clear()
                streams.clear()
                refused.clear()
                refresh()
            }
        }
    }

    fun attach(controller: Player?) {
        runCatching {
            if (this.controller === controller) return
            this.controller?.removeListener(controllerListener)
            this.controller = controller
            controller?.addListener(controllerListener)
            _playing.value = controller?.isPlaying == true
            refresh()
        }.onFailure { TrackLog.w(TAG, "Failed to attach controller: ${it.message}") }
    }

    internal fun claim(view: TextureView, priority: Int): () -> Unit {
        releaseJob?.cancel()
        surfaces.removeAll { it.view === view }
        surfaces += Surface(view, priority)
        val app = view.context.applicationContext
        if (prefs == null) {
            prefs = app.getSharedPreferences("music_video", Context.MODE_PRIVATE).also { stored ->
                val held = stored.getInt(KEY_QUALITY, 0).takeIf { it > 0 }
                _quality.value = _quality.value.copy(held = held)
            }
        }
        val exo = ensurePlayer(app)
        if (top() === view) {
            _frameOn.value = null
            exo.setVideoTextureView(view)
            repaint()
        }
        refresh()
        return release@{
            val wasTop = top() === view
            surfaces.removeAll { it.view === view }
            if (!wasTop) return@release
            if (_frameOn.value === view) _frameOn.value = null
            val next = top()
            if (next != null) {
                exo.setVideoTextureView(next)
                repaint()
            } else {
                exo.clearVideoTextureView(view)
                releaseJob = scope.launch {
                    delay(RELEASE_GRACE_MS)
                    if (surfaces.isEmpty()) unload()
                }
            }
        }
    }

    private fun ensurePlayer(context: Context): ExoPlayer = player ?: ExoPlayer.Builder(context)
        .build()
        .apply {
            volume = 0f
            trackSelectionParameters = trackSelectionParameters.buildUpon()
                .setTrackTypeDisabled(C.TRACK_TYPE_AUDIO, true)
                .build()
            addListener(playerListener)
        }
        .also { player = it }

    private fun repaint() {
        val exo = player ?: return
        if (!exo.playWhenReady && exo.playbackState != Player.STATE_IDLE) {
            exo.seekTo(exo.currentPosition)
        }
    }

    private fun wanted(): Song? = runCatching {
        val song = controller?.currentMediaItem?.toSong() ?: return null
        song.takeIf { it.isVideo && it.videoId !in noPicture }
    }.getOrNull()

    private fun refresh() {
        runCatching {
            val song = if (surfaces.isEmpty()) null else wanted()
            if (song == null) {
                if (surfaces.isNotEmpty() || wanted()?.videoId != loadedId) unload()
                return
            }
            if (song.videoId == loadedId) {
                startSync()
                return
            }
            load(song.videoId)
        }.onFailure { TrackLog.w(TAG, "Failed to refresh video: ${it.message}") }
    }

    fun setQuality(height: Int?) {
        prefs?.edit()?.apply {
            if (height == null) remove(KEY_QUALITY) else putInt(KEY_QUALITY, height)
        }?.apply()
        _quality.value = _quality.value.copy(held = height)
        val id = loadedId ?: return
        streams.remove(id)
        stepDown.remove(id)
        load(id)
    }

    private fun capFor(videoId: String): Int {
        val metered = AppSettings.meteredConnection.value == true
        val auto = if (metered) METERED_HEIGHT else AUTO_HEIGHT
        val held = _quality.value.held ?: return auto
        return if (videoId in stepDown) minOf(held, AUTO_HEIGHT) else held
    }

    private fun isRefusal(error: PlaybackException): Boolean =
        generateSequence<Throwable>(error) { it.cause }
            .filterIsInstance<HttpDataSource.InvalidResponseCodeException>()
            .any { it.responseCode in REFUSAL_CODES }

    private suspend fun resolve(videoId: String, cap: Int): InnerTubeXResolver.VideoStream? {
        val skip = refused[videoId].orEmpty().toSet()
        if (videoId !in ageGated) {
            val plain = try {
                withContext(Dispatchers.IO) { InnerTubeXResolver.extractVideo(videoId, cap, skip) }
            } catch (e: StreamResolveException) {
                if (e.reason !in ESCALATED_REASONS) throw e
                null
            }
            if (plain != null) return plain
            TrackLog.d(TAG, "video: nothing asked plainly; asking as age-restricted", about = videoId)
        }
        return withContext(Dispatchers.IO) {
            InnerTubeXResolver.extractVideo(videoId, cap, skip, ageRestricted = true)
        }?.also { ageGated += videoId }
    }

    private fun load(videoId: String) {
        unload()
        loadedId = videoId
        val cap = capFor(videoId)
        loadedCap = cap
        loadJob = scope.launch {
            val stream = try {
                cachedStream(videoId, cap)
                    ?: resolve(videoId, cap)?.also { streams[videoId] = Triple(it, cap, System.currentTimeMillis()) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: StreamResolveException) {
                TrackLog.w(TAG, "video: no picture (${e.reason}): ${e.message}", about = videoId)
                if (loadedId != videoId) return@launch
                loadedId = null
                if (e.reason != StreamResolveException.Reason.NETWORK) noPicture += videoId
                return@launch
            } catch (e: Exception) {
                TrackLog.w(TAG, "video: couldn't resolve the picture: ${e.message}", about = videoId)
                if (loadedId == videoId) loadedId = null
                return@launch
            }
            if (loadedId != videoId) return@launch
            if (stream == null || stream.aspect < MIN_VIDEO_ASPECT) {
                noPicture += videoId
                loadedId = null
                return@launch
            }
            val exo = player ?: return@launch
            val upstream = OkHttpDataSource.Factory(Http.client)
                .setDefaultRequestProperties(stream.headers)
            val source = ProgressiveMediaSource.Factory(ChunkedDataSource.Factory(upstream, CHUNK_BYTES))
                .createMediaSource(MediaItem.fromUri(stream.url))
            if (stream.aspect > 0f) _aspect.value = stream.aspect
            _quality.value = _quality.value.copy(heights = stream.heights, activeHeight = stream.height)
            loadedProfile = stream.profileId
            val start = controller?.currentPosition?.coerceAtLeast(0L) ?: 0L
            exo.setMediaSource(source, start + seekLeadMs)
            exo.playWhenReady = controller?.isPlaying == true
            exo.prepare()
            lastSeekAt = System.currentTimeMillis()
            seekStartedAt = lastSeekAt
            startSync()
        }
    }

    private fun cachedStream(videoId: String, cap: Int): InnerTubeXResolver.VideoStream? {
        val (stream, askedFor, at) = streams[videoId] ?: return null
        if (askedFor != cap || System.currentTimeMillis() - at > STREAM_TTL_MS) {
            streams.remove(videoId)
            return null
        }
        return stream
    }

    private fun unload() {
        loadJob?.cancel()
        loadJob = null
        syncJob?.cancel()
        syncJob = null
        loadedId = null
        loadedProfile = null
        _shownVideoId.value = null
        _frameOn.value = null
        _quality.value = _quality.value.copy(heights = emptyList(), activeHeight = null)
        player?.let {
            it.stop()
            it.clearMediaItems()
        }
        while (streams.size > 8) streams.remove(streams.keys.first())
    }

    private fun startSync() {
        if (syncJob?.isActive == true) return
        syncJob = scope.launch {
            while (isActive) {
                sync()
                delay(SYNC_EVERY_MS)
            }
        }
    }

    private fun sync() {
        val audio = controller ?: return
        val exo = player ?: return
        if (loadedId == null || exo.playbackState == Player.STATE_IDLE || exo.playbackState == Player.STATE_ENDED) return
        val speed = audio.playbackParameters.speed
        val audioPos = audio.currentPosition
        val now = System.currentTimeMillis()
        if (!audio.isPlaying) {
            exo.playWhenReady = false
            setSpeed(exo, speed)
            if (abs(exo.currentPosition - audioPos) > 40L && now - lastSeekAt > 120L) seek(exo, audioPos)
            return
        }
        exo.playWhenReady = true
        if (exo.playbackState == Player.STATE_BUFFERING) return
        val drift = exo.currentPosition - audioPos
        if (abs(drift) > SEEK_DRIFT_MS) {
            if (now - lastSeekAt > SEEK_COOLDOWN_MS) seek(exo, audioPos + seekLeadMs)
            return
        }
        val nudge = if (abs(drift) > IGNORE_DRIFT_MS) (-drift / 1000f).coerceIn(-0.1f, 0.1f) else 0f
        setSpeed(exo, speed * (1f + nudge))
    }

    private fun seek(exo: ExoPlayer, positionMs: Long) {
        lastSeekAt = System.currentTimeMillis()
        seekStartedAt = lastSeekAt
        exo.seekTo(positionMs.coerceAtLeast(0L))
    }

    private fun setSpeed(exo: ExoPlayer, speed: Float) {
        if (abs(exo.playbackParameters.speed - speed) > 0.005f) {
            exo.playbackParameters = PlaybackParameters(speed)
        }
    }
}

/**
 * Where the playing music video shows: [videoId]'s picture, fitted into or
 * cropped to these bounds. Shows nothing until a frame of that video has
 * landed here, so a caller keeps its still artwork underneath and the picture
 * fades in over it.
 */
@OptIn(UnstableApi::class)
@Composable
fun AndroidMusicVideo(
    videoId: String,
    fit: Boolean,
    onRenderedChanged: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    priority: Int = 1,
) {
    val foreground = rememberIsForeground()
    var view by remember { mutableStateOf<TextureView?>(null) }
    DisposableEffect(view, foreground, priority) {
        val target = view
        val release = if (target != null && foreground) MusicVideoEngine.claim(target, priority) else null
        onDispose { release?.invoke() }
    }

    val shown by MusicVideoEngine.shownVideoId.collectAsStateWithLifecycle()
    val frameOn by MusicVideoEngine.frameOn.collectAsStateWithLifecycle()
    val aspect by MusicVideoEngine.aspect.collectAsStateWithLifecycle()
    val rendered = view != null && frameOn === view && shown == videoId
    val playing by MusicVideoEngine.playing.collectAsStateWithLifecycle()

    val awake = rendered && playing
    LaunchedEffect(view, awake) { view?.keepScreenOn = awake }

    val report by rememberUpdatedState(onRenderedChanged)
    LaunchedEffect(rendered) { report(rendered) }
    DisposableEffect(Unit) { onDispose { report(false) } }

    val alpha by animateFloatAsState(
        targetValue = if (rendered) 1f else 0f,
        animationSpec = tween(durationMillis = 320),
        label = "musicVideoAlpha",
    )

    Box(modifier.clipToBounds(), contentAlignment = Alignment.Center) {
        AndroidView(
            factory = { context ->
                TextureView(context).apply {
                    layoutParams = ViewGroup.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT,
                    )
                    isOpaque = false
                    this.alpha = 0f
                    view = this
                }
            },
            update = { it.alpha = alpha },
            onRelease = { if (view === it) view = null },
            modifier = Modifier.layout { measurable, constraints ->
                val width = constraints.maxWidth
                val height = if (constraints.hasBoundedHeight) {
                    constraints.maxHeight
                } else {
                    (width / aspect).roundToInt()
                }
                val boundsAspect = width.toFloat() / height.coerceAtLeast(1)
                val wider = boundsAspect > aspect
                val (w, h) = if (wider == fit) {
                    (height * aspect).roundToInt() to height
                } else {
                    width to (width / aspect).roundToInt()
                }
                val placeable = measurable.measure(Constraints.fixed(w.coerceAtLeast(1), h.coerceAtLeast(1)))
                layout(width, height) {
                    placeable.place((width - w) / 2, (height - h) / 2)
                }
            },
        )
    }
}
