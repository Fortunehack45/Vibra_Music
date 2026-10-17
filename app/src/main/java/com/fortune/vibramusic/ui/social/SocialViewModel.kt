package com.fortune.vibramusic.ui.social

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.fortune.vibramusic.auth.AuthStore
import com.fortune.vibramusic.data.DebugLog as Log
import com.fortune.vibramusic.data.quiz.QuizArtist
import com.fortune.vibramusic.data.settings.AppSettings
import com.fortune.vibramusic.data.social.DirectMessage
import com.fortune.vibramusic.data.social.MusicTrackAttachment
import com.fortune.vibramusic.data.social.PollData
import com.fortune.vibramusic.data.social.PostComment
import com.fortune.vibramusic.data.social.SocialNotification
import com.fortune.vibramusic.data.social.SocialPost
import com.fortune.vibramusic.data.social.SocialProfile
import com.fortune.vibramusic.data.supabase.SupabaseService
import com.fortune.vibramusic.data.supabase.UserCloudSyncManager
import com.fortune.vibramusic.data.YtMusicRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

import com.fortune.vibramusic.ui.components.SocialTab

enum class FeedTab {
    FOR_YOU,
    FRIENDS,
}

class SocialViewModel(application: Application) : AndroidViewModel(application) {

    private val authStore = AuthStore(application)
    private val cacheStore = com.fortune.vibramusic.data.social.SocialCacheStore(application)

    private val _currentProfile = MutableStateFlow<SocialProfile?>(null)
    val currentProfile: StateFlow<SocialProfile?> = _currentProfile.asStateFlow()

    private val _navTab = MutableStateFlow(SocialTab.FEED)
    val navTab: StateFlow<SocialTab> = _navTab.asStateFlow()

    private val _feedTab = MutableStateFlow(FeedTab.FOR_YOU)
    val feedTab: StateFlow<FeedTab> = _feedTab.asStateFlow()

    private val _posts = MutableStateFlow<List<SocialPost>>(emptyList())
    val posts: StateFlow<List<SocialPost>> = _posts.asStateFlow()

    private val _isRefreshing = MutableStateFlow(false)
    val isRefreshing: StateFlow<Boolean> = _isRefreshing.asStateFlow()

    private val _isLoadingFeed = MutableStateFlow(false)
    val isLoadingFeed: StateFlow<Boolean> = _isLoadingFeed.asStateFlow()

    private val _stories = MutableStateFlow<List<SocialProfile>>(emptyList())
    val stories: StateFlow<List<SocialProfile>> = _stories.asStateFlow()

    private val _conversations = MutableStateFlow<List<SocialProfile>>(emptyList())
    val conversations: StateFlow<List<SocialProfile>> = _conversations.asStateFlow()

    private val _activeChatFriend = MutableStateFlow<SocialProfile?>(null)
    val activeChatFriend: StateFlow<SocialProfile?> = _activeChatFriend.asStateFlow()

    private val _chatMessages = MutableStateFlow<List<DirectMessage>>(emptyList())
    val chatMessages: StateFlow<List<DirectMessage>> = _chatMessages.asStateFlow()

    private val _selectedPostForComments = MutableStateFlow<SocialPost?>(null)
    val selectedPostForComments: StateFlow<SocialPost?> = _selectedPostForComments.asStateFlow()

    private val _comments = MutableStateFlow<List<PostComment>>(emptyList())
    val comments: StateFlow<List<PostComment>> = _comments.asStateFlow()

    private val _favoriteArtists = MutableStateFlow<List<QuizArtist>>(emptyList())
    val favoriteArtists: StateFlow<List<QuizArtist>> = _favoriteArtists.asStateFlow()

    private val _viewingProfile = MutableStateFlow<SocialProfile?>(null)
    val viewingProfile: StateFlow<SocialProfile?> = _viewingProfile.asStateFlow()

