package com.fortune.vibramusic.ui.social

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.fortune.vibramusic.auth.AuthStore
import com.fortune.vibramusic.data.DebugLog as Log
import com.fortune.vibramusic.data.quiz.QuizArtist
import com.fortune.vibramusic.data.settings.AppSettings
import com.fortune.vibramusic.data.social.ConversationSummary
import com.fortune.vibramusic.data.social.DirectMessage
import com.fortune.vibramusic.data.social.MusicTrackAttachment
import com.fortune.vibramusic.data.social.NotificationType
import com.fortune.vibramusic.data.social.PollData
import com.fortune.vibramusic.data.social.PostComment
import com.fortune.vibramusic.data.social.SocialNotification
import com.fortune.vibramusic.data.social.SocialPost
import com.fortune.vibramusic.data.social.SocialProfile
import com.fortune.vibramusic.data.supabase.SupabaseService
import com.fortune.vibramusic.data.supabase.UserCloudSyncManager
import com.fortune.vibramusic.data.YtMusicRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
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

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    fun clearErrorMessage() {
        _errorMessage.value = null
    }

    private val _stories = MutableStateFlow<List<SocialProfile>>(emptyList())
    val stories: StateFlow<List<SocialProfile>> = _stories.asStateFlow()

    private val _conversations = MutableStateFlow<List<ConversationSummary>>(emptyList())
    val conversations: StateFlow<List<ConversationSummary>> = _conversations.asStateFlow()

    private fun updatePostAcrossAllLists(postId: String, transform: (SocialPost) -> SocialPost) {
        _posts.value = _posts.value.map { if (it.id == postId) transform(it) else it }
        _viewingProfilePosts.value = _viewingProfilePosts.value.map { if (it.id == postId) transform(it) else it }
        val selected = _selectedPostForComments.value
        if (selected?.id == postId) {
            _selectedPostForComments.value = transform(selected)
        }
    }

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

    private val _followingList = MutableStateFlow<List<SocialProfile>>(emptyList())
    val followingList: StateFlow<List<SocialProfile>> = _followingList.asStateFlow()

    private val _followersList = MutableStateFlow<List<SocialProfile>>(emptyList())
    val followersList: StateFlow<List<SocialProfile>> = _followersList.asStateFlow()

    private val _friendsList = MutableStateFlow<List<SocialProfile>>(emptyList())
    val friendsList: StateFlow<List<SocialProfile>> = _friendsList.asStateFlow()

    private val _suggestedUsersList = MutableStateFlow<List<SocialProfile>>(emptyList())
    val suggestedUsersList: StateFlow<List<SocialProfile>> = _suggestedUsersList.asStateFlow()

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

        // Background polling for notifications & conversations
        viewModelScope.launch {
            while (true) {
                kotlinx.coroutines.delay(25_000)
                loadNotifications()
                loadConversations()
            }
        }
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

    fun onSignOut() {
        _viewingProfile.value = null
        _viewingProfilePosts.value = emptyList()
        _favoriteArtists.value = emptyList()
        _chatMessages.value = emptyList()
        _conversations.value = emptyList()
        _activeChatFriend.value = null
        initUserProfile()
    }

    fun loadFeed() {
        viewModelScope.launch {
            if (_posts.value.isEmpty()) {
                val diskCached = withContext(Dispatchers.IO) { cacheStore.loadPosts() }
                if (diskCached.isNotEmpty() && _posts.value.isEmpty()) {
                    _posts.value = diskCached
                }
            }
            _isLoadingFeed.value = true
            val userId = _currentProfile.value?.id
            val isFriendsOnly = _feedTab.value == FeedTab.FRIENDS

            SupabaseService.fetchPosts(forUserId = userId, friendsOnly = isFriendsOnly)
                .onSuccess { loadedPosts ->
                    _errorMessage.value = null
                    val cached = if (_feedTab.value == FeedTab.FOR_YOU) forYouPostsCache else friendsPostsCache
                    val localUnsynced = cached.filter { c -> c.createdAt == "Just now" && loadedPosts.none { it.id == c.id } }
                    val merged = (localUnsynced + loadedPosts).distinctBy { it.id }
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
                    _errorMessage.value = "Couldn't load feed, tap to retry"
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
                    _errorMessage.value = null
                    val cached = if (_feedTab.value == FeedTab.FOR_YOU) forYouPostsCache else friendsPostsCache
                    val localUnsynced = cached.filter { c -> c.createdAt == "Just now" && loadedPosts.none { it.id == c.id } }
                    val merged = (localUnsynced + loadedPosts).distinctBy { it.id }
                    if (_feedTab.value == FeedTab.FOR_YOU) {
                        forYouPostsCache = merged
                    } else {
                        friendsPostsCache = merged
                    }
                    _posts.value = merged
                    cacheStore.savePosts(merged)
                }
                .onFailure { e ->
                    Log.w("SocialViewModel", "Failed to refresh posts: ${e.message}")
                    _errorMessage.value = "Couldn't load feed, tap to retry"
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
            val updatedFeed = (listOf(optimisticPost) + _posts.value).distinctBy { it.id }
            _posts.value = updatedFeed
            forYouPostsCache = (listOf(optimisticPost) + forYouPostsCache).distinctBy { it.id }
            if (_viewingProfile.value?.id == user.id || _currentProfile.value?.id == user.id) {
                _viewingProfilePosts.value = (listOf(optimisticPost) + _viewingProfilePosts.value).distinctBy { it.id }
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
                val reconciled = newPost.copy(quoteOf = optimisticPost.quoteOf)
                val finalFeed = _posts.value.map { if (it.id == optimisticPost.id) reconciled else it }.distinctBy { it.id }
                _posts.value = finalFeed
                forYouPostsCache = forYouPostsCache.map { if (it.id == optimisticPost.id) reconciled else it }.distinctBy { it.id }
                _viewingProfilePosts.value = _viewingProfilePosts.value.map { if (it.id == optimisticPost.id) reconciled else it }.distinctBy { it.id }
                cacheStore.savePosts(finalFeed)
                _isCreatingPost.value = false
                _quotingPost.value = null
                onSuccess()
            }.onFailure { err ->
                Log.e("SocialViewModel", "Failed to create post", err)
                // Roll back optimistic post from all collections on failure
                _posts.value = _posts.value.filterNot { it.id == optimisticPost.id }.distinctBy { it.id }
                forYouPostsCache = forYouPostsCache.filterNot { it.id == optimisticPost.id }.distinctBy { it.id }
                _viewingProfilePosts.value = _viewingProfilePosts.value.filterNot { it.id == optimisticPost.id }.distinctBy { it.id }
                _errorMessage.value = "Failed to create post: ${err.message ?: "Please try again"}"
                _isCreatingPost.value = false
            }
        }
    }

    fun deletePost(post: SocialPost) {
        val user = _currentProfile.value ?: return
        if (post.authorId != user.id) return

        // Optimistically remove from feeds and profile
        _posts.value = _posts.value.filterNot { it.id == post.id }.distinctBy { it.id }
        forYouPostsCache = forYouPostsCache.filterNot { it.id == post.id }.distinctBy { it.id }
        friendsPostsCache = friendsPostsCache.filterNot { it.id == post.id }.distinctBy { it.id }
        _viewingProfilePosts.value = _viewingProfilePosts.value.filterNot { it.id == post.id }.distinctBy { it.id }

        viewModelScope.launch {
            cacheStore.savePosts(_posts.value)
            SupabaseService.deletePost(post.id, user.id).onFailure { error ->
                Log.w("SocialViewModel", "Failed to delete post: ${error.message}")
                _errorMessage.value = "Failed to delete post. Please try again."
                loadFeed()
            }
        }
    }

    fun editPost(postId: String, newContent: String, onComplete: (Boolean) -> Unit = {}) {
        val user = _currentProfile.value ?: return
        val trimmed = newContent.trim()
        if (trimmed.isBlank()) return

        fun updateList(list: List<SocialPost>) = list.map {
            if (it.id == postId) it.copy(content = trimmed, isEdited = true) else it
        }

        _posts.value = updateList(_posts.value)
        forYouPostsCache = updateList(forYouPostsCache)
        friendsPostsCache = updateList(friendsPostsCache)
        _viewingProfilePosts.value = updateList(_viewingProfilePosts.value)

        viewModelScope.launch {
            cacheStore.savePosts(_posts.value)
            SupabaseService.updatePost(postId, user.id, trimmed)
                .onSuccess {
                    onComplete(true)
                }
                .onFailure { error ->
                    Log.w("SocialViewModel", "Failed to update post: ${error.message}")
                    onComplete(false)
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

        // Optimistic UI update across feed and profile lists
        updatePostAcrossAllLists(post.id) {
            it.copy(isLikedByMe = !currentlyLiked, likesCount = newCount)
        }

        viewModelScope.launch {
            SupabaseService.toggleLikePost(postId = post.id, userId = userId, liked = !currentlyLiked)
                .onSuccess {
                    if (!currentlyLiked && post.authorId.isNotBlank() && post.authorId != userId) {
                        val actor = _currentProfile.value ?: return@onSuccess
                        SupabaseService.createNotification(
                            recipientUserId = post.authorId,
                            actor = actor,
                            type = NotificationType.LIKE,
                            targetPostId = post.id,
                            message = "liked your post",
                        )
                    }
                }
                .onFailure {
                    // Revert on failure
                    updatePostAcrossAllLists(post.id) {
                        it.copy(isLikedByMe = currentlyLiked, likesCount = post.likesCount)
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
        updatePostAcrossAllLists(post.id) {
            it.copy(isRepostedByMe = !currentlyReposted, repostsCount = newRepostCount)
        }

        viewModelScope.launch {
            SupabaseService.toggleRepost(postId = post.id, user = user, currentlyReposted = currentlyReposted)
                .onSuccess { isNowReposted ->
                    updatePostAcrossAllLists(post.id) {
                        it.copy(isRepostedByMe = isNowReposted)
                    }
                    cacheStore.savePosts(_posts.value)
                    if (isNowReposted && post.authorId.isNotBlank() && post.authorId != user.id) {
                        SupabaseService.createNotification(
                            recipientUserId = post.authorId,
                            actor = user,
                            type = NotificationType.REPOST,
                            targetPostId = post.id,
                            message = "reposted your post",
                        )
                    }
                }
                .onFailure {
                    updatePostAcrossAllLists(post.id) {
                        it.copy(isRepostedByMe = currentlyReposted, repostsCount = post.repostsCount)
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
        country: String = "",
        age: Int? = null,
        statusBubble: String = "",
        bannerPlaylists: List<String> = emptyList(),
        bannerUrl: String? = null,
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
            bannerUrl = bannerUrl ?: current.bannerUrl,
            country = country.trim(),
            age = age,
            statusBubble = statusBubble.trim(),
            bannerPlaylists = bannerPlaylists,
        )

        _currentProfile.value = updated
        if (_viewingProfile.value?.id == current.id) {
            _viewingProfile.value = updated
        }

        viewModelScope.launch {
            cacheStore.saveProfile(updated)
            SupabaseService.updateUserProfile(
                userId = current.id,
                displayName = updated.displayName,
                handle = updated.handle,
                bio = updated.bio,
                avatarUrl = updated.avatarUrl,
                country = updated.country,
                age = updated.age,
                statusBubble = updated.statusBubble,
                bannerPlaylists = updated.bannerPlaylists,
                bannerUrl = updated.bannerUrl,
            ).onSuccess {
                onComplete(true)
            }.onFailure {
                Log.w("SocialViewModel", "Failed to update profile", it)
                onComplete(false)
            }
        }
    }

    fun updateStatusBubble(status: String) {
        val current = _currentProfile.value ?: return
        updateUserProfile(
            displayName = current.displayName,
            handle = current.handle,
            bio = current.bio,
            avatarUrl = current.avatarUrl,
            country = current.country,
            age = current.age,
            statusBubble = status.trim(),
            bannerPlaylists = current.bannerPlaylists,
        )
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
        updatePostAcrossAllLists(postId) {
            it.copy(commentsCount = it.commentsCount + 1)
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

                val targetPost = _posts.value.firstOrNull { it.id == postId } ?: _selectedPostForComments.value
                val recipientId = targetPost?.authorId
                if (!recipientId.isNullOrBlank() && recipientId != user.id) {
                    val snippet = when {
                        content.isNotBlank() -> "commented: \"${content.take(50)}\""
                        !gifUrl.isNullOrBlank() -> "replied with a GIF"
                        else -> "commented on your post"
                    }
                    SupabaseService.createNotification(
                        recipientUserId = recipientId,
                        actor = user,
                        type = NotificationType.COMMENT,
                        targetPostId = postId,
                        message = snippet,
                    )
                }
            }
        }
    }

    fun editComment(commentId: String, newContent: String) {
        val trimmed = newContent.trim()
        if (trimmed.isBlank()) return
        val updated = _comments.value.map {
            if (it.id == commentId) it.copy(content = trimmed, isEdited = true) else it
        }
        _comments.value = updated
        val postId = _selectedPostForComments.value?.id
        if (postId != null) {
            viewModelScope.launch {
                cacheStore.saveComments(postId, updated)
                SupabaseService.editComment(commentId, trimmed)
            }
        }
    }

    fun deleteComment(commentId: String, postId: String) {
        val updated = _comments.value.filter { it.id != commentId }
        _comments.value = updated
        updatePostAcrossAllLists(postId) {
            it.copy(commentsCount = (it.commentsCount - 1).coerceAtLeast(0))
        }
        viewModelScope.launch {
            cacheStore.saveComments(postId, updated)
            SupabaseService.deleteComment(commentId, postId)
        }
    }

    fun deleteComment(comment: PostComment) {
        deleteComment(comment.id, comment.postId)
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

        _conversations.value = _conversations.value.map {
            if (it.friend.id == friend.id) it.copy(unreadCount = 0) else it
        }

        viewModelScope.launch {
            SupabaseService.markMessagesAsRead(senderId = friend.id, receiverId = userId)
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
        replyTo: DirectMessage? = null,
    ) {
        val user = _currentProfile.value ?: return
        val recipient = _activeChatFriend.value ?: return
        if (text.isBlank() && musicAttachment == null && playlistAttachment == null && imageUrl == null && videoUrl == null && audioUrl == null && gifUrl == null) return

        viewModelScope.launch {
            SupabaseService.sendDirectMessage(
                senderId = user.id,
                recipientId = recipient.id,
                message = text,
                senderProfile = user,
                trackAttachment = musicAttachment,
                playlistAttachment = playlistAttachment,
                imageUrl = imageUrl,
                videoUrl = videoUrl,
                audioUrl = audioUrl,
                gifUrl = gifUrl,
                replyTo = replyTo,
                recipientDisplayName = recipient.displayName,
            ).onSuccess { newMsg ->
                _chatMessages.value = (_chatMessages.value + newMsg).distinctBy { it.id }
                loadConversations()
            }
        }
    }

    fun editDirectMessage(messageId: String, newText: String) {
        val user = _currentProfile.value ?: return
        if (newText.isBlank()) return
        val originalMessages = _chatMessages.value
        val msgToEdit = originalMessages.firstOrNull { it.id == messageId } ?: return
        if (msgToEdit.senderId != user.id) return

        // Optimistic update
        _chatMessages.value = originalMessages.map {
            if (it.id == messageId) it.copy(content = newText) else it
        }

        viewModelScope.launch {
            val preservedContent = buildString {
                if (msgToEdit.replyToText != null) {
                    val snippet = msgToEdit.replyToText.take(80).replace("\n", " ")
                    val encoded = runCatching {
                        android.util.Base64.encodeToString(snippet.toByteArray(Charsets.UTF_8), android.util.Base64.NO_WRAP)
                    }.getOrDefault(snippet)
                    val senderLabel = msgToEdit.replyToSender ?: "Friend"
                    append("[reply:${msgToEdit.replyToId ?: ""}:$senderLabel:$encoded] ")
                }
                if (!msgToEdit.imageUrl.isNullOrBlank()) append("[image:${msgToEdit.imageUrl}] ")
                if (!msgToEdit.videoUrl.isNullOrBlank()) append("[video:${msgToEdit.videoUrl}] ")
                if (!msgToEdit.audioUrl.isNullOrBlank()) append("[audio:${msgToEdit.audioUrl}] ")
                if (!msgToEdit.gifUrl.isNullOrBlank()) append("[gif:${msgToEdit.gifUrl}] ")
                append(newText)
            }.trim()

            SupabaseService.updateDirectMessage(
                messageId = messageId,
                senderId = user.id,
                newContent = preservedContent,
            ).onFailure {
                Log.w("SocialViewModel", "Failed to edit direct message: ${it.message}")
                _chatMessages.value = originalMessages
            }
        }
    }

    fun deleteDirectMessage(messageId: String) {
        val user = _currentProfile.value ?: return
        val originalMessages = _chatMessages.value
        val msgToDelete = originalMessages.firstOrNull { it.id == messageId } ?: return
        if (msgToDelete.senderId != user.id) return

        // Optimistic deletion
        _chatMessages.value = originalMessages.filter { it.id != messageId }

        viewModelScope.launch {
            SupabaseService.deleteDirectMessage(
                messageId = messageId,
                senderId = user.id,
            ).onFailure {
                Log.w("SocialViewModel", "Failed to delete direct message: ${it.message}")
                _chatMessages.value = originalMessages
            }
        }
    }

    private var loadProfileJob: Job? = null

    fun openUserProfile(profile: SocialProfile) {
        _viewingProfile.value = profile
        loadProfileData(profile.id)
    }

    fun closeUserProfile() {
        loadProfileJob?.cancel()
        loadProfileJob = null
        _viewingProfile.value = null
        _viewingProfilePosts.value = emptyList()
    }

    fun loadProfileData(userId: String) {
        loadProfileJob?.cancel()
        val currentUserId = _currentProfile.value?.id.orEmpty()
        loadProfileJob = viewModelScope.launch {
            val cached = cacheStore.loadProfile(userId)
            if (cached != null && _viewingProfile.value?.id == userId) {
                _viewingProfile.value = cached
            }
            SupabaseService.fetchUserProfile(userId, currentUserId = currentUserId).onSuccess { fresh ->
                if (fresh != null) {
                    val resolvedFresh = if (fresh.bannerUrl.isNullOrBlank() && _currentProfile.value?.id == userId && !_currentProfile.value?.bannerUrl.isNullOrBlank()) {
                        fresh.copy(bannerUrl = _currentProfile.value?.bannerUrl)
                    } else {
                        fresh
                    }
                    if (_viewingProfile.value?.id == userId) {
                        _viewingProfile.value = resolvedFresh
                    }
                    cacheStore.saveProfile(resolvedFresh)
                    if (_currentProfile.value?.id == userId) {
                        _currentProfile.value = resolvedFresh
                    }
                }
            }
        }
        loadProfilePosts(userId)
        loadFavoriteArtists(userId)
    }

    fun loadProfilePosts(userId: String) {
        viewModelScope.launch {
            SupabaseService.fetchUserPosts(userId)
                .onSuccess { list ->
                    val localUnsynced = _viewingProfilePosts.value.filter { c -> c.createdAt == "Just now" && list.none { it.id == c.id } }
                    _viewingProfilePosts.value = (localUnsynced + list).distinctBy { it.id }
                }
        }
    }

    fun toggleFollowUser(targetUserId: String, targetProfile: SocialProfile? = null) {
        val myId = _currentProfile.value?.id ?: return
        if (myId == targetUserId) return
        val viewing = targetProfile ?: _viewingProfile.value?.takeIf { it.id == targetUserId }
        val isFollowing = viewing?.isFollowing ?: false

        if (_viewingProfile.value?.id == targetUserId) {
            val currentProfile = _viewingProfile.value!!
            _viewingProfile.value = currentProfile.copy(
                isFollowing = !isFollowing,
                followersCount = if (isFollowing) (currentProfile.followersCount - 1).coerceAtLeast(0) else currentProfile.followersCount + 1,
            )
        }

        _followingList.value = _followingList.value.map {
            if (it.id == targetUserId) it.copy(isFollowing = !isFollowing) else it
        }
        _followersList.value = _followersList.value.map {
            if (it.id == targetUserId) it.copy(isFollowing = !isFollowing) else it
        }
        _friendsList.value = _friendsList.value.map {
            if (it.id == targetUserId) it.copy(isFollowing = !isFollowing) else it
        }
        _suggestedUsersList.value = _suggestedUsersList.value.map {
            if (it.id == targetUserId) it.copy(isFollowing = !isFollowing) else it
        }

        viewModelScope.launch {
            SupabaseService.toggleFollow(myId, targetUserId, !isFollowing)
                .onSuccess {
                    if (!isFollowing) {
                        val actor = _currentProfile.value
                        if (actor != null && targetUserId != actor.id) {
                            SupabaseService.createNotification(
                                recipientUserId = targetUserId,
                                actor = actor,
                                type = NotificationType.FOLLOW,
                                message = "started following you",
                            )
                        }
                    }
                    loadConnections(myId)
                }
        }
    }

    fun loadConnections(userId: String) {
        val myId = _currentProfile.value?.id ?: ""
        viewModelScope.launch {
            launch {
                SupabaseService.getFollowers(userId, myId).onSuccess { list ->
                    _followersList.value = list.filter { it.id != userId }
                }
            }
            launch {
                SupabaseService.getFollowing(userId, myId).onSuccess { list ->
                    _followingList.value = list.filter { it.id != userId }
                }
            }
            launch {
                SupabaseService.getFriends(userId, myId).onSuccess { list ->
                    _friendsList.value = list.filter { it.id != userId }
                }
            }
            launch {
                SupabaseService.getSuggestedUsers(userId).onSuccess { list ->
                    _suggestedUsersList.value = list.filter { it.id != userId }
                }
            }
        }
    }

    fun openUserProfileByHandle(handle: String) {
        val clean = handle.trim().removePrefix("@")
        if (clean.isBlank()) return
        viewModelScope.launch {
            SupabaseService.searchUsersForMention(clean, limit = 1).onSuccess { list ->
                val match = list.firstOrNull { it.handle.equals(clean, ignoreCase = true) } ?: list.firstOrNull()
                if (match != null) {
                    openUserProfile(match)
                }
            }
        }
    }

    fun sendFriendRequest(targetUserId: String) {
        val myId = _currentProfile.value?.id ?: return
        val viewing = _viewingProfile.value
        if (viewing?.id == targetUserId) {
            _viewingProfile.value = viewing.copy(friendshipStatus = "PENDING")
        }
        viewModelScope.launch {
            SupabaseService.sendFriendRequest(myId, targetUserId)
                .onSuccess {
                    val actor = _currentProfile.value
                    if (actor != null && targetUserId != actor.id) {
                        SupabaseService.createNotification(
                            recipientUserId = targetUserId,
                            actor = actor,
                            type = NotificationType.FRIEND_REQUEST,
                            message = "sent you a friend request",
                        )
                    }
                }
        }
    }

    private fun sanitizeQuizArtist(artist: QuizArtist): QuizArtist {
        val fixedId = when {
            artist.name.equals("Drake", ignoreCase = true) && (artist.id == "UC0C-w0YjGpqDXGB8Tr0GGyA" || artist.id.isBlank()) -> "UCU6cE7pdJPc6DU2jSrKEsdQ"
            artist.name.equals("Taylor Swift", ignoreCase = true) && artist.id.isBlank() -> "UCPC0L1d253x-KuMNwa05TpA"
            artist.name.equals("Burna Boy", ignoreCase = true) && artist.id.isBlank() -> "UCr61sufuLt7_eB7ak1bXHIg"
            artist.name.equals("The Weeknd", ignoreCase = true) && artist.id.isBlank() -> "UClYV6hHlupm_S_ObS1W-DYw"
            artist.name.equals("Kendrick Lamar", ignoreCase = true) && artist.id.isBlank() -> "UCprAFmT0C6O4X0ToEXpeFTQ"
            artist.name.equals("Billie Eilish", ignoreCase = true) && artist.id.isBlank() -> "UCERrDZ8oN0U_n9MphMKERcg"
            artist.name.equals("Wizkid", ignoreCase = true) && artist.id.isBlank() -> "UC25DGtgYk5TwdksvtpeWYvA"
            artist.name.equals("Asake", ignoreCase = true) && artist.id.isBlank() -> "UCCjfbcoH0ZYT0r1jScDHJMg"
            artist.name.equals("Travis Scott", ignoreCase = true) && artist.id.isBlank() -> "UCf_gP4AMRSgAfyzbkeS9k4g"
            artist.name.equals("SZA", ignoreCase = true) && artist.id.isBlank() -> "UCeKDV9JgivrXehVluw5bKFA"
            artist.name.equals("Post Malone", ignoreCase = true) && artist.id.isBlank() -> "UCyD3XWRK9ko-izf2nBSFitw"
            artist.name.equals("Ariana Grande", ignoreCase = true) && artist.id.isBlank() -> "UC0076UMUgEng8HORUw_MYHA"
            else -> artist.id
        }
        return artist.copy(id = fixedId)
    }

    fun loadFavoriteArtists(userId: String) {
        viewModelScope.launch {
            SupabaseService.fetchFavoriteArtists(userId)
                .onSuccess { list ->
                    val loaded = list.map {
                        sanitizeQuizArtist(
                            QuizArtist(
                                id = it.artistId,
                                name = it.artistName,
                                artworkUrl = it.artworkUrl,
                            )
                        )
                    }
                    _favoriteArtists.value = loaded

                    // Asynchronously resolve and heal any missing or broken thumbnails from YouTube Music
                    loaded.forEach { artist ->
                        val needsThumb = artist.artworkUrl.isNullOrBlank() || artist.artworkUrl?.contains("/test") == true || artist.artworkUrl?.startsWith("http") != true
                        val needsIdRepair = list.any { it.artistName.equals("Drake", ignoreCase = true) && it.artistId == "UC0C-w0YjGpqDXGB8Tr0GGyA" }
                        if (needsThumb || needsIdRepair) {
                            launch {
                                val resolvedThumb = if (needsThumb) YtMusicRepository.getArtistThumbnail(artist.id, artist.name) else artist.artworkUrl
                                val updatedArtist = artist.copy(artworkUrl = resolvedThumb ?: artist.artworkUrl)
                                _favoriteArtists.value = _favoriteArtists.value.map {
                                    if (it.id == artist.id) updatedArtist else it
                                }
                                SupabaseService.addFavoriteArtist(userId, updatedArtist)
                            }
                        }
                    }
                }
        }
    }

    fun addFavoriteArtist(artist: QuizArtist) {
        val userId = _currentProfile.value?.id ?: return
        val sanitized = sanitizeQuizArtist(artist)
        if (_favoriteArtists.value.any { it.id == sanitized.id }) return

        _favoriteArtists.value = _favoriteArtists.value + sanitized
        viewModelScope.launch {
            var toSave = sanitized
            if (toSave.artworkUrl.isNullOrBlank() || toSave.artworkUrl?.contains("/test") == true || toSave.artworkUrl?.startsWith("http") != true) {
                val thumb = YtMusicRepository.getArtistThumbnail(sanitized.id, sanitized.name)
                if (!thumb.isNullOrBlank()) {
                    toSave = sanitized.copy(artworkUrl = thumb)
                    _favoriteArtists.value = _favoriteArtists.value.map {
                        if (it.id == sanitized.id) toSave else it
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
