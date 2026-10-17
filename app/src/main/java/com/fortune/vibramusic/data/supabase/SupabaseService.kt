package com.fortune.vibramusic.data.supabase

import com.fortune.vibramusic.auth.GoogleAccountSession
import com.fortune.vibramusic.auth.YouTubeProfile
import com.fortune.vibramusic.data.DebugLog as Log
import com.fortune.vibramusic.data.quiz.LeaderboardEntry
import com.fortune.vibramusic.data.quiz.QuizArtist
import com.fortune.vibramusic.data.quiz.QuizScoreResult
import com.fortune.vibramusic.data.model.Song
import com.fortune.vibramusic.data.model.UserPlaylist
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

            val response = client.post("${baseUrl("profiles")}?on_conflict=id") {
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
                "{\"video_id\":\"${it.videoId}\",\"title\":${jsonQuote(it.title)},\"artist\":${jsonQuote(it.artist)},\"thumbnail_url\":${jsonQuote(it.thumbnailUrl ?: "")},\"duration_text\":${jsonQuote(it.durationText ?: "")}}"
            }

            val pollJson = poll?.let {
                val optionsArray = it.options.joinToString(",") { opt ->
                    "{\"text\":${jsonQuote(opt.text)},\"votes\":${opt.votes}}"
                }
                "{\"question\":${jsonQuote(it.question)},\"options\":[$optionsArray]}"
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
                val err = response.bodyAsText()
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
     * Toggles repost of a post ensuring single repost per user.
     */
    suspend fun toggleRepost(postId: String, user: SocialProfile, currentlyReposted: Boolean): Result<Boolean> =
        withContext(Dispatchers.IO) {
            runCatching {
                if (currentlyReposted) {
                    client.delete(baseUrl("posts")) {
                        header("apikey", SupabaseConfig.anonKey)
                        header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                        parameter("author_id", "eq.${user.id}")
                        parameter("repost_of_id", "eq.$postId")
                    }
                    false
                } else {
                    val newPostId = UUID.randomUUID().toString()
                    client.post(baseUrl("posts")) {
                        header("apikey", SupabaseConfig.anonKey)
                        header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                        contentType(ContentType.Application.Json)
                        setBody("{\"id\":\"$newPostId\",\"author_id\":\"${user.id}\",\"repost_of_id\":\"$postId\",\"content\":\"\"}")
                    }
                    true
                }
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
        gifUrl: String? = null,
    ): Result<PostComment> = withContext(Dispatchers.IO) {
        runCatching {
            val commentId = UUID.randomUUID().toString()
            val finalContent = if (!gifUrl.isNullOrBlank()) {
                if (content.isNotBlank()) "[gif:$gifUrl] $content" else "[gif:$gifUrl]"
            } else content

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
                Log.w(TAG, "addComment failed with status ${response.status}: ${response.bodyAsText()}")
            }

            PostComment(
                id = commentId,
                postId = postId,
                authorId = user.id,
                author = user,
                parentId = parentCommentId,
                content = content,
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
            val element = json.parseToJsonElement(response.bodyAsText()).jsonArray
            element.mapNotNull { it.jsonObject["comment_id"]?.jsonPrimitive?.content }.toSet()
        }
    }

    /**
     * Likes or unlikes a comment.
     */
    suspend fun toggleLikeComment(commentId: String, userId: String, liked: Boolean): Result<Unit> =
        withContext(Dispatchers.IO) {
            runCatching {
                if (!liked) {
                    client.delete(baseUrl("comment_likes")) {
                        header("apikey", SupabaseConfig.anonKey)
                        header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                        parameter("comment_id", "eq.$commentId")
                        parameter("user_id", "eq.$userId")
                    }
                } else {
                    client.post(baseUrl("comment_likes")) {
                        header("apikey", SupabaseConfig.anonKey)
                        header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                        contentType(ContentType.Application.Json)
                        setBody("{\"comment_id\":\"$commentId\",\"user_id\":\"$userId\"}")
                    }
                }
                Unit
            }
        }

    /**
     * Updates editable fields of a user's social profile.
     * Uses POST with merge-duplicates so the profile is always created if it did not exist yet.
     */
    suspend fun updateUserProfile(
        userId: String,
        displayName: String,
        handle: String,
        bio: String,
        avatarUrl: String? = null,
    ): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val body = buildString {
                append("{")
                append("\"id\":\"$userId\",")
                append("\"display_name\":${jsonQuote(displayName)},")
                append("\"handle\":${jsonQuote(handle)},")
                append("\"bio\":${jsonQuote(bio)}")
                if (avatarUrl != null) append(",\"avatar_url\":${jsonQuote(avatarUrl)}")
                append(",\"referral_code\":\"vibra_${userId.takeLast(6)}\"")
                append("}")
            }
            val response = client.post("${baseUrl("profiles")}?on_conflict=id") {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                header("Prefer", "resolution=merge-duplicates")
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            if (!response.status.isSuccess()) {
                val errorText = response.bodyAsText()
                Log.w(TAG, "updateUserProfile returned status ${response.status}: $errorText")
            }
            Unit
        }
    }

    /**
     * Fetches a single user's profile by ID.
     */
    suspend fun fetchUserProfile(userId: String): Result<SocialProfile?> = withContext(Dispatchers.IO) {
        runCatching {
            val response = client.get(baseUrl("profiles")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("id", "eq.$userId")
                parameter("limit", "1")
            }
            if (!response.status.isSuccess()) {
                null
            } else {
                parseProfiles(response.bodyAsText()).firstOrNull()
            }
        }
    }

    /**
     * Uploads media (images or videos) to Supabase Storage bucket 'vibra_social'.
     * Returns the publicly accessible URL of the uploaded media file.
     */
    suspend fun uploadMedia(
        bytes: ByteArray,
        mimeType: String = "image/jpeg",
        fileName: String = "${UUID.randomUUID()}.${if (mimeType.contains("video")) "mp4" else "jpg"}",
    ): Result<String> = withContext(Dispatchers.IO) {
        runCatching {
            val uploadUrl = "${SupabaseConfig.url.trimEnd('/')}/storage/v1/object/vibra_social/$fileName"
            val response = client.post(uploadUrl) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                contentType(ContentType.parse(mimeType))
                setBody(bytes)
            }
            if (!response.status.isSuccess()) {
                val errorText = response.bodyAsText()
                Log.w(TAG, "uploadMedia returned status ${response.status}: $errorText")
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
     * Sends a direct message with optional attached music card or playlist card.
     */
    suspend fun sendDirectMessage(
        senderId: String,
        recipientId: String,
        message: String,
        trackAttachment: MusicTrackAttachment? = null,
        playlistAttachment: SharedPlaylistAttachment? = null,
        imageUrl: String? = null,
        videoUrl: String? = null,
        audioUrl: String? = null,
        gifUrl: String? = null,
    ): Result<DirectMessage> = withContext(Dispatchers.IO) {
        runCatching {
            val messageId = UUID.randomUUID().toString()
            val sharedMusicJson = trackAttachment?.let {
                "{\"video_id\":\"${it.videoId}\",\"title\":${jsonQuote(it.title)},\"artist\":${jsonQuote(it.artist)},\"thumbnail_url\":${jsonQuote(it.thumbnailUrl ?: "")},\"duration_text\":${jsonQuote(it.durationText ?: "")}}"
            }
            val sharedPlaylistJson = playlistAttachment?.let {
                "{\"playlist_id\":${jsonQuote(it.playlistId)},\"title\":${jsonQuote(it.title)},\"author\":${jsonQuote(it.author)},\"thumbnail_url\":${jsonQuote(it.thumbnailUrl ?: "")},\"track_count\":${it.trackCount}}"
            }

            val finalContent = buildString {
                if (!imageUrl.isNullOrBlank()) append("[image:$imageUrl] ")
                if (!videoUrl.isNullOrBlank()) append("[video:$videoUrl] ")
                if (!audioUrl.isNullOrBlank()) append("[audio:$audioUrl] ")
                if (!gifUrl.isNullOrBlank()) append("[gif:$gifUrl] ")
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
                Log.w(TAG, "sendDirectMessage returned ${res.status}: ${res.bodyAsText()}")
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
            client.patch(baseUrl("notifications")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("id", "eq.$notificationId")
                contentType(ContentType.Application.Json)
                setBody("{\"is_read\":true}")
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
                    Log.w(TAG, "addFavoriteArtist returned ${res.status}: ${res.bodyAsText()}")
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
                append("}")
            }
            client.post(baseUrl("user_listening_experience")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                header("Prefer", "resolution=merge-duplicates")
                contentType(ContentType.Application.Json)
                setBody(body)
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
            val array = json.parseToJsonElement(response.bodyAsText()).jsonArray
            val obj = array.firstOrNull()?.jsonObject ?: return@runCatching null
            val genres = obj["preferred_genres"]?.jsonArray?.mapNotNull { it.jsonPrimitive.content } ?: emptyList()
            UserListeningExperience(
                userId = userId,
                spotifySpdcToken = obj["spotify_spdc_token"]?.jsonPrimitive?.content,
                spotifyConnected = obj["spotify_connected"]?.jsonPrimitive?.booleanOrNull ?: false,
                audioQuality = obj["audio_quality"]?.jsonPrimitive?.content ?: "HIGH",
                equalizerEnabled = obj["equalizer_enabled"]?.jsonPrimitive?.booleanOrNull ?: false,
                equalizerPreset = obj["equalizer_preset"]?.jsonPrimitive?.content ?: "FLAT",
                volumeNormalization = obj["volume_normalization"]?.jsonPrimitive?.booleanOrNull ?: true,
                bassBoostPercent = obj["bass_boost_percent"]?.jsonPrimitive?.intOrNull ?: 0,
                virtualizerPercent = obj["virtualizer_percent"]?.jsonPrimitive?.intOrNull ?: 0,
                pitchCents = obj["pitch_cents"]?.jsonPrimitive?.intOrNull ?: 0,
                tempoMultiplier = obj["tempo_multiplier"]?.jsonPrimitive?.doubleOrNull?.toFloat() ?: 1.0f,
                autoSkipSilence = obj["auto_skip_silence"]?.jsonPrimitive?.booleanOrNull ?: false,
                lyricsSource = obj["lyrics_source"]?.jsonPrimitive?.content ?: "DEFAULT",
                canvasEnabled = obj["canvas_enabled"]?.jsonPrimitive?.booleanOrNull ?: true,
                preferredGenres = genres,
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
            client.post(baseUrl("user_liked_tracks")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                header("Prefer", "resolution=merge-duplicates")
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            Unit
        }
    }

    /**
     * Removes a liked track from the user's cloud library.
     */
    suspend fun removeLikedTrack(userId: String, videoId: String): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            client.delete(baseUrl("user_liked_tracks")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("user_id", "eq.$userId")
                parameter("video_id", "eq.$videoId")
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
            val array = json.parseToJsonElement(response.bodyAsText()).jsonArray
            array.mapNotNull {
                val obj = it.jsonObject
                val videoId = obj["video_id"]?.jsonPrimitive?.content ?: return@mapNotNull null
                val title = obj["title"]?.jsonPrimitive?.content ?: return@mapNotNull null
                val artist = obj["artist"]?.jsonPrimitive?.content ?: ""
                val thumb = obj["thumbnail_url"]?.jsonPrimitive?.content
                val duration = obj["duration_text"]?.jsonPrimitive?.content
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
            client.post(baseUrl("user_playlists")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                header("Prefer", "resolution=merge-duplicates")
                contentType(ContentType.Application.Json)
                setBody(body)
            }
            Unit
        }
    }

    /**
     * Deletes a user playlist and its tracks from the cloud.
     */
    suspend fun deletePlaylist(userId: String, playlistId: String): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            client.delete(baseUrl("user_playlists")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("id", "eq.$playlistId")
                parameter("user_id", "eq.$userId")
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

                client.post(baseUrl("user_playlist_tracks")) {
                    header("apikey", SupabaseConfig.anonKey)
                    header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                    contentType(ContentType.Application.Json)
                    setBody(tracksJson)
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
            val playlistsArray = json.parseToJsonElement(response.bodyAsText()).jsonArray
            val result = mutableListOf<Pair<UserPlaylist, List<Song>>>()

            for (item in playlistsArray) {
                val pObj = item.jsonObject
                val pId = pObj["id"]?.jsonPrimitive?.content ?: continue
                val pTitle = pObj["title"]?.jsonPrimitive?.content ?: "Playlist"
                val pThumb = pObj["thumbnail_url"]?.jsonPrimitive?.content

                val tracksResp = client.get(baseUrl("user_playlist_tracks")) {
                    header("apikey", SupabaseConfig.anonKey)
                    header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                    parameter("playlist_id", "eq.$pId")
                    parameter("order", "position.asc")
                }
                val tracksArray = json.parseToJsonElement(tracksResp.bodyAsText()).jsonArray
                val songs = tracksArray.mapNotNull { tItem ->
                    val tObj = tItem.jsonObject
                    val vId = tObj["video_id"]?.jsonPrimitive?.content ?: return@mapNotNull null
                    val title = tObj["title"]?.jsonPrimitive?.content ?: return@mapNotNull null
                    val artist = tObj["artist"]?.jsonPrimitive?.content ?: ""
                    val thumb = tObj["thumbnail_url"]?.jsonPrimitive?.content
                    val duration = tObj["duration_text"]?.jsonPrimitive?.content
                    Song(
                        videoId = vId,
                        title = title,
                        artist = artist,
                        thumbnailUrl = thumb,
                        durationText = duration,
                    )
                }

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
            val imageUrls = obj["image_urls"]?.jsonArray?.mapNotNull { it.jsonPrimitive.content } ?: emptyList()
            val videoUrl = obj["video_url"]?.jsonPrimitive?.content
            val gifUrl = obj["gif_url"]?.jsonPrimitive?.content
                ?: if (imageUrl?.endsWith(".gif", ignoreCase = true) == true || imageUrl?.contains("giphy", ignoreCase = true) == true || imageUrl?.contains("tenor", ignoreCase = true) == true) imageUrl else null
            val quoteOfId = obj["quote_of_id"]?.jsonPrimitive?.content
            val repostOfId = obj["repost_of_id"]?.jsonPrimitive?.content
            val createdAt = obj["created_at"]?.jsonPrimitive?.content ?: ""
            val likesCount = obj["likes_count"]?.jsonPrimitive?.intOrNull ?: 0
            val commentsCount = obj["comments_count"]?.jsonPrimitive?.intOrNull ?: 0
            val repostsCount = obj["reposts_count"]?.jsonPrimitive?.intOrNull ?: 0

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

            val audioUrl = obj["audio_url"]?.jsonPrimitive?.content
            val isReview = runCatching { obj["is_review"]?.jsonPrimitive?.content?.toBooleanStrictOrNull() ?: false }.getOrDefault(false)
            val rating = obj["rating"]?.jsonPrimitive?.intOrNull ?: 0
            val taggedArtist = obj["tagged_artist"]?.jsonPrimitive?.content
            val isRepostedByMe = if (currentUserId.isNotBlank()) {
                repostOfId != null && authorId == currentUserId
            } else false

            SocialPost(
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
                isRepostedByMe = isRepostedByMe,
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
            val rawContent = obj["content"]?.jsonPrimitive?.content ?: ""
            var cleanContent = rawContent
            var gifUrl = obj["gif_url"]?.jsonPrimitive?.content
            if (rawContent.contains("[gif:")) {
                val match = "\\[gif:(https?://[^\\]]+)\\]".toRegex().find(rawContent)
                if (match != null) {
                    if (gifUrl == null) gifUrl = match.groupValues[1]
                    cleanContent = rawContent.replace(match.value, "").trim()
                }
            }
            val parentId = obj["parent_id"]?.jsonPrimitive?.content
            val createdAt = obj["created_at"]?.jsonPrimitive?.content ?: ""
            val likesCount = obj["likes_count"]?.jsonPrimitive?.intOrNull ?: 0

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
                content = cleanContent,
                gifUrl = gifUrl,
                likesCount = likesCount,
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
            val rawContent = obj["content"]?.jsonPrimitive?.content ?: ""
            var cleanContent = rawContent
            var imageUrl = obj["image_url"]?.jsonPrimitive?.content
            var videoUrl = obj["video_url"]?.jsonPrimitive?.content
            var audioUrl = obj["audio_url"]?.jsonPrimitive?.content
            var gifUrl = obj["gif_url"]?.jsonPrimitive?.content

            val tagRegex = "\\[(image|video|audio|gif):(https?://[^\\]]+)\\]".toRegex()
            tagRegex.findAll(rawContent).forEach { match ->
                val type = match.groupValues[1]
                val url = match.groupValues[2]
                when (type) {
                    "image" -> if (imageUrl == null) imageUrl = url
                    "video" -> if (videoUrl == null) videoUrl = url
                    "audio" -> if (audioUrl == null) audioUrl = url
                    "gif" -> if (gifUrl == null) gifUrl = url
                }
            }
            cleanContent = rawContent.replace(tagRegex, "").trim()

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

            val sharedPlaylist = obj["shared_playlist"]?.jsonObject?.let { p ->
                SharedPlaylistAttachment(
                    playlistId = p["playlist_id"]?.jsonPrimitive?.content ?: "",
                    title = p["title"]?.jsonPrimitive?.content ?: "",
                    author = p["author"]?.jsonPrimitive?.content ?: "",
                    thumbnailUrl = p["thumbnail_url"]?.jsonPrimitive?.content,
                    trackCount = p["track_count"]?.jsonPrimitive?.intOrNull ?: 0,
                )
            }

            DirectMessage(
                id = id,
                senderId = senderId,
                receiverId = receiverId,
                content = cleanContent,
                imageUrl = imageUrl,
                videoUrl = videoUrl,
                audioUrl = audioUrl,
                gifUrl = gifUrl,
                sharedMusic = sharedMusic,
                sharedPlaylist = sharedPlaylist,
                isRead = isRead,
                createdAt = createdAt,
            )
        }
    }.getOrDefault(emptyList())

    private fun parseNotifications(raw: String, currentUserId: String): List<SocialNotification> = runCatching {
        val array = json.parseToJsonElement(raw).jsonArray
        array.mapNotNull { element ->
            val obj = element.jsonObject
            val id = obj["id"]?.jsonPrimitive?.content ?: return@mapNotNull null
            val actorId = obj["actor_id"]?.jsonPrimitive?.content ?: ""
            val actorName = obj["actor_name"]?.jsonPrimitive?.content ?: "A listener"
            val actorAvatar = obj["actor_avatar"]?.jsonPrimitive?.content
            val actorHandle = obj["actor_handle"]?.jsonPrimitive?.content ?: ""
            val typeStr = obj["type"]?.jsonPrimitive?.content ?: "LIKE"
            val type = runCatching { NotificationType.valueOf(typeStr) }.getOrDefault(NotificationType.LIKE)
            val targetPostId = obj["target_post_id"]?.jsonPrimitive?.content
            val message = obj["message"]?.jsonPrimitive?.content ?: ""
            val isRead = obj["is_read"]?.jsonPrimitive?.booleanOrNull ?: false
            val createdAt = obj["created_at"]?.jsonPrimitive?.content ?: ""

            SocialNotification(
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
    }.getOrDefault(emptyList())

    /**
     * Searches both profiles and posts across the Vibra Social database.
     */
    suspend fun searchPostsAndUsers(
        query: String,
        currentUserId: String = "",
        limit: Int = 20,
    ): Result<Pair<List<SocialProfile>, List<SocialPost>>> = withContext(Dispatchers.IO) {
        runCatching {
            val q = query.trim()
            if (q.isBlank()) return@runCatching (emptyList<SocialProfile>() to emptyList<SocialPost>())

            val encodedQ = "*$q*"

            val profilesResp = client.get(baseUrl("profiles")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("or", "(display_name.ilike.$encodedQ,handle.ilike.$encodedQ)")
                parameter("limit", limit)
            }
            val matchedProfiles = parseProfiles(profilesResp.bodyAsText())

            val postsResp = client.get(baseUrl("posts")) {
                header("apikey", SupabaseConfig.anonKey)
                header("Authorization", "Bearer ${SupabaseConfig.anonKey}")
                parameter("select", "*,profiles:author_id(*)")
                parameter("or", "(content.ilike.$encodedQ,music_track->>title.ilike.$encodedQ,music_track->>artist.ilike.$encodedQ)")
                parameter("order", "created_at.desc")
                parameter("limit", limit)
            }
            val matchedPosts = parsePosts(postsResp.bodyAsText(), currentUserId)

            matchedProfiles to matchedPosts
        }
    }

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