    private val _viewingProfilePosts = MutableStateFlow<List<SocialPost>>(emptyList())
    val viewingProfilePosts: StateFlow<List<SocialPost>> = _viewingProfilePosts.asStateFlow()

    private val _isCreatingPost = MutableStateFlow(false)
    val isCreatingPost: StateFlow<Boolean> = _isCreatingPost.asStateFlow()

    private val _quotingPost = MutableStateFlow<SocialPost?>(null)
    val quotingPost: StateFlow<SocialPost?> = _quotingPost.asStateFlow()

    private val _notifications = MutableStateFlow<List<SocialNotification>>(emptyList())
    val notifications: StateFlow<List<SocialNotification>> = _notifications.asStateFlow()

    private val _isNotificationsOpen = MutableStateFlow(false)
    val isNotificationsOpen: StateFlow<Boolean> = _isNotificationsOpen.asStateFlow()

    init {
        viewModelScope.launch {
            val cached = cacheStore.loadPosts()
            if (cached.isNotEmpty()) {
                forYouPostsCache = cached
                _posts.value = cached
            }
        }
        initUserProfile()
        loadFeed()
    }

    fun setNavTab(tab: SocialTab) {
        _navTab.value = tab
        if (tab == SocialTab.MESSAGES) {
            loadConversations()
        } else if (tab == SocialTab.PROFILE && _viewingProfile.value == null) {
            _viewingProfile.value = _currentProfile.value
            _currentProfile.value?.id?.let { loadProfilePosts(it) }
        }
    }

    private var forYouPostsCache: List<SocialPost> = emptyList()
    private var friendsPostsCache: List<SocialPost> = emptyList()

    private val _searchQuery = MutableStateFlow("")
    val searchQuery: StateFlow<String> = _searchQuery.asStateFlow()

    private val _searchResults = MutableStateFlow<Pair<List<SocialProfile>, List<SocialPost>>?>(null)
    val searchResults: StateFlow<Pair<List<SocialProfile>, List<SocialPost>>?> = _searchResults.asStateFlow()

    private val _isSearching = MutableStateFlow(false)
    val isSearching: StateFlow<Boolean> = _isSearching.asStateFlow()

    fun setFeedTab(tab: FeedTab) {
        if (_feedTab.value != tab) {
            _feedTab.value = tab
            // Seamless instant swap to cached posts
            _posts.value = if (tab == FeedTab.FOR_YOU) forYouPostsCache else friendsPostsCache
            loadFeed()
        }
    }

    fun setSearchQuery(query: String) {
        _searchQuery.value = query
        val q = query.trim()
        if (q.isBlank()) {
            _searchResults.value = null
            _isSearching.value = false
            return
        }
        viewModelScope.launch {
            _isSearching.value = true
            SupabaseService.searchPostsAndUsers(q, currentUserId = _currentProfile.value?.id ?: "")
                .onSuccess { result ->
                    if (_searchQuery.value.trim() == q) {
                        _searchResults.value = result
                    }
                }
            _isSearching.value = false
        }
    }

    fun clearSearch() {
        _searchQuery.value = ""
        _searchResults.value = null
        _isSearching.value = false
    }

