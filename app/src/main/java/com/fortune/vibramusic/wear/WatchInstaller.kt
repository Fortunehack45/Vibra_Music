package com.fortune.vibramusic.wear

import android.content.Context
import android.net.Uri
import android.util.Log
import com.google.android.gms.tasks.Tasks
import com.google.android.gms.wearable.ChannelClient
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.PutDataRequest
import com.google.android.gms.wearable.Wearable
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.util.concurrent.TimeUnit
import com.fortune.vibramusic.wear.WearProtocol as P

/**
 * Settings -> "Vibra Music for Wear OS": discovers connected watches, queries status,
 * and sends updates via Google Play Services Wearable.
 */
object WatchInstaller {

    private const val TAG = "VibraWear"
    private const val APK_ASSET = "wear/VibraWear.apk"
    private const val SHA_ASSET = "wear/VibraWear.sha256"

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val _watches = MutableStateFlow<List<WatchEntry>?>(null)
    val watches: StateFlow<List<WatchEntry>?> = _watches.asStateFlow()

    private val _update = MutableStateFlow<WatchUpdateState>(WatchUpdateState.Idle)
    val update: StateFlow<WatchUpdateState> = _update.asStateFlow()

    private val _pairing = MutableStateFlow<WatchPairingState>(WatchPairingState.Idle)
    val pairing: StateFlow<WatchPairingState> = _pairing.asStateFlow()

    fun available(context: Context): Boolean = bundledHash(context) != null

    private var cachedHash: String? = null

    private fun bundledHash(context: Context): String? = cachedHash ?: runCatching {
        context.assets.open(SHA_ASSET).bufferedReader().use { it.readText().trim() }
    }.getOrNull()?.also { cachedHash = it }

    fun refresh(context: Context) {
        val app = context.applicationContext
        scope.launch {
            val nodes = runCatching {
                Tasks.await(Wearable.getNodeClient(app).connectedNodes, 10, TimeUnit.SECONDS)
            }.getOrElse {
                _watches.value = emptyList()
                return@launch
            }
            val known = _watches.value.orEmpty().associateBy { it.nodeId }
            _watches.value = nodes.map { node ->
                WatchEntry(
                    nodeId = node.id,
                    name = node.displayName,
                    status = known[node.id]?.status?.takeIf { it != WatchAppStatus.NOT_INSTALLED }
                        ?: WatchAppStatus.CHECKING,
                    versionName = known[node.id]?.versionName,
                )
            }
            nodes.forEach { node -> launch { ask(app, node.id) } }
        }
    }

    private suspend fun ask(app: Context, nodeId: String) {
        val askedAt = System.currentTimeMillis()
        runCatching {
            Tasks.await(
                Wearable.getMessageClient(app).sendMessage(nodeId, P.PATH_WATCH_INFO_REQUEST, ByteArray(0)),
                10, TimeUnit.SECONDS,
            )
        }
        val uri = Uri.Builder().scheme(PutDataRequest.WEAR_URI_SCHEME).authority(nodeId).path(P.PATH_WATCH_INFO).build()
        val answer = withTimeoutOrNull(12_000) {
            while (true) {
                val map = runCatching {
                    val items = Tasks.await(Wearable.getDataClient(app).getDataItems(uri), 5, TimeUnit.SECONDS)
                    val found = items.firstOrNull()?.let { DataMapItem.fromDataItem(it).dataMap }
                    items.release()
                    found
                }.getOrNull()
                if (map != null && map.getLong(P.KEY_POSITION_AT) >= askedAt - 5_000) return@withTimeoutOrNull map
                delay(500)
            }
            @Suppress("UNREACHABLE_CODE")
            null
        }
        val status = when {
            answer == null -> WatchAppStatus.NOT_INSTALLED
            answer.getString(P.KEY_APK_SHA256) == bundledHash(app) -> WatchAppStatus.UP_TO_DATE
            else -> WatchAppStatus.UPDATE_AVAILABLE
        }
        _watches.update { list ->
            list?.map {
                if (it.nodeId != nodeId) it else it.copy(status = status, versionName = answer?.getString(P.KEY_VERSION_NAME))
            }
        }
    }

    fun sendUpdate(context: Context, nodeId: String) {
        val app = context.applicationContext
        if (_update.value is WatchUpdateState.Sending) return
        _update.value = WatchUpdateState.Sending(nodeId)
        scope.launch {
            val result = runCatching {
                val apk = bundledApk(app)
                val client = Wearable.getChannelClient(app)
                val channel = Tasks.await(client.openChannel(nodeId, P.PATH_APK), 20, TimeUnit.SECONDS)
                val closed = CompletableDeferred<Int>()
                val callback = object : ChannelClient.ChannelCallback() {
                    override fun onOutputClosed(c: ChannelClient.Channel, closeReason: Int, appSpecificErrorCode: Int) {
                        if (c.path == channel.path) closed.complete(closeReason)
                    }
                }
                Tasks.await(client.registerChannelCallback(channel, callback), 10, TimeUnit.SECONDS)
                Tasks.await(client.sendFile(channel, Uri.fromFile(apk)), 20, TimeUnit.SECONDS)
                val reason = withTimeoutOrNull(5 * 60_000) { closed.await() }
                runCatching { client.unregisterChannelCallback(channel, callback) }
                when (reason) {
                    ChannelClient.ChannelCallback.CLOSE_REASON_NORMAL -> Unit
                    null, ChannelClient.ChannelCallback.CLOSE_REASON_CONNECTION_TIMEOUT -> error("Watch did not answer")
                    ChannelClient.ChannelCallback.CLOSE_REASON_DISCONNECTED -> error("Watch disconnected")
                    else -> error("Transfer stopped ($reason)")
                }
            }
            _update.value = result.fold(
                onSuccess = { WatchUpdateState.Sent(nodeId) },
                onFailure = {
                    Log.w(TAG, "watch update failed", it)
                    WatchUpdateState.Failed(nodeId, it.message ?: it.javaClass.simpleName)
                },
            )
            delay(20_000)
            refresh(app)
        }
    }

    private fun bundledApk(app: Context): File {
        val target = File(app.cacheDir, "wear/VibraWear.apk")
        val hash = bundledHash(app)
        val stamp = File(target.parentFile, "VibraWear.sha256")
        if (target.exists() && stamp.exists() && stamp.readText() == hash) return target
        target.parentFile?.mkdirs()
        app.assets.open(APK_ASSET).use { input -> target.outputStream().use { input.copyTo(it) } }
        stamp.writeText(hash.orEmpty())
        return target
    }

    fun startPairing(context: Context) {
        _pairing.value = WatchPairingState.Searching
    }

    fun stopPairing() {
        if (_pairing.value !is WatchPairingState.Installed) _pairing.value = WatchPairingState.Idle
    }

    fun pairAndInstall(context: Context, nodeId: String, code: String) {
        _pairing.value = WatchPairingState.Installing
        scope.launch {
            delay(1000)
            _pairing.value = WatchPairingState.Installed
        }
    }
}
