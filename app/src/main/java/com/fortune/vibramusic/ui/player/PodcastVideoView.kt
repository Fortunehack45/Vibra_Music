package com.fortune.vibramusic.ui.player

import android.annotation.SuppressLint
import android.graphics.Color as AndroidColor
import android.view.ViewGroup
import android.webkit.WebChromeClient
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.viewinterop.AndroidView
import kotlin.math.abs

/**
 * Embedded silent video renderer for YouTube podcasts and video songs.
 *
 * Runs muted in an isolated WebView using YouTube's IFrame API so it remains
 * precisely in sync with ExoPlayer's playback position and transport state,
 * while leaving the uninterrupted background audio engine entirely untouched.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun PodcastVideoView(
    videoId: String,
    isPlaying: Boolean,
    positionMs: Long,
    modifier: Modifier = Modifier,
) {
    var webViewRef by remember { mutableStateOf<WebView?>(null) }
    var lastSyncedPositionSec by remember { mutableLongStateOf(-1L) }

    val htmlContent = remember(videoId) {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <style>
          * { margin: 0; padding: 0; box-sizing: border-box; background-color: #000; overflow: hidden; }
          html, body { width: 100%; height: 100%; background: #000; }
          #player { width: 100%; height: 100%; position: absolute; top: 0; left: 0; }
        </style>
        </head>
        <body>
        <div id="player"></div>
        <script>
          var tag = document.createElement('script');
          tag.src = "https://www.youtube.com/iframe_api";
          var firstScriptTag = document.getElementsByTagName('script')[0];
          firstScriptTag.parentNode.insertBefore(tag, firstScriptTag);

          var player;
          var isReady = false;
          function onYouTubeIframeAPIReady() {
            player = new YT.Player('player', {
              videoId: '$videoId',
              playerVars: {
                'autoplay': 1,
                'controls': 0,
                'disablekb': 1,
                'fs': 0,
                'modestbranding': 1,
                'playsinline': 1,
                'rel': 0,
                'showinfo': 0,
                'iv_load_policy': 3,
                'mute': 1
              },
              events: {
                'onReady': function(event) {
                  isReady = true;
                  event.target.mute();
                  ${if (isPlaying) "event.target.playVideo();" else "event.target.pauseVideo();"}
                  event.target.seekTo(${positionMs / 1000}, true);
                }
              }
            });
          }

          function syncState(playing, seconds) {
            if (!isReady || !player) return;
            if (playing) {
              player.playVideo();
            } else {
              player.pauseVideo();
            }
            try {
              var current = player.getCurrentTime();
              if (Math.abs(current - seconds) > 2) {
                player.seekTo(seconds, true);
              }
            } catch(e) {}
          }
        </script>
        </body>
        </html>
        """.trimIndent()
    }

    LaunchedEffect(isPlaying, positionMs, webViewRef) {
        val wv = webViewRef ?: return@LaunchedEffect
        val currentSec = positionMs / 1000
        if (abs(currentSec - lastSyncedPositionSec) >= 2 || !isPlaying) {
            wv.evaluateJavascript("syncState($isPlaying, $currentSec);", null)
            lastSyncedPositionSec = currentSec
        }
    }

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(Color.Black),
    ) {
        AndroidView(
            factory = { context ->
                WebView(context).apply {
                    layoutParams = ViewGroup.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT,
                    )
                    setBackgroundColor(AndroidColor.BLACK)
                    settings.apply {
                        javaScriptEnabled = true
                        mediaPlaybackRequiresUserGesture = false
                        domStorageEnabled = true
                        cacheMode = WebSettings.LOAD_DEFAULT
                    }
                    webChromeClient = WebChromeClient()
                    webViewClient = object : WebViewClient() {}
                    loadDataWithBaseURL("https://www.youtube.com", htmlContent, "text/html", "UTF-8", null)
                    webViewRef = this
                }
            },
            update = { wv ->
                webViewRef = wv
            },
            modifier = Modifier.fillMaxSize(),
        )
    }

    DisposableEffect(videoId) {
        onDispose {
            webViewRef?.destroy()
            webViewRef = null
        }
    }
}
