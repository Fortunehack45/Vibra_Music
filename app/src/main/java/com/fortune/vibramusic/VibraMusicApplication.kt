package com.fortune.vibramusic

import android.app.Application
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Process
import android.util.Log
import java.io.File
import kotlin.system.exitProcess
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import coil3.ImageLoader
import coil3.PlatformContext
import coil3.SingletonImageLoader
import coil3.disk.DiskCache
import coil3.disk.directory
import coil3.gif.AnimatedImageDecoder
import coil3.gif.GifDecoder
import coil3.memory.MemoryCache
import coil3.request.crossfade
import com.fortune.vibramusic.auth.AuthStore
import com.fortune.vibramusic.data.canvas.CanvasCache
import com.fortune.vibramusic.data.smb.SmbCoverFetcher
import com.fortune.vibramusic.data.webdav.WebDavCoilAuth
import com.fortune.vibramusic.data.canvas.SpotifyToken
import com.fortune.vibramusic.playback.AudioCache
import com.fortune.vibramusic.playback.LastPlayed
import com.fortune.vibramusic.playback.OriginalVersion
import com.fortune.vibramusic.data.innertube.Innertube
import com.fortune.vibramusic.data.innertube.InnerTubeXResolver
import com.fortune.vibramusic.data.listentogether.ListenTogether
import com.fortune.vibramusic.data.scrobbling.LastFM
import com.fortune.vibramusic.data.settings.AppSettings
import com.fortune.vibramusic.data.settings.SearchHistory
import com.fortune.vibramusic.data.sources.SourceRegistry
import com.fortune.vibramusic.data.stats.ArtistFacts
import com.fortune.vibramusic.data.stats.ListeningStats
import com.fortune.vibramusic.download.Downloads
import com.fortune.vibramusic.ui.CrashActivity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlin.concurrent.thread

class VibraMusicApplication : Application(), SingletonImageLoader.Factory {

    @OptIn(UnstableApi::class)
    override fun onCreate() {
        super.onCreate()

        // If this is the crash reporting process, do not run standard application initialization.
        if (isCrashProcess()) {
            return
        }

        val defaultHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            runCatching {
                Log.e("VibraMusic", "FATAL CRASH on thread ${thread.name}", throwable)
                val runtime = Runtime.getRuntime()
                val usedMemMb = (runtime.totalMemory() - runtime.freeMemory()) / (1024 * 1024)
                val maxMemMb = runtime.maxMemory() / (1024 * 1024)
                val isOom = throwable is OutOfMemoryError
                val topThreads = runCatching {
                    Thread.getAllStackTraces().keys.take(5).joinToString("\n") { "  - ${it.name} (${it.state})" }
                }.getOrDefault("  - ${thread.name} (${thread.state})")
                val crashDetails =
                    "Timestamp: ${System.currentTimeMillis()}\n" +
                    "Version: ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})\n" +
                    "Device: ${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL} (Android ${android.os.Build.VERSION.RELEASE}, API ${android.os.Build.VERSION.SDK_INT})\n" +
                    "Thread: ${thread.name}\n" +
                    "Memory: ${usedMemMb}MB / ${maxMemMb}MB\n" +
                    "OOM: $isOom\n" +
                    "Top Live Threads:\n$topThreads\n" +
                    "Exception: ${throwable.javaClass.name}: ${throwable.message}\n\n" +
                    Log.getStackTraceString(throwable)

                // 1. Internal storage
                runCatching { File(filesDir, "last_crash.log").writeText(crashDetails) }

                // 2. External app-specific storage (accessible to users via file manager)
                runCatching {
                    getExternalFilesDir(null)?.resolve("crash_log.txt")?.writeText(crashDetails)
                }

                // 3. Cache directory
                runCatching {
                    cacheDir.resolve("crash_log.txt").writeText(crashDetails)
                }

                // 4. Launch dedicated crash activity in :crash process
                val crashIntent = Intent(this, CrashActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
                    putExtra(CrashActivity.EXTRA_CRASH_INFO, crashDetails)
                }
                startActivity(crashIntent)

                // 5. Terminate crashed process
                Process.killProcess(Process.myPid())
                exitProcess(10)
            }.onFailure {
                defaultHandler?.uncaughtException(thread, throwable)
            }
        }

