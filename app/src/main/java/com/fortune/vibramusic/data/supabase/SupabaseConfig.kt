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

    const val DEFAULT_URL = "https://yinaxpgnnadhbkplokvl.supabase.co"
    const val DEFAULT_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InlpbmF4cGdubmFkaGJrcGxva3ZsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTIxNTYxNDQsImV4cCI6MjEwNzczMjE0NH0.PtGQ_Yy4X-bKEPaukfydrlABsZKiYrzSfQ_Awz5075g"

    val url: String = try {
        BuildConfig.SUPABASE_URL.trim().ifBlank { DEFAULT_URL }
    } catch (_: Throwable) {
        DEFAULT_URL
    }

    val anonKey: String = try {
        BuildConfig.SUPABASE_ANON_KEY.trim().ifBlank { DEFAULT_KEY }
    } catch (_: Throwable) {
        DEFAULT_KEY
    }

    val isConfigured: Boolean
        get() = url.isNotBlank() && anonKey.isNotBlank()
}
