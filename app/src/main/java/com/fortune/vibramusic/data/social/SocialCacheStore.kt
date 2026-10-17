package com.fortune.vibramusic.data.social

import android.content.Context
import com.fortune.vibramusic.data.DebugLog as Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File

/**
 * High-performance offline file cache for social posts and comments.
 * Ensures user content is permanently preserved across process terminations,
 * app restarts, and offline network situations.
 */
class SocialCacheStore(private val context: Context) {

    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        encodeDefaults = true
    }

    private val cacheDir = File(context.filesDir, "social_cache").apply { mkdirs() }
    private val postsFile = File(cacheDir, "cached_posts.json")

    suspend fun savePosts(posts: List<SocialPost>) = withContext(Dispatchers.IO) {
        runCatching {
            val text = json.encodeToString(posts)
            postsFile.writeText(text)
        }.onFailure { e ->
            Log.w("SocialCacheStore", "Failed to cache posts: ${e.message}")
        }
    }

    suspend fun loadPosts(): List<SocialPost> = withContext(Dispatchers.IO) {
        runCatching {
            if (!postsFile.exists()) return@withContext emptyList()
            val text = postsFile.readText()
            if (text.isBlank()) return@withContext emptyList()
            json.decodeFromString<List<SocialPost>>(text)
        }.getOrDefault(emptyList())
    }

    suspend fun saveComments(postId: String, comments: List<PostComment>) = withContext(Dispatchers.IO) {
        runCatching {
            val file = File(cacheDir, "comments_$postId.json")
            val text = json.encodeToString(comments)
            file.writeText(text)
        }.onFailure { e ->
            Log.w("SocialCacheStore", "Failed to cache comments for $postId: ${e.message}")
        }
    }

    suspend fun loadComments(postId: String): List<PostComment> = withContext(Dispatchers.IO) {
        runCatching {
            val file = File(cacheDir, "comments_$postId.json")
            if (!file.exists()) return@withContext emptyList()
            val text = file.readText()
            if (text.isBlank()) return@withContext emptyList()
            json.decodeFromString<List<PostComment>>(text)
        }.getOrDefault(emptyList())
    }
}
