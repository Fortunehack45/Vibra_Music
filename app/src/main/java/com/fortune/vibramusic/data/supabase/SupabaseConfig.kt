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

    val url: String = try {
        BuildConfig.SUPABASE_URL
    } catch (_: Exception) {
        ""
    }

    val anonKey: String = try {
        BuildConfig.SUPABASE_ANON_KEY
    } catch (_: Exception) {
        ""
    }

    val isConfigured: Boolean
        get() = url.isNotBlank() && anonKey.isNotBlank()
}