        // PlaybackService shares this process, so seeding the cookie here means
        // stream resolution is authenticated from the first play onwards.
        runCatching {
            authStore = AuthStore(this)
        }.onFailure { Log.e("VibraMusic", "Failed to initialize AuthStore", it) }

        val backgroundInit = thread(name = "startup-init") {
            runCatching { SourceRegistry.init(this) }.onFailure { Log.w("VibraMusic", "Failed to init SourceRegistry", it) }
            runCatching { InnerTubeXResolver.init(this) }.onFailure { Log.w("VibraMusic", "Failed to init InnerTubeXResolver", it) }
            runCatching { CanvasCache.init(this) }.onFailure { Log.w("VibraMusic", "Failed to init CanvasCache", it) }
            runCatching { com.fortune.vibramusic.data.lyrics.CustomLyricsStore.init(this) }.onFailure { Log.w("VibraMusic", "Failed to init CustomLyricsStore", it) }
            runCatching { com.fortune.vibramusic.data.LocalLikesStore.init(this) }.onFailure { Log.w("VibraMusic", "Failed to init LocalLikesStore", it) }
            runCatching { com.fortune.vibramusic.data.LocalPlaylistsStore.init(this) }.onFailure { Log.w("VibraMusic", "Failed to init LocalPlaylistsStore", it) }
            runCatching { com.fortune.vibramusic.playback.smart.MetaSchedulerHolder.init(this) }.onFailure { Log.w("VibraMusic", "Failed to init MetaSchedulerHolder", it) }
            runCatching {
                val smartStore = com.fortune.vibramusic.playback.smart.AnalysisStore(this)
                com.fortune.vibramusic.playback.smart.AcousticCatalogService.purgeFabricatedMeta(this, smartStore)
            }.onFailure { Log.w("VibraMusic", "Failed to init AnalysisStore", it) }
        }

        runCatching {
            if (isAuthStoreInitialized) {
                val restoredSession = authStore.activeSession
                if (restoredSession != null && authStore.activeAccountId == null) {
                    authStore.select(restoredSession.accountId, restoredSession.activeProfileId)
                }
                authStore.cookie = restoredSession?.cookie
                Innertube.cookie = restoredSession?.cookie

                if (restoredSession != null) {
                    restoredSession.profiles.firstOrNull { it.profileId == restoredSession.activeProfileId }
                        ?.let { Innertube.selectChannel(it.pageId, it.dataSyncId, it.authUser) }
                    CoroutineScope(Dispatchers.IO).launch { Innertube.ensureSessionScope() }
                }
                AppSettings.init(this, authStore)
            }
        }.onFailure { Log.w("VibraMusic", "Failed to restore session or AppSettings", it) }

        runCatching { ListenTogether.init(this) }.onFailure { Log.w("VibraMusic", "Failed to init ListenTogether", it) }
        runCatching { SearchHistory.init(this) }.onFailure { Log.w("VibraMusic", "Failed to init SearchHistory", it) }
        runCatching { LastPlayed.init(this) }.onFailure { Log.w("VibraMusic", "Failed to init LastPlayed", it) }
        runCatching { com.fortune.vibramusic.playback.PartyPersonalQueueStash.init(this) }.onFailure { Log.w("VibraMusic", "Failed to init PartyPersonalQueueStash", it) }
        runCatching { OriginalVersion.init(this) }.onFailure { Log.w("VibraMusic", "Failed to init OriginalVersion", it) }
        runCatching { Downloads.init(this) }.onFailure { Log.w("VibraMusic", "Failed to init Downloads", it) }
        runCatching { ListeningStats.init(this) }.onFailure { Log.w("VibraMusic", "Failed to init ListeningStats", it) }
        runCatching { ArtistFacts.init(this) }.onFailure { Log.w("VibraMusic", "Failed to init ArtistFacts", it) }
        runCatching { AudioCache.init(this) }.onFailure { Log.w("VibraMusic", "Failed to init AudioCache", it) }
        runCatching { com.fortune.vibramusic.data.cache.OfflineCacheManager.init(this) }.onFailure { Log.w("VibraMusic", "Failed to init OfflineCacheManager", it) }

