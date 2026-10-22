package com.fortune.vibramusic.data.supabase

import com.fortune.vibramusic.auth.GoogleAccountSession
import com.fortune.vibramusic.auth.YouTubeProfile
import com.fortune.vibramusic.data.DebugLog as Log
import com.fortune.vibramusic.data.quiz.LeaderboardEntry
import com.fortune.vibramusic.data.quiz.QuizArtist
import com.fortune.vibramusic.data.quiz.QuizScoreResult
import com.fortune.vibramusic.data.model.Song
import com.fortune.vibramusic.data.model.UserPlaylist
import com.fortune.vibramusic.data.social.ConversationSummary
import com.fortune.vibramusic.data.social.DirectMessage
import com.fortune.vibramusic.data.social.FavoriteArtist
import com.fortune.vibramusic.data.social.Friendship
import com.fortune.vibramusic.data.social.FriendshipStatus
import com.fortune.vibramusic.data.social.MusicTrackAttachment
import com.fortune.vibramusic.data.social.NotificationType
import com.fortune.vibramusic.data.social.PollData
import com.fortune.vibramusic.data.social.PollOption
import com.fortune.vibramusic.data.social.PostComment
import com.fortune.vibramusic.data.social.SharedPlaylistAttachment
import com.fortune.vibramusic.data.social.SocialNotification
import com.fortune.vibramusic.data.social.SocialPost
import com.fortune.vibramusic.data.social.SocialProfile
import com.fortune.vibramusic.data.social.UserListeningExperience
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.request.delete
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.parameter
import io.ktor.client.request.patch
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import io.ktor.serialization.kotlinx.json.json
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import java.util.UUID

/**
 * Service managing all interactions with Supabase PostgREST endpoints.
 */
object SupabaseService {