    fun initUserProfile() {
        viewModelScope.launch {
            val session = authStore.activeSession ?: authStore.sessions.firstOrNull()
            val profile = session?.profiles?.firstOrNull { it.profileId == session.activeProfileId }
                ?: session?.profiles?.firstOrNull()

            if (session != null) {
                SupabaseService.syncUserProfile(session, profile)
                    .onSuccess { syncedProfile ->
                        _currentProfile.value = syncedProfile
                        loadProfileData(syncedProfile.id)
                        UserCloudSyncManager.restoreUserData(syncedProfile.id)
                    }
                    .onFailure { error ->
                        Log.w("SocialViewModel", "Failed to sync profile: ${error.message}")
                        // Fallback to local profile representation
                        val fallback = SocialProfile(
                            id = profile?.profileId ?: session.accountId,
                            handle = profile?.handle?.ifBlank { null }
                                ?: profile?.name?.lowercase()?.replace(" ", "")
                                ?: "vibra_user",
                            displayName = profile?.name ?: session.name.ifBlank { "Vibra Listener" },
                            avatarUrl = profile?.avatar,
                            referralCode = "vibra_${(profile?.profileId ?: session.accountId).takeLast(6)}",
                        )
                        _currentProfile.value = fallback
                        loadProfileData(fallback.id)
                    }
            } else {
                // Persistent guest profile tied to device ID
                val anyAvatar = authStore.sessions.flatMap { it.profiles }.firstOrNull { !it.avatar.isNullOrBlank() }?.avatar
                val anyName = authStore.sessions.flatMap { it.profiles }.firstOrNull { it.name.isNotBlank() }?.name
                val guestId = AppSettings.deviceUserId
                val existing = SupabaseService.fetchUserProfile(guestId).getOrNull()
                val guestProfile = if (existing != null) {
                    if (existing.avatarUrl.isNullOrBlank() && anyAvatar != null) {
                        existing.copy(avatarUrl = anyAvatar)
                    } else {
                        existing
                    }
                } else {
                    SocialProfile(
                        id = guestId,
                        handle = "guest_${guestId.takeLast(6)}",
                        displayName = anyName ?: "Guest Listener",
                        avatarUrl = anyAvatar,
                        referralCode = "vibra_${guestId.takeLast(6)}",
                    )
                }
                _currentProfile.value = guestProfile
                loadProfileData(guestId)
                UserCloudSyncManager.restoreUserData(guestId)
            }
        }
    }

    fun loadFeed() {
        viewModelScope.launch {
            _isLoadingFeed.value = true
            val userId = _currentProfile.value?.id
            val isFriendsOnly = _feedTab.value == FeedTab.FRIENDS

            SupabaseService.fetchPosts(forUserId = userId, friendsOnly = isFriendsOnly)
                .onSuccess { loadedPosts ->
                    val cached = if (_feedTab.value == FeedTab.FOR_YOU) forYouPostsCache else friendsPostsCache
                    val localUnsynced = cached.filter { c -> loadedPosts.none { it.id == c.id } }
                    val merged = localUnsynced + loadedPosts
                    if (_feedTab.value == FeedTab.FOR_YOU) {
                        forYouPostsCache = merged
                    } else {
                        friendsPostsCache = merged
                    }
                    _posts.value = merged
                    cacheStore.savePosts(merged)
                }
                .onFailure { e ->
                    Log.w("SocialViewModel", "Failed to load posts: ${e.message}")
                }
            _isLoadingFeed.value = false
        }
    }

    fun refreshFeed() {
        viewModelScope.launch {
            _isRefreshing.value = true
            val userId = _currentProfile.value?.id
            val isFriendsOnly = _feedTab.value == FeedTab.FRIENDS

            SupabaseService.fetchPosts(forUserId = userId, friendsOnly = isFriendsOnly)
                .onSuccess { loadedPosts ->
                    val cached = if (_feedTab.value == FeedTab.FOR_YOU) forYouPostsCache else friendsPostsCache
                    val localUnsynced = cached.filter { c -> loadedPosts.none { it.id == c.id } }
                    val merged = localUnsynced + loadedPosts
                    if (_feedTab.value == FeedTab.FOR_YOU) {
                        forYouPostsCache = merged
                    } else {
                        friendsPostsCache = merged
                    }
                    _posts.value = merged
                    cacheStore.savePosts(merged)
                }
            _isRefreshing.value = false
        }
    }

