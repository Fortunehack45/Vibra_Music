package com.fortune.vibramusic.data.canvas

import com.fortune.vibramusic.BuildConfig

/**
 * Default implementation of [TokenProvider].
 *
 * 1. Reads [BuildConfig.SPOTIFY_SPDC], which is injected at build time via
 *    local.properties or CI repository environment variables.
 * 2. If absent or blank, falls back to reflective desktop secret store lookup on desktop targets.
 * 3. Returns null if no token is configured.
 */
object DefaultTokenProvider : TokenProvider {

    override fun getSpdcToken(): String? {
        val buildConfigToken = try {
            BuildConfig.SPOTIFY_SPDC.trim().takeIf { it.isNotBlank() }
        } catch (_: Throwable) {
            null
        }
        if (buildConfigToken != null) return buildConfigToken

        // Fallback for desktop runtime or reflective lookup on supported platforms
        return runCatching {
            val clazz = Class.forName("com.fortune.vibramusic.desktop.DesktopSecretStore")
            val method = clazz.getMethod("lookupSpotifySpdc")
            val instance = clazz.getField("INSTANCE").get(null)
            method.invoke(instance) as? String
        }.getOrNull()
    }
}
