package com.fortune.vibramusic.data

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import com.fortune.vibramusic.BuildConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Request
import java.io.File
import java.security.MessageDigest

/**
 * Vibra Music ships as a sideloaded APK off GitHub Releases rather than through
 * a store, so there's nothing to push an update notice on its own — this
 * polls the repo's "latest release" once per launch and compares its tag
 * against the running build.
 *
 * The update itself is also handled here: the release's `.apk` asset is
 * downloaded into the app's cache and handed to the system package installer,
 * so the whole round trip stays inside the app instead of bouncing out to a
 * browser.
 */
object AppUpdateChecker {

    data class UpdateInfo(
        val version: String,
        val releaseUrl: String,
        val apkUrl: String?,
        val apkFileName: String? = null,
        val checksumsUrl: String? = null,
        /** The release's own Markdown body, shown as this update's "what's new". */
        val notes: String? = null,
    )

    private const val CACHE_SUBDIR = "updates"

    private const val LATEST_RELEASE_URL =
        "https://api.github.com/repos/Fortunehack45/Vibra_Music_Releases/releases/latest"

    private val json = Json { ignoreUnknownKeys = true }

    private val _available = MutableStateFlow<UpdateInfo?>(null)
    val available = _available.asStateFlow()

    /** Where this update's APK download currently stands, for the dialog's progress row. */
    sealed interface DownloadState {
        data object Idle : DownloadState
        data class Downloading(val fraction: Float) : DownloadState
        data class Ready(val file: File) : DownloadState
        data class Failed(val message: String) : DownloadState
    }

    private val _download = MutableStateFlow<DownloadState>(DownloadState.Idle)
    val download = _download.asStateFlow()

    /** Set from the UI thread when the user cancels; polled between network reads. */
    @Volatile
    private var downloadCancelled = false