    fun createPost(
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
        onSuccess: () -> Unit = {},
    ) {
        val user = _currentProfile.value ?: return
        viewModelScope.launch {
            _isCreatingPost.value = true
            val optimisticPost = SocialPost(
                id = java.util.UUID.randomUUID().toString(),
                authorId = user.id,
                author = user,
                content = content,
                imageUrl = imageUrls.firstOrNull() ?: gifUrl,
                imageUrls = if (gifUrl != null) listOf(gifUrl) + imageUrls else imageUrls,
                videoUrl = videoUrl,
                gifUrl = gifUrl,
                audioUrl = audioUrl,
                isReview = isReview,
                rating = rating,
                taggedArtist = taggedArtist,
                musicTrack = musicAttachment,
                pollData = poll,
                quoteOfId = quoteOfId,
                quoteOf = _quotingPost.value,
                createdAt = "Just now",
            )
            val updatedFeed = listOf(optimisticPost) + _posts.value
            _posts.value = updatedFeed
            forYouPostsCache = listOf(optimisticPost) + forYouPostsCache
            if (_viewingProfile.value?.id == user.id || _currentProfile.value?.id == user.id) {
                _viewingProfilePosts.value = listOf(optimisticPost) + _viewingProfilePosts.value
            }
            cacheStore.savePosts(updatedFeed)

            SupabaseService.createPost(
                author = user,
                content = content,
                imageUrls = imageUrls,
                videoUrl = videoUrl,
                gifUrl = gifUrl,
                audioUrl = audioUrl,
                isReview = isReview,
                rating = rating,
                taggedArtist = taggedArtist,
                musicAttachment = musicAttachment,
                poll = poll,
                quoteOfId = quoteOfId,
            ).onSuccess { newPost ->
                val finalFeed = _posts.value.map { if (it.id == optimisticPost.id) newPost.copy(quoteOf = optimisticPost.quoteOf) else it }
                _posts.value = finalFeed
                forYouPostsCache = finalFeed
                cacheStore.savePosts(finalFeed)
                _isCreatingPost.value = false
                _quotingPost.value = null
                onSuccess()
            }.onFailure { err ->
                Log.e("SocialViewModel", "Failed to create post", err)
                _isCreatingPost.value = false
            }
        }
    }

    fun openQuotePost(post: SocialPost) {
        _quotingPost.value = post
    }

    fun clearQuotePost() {
        _quotingPost.value = null
    }

    fun toggleLike(post: SocialPost) {
        val userId = _currentProfile.value?.id ?: return
        val currentlyLiked = post.isLikedByMe
        val newCount = if (currentlyLiked) (post.likesCount - 1).coerceAtLeast(0) else post.likesCount + 1

        // Optimistic UI update
        _posts.value = _posts.value.map {
            if (it.id == post.id) {
                it.copy(isLikedByMe = !currentlyLiked, likesCount = newCount)
            } else it
        }

        viewModelScope.launch {
            SupabaseService.toggleLikePost(postId = post.id, userId = userId, liked = !currentlyLiked)
                .onFailure {
                    // Revert on failure
                    _posts.value = _posts.value.map {
                        if (it.id == post.id) {
                            it.copy(isLikedByMe = currentlyLiked, likesCount = post.likesCount)
                        } else it
                    }
                }
        }
    }

    fun repost(post: SocialPost) = toggleRepost(post)

    fun toggleRepost(post: SocialPost) {
        val user = _currentProfile.value ?: return
        val currentlyReposted = post.isRepostedByMe
        val newRepostCount = if (currentlyReposted) (post.repostsCount - 1).coerceAtLeast(0) else post.repostsCount + 1

        // Single repost rule: toggle between reposted and not reposted
        _posts.value = _posts.value.map {
            if (it.id == post.id) it.copy(isRepostedByMe = !currentlyReposted, repostsCount = newRepostCount) else it
        }

        viewModelScope.launch {
            SupabaseService.toggleRepost(postId = post.id, user = user, currentlyReposted = currentlyReposted)
                .onSuccess { isNowReposted ->
                    _posts.value = _posts.value.map {
                        if (it.id == post.id) it.copy(isRepostedByMe = isNowReposted) else it
                    }
                    cacheStore.savePosts(_posts.value)
                }
                .onFailure {
                    _posts.value = _posts.value.map {
                        if (it.id == post.id) it.copy(isRepostedByMe = currentlyReposted, repostsCount = post.repostsCount) else it
                    }
                }
        }
    }

