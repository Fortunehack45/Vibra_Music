package com.fortune.vibramusic.data.supabase

import com.fortune.vibramusic.BuildConfig

/**
 * Configuration for Supabase backend.
 * Provides the Project URL and Anon API Key.
 *
 * NOTE: Credentials must be provided via BuildConfig (e.g. from local.properties
 * or CI repository environment variables). No real credentials are hardcoded in source.
 * When unconfigured, [isConfigured] evaluates to false and cloud sync/social functions
 * gracefully degrade without crashing.
 */
object SupabaseConfig {

    val url: String = try {
        BuildConfig.SUPABASE_URL.trim()
    } catch (_: Throwable) {
        ""
    }

    val anonKey: String = try {
        BuildConfig.SUPABASE_ANON_KEY.trim()
    } catch (_: Throwable) {
        ""
    }

    val isConfigured: Boolean
        get() = url.isNotBlank() && anonKey.isNotBlank()
}
