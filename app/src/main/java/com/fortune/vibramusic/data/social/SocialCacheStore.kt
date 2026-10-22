package com.fortune.vibramusic.data.social

import android.content.Context
import com.fortune.vibramusic.data.DebugLog as Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.withLock
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
    private val storiesFile = File(cacheDir, "cached_stories.json")
    private val mutex = kotlinx.coroutines.sync.Mutex()

    private fun atomicWrite(target: File, content: String) {
        val tmp = File(target.parentFile, "${target.name}.tmp")
        tmp.writeText(content)
        if (!tmp.renameTo(target)) {
            target.delete()
            tmp.renameTo(target)
        }
    }

    suspend fun savePosts(posts: List<SocialPost>) = withContext(Dispatchers.IO) {
        mutex.withLock {
            runCatching {
                val text = json.encodeToString(posts)
                atomicWrite(postsFile, text)
            }.onFailure { e ->
                Log.w("SocialCacheStore", "Failed to cache posts: ${e.message}")
            }
        }
    }

    suspend fun loadPosts(): List<SocialPost> = withContext(Dispatchers.IO) {
        mutex.withLock {
            runCatching {
                if (!postsFile.exists()) {
                    emptyList()
                } else {
                    val text = postsFile.readText()
                    if (text.isBlank()) emptyList() else json.decodeFromString<List<SocialPost>>(text)
                }
            }.getOrDefault(emptyList())
        }
    }

    suspend fun saveComments(postId: String, comments: List<PostComment>) = withContext(Dispatchers.IO) {
        mutex.withLock {
            runCatching {
                val file = File(cacheDir, "comments_$postId.json")
                val text = json.encodeToString(comments)
                atomicWrite(file, text)
            }.onFailure { e ->
                Log.w("SocialCacheStore", "Failed to cache comments for $postId: ${e.message}")
            }
        }
    }

    suspend fun loadComments(postId: String): List<PostComment> = withContext(Dispatchers.IO) {
        mutex.withLock {
            runCatching {
                val file = File(cacheDir, "comments_$postId.json")
                if (!file.exists()) {
                    emptyList()
                } else {
                    val text = file.readText()
                    if (text.isBlank()) emptyList() else json.decodeFromString<List<PostComment>>(text)
                }
            }.getOrDefault(emptyList())
        }
    }

    suspend fun saveProfile(profile: SocialProfile) = withContext(Dispatchers.IO) {
        mutex.withLock {
            runCatching {
                val file = File(cacheDir, "profile_${profile.id}.json")
                val text = json.encodeToString(profile)
                atomicWrite(file, text)
            }.onFailure { e ->
                Log.w("SocialCacheStore", "Failed to cache profile ${profile.id}: ${e.message}")
            }
        }
    }

    suspend fun saveLastActiveProfile(profile: SocialProfile) = withContext(Dispatchers.IO) {
        saveProfile(profile)
        mutex.withLock {
            runCatching {
                val file = File(cacheDir, "last_active_profile.json")
                val text = json.encodeToString(profile)
                atomicWrite(file, text)
            }
        }
    }

    suspend fun loadLastActiveProfile(): SocialProfile? = withContext(Dispatchers.IO) {
        mutex.withLock {
            runCatching {
                val file = File(cacheDir, "last_active_profile.json")
                if (file.exists()) {
                    val text = file.readText()
                    if (text.isNotBlank()) json.decodeFromString<SocialProfile>(text) else null
                } else null
            }.getOrNull()
        }
    }

    suspend fun loadProfile(userId: String): SocialProfile? = withContext(Dispatchers.IO) {
        mutex.withLock {
            runCatching {
                val file = File(cacheDir, "profile_${userId}.json")
                if (!file.exists()) {
                    null
                } else {
                    val text = file.readText()
                    if (text.isBlank()) null else json.decodeFromString<SocialProfile>(text)
                }
            }.getOrNull()
        }
    }

    private val pollVotesFile = File(cacheDir, "user_poll_votes.json")

    suspend fun saveUserPollVote(postId: String, optionIndex: Int) = withContext(Dispatchers.IO) {
        mutex.withLock {
            runCatching {
                val current = loadUserPollVotesInternal().toMutableMap()
                current[postId] = optionIndex
                val text = json.encodeToString(current)
                atomicWrite(pollVotesFile, text)
            }.onFailure { e ->
                Log.w("SocialCacheStore", "Failed to cache poll vote: ${e.message}")
            }
        }
    }

    suspend fun getUserPollVotes(): Map<String, Int> = withContext(Dispatchers.IO) {
        mutex.withLock {
            loadUserPollVotesInternal()
        }
    }

    private fun loadUserPollVotesInternal(): Map<String, Int> {
        return runCatching {
            if (!pollVotesFile.exists()) emptyMap()
            else {
                val text = pollVotesFile.readText()
                if (text.isBlank()) emptyMap() else json.decodeFromString<Map<String, Int>>(text)
            }
        }.getOrDefault(emptyMap())
    }

    suspend fun saveStories(stories: List<UserStory>) = withContext(Dispatchers.IO) {
        mutex.withLock {
            runCatching {
                val text = json.encodeToString(stories)
                atomicWrite(storiesFile, text)
            }.onFailure { e ->
                Log.w("SocialCacheStore", "Failed to cache stories: ${e.message}")
            }
        }
    }

    suspend fun loadStories(): List<UserStory> = withContext(Dispatchers.IO) {
        mutex.withLock {
            runCatching {
                if (!storiesFile.exists()) {
                    emptyList()
                } else {
                    val text = storiesFile.readText()
                    if (text.isBlank()) emptyList() else json.decodeFromString<List<UserStory>>(text)
                }
            }.getOrDefault(emptyList())
        }
    }
}