    fun votePoll(post: SocialPost, optionIndex: Int) {
        val poll = post.poll ?: return
        val userId = _currentProfile.value?.id ?: return
        if (poll.userVotedIndex != null) return

        val updatedOptions = poll.options.mapIndexed { idx, opt ->
            if (idx == optionIndex) opt.copy(votes = opt.votes + 1) else opt
        }
        val updatedPoll = poll.copy(
            options = updatedOptions,
            totalVotes = poll.totalVotes + 1,
            userVotedIndex = optionIndex,
        )

        // Optimistic update
        _posts.value = _posts.value.map {
            if (it.id == post.id) it.copy(pollData = updatedPoll) else it
        }

        viewModelScope.launch {
            SupabaseService.votePoll(postId = post.id, optionIndex = optionIndex, userId = userId)
        }
    }

    fun openComments(post: SocialPost) {
        _selectedPostForComments.value = post
        viewModelScope.launch {
            val cachedComments = cacheStore.loadComments(post.id)
            if (cachedComments.isNotEmpty()) {
                _comments.value = cachedComments
            } else {
                _comments.value = emptyList()
            }
            val userId = _currentProfile.value?.id
            SupabaseService.fetchComments(post.id, currentUserId = userId)
                .onSuccess { list ->
                    _comments.value = list
                    cacheStore.saveComments(post.id, list)
                }
        }
    }

    fun openCommentsForPostId(postId: String) {
        val post = _posts.value.firstOrNull { it.id == postId }
        if (post != null) {
            openComments(post)
        } else {
            val stub = SocialPost(
                id = postId,
                authorId = "",
                content = "",
            )
            openComments(stub)
        }
    }

    fun toggleLikeComment(comment: PostComment) {
        val userId = _currentProfile.value?.id ?: return
        val currentlyLiked = comment.isLikedByMe
        val newCount = if (currentlyLiked) (comment.likesCount - 1).coerceAtLeast(0) else comment.likesCount + 1

        _comments.value = _comments.value.map {
            if (it.id == comment.id) it.copy(isLikedByMe = !currentlyLiked, likesCount = newCount) else it
        }

        viewModelScope.launch {
            SupabaseService.toggleLikeComment(comment.id, userId, !currentlyLiked)
                .onFailure {
                    _comments.value = _comments.value.map {
                        if (it.id == comment.id) it.copy(isLikedByMe = currentlyLiked, likesCount = comment.likesCount) else it
                    }
                }
        }
    }

    fun updateUserProfile(
        displayName: String,
        handle: String,
        bio: String,
        avatarUrl: String?,
        onComplete: (Boolean) -> Unit = {},
    ) {
        val current = _currentProfile.value ?: return
        val cleanHandle = handle.trim().trimStart('@')
        val cleanName = displayName.trim()
        val updated = current.copy(
            displayName = cleanName.ifBlank { current.displayName },
            handle = cleanHandle.ifBlank { current.handle },
            bio = bio.trim(),
            avatarUrl = avatarUrl ?: current.avatarUrl,
        )

        _currentProfile.value = updated
        if (_viewingProfile.value?.id == current.id) {
            _viewingProfile.value = updated
        }

        viewModelScope.launch {
            SupabaseService.updateUserProfile(
                userId = current.id,
                displayName = updated.displayName,
                handle = updated.handle,
                bio = updated.bio,
                avatarUrl = updated.avatarUrl,
            ).onSuccess {
                onComplete(true)
            }.onFailure {
                Log.w("SocialViewModel", "Failed to update profile", it)
                onComplete(false)
            }
        }
    }

