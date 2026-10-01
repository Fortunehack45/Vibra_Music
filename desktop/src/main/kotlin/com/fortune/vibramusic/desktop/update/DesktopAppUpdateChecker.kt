package com.fortune.vibramusic.desktop.update

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.FileOutputStream

object DesktopAppUpdateChecker {
    const val CURRENT_VERSION = "1.8.19"

    private const val LATEST_RELEASE_URL =
        "https://api.github.com/repos/Fortunehack45/Vibra_Music_Releases/releases/latest"

    private val json = Json { ignoreUnknownKeys = true }
    private val httpClient = OkHttpClient.Builder().build()

    data class DesktopUpdateInfo(
        val version: String,
        val releaseUrl: String,
        val msiUrl: String?,
        val msiFileName: String?,
        val notes: String?,
    )

    sealed interface DownloadState {
        data object Idle : DownloadState
        data class Downloading(val fraction: Float) : DownloadState
        data class Ready(val file: File) : DownloadState
        data class Failed(val message: String) : DownloadState
    }

    private val _available = MutableStateFlow<DesktopUpdateInfo?>(null)
    val available: StateFlow<DesktopUpdateInfo?> = _available.asStateFlow()

    private val _downloadState = MutableStateFlow<DownloadState>(DownloadState.Idle)
    val downloadState: StateFlow<DownloadState> = _downloadState.asStateFlow()

    @Volatile
    private var isCancelled = false

    suspend fun check(): DesktopUpdateInfo? = withContext(Dispatchers.IO) {
        try {
            val req = Request.Builder()
                .url(LATEST_RELEASE_URL)
                .header("User-Agent", "VibraMusic-Windows/$CURRENT_VERSION")
                .header("Accept", "application/vnd.github+json")
                .build()

            val body = httpClient.newCall(req).execute().use { resp ->
                if (resp.isSuccessful) resp.body?.string() else null
            } ?: return@withContext null

            val root = json.parseToJsonElement(body).jsonObject
            val tag = root["tag_name"]?.jsonPrimitive?.contentOrNull ?: return@withContext null
            val htmlUrl = root["html_url"]?.jsonPrimitive?.contentOrNull ?: ""
            val bodyNotes = root["body"]?.jsonPrimitive?.contentOrNull ?: ""

            // Locate Windows MSI asset
            val assets = root["assets"]?.jsonArray
            var msiUrl: String? = null
            var msiFileName: String? = null

            assets?.forEach { element ->
                val assetObj = element.jsonObject
                val name = assetObj["name"]?.jsonPrimitive?.contentOrNull ?: ""
                if (name.endsWith(".msi", ignoreCase = true)) {
                    msiUrl = assetObj["browser_download_url"]?.jsonPrimitive?.contentOrNull
                    msiFileName = name
                }
            }

            val remoteVersion = tag.removePrefix("v").trim()
            if (isNewer(remoteVersion, CURRENT_VERSION)) {
                val info = DesktopUpdateInfo(
                    version = remoteVersion,
                    releaseUrl = htmlUrl,
                    msiUrl = msiUrl,
                    msiFileName = msiFileName,
                    notes = bodyNotes,
                )
                _available.value = info
                return@withContext info
            }
        } catch (t: Throwable) {
            println("[DesktopAppUpdateChecker] Check error: ${t.message}")
        }
        null
    }

    suspend fun downloadUpdate(): File? = withContext(Dispatchers.IO) {
        val info = _available.value ?: return@withContext null
        val downloadUrl = info.msiUrl ?: return@withContext null
        val fileName = info.msiFileName ?: "VibraMusic-v${info.version}-Windows-Installer.msi"

        isCancelled = false
        _downloadState.value = DownloadState.Downloading(0f)

        try {
            val tempDir = File(System.getProperty("java.io.tmpdir"), "VibraMusicUpdates")
            if (!tempDir.exists()) tempDir.mkdirs()
            val targetFile = File(tempDir, fileName)

            val req = Request.Builder().url(downloadUrl).build()
            httpClient.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) {
                    _downloadState.value = DownloadState.Failed("Download failed: HTTP ${resp.code}")
                    return@withContext null
                }

                val body = resp.body ?: run {
                    _downloadState.value = DownloadState.Failed("Empty response body")
                    return@withContext null
                }

                val contentLength = body.contentLength()
                body.byteStream().use { input ->
                    FileOutputStream(targetFile).use { output ->
                        val buffer = ByteArray(16 * 1024)
                        var bytesRead: Int
                        var totalRead = 0L

                        while (input.read(buffer).also { bytesRead = it } != -1) {
                            if (isCancelled) {
                                targetFile.delete()
                                _downloadState.value = DownloadState.Idle
                                return@withContext null
                            }
                            output.write(buffer, 0, bytesRead)
                            totalRead += bytesRead
                            if (contentLength > 0) {
                                val progress = (totalRead.toFloat() / contentLength.toFloat()).coerceIn(0f, 1f)
                                _downloadState.value = DownloadState.Downloading(progress)
                            }
                        }
                    }
                }
            }

            _downloadState.value = DownloadState.Ready(targetFile)
            return@withContext targetFile
        } catch (t: Throwable) {
            _downloadState.value = DownloadState.Failed(t.message ?: "Download failed")
            null
        }
    }

    fun installAndRestart(msiFile: File) {
        try {
            // Run msiexec in passive/quiet UI mode
            ProcessBuilder("msiexec.exe", "/i", msiFile.absolutePath).start()
            // Exit current app so installer can overwrite binaries
            System.exit(0)
        } catch (t: Throwable) {
            t.printStackTrace()
        }
    }

    fun dismiss() {
        _available.value = null
        _downloadState.value = DownloadState.Idle
    }

    private fun isNewer(latest: String, current: String): Boolean {
        val lParts = latest.split('.').mapNotNull { it.toIntOrNull() }
        val cParts = current.split('.').mapNotNull { it.toIntOrNull() }
        val maxLen = maxOf(lParts.size, cParts.size)
        for (i in 0 until maxLen) {
            val l = lParts.getOrElse(i) { 0 }
            val c = cParts.getOrElse(i) { 0 }
            if (l > c) return true
            if (l < c) return false
        }
        return false
    }
}
