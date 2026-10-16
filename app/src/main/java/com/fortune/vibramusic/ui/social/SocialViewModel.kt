package com.fortune.vibramusic.ui.social

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.fortune.vibramusic.auth.AuthStore
import com.fortune.vibramusic.data.DebugLog as Log
import com.fortune.vibramusic.data.quiz.QuizArtist
import com.fortune.vibramusic.data.social.DirectMessage
import com.fortune.vibramusic.data.social.MusicTrackAttachment
import com.fortune.vibramusic.data.social.PollData
import com.fortune.vibramusic.data.social.PostComment
import com.fortune.vibramusic.data.social.SocialPost
import com.fortune.vibramusic.data.social.SocialProfile
import com.fortune.vibramusic.data.supabase.SupabaseService
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

    init {
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

    fun setFeedTab(tab: FeedTab) {
        if (_feedTab.value != tab) {
            _feedTab.value = tab
            loadFeed()
        }
    }

    fun initUserProfile() {
        viewModelScope.launch {
            val session = authStore.activeSession
            val profile = session?.profiles?.firstOrNull { it.profileId == session.activeProfileId }
                ?: session?.profiles?.firstOrNull()

            if (session != null) {
                SupabaseService.syncUserProfile(session, profile)
                    .onSuccess { syncedProfile ->
                        _currentProfile.value = syncedProfile
                        loadFavoriteArtists(syncedProfile.id)
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
                    }
            } else {
                // Guest profile
                val guestId = "guest_device"
                val guestProfile = SocialProfile(
                    id = guestId,
                    handle = "guest_listener",
                    displayName = "Guest Listener",
                    avatarUrl = null,
                    referralCode = "vibra_guest",
                )
                _currentProfile.value = guestProfile
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
                    _posts.value = loadedPosts
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
                    _posts.value = loadedPosts
                }
            _isRefreshing.value = false
        }
    }

    fun createPost(
        content: String,
        musicAttachment: MusicTrackAttachment? = null,
        poll: PollData? = null,
        onSuccess: () -> Unit = {},
    ) {
        val user = _currentProfile.value ?: return
        viewModelScope.launch {
            _isCreatingPost.value = true
            SupabaseService.createPost(
                author = user,
                content = content,
                musicAttachment = musicAttachment,
                poll = poll,
            ).onSuccess { newPost ->
                _posts.value = listOf(newPost) + _posts.value
                _isCreatingPost.value = false
                onSuccess()
            }.onFailure { err ->
                Log.e("SocialViewModel", "Failed to create post", err)
                _isCreatingPost.value = false
            }
        }
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

    fun repost(post: SocialPost) {
        val user = _currentProfile.value ?: return
        val newRepostCount = post.repostsCount + 1

        // Optimistic update
        _posts.value = _posts.value.map {
            if (it.id == post.id) it.copy(repostsCount = newRepostCount) else it
        }

        viewModelScope.launch {
            SupabaseService.repost(postId = post.id, user = user)
                .onSuccess { newPost ->
                    _posts.value = listOf(newPost) + _posts.value
                }
                .onFailure {
                    _posts.value = _posts.value.map {
                        if (it.id == post.id) it.copy(repostsCount = post.repostsCount) else it
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
        _comments.value = emptyList()
        viewModelScope.launch {
            SupabaseService.fetchComments(post.id)
                .onSuccess { list ->
                    _comments.value = list
                }
        }
    }

    fun closeComments() {
        _selectedPostForComments.value = null
        _comments.value = emptyList()
    }

    fun addComment(postId: String, content: String, parentCommentId: String? = null) {
        val user = _currentProfile.value ?: return
        if (content.isBlank()) return

        viewModelScope.launch {
            SupabaseService.addComment(
                postId = postId,
                user = user,
                content = content,
                parentCommentId = parentCommentId,
            ).onSuccess { newComment ->
                _comments.value = _comments.value + newComment
                // Update comment count on post
                _posts.value = _posts.value.map {
                    if (it.id == postId) it.copy(commentsCount = it.commentsCount + 1) else it
                }
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
    ) {
        val user = _currentProfile.value ?: return
        val recipient = _activeChatFriend.value ?: return
        if (text.isBlank() && musicAttachment == null) return

        viewModelScope.launch {
            SupabaseService.sendDirectMessage(
                senderId = user.id,
                recipientId = recipient.id,
                message = text,
                trackAttachment = musicAttachment,
            ).onSuccess { newMsg ->
                _chatMessages.value = _chatMessages.value + newMsg
            }
        }
    }

    fun openUserProfile(profile: SocialProfile) {
        _viewingProfile.value = profile
        loadProfilePosts(profile.id)
    }

    fun closeUserProfile() {
        _viewingProfile.value = null
        _viewingProfilePosts.value = emptyList()
    }

    private fun loadProfilePosts(userId: String) {
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

    private fun loadFavoriteArtists(userId: String) {
        viewModelScope.launch {
            SupabaseService.fetchFavoriteArtists(userId)
                .onSuccess { list ->
                    _favoriteArtists.value = list.map {
                        QuizArtist(
                            id = it.artistId,
                            name = it.artistName,
                            artworkUrl = it.artworkUrl,
                        )
                    }
                }
        }
    }

    fun addFavoriteArtist(artist: QuizArtist) {
        val userId = _currentProfile.value?.id ?: return
        if (_favoriteArtists.value.any { it.id == artist.id }) return

        _favoriteArtists.value = _favoriteArtists.value + artist
        viewModelScope.launch {
            SupabaseService.addFavoriteArtist(userId, artist)
        }
    }

    fun removeFavoriteArtist(artistId: String) {
        val userId = _currentProfile.value?.id ?: return
        _favoriteArtists.value = _favoriteArtists.value.filterNot { it.id == artistId }
        viewModelScope.launch {
            SupabaseService.removeFavoriteArtist(userId, artistId)
        }
    }
}