    fun closeComments() {
        _selectedPostForComments.value = null
        _comments.value = emptyList()
    }

    fun addComment(postId: String, content: String, parentCommentId: String? = null, gifUrl: String? = null) {
        val user = _currentProfile.value ?: return
        if (content.isBlank() && gifUrl.isNullOrBlank()) return

        val optimisticComment = PostComment(
            id = java.util.UUID.randomUUID().toString(),
            postId = postId,
            authorId = user.id,
            author = user,
            parentId = parentCommentId,
            content = content,
            gifUrl = gifUrl,
        )
        val updatedComments = _comments.value + optimisticComment
        _comments.value = updatedComments
        _posts.value = _posts.value.map {
            if (it.id == postId) it.copy(commentsCount = it.commentsCount + 1) else it
        }

        viewModelScope.launch {
            cacheStore.saveComments(postId, updatedComments)
            SupabaseService.addComment(
                postId = postId,
                user = user,
                content = content,
                parentCommentId = parentCommentId,
                gifUrl = gifUrl,
            ).onSuccess { newComment ->
                val reconciled = _comments.value.map { if (it.id == optimisticComment.id) newComment else it }
                _comments.value = reconciled
                cacheStore.saveComments(postId, reconciled)
            }
        }
    }

    fun loadConversations() {
        val userId = _currentProfile.value?.id ?: return
        viewModelScope.launch {
            SupabaseService.fetchConversations(userId)
                .onSuccess { convos ->
                    _conversations.value = convos
                }
        }
    }

    fun openChat(friend: SocialProfile) {
        _activeChatFriend.value = friend
        _chatMessages.value = emptyList()
        val userId = _currentProfile.value?.id ?: return

        viewModelScope.launch {
            SupabaseService.fetchDirectMessages(userId, friend.id)
                .onSuccess { msgs ->
                    _chatMessages.value = msgs
                }
        }
    }

    fun closeChat() {
        _activeChatFriend.value = null
        _chatMessages.value = emptyList()
    }

    fun sendDirectMessage(
        text: String,
        musicAttachment: MusicTrackAttachment? = null,
        playlistAttachment: com.fortune.vibramusic.data.social.SharedPlaylistAttachment? = null,
        imageUrl: String? = null,
        videoUrl: String? = null,
        audioUrl: String? = null,
        gifUrl: String? = null,
    ) {
        val user = _currentProfile.value ?: return
        val recipient = _activeChatFriend.value ?: return
        if (text.isBlank() && musicAttachment == null && playlistAttachment == null && imageUrl == null && videoUrl == null && audioUrl == null && gifUrl == null) return

        viewModelScope.launch {
            SupabaseService.sendDirectMessage(
                senderId = user.id,
                recipientId = recipient.id,
                message = text,
                trackAttachment = musicAttachment,
                playlistAttachment = playlistAttachment,
                imageUrl = imageUrl,
                videoUrl = videoUrl,
                audioUrl = audioUrl,
                gifUrl = gifUrl,
            ).onSuccess { newMsg ->
                _chatMessages.value = _chatMessages.value + newMsg
            }
        }
    }

    fun openUserProfile(profile: SocialProfile) {
        _viewingProfile.value = profile
        loadProfileData(profile.id)
    }

    fun closeUserProfile() {
        _viewingProfile.value = null
        _viewingProfilePosts.value = emptyList()
    }

    fun loadProfileData(userId: String) {
        loadProfilePosts(userId)
        loadFavoriteArtists(userId)
    }

    fun loadProfilePosts(userId: String) {
        viewModelScope.launch {
            SupabaseService.fetchUserPosts(userId)
                .onSuccess { list ->
                    _viewingProfilePosts.value = list
                }
        }
    }

