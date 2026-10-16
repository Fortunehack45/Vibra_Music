package com.fortune.vibramusic.data.supabase

import android.content.Context
import com.fortune.vibramusic.BuildConfig

/**
 * Configuration for Supabase backend.
 * Provides the Project URL and Anon API Key.
 */
object SupabaseConfig {

    // Default configuration points to the Vibra Music Supabase cloud instance.
    // Can be overridden via local.properties or BuildConfig at build time.
    val url: String
        get() = try {
            val field = BuildConfig::class.java.getField("SUPABASE_URL")
            field.get(null) as? String ?: DEFAULT_URL
        } catch (_: Exception) {
            DEFAULT_URL
        }

    val anonKey: String
        get() = try {
            val field = BuildConfig::class.java.getField("SUPABASE_ANON_KEY")
            field.get(null) as? String ?: DEFAULT_KEY
        } catch (_: Exception) {
            DEFAULT_KEY
        }

    const val DEFAULT_URL = "https://yinaxpgnnadhbkplokvl.supabase.co"
    const val DEFAULT_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InlpbmF4cGdubmFkaGJrcGxva3ZsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTIxNTYxNDQsImV4cCI6MjEwNzczMjE0NH0.PtGQ_Yy4X-bKEPaukfydrlABsZKiYrzSfQ_Awz5075g"

    val isConfigured: Boolean
        get() = url.isNotBlank() && anonKey.isNotBlank()
}
