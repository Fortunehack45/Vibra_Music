package com.fortune.vibramusic.ui.screens

import android.annotation.SuppressLint
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.core.net.toUri
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.ui.platform.LocalContext
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.fortune.vibramusic.R
import com.fortune.vibramusic.data.settings.AppSettings
import com.fortune.vibramusic.data.spotify.SpotifyLibrary
import com.fortune.vibramusic.data.spotify.SpotifyPlaylist
import com.fortune.vibramusic.data.spotify.SpotifyTrack

private const val LOGIN_URL =
    "https://accounts.spotify.com/login?continue=https%3A%2F%2Fopen.spotify.com%2F"

private const val LOGIN_USER_AGENT =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

private const val LOGIN_LAYOUT_FIX = """
    (function () {
      var id = 'vibramusic-login-layout-fix';
      if (document.getElementById(id)) return;
      var st = document.createElement('style');
      st.id = id;
      st.textContent =
        'html, body { height: auto !important; min-height: 100% !important; overflow: visible !important; }' +
        'body > div { height: auto !important; min-height: 100% !important; }' +
        'main { position: static !important; height: auto !important; min-height: 100dvh !important;' +
        ' max-height: none !important; overflow: visible !important; }';
      (document.head || document.documentElement).appendChild(st);
    })();
"""

/**
 * The signed-in Spotify account's playlists. A tap opens one as an ordinary
 * playlist page ([onOpenPlaylist]) — this screen is only the way in.
 */
@Composable
fun SpotifyLibraryScreen(
    onOpenPlaylist: (SpotifyPlaylist) -> Unit,
    onOpenLogin: () -> Unit,
    onOpenManualCookie: () -> Unit,
    contentPadding: PaddingValues,
    modifier: Modifier = Modifier,
) {
    val cookie by AppSettings.spotifySpdcToken.collectAsStateWithLifecycle()
    var playlists by remember { mutableStateOf<List<SpotifyPlaylist>>(emptyList()) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(cookie) {
        val builtIn = com.fortune.vibramusic.data.canvas.SpotifyTokenSecret.getBuiltInSpdc()
        if (cookie.isNotBlank() && cookie.trim() == builtIn) {
            clearSpotifyWebSession()
            AppSettings.setSpotifySpdcToken("")
            playlists = emptyList()
            error = null
            return@LaunchedEffect
        }
        if (cookie.isBlank()) {
            playlists = emptyList()
            error = null
            return@LaunchedEffect
        }
        loading = true
        error = null
        runCatching { SpotifyLibrary.playlists() }
            .onSuccess { playlists = it }
            .onFailure { error = it.message }
        loading = false
    }

    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = contentPadding,
    ) {
        item {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 8.dp, bottom = 14.dp),
            ) {
                Icon(
                    painter = painterResource(R.drawable.ic_spotify),
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onBackground,
                    modifier = Modifier.size(38.dp),
                )
                Spacer(Modifier.width(12.dp))
                Text(
                    text = stringResource(R.string.spotify),
                    style = MaterialTheme.typography.displayLarge,
                    color = MaterialTheme.colorScheme.onBackground,
                )
            }
        }
        if (cookie.isBlank()) {
            item {
                Column(Modifier.padding(horizontal = 20.dp)) {
                    Text(
                        text = stringResource(R.string.spotify_connect_subtitle),
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.height(16.dp))
                    Button(onClick = onOpenLogin) {
                        Text(stringResource(R.string.spotify_sign_in))
                    }
                    Spacer(Modifier.height(8.dp))
                    androidx.compose.material3.TextButton(onClick = onOpenManualCookie) {
                        Text(stringResource(R.string.integrate_spotify_canvas))
                    }
                }
            }
        } else {
            item {
                Text(
                    text = stringResource(R.string.spotify_library_subtitle),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 20.dp, vertical = 6.dp),
                )
            }
            if (loading) {
                item {
                    Box(Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator()
                    }
                }
            }
            error?.let { message ->
                item {
                    Text(
                        text = message,
                        color = MaterialTheme.colorScheme.error,
                        modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp),
                    )
                }
            }
            itemsIndexed(playlists, key = { index, item -> "${item.id}_$index" }) { _, item ->
                LibraryRow(
                    title = item.name,
                    subtitle = item.owner.orEmpty(),
                    imageUrl = item.imageUrl,
                    onClick = { onOpenPlaylist(item) },
                )
            }
        }
    }
}

