package com.fortune.vibramusic



import android.app.Application
import android.util.Log
import java.io.File
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

import kotlinx.coroutines.CoroutineScope

import kotlinx.coroutines.Dispatchers

import kotlinx.coroutines.launch

import kotlin.concurrent.thread



class VibraMusicApplication : Application(), SingletonImageLoader.Factory {



    @OptIn(UnstableApi::class)

    override fun onCreate() {
        super.onCreate()

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
                val crashFile = File(filesDir, "last_crash.log")
                crashFile.writeText(
                    "Timestamp: ${System.currentTimeMillis()}\n" +
                    "Version: ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})\n" +
                    "Device: ${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL} (Android ${android.os.Build.VERSION.RELEASE}, API ${android.os.Build.VERSION.SDK_INT})\n" +
                    "Thread: ${thread.name}\n" +
                    "Memory: ${usedMemMb}MB / ${maxMemMb}MB\n" +
                    "OOM: $isOom\n" +
                    "Top Live Threads:\n$topThreads\n" +
                    "Exception: ${throwable.javaClass.name}: ${throwable.message}\n\n" +
                    Log.getStackTraceString(throwable)
                )
            }
            defaultHandler?.uncaughtException(thread, throwable)
        }

        // Prune any legacy aliases that were erroneously enabled in previous builds
        // to guarantee exactly one launcher icon appears on the device home screen.
        runCatching {
            val pm = packageManager
            val darkLauncher = android.content.ComponentName(this, "$packageName.LauncherGlassDark")
            val lightLauncher = android.content.ComponentName(this, "$packageName.LauncherGlassLight")
            if (pm.getComponentEnabledSetting(darkLauncher) == android.content.pm.PackageManager.COMPONENT_ENABLED_STATE_ENABLED) {
                pm.setComponentEnabledSetting(
                    darkLauncher,
                    android.content.pm.PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    android.content.pm.PackageManager.DONT_KILL_APP,
                )
            }
            if (pm.getComponentEnabledSetting(lightLauncher) == android.content.pm.PackageManager.COMPONENT_ENABLED_STATE_ENABLED) {
                pm.setComponentEnabledSetting(
                    lightLauncher,
                    android.content.pm.PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    android.content.pm.PackageManager.DONT_KILL_APP,
                )
            }
        }.onFailure { Log.w("VibraMusic", "Could not prune duplicate launcher aliases", it) }

        // PlaybackService shares this process, so seeding the cookie here means

        // stream resolution is authenticated from the first play onwards.

        authStore = AuthStore(this)

        // Opened off the main thread, alongside everything below: none of these

        // reads a setting or the session, and between them they are the slowest

        // opens at startup — SourceRegistry's encrypted store most of all.

        // Started only once [AuthStore] exists, because both encrypted stores

        // share one keystore master key and a first launch must not have two

        // threads racing to create it. Joined before onCreate returns, so

        // nothing that runs after startup can see any of them half open.

        val backgroundInit = thread(name = "startup-init") {

            runCatching { SourceRegistry.init(this) }.onFailure { Log.w("VibraMusic", "Failed to init SourceRegistry", it) }

            runCatching { InnerTubeXResolver.init(this) }.onFailure { Log.w("VibraMusic", "Failed to init InnerTubeXResolver", it) }

            // Its own directory: canvas clips are looping video, not audio, and

            // belong in a cache AudioCache's own limit and eviction policy were

            // never sized for. See CanvasCache's doc for why this one exists at

            // all — it is the fix for canvas clips re-fetching the same few

            // seconds of video from the network on every loop.

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

        // Migration-safe: an old single cookie becomes the first encrypted

        // session, while newer installs restore the profile the listener chose.

        val restoredSession = authStore.activeSession

        if (restoredSession != null && authStore.activeAccountId == null) {

            authStore.select(restoredSession.accountId, restoredSession.activeProfileId)

        }

        authStore.cookie = restoredSession?.cookie

        Innertube.cookie = restoredSession?.cookie

        // Which account that cookie actually acts as. Read here rather than on

        // demand so the answer is usually in hand before the first request needs

        // it: a play registered under the wrong account is indistinguishable, to

        // the listener, from one that was never registered at all. Fire and

        // forget — every caller works without it, just less precisely.

        if (restoredSession != null) {

            // After the cookie, never before: setting the cookie clears any

            // channel the last session was acting as, so restoring the choice

            // first would restore it into the value about to be wiped.

            restoredSession.profiles.firstOrNull { it.profileId == restoredSession.activeProfileId }

                ?.let { Innertube.selectChannel(it.pageId, it.dataSyncId, it.authUser) }

            CoroutineScope(Dispatchers.IO).launch { Innertube.ensureSessionScope() }

        }

        runCatching { AppSettings.init(this, authStore) }.onFailure { Log.w("VibraMusic", "Failed to init AppSettings", it) }

        // Restores a party this device is still a member of, so a process death

        // mid-session is something the rest of the party never sees. The socket

        // and the clock offset are not restored — both are re-established on

        // the next connect, which is the only way to be sure they are current.

        runCatching { ListenTogether.init(this) }.onFailure { Log.w("VibraMusic", "Failed to init ListenTogether", it) }

        runCatching { SearchHistory.init(this) }.onFailure { Log.w("VibraMusic", "Failed to init SearchHistory", it) }

        runCatching { LastPlayed.init(this) }.onFailure { Log.w("VibraMusic", "Failed to init LastPlayed", it) }

        runCatching { com.fortune.vibramusic.playback.PartyPersonalQueueStash.init(this) }.onFailure { Log.w("VibraMusic", "Failed to init PartyPersonalQueueStash", it) }

        // Which tracks the listener has reverted to YouTube's own upload. Read

        // by [Song.toMediaItem], so it has to be open before the restart

        // snapshot below is turned back into queue items.

        runCatching { OriginalVersion.init(this) }.onFailure { Log.w("VibraMusic", "Failed to init OriginalVersion", it) }

        // What's already saved to Downloads, so the song menu can say so

        // without a media-store query per row.

        runCatching { Downloads.init(this) }.onFailure { Log.w("VibraMusic", "Failed to init Downloads", it) }

        // The device's own listening record. Opened here rather than in

        // PlaybackService because the Replay page reads it from the UI side and

        // both live in this process — one owner, one directory.

        runCatching { ListeningStats.init(this) }.onFailure { Log.w("VibraMusic", "Failed to init ListeningStats", it) }

        // After AppSettings, whose switch decides whether half of it runs.

        runCatching { ArtistFacts.init(this) }.onFailure { Log.w("VibraMusic", "Failed to init ArtistFacts", it) }

        // One cache directory can only be opened once per process, and

        // PlaybackService shares this one — so it's opened here, not there.

        runCatching { AudioCache.init(this) }.onFailure { Log.w("VibraMusic", "Failed to init AudioCache", it) }
        runCatching { com.fortune.vibramusic.data.cache.OfflineCacheManager.init(this) }.onFailure { Log.w("VibraMusic", "Failed to init OfflineCacheManager", it) }

        // The offscreen WebView that mints a Spotify access token from the

        // listener's own session cookie needs a Context, and nothing in the

        // suspend call chain that reaches it (a track's canvas lookup) has

        // one to hand — see SpotifyToken's doc for why.

        // Purge built-in Spotify token if it was erroneously saved to user preferences by previous builds
        val builtIn = com.fortune.vibramusic.data.canvas.TokenProvider.getSpdcToken()
        if (builtIn != null && AppSettings.spotifySpdcToken.value.isNotBlank() && AppSettings.spotifySpdcToken.value.trim() == builtIn) {
            AppSettings.setSpotifySpdcToken("")
        }

        runCatching { SpotifyToken.init(this) }.onFailure { Log.w("VibraMusic", "Failed to init SpotifyToken", it) }
        runCatching { SpotifyToken.warmUp() }.onFailure { Log.w("VibraMusic", "Failed to warm up SpotifyToken", it) }

        // A sideloaded update is just a new APK over the old one, so app data —

        // including whatever the old build left in these caches — survives it

        // untouched. Wipe both on the first launch of a higher versionCode so a

        // format or key change between builds can't serve stale or mismatched

        // bytes from a cache the new code didn't write.

        if (AppSettings.consumeVersionUpdate(BuildConfig.VERSION_CODE)) {

            AudioCache.clear()

            SingletonImageLoader.get(this).let { loader ->

                loader.memoryCache?.clear()

                loader.diskCache?.clear()

            }

        }

        // Initialize LastFM with saved settings if available
        runCatching { initLastfm() }.onFailure { Log.w("VibraMusic", "Failed to init LastFM", it) }

        runCatching { backgroundInit.join(3000L) }.onFailure { Log.w("VibraMusic", "Background init join timed out", it) }
    }



    /**

     * Artwork loading, which was previously left entirely on Coil's defaults.

     *

     * The defaults aren't unreasonable, but the disk cache is sized at 2% of

     * free space — which on a full phone is the 10MB floor, a few screens of

     * covers, and covers are exactly the thing worth still having tomorrow.

     * Naming a directory alongside it keeps that cache somewhere identifiable

     * rather than in the process's temp dir.

     */

    override fun newImageLoader(context: PlatformContext): ImageLoader =

        ImageLoader.Builder(context)

            // Covers on the WebDAV server need the credential or every one

            // of them 401s — which reads as "this track has no artwork".

            // Coil's own transport never sees Http.client's interceptor, so

            // the header is attached per request instead. See WebDavCoilAuth.

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
            // Covers arriving with a hard cut read as the list flickering as
            // it scrolls; a short fade reads as them developing.
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

    }

}