    fun toggleFollowUser(targetUserId: String) {
        val myId = _currentProfile.value?.id ?: return
        val currentProfile = _viewingProfile.value ?: return
        val isFollowing = currentProfile.isFollowing

        val updated = currentProfile.copy(
            isFollowing = !isFollowing,
            followersCount = if (isFollowing) (currentProfile.followersCount - 1).coerceAtLeast(0) else currentProfile.followersCount + 1,
        )
        _viewingProfile.value = updated

        viewModelScope.launch {
            SupabaseService.toggleFollow(myId, targetUserId, !isFollowing)
        }
    }

    fun sendFriendRequest(targetUserId: String) {
        val myId = _currentProfile.value?.id ?: return
        viewModelScope.launch {
            SupabaseService.sendFriendRequest(myId, targetUserId)
        }
    }

    fun loadFavoriteArtists(userId: String) {
        viewModelScope.launch {
            SupabaseService.fetchFavoriteArtists(userId)
                .onSuccess { list ->
                    val loaded = list.map {
                        QuizArtist(
                            id = it.artistId,
                            name = it.artistName,
                            artworkUrl = it.artworkUrl,
                        )
                    }
                    _favoriteArtists.value = loaded

                    // Asynchronously resolve and heal any missing or broken thumbnails from YouTube Music
                    loaded.filter { it.artworkUrl.isNullOrBlank() || it.artworkUrl?.contains("/test") == true || it.artworkUrl?.startsWith("http") != true }.forEach { artist ->
                        launch {
                            val resolvedThumb = YtMusicRepository.getArtistThumbnail(artist.id, artist.name)
                            if (!resolvedThumb.isNullOrBlank()) {
                                _favoriteArtists.value = _favoriteArtists.value.map {
                                    if (it.id == artist.id) it.copy(artworkUrl = resolvedThumb) else it
                                }
                                SupabaseService.addFavoriteArtist(userId, artist.copy(artworkUrl = resolvedThumb))
                            }
                        }
                    }
                }
        }
    }

    fun addFavoriteArtist(artist: QuizArtist) {
        val userId = _currentProfile.value?.id ?: return
        if (_favoriteArtists.value.any { it.id == artist.id }) return

        _favoriteArtists.value = _favoriteArtists.value + artist
        viewModelScope.launch {
            var toSave = artist
            if (toSave.artworkUrl.isNullOrBlank() || toSave.artworkUrl?.contains("/test") == true || toSave.artworkUrl?.startsWith("http") != true) {
                val thumb = YtMusicRepository.getArtistThumbnail(artist.id, artist.name)
                if (!thumb.isNullOrBlank()) {
                    toSave = artist.copy(artworkUrl = thumb)
                    _favoriteArtists.value = _favoriteArtists.value.map {
                        if (it.id == artist.id) toSave else it
                    }
                }
            }
            SupabaseService.addFavoriteArtist(userId, toSave)
        }
    }

    fun removeFavoriteArtist(artistId: String) {
        val userId = _currentProfile.value?.id ?: return
        _favoriteArtists.value = _favoriteArtists.value.filterNot { it.id == artistId }
        viewModelScope.launch {
            SupabaseService.removeFavoriteArtist(userId, artistId)
        }
    }

    fun openNotifications() {
        _isNotificationsOpen.value = true
        loadNotifications()
    }

    fun closeNotifications() {
        _isNotificationsOpen.value = false
    }

    fun loadNotifications() {
        val userId = _currentProfile.value?.id ?: return
        viewModelScope.launch {
            SupabaseService.fetchNotifications(userId).onSuccess { list ->
                _notifications.value = list
            }
        }
    }

    fun markNotificationRead(id: String) {
        _notifications.value = _notifications.value.map {
            if (it.id == id) it.copy(isRead = true) else it
        }
        viewModelScope.launch {
            SupabaseService.markNotificationRead(id)
        }
    }
}