@Composable
private fun LibraryRow(
    title: String,
    subtitle: String,
    imageUrl: String?,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 20.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        AsyncImage(
            model = imageUrl,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier.size(52.dp).clip(RoundedCornerShape(8.dp)),
        )
        Column(Modifier.weight(1f)) {
            Text(
                text = title,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onBackground,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (subtitle.isNotBlank()) {
                Text(
                    text = subtitle,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

private val SPOTIFY_COOKIE_URLS = listOf(
    "https://open.spotify.com",
    "https://accounts.spotify.com",
    "https://www.spotify.com",
    "https://spotify.com",
)

private val LOGIN_HOST_SUFFIXES = listOf(
    "spotify.com", "scdn.co", "google.com", "gstatic.com", "facebook.com", "apple.com",
)

private fun hostMatches(uri: Uri?, suffixes: List<String>): Boolean {
    if (uri?.scheme != "https") return false
    val host = uri.host?.lowercase() ?: return false
    return suffixes.any { host == it || host.endsWith(".$it") }
}

private fun isSpotifyHost(uri: Uri?) = hostMatches(uri, listOf("spotify.com"))

private fun isLoginHost(uri: Uri?) = hostMatches(uri, LOGIN_HOST_SUFFIXES)

/**
 * Signs the login WebView out of Spotify. Disconnecting only forgot the
 * stored cookie, and the WebView's own jar would have signed the next
 * "Sign in" straight back in. Only Spotify's cookies go — the same jar holds
 * the YouTube Music sign-in.
 */
fun clearSpotifyWebSession() {
    runCatching {
        val cookies = CookieManager.getInstance()
        for (url in SPOTIFY_COOKIE_URLS) {
            val names = cookies.getCookie(url)?.split(";")
                ?.map { it.substringBefore("=").trim() }
                ?.filter { it.isNotEmpty() }
                .orEmpty()
            for (name in names) {
                val expired = "$name=; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/"
                cookies.setCookie(url, expired)
                cookies.setCookie(url, "$expired; Domain=.spotify.com")
                cookies.setCookie(url, "$expired; Domain=spotify.com")
                cookies.setCookie(url, "$expired; Domain=.open.spotify.com")
                cookies.setCookie(url, "$expired; Domain=.accounts.spotify.com")
            }
            cookies.setCookie(url, "sp_dc=; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/; Domain=.spotify.com")
            cookies.setCookie(url, "sp_dc=; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/; Domain=spotify.com")
            cookies.setCookie(url, "sp_dc=; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/")
        }
        cookies.flush()
    }
}

@SuppressLint("SetJavaScriptEnabled")
@Composable
fun SpotifyLoginScreen(
    onConnected: (String) -> Unit,
    modifier: Modifier = Modifier,
    onManualCookieClick: (() -> Unit)? = null,
) {
    var sent by remember { mutableStateOf(false) }
    var webViewError by remember { mutableStateOf<String?>(null) }
    var showGoogleNoticeDialog by remember { mutableStateOf(false) }
    val context = LocalContext.current

    if (webViewError != null) {
        Box(modifier = modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
            Text(
                text = "Could not initialize web browser: $webViewError",
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodyLarge,
            )
        }
        return
    }

    if (showGoogleNoticeDialog) {
        AlertDialog(
            onDismissRequest = { showGoogleNoticeDialog = false },
            icon = {
                Icon(
                    Icons.Rounded.Info,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                )
            },
            title = {
                Text(stringResource(R.string.spotify_login_google_notice_title))
            },
            text = {
                Text(stringResource(R.string.spotify_login_google_notice_desc))
            },
            confirmButton = {
                Button(
                    onClick = {
                        showGoogleNoticeDialog = false
                        runCatching {
                            val intent = Intent(Intent.ACTION_VIEW, Uri.parse("https://www.spotify.com/password-reset"))
                            context.startActivity(intent)
                        }
                    },
                ) {
                    Text(stringResource(R.string.spotify_login_set_password))
                }
            },
            dismissButton = {
                TextButton(onClick = { showGoogleNoticeDialog = false }) {
                    Text(stringResource(R.string.close))
                }
            },
        )
    }

    Column(modifier = modifier.fillMaxSize()) {
        Card(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 6.dp),
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.7f),
            ),
        ) {
            Column(Modifier.padding(horizontal = 12.dp, vertical = 10.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        Icons.Rounded.Info,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(
                        text = stringResource(R.string.spotify_login_tip_banner_title),
                        style = MaterialTheme.typography.titleSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Spacer(Modifier.height(4.dp))
                Text(
                    text = stringResource(R.string.spotify_login_tip_banner_desc),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(6.dp))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    OutlinedButton(
                        onClick = {
                            runCatching {
                                val intent = Intent(Intent.ACTION_VIEW, Uri.parse("https://www.spotify.com/password-reset"))
                                context.startActivity(intent)
                            }
                        },
                        modifier = Modifier.weight(1f),
                    ) {
                        Text(
                            text = stringResource(R.string.spotify_login_set_password),
                            style = MaterialTheme.typography.labelSmall,
                        )
                    }
                    if (onManualCookieClick != null) {
                        TextButton(
                            onClick = onManualCookieClick,
                            modifier = Modifier.weight(1f),
                        ) {
                            Text(
                                text = stringResource(R.string.spotify_login_manual_cookie),
                                style = MaterialTheme.typography.labelSmall,
                            )
                        }
                    }
                }
            }
        }

        AndroidView(
            modifier = Modifier.weight(1f).fillMaxWidth(),
            factory = { ctx ->
                try {
                    clearSpotifyWebSession()
                    WebView(ctx).apply {
                        layoutParams = ViewGroup.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            ViewGroup.LayoutParams.MATCH_PARENT,
                        )
                        settings.javaScriptEnabled = true
                        settings.domStorageEnabled = true
                        settings.loadWithOverviewMode = true
                        settings.useWideViewPort = true
                        settings.userAgentString = LOGIN_USER_AGENT
                        if (Build.VERSION.SDK_INT >= 33) {
                            settings.isAlgorithmicDarkeningAllowed = false
                        } else if (Build.VERSION.SDK_INT >= 29) {
                            @Suppress("DEPRECATION")
                            settings.forceDark = WebSettings.FORCE_DARK_OFF
                        }
                        setBackgroundColor(0xFF121212.toInt())
                        CookieManager.getInstance().setAcceptCookie(true)
                        CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
                        webViewClient = object : WebViewClient() {
                            override fun shouldOverrideUrlLoading(
                                view: WebView,
                                request: WebResourceRequest,
                            ): Boolean {
                                val host = request.url.host?.lowercase().orEmpty()
                                val urlStr = request.url.toString()
                                if (host == "accounts.google.com" || host.endsWith(".accounts.google.com") || host == "google.com" || host.endsWith(".google.com") || urlStr.contains("/login/google") || urlStr.contains("api/login/google")) {
                                    showGoogleNoticeDialog = true
                                    return true
                                }
                                return !isLoginHost(request.url)
                            }

                            override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) {
                                super.onPageStarted(view, url, favicon)
                                val host = url?.toUri()?.host?.lowercase().orEmpty()
                                if (host == "accounts.google.com" || host.endsWith(".accounts.google.com")) {
                                    view.stopLoading()
                                    showGoogleNoticeDialog = true
                                    view.post { view.loadUrl(LOGIN_URL) }
                                }
                            }

                            override fun onPageFinished(view: WebView, url: String?) {
                                if (isSpotifyHost(url?.toUri())) view.evaluateJavascript(LOGIN_LAYOUT_FIX, null)
                                if (sent || url?.startsWith("https://open.spotify.com") != true) return
                                val raw = runCatching { CookieManager.getInstance().getCookie("https://open.spotify.com") }.getOrNull() ?: return
                                val token = raw.split(";")
                                    .map { it.trim() }
                                    .firstOrNull { it.startsWith("sp_dc=") }
                                    ?.substringAfter("=")
                                    ?.takeIf { it.isNotBlank() }
                                    ?: return
                                val builtIn = com.fortune.vibramusic.data.canvas.SpotifyTokenSecret.getBuiltInSpdc()
                                if (token == builtIn) {
                                    // Ignore built-in token if somehow present; wait for user's own credentials
                                    return
                                }
                                sent = true
                                onConnected(token)
                            }

                            override fun onRenderProcessGone(
                                view: WebView?,
                                detail: RenderProcessGoneDetail?,
                            ): Boolean {
                                webViewError = "Web browser process stopped. Please reopen this screen."
                                return true
                            }
                        }
                        loadUrl(LOGIN_URL)
                    }
                } catch (e: Throwable) {
                    webViewError = e.message ?: "Failed to initialize WebView"
                    android.view.View(ctx)
                }
            },
            onRelease = { view -> runCatching { (view as? WebView)?.destroy() } },
        )
    }
}