        runCatching {
            val builtIn = com.fortune.vibramusic.data.canvas.TokenProvider.getSpdcToken()
            if (builtIn != null && AppSettings.spotifySpdcToken.value.isNotBlank() && AppSettings.spotifySpdcToken.value.trim() == builtIn) {
                AppSettings.setSpotifySpdcToken("")
            }
        }.onFailure { Log.w("VibraMusic", "Failed to purge built-in Spotify token", it) }

        runCatching { SpotifyToken.init(this) }.onFailure { Log.w("VibraMusic", "Failed to init SpotifyToken", it) }
        runCatching { SpotifyToken.warmUp() }.onFailure { Log.w("VibraMusic", "Failed to warm up SpotifyToken", it) }

        runCatching {
            if (AppSettings.consumeVersionUpdate(BuildConfig.VERSION_CODE)) {
                AudioCache.clear()
                SingletonImageLoader.get(this).let { loader ->
                    loader.memoryCache?.clear()
                    loader.diskCache?.clear()
                }
            }
        }.onFailure { Log.w("VibraMusic", "Failed to execute version update cache wipe", it) }

        runCatching { initLastfm() }.onFailure { Log.w("VibraMusic", "Failed to init LastFM", it) }
        runCatching { backgroundInit.join(3000L) }.onFailure { Log.w("VibraMusic", "Background init join timed out", it) }
    }

    private fun isCrashProcess(): Boolean = runCatching {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            getProcessName().endsWith(":crash")
        } else {
            val pid = Process.myPid()
            val am = getSystemService(Context.ACTIVITY_SERVICE) as? android.app.ActivityManager
            am?.runningAppProcesses?.firstOrNull { it.pid == pid }?.processName?.endsWith(":crash") == true
        }
    }.getOrDefault(false)

    override fun newImageLoader(context: PlatformContext): ImageLoader =
        ImageLoader.Builder(context)
            .components {
                add(WebDavCoilAuth())
                add(SmbCoverFetcher.Factory())
                if (android.os.Build.VERSION.SDK_INT >= 28) {
                    add(AnimatedImageDecoder.Factory())
                } else {
                    add(GifDecoder.Factory())
                }
            }
            .memoryCache {
                MemoryCache.Builder()
                    .maxSizePercent(context, 0.12)
                    .build()
            }
            .diskCache {
                DiskCache.Builder()
                    .directory(cacheDir.resolve("image_cache"))
                    .maxSizeBytes(100L * 1024 * 1024)
                    .build()
            }
            .crossfade(200)
            .build()

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        if (level >= TRIM_MEMORY_BACKGROUND || level >= TRIM_MEMORY_RUNNING_LOW) {
            SingletonImageLoader.get(this).memoryCache?.clear()
            com.fortune.vibramusic.ui.player.clearBackdropCaches()
        }
    }

    override fun onLowMemory() {
        super.onLowMemory()
        SingletonImageLoader.get(this).memoryCache?.clear()
        com.fortune.vibramusic.ui.player.clearBackdropCaches()
    }

    private fun initLastfm() {
        val sessionKey = AppSettings.lastfmSessionKey.value
        if (sessionKey.isBlank()) return
        val endpoint = AppSettings.lastfmEndpoint.value.ifBlank { LastFM.DEFAULT_API_ENDPOINT }
        val apiKey = AppSettings.lastfmApiKey.value.trim()
        val secret = AppSettings.lastfmSecret.value.trim()
        if (apiKey.isBlank() || secret.isBlank()) return
        LastFM.configure(
            endpoint = endpoint,
            apiKey = apiKey,
            secret = secret,
            sessionKey = sessionKey,
        )
    }

    companion object {
        lateinit var authStore: AuthStore
            private set

        val isAuthStoreInitialized: Boolean
            get() = ::authStore.isInitialized
    }
}
