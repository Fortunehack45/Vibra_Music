package com.fortune.vibramusic.data.canvas

/**
 * Provides access to a Spotify service token (sp_dc) at runtime,
 * decoupling the app from any embedded secrets or hardcoded literals.
 */
fun interface TokenProvider {

    fun getSpdcToken(): String?

    companion object {
        var current: TokenProvider = DefaultTokenProvider
        fun getSpdcToken(): String? = current.getSpdcToken()
    }
}
