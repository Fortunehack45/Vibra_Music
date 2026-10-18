package com.fortune.vibramusic.data.canvas

/**
 * Cross-module interface for resolving runtime Spotify sp_dc tokens.
 */
fun interface TokenProvider {
    fun getSpdcToken(): String?
}
