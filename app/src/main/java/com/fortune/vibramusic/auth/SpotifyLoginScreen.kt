package com.fortune.vibramusic.auth

import android.annotation.SuppressLint
import android.content.Intent
import android.net.Uri
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebStorage
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.fortune.vibramusic.R
import com.fortune.vibramusic.data.canvas.TokenProvider
import kotlinx.coroutines.delay

private const val LOGIN_URL =
    "https://accounts.spotify.com/login?continue=https%3A%2F%2Fopen.spotify.com%2F"

private val SPOTIFY_COOKIE_URLS = listOf(
    "https://open.spotify.com",
    "https://accounts.spotify.com",
    "https://www.spotify.com",
    "https://spotify.com",
)

private val LOGIN_HOST_SUFFIXES = listOf(
    "spotify.com",
    "spotifycdn.com",
    "spotifycdn.net",
    "scdn.co",
    "spclient.wg.spotify.com",
    "google.com",
    "gstatic.com",
    "googleusercontent.com",
    "facebook.com",
    "fbcdn.net",
    "apple.com",
    "appleid.apple.com",
    "akamaized.net",
    "arkoselabs.com",
    "arkoselabs.net",
    "funcaptcha.com",
    "recaptcha.net",
    "doubleclick.net",
    "cloudflare.com",
    "challenges.cloudflare.com",
)

/**
 * Standard Chrome Mobile UA on Android without manufacturer-specific tags (ColorOS, HeyTap,
 * MIUI) that trip Spotify's Cloudflare / Akamai bot-defense checks.
 */
private const val STANDARD_MOBILE_CHROME_UA =
    "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"

private fun hostMatches(uri: Uri?, suffixes: List<String>): Boolean {
    val host = uri?.host?.lowercase() ?: return false
    return suffixes.any { host == it || host.endsWith(".$it") }
}

private fun isLoginHost(uri: Uri?) = hostMatches(uri, LOGIN_HOST_SUFFIXES)

/**
 * Signs the login WebView out of Spotify. Disconnecting only forgot the
 * stored cookie, and the WebView's own jar would have signed the next
 * "Sign in" straight back in. Only Spotify's cookies and WebStorage go — the same jar
 * holds the YouTube Music sign-in.
 */
fun clearSpotifyWebSession() {
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
        }
    }
    cookies.flush()

    runCatching {
        val storage = WebStorage.getInstance()
        storage.deleteOrigin("https://accounts.spotify.com")
        storage.deleteOrigin("https://open.spotify.com")
        storage.deleteOrigin("https://www.spotify.com")
        storage.deleteOrigin("https://spotify.com")
    }
}

