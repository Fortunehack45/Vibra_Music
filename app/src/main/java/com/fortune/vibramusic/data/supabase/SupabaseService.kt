package com.fortune.vibramusic.data.supabase

import com.fortune.vibramusic.auth.GoogleAccountSession
import com.fortune.vibramusic.auth.YouTubeProfile
import com.fortune.vibramusic.data.DebugLog as Log
import com.fortune.vibramusic.data.quiz.LeaderboardEntry
import com.fortune.vibramusic.data.quiz.QuizArtist
import com.fortune.vibramusic.data.quiz.QuizScoreResult
import com.fortune.vibramusic.data.social.DirectMessage
import com.fortune.vibramusic.data.social.FavoriteArtist
import com.fortune.vibramusic.data.social.Friendship
import com.fortune.vibramusic.data.social.FriendshipStatus
import com.fortune.vibramusic.data.social.MusicTrackAttachment
import com.fortune.vibramusic.data.social.PollData
import com.fortune.vibramusic.data.social.PollOption
import com.fortune.vibramusic.data.social.PostComment
import com.fortune.vibramusic.data.social.SocialPost
import com.fortune.vibramusic.data.social.SocialProfile
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
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
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

    private fun baseUrl(table: String): String = "${SupabaseConfig.url.trimEnd('/')}/rest/v1/$table"

    /**
     * Synchronizes the user's active YouTube identity into Supabase profiles table.
     */
    suspend fun syncUserProfile(
        session: GoogleAccountSession,
        profile: YouTubeProfile?,
    ): Result<SocialProfile> = withContext(Dispatchers.IO) {
        runCatching {
            val userId = profile?.profileId ?: session.accountId
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

            val response = client.post(baseUrl("profiles")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                header("Prefer", "resolution=merge-duplicates,return=representation")
                contentType(ContentType.Application.Json)
                setBody(body)
            }

            if (!response.status.isSuccess()) {
                val errorText = response.bodyAsText()
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
     * Fetches public posts for either the For You or Friends feed.
     */
    suspend fun fetchPosts(
        forUserId: String? = null,
        friendsOnly: Boolean = false,
        limit: Int = 30,
        offset: Int = 0,
    ): Result<List<SocialPost>> = withContext(Dispatchers.IO) {
        runCatching {
            val url = baseUrl("posts")
            val response = client.get(url) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("select", "*,profiles:author_id(*)")
                parameter("order", "created_at.desc")
                parameter("limit", limit)
                parameter("offset", offset)
            }

            if (!response.status.isSuccess()) {
                Log.w(TAG, "fetchPosts failed with ${response.status}")
                return@runCatching emptyList()
            }

            parsePosts(response.bodyAsText(), forUserId ?: "")
        }
    }

    /**
     * Fetches posts authored by a specific user.
     */
    suspend fun fetchUserPosts(userId: String): Result<List<SocialPost>> = withContext(Dispatchers.IO) {
        runCatching {
            val response = client.get(baseUrl("posts")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("author_id", "eq.$userId")
                parameter("select", "*,profiles:author_id(*)")
                parameter("order", "created_at.desc")
            }
            parsePosts(response.bodyAsText(), userId)
        }
    }

    /**
     * Publishes a new social post.
     */
    suspend fun createPost(
        author: SocialProfile,
        content: String,
        musicAttachment: MusicTrackAttachment? = null,
        poll: PollData? = null,
    ): Result<SocialPost> = withContext(Dispatchers.IO) {
        runCatching {
            val postId = UUID.randomUUID().toString()
            val musicTrackJson = musicAttachment?.let {
                "{\"video_id\":\"${it.videoId}\",\"title\":${jsonQuote(it.title)},\"artist\":${jsonQuote(it.artist)},\"thumbnail_url\":${jsonQuote(it.thumbnailUrl ?: "")},\"duration_text\":${jsonQuote(it.durationText ?: "")}}"
            }

            val pollJson = poll?.let {
                val optionsArray = it.options.joinToString(",") { opt ->
                    "{\"text\":${jsonQuote(opt.text)},\"votes\":${opt.votes}}"
                }
                "{\"question\":${jsonQuote(it.question)},\"options\":[$optionsArray]}"
            }

            val body = buildString {
                append("{")
                append("\"id\":\"$postId\",")
                append("\"author_id\":\"${author.id}\",")
                append("\"content\":${jsonQuote(content)}")
                if (musicTrackJson != null) append(",\"music_track\":$musicTrackJson")
                if (pollJson != null) append(",\"poll_data\":$pollJson")
                append("}")
            }

            val response = client.post(baseUrl("posts")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                header("Prefer", "return=representation")
                contentType(ContentType.Application.Json)
                setBody(body)
            }

            SocialPost(
                id = postId,
                authorId = author.id,
                author = author,
                content = content,
                musicTrack = musicAttachment,
                pollData = poll,
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
                    client.delete(baseUrl("post_likes")) {
                        header("apikey", SupabaseConfig.anonKey)
                        header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                        parameter("post_id", "eq.$postId")
                        parameter("user_id", "eq.$userId")
                    }
                } else {
                    client.post(baseUrl("post_likes")) {
                        header("apikey", SupabaseConfig.anonKey)
                        header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                        contentType(ContentType.Application.Json)
                        setBody("{\"post_id\":\"$postId\",\"user_id\":\"$userId\"}")
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
            client.post(baseUrl("posts")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                contentType(ContentType.Application.Json)
                setBody("{\"id\":\"$newPostId\",\"author_id\":\"${user.id}\",\"repost_of_id\":\"$postId\",\"content\":\"\"}")
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
     * Casts a vote on a poll.
     */
    suspend fun votePoll(postId: String, optionIndex: Int, userId: String): Result<Unit> =
        withContext(Dispatchers.IO) {
            runCatching {
                // Submit poll vote event
                client.post(baseUrl("poll_votes")) {
                    header("apikey", SupabaseConfig.anonKey)
                    header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                    contentType(ContentType.Application.Json)
                    setBody("{\"post_id\":\"$postId\",\"option_index\":$optionIndex,\"user_id\":\"$userId\"}")
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
    ): Result<PostComment> = withContext(Dispatchers.IO) {
        runCatching {
            val commentId = UUID.randomUUID().toString()
            val body = buildString {
                append("{")
                append("\"id\":\"$commentId\",")
                append("\"post_id\":\"$postId\",")
                append("\"author_id\":\"${user.id}\",")
                append("\"content\":${jsonQuote(content)}")
                if (parentCommentId != null) append(",\"parent_id\":\"$parentCommentId\"")
                append("}")
            }

            client.post(baseUrl("post_comments")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                contentType(ContentType.Application.Json)
                setBody(body)
            }

            PostComment(
                id = commentId,
                postId = postId,
                authorId = user.id,
                author = user,
                parentId = parentCommentId,
                content = content,
            )
        }
    }

    /**
     * Fetches comments for a specific post.
     */
    suspend fun fetchComments(postId: String): Result<List<PostComment>> =
        withContext(Dispatchers.IO) {
            runCatching {
                val response = client.get(baseUrl("post_comments")) {
                    header("apikey", SupabaseConfig.anonKey)
                    header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                    parameter("post_id", "eq.$postId")
                    parameter("select", "*,profiles:author_id(*)")
                    parameter("order", "created_at.asc")
                }
                parseComments(response.bodyAsText())
            }
        }

    /**
     * Fetches friends list and active conversations for the user.
     */
    suspend fun fetchConversations(userId: String): Result<List<SocialProfile>> = withContext(Dispatchers.IO) {
        runCatching {
            val response = client.get(baseUrl("profiles")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("id", "neq.$userId")
                parameter("limit", "20")
            }
            parseProfiles(response.bodyAsText())
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
            parseDirectMessages(response.bodyAsText())
        }
    }

    /**
     * Sends a direct message with optional attached music card.
     */
    suspend fun sendDirectMessage(
        senderId: String,
        recipientId: String,
        message: String,
        trackAttachment: MusicTrackAttachment? = null,
    ): Result<DirectMessage> = withContext(Dispatchers.IO) {
        runCatching {
            val messageId = UUID.randomUUID().toString()
            val sharedMusicJson = trackAttachment?.let {
                "{\"video_id\":\"${it.videoId}\",\"title\":${jsonQuote(it.title)},\"artist\":${jsonQuote(it.artist)},\"thumbnail_url\":${jsonQuote(it.thumbnailUrl ?: "")},\"duration_text\":${jsonQuote(it.durationText ?: "")}}"
            }

            val body = buildString {
                append("{")
                append("\"id\":\"$messageId\",")
                append("\"sender_id\":\"$senderId\",")
                append("\"receiver_id\":\"$recipientId\",")
                append("\"content\":${jsonQuote(message)}")
                if (sharedMusicJson != null) append(",\"shared_music\":$sharedMusicJson")
                append("}")
            }
            client.post(baseUrl("direct_messages")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                contentType(ContentType.Application.Json)
                setBody(body)
            }

            DirectMessage(
                id = messageId,
                senderId = senderId,
                receiverId = recipientId,
                content = message,
                sharedMusic = trackAttachment,
            )
        }
    }

    /**
     * Follows or unfollows a target user.
     */
    suspend fun toggleFollow(followerId: String, targetUserId: String, follow: Boolean): Result<Unit> =
        withContext(Dispatchers.IO) {
            runCatching {
                if (follow) {
                    client.post(baseUrl("follows")) {
                        header("apikey", SupabaseConfig.anonKey)
                        header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                        contentType(ContentType.Application.Json)
                        setBody("{\"follower_id\":\"$followerId\",\"following_id\":\"$targetUserId\"}")
                    }
                } else {
                    client.delete(baseUrl("follows")) {
                        header("apikey", SupabaseConfig.anonKey)
                        header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                        parameter("follower_id", "eq.$followerId")
                        parameter("following_id", "eq.$targetUserId")
                    }
                }
                Unit
            }
        }

    /**
     * Sends a friend request.
     */
    suspend fun sendFriendRequest(requesterId: String, targetUserId: String): Result<Unit> =
        withContext(Dispatchers.IO) {
            runCatching {
                client.post(baseUrl("friendships")) {
                    header("apikey", SupabaseConfig.anonKey)
                    header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                    contentType(ContentType.Application.Json)
                    setBody("{\"requester_id\":\"$requesterId\",\"receiver_id\":\"$targetUserId\",\"status\":\"PENDING\"}")
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
            val array = json.parseToJsonElement(response.bodyAsText()).jsonArray
            array.mapNotNull {
                val obj = it.jsonObject
                FavoriteArtist(
                    id = obj["artist_id"]?.jsonPrimitive?.content ?: return@mapNotNull null,
                    name = obj["artist_name"]?.jsonPrimitive?.content ?: "",
                    avatarUrl = obj["artist_artwork"]?.jsonPrimitive?.content,
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
                val artwork = artist.artworkUrl
                val body = buildString {
                    append("{")
                    append("\"user_id\":\"$userId\",")
                    append("\"artist_id\":\"${artist.id}\",")
                    append("\"artist_name\":${jsonQuote(artist.name)}")
                    if (artwork != null) append(",\"artist_artwork\":${jsonQuote(artwork)}")
                    append("}")
                }
                client.post(baseUrl("favorite_artists")) {
                    header("apikey", SupabaseConfig.anonKey)
                    header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                    contentType(ContentType.Application.Json)
                    setBody(body)
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
                client.delete(baseUrl("favorite_artists")) {
                    header("apikey", SupabaseConfig.anonKey)
                    header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                    parameter("user_id", "eq.$userId")
                    parameter("artist_id", "eq.$artistId")
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
                client.post(baseUrl("quiz_leaderboards")) {
                    header("apikey", SupabaseConfig.anonKey)
                    header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                    contentType(ContentType.Application.Json)
                    setBody(body)
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
            parseLeaderboard(response.bodyAsText(), currentUserId)
        }
    }

    // ---- JSON Parsing Utilities ----------------------------------------------

    private fun jsonQuote(text: String): String =
        "\"" + text.replace("\\", "\\\\")
            .replace("\"", "\\\"")
            .replace("\n", "\\n")
            .replace("\r", "\\r") + "\""

    private fun parseProfiles(raw: String): List<SocialProfile> = runCatching {
        val array = json.parseToJsonElement(raw).jsonArray
        array.mapNotNull { element ->
            val obj = element.jsonObject
            val id = obj["id"]?.jsonPrimitive?.content ?: return@mapNotNull null
            val handle = obj["handle"]?.jsonPrimitive?.content ?: "user"
            val displayName = obj["display_name"]?.jsonPrimitive?.content ?: handle
            val avatarUrl = obj["avatar_url"]?.jsonPrimitive?.content
            SocialProfile(
                id = id,
                handle = handle,
                displayName = displayName,
                avatarUrl = avatarUrl,
            )
        }
    }.getOrDefault(emptyList())

    private fun parsePosts(raw: String, currentUserId: String): List<SocialPost> = runCatching {
        val array = json.parseToJsonElement(raw).jsonArray
        array.mapNotNull { element ->
            val obj = element.jsonObject
            val id = obj["id"]?.jsonPrimitive?.content ?: return@mapNotNull null
            val authorId = obj["author_id"]?.jsonPrimitive?.content ?: ""
            val content = obj["content"]?.jsonPrimitive?.content ?: ""
            val imageUrl = obj["image_url"]?.jsonPrimitive?.content
            val createdAt = obj["created_at"]?.jsonPrimitive?.content ?: ""
            val likesCount = obj["likes_count"]?.jsonPrimitive?.intOrNull ?: 0
            val commentsCount = obj["comments_count"]?.jsonPrimitive?.intOrNull ?: 0

            val profileObj = obj["profiles"]?.jsonObject
            val author = profileObj?.let {
                SocialProfile(
                    id = it["id"]?.jsonPrimitive?.content ?: authorId,
                    handle = it["handle"]?.jsonPrimitive?.content ?: "",
                    displayName = it["display_name"]?.jsonPrimitive?.content ?: "Listener",
                    avatarUrl = it["avatar_url"]?.jsonPrimitive?.content,
                )
            }

            // Extract optional music track attachment
            val musicTrack = obj["music_track"]?.jsonObject?.let { m ->
                MusicTrackAttachment(
                    videoId = m["video_id"]?.jsonPrimitive?.content ?: "",
                    title = m["title"]?.jsonPrimitive?.content ?: "",
                    artist = m["artist"]?.jsonPrimitive?.content ?: "",
                    thumbnailUrl = m["thumbnail_url"]?.jsonPrimitive?.content,
                    durationText = m["duration_text"]?.jsonPrimitive?.content,
                )
            }

            // Extract optional poll
            val poll = obj["poll_data"]?.jsonObject?.let { p ->
                val question = p["question"]?.jsonPrimitive?.content ?: ""
                val options = p["options"]?.jsonArray?.mapIndexed { idx, opt ->
                    val o = opt.jsonObject
                    PollOption(
                        id = "$idx",
                        text = o["text"]?.jsonPrimitive?.content ?: "",
                        votes = o["votes"]?.jsonPrimitive?.intOrNull ?: 0,
                    )
                } ?: emptyList()
                PollData(question = question, options = options, totalVotes = options.sumOf { it.votes })
            }

            SocialPost(
                id = id,
                authorId = authorId,
                author = author,
                content = content,
                imageUrl = imageUrl,
                musicTrack = musicTrack,
                pollData = poll,
                likesCount = likesCount,
                commentsCount = commentsCount,
                createdAt = createdAt,
            )
        }
    }.getOrDefault(emptyList())

    private fun parseComments(raw: String): List<PostComment> = runCatching {
        val array = json.parseToJsonElement(raw).jsonArray
        array.mapNotNull { element ->
            val obj = element.jsonObject
            val id = obj["id"]?.jsonPrimitive?.content ?: return@mapNotNull null
            val postId = obj["post_id"]?.jsonPrimitive?.content ?: ""
            val authorId = obj["author_id"]?.jsonPrimitive?.content ?: ""
            val content = obj["content"]?.jsonPrimitive?.content ?: ""
            val parentId = obj["parent_id"]?.jsonPrimitive?.content
            val createdAt = obj["created_at"]?.jsonPrimitive?.content ?: ""

            val profileObj = obj["profiles"]?.jsonObject
            val author = profileObj?.let {
                SocialProfile(
                    id = it["id"]?.jsonPrimitive?.content ?: authorId,
                    handle = it["handle"]?.jsonPrimitive?.content ?: "",
                    displayName = it["display_name"]?.jsonPrimitive?.content ?: "Listener",
                    avatarUrl = it["avatar_url"]?.jsonPrimitive?.content,
                )
            }

            PostComment(
                id = id,
                postId = postId,
                authorId = authorId,
                author = author,
                parentId = parentId,
                content = content,
                createdAt = createdAt,
            )
        }
    }.getOrDefault(emptyList())

    private fun parseDirectMessages(raw: String): List<DirectMessage> = runCatching {
        val array = json.parseToJsonElement(raw).jsonArray
        array.mapNotNull { element ->
            val obj = element.jsonObject
            val id = obj["id"]?.jsonPrimitive?.content ?: return@mapNotNull null
            val senderId = obj["sender_id"]?.jsonPrimitive?.content ?: ""
            val receiverId = obj["receiver_id"]?.jsonPrimitive?.content ?: ""
            val content = obj["content"]?.jsonPrimitive?.content ?: ""
            val isRead = obj["is_read"]?.jsonPrimitive?.booleanOrNull ?: false
            val createdAt = obj["created_at"]?.jsonPrimitive?.content ?: ""

            val sharedMusic = obj["shared_music"]?.jsonObject?.let { m ->
                MusicTrackAttachment(
                    videoId = m["video_id"]?.jsonPrimitive?.content ?: "",
                    title = m["title"]?.jsonPrimitive?.content ?: "",
                    artist = m["artist"]?.jsonPrimitive?.content ?: "",
                    thumbnailUrl = m["thumbnail_url"]?.jsonPrimitive?.content,
                    durationText = m["duration_text"]?.jsonPrimitive?.content,
                )
            }

            DirectMessage(
                id = id,
                senderId = senderId,
                receiverId = receiverId,
                content = content,
                sharedMusic = sharedMusic,
                isRead = isRead,
                createdAt = createdAt,
            )
        }
    }.getOrDefault(emptyList())

    private fun parseLeaderboard(raw: String, currentUserId: String): List<LeaderboardEntry> =
        runCatching {
            val array = json.parseToJsonElement(raw).jsonArray
            array.mapIndexedNotNull { index, element ->
                val obj = element.jsonObject
                val userId = obj["user_id"]?.jsonPrimitive?.content ?: return@mapIndexedNotNull null
                val score = obj["score"]?.jsonPrimitive?.intOrNull ?: 0
                val total = obj["total_questions"]?.jsonPrimitive?.intOrNull ?: 10
                val time = obj["time_seconds"]?.jsonPrimitive?.doubleOrNull ?: 0.0
                val createdAt = obj["created_at"]?.jsonPrimitive?.content ?: ""

                val profileObj = obj["profiles"]?.jsonObject
                val handle = profileObj?.get("handle")?.jsonPrimitive?.content ?: "user_${userId.takeLast(4)}"
                val displayName = profileObj?.get("display_name")?.jsonPrimitive?.content ?: handle
                val avatarUrl = profileObj?.get("avatar_url")?.jsonPrimitive?.content

                LeaderboardEntry(
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
        }.getOrDefault(emptyList())
}