    private const val TAG = "SupabaseService"

    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        encodeDefaults = true
    }

    private val client = HttpClient(OkHttp) {
        install(ContentNegotiation) {
            json(json)
        }
    }

    private fun baseUrl(table: String): String {
        val root = SupabaseConfig.url.trim().trimEnd('/')
        check(root.isNotBlank()) { "Supabase URL is not configured" }
        return "$root/rest/v1/$table"
    }

    // ---- Null-safe JSON Accessors --------------------------------------------

    private fun JsonObject.str(key: String): String? =
        (this[key] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content

    private fun JsonObject.int(key: String): Int? =
        (this[key] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.intOrNull

    private fun JsonObject.bool(key: String): Boolean? =
        (this[key] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.booleanOrNull

    private fun JsonObject.double(key: String): Double? =
        (this[key] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.doubleOrNull

    private fun JsonObject.obj(key: String): JsonObject? = this[key] as? JsonObject
    private fun JsonObject.arr(key: String): JsonArray? = this[key] as? JsonArray

    private fun JsonObject.embeddedProfile(key: String = "profiles"): JsonObject? =
        (this[key] as? JsonObject) ?: (this[key] as? JsonArray)?.firstOrNull() as? JsonObject

    /**
     * Synchronizes the user's active YouTube identity into Supabase profiles table.
     * Preserves any existing custom profile attributes (handle, display name, avatar, bio, banner)
     * so they are never overwritten by YouTube channel information.
     */
    suspend fun syncUserProfile(
        session: GoogleAccountSession,
        profile: YouTubeProfile?,
    ): Result<SocialProfile> = withContext(Dispatchers.IO) {
        runCatching {
            val userId = profile?.profileId ?: session.accountId
            // Check existing profile in database first to preserve custom Vibra profile settings
            val existing = fetchUserProfile(userId).getOrNull()
            if (existing != null) {
                return@runCatching existing
            }

            val handle = profile?.handle?.takeIf { it.isNotBlank() }
                ?: (profile?.name ?: session.name)
                    .lowercase()
                    .replace("[^a-z0-9_]".toRegex(), "")
                    .takeIf { it.isNotBlank() }
                ?: "listener_${userId.takeLast(6)}"

            val displayName = profile?.name?.takeIf { it.isNotBlank() }
                ?: session.name.takeIf { it.isNotBlank() }
                ?: "Vibra Listener"

            val avatarUrl = profile?.avatar

            val body = buildString {
                append("{")
                append("\"id\":\"$userId\",")
                append("\"handle\":\"$handle\",")
                append("\"display_name\":${jsonQuote(displayName)},")
                if (avatarUrl != null) append("\"avatar_url\":${jsonQuote(avatarUrl)},")
                append("\"referral_code\":\"vibra_${userId.takeLast(6)}\"")
                append("}")
            }

            val response = client.post("${baseUrl("profiles")}?on_conflict=id") {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                header("Prefer", "resolution=merge-duplicates,return=representation")
                contentType(ContentType.Application.Json)
                setBody(body)
            }

            if (!response.status.isSuccess()) {
                val errorText = response.bodyAsText().take(300)
                Log.w(TAG, "syncUserProfile returned status ${response.status}: $errorText")
            }

            SocialProfile(
                id = userId,
                handle = handle,
                displayName = displayName,
                avatarUrl = avatarUrl,
                referralCode = "vibra_${userId.takeLast(6)}",
            )
        }
    }

    /**
     * Fetches public posts for either the For You or Friends feed with user like states.
     */
    suspend fun fetchPosts(
        forUserId: String? = null,
        friendsOnly: Boolean = false,
        limit: Int = 30,
        offset: Int = 0,
    ): Result<List<SocialPost>> = withContext(Dispatchers.IO) {
        runCatching {
            coroutineScope {
                val postsDeferred = async {
                    val url = baseUrl("posts")
                    client.get(url) {
                        header("apikey", SupabaseConfig.anonKey)
                        header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                        parameter("select", "*,profiles:author_id(*)")
                        parameter("order", "created_at.desc")
                        parameter("limit", limit)
                        parameter("offset", offset)
                    }
                }

                val likesDeferred = async {
                    if (!forUserId.isNullOrBlank()) {
                        runCatching {
                            val likesRes = client.get(baseUrl("post_likes")) {
                                header("apikey", SupabaseConfig.anonKey)
                                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                                parameter("user_id", "eq.$forUserId")
                                parameter("select", "post_id")
                            }
                            if (likesRes.status.isSuccess()) {
                                val arr = json.parseToJsonElement(likesRes.bodyAsText()) as? JsonArray
                                arr?.mapNotNull { (it as? JsonObject)?.str("post_id") }?.toSet() ?: emptySet()
                            } else emptySet()
                        }.getOrDefault(emptySet())
                    } else emptySet()
                }

                val pollVotesDeferred = async {
                    if (!forUserId.isNullOrBlank()) {
                        runCatching {
                            val pollRes = client.get(baseUrl("poll_votes")) {
                                header("apikey", SupabaseConfig.anonKey)
                                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                                parameter("user_id", "eq.$forUserId")
                                parameter("select", "post_id,option_index")
                            }
                            if (pollRes.status.isSuccess()) {
                                val arr = json.parseToJsonElement(pollRes.bodyAsText()) as? JsonArray
                                arr?.mapNotNull { el ->
                                    val o = el as? JsonObject ?: return@mapNotNull null
                                    val pid = o.str("post_id") ?: return@mapNotNull null
                                    val optIdx = o.int("option_index") ?: return@mapNotNull null
                                    pid to optIdx
                                }?.toMap() ?: emptyMap()
                            } else emptyMap()
                        }.getOrDefault(emptyMap())
                    } else emptyMap()
                }

                val response = postsDeferred.await()
                if (!response.status.isSuccess()) {
                    val errorText = response.bodyAsText().take(300)
                    Log.w(TAG, "fetchPosts failed with ${response.status}: $errorText")
                    throw RuntimeException("HTTP ${response.status.value}: $errorText")
                }

                val likedPostIds = likesDeferred.await()
                val userPollVotes = pollVotesDeferred.await()
                val rawPosts = parsePosts(response.bodyAsText(), forUserId ?: "", likedPostIds, userPollVotes)
                resolveReferencedPosts(rawPosts, forUserId ?: "", likedPostIds, userPollVotes)
            }
        }
    }

    private suspend fun resolveReferencedPosts(
        posts: List<SocialPost>,
        currentUserId: String,
        userLikedPostIds: Set<String> = emptySet(),
        userPollVotes: Map<String, Int> = emptyMap(),
    ): List<SocialPost> {
        val missingIds = posts.mapNotNull { it.repostOfId }.plus(posts.mapNotNull { it.quoteOfId })
            .filter { refId -> posts.none { it.id == refId } }
            .distinct()

        val resolvedMap = posts.associateBy { it.id }.toMutableMap()

        if (missingIds.isNotEmpty()) {
            runCatching {
                val idFilter = PostgrestSanitizer.buildSafeInFilter(missingIds)
                val response = client.get(baseUrl("posts")) {
                    header("apikey", SupabaseConfig.anonKey)
                    header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                    parameter("id", idFilter)
                    parameter("select", "*,profiles:author_id(*)")
                }
                if (response.status.isSuccess()) {
                    val batch = parsePosts(response.bodyAsText(), currentUserId, userLikedPostIds, userPollVotes)
                    batch.forEach { resolvedMap[it.id] = it }
                }
            }
        }

        return posts.map { post ->
            val origRepost = post.repostOfId?.let { resolvedMap[it] }
            val origQuote = post.quoteOfId?.let { resolvedMap[it] }
            post.copy(repostOf = origRepost, quoteOf = origQuote)
        }
    }

    /**
     * Fetches posts authored by a specific user with accurate like state.
     */
    suspend fun fetchUserPosts(userId: String, currentUserId: String = ""): Result<List<SocialPost>> = withContext(Dispatchers.IO) {
        runCatching {
            val response = client.get(baseUrl("posts")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("author_id", "eq.$userId")
                parameter("select", "*,profiles:author_id(*)")
                parameter("order", "created_at.desc")
            }
            if (!response.status.isSuccess()) {
                val errorText = response.bodyAsText().take(300)
                Log.w(TAG, "fetchUserPosts ${response.status}: $errorText")
                return@runCatching emptyList()
            }
            val activeUser = currentUserId.ifBlank { userId }
            val likedPostIds = if (activeUser.isNotBlank()) {
                runCatching {
                    val likesRes = client.get(baseUrl("post_likes")) {
                        header("apikey", SupabaseConfig.anonKey)
                        header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                        parameter("user_id", "eq.$activeUser")
                        parameter("select", "post_id")
                    }
                    if (likesRes.status.isSuccess()) {
                        val arr = json.parseToJsonElement(likesRes.bodyAsText()) as? JsonArray
                        arr?.mapNotNull { (it as? JsonObject)?.str("post_id") }?.toSet() ?: emptySet()
                    } else emptySet()
                }.getOrDefault(emptySet())
            } else emptySet()

            val userPollVotes = if (activeUser.isNotBlank()) {
                runCatching {
                    val pollRes = client.get(baseUrl("poll_votes")) {
                        header("apikey", SupabaseConfig.anonKey)
                        header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                        parameter("user_id", "eq.$activeUser")
                        parameter("select", "post_id,option_index")
                    }
                    if (pollRes.status.isSuccess()) {
                        val arr = json.parseToJsonElement(pollRes.bodyAsText()) as? JsonArray
                        arr?.mapNotNull { el ->
                            val o = el as? JsonObject ?: return@mapNotNull null
                            val pid = o.str("post_id") ?: return@mapNotNull null
                            val optIdx = o.int("option_index") ?: return@mapNotNull null
                            pid to optIdx
                        }?.toMap() ?: emptyMap()
                    } else emptyMap()
                }.getOrDefault(emptyMap())
            } else emptyMap()

            val rawPosts = parsePosts(response.bodyAsText(), activeUser, likedPostIds, userPollVotes)
            resolveReferencedPosts(rawPosts, activeUser, likedPostIds, userPollVotes)
        }
    }

    /**
     * Publishes a new social post.
     */
    suspend fun createPost(
        author: SocialProfile,
        content: String,
        imageUrls: List<String> = emptyList(),
        videoUrl: String? = null,
        gifUrl: String? = null,
        audioUrl: String? = null,
        isReview: Boolean = false,
        rating: Int = 0,
        taggedArtist: String? = null,
        musicAttachment: MusicTrackAttachment? = null,
        poll: PollData? = null,
        quoteOfId: String? = null,
    ): Result<SocialPost> = withContext(Dispatchers.IO) {
        runCatching {
            val postId = UUID.randomUUID().toString()
            val musicTrackJson = musicAttachment?.let {
                val thumb = it.thumbnailUrl ?: it.artworkUrl ?: ""
                val art = it.artworkUrl ?: it.thumbnailUrl ?: ""
                "{\"video_id\":\"${it.videoId}\",\"title\":${jsonQuote(it.title)},\"artist\":${jsonQuote(it.artist)},\"thumbnail_url\":${jsonQuote(thumb)},\"artwork_url\":${jsonQuote(art)},\"duration_text\":${jsonQuote(it.durationText ?: "")}}"
            }

            val pollJson = poll?.let {
                val optionsArray = it.options.joinToString(",") { opt ->
                    val optImg = opt.imageUrl ?: opt.songAttachment?.artworkUrl ?: opt.songAttachment?.thumbnailUrl ?: ""
                    "{\"text\":${jsonQuote(opt.text)},\"votes\":${opt.votes},\"image_url\":${jsonQuote(optImg)}}"
                }
                val endsAtClause = it.endsAt?.let { ea -> ",\"ends_at\":${jsonQuote(ea)}" } ?: ""
                "{\"question\":${jsonQuote(it.question)},\"options\":[$optionsArray]$endsAtClause}"
            }

            val allImages = if (gifUrl != null) listOf(gifUrl) + imageUrls else imageUrls
            val imageUrlsJson = if (allImages.isNotEmpty()) {
                allImages.joinToString(prefix = "[", postfix = "]", separator = ",") { jsonQuote(it) }
            } else null

            val body = buildString {
                append("{")
                append("\"id\":\"$postId\",")
                append("\"author_id\":\"${author.id}\",")
                append("\"content\":${jsonQuote(content)}")
                if (imageUrlsJson != null) append(",\"image_urls\":$imageUrlsJson")
                if (allImages.isNotEmpty()) append(",\"image_url\":${jsonQuote(allImages.first())}")
                if (videoUrl != null) append(",\"video_url\":${jsonQuote(videoUrl)}")
                if (audioUrl != null) append(",\"audio_url\":${jsonQuote(audioUrl)}")
                if (isReview) {
                    append(",\"is_review\":true")
                    append(",\"rating\":$rating")
                }
                if (taggedArtist != null) append(",\"tagged_artist\":${jsonQuote(taggedArtist)}")
                if (musicTrackJson != null) append(",\"music_track\":$musicTrackJson")
                if (pollJson != null) append(",\"poll_data\":$pollJson")
                if (quoteOfId != null) append(",\"quote_of_id\":\"$quoteOfId\"")
                append("}")
            }

            val response = client.post(baseUrl("posts")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                header("Prefer", "return=representation")
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            if (!response.status.isSuccess()) {
                val err = response.bodyAsText().take(300)
                Log.w(TAG, "createPost failed with ${response.status}: $err")
            }

            SocialPost(
                id = postId,
                authorId = author.id,
                author = author,
                content = content,
                imageUrl = allImages.firstOrNull(),
                imageUrls = allImages,
                videoUrl = videoUrl,
                gifUrl = gifUrl,
                audioUrl = audioUrl,
                isReview = isReview,
                rating = rating,
                taggedArtist = taggedArtist,
                musicTrack = musicAttachment,
                pollData = poll,
                quoteOfId = quoteOfId,
            )
        }
    }

    /**
     * Likes or unlikes a post.
     */
    suspend fun toggleLikePost(postId: String, userId: String, liked: Boolean): Result<Unit> =
        withContext(Dispatchers.IO) {
            runCatching {
                if (!liked) {
                    val response = client.delete(baseUrl("post_likes")) {
                        header("apikey", SupabaseConfig.anonKey)
                        header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                        parameter("post_id", "eq.$postId")
                        parameter("user_id", "eq.$userId")
                    }
                    if (!response.status.isSuccess()) {
                        Log.w(TAG, "toggleLikePost (unlike) ${response.status}: ${response.bodyAsText().take(300)}")
                    }
                } else {
                    val response = client.post(baseUrl("post_likes")) {
                        header("apikey", SupabaseConfig.anonKey)
                        header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                        contentType(ContentType.Application.Json)
                        setBody("{\"post_id\":${PostgrestSanitizer.safeJsonString(postId)},\"user_id\":${PostgrestSanitizer.safeJsonString(userId)}}")
                    }
                    if (!response.status.isSuccess()) {
                        Log.w(TAG, "toggleLikePost (like) ${response.status}: ${response.bodyAsText().take(300)}")
                    }
                }
                // Synchronize likes_count on posts table
                runCatching {
                    val countRes = client.get(baseUrl("post_likes")) {
                        header("apikey", SupabaseConfig.anonKey)
                        header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                        parameter("post_id", "eq.$postId")
                        parameter("select", "user_id")
                    }
                    if (countRes.status.isSuccess()) {
                        val count = (json.parseToJsonElement(countRes.bodyAsText()) as? JsonArray)?.size ?: 0
                        client.patch(baseUrl("posts")) {
                            header("apikey", SupabaseConfig.anonKey)
                            header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                            contentType(ContentType.Application.Json)
                            parameter("id", "eq.$postId")
                            setBody("{\"likes_count\":$count}")
                        }
                    }
                }
                Unit
            }
        }

    /**
     * Reposts a post.
     */
    suspend fun repost(postId: String, user: SocialProfile): Result<SocialPost> = withContext(Dispatchers.IO) {
        runCatching {
            val newPostId = UUID.randomUUID().toString()
            val response = client.post(baseUrl("posts")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                contentType(ContentType.Application.Json)
                setBody("{\"id\":\"$newPostId\",\"author_id\":\"${user.id}\",\"repost_of_id\":\"$postId\",\"content\":\"\"}")
            }
            if (!response.status.isSuccess()) {
                Log.w(TAG, "repost ${response.status}: ${response.bodyAsText().take(300)}")
            }
            SocialPost(
                id = newPostId,
                authorId = user.id,
                author = user,
                content = "",
                repostOfId = postId,
            )
        }
    }

    /**
     * Toggles repost of a post ensuring single repost per user.
     */
    suspend fun toggleRepost(postId: String, user: SocialProfile, currentlyReposted: Boolean): Result<Boolean> =
        withContext(Dispatchers.IO) {
            runCatching {
                if (currentlyReposted) {
                    val response = client.delete(baseUrl("posts")) {
                        header("apikey", SupabaseConfig.anonKey)
                        header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                        parameter("author_id", "eq.${user.id}")
                        parameter("repost_of_id", "eq.$postId")
                    }
                    if (!response.status.isSuccess()) {
                        Log.w(TAG, "toggleRepost (delete) ${response.status}: ${response.bodyAsText().take(300)}")
                    }
                    false
                } else {
                    val newPostId = UUID.randomUUID().toString()
                    val response = client.post(baseUrl("posts")) {
                        header("apikey", SupabaseConfig.anonKey)
                        header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                        contentType(ContentType.Application.Json)
                        setBody("{\"id\":\"$newPostId\",\"author_id\":\"${user.id}\",\"repost_of_id\":\"$postId\",\"content\":\"\"}")
                    }
                    if (!response.status.isSuccess()) {
                        Log.w(TAG, "toggleRepost (create) ${response.status}: ${response.bodyAsText().take(300)}")
                    }
                    true
                }
            }
        }

    /**
     * Casts a vote on a poll.
     */
    suspend fun votePoll(
        postId: String,
        optionIndex: Int,
        userId: String,
        updatedPollData: PollData? = null,
    ): Result<Unit> =
        withContext(Dispatchers.IO) {
            runCatching {
                val response = client.post(baseUrl("poll_votes")) {
                    header("apikey", SupabaseConfig.anonKey)
                    header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                    contentType(ContentType.Application.Json)
                    setBody("{\"post_id\":${PostgrestSanitizer.safeJsonString(postId)},\"option_index\":$optionIndex,\"user_id\":${PostgrestSanitizer.safeJsonString(userId)}}")
                }
                if (!response.status.isSuccess()) {
                    Log.w(TAG, "votePoll ${response.status}: ${response.bodyAsText().take(300)}")
                }
                if (updatedPollData != null) {
                    val pollJson = buildString {
                        append("{")
                        append("\"question\":${jsonQuote(updatedPollData.question)},")
                        if (updatedPollData.endsAt != null) {
                            append("\"ends_at\":${jsonQuote(updatedPollData.endsAt)},")
                        }
                        append("\"options\":[")
                        updatedPollData.options.forEachIndexed { i, opt ->
                            if (i > 0) append(",")
                            append("{")
                            append("\"text\":${jsonQuote(opt.text)},")
                            append("\"votes\":${opt.votes}")
                            if (opt.imageUrl != null) {
                                append(",\"image_url\":${jsonQuote(opt.imageUrl)}")
                            }
                            append("}")
                        }
                        append("]")
                        append("}")
                    }
                    val postResponse = client.patch(baseUrl("posts")) {
                        header("apikey", SupabaseConfig.anonKey)
                        header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                        contentType(ContentType.Application.Json)
                        parameter("id", "eq.$postId")
                        setBody("{\"poll_data\":$pollJson}")
                    }
                    if (!postResponse.status.isSuccess()) {
                        Log.w(TAG, "votePoll update poll_data ${postResponse.status}: ${postResponse.bodyAsText().take(300)}")
                    }
                }
                Unit
            }
        }

    /**
     * Adds a comment to a post.
     */
    suspend fun addComment(
        postId: String,
        user: SocialProfile,
        content: String,
        parentCommentId: String? = null,
        imageUrl: String? = null,
        videoUrl: String? = null,
        gifUrl: String? = null,
    ): Result<PostComment> = withContext(Dispatchers.IO) {
        runCatching {
            val commentId = UUID.randomUUID().toString()
            var finalContent = content.trim()
            if (!imageUrl.isNullOrBlank()) {
                finalContent = "[image:$imageUrl] $finalContent".trim()
            }
            if (!videoUrl.isNullOrBlank()) {
                finalContent = "[video:$videoUrl] $finalContent".trim()
            }
            if (!gifUrl.isNullOrBlank()) {
                finalContent = "[gif:$gifUrl] $finalContent".trim()
            }

            val body = buildString {
                append("{")
                append("\"id\":\"$commentId\",")
                append("\"post_id\":\"$postId\",")
                append("\"author_id\":\"${user.id}\",")
                append("\"content\":${jsonQuote(finalContent)}")
                if (parentCommentId != null) append(",\"parent_id\":\"$parentCommentId\"")
                append("}")
            }

            val response = client.post(baseUrl("post_comments")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            if (!response.status.isSuccess()) {
                Log.w(TAG, "addComment failed with status ${response.status}: ${response.bodyAsText().take(300)}")
            } else {
                // Synchronize comments_count on posts table
                runCatching {
                    val countRes = client.get(baseUrl("post_comments")) {
                        header("apikey", SupabaseConfig.anonKey)
                        header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                        parameter("post_id", "eq.$postId")
                        parameter("select", "id")
                    }
                    if (countRes.status.isSuccess()) {
                        val count = (json.parseToJsonElement(countRes.bodyAsText()) as? JsonArray)?.size ?: 0
                        client.patch(baseUrl("posts")) {
                            header("apikey", SupabaseConfig.anonKey)
                            header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                            contentType(ContentType.Application.Json)
                            parameter("id", "eq.$postId")
                            setBody("{\"comments_count\":$count}")
                        }
                    }
                }
            }

            PostComment(
                id = commentId,
                postId = postId,
                authorId = user.id,
                author = user,
                parentId = parentCommentId,
                content = content.trim(),
                imageUrl = imageUrl,
                videoUrl = videoUrl,
                gifUrl = gifUrl,
            )
        }
    }

    /**
     * Fetches comments for a specific post.
     */
    suspend fun fetchComments(postId: String, currentUserId: String? = null): Result<List<PostComment>> =
        withContext(Dispatchers.IO) {
            runCatching {
                val response = client.get(baseUrl("post_comments")) {
                    header("apikey", SupabaseConfig.anonKey)
                    header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                    parameter("post_id", "eq.$postId")
                    parameter("select", "*,profiles:author_id(*)")
                    parameter("order", "created_at.asc")
                }
                if (!response.status.isSuccess()) {
                    val err = response.bodyAsText().take(300)
                    Log.w(TAG, "fetchComments ${response.status}: $err")
                    return@runCatching emptyList()
                }
                val rawComments = parseComments(response.bodyAsText())
                val likedCommentIds = if (!currentUserId.isNullOrBlank()) {
                    fetchLikedCommentIds(currentUserId).getOrDefault(emptySet())
                } else emptySet()

                rawComments.map { comment ->
                    comment.copy(isLikedByMe = likedCommentIds.contains(comment.id))
                }
            }
        }

    /**
     * Updates content of a comment and marks it as edited.
     */
    suspend fun editComment(commentId: String, newContent: String): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val response = client.patch(baseUrl("post_comments")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                contentType(ContentType.Application.Json)
                parameter("id", "eq.$commentId")
                setBody("{\"content\":${jsonQuote(newContent)},\"is_edited\":true}")
            }
            if (!response.status.isSuccess()) {
                val errorText = response.bodyAsText().take(300)
                Log.w(TAG, "editComment failed: ${response.status}: $errorText")
                throw RuntimeException("Failed to edit comment: HTTP ${response.status.value}")
            }
            Unit
        }
    }

    /**
     * Deletes a comment and updates the post's comments_count.
     */
    suspend fun deleteComment(commentId: String, postId: String): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val response = client.delete(baseUrl("post_comments")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("id", "eq.$commentId")
            }
            if (!response.status.isSuccess()) {
                val errorText = response.bodyAsText().take(300)
                Log.w(TAG, "deleteComment failed: ${response.status}: $errorText")
                throw RuntimeException("Failed to delete comment: HTTP ${response.status.value}")
            }
            runCatching {
                val countRes = client.get(baseUrl("post_comments")) {
                    header("apikey", SupabaseConfig.anonKey)
                    header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                    parameter("post_id", "eq.$postId")
                    parameter("select", "id")
                }
                if (countRes.status.isSuccess()) {
                    val count = (json.parseToJsonElement(countRes.bodyAsText()) as? JsonArray)?.size ?: 0
                    client.patch(baseUrl("posts")) {
                        header("apikey", SupabaseConfig.anonKey)
                        header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                        contentType(ContentType.Application.Json)
                        parameter("id", "eq.$postId")
                        setBody("{\"comments_count\":$count}")
                    }
                }
            }
            Unit
        }
    }

    /**
     * Fetches the set of comment IDs liked by the specified user.
     */
    suspend fun fetchLikedCommentIds(userId: String): Result<Set<String>> = withContext(Dispatchers.IO) {
        runCatching {
            val response = client.get(baseUrl("comment_likes")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("user_id", "eq.$userId")
                parameter("select", "comment_id")
            }
            if (!response.status.isSuccess()) {
                val err = response.bodyAsText().take(300)
                Log.w(TAG, "fetchLikedCommentIds ${response.status}: $err")
                return@runCatching emptySet()
            }
            val root = json.parseToJsonElement(response.bodyAsText())
            if (root !is JsonArray) {
                return@runCatching emptySet()
            }
            root.mapNotNull { (it as? JsonObject)?.str("comment_id") }.toSet()
        }
    }

    /**
     * Likes or unlikes a comment.
     */
    suspend fun toggleLikeComment(commentId: String, userId: String, liked: Boolean): Result<Unit> =
        withContext(Dispatchers.IO) {
            runCatching {
                if (!liked) {
                    val response = client.delete(baseUrl("comment_likes")) {
                        header("apikey", SupabaseConfig.anonKey)
                        header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                        parameter("comment_id", "eq.$commentId")
                        parameter("user_id", "eq.$userId")
                    }
                    if (!response.status.isSuccess()) {
                        Log.w(TAG, "toggleLikeComment (unlike) ${response.status}: ${response.bodyAsText().take(300)}")
                    }
                } else {
                    val response = client.post(baseUrl("comment_likes")) {
                        header("apikey", SupabaseConfig.anonKey)
                        header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                        contentType(ContentType.Application.Json)
                        setBody("{\"comment_id\":${PostgrestSanitizer.safeJsonString(commentId)},\"user_id\":${PostgrestSanitizer.safeJsonString(userId)}}")
                    }
                    if (!response.status.isSuccess()) {
                        Log.w(TAG, "toggleLikeComment (like) ${response.status}: ${response.bodyAsText().take(300)}")
                    }
                }
                Unit
            }
        }

    /**
     * Updates editable fields of a user's social profile.
     * Uses POST with merge-duplicates so the profile is always created if it did not exist yet.
     */
    suspend fun updateUserProfile(profile: SocialProfile): Result<Unit> = updateUserProfile(
        userId = profile.id,
        displayName = profile.displayName,
        handle = profile.handle,
        bio = profile.bio,
        avatarUrl = profile.avatarUrl,
        country = profile.country,
        age = profile.age,
        statusBubble = profile.statusBubble,
        bannerPlaylists = profile.bannerPlaylists,
        bannerUrl = profile.bannerUrl,
        favoriteArtists = profile.favoriteArtists,
    )

    suspend fun updateUserProfile(
        userId: String,
        displayName: String,
        handle: String,
        bio: String,
        avatarUrl: String? = null,
        country: String = "",
        age: Int? = null,
        statusBubble: String = "",
        bannerPlaylists: List<String> = emptyList(),
        bannerUrl: String? = null,
        favoriteArtists: List<FavoriteArtist> = emptyList(),
    ): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val bannerPlaylistsJson = if (bannerPlaylists.isNotEmpty()) {
                "[" + bannerPlaylists.joinToString(",") { jsonQuote(it) } + "]"
            } else "[]"
            val favoriteArtistsJson = if (favoriteArtists.isNotEmpty()) {
                "[" + favoriteArtists.joinToString(",") { fa ->
                    val artworkPart = if (fa.artworkUrl != null) ",\"artwork_url\":${jsonQuote(fa.artworkUrl)}" else ""
                    "{\"id\":${jsonQuote(fa.id)},\"name\":${jsonQuote(fa.name)}$artworkPart}"
                } + "]"
            } else "[]"
            val body = buildString {
                append("{")
                append("\"id\":\"$userId\",")
                append("\"display_name\":${jsonQuote(displayName)},")
                append("\"handle\":${jsonQuote(handle)},")
                append("\"bio\":${jsonQuote(bio)}")
                if (avatarUrl != null) append(",\"avatar_url\":${jsonQuote(avatarUrl)}")
                if (bannerUrl != null) append(",\"banner_url\":${jsonQuote(bannerUrl)}")
                append(",\"referral_code\":\"vibra_${userId.takeLast(6)}\"")
                append(",\"country\":${jsonQuote(country)}")
                if (age != null) append(",\"age\":$age") else append(",\"age\":null")
                append(",\"status_bubble\":${jsonQuote(statusBubble)}")
                append(",\"banner_playlists\":$bannerPlaylistsJson")
                append(",\"favorite_artists\":$favoriteArtistsJson")
                append("}")
            }
            var response = client.post("${baseUrl("profiles")}?on_conflict=id") {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                header("Prefer", "resolution=merge-duplicates")
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            if (!response.status.isSuccess()) {
                val errorText = response.bodyAsText().take(300)
                Log.w(TAG, "updateUserProfile returned status ${response.status}: $errorText, falling back to legacy profile columns")
                val fallbackBody = buildString {
                    append("{")
                    append("\"id\":\"$userId\",")
                    append("\"display_name\":${jsonQuote(displayName)},")
                    append("\"handle\":${jsonQuote(handle)},")
                    append("\"bio\":${jsonQuote(bio)}")
                    if (avatarUrl != null) append(",\"avatar_url\":${jsonQuote(avatarUrl)}")
                    if (bannerUrl != null) append(",\"banner_url\":${jsonQuote(bannerUrl)}")
                    append(",\"referral_code\":\"vibra_${userId.takeLast(6)}\"")
                    append("}")
                }
                response = client.post("${baseUrl("profiles")}?on_conflict=id") {
                    header("apikey", SupabaseConfig.anonKey)
                    header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                    header("Prefer", "resolution=merge-duplicates")
                    contentType(ContentType.Application.Json)
                    setBody(fallbackBody)
                }
            }
            Unit
        }
    }

    /**
     * Fetches a single user's profile by ID with live counts and relationship status.
     */
    suspend fun fetchUserProfile(userId: String, currentUserId: String = ""): Result<SocialProfile?> = withContext(Dispatchers.IO) {
        runCatching {
            val response = client.get(baseUrl("profiles")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("id", "eq.$userId")
                parameter("limit", "1")
            }
            if (!response.status.isSuccess()) {
                val err = response.bodyAsText().take(300)
                Log.w(TAG, "fetchUserProfile ${response.status}: $err")
                return@runCatching null
            }
            val baseProfile = parseProfiles(response.bodyAsText()).firstOrNull() ?: return@runCatching null

            // 1. Parallelize secondary lookups (followers, following, friends, relationship, favorite artists)
            coroutineScope {
                val followersDeferred = async {
                    runCatching {
                        val fRes = client.get(baseUrl("follows")) {
                            header("apikey", SupabaseConfig.anonKey)
                            header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                            parameter("following_id", "eq.$userId")
                            parameter("select", "follower_id")
                        }
                        if (fRes.status.isSuccess()) {
                            val arr = json.parseToJsonElement(fRes.bodyAsText()) as? JsonArray
                            val validFollowers = arr?.filter { (it as? JsonObject)?.str("follower_id") != userId } ?: emptyList()
                            val isF = if (currentUserId.isNotBlank()) validFollowers.any { (it as? JsonObject)?.str("follower_id") == currentUserId } else false
                            Pair(validFollowers.size, isF)
                        } else null
                    }.getOrNull()
                }

                val followingDeferred = async {
                    runCatching {
                        val ingRes = client.get(baseUrl("follows")) {
                            header("apikey", SupabaseConfig.anonKey)
                            header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                            parameter("follower_id", "eq.$userId")
                            parameter("select", "following_id")
                        }
                        if (ingRes.status.isSuccess()) {
                            val arr = json.parseToJsonElement(ingRes.bodyAsText()) as? JsonArray
                            arr?.filter { (it as? JsonObject)?.str("following_id") != userId }?.size
                        } else null
                    }.getOrNull()
                }

                val friendsDeferred = async {
                    runCatching {
                        val friendsRes = client.get(baseUrl("friendships")) {
                            header("apikey", SupabaseConfig.anonKey)
                            header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                            parameter("or", "(requester_id.eq.$userId,receiver_id.eq.$userId)")
                            parameter("status", "eq.ACCEPTED")
                            parameter("select", "id")
                        }
                        if (friendsRes.status.isSuccess()) {
                            val arr = json.parseToJsonElement(friendsRes.bodyAsText()) as? JsonArray
                            arr?.size
                        } else null
                    }.getOrNull()
                }

                val relationshipDeferred = async {
                    if (currentUserId.isNotBlank() && currentUserId != userId) {
                        runCatching {
                            val relRes = client.get(baseUrl("friendships")) {
                                header("apikey", SupabaseConfig.anonKey)
                                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                                parameter(
                                    "or",
                                    "(and(requester_id.eq.$currentUserId,receiver_id.eq.$userId),and(requester_id.eq.$userId,receiver_id.eq.$currentUserId))",
                                )
                                parameter("limit", "1")
                            }
                            if (relRes.status.isSuccess()) {
                                val arr = json.parseToJsonElement(relRes.bodyAsText()) as? JsonArray
                                val firstObj = arr?.firstOrNull() as? JsonObject
                                if (firstObj != null) {
                                    val status = firstObj.str("status") ?: "NONE"
                                    Pair(status == "ACCEPTED", status)
                                } else null
                            } else null
                        }.getOrNull()
                    } else null
                }

                val favArtistsDeferred = async {
                    if (baseProfile.favoriteArtists.isEmpty()) {
                        fetchFavoriteArtists(userId).getOrDefault(emptyList())
                    } else {
                        baseProfile.favoriteArtists
                    }
                }

                val followersResult = followersDeferred.await()
                val followingCount = followingDeferred.await() ?: baseProfile.followingCount
                val friendsCount = friendsDeferred.await() ?: baseProfile.friendsCount
                val relationshipResult = relationshipDeferred.await()
                val resolvedFavArtists = favArtistsDeferred.await()

                val realFollowers = followersResult?.first ?: baseProfile.followersCount
                val isFollowing = followersResult?.second ?: baseProfile.isFollowing
                val isFriend = relationshipResult?.first ?: baseProfile.isFriend
                val friendshipStatus = relationshipResult?.second ?: baseProfile.friendshipStatus

                baseProfile.copy(
                    followersCount = realFollowers,
                    followingCount = followingCount,
                    friendsCount = friendsCount,
                    isFollowing = isFollowing,
                    isFriend = isFriend,
                    friendshipStatus = friendshipStatus,
                    favoriteArtists = resolvedFavArtists,
                )
            }
        }
    }

    /**
     * Updates post content and sets is_edited to true.
     */
    suspend fun updatePost(postId: String, authorId: String, newContent: String): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val body = "{\"content\":${jsonQuote(newContent)},\"is_edited\":true}"
            val response = client.patch(baseUrl("posts")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                contentType(ContentType.Application.Json)
                parameter("id", "eq.$postId")
                parameter("author_id", "eq.$authorId")
                setBody(body)
            }
            if (!response.status.isSuccess()) {
                val errorText = response.bodyAsText().take(300)
                Log.w(TAG, "updatePost returned status ${response.status}: $errorText")
                throw RuntimeException("Failed to update post: HTTP ${response.status.value}")
            }
            Unit
        }
    }

    /**
     * Deletes a post authored by authorId.
     */
    suspend fun deletePost(postId: String, authorId: String): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val response = client.delete(baseUrl("posts")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("id", "eq.$postId")
                parameter("author_id", "eq.$authorId")
            }
            if (!response.status.isSuccess()) {
                val errorText = response.bodyAsText().take(300)
                Log.w(TAG, "deletePost returned status ${response.status}: $errorText")
                throw RuntimeException("Failed to delete post: HTTP ${response.status.value}")
            }
            Unit
        }
    }

    /**
     * Uploads media (images or videos) to Supabase Storage bucket 'vibra_social'.
     * Returns the publicly accessible URL of the uploaded media file.
     * Enforces 50MB max for video and 10MB max for images/audio.
     */
    suspend fun uploadMedia(
        bytes: ByteArray,
        mimeType: String = "image/jpeg",
        fileName: String = "${UUID.randomUUID()}.${if (mimeType.contains("video")) "mp4" else "jpg"}",
    ): Result<String> = withContext(Dispatchers.IO) {
        runCatching {
            val maxBytes = if (mimeType.contains("video")) 50L * 1024 * 1024 else 10L * 1024 * 1024
            if (bytes.size > maxBytes) {
                val limitMb = maxBytes / (1024 * 1024)
                throw IllegalArgumentException("File size exceeds maximum allowed limit of ${limitMb}MB")
            }
            val uploadUrl = "${SupabaseConfig.url.trimEnd('/')}/storage/v1/object/vibra_social/$fileName"
            val response = client.post(uploadUrl) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                contentType(ContentType.parse(mimeType))
                setBody(bytes)
            }
            if (!response.status.isSuccess()) {
                val errorText = response.bodyAsText().take(300)
                Log.w(TAG, "uploadMedia returned status ${response.status}: $errorText")
                throw RuntimeException("Upload failed: HTTP ${response.status.value} - $errorText")
            }
            "${SupabaseConfig.url.trimEnd('/')}/storage/v1/object/public/vibra_social/$fileName"
        }
    }

    /**
     * Uploads an image byte array to Supabase Storage bucket 'vibra_social'.
     * Delegates to [uploadMedia].
     */
    suspend fun uploadImage(
        bytes: ByteArray,
        mimeType: String = "image/jpeg",
        fileName: String = "${UUID.randomUUID()}.jpg",
    ): Result<String> = uploadMedia(bytes, mimeType, fileName)

    /**
     * Deletes a file from Supabase Storage (e.g. 'vibra_social' bucket).
     */
    suspend fun deleteStorageFile(bucket: String = "vibra_social", path: String): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val cleanPath = path.trim().trimStart('/')
            val deleteUrl = "${SupabaseConfig.url.trimEnd('/')}/storage/v1/object/$bucket/$cleanPath"
            val response = client.delete(deleteUrl) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
            }
            if (!response.status.isSuccess()) {
                Log.w(TAG, "deleteStorageFile returned ${response.status}: ${response.bodyAsText().take(200)}")
            }
            Unit
        }
    }

    /**
     * Fetches conversations for the user with last message preview and unread count.
     */
    suspend fun fetchConversations(userId: String): Result<List<ConversationSummary>> = withContext(Dispatchers.IO) {
        runCatching {
            // 1. Fetch user's direct messages (sent and received) ordered by newest first
            val dmsResponse = client.get(baseUrl("direct_messages")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("or", "(sender_id.eq.$userId,receiver_id.eq.$userId)")
                parameter("order", "created_at.desc")
                parameter("limit", "150")
            }
            val allDms = if (dmsResponse.status.isSuccess()) {
                parseDirectMessages(dmsResponse.bodyAsText())
            } else emptyList()

            // 2. Group messages by partner
            val partnerMap = LinkedHashMap<String, MutableList<DirectMessage>>()
            allDms.forEach { dm ->
                val partnerId = if (dm.senderId == userId) dm.receiverId else dm.senderId
                if (partnerId.isNotBlank() && partnerId != userId) {
                    partnerMap.getOrPut(partnerId) { mutableListOf() }.add(dm)
                }
            }

            // 3. Fetch profiles for partners, plus suggested friends
            val partnerIds = partnerMap.keys.toList()
            val profilesToFetch = if (partnerIds.isNotEmpty()) {
                val filter = "in.(${partnerIds.joinToString(",")})"
                val response = client.get(baseUrl("profiles")) {
                    header("apikey", SupabaseConfig.anonKey)
                    header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                    parameter("id", filter)
                }
                if (response.status.isSuccess()) parseProfiles(response.bodyAsText()) else emptyList()
            } else emptyList()

            val profilesMap = profilesToFetch.associateBy { it.id }.toMutableMap()

            // 3b. Fetch user's actual accepted friends so the chat list only shows actual friends
            val myFriends = getFriends(userId).getOrDefault(emptyList())
            myFriends.forEach { f ->
                if (!profilesMap.containsKey(f.id)) {
                    profilesMap[f.id] = f
                }
            }

            // 4. Construct ConversationSummary for each accepted friend
            val summaries = mutableListOf<ConversationSummary>()
            val friendIds = myFriends.map { it.id }.toSet()

            // First, accepted friends with message history in order of recency
            partnerIds.filter { friendIds.contains(it) }.forEach { partnerId ->
                val profile = profilesMap[partnerId]
                if (profile != null) {
                    val msgs = partnerMap[partnerId].orEmpty()
                    val last = msgs.firstOrNull()
                    val unread = msgs.count { it.receiverId == userId && !it.isRead }
                    val preview = when {
                        last == null -> "Start a conversation"
                        last.audioUrl != null -> "Voice note"
                        last.imageUrl != null -> "Sent a photo"
                        last.videoUrl != null -> "Sent a video"
                        last.gifUrl != null -> "Sent a GIF"
                        last.sharedMusic != null -> "Shared track: ${last.sharedMusic.title}"
                        last.sharedPlaylist != null -> "Shared playlist: ${last.sharedPlaylist.title}"
                        last.content.isNotBlank() -> last.content
                        else -> "Sent an attachment"
                    }
                    summaries.add(
                        ConversationSummary(
                            friend = profile,
                            lastMessage = last,
                            lastMessagePreview = preview,
                            lastMessageTime = last?.createdAt ?: "",
                            unreadCount = unread,
                        )
                    )
                }
            }

            // Next, accepted friends without message history yet (never random strangers)
            myFriends.forEach { friendProfile ->
                if (!partnerMap.containsKey(friendProfile.id)) {
                    summaries.add(
                        ConversationSummary(
                            friend = friendProfile,
                            lastMessage = null,
                            lastMessagePreview = "Say hello to start chatting",
                            lastMessageTime = "",
                            unreadCount = 0,
                        )
                    )
                }
            }

            summaries
        }
    }

    /**
     * Marks all unread messages from senderId to receiverId as read.
     */
    suspend fun markMessagesAsRead(senderId: String, receiverId: String): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val response = client.patch(baseUrl("direct_messages")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                contentType(ContentType.Application.Json)
                parameter("sender_id", "eq.$senderId")
                parameter("receiver_id", "eq.$receiverId")
                parameter("is_read", "eq.false")
                setBody("{\"is_read\":true}")
            }
            if (!response.status.isSuccess()) {
                Log.w(TAG, "markMessagesAsRead ${response.status}: ${response.bodyAsText().take(300)}")
            }
            Unit
        }
    }

    /**
     * Updates user's updated_at timestamp in profiles table for online presence detection.
     */
    suspend fun updatePresence(userId: String): Result<Unit> = withContext(Dispatchers.IO) {
        if (userId.isBlank() || !SupabaseConfig.isConfigured) return@withContext Result.success(Unit)
        runCatching {
            val now = java.time.Instant.now().toString()
            val res = client.patch(baseUrl("profiles")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                contentType(ContentType.Application.Json)
                parameter("id", "eq.$userId")
                setBody("{\"updated_at\":\"$now\"}")
            }
            if (!res.status.isSuccess()) {
                Log.w(TAG, "updatePresence ${res.status}: ${res.bodyAsText().take(300)}")
            }
            Unit
        }
    }

    /**
     * Fetches Direct Messages between two users.
     */
    suspend fun fetchDirectMessages(
        currentUserId: String,
        friendId: String,
    ): Result<List<DirectMessage>> = withContext(Dispatchers.IO) {
        runCatching {
            val response = client.get(baseUrl("direct_messages")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter(
                    "or",
                    "(and(sender_id.eq.$currentUserId,receiver_id.eq.$friendId),and(sender_id.eq.$friendId,receiver_id.eq.$currentUserId))",
                )
                parameter("order", "created_at.asc")
            }
            if (!response.status.isSuccess()) {
                val err = response.bodyAsText().take(300)
                Log.w(TAG, "fetchDirectMessages ${response.status}: $err")
                return@runCatching emptyList()
            }
            parseDirectMessages(response.bodyAsText())
        }
    }

    /**
     * Sends a direct message with optional attached music card or playlist card.
     */
    suspend fun sendDirectMessage(
        senderId: String,
        recipientId: String,
        message: String,
        senderProfile: SocialProfile? = null,
        trackAttachment: MusicTrackAttachment? = null,
        playlistAttachment: SharedPlaylistAttachment? = null,
        imageUrl: String? = null,
        videoUrl: String? = null,
        audioUrl: String? = null,
        gifUrl: String? = null,
        replyTo: DirectMessage? = null,
        recipientDisplayName: String? = null,
    ): Result<DirectMessage> = withContext(Dispatchers.IO) {
        runCatching {
            val messageId = UUID.randomUUID().toString()
            val sharedMusicJson = trackAttachment?.let {
                val thumb = it.thumbnailUrl ?: it.artworkUrl ?: "https://i.ytimg.com/vi/${it.videoId}/hqdefault.jpg"
                "{\"video_id\":\"${it.videoId}\",\"title\":${jsonQuote(it.title)},\"artist\":${jsonQuote(it.artist)},\"thumbnail_url\":${jsonQuote(thumb)},\"duration_text\":${jsonQuote(it.durationText ?: "")}}"
            }
            val sharedPlaylistJson = playlistAttachment?.let {
                "{\"playlist_id\":${jsonQuote(it.playlistId)},\"title\":${jsonQuote(it.title)},\"author\":${jsonQuote(it.author)},\"thumbnail_url\":${jsonQuote(it.thumbnailUrl ?: "")},\"track_count\":${it.trackCount}}"
            }

            val replySnippet = replyTo?.let { rep ->
                rep.content.ifBlank {
                    when {
                        rep.sharedMusic != null -> "Song: ${rep.sharedMusic.title}"
                        rep.sharedPlaylist != null -> "Playlist: ${rep.sharedPlaylist.title}"
                        !rep.imageUrl.isNullOrBlank() -> "Photo"
                        !rep.videoUrl.isNullOrBlank() -> "Video"
                        !rep.audioUrl.isNullOrBlank() -> "Voice note"
                        !rep.gifUrl.isNullOrBlank() -> "GIF"
                        else -> "Message"
                    }
                }.take(80).replace("\n", " ")
            }
            val replySender = replyTo?.let { rep ->
                if (rep.senderId == senderId) "You" else (recipientDisplayName ?: rep.replyToSender ?: "Friend")
            }

            val finalContent = buildString {
                if (replyTo != null && !replySnippet.isNullOrBlank()) {
                    val encoded = runCatching {
                        android.util.Base64.encodeToString(replySnippet.toByteArray(Charsets.UTF_8), android.util.Base64.NO_WRAP)
                    }.getOrDefault(replySnippet)
                    append("[reply:${replyTo.id}:${replySender ?: "Friend"}:$encoded] ")
                }
                if (!imageUrl.isNullOrBlank()) append("[image:$imageUrl] ")
                if (!videoUrl.isNullOrBlank()) append("[video:$videoUrl] ")
                if (!audioUrl.isNullOrBlank()) append("[audio:$audioUrl] ")
                if (!gifUrl.isNullOrBlank()) append("[gif:$gifUrl] ")
                trackAttachment?.let { t ->
                    val encT = android.util.Base64.encodeToString(t.title.toByteArray(Charsets.UTF_8), android.util.Base64.NO_WRAP)
                    val encA = android.util.Base64.encodeToString(t.artist.toByteArray(Charsets.UTF_8), android.util.Base64.NO_WRAP)
                    val thumb = t.thumbnailUrl ?: t.artworkUrl ?: "https://i.ytimg.com/vi/${t.videoId}/hqdefault.jpg"
                    val encThumb = android.util.Base64.encodeToString(thumb.toByteArray(Charsets.UTF_8), android.util.Base64.NO_WRAP)
                    append("[music:${t.videoId}:$encT:$encA:$encThumb] ")
                }
                playlistAttachment?.let { p ->
                    val encT = android.util.Base64.encodeToString(p.title.toByteArray(Charsets.UTF_8), android.util.Base64.NO_WRAP)
                    val encA = android.util.Base64.encodeToString(p.author.toByteArray(Charsets.UTF_8), android.util.Base64.NO_WRAP)
                    val encThumb = android.util.Base64.encodeToString((p.thumbnailUrl ?: "").toByteArray(Charsets.UTF_8), android.util.Base64.NO_WRAP)
                    append("[playlist:${p.playlistId}:$encT:$encA:$encThumb] ")
                }
                append(message)
            }.trim()

            val body = buildString {
                append("{")
                append("\"id\":\"$messageId\",")
                append("\"sender_id\":\"$senderId\",")
                append("\"receiver_id\":\"$recipientId\",")
                append("\"content\":${jsonQuote(finalContent)}")
                if (sharedMusicJson != null) append(",\"shared_music\":$sharedMusicJson")
                if (sharedPlaylistJson != null) append(",\"shared_playlist\":$sharedPlaylistJson")
                append("}")
            }
            val res = client.post(baseUrl("direct_messages")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            if (!res.status.isSuccess()) {
                Log.w(TAG, "sendDirectMessage returned ${res.status}: ${res.bodyAsText().take(300)}")
            } else if (senderProfile != null && recipientId != senderId) {
                val preview = when {
                    !audioUrl.isNullOrBlank() -> "sent you a voice note"
                    !imageUrl.isNullOrBlank() -> "sent you a photo"
                    !videoUrl.isNullOrBlank() -> "sent you a video"
                    !gifUrl.isNullOrBlank() -> "sent you a GIF"
                    trackAttachment != null -> "shared a track with you: ${trackAttachment.title}"
                    playlistAttachment != null -> "shared a playlist: ${playlistAttachment.title}"
                    message.isNotBlank() -> message.take(80)
                    else -> "sent you a message"
                }
                createNotification(
                    recipientUserId = recipientId,
                    actor = senderProfile,
                    type = NotificationType.MESSAGE,
                    message = preview,
                )
            }

            DirectMessage(
                id = messageId,
                senderId = senderId,
                receiverId = recipientId,
                content = message,
                imageUrl = imageUrl,
                videoUrl = videoUrl,
                audioUrl = audioUrl,
                gifUrl = gifUrl,
                sharedMusic = trackAttachment,
                sharedPlaylist = playlistAttachment,
                replyToId = replyTo?.id,
                replyToSender = replySender,
                replyToText = replySnippet,
            )
        }
    }

    /**
     * Updates content of a direct message authored by senderId.
     */
    suspend fun updateDirectMessage(
        messageId: String,
        senderId: String,
        newContent: String,
    ): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val body = "{\"content\":${jsonQuote(newContent)},\"is_edited\":true}"
            val response = client.patch(baseUrl("direct_messages")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                contentType(ContentType.Application.Json)
                parameter("id", "eq.$messageId")
                parameter("sender_id", "eq.$senderId")
                setBody(body)
            }
            if (!response.status.isSuccess()) {
                val errorText = response.bodyAsText().take(300)
                Log.w(TAG, "updateDirectMessage returned status ${response.status}: $errorText")
                throw RuntimeException("Failed to update message: HTTP ${response.status.value}")
            }
            Unit
        }
    }

    /**
     * Deletes a direct message authored by senderId.
     */
    suspend fun deleteDirectMessage(
        messageId: String,
        senderId: String,
    ): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val response = client.delete(baseUrl("direct_messages")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("id", "eq.$messageId")
                parameter("sender_id", "eq.$senderId")
            }
            if (!response.status.isSuccess()) {
                val errorText = response.bodyAsText().take(300)
                Log.w(TAG, "deleteDirectMessage returned status ${response.status}: $errorText")
                throw RuntimeException("Failed to delete message: HTTP ${response.status.value}")
            }
            Unit
        }
    }

    /**
     * Follows or unfollows a target user.
     */
    suspend fun toggleFollow(followerId: String, targetUserId: String, follow: Boolean): Result<Unit> =
        withContext(Dispatchers.IO) {
            runCatching {
                if (follow) {
                    val response = client.post(baseUrl("follows")) {
                        header("apikey", SupabaseConfig.anonKey)
                        header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                        contentType(ContentType.Application.Json)
                        setBody("{\"follower_id\":${PostgrestSanitizer.safeJsonString(followerId)},\"following_id\":${PostgrestSanitizer.safeJsonString(targetUserId)}}")
                    }
                    if (!response.status.isSuccess()) {
                        Log.w(TAG, "toggleFollow (follow) ${response.status}: ${response.bodyAsText().take(300)}")
                    }
                } else {
                    val response = client.delete(baseUrl("follows")) {
                        header("apikey", SupabaseConfig.anonKey)
                        header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                        parameter("follower_id", "eq.$followerId")
                        parameter("following_id", "eq.$targetUserId")
                    }
                    if (!response.status.isSuccess()) {
                        Log.w(TAG, "toggleFollow (unfollow) ${response.status}: ${response.bodyAsText().take(300)}")
                    }
                }
                // Synchronize followers and following counts on profiles table
                runCatching {
                    val followersRes = client.get(baseUrl("follows")) {
                        header("apikey", SupabaseConfig.anonKey)
                        header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                        parameter("following_id", "eq.$targetUserId")
                        parameter("select", "follower_id")
                    }
                    if (followersRes.status.isSuccess()) {
                        val count = (json.parseToJsonElement(followersRes.bodyAsText()) as? JsonArray)?.size ?: 0
                        client.patch(baseUrl("profiles")) {
                            header("apikey", SupabaseConfig.anonKey)
                            header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                            contentType(ContentType.Application.Json)
                            parameter("id", "eq.$targetUserId")
                            setBody("{\"followers_count\":$count}")
                        }
                    }
                }
                runCatching {
                    val followingRes = client.get(baseUrl("follows")) {
                        header("apikey", SupabaseConfig.anonKey)
                        header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                        parameter("follower_id", "eq.$followerId")
                        parameter("select", "following_id")
                    }
                    if (followingRes.status.isSuccess()) {
                        val count = (json.parseToJsonElement(followingRes.bodyAsText()) as? JsonArray)?.size ?: 0
                        client.patch(baseUrl("profiles")) {
                            header("apikey", SupabaseConfig.anonKey)
                            header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                            contentType(ContentType.Application.Json)
                            parameter("id", "eq.$followerId")
                            setBody("{\"following_count\":$count}")
                        }
                    }
                }
                Unit
            }
        }

    /**
     * Checks if a handle is available (unique).
     */
    suspend fun isHandleAvailable(handle: String, excludeUserId: String = ""): Result<Boolean> = withContext(Dispatchers.IO) {
        runCatching {
            val cleanHandle = handle.trim().lowercase().removePrefix("@")
            if (cleanHandle.isBlank()) return@runCatching false
            val response = client.get(baseUrl("profiles")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("handle", "ilike.$cleanHandle")
                parameter("select", "id")
                parameter("limit", "1")
            }
            if (!response.status.isSuccess()) {
                return@runCatching true
            }
            val arr = json.parseToJsonElement(response.bodyAsText()) as? JsonArray ?: return@runCatching true
            if (arr.isEmpty()) return@runCatching true
            val first = arr.firstOrNull() as? JsonObject
            val foundId = first?.str("id")
            foundId == null || foundId == excludeUserId
        }
    }

    /**
     * Searches profiles for @mention auto-complete popup.
     */
    /**
     * Sends a lightweight keepalive ping to the Supabase database to prevent 7-day idle pause.
     */
    suspend fun pingDatabase(force: Boolean = false): Result<Boolean> = withContext(Dispatchers.IO) {
        runCatching {
            val now = System.currentTimeMillis()
            val fiveDaysMs = 5L * 24 * 60 * 60 * 1000
            if (!force && (now - com.fortune.vibramusic.data.settings.AppSettings.lastSupabasePingTimestamp) < fiveDaysMs) {
                return@runCatching true
            }
            val response = client.get(baseUrl("profiles")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("select", "id")
                parameter("limit", "1")
            }
            if (response.status.isSuccess()) {
                com.fortune.vibramusic.data.settings.AppSettings.lastSupabasePingTimestamp = now
                true
            } else {
                false
            }
        }
    }

    suspend fun searchUsersForMention(query: String, limit: Int = 8): Result<List<SocialProfile>> = withContext(Dispatchers.IO) {
        runCatching {
            val cleanQuery = PostgrestSanitizer.escapeIlikePattern(query.trim().removePrefix("@"))
            val response = client.get(baseUrl("profiles")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                if (cleanQuery.isNotBlank()) {
                    val encodedQ = "*$cleanQuery*"
                    parameter("or", "(handle.ilike.$encodedQ,display_name.ilike.$encodedQ)")
                }
                parameter("limit", limit.toString())
                parameter("order", "handle.asc")
            }
            if (!response.status.isSuccess()) {
                return@runCatching emptyList()
            }
            parseProfiles(response.bodyAsText())
        }
    }

    /**
     * Fetches a single profile by handle.
     */
    suspend fun getProfileByHandle(handle: String, currentUserId: String = ""): Result<SocialProfile?> = withContext(Dispatchers.IO) {
        runCatching {
            val clean = handle.trim().lowercase().removePrefix("@")
            if (clean.isBlank()) return@runCatching null
            val response = client.get(baseUrl("profiles")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("or", "(handle.ilike.$clean,handle.ilike.@$clean)")
                parameter("limit", "1")
            }
            if (!response.status.isSuccess()) return@runCatching null
            val arr = json.parseToJsonElement(response.bodyAsText()) as? JsonArray ?: return@runCatching null
            val first = arr.firstOrNull() as? JsonObject ?: return@runCatching null
            val baseProfile = parseProfileRow(first)
            fetchUserProfile(baseProfile.id, currentUserId).getOrNull() ?: baseProfile
        }
    }

    /**
     * Fetches accounts following the given user.
     */
    suspend fun getFollowers(userId: String, currentUserId: String = ""): Result<List<SocialProfile>> = withContext(Dispatchers.IO) {
        runCatching {
            val response = client.get(baseUrl("follows")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("following_id", "eq.$userId")
                parameter("select", "profiles:follower_id(*)")
            }
            if (!response.status.isSuccess()) {
                val err = response.bodyAsText().take(300)
                Log.w(TAG, "getFollowers error ${response.status}: $err")
                return@runCatching emptyList()
            }
            val arr = json.parseToJsonElement(response.bodyAsText()) as? JsonArray ?: return@runCatching emptyList()
            val profiles = arr.mapNotNull { item ->
                val obj = item as? JsonObject ?: return@mapNotNull null
                val pObj = obj.embeddedProfile("profiles") ?: obj.obj("profiles")
                pObj?.let { parseProfileRow(it) }
            }

            val activeUser = currentUserId.ifBlank { userId }
            val myFollowing = if (activeUser.isNotBlank()) {
                runCatching {
                    val fRes = client.get(baseUrl("follows")) {
                        header("apikey", SupabaseConfig.anonKey)
                        header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                        parameter("follower_id", "eq.$activeUser")
                        parameter("select", "following_id")
                    }
                    if (fRes.status.isSuccess()) {
                        val fArr = json.parseToJsonElement(fRes.bodyAsText()) as? JsonArray
                        fArr?.mapNotNull { (it as? JsonObject)?.str("following_id") }?.toSet() ?: emptySet()
                    } else emptySet()
                }.getOrDefault(emptySet())
            } else emptySet()

            profiles.filter { it.id != userId }.map { p ->
                p.copy(isFollowing = myFollowing.contains(p.id))
            }
        }
    }

    /**
     * Fetches accounts the given user is following with follow status reconciled against active user.
     */
    suspend fun getFollowing(userId: String, currentUserId: String = ""): Result<List<SocialProfile>> = withContext(Dispatchers.IO) {
        runCatching {
            val response = client.get(baseUrl("follows")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("follower_id", "eq.$userId")
                parameter("select", "profiles:following_id(*)")
            }
            if (!response.status.isSuccess()) {
                val err = response.bodyAsText().take(300)
                Log.w(TAG, "getFollowing error ${response.status}: $err")
                return@runCatching emptyList()
            }
            val arr = json.parseToJsonElement(response.bodyAsText()) as? JsonArray ?: return@runCatching emptyList()
            val profiles = arr.mapNotNull { item ->
                val obj = item as? JsonObject ?: return@mapNotNull null
                val pObj = obj.embeddedProfile("profiles") ?: obj.obj("profiles")
                pObj?.let { parseProfileRow(it) }
            }

            val validProfiles = profiles.filter { it.id != userId }
            val activeUser = currentUserId.ifBlank { userId }
            if (activeUser == userId) {
                validProfiles.map { it.copy(isFollowing = true) }
            } else {
                val myFollowing = runCatching {
                    val fRes = client.get(baseUrl("follows")) {
                        header("apikey", SupabaseConfig.anonKey)
                        header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                        parameter("follower_id", "eq.$activeUser")
                        parameter("select", "following_id")
                    }
                    if (fRes.status.isSuccess()) {
                        val fArr = json.parseToJsonElement(fRes.bodyAsText()) as? JsonArray
                        fArr?.mapNotNull { (it as? JsonObject)?.str("following_id") }?.toSet() ?: emptySet()
                    } else emptySet()
                }.getOrDefault(emptySet())
                validProfiles.map { p ->
                    p.copy(isFollowing = myFollowing.contains(p.id))
                }
            }
        }
    }

    /**
     * Fetches friends (mutual follows between users).
     */
    suspend fun getFriends(userId: String, currentUserId: String = ""): Result<List<SocialProfile>> = withContext(Dispatchers.IO) {
        runCatching {
            val friendshipProfiles = mutableListOf<SocialProfile>()
            val friendsRes = client.get(baseUrl("friendships")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("or", "(requester_id.eq.$userId,receiver_id.eq.$userId)")
                parameter("status", "eq.ACCEPTED")
            }
            if (friendsRes.status.isSuccess()) {
                val arr = json.parseToJsonElement(friendsRes.bodyAsText()) as? JsonArray
                val friendIds = arr?.mapNotNull { item ->
                    val obj = item as? JsonObject
                    val req = obj?.str("requester_id")
                    val rec = obj?.str("receiver_id")
                    if (req == userId) rec else req
                }?.filter { !it.isNullOrBlank() }?.toSet().orEmpty()

                if (friendIds.isNotEmpty()) {
                    val inFilter = PostgrestSanitizer.buildSafeInFilter(friendIds)
                    val profRes = client.get(baseUrl("profiles")) {
                        header("apikey", SupabaseConfig.anonKey)
                        header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                        parameter("id", inFilter)
                    }
                    if (profRes.status.isSuccess()) {
                        val profArr = json.parseToJsonElement(profRes.bodyAsText()) as? JsonArray
                        profArr?.mapNotNull { (it as? JsonObject)?.let { row -> parseProfileRow(row) } }?.let {
                            friendshipProfiles.addAll(it.map { p -> p.copy(isFriend = true) })
                        }
                    }
                }
            }

            val following = getFollowing(userId, currentUserId).getOrDefault(emptyList())
            val followers = getFollowers(userId, currentUserId).getOrDefault(emptyList())
            val followerIds = followers.map { it.id }.toSet()
            val mutuals = following.filter { followerIds.contains(it.id) }.map {
                it.copy(isFriend = true)
            }

            (friendshipProfiles + mutuals).distinctBy { it.id }
        }
    }

    /**
     * Fetches suggested users to follow.
     */
    suspend fun getSuggestedUsers(userId: String): Result<List<SocialProfile>> = withContext(Dispatchers.IO) {
        runCatching {
            val following = getFollowing(userId, userId).getOrDefault(emptyList())
            val excludedIds = following.map { it.id }.toSet() + userId

            val response = client.get(baseUrl("profiles")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("limit", "20")
                parameter("order", "created_at.desc")
            }
            if (!response.status.isSuccess()) {
                return@runCatching emptyList()
            }
            val arr = json.parseToJsonElement(response.bodyAsText()) as? JsonArray ?: return@runCatching emptyList()
            arr.mapNotNull { item ->
                (item as? JsonObject)?.let { parseProfileRow(it) }
            }.filter { !excludedIds.contains(it.id) }
        }
    }

    /**
     * Sends a friend request.
     */
    suspend fun sendFriendRequest(requesterId: String, targetUserId: String): Result<Unit> =
        withContext(Dispatchers.IO) {
            runCatching {
                val response = client.post(baseUrl("friendships")) {
                    header("apikey", SupabaseConfig.anonKey)
                    header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                    contentType(ContentType.Application.Json)
                    setBody("{\"requester_id\":${PostgrestSanitizer.safeJsonString(requesterId)},\"receiver_id\":${PostgrestSanitizer.safeJsonString(targetUserId)},\"status\":\"PENDING\"}")
                }
                if (!response.status.isSuccess()) {
                    Log.w(TAG, "sendFriendRequest ${response.status}: ${response.bodyAsText().take(300)}")
                }
                Unit
            }
        }

    /**
     * Fetches notifications for a user.
     */
    suspend fun fetchNotifications(userId: String): Result<List<SocialNotification>> = withContext(Dispatchers.IO) {
        runCatching {
            val response = client.get(baseUrl("notifications")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("user_id", "eq.$userId")
                parameter("order", "created_at.desc")
                parameter("limit", 40)
            }
            if (!response.status.isSuccess()) {
                val err = response.bodyAsText().take(300)
                Log.w(TAG, "fetchNotifications ${response.status}: $err")
                return@runCatching emptyList()
            }
            parseNotifications(response.bodyAsText(), userId)
        }
    }

    /**
     * Marks a notification as read.
     */
    suspend fun markNotificationRead(notificationId: String): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val response = client.patch(baseUrl("notifications")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("id", "eq.$notificationId")
                contentType(ContentType.Application.Json)
                setBody("{\"is_read\":true}")
            }
            if (!response.status.isSuccess()) {
                Log.w(TAG, "markNotificationRead ${response.status}: ${response.bodyAsText().take(300)}")
            }
            Unit
        }
    }

    /**
     * Creates and dispatches an in-app social notification to a recipient user.
     */
    suspend fun createNotification(
        recipientUserId: String,
        actor: SocialProfile,
        type: NotificationType,
        targetPostId: String? = null,
        message: String = "",
    ): Result<Unit> = withContext(Dispatchers.IO) {
        if (recipientUserId.isBlank() || recipientUserId == actor.id) {
            return@withContext Result.success(Unit)
        }
        runCatching {
            val body = buildString {
                append("{")
                append("\"id\":\"${UUID.randomUUID()}\",")
                append("\"user_id\":${jsonQuote(recipientUserId)},")
                append("\"actor_id\":${jsonQuote(actor.id)},")
                append("\"actor_name\":${jsonQuote(actor.displayName)},")
                append("\"actor_handle\":${jsonQuote(actor.handle)},")
                if (!actor.avatarUrl.isNullOrBlank()) {
                    append("\"actor_avatar\":${jsonQuote(actor.avatarUrl)},")
                }
                append("\"type\":${jsonQuote(type.name)},")
                if (!targetPostId.isNullOrBlank()) {
                    append("\"target_post_id\":${jsonQuote(targetPostId)},")
                }
                append("\"message\":${jsonQuote(message)},")
                append("\"is_read\":false")
                append("}")
            }
            val response = client.post(baseUrl("notifications")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            if (!response.status.isSuccess()) {
                Log.w(TAG, "createNotification ${response.status}: ${response.bodyAsText().take(300)}")
            }
            Unit
        }
    }

    /**
     * Fetches favorite artists for a user.
     */
    suspend fun fetchFavoriteArtists(userId: String): Result<List<FavoriteArtist>> = withContext(Dispatchers.IO) {
        runCatching {
            val response = client.get(baseUrl("favorite_artists")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("user_id", "eq.$userId")
            }
            if (!response.status.isSuccess()) {
                val err = response.bodyAsText().take(300)
                Log.w(TAG, "fetchFavoriteArtists ${response.status}: $err")
                return@runCatching emptyList()
            }
            val root = json.parseToJsonElement(response.bodyAsText())
            if (root !is JsonArray) {
                Log.w(TAG, "fetchFavoriteArtists: expected array, got: ${response.bodyAsText().take(300)}")
                return@runCatching emptyList()
            }
            root.mapNotNull { el ->
                val obj = el as? JsonObject ?: return@mapNotNull null
                val id = obj.str("artist_id") ?: return@mapNotNull null
                val name = obj.str("artist_name") ?: ""
                val artwork = obj.str("artist_artwork")?.takeIf { it.isNotBlank() && it != "null" }
                FavoriteArtist(
                    id = id,
                    name = name,
                    avatarUrl = artwork,
                )
            }
        }
    }

    /**
     * Adds an artist to the user's favorite artists.
     */
    suspend fun addFavoriteArtist(userId: String, artist: QuizArtist): Result<Unit> =
        withContext(Dispatchers.IO) {
            runCatching {
                // Delete existing favorite entry to avoid ON CONFLICT inference errors across schemas
                client.delete(baseUrl("favorite_artists")) {
                    header("apikey", SupabaseConfig.anonKey)
                    header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                    parameter("user_id", "eq.$userId")
                    parameter("artist_id", "eq.${artist.id}")
                }
                val artwork = artist.artworkUrl
                val body = buildString {
                    append("{")
                    append("\"user_id\":\"$userId\",")
                    append("\"artist_id\":\"${artist.id}\",")
                    append("\"artist_name\":${jsonQuote(artist.name)}")
                    if (artwork != null) append(",\"artist_artwork\":${jsonQuote(artwork)}")
                    append("}")
                }
                val res = client.post(baseUrl("favorite_artists")) {
                    header("apikey", SupabaseConfig.anonKey)
                    header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                    contentType(ContentType.Application.Json)
                    setBody(body)
                }
                if (!res.status.isSuccess()) {
                    Log.w(TAG, "addFavoriteArtist returned ${res.status}: ${res.bodyAsText().take(300)}")
                }
                Unit
            }
        }

    /**
     * Removes an artist from favorite artists.
     */
    suspend fun removeFavoriteArtist(userId: String, artistId: String): Result<Unit> =
        withContext(Dispatchers.IO) {
            runCatching {
                val res = client.delete(baseUrl("favorite_artists")) {
                    header("apikey", SupabaseConfig.anonKey)
                    header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                    parameter("user_id", "eq.$userId")
                    parameter("artist_id", "eq.$artistId")
                }
                if (!res.status.isSuccess()) {
                    Log.w(TAG, "removeFavoriteArtist returned ${res.status}: ${res.bodyAsText().take(300)}")
                }
                Unit
            }
        }

    /**
     * Submits a verified music quiz result to the database.
     */
    suspend fun submitQuizScore(result: QuizScoreResult): Result<Unit> =
        withContext(Dispatchers.IO) {
            runCatching {
                val body = buildString {
                    append("{")
                    append("\"user_id\":\"${result.userId}\",")
                    append("\"artist_id\":\"${result.artistId}\",")
                    append("\"artist_name\":${jsonQuote(result.artistName)},")
                    if (result.artistAvatar != null) append("\"artist_avatar\":${jsonQuote(result.artistAvatar)},")
                    append("\"score\":${result.score},")
                    append("\"total_questions\":${result.totalQuestions},")
                    append("\"time_seconds\":${result.timeSeconds},")
                    append("\"percentile\":${result.percentile}")
                    append("}")
                }
                val res = client.post(baseUrl("quiz_leaderboards")) {
                    header("apikey", SupabaseConfig.anonKey)
                    header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                    contentType(ContentType.Application.Json)
                    setBody(body)
                }
                if (!res.status.isSuccess()) {
                    Log.w(TAG, "submitQuizScore returned ${res.status}: ${res.bodyAsText().take(300)}")
                }
                Unit
            }
        }

    /**
     * Retrieves the top leaderboard for a specific artist.
     */
    suspend fun fetchArtistLeaderboard(
        artistId: String,
        currentUserId: String = "",
        limit: Int = 50,
    ): Result<List<LeaderboardEntry>> = withContext(Dispatchers.IO) {
        runCatching {
            val response = client.get(baseUrl("quiz_leaderboards")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("artist_id", "eq.$artistId")
                parameter("select", "*,profiles:user_id(handle,display_name,avatar_url)")
                parameter("order", "score.desc,time_seconds.asc")
                parameter("limit", limit)
            }
            if (!response.status.isSuccess()) {
                val err = response.bodyAsText().take(300)
                Log.w(TAG, "fetchArtistLeaderboard ${response.status}: $err")
                return@runCatching emptyList()
            }
            parseLeaderboard(response.bodyAsText(), currentUserId)
        }
    }

    /**
     * Synchronizes listening experience preferences and connected Spotify session.
     */
    suspend fun syncListeningExperience(
        userId: String,
        spotifySpdcToken: String?,
        spotifyConnected: Boolean,
        audioQuality: String,
        equalizerEnabled: Boolean,
        equalizerPreset: String,
        volumeNormalization: Boolean,
        bassBoostPercent: Int,
        virtualizerPercent: Int,
        pitchCents: Int,
        tempoMultiplier: Float,
        autoSkipSilence: Boolean,
        lyricsSource: String,
        canvasEnabled: Boolean,
        preferredGenres: List<String> = emptyList(),
        listeningStatsJson: String? = null,
    ): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val genresJson = preferredGenres.joinToString(prefix = "[", postfix = "]", separator = ",") { jsonQuote(it) }
            val body = buildString {
                append("{")
                append("\"user_id\":\"$userId\",")
                if (spotifySpdcToken != null) append("\"spotify_spdc_token\":${jsonQuote(spotifySpdcToken)},")
                append("\"spotify_connected\":$spotifyConnected,")
                append("\"audio_quality\":${jsonQuote(audioQuality)},")
                append("\"equalizer_enabled\":$equalizerEnabled,")
                append("\"equalizer_preset\":${jsonQuote(equalizerPreset)},")
                append("\"volume_normalization\":$volumeNormalization,")
                append("\"bass_boost_percent\":$bassBoostPercent,")
                append("\"virtualizer_percent\":$virtualizerPercent,")
                append("\"pitch_cents\":$pitchCents,")
                append("\"tempo_multiplier\":$tempoMultiplier,")
                append("\"auto_skip_silence\":$autoSkipSilence,")
                append("\"lyrics_source\":${jsonQuote(lyricsSource)},")
                append("\"canvas_enabled\":$canvasEnabled,")
                append("\"preferred_genres\":$genresJson")
                if (listeningStatsJson != null) append(",\"listening_stats_json\":${jsonQuote(listeningStatsJson)}")
                append("}")
            }
            val res = client.post("${baseUrl("user_listening_experience")}?on_conflict=user_id") {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                header("Prefer", "resolution=merge-duplicates")
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            if (!res.status.isSuccess()) {
                Log.w(TAG, "syncListeningExperience returned ${res.status}: ${res.bodyAsText().take(300)}")
            }
            Unit
        }
    }

    /**
     * Fetches saved listening experience and connected Spotify session for a user.
     */
    suspend fun fetchListeningExperience(userId: String): Result<UserListeningExperience?> = withContext(Dispatchers.IO) {
        runCatching {
            val response = client.get(baseUrl("user_listening_experience")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("user_id", "eq.$userId")
            }
            if (!response.status.isSuccess()) {
                val err = response.bodyAsText().take(300)
                Log.w(TAG, "fetchListeningExperience ${response.status}: $err")
                return@runCatching null
            }
            val root = json.parseToJsonElement(response.bodyAsText())
            if (root !is JsonArray) {
                Log.w(TAG, "fetchListeningExperience: expected array, got: ${response.bodyAsText().take(300)}")
                return@runCatching null
            }
            val obj = root.firstOrNull() as? JsonObject ?: return@runCatching null
            val genres = obj.arr("preferred_genres")?.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p !is JsonNull }?.content?.takeIf { s -> s.isNotBlank() && s != "null" } } ?: emptyList()
            UserListeningExperience(
                userId = userId,
                spotifySpdcToken = obj.str("spotify_spdc_token"),
                spotifyConnected = obj.bool("spotify_connected") ?: false,
                audioQuality = obj.str("audio_quality") ?: "HIGH",
                equalizerEnabled = obj.bool("equalizer_enabled") ?: false,
                equalizerPreset = obj.str("equalizer_preset") ?: "FLAT",
                volumeNormalization = obj.bool("volume_normalization") ?: true,
                bassBoostPercent = obj.int("bass_boost_percent") ?: 0,
                virtualizerPercent = obj.int("virtualizer_percent") ?: 0,
                pitchCents = obj.int("pitch_cents") ?: 0,
                tempoMultiplier = obj.double("tempo_multiplier")?.toFloat() ?: 1.0f,
                autoSkipSilence = obj.bool("auto_skip_silence") ?: false,
                lyricsSource = obj.str("lyrics_source") ?: "DEFAULT",
                canvasEnabled = obj.bool("canvas_enabled") ?: true,
                preferredGenres = genres,
                listeningStatsJson = obj.str("listening_stats_json"),
            )
        }
    }

    /**
     * Records a liked music track (metadata only, no audio bytes).
     */
    suspend fun syncLikedTrack(userId: String, song: Song): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val body = buildString {
                append("{")
                append("\"user_id\":\"$userId\",")
                append("\"video_id\":\"${song.videoId}\",")
                append("\"title\":${jsonQuote(song.title)},")
                append("\"artist\":${jsonQuote(song.artist)}")
                if (song.thumbnailUrl != null) append(",\"thumbnail_url\":${jsonQuote(song.thumbnailUrl)}")
                if (song.durationText != null) append(",\"duration_text\":${jsonQuote(song.durationText)}")
                append("}")
            }
            val res = client.post(baseUrl("user_liked_tracks")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                header("Prefer", "resolution=merge-duplicates")
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            if (!res.status.isSuccess()) {
                Log.w(TAG, "syncLikedTrack returned ${res.status}: ${res.bodyAsText().take(300)}")
            }
            Unit
        }
    }

    /**
     * Removes a liked track from the user's cloud library.
     */
    suspend fun removeLikedTrack(userId: String, videoId: String): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val res = client.delete(baseUrl("user_liked_tracks")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("user_id", "eq.$userId")
                parameter("video_id", "eq.$videoId")
            }
            if (!res.status.isSuccess()) {
                Log.w(TAG, "removeLikedTrack returned ${res.status}: ${res.bodyAsText().take(300)}")
            }
            Unit
        }
    }

    /**
     * Fetches all liked tracks for a user from Supabase.
     */
    suspend fun fetchLikedTracks(userId: String): Result<List<Song>> = withContext(Dispatchers.IO) {
        runCatching {
            val response = client.get(baseUrl("user_liked_tracks")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("user_id", "eq.$userId")
                parameter("order", "liked_at.desc")
            }
            if (!response.status.isSuccess()) {
                val err = response.bodyAsText().take(300)
                Log.w(TAG, "fetchLikedTracks ${response.status}: $err")
                return@runCatching emptyList()
            }
            val root = json.parseToJsonElement(response.bodyAsText())
            if (root !is JsonArray) {
                Log.w(TAG, "fetchLikedTracks: expected array, got: ${response.bodyAsText().take(300)}")
                return@runCatching emptyList()
            }
            root.mapNotNull { el ->
                val obj = el as? JsonObject ?: return@mapNotNull null
                val videoId = obj.str("video_id") ?: return@mapNotNull null
                val title = obj.str("title") ?: return@mapNotNull null
                val artist = obj.str("artist") ?: ""
                val thumb = obj.str("thumbnail_url")?.takeIf { it.isNotBlank() && it != "null" }
                val duration = obj.str("duration_text")
                Song(
                    videoId = videoId,
                    title = title,
                    artist = artist,
                    thumbnailUrl = thumb,
                    durationText = duration,
                )
            }
        }
    }

    /**
     * Synchronizes a user playlist metadata to the cloud.
     */
    suspend fun syncPlaylist(
        userId: String,
        playlistId: String,
        title: String,
        description: String = "",
        thumbnailUrl: String? = null,
        trackCount: Int = 0,
    ): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val body = buildString {
                append("{")
                append("\"id\":\"$playlistId\",")
                append("\"user_id\":\"$userId\",")
                append("\"title\":${jsonQuote(title)},")
                append("\"description\":${jsonQuote(description)},")
                if (thumbnailUrl != null) append("\"thumbnail_url\":${jsonQuote(thumbnailUrl)},")
                append("\"track_count\":$trackCount")
                append("}")
            }
            val res = client.post(baseUrl("user_playlists")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                header("Prefer", "resolution=merge-duplicates")
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            if (!res.status.isSuccess()) {
                Log.w(TAG, "syncPlaylist returned ${res.status}: ${res.bodyAsText().take(300)}")
            }
            Unit
        }
    }

    /**
     * Deletes a user playlist and its tracks from the cloud.
     */
    suspend fun deletePlaylist(userId: String, playlistId: String): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val res = client.delete(baseUrl("user_playlists")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("id", "eq.$playlistId")
                parameter("user_id", "eq.$userId")
            }
            if (!res.status.isSuccess()) {
                Log.w(TAG, "deletePlaylist returned ${res.status}: ${res.bodyAsText().take(300)}")
            }
            Unit
        }
    }

    /**
     * Synchronizes the tracks of a playlist (metadata only, no audio bytes).
     */
    suspend fun syncPlaylistTracks(
        userId: String,
        playlistId: String,
        tracks: List<Song>,
    ): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            client.delete(baseUrl("user_playlist_tracks")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("playlist_id", "eq.$playlistId")
            }
            if (tracks.isNotEmpty()) {
                val tracksJson = tracks.mapIndexed { idx, song ->
                    buildString {
                        append("{")
                        append("\"playlist_id\":\"$playlistId\",")
                        append("\"user_id\":\"$userId\",")
                        append("\"video_id\":\"${song.videoId}\",")
                        append("\"title\":${jsonQuote(song.title)},")
                        append("\"artist\":${jsonQuote(song.artist)},")
                        if (song.thumbnailUrl != null) append("\"thumbnail_url\":${jsonQuote(song.thumbnailUrl)},")
                        if (song.durationText != null) append("\"duration_text\":${jsonQuote(song.durationText)},")
                        append("\"position\":$idx")
                        append("}")
                    }
                }.joinToString(",", "[", "]")

                val res = client.post(baseUrl("user_playlist_tracks")) {
                    header("apikey", SupabaseConfig.anonKey)
                    header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                    contentType(ContentType.Application.Json)
                    setBody(tracksJson)
                }
                if (!res.status.isSuccess()) {
                    Log.w(TAG, "syncPlaylistTracks returned ${res.status}: ${res.bodyAsText().take(300)}")
                }
            }
            Unit
        }
    }

    /**
     * Fetches all user playlists along with their track items from the cloud.
     */
    suspend fun fetchUserPlaylistsWithTracks(
        userId: String,
    ): Result<List<Pair<UserPlaylist, List<Song>>>> = withContext(Dispatchers.IO) {
        runCatching {
            val response = client.get(baseUrl("user_playlists")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("user_id", "eq.$userId")
                parameter("order", "created_at.desc")
            }
            if (!response.status.isSuccess()) {
                val err = response.bodyAsText().take(300)
                Log.w(TAG, "fetchUserPlaylistsWithTracks ${response.status}: $err")
                return@runCatching emptyList()
            }
            val root = json.parseToJsonElement(response.bodyAsText())
            if (root !is JsonArray) {
                Log.w(TAG, "fetchUserPlaylistsWithTracks: expected array, got: ${response.bodyAsText().take(300)}")
                return@runCatching emptyList()
            }
            val result = mutableListOf<Pair<UserPlaylist, List<Song>>>()

            for (item in root) {
                val pObj = item as? JsonObject ?: continue
                val pId = pObj.str("id") ?: continue
                val pTitle = pObj.str("title") ?: "Playlist"
                val pThumb = pObj.str("thumbnail_url")?.takeIf { it.isNotBlank() && it != "null" }

                val tracksResp = client.get(baseUrl("user_playlist_tracks")) {
                    header("apikey", SupabaseConfig.anonKey)
                    header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                    parameter("playlist_id", "eq.$pId")
                    parameter("order", "position.asc")
                }
                if (!tracksResp.status.isSuccess()) {
                    Log.w(TAG, "fetchUserPlaylistsWithTracks tracks ${tracksResp.status}: ${tracksResp.bodyAsText().take(300)}")
                    continue
                }
                val tracksRoot = json.parseToJsonElement(tracksResp.bodyAsText())
                val songs = if (tracksRoot is JsonArray) {
                    tracksRoot.mapNotNull { tItem ->
                        val tObj = tItem as? JsonObject ?: return@mapNotNull null
                        val vId = tObj.str("video_id") ?: return@mapNotNull null
                        val title = tObj.str("title") ?: return@mapNotNull null
                        val artist = tObj.str("artist") ?: ""
                        val thumb = tObj.str("thumbnail_url")?.takeIf { it.isNotBlank() && it != "null" }
                        val duration = tObj.str("duration_text")
                        Song(
                            videoId = vId,
                            title = title,
                            artist = artist,
                            thumbnailUrl = thumb,
                            durationText = duration,
                        )
                    }
                } else emptyList()

                val userPlaylist = UserPlaylist(
                    playlistId = pId,
                    title = pTitle,
                    subtitle = "${songs.size} " + if (songs.size == 1) "song" else "songs",
                    thumbnailUrl = pThumb ?: songs.firstOrNull()?.thumbnailUrl,
                )
                result.add(userPlaylist to songs)
            }
            result
        }
    }

    /**
     * Searches both profiles and posts across the Vibra Social database.
     */
    suspend fun searchPostsAndUsers(
        query: String,
        currentUserId: String = "",
        limit: Int = 20,
    ): Result<Pair<List<SocialProfile>, List<SocialPost>>> = withContext(Dispatchers.IO) {
        runCatching {
            val cleanQ = PostgrestSanitizer.escapeIlikePattern(query)
            if (cleanQ.isBlank()) return@runCatching (emptyList<SocialProfile>() to emptyList<SocialPost>())

            val encodedQ = "*$cleanQ*"

            val profilesResp = client.get(baseUrl("profiles")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("or", "(display_name.ilike.$encodedQ,handle.ilike.$encodedQ)")
                parameter("limit", limit)
            }
            val matchedProfiles = if (profilesResp.status.isSuccess()) {
                parseProfiles(profilesResp.bodyAsText())
            } else {
                Log.w(TAG, "searchProfiles ${profilesResp.status}: ${profilesResp.bodyAsText().take(300)}")
                emptyList()
            }

            val postsResp = client.get(baseUrl("posts")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("select", "*,profiles:author_id(*)")
                parameter("or", "(content.ilike.$encodedQ,music_track->>title.ilike.$encodedQ,music_track->>artist.ilike.$encodedQ)")
                parameter("order", "created_at.desc")
                parameter("limit", limit)
            }
            val matchedPosts = if (postsResp.status.isSuccess()) {
                parsePosts(postsResp.bodyAsText(), currentUserId)
            } else {
                Log.w(TAG, "searchPosts ${postsResp.status}: ${postsResp.bodyAsText().take(300)}")
                emptyList()
            }

            matchedProfiles to matchedPosts
        }
    }

    // ---- JSON Parsing Utilities ----------------------------------------------

    private fun jsonQuote(text: String): String = PostgrestSanitizer.safeJsonString(text)

    internal fun parseProfiles(raw: String): List<SocialProfile> {
        val root = runCatching { json.parseToJsonElement(raw) }.getOrNull()
        if (root !is JsonArray) {
            Log.w(TAG, "parseProfiles: expected array, got: ${raw.take(300)}")
            return emptyList()
        }
        return root.mapNotNull { element ->
            runCatching { parseProfileRow(element as JsonObject) }
                .onFailure { Log.w(TAG, "parseProfiles: skipping bad row: ${it.message}") }
                .getOrNull()
        }
    }

    internal fun parseProfileRow(obj: JsonObject): SocialProfile {
        val id = obj.str("id") ?: throw IllegalArgumentException("Missing profile id")
        val handle = obj.str("handle") ?: "user"
        val displayName = obj.str("display_name") ?: handle
        val avatarUrl = obj.str("avatar_url")?.takeIf { it.isNotBlank() && it != "null" }
        val bio = obj.str("bio") ?: ""
        val referralCode = obj.str("referral_code") ?: ""
        val invitedBy = obj.str("invited_by")?.takeIf { it.isNotBlank() && it != "null" }
        val invitesCount = obj.int("invites_count") ?: 0
        val quizLives = obj.int("quiz_lives") ?: 5
        val isUnlimitedLives = obj.bool("is_unlimited_lives") ?: false
        val country = obj.str("country") ?: ""
        val age = obj.int("age")
        val statusBubble = obj.str("status_bubble") ?: ""
        val bannerUrl = obj.str("banner_url")?.takeIf { it.isNotBlank() && it != "null" }
        val bannerPlaylists = obj.arr("banner_playlists")?.mapNotNull {
            (it as? JsonPrimitive)?.takeIf { p -> p !is JsonNull }?.content?.takeIf { s -> s.isNotBlank() }
        } ?: emptyList()
        val favoriteArtists = obj.arr("favorite_artists")?.mapNotNull { el ->
            val a = el as? JsonObject ?: return@mapNotNull null
            val aid = a.str("id") ?: a.str("artist_id") ?: return@mapNotNull null
            val aname = a.str("name") ?: a.str("artist_name") ?: ""
            val artwork = a.str("artwork_url") ?: a.str("avatar_url") ?: a.str("artist_artwork")
            FavoriteArtist(
                id = aid,
                name = aname,
                avatarUrl = artwork,
                artworkUrl = artwork,
            )
        } ?: emptyList()
        val followersCount = obj.int("followers_count") ?: 0
        val followingCount = obj.int("following_count") ?: 0
        val friendsCount = obj.int("friends_count") ?: 0
        val createdAt = obj.str("created_at") ?: ""
        val updatedAt = obj.str("updated_at") ?: ""

        return SocialProfile(
            id = id,
            handle = handle,
            displayName = displayName,
            avatarUrl = avatarUrl,
            bio = bio,
            referralCode = referralCode,
            invitedBy = invitedBy,
            invitesCount = invitesCount,
            quizLives = quizLives,
            isUnlimitedLives = isUnlimitedLives,
            followersCount = followersCount,
            followingCount = followingCount,
            friendsCount = friendsCount,
            country = country,
            age = age,
            statusBubble = statusBubble,
            bannerUrl = bannerUrl,
            bannerPlaylists = bannerPlaylists,
            favoriteArtists = favoriteArtists,
            createdAt = createdAt,
            updatedAt = updatedAt,
        )
    }

    internal fun parsePosts(
        raw: String,
        currentUserId: String,
        userLikedPostIds: Set<String> = emptySet(),
        userPollVotes: Map<String, Int> = emptyMap(),
    ): List<SocialPost> {
        val root = runCatching { json.parseToJsonElement(raw) }.getOrNull()
        if (root !is JsonArray) {
            Log.w(TAG, "parsePosts: expected array, got: ${raw.take(300)}")
            return emptyList()
        }
        return root.mapNotNull { element ->
            runCatching { parsePostRow(element as JsonObject, currentUserId, userLikedPostIds, userPollVotes) }
                .onFailure { Log.w(TAG, "parsePosts: skipping bad row: ${it.message}") }
                .getOrNull()
        }
    }

    internal fun parsePostRow(
        obj: JsonObject,
        currentUserId: String,
        userLikedPostIds: Set<String> = emptySet(),
        userPollVotes: Map<String, Int> = emptyMap(),
    ): SocialPost {
        val id = obj.str("id") ?: throw IllegalArgumentException("Missing post id")
        val authorId = obj.str("author_id") ?: throw IllegalArgumentException("Missing author_id")
        val content = obj.str("content") ?: ""
        val imageUrl = obj.str("image_url")?.takeIf { it.isNotBlank() && it != "null" }
        val imageUrls = obj.arr("image_urls")?.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p !is JsonNull }?.content?.takeIf { s -> s.isNotBlank() && s != "null" } } ?: emptyList()
        val videoUrl = obj.str("video_url")?.takeIf { it.isNotBlank() && it != "null" }
        var gifUrl = obj.str("gif_url")?.takeIf { it.isNotBlank() && it != "null" }
        if (gifUrl == null && (imageUrl?.endsWith(".gif", ignoreCase = true) == true || imageUrl?.contains("giphy", ignoreCase = true) == true || imageUrl?.contains("tenor", ignoreCase = true) == true)) {
            gifUrl = imageUrl
        }
        val quoteOfId = obj.str("quote_of_id")?.takeIf { it.isNotBlank() && it != "null" }
        val repostOfId = obj.str("repost_of_id")?.takeIf { it.isNotBlank() && it != "null" }
        val createdAt = obj.str("created_at") ?: ""
        var likesCount = obj["likes_count"]?.let { el ->
            if (el is JsonNull) 0
            else (el as? JsonPrimitive)?.intOrNull ?: throw IllegalArgumentException("Invalid likes_count: $el")
        } ?: 0
        val commentsCount = obj["comments_count"]?.let { el ->
            if (el is JsonNull) 0
            else (el as? JsonPrimitive)?.intOrNull ?: throw IllegalArgumentException("Invalid comments_count: $el")
        } ?: 0
        val repostsCount = obj["reposts_count"]?.let { el ->
            if (el is JsonNull) 0
            else (el as? JsonPrimitive)?.intOrNull ?: throw IllegalArgumentException("Invalid reposts_count: $el")
        } ?: 0

        val profileObj = obj.embeddedProfile("profiles")
        val author = profileObj?.let {
            SocialProfile(
                id = it.str("id") ?: authorId,
                handle = it.str("handle") ?: "",
                displayName = it.str("display_name") ?: "Listener",
                avatarUrl = it.str("avatar_url")?.takeIf { u -> u.isNotBlank() && u != "null" },
            )
        }

        // Extract optional music track attachment
        val musicTrack = obj.obj("music_track")?.let { m ->
            val art = m.str("artwork_url")?.takeIf { it.isNotBlank() && it != "null" }
            val thumb = m.str("thumbnail_url")?.takeIf { it.isNotBlank() && it != "null" } ?: art
            MusicTrackAttachment(
                videoId = m.str("video_id") ?: "",
                title = m.str("title") ?: "",
                artist = m.str("artist") ?: "",
                thumbnailUrl = thumb,
                durationText = m.str("duration_text")?.takeIf { it.isNotBlank() && it != "null" },
                artworkUrl = art ?: thumb,
            )
        }

        // Extract optional poll
        val poll = obj.obj("poll_data")?.let { p ->
            val question = p.str("question") ?: ""
            val endsAt = p.str("ends_at") ?: p.str("endsAt")
            val options = p.arr("options")?.mapIndexedNotNull { idx, opt ->
                val o = opt as? JsonObject ?: return@mapIndexedNotNull null
                val optImageUrl = o.str("image_url")?.takeIf { it.isNotBlank() && it != "null" }
                PollOption(
                    id = "$idx",
                    text = o.str("text") ?: "",
                    votes = o.int("votes") ?: 0,
                    imageUrl = optImageUrl,
                )
            } ?: emptyList()
            PollData(
                question = question,
                options = options,
                totalVotes = options.sumOf { it.votes },
                userVotedIndex = userPollVotes[id],
                endsAt = endsAt,
            )
        }

        val audioUrl = obj.str("audio_url")?.takeIf { it.isNotBlank() && it != "null" }
        val isReview = obj.bool("is_review") ?: (obj.str("is_review")?.toBooleanStrictOrNull() ?: false)
        val rating = obj.int("rating") ?: 0
        val taggedArtist = obj.str("tagged_artist")?.takeIf { it.isNotBlank() && it != "null" }
        val isRepostedByMe = if (currentUserId.isNotBlank()) {
            repostOfId != null && authorId == currentUserId
        } else false
        val isLikedByMe = userLikedPostIds.contains(id)
        if (isLikedByMe && likesCount == 0) likesCount = 1
        val isEdited = obj.bool("is_edited") ?: false
        val isDeleted = obj.bool("is_deleted") ?: (content.trim() == "[This post was deleted by the author]" || content.trim() == "This post was deleted by the author." || content.contains("deleted by the author", ignoreCase = true))

        return SocialPost(
            id = id,
            authorId = authorId,
            author = author,
            content = content,
            imageUrl = imageUrl,
            imageUrls = imageUrls,
            videoUrl = videoUrl,
            gifUrl = gifUrl,
            audioUrl = audioUrl,
            isReview = isReview,
            rating = rating,
            taggedArtist = taggedArtist,
            musicTrack = musicTrack,
            pollData = poll,
            likesCount = likesCount,
            commentsCount = commentsCount,
            repostsCount = repostsCount,
            quoteOfId = quoteOfId,
            repostOfId = repostOfId,
            isLikedByMe = isLikedByMe,
            isRepostedByMe = isRepostedByMe,
            isEdited = isEdited,
            isDeleted = isDeleted,
            createdAt = createdAt,
        )
    }

    internal fun parseComments(raw: String): List<PostComment> {
        val root = runCatching { json.parseToJsonElement(raw) }.getOrNull()
        if (root !is JsonArray) {
            Log.w(TAG, "parseComments: expected array, got: ${raw.take(300)}")
            return emptyList()
        }
        return root.mapNotNull { element ->
            runCatching { parseCommentRow(element as JsonObject) }
                .onFailure { Log.w(TAG, "parseComments: skipping bad row: ${it.message}") }
                .getOrNull()
        }
    }

    internal fun parseCommentRow(obj: JsonObject): PostComment {
        val id = obj.str("id") ?: throw IllegalArgumentException("Missing comment id")
        val postId = obj.str("post_id") ?: ""
        val authorId = obj.str("author_id") ?: ""
        val rawContent = obj.str("content") ?: ""
        var cleanContent = rawContent
        var gifUrl = obj.str("gif_url")?.takeIf { it.isNotBlank() && it != "null" }
        if (rawContent.contains("[gif:")) {
            val match = "\\[gif:(https?://[^\\]]+)\\]".toRegex().find(rawContent)
            if (match != null) {
                if (gifUrl == null) gifUrl = match.groupValues[1]
                cleanContent = rawContent.replace(match.value, "").trim()
            }
        }
        var imageUrl = obj.str("image_url")?.takeIf { it.isNotBlank() && it != "null" }
        if (cleanContent.contains("[image:")) {
            val match = "\\[image:(https?://[^\\]]+)\\]".toRegex().find(cleanContent)
            if (match != null) {
                if (imageUrl == null) imageUrl = match.groupValues[1]
                cleanContent = cleanContent.replace(match.value, "").trim()
            }
        }
        var videoUrl = obj.str("video_url")?.takeIf { it.isNotBlank() && it != "null" }
        if (cleanContent.contains("[video:")) {
            val match = "\\[video:(https?://[^\\]]+)\\]".toRegex().find(cleanContent)
            if (match != null) {
                if (videoUrl == null) videoUrl = match.groupValues[1]
                cleanContent = cleanContent.replace(match.value, "").trim()
            }
        }
        val parentId = obj.str("parent_id")?.takeIf { it.isNotBlank() && it != "null" }
        val createdAt = obj.str("created_at") ?: ""
        val likesCount = obj["likes_count"]?.let { el ->
            if (el is JsonNull) 0
            else (el as? JsonPrimitive)?.intOrNull ?: throw IllegalArgumentException("Invalid likes_count: $el")
        } ?: 0

        val profileObj = obj.embeddedProfile("profiles")
        val author = profileObj?.let {
            SocialProfile(
                id = it.str("id") ?: authorId,
                handle = it.str("handle") ?: "",
                displayName = it.str("display_name") ?: "Listener",
                avatarUrl = it.str("avatar_url")?.takeIf { u -> u.isNotBlank() && u != "null" },
            )
        } ?: SocialProfile(id = authorId, handle = "", displayName = "Listener")

        val isEdited = obj.bool("is_edited") ?: false
        val isDeleted = obj.bool("is_deleted") ?: (cleanContent.trim() == "[This comment was deleted by the user]" || cleanContent.trim() == "This comment has been deleted by the user." || cleanContent.contains("deleted by the user", ignoreCase = true))

        return PostComment(
            id = id,
            postId = postId,
            authorId = authorId,
            author = author,
            parentId = parentId,
            content = cleanContent,
            imageUrl = imageUrl,
            videoUrl = videoUrl,
            gifUrl = gifUrl,
            likesCount = likesCount,
            isEdited = isEdited,
            isDeleted = isDeleted,
            createdAt = createdAt,
        )
    }

    internal fun parseDirectMessages(raw: String): List<DirectMessage> {
        val root = runCatching { json.parseToJsonElement(raw) }.getOrNull()
        if (root !is JsonArray) {
            Log.w(TAG, "parseDirectMessages: expected array, got: ${raw.take(300)}")
            return emptyList()
        }
        return root.mapNotNull { element ->
            runCatching { parseDmRow(element as JsonObject) }
                .onFailure { Log.w(TAG, "parseDirectMessages: skipping bad row: ${it.message}") }
                .getOrNull()
        }
    }

    internal fun parseDmRow(obj: JsonObject): DirectMessage {
        val id = obj.str("id") ?: throw IllegalArgumentException("Missing message id")
        val senderId = obj.str("sender_id") ?: ""
        val receiverId = obj.str("receiver_id") ?: ""
        val rawContent = obj.str("content") ?: ""
        var cleanContent = rawContent
        var imageUrl = obj.str("image_url")?.takeIf { it.isNotBlank() && it != "null" }
        var videoUrl = obj.str("video_url")?.takeIf { it.isNotBlank() && it != "null" }
        var audioUrl = obj.str("audio_url")?.takeIf { it.isNotBlank() && it != "null" }
        var gifUrl = obj.str("gif_url")?.takeIf { it.isNotBlank() && it != "null" }

        val tagRegex = "\\[(image|video|audio|gif):(https?://[^\\]]+)\\]".toRegex()
        tagRegex.findAll(rawContent).forEach { match ->
            val type = match.groupValues[1]
            val url = match.groupValues[2].takeIf { it.isNotBlank() && it != "null" }
            when (type) {
                "image" -> if (imageUrl == null) imageUrl = url
                "video" -> if (videoUrl == null) videoUrl = url
                "audio" -> if (audioUrl == null) audioUrl = url
                "gif" -> if (gifUrl == null) gifUrl = url
            }
        }
        val replyRegex = "\\[reply:([^:]*):([^:]*):([^\\]]*)\\]".toRegex()
        val replyMatch = replyRegex.find(rawContent)
        var replyToId: String? = null
        var replyToSender: String? = null
        var replyToText: String? = null
        if (replyMatch != null) {
            replyToId = replyMatch.groupValues[1].takeIf { it.isNotBlank() }
            replyToSender = replyMatch.groupValues[2].takeIf { it.isNotBlank() }
            val encoded = replyMatch.groupValues[3]
            replyToText = runCatching {
                String(android.util.Base64.decode(encoded, android.util.Base64.NO_WRAP), Charsets.UTF_8)
            }.getOrNull() ?: encoded
        }

        val musicRegex = "\\[music:([^:]*):([^:]*):([^:]*):([^\\]]*)\\]".toRegex()
        val musicMatch = musicRegex.find(rawContent)
        var parsedMusic: MusicTrackAttachment? = null
        if (musicMatch != null) {
            val vId = musicMatch.groupValues[1]
            val encT = musicMatch.groupValues[2]
            val encA = musicMatch.groupValues[3]
            val encTh = musicMatch.groupValues[4]
            val t = runCatching { String(android.util.Base64.decode(encT, android.util.Base64.NO_WRAP), Charsets.UTF_8) }.getOrDefault(encT)
            val a = runCatching { String(android.util.Base64.decode(encA, android.util.Base64.NO_WRAP), Charsets.UTF_8) }.getOrDefault(encA)
            val th = runCatching { String(android.util.Base64.decode(encTh, android.util.Base64.NO_WRAP), Charsets.UTF_8) }.getOrDefault(encTh)
                .takeIf { it.isNotBlank() && it != "null" } ?: "https://i.ytimg.com/vi/$vId/hqdefault.jpg"
            parsedMusic = MusicTrackAttachment(videoId = vId, title = t, artist = a, thumbnailUrl = th)
        }

        val playlistRegex = "\\[playlist:([^:]*):([^:]*):([^:]*):([^\\]]*)\\]".toRegex()
        val playlistMatch = playlistRegex.find(rawContent)
        var parsedPlaylist: SharedPlaylistAttachment? = null
        if (playlistMatch != null) {
            val pId = playlistMatch.groupValues[1]
            val encT = playlistMatch.groupValues[2]
            val encA = playlistMatch.groupValues[3]
            val encTh = playlistMatch.groupValues[4]
            val t = runCatching { String(android.util.Base64.decode(encT, android.util.Base64.NO_WRAP), Charsets.UTF_8) }.getOrDefault(encT)
            val a = runCatching { String(android.util.Base64.decode(encA, android.util.Base64.NO_WRAP), Charsets.UTF_8) }.getOrDefault(encA)
            val th = runCatching { String(android.util.Base64.decode(encTh, android.util.Base64.NO_WRAP), Charsets.UTF_8) }.getOrDefault(encTh)
                .takeIf { it.isNotBlank() && it != "null" }
            parsedPlaylist = SharedPlaylistAttachment(playlistId = pId, title = t, author = a, thumbnailUrl = th)
        }

        cleanContent = rawContent.replace(tagRegex, "").replace(replyRegex, "").replace(musicRegex, "").replace(playlistRegex, "").trim()

        val isRead = obj.bool("is_read") ?: false
        val createdAt = obj.str("created_at") ?: ""

        val sharedMusicObj = obj.obj("shared_music")?.let { m ->
            MusicTrackAttachment(
                videoId = m.str("video_id") ?: "",
                title = m.str("title") ?: "",
                artist = m.str("artist") ?: "",
                thumbnailUrl = m.str("thumbnail_url")?.takeIf { it.isNotBlank() && it != "null" },
                durationText = m.str("duration_text")?.takeIf { it.isNotBlank() && it != "null" },
            )
        }

        val sharedPlaylistObj = obj.obj("shared_playlist")?.let { p ->
            SharedPlaylistAttachment(
                playlistId = p.str("playlist_id") ?: "",
                title = p.str("title") ?: "",
                author = p.str("author") ?: "",
                thumbnailUrl = p.str("thumbnail_url")?.takeIf { it.isNotBlank() && it != "null" },
                trackCount = p.int("track_count") ?: 0,
            )
        }

        val effectiveMusic = (sharedMusicObj ?: parsedMusic)?.let {
            if (it.thumbnailUrl.isNullOrBlank() && it.videoId.isNotBlank()) {
                it.copy(thumbnailUrl = "https://i.ytimg.com/vi/${it.videoId}/maxresdefault.jpg")
            } else it
        }

        val effectivePlaylist = sharedPlaylistObj ?: parsedPlaylist

        val isEdited = obj.bool("is_edited") ?: false

        return DirectMessage(
            id = id,
            senderId = senderId,
            receiverId = receiverId,
            content = cleanContent,
            imageUrl = imageUrl,
            videoUrl = videoUrl,
            audioUrl = audioUrl,
            gifUrl = gifUrl,
            sharedMusic = effectiveMusic,
            sharedPlaylist = effectivePlaylist,
            replyToId = replyToId,
            replyToSender = replyToSender,
            replyToText = replyToText,
            isRead = isRead,
            isEdited = isEdited,
            createdAt = createdAt,
        )
    }

    internal fun parseNotifications(raw: String, currentUserId: String): List<SocialNotification> {
        val root = runCatching { json.parseToJsonElement(raw) }.getOrNull()
        if (root !is JsonArray) {
            Log.w(TAG, "parseNotifications: expected array, got: ${raw.take(300)}")
            return emptyList()
        }
        return root.mapNotNull { element ->
            runCatching { parseNotificationRow(element as JsonObject, currentUserId) }
                .onFailure { Log.w(TAG, "parseNotifications: skipping bad row: ${it.message}") }
                .getOrNull()
        }
    }

    internal fun parseNotificationRow(obj: JsonObject, currentUserId: String): SocialNotification {
        val id = obj.str("id") ?: throw IllegalArgumentException("Missing notification id")
        val actorId = obj.str("actor_id") ?: ""
        val actorName = obj.str("actor_name") ?: "A listener"
        val actorAvatar = obj.str("actor_avatar")?.takeIf { it.isNotBlank() && it != "null" }
        val actorHandle = obj.str("actor_handle") ?: ""
        val typeStr = obj.str("type") ?: "LIKE"
        val type = runCatching { NotificationType.valueOf(typeStr) }.getOrDefault(NotificationType.LIKE)
        val targetPostId = obj.str("target_post_id")?.takeIf { it.isNotBlank() && it != "null" }
        val message = obj.str("message") ?: ""
        val isRead = obj.bool("is_read") ?: false
        val createdAt = obj.str("created_at") ?: ""

        return SocialNotification(
            id = id,
            userId = currentUserId,
            actorId = actorId,
            actorName = actorName,
            actorAvatar = actorAvatar,
            actorHandle = actorHandle,
            type = type,
            targetPostId = targetPostId,
            message = message,
            isRead = isRead,
            createdAt = createdAt,
        )
    }

    internal fun parseLeaderboard(raw: String, currentUserId: String): List<LeaderboardEntry> {
        val root = runCatching { json.parseToJsonElement(raw) }.getOrNull()
        if (root !is JsonArray) {
            Log.w(TAG, "parseLeaderboard: expected array, got: ${raw.take(300)}")
            return emptyList()
        }
        val allEntries = root.mapIndexedNotNull { index, element ->
            runCatching { parseLeaderboardRow(index, element as JsonObject, currentUserId) }
                .onFailure { Log.w(TAG, "parseLeaderboard: skipping bad row: ${it.message}") }
                .getOrNull()
        }
        val distinctByUser = allEntries.distinctBy { it.userId }
        return distinctByUser.mapIndexed { index, entry ->
            entry.copy(id = "$index", rank = index + 1)
        }
    }

    internal fun parseLeaderboardRow(index: Int, obj: JsonObject, currentUserId: String): LeaderboardEntry {
        val userId = obj.str("user_id") ?: throw IllegalArgumentException("Missing user_id")
        val score = obj.int("score") ?: 0
        val total = obj.int("total_questions") ?: 10
        val time = obj.double("time_seconds") ?: 0.0
        val createdAt = obj.str("created_at") ?: ""

        val profileObj = obj.embeddedProfile("profiles")
        val handle = profileObj?.str("handle") ?: "user_${userId.takeLast(4)}"
        val displayName = profileObj?.str("display_name") ?: handle
        val avatarUrl = profileObj?.str("avatar_url")?.takeIf { it.isNotBlank() && it != "null" }

        return LeaderboardEntry(
            id = "$index",
            rank = index + 1,
            userId = userId,
            handle = handle,
            displayName = displayName,
            avatarUrl = avatarUrl,
            score = score,
            totalQuestions = total,
            timeSeconds = time,
            isCurrentUser = userId == currentUserId,
            createdAt = createdAt,
        )
    }
}