/**
 * In-app Spotify sign-in. Lets the real accounts.spotify.com page handle the
 * login, then hands the `sp_dc` cookie to [onConnected] once the page lands on
 * open.spotify.com or sets the session cookie.
 *
 * Must be hosted as a root overlay, like [DiscordLoginScreen], never inside the
 * page content: that subtree is the `hazeSource` and the glass backdrop, both of
 * which record it into a layer and draw it a second time. A WebView drawn twice
 * flickers, drops parts of the page, and on some devices takes the app down in
 * Chromium's draw functor.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun SpotifyLoginScreen(
    onConnected: (String) -> Unit,
    modifier: Modifier = Modifier,
    onManualCookieClick: (() -> Unit)? = null,
) {
    var webView by remember { mutableStateOf<WebView?>(null) }
    var canGoBack by remember { mutableStateOf(false) }
    var sent by remember { mutableStateOf(false) }

    fun checkAndHarvestCookie(view: WebView? = webView): Boolean {
        if (sent) return true
        val cookieJar = CookieManager.getInstance()
        val raw = SPOTIFY_COOKIE_URLS.firstNotNullOfOrNull { u ->
            cookieJar.getCookie(u)?.takeIf { it.contains("sp_dc=") }
        } ?: return false

        val token = raw.split(";")
            .map { it.trim() }
            .firstOrNull { it.startsWith("sp_dc=") }
            ?.substringAfter("=")
            ?.trim('"', '\'', ';', ' ')
            ?.takeIf { it.isNotBlank() }
            ?: return false

        val builtIn = TokenProvider.getSpdcToken()
        if (builtIn != null && token == builtIn) {
            // Do not harvest the fallback service token as a user login
            return false
        }

        sent = true
        view?.visibility = View.GONE
        onConnected(token)
        return true
    }

    LaunchedEffect(Unit) {
        while (!sent) {
            delay(500)
            checkAndHarvestCookie()
        }
    }

    Column(modifier = modifier.fillMaxSize()) {
        Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
            AndroidView(
                modifier = Modifier.fillMaxSize(),
                factory = { context ->
                    WebView(context).apply {
                        layoutParams = ViewGroup.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            ViewGroup.LayoutParams.MATCH_PARENT,
                        )
                        clearSpotifyWebSession()
                        clearCache(true)
                        clearFormData()

                        settings.javaScriptEnabled = true
                        settings.domStorageEnabled = true
                        settings.databaseEnabled = true
                        settings.useWideViewPort = true
                        settings.loadWithOverviewMode = true
                        settings.javaScriptCanOpenWindowsAutomatically = true
                        settings.setSupportMultipleWindows(false)
                        settings.mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
                        settings.cacheMode = WebSettings.LOAD_DEFAULT
                        settings.userAgentString = STANDARD_MOBILE_CHROME_UA

                        setBackgroundColor(0xFF121212.toInt())
                        webChromeClient = WebChromeClient()

                        CookieManager.getInstance().setAcceptCookie(true)
                        CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)

                        webViewClient = object : WebViewClient() {
                            override fun shouldOverrideUrlLoading(
                                view: WebView,
                                request: WebResourceRequest,
                            ): Boolean {
                                checkAndHarvestCookie(view)
                                if (!request.isForMainFrame) return false
                                val uri = request.url ?: return false
                                val scheme = uri.scheme?.lowercase() ?: return false
                                if (scheme != "http" && scheme != "https") {
                                    return true
                                }
                                val host = uri.host?.lowercase() ?: return false
                                if (host.contains("accounts.google.com")) {
                                    // Google OAuth blocks Android embedded WebViews with disallowed_useragent
                                    runCatching {
                                        val intent = Intent(Intent.ACTION_VIEW, uri)
                                        view.context.startActivity(intent)
                                    }
                                    return true
                                }
                                if (!isLoginHost(uri)) {
                                    // Open external links (Help, Terms, Privacy) in external browser
                                    runCatching {
                                        val intent = Intent(Intent.ACTION_VIEW, uri)
                                        view.context.startActivity(intent)
                                    }
                                    return true
                                }
                                return false
                            }

                            override fun onPageStarted(view: WebView, url: String?, favicon: android.graphics.Bitmap?) {
                                super.onPageStarted(view, url, favicon)
                                canGoBack = view.canGoBack()
                                checkAndHarvestCookie(view)
                            }

                            override fun doUpdateVisitedHistory(view: WebView?, url: String?, isReload: Boolean) {
                                super.doUpdateVisitedHistory(view, url, isReload)
                                checkAndHarvestCookie(view)
                            }

                            override fun onPageFinished(view: WebView, url: String?) {
                                canGoBack = view.canGoBack()
                                checkAndHarvestCookie(view)
                            }
                        }
                        webView = this
                        loadUrl(LOGIN_URL)
                    }
                },
                onRelease = { it.destroy() },
            )
        }

        if (onManualCookieClick != null) {
            TextButton(
                onClick = onManualCookieClick,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 6.dp),
            ) {
                Text(
                    text = stringResource(R.string.integrate_spotify_canvas),
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
        }
    }

    BackHandler(enabled = canGoBack) {
        webView?.goBack()
    }
}
