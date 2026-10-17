package com.fortune.vibramusic.data.supabase

import com.fortune.vibramusic.BuildConfig

/**
 * Configuration for Supabase backend.
 * Provides the Project URL and Anon API Key.
 *
 * TODO: The schema currently has `using (true) with check (true)` on every table,
 * meaning anyone with the anon key can read/write/delete everything, including
 * `spotify_spdc_token` in `user_listening_experience`. This needs real auth-based RLS,
 * and `spotify_spdc_token` should be moved out of anon-readable access as a follow-up.
 */
object SupabaseConfig {

    const val DEFAULT_URL = "https://yinaxpgnnadhbkplokvl.supabase.co"
    const val DEFAULT_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InlpbmF4cGdubmFkaGJrcGxva3ZsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTIxNTYxNDQsImV4cCI6MjEwNzczMjE0NH0.PtGQ_Yy4X-bKEPaukfydrlABsZKiYrzSfQ_Awz5075g"

    val url: String = try {
        BuildConfig.SUPABASE_URL.takeIf { it.isNotBlank() } ?: DEFAULT_URL
    } catch (_: Exception) {
        DEFAULT_URL
    }

    val anonKey: String = try {
        BuildConfig.SUPABASE_ANON_KEY.takeIf { it.isNotBlank() } ?: DEFAULT_KEY
    } catch (_: Exception) {
        DEFAULT_KEY
    }

    val isConfigured: Boolean
        get() = url.isNotBlank() && anonKey.isNotBlank()
}