    suspend fun check(): UpdateInfo? = withContext(Dispatchers.IO) {
        runCatching {
            val request = Request.Builder()
                .url(LATEST_RELEASE_URL)
                .header("User-Agent", "VibraMusic-App/${BuildConfig.VERSION_NAME}")
                .header("Accept", "application/vnd.github+json")
                .build()
            val body = Http.client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) {
                    android.util.Log.w("AppUpdateChecker", "Update check failed: HTTP ${response.code} ${response.message}")
                    null
                } else {
                    response.body?.string()
                }
            } ?: return@runCatching null
            val release = json.parseToJsonElement(body) as? JsonObject ?: return@runCatching null
            val tag = release["tag_name"]?.jsonPrimitive?.contentOrNull ?: return@runCatching null
            val url = release["html_url"]?.jsonPrimitive?.contentOrNull ?: return@runCatching null
            val apkAssetInfo = apkAsset(release)
            val apkUrl = apkAssetInfo?.first
            val apkFileName = apkAssetInfo?.second
            val checksumsUrl = release["assets"]?.jsonArray
                ?.mapNotNull { it as? JsonObject }
                ?.firstOrNull { it["name"]?.jsonPrimitive?.contentOrNull == "checksums.txt" }
                ?.get("browser_download_url")?.jsonPrimitive?.contentOrNull
            val notes = release["body"]?.jsonPrimitive?.contentOrNull
            val latest = tag.removePrefix("v")
            if (isNewer(latest, BuildConfig.VERSION_NAME)) {
                val info = UpdateInfo(latest, url, apkUrl, apkFileName, checksumsUrl, notes)
                _available.value = info
                info
            } else {
                null
            }
        }.getOrNull()
    }

    /**
     * Wipes any APK left over from a previous run. Called once at cold start
     * so a downloaded update is only ever "Install Now" for the session that
     * downloaded it — the next launch starts clean rather than trying to work
     * out whether a leftover file is still good.
     */
    suspend fun clearCache(context: Context) = withContext(Dispatchers.IO) {
        File(context.cacheDir, CACHE_SUBDIR).listFiles()?.forEach { it.delete() }
    }

    /**
     * Finds the most appropriate `.apk` asset for this device's ABI, falling
     * back to universal or the first available APK. Returns Pair(downloadUrl, fileName).
     */
    private fun apkAsset(release: JsonObject): Pair<String, String>? = runCatching {
        val assets = release["assets"]?.jsonArray
            ?.mapNotNull { it as? JsonObject }
            ?.filter { asset ->
                asset["name"]?.jsonPrimitive?.contentOrNull?.endsWith(".apk", ignoreCase = true) == true &&
                    asset["state"]?.jsonPrimitive?.contentOrNull == "uploaded"
            } ?: return null
        if (assets.isEmpty()) return null

        val supportedAbis = Build.SUPPORTED_ABIS ?: emptyArray()
        val best = supportedAbis.firstNotNullOfOrNull { abi ->
            assets.firstOrNull { asset ->
                val name = asset["name"]?.jsonPrimitive?.contentOrNull ?: ""
                name.contains(abi, ignoreCase = true)
            }
        } ?: assets.firstOrNull { asset ->
            val name = asset["name"]?.jsonPrimitive?.contentOrNull ?: ""
            name.contains("universal", ignoreCase = true)
        } ?: assets.first()

        val downloadUrl = best["browser_download_url"]?.jsonPrimitive?.contentOrNull ?: return null
        val fileName = best["name"]?.jsonPrimitive?.contentOrNull ?: "app.apk"
        Pair(downloadUrl, fileName)
    }.getOrNull()

    /**
     * Streams the current update's APK into the app cache, reporting progress
     * through [download]. A finished file survives a cancelled dialog: until
     * the state is reset, "Install Now" comes straight back without a second
     * download.
     *
     * Security controls:
     * 1. Validates HTTPS and trusted host domain (github.com or objects.githubusercontent.com)
     * 2. Computes SHA-256 and verifies against official release checksums.txt when available
     */
    suspend fun downloadApk(context: Context): Unit = withContext(Dispatchers.IO) {
        val info = _available.value ?: return@withContext
        val url = info.apkUrl ?: return@withContext
        downloadCancelled = false
        _download.value = DownloadState.Downloading(0f)

        runCatching {
            // Security check 1: Enforce HTTPS and trusted host domain
            val parsedUri = Uri.parse(url)
            val host = parsedUri.host?.lowercase() ?: ""
            val isTrustedHost = host == "github.com" ||
                host.endsWith(".github.com") ||
                host == "objects.githubusercontent.com" ||
                host.endsWith(".githubusercontent.com")
            if (parsedUri.scheme != "https" || !isTrustedHost) {
                error("Untrusted update download URL: $url")
            }

            val dir = File(context.cacheDir, CACHE_SUBDIR).apply { mkdirs() }
            // Drop anything left over from an earlier attempt.
            dir.listFiles()?.forEach { it.delete() }
            val target = File(dir, "vibra-${info.version}.apk")

            val request = Request.Builder()
                .url(url)
                .header("User-Agent", "VibraMusic-App/${BuildConfig.VERSION_NAME}")
                .build()
            Http.client.newCall(request).execute().use { response ->
                check(response.isSuccessful) { "Download failed: HTTP ${response.code}" }
                val body = response.body ?: error("Empty download body")
                val total = body.contentLength().takeIf { it > 0 }

                body.byteStream().use { input ->
                    target.outputStream().use { output ->
                        val buffer = ByteArray(64 * 1024)
                        var readTotal = 0L
                        while (true) {
                            if (downloadCancelled) {
                                _download.value = DownloadState.Idle
                                return@withContext
                            }
                            val read = input.read(buffer)
                            if (read == -1) break
                            output.write(buffer, 0, read)
                            readTotal += read
                            total?.let {
                                _download.value =
                                    DownloadState.Downloading((readTotal.toFloat() / it).coerceIn(0f, 1f))
                            }
                        }
                    }
                }
            }

            // Security check 2: Verify SHA-256 checksum against official release checksums.txt
            if (!info.checksumsUrl.isNullOrBlank()) {
                val checksumReq = Request.Builder()
                    .url(info.checksumsUrl)
                    .header("User-Agent", "VibraMusic-App/${BuildConfig.VERSION_NAME}")
                    .build()
                val checksumBody = Http.client.newCall(checksumReq).execute().use { resp ->
                    if (resp.isSuccessful) resp.body?.string() else null
                }
                if (!checksumBody.isNullOrBlank()) {
                    val digest = MessageDigest.getInstance("SHA-256")
                    target.inputStream().use { fis ->
                        val buf = ByteArray(64 * 1024)
                        var n: Int
                        while (fis.read(buf).also { n = it } != -1) {
                            digest.update(buf, 0, n)
                        }
                    }
                    val computedHash = digest.digest().joinToString("") { "%02x".format(it) }

                    // Format of checksums.txt lines: "<sha256>  <filename>"
                    val targetName = info.apkFileName ?: target.name
                    val matchedLine = checksumBody.lineSequence().firstOrNull { line ->
                        line.trim().endsWith(targetName, ignoreCase = true)
                    }
                    if (matchedLine != null) {
                        val expectedHash = matchedLine.trim().split(Regex("\\s+")).firstOrNull() ?: ""
                        if (!computedHash.equals(expectedHash, ignoreCase = true)) {
                            target.delete()
                            error("Integrity error: APK SHA-256 hash mismatch (expected $expectedHash, got $computedHash)")
                        }
                    }
                }
            }

            _download.value = DownloadState.Ready(target)
        }.onFailure { error ->
            _download.value = if (downloadCancelled) {
                DownloadState.Idle
            } else {
                DownloadState.Failed(error.message ?: "Download failed")
            }
        }
    }

    /** Stops an in-flight download; the next read loop sees this and bails. */
    fun cancelDownload() {
        downloadCancelled = true
    }

    /** Back to square one after a failure, so the dialog offers Download again. */
    fun resetDownload() {
        _download.value = DownloadState.Idle
    }

    /**
     * Hands a downloaded APK to the system installer.
     *
     * Sideloaded apps need the user's blessing per app ("install unknown apps");
     * without it the installer intent silently does nothing on most ROMs, so
     * the user is sent to that one switch first and taps Install again after.
     */
    fun installApk(context: Context, file: File) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !context.packageManager.canRequestPackageInstalls()
        ) {
            context.startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                    .setData(Uri.parse("package:${context.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            return
        }
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        val installIntent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                putExtra(Intent.EXTRA_NOT_UNKNOWN_SOURCE, true)
                putExtra(Intent.EXTRA_RETURN_RESULT, true)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        } else {
            @Suppress("DEPRECATION")
            Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                putExtra(Intent.EXTRA_NOT_UNKNOWN_SOURCE, true)
                putExtra(Intent.EXTRA_RETURN_RESULT, true)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        }
        context.startActivity(installIntent)
    }

    /** A version split into its numeric dotted parts and whether it carries a "-suffix" (e.g. "-beta2"). */
    private data class ParsedVersion(val parts: List<Int>, val isPreRelease: Boolean)

    private fun parseVersion(raw: String): ParsedVersion {
        val dash = raw.indexOf('-')
        val base = if (dash >= 0) raw.substring(0, dash) else raw
        return ParsedVersion(base.split(".").map { it.toIntOrNull() ?: 0 }, dash >= 0)
    }

    /**
     * Numeric, dot-separated comparison — "1.10" outranks "1.9" — with one
     * extra rule: a "-betaN" build (see the debug build type's
     * `versionNameSuffix` in app/build.gradle.kts) is treated as older than a
     * plain release of the same numbers, since the beta by definition predates
     * the tag it was testing toward. Without this, a beta and the release it
     * matches compare equal and testers never get nudged onto the real build.
     */
    private fun isNewer(latest: String, current: String): Boolean {
        val l = parseVersion(latest)
        val c = parseVersion(current)
        for (i in 0 until maxOf(l.parts.size, c.parts.size)) {
            val a = l.parts.getOrElse(i) { 0 }
            val b = c.parts.getOrElse(i) { 0 }
            if (a != b) return a > b
        }
        return c.isPreRelease && !l.isPreRelease
    }
}
