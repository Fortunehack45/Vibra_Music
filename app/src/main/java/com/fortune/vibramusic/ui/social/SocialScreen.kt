package com.fortune.vibramusic.ui.social

import android.content.Intent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.heightIn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.ChatBubbleOutline
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Repeat
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.StarOutline
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.fortune.vibramusic.data.model.Song
import com.fortune.vibramusic.data.social.MusicTrackAttachment
import com.fortune.vibramusic.data.social.PollData
import com.fortune.vibramusic.data.social.SocialPost
import com.fortune.vibramusic.data.social.SocialProfile
import com.fortune.vibramusic.data.social.formatHandle
import com.fortune.vibramusic.ui.components.ArtistAvatar
import com.fortune.vibramusic.ui.components.lightweightLiquidGlass
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.material.icons.rounded.DeleteOutline
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ElevatedButton
import androidx.compose.runtime.rememberCoroutineScope
import com.fortune.vibramusic.data.YtMusicRepository
import kotlinx.coroutines.launch
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.hazeSource
import com.fortune.vibramusic.data.social.PostMediaItem
import com.fortune.vibramusic.data.social.PostMediaType
import com.fortune.vibramusic.data.social.formatRelativeTime

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SocialScreen(
    viewModel: SocialViewModel,
    currentlyPlayingSong: Song?,
    onPlayTrack: (MusicTrackAttachment) -> Unit,
    onOpenProfile: (SocialProfile) -> Unit,
    onOpenArtistDetail: ((id: String, name: String, artworkUrl: String?) -> Unit)? = null,
    contentPadding: PaddingValues,
    hazeState: HazeState,
    modifier: Modifier = Modifier,
) {
    val coroutineScope = rememberCoroutineScope()
    val currentProfile by viewModel.currentProfile.collectAsStateWithLifecycle()
    var postToDelete by remember { mutableStateOf<SocialPost?>(null) }
    var inspectedQuotedPost by remember { mutableStateOf<SocialPost?>(null) }

    val posts by viewModel.posts.collectAsStateWithLifecycle()
    val feedTab by viewModel.feedTab.collectAsStateWithLifecycle()
    val isRefreshing by viewModel.isRefreshing.collectAsStateWithLifecycle()
    val isLoading by viewModel.isLoadingFeed.collectAsStateWithLifecycle()
    val errorMessage by viewModel.errorMessage.collectAsStateWithLifecycle()
    val stories by viewModel.stories.collectAsStateWithLifecycle()
    val selectedPostForComments by viewModel.selectedPostForComments.collectAsStateWithLifecycle()
    val comments by viewModel.comments.collectAsStateWithLifecycle()
    val isPosting by viewModel.isCreatingPost.collectAsStateWithLifecycle()
    val quotingPost by viewModel.quotingPost.collectAsStateWithLifecycle()

    val searchQuery by viewModel.searchQuery.collectAsStateWithLifecycle()
    val searchResults by viewModel.searchResults.collectAsStateWithLifecycle()
    val isSearching by viewModel.isSearching.collectAsStateWithLifecycle()
    var isSearchExpanded by remember { mutableStateOf(false) }

    var showCreatePostSheet by remember { mutableStateOf(false) }
    var repostActionTarget by remember { mutableStateOf<SocialPost?>(null) }
    var previewImageUrl by remember { mutableStateOf<String?>(null) }
    var activeMediaViewer by remember { mutableStateOf<Pair<List<PostMediaItem>, Int>?>(null) }
    val context = LocalContext.current

    Box(
        modifier = modifier.fillMaxSize(),
    ) {
        PullToRefreshBox(
            isRefreshing = isRefreshing,
            onRefresh = { viewModel.refreshFeed() },
            modifier = Modifier.fillMaxSize(),
        ) {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(
                    top = contentPadding.calculateTopPadding() + 8.dp,
                    bottom = contentPadding.calculateBottomPadding() + 80.dp,
                ),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                // Header Bar: Feed Tab Selector + Search Button OR Search Input
                item(key = "feed_header") {
                    if (!isSearchExpanded) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 20.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            FeedTabSwitcher(
                                selectedTab = feedTab,
                                onTabSelect = { viewModel.setFeedTab(it) },
                                modifier = Modifier.weight(1f),
                            )

                            // Search Toggle Button
                            Box(
                                modifier = Modifier
                                    .size(42.dp)
                                    .clip(CircleShape)
                                    .background(MaterialTheme.colorScheme.surfaceVariant)
                                    .clickable { isSearchExpanded = true },
                                contentAlignment = Alignment.Center,
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.Search,
                                    contentDescription = "Search",
                                    tint = MaterialTheme.colorScheme.onSurface,
                                    modifier = Modifier.size(20.dp),
                                )
                            }
                        }
                    } else {
                        // Expanded Search Bar (Solid Surface)
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 20.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            Box(
                                modifier = Modifier
                                    .weight(1f)
                                    .height(44.dp)
                                    .clip(RoundedCornerShape(22.dp))
                                    .background(MaterialTheme.colorScheme.surfaceVariant)
                                    .padding(horizontal = 14.dp),
                                contentAlignment = Alignment.CenterStart,
                            ) {
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    modifier = Modifier.fillMaxWidth(),
                                ) {
                                    Icon(
                                        imageVector = Icons.Rounded.Search,
                                        contentDescription = null,
                                        tint = MaterialTheme.colorScheme.primary,
                                        modifier = Modifier.size(18.dp),
                                    )
                                    Spacer(Modifier.width(8.dp))
                                    BasicTextField(
                                        value = searchQuery,
                                        onValueChange = { viewModel.setSearchQuery(it) },
                                        textStyle = TextStyle(
                                            color = MaterialTheme.colorScheme.onSurface,
                                            fontSize = 14.sp,
                                        ),
                                        cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                                        singleLine = true,
                                        modifier = Modifier.weight(1f),
                                        decorationBox = { inner ->
                                            if (searchQuery.isEmpty()) {
                                                Text(
                                                    text = "Search posts and users...",
                                                    style = MaterialTheme.typography.bodySmall,
                                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                                )
                                            }
                                            inner()
                                        },
                                    )
                                    if (searchQuery.isNotEmpty()) {
                                        IconButton(
                                            onClick = { viewModel.clearSearch() },
                                            modifier = Modifier.size(24.dp),
                                        ) {
                                            Icon(
                                                imageVector = Icons.Rounded.Close,
                                                contentDescription = "Clear",
                                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                                modifier = Modifier.size(16.dp),
                                            )
                                        }
                                    }
                                }
                            }

                            // Close Search Button
                            Box(
                                modifier = Modifier
                                    .size(42.dp)
                                    .clip(CircleShape)
                                    .background(MaterialTheme.colorScheme.surfaceVariant)
                                    .clickable {
                                        isSearchExpanded = false
                                        viewModel.clearSearch()
                                    },
                                contentAlignment = Alignment.Center,
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.Close,
                                    contentDescription = "Close Search",
                                    tint = MaterialTheme.colorScheme.onSurface,
                                    modifier = Modifier.size(18.dp),
                                )
                            }
                        }
                    }
                }

                if (isSearchExpanded && searchQuery.isNotBlank()) {
                    // Search Mode
                    if (isSearching) {
                        item(key = "search_loading") {
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .height(150.dp),
                                contentAlignment = Alignment.Center,
                            ) {
                                CircularProgressIndicator(
                                    color = MaterialTheme.colorScheme.primary,
                                    strokeWidth = 2.dp,
                                )
                            }
                        }
                    } else {
                        searchResults?.let { (matchedUsers, matchedPosts) ->
                            if (matchedUsers.isNotEmpty()) {
                                item(key = "search_users_header") {
                                    Text(
                                        text = "People & Artists",
                                        style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Bold),
                                        color = MaterialTheme.colorScheme.primary,
                                        modifier = Modifier.padding(horizontal = 20.dp),
                                    )
                                }
                                item(key = "search_users_row") {
                                    LazyRow(
                                        modifier = Modifier.fillMaxWidth(),
                                        contentPadding = PaddingValues(horizontal = 20.dp),
                                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                                    ) {
                                        items(matchedUsers, key = { it.id }) { user ->
                                            SearchUserChip(
                                                user = user,
                                                onClick = { onOpenProfile(user) },
                                            )
                                        }
                                    }
                                }
                            }

                            if (matchedPosts.isNotEmpty()) {
                                item(key = "search_posts_header") {
                                    Text(
                                        text = "Posts",
                                        style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Bold),
                                        color = MaterialTheme.colorScheme.primary,
                                        modifier = Modifier.padding(horizontal = 20.dp),
                                    )
                                }
                                items(matchedPosts, key = { "search_${it.id}" }) { post ->
                                    SocialPostCard(
                                        post = post,
                                        onLikeClick = { viewModel.toggleLike(post) },
                                        onCommentClick = { viewModel.openComments(post) },
                                        onRepostClick = {
                                            if (post.isRepostedByMe) {
                                                viewModel.toggleRepost(post)
                                            } else {
                                                repostActionTarget = post
                                            }
                                        },
                                        onImageClick = { previewImageUrl = it },
                                        onMediaClick = { list, idx -> activeMediaViewer = Pair(list, idx) },
                                        onShareClick = {
                                            val sendIntent = Intent(Intent.ACTION_SEND).apply {
                                                putExtra(
                                                    Intent.EXTRA_TEXT,
                                                    "Check out @${post.authorHandle}'s music post on Vibra:\n\n${post.content}",
                                                )
                                                type = "text/plain"
                                            }
                                            context.startActivity(Intent.createChooser(sendIntent, "Share Post"))
                                        },
                                        onPlayTrack = onPlayTrack,
                                        onVotePoll = { optionIdx -> viewModel.votePoll(post, optionIdx) },
                                        onAuthorClick = {
                                            onOpenProfile(
                                                post.author ?: SocialProfile(
                                                    id = post.authorId,
                                                    handle = post.authorHandle,
                                                    displayName = post.authorName,
                                                    avatarUrl = post.authorAvatar,
                                                    verifiedBadge = post.authorVerified,
                                                ),
                                            )
                                        },
                                        onTaggedArtistClick = { artistName ->
                                            coroutineScope.launch {
                                                val resolved = YtMusicRepository.resolveArtist(artistName)
                                                val browseId = resolved?.first ?: artistName
                                                val artwork = resolved?.second
                                                onOpenArtistDetail?.invoke(browseId, artistName, artwork)
                                            }
                                        },
                                        onDeleteClick = null,
                                        onQuoteClick = { quoted ->
                                            inspectedQuotedPost = quoted
                                        },
                                        onMentionClick = { handle ->
                                            viewModel.openUserProfileByHandle(handle)
                                        },
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .padding(horizontal = 16.dp),
                                    )
                                }
                            }

                            if (matchedUsers.isEmpty() && matchedPosts.isEmpty()) {
                                item(key = "no_search_results") {
                                    Box(
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .padding(top = 40.dp),
                                        contentAlignment = Alignment.Center,
                                    ) {
                                        Text(
                                            text = "No users or posts found for \"$searchQuery\"",
                                            style = MaterialTheme.typography.bodyMedium,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        )
                                    }
                                }
                            }
                        }
                    }
                } else {
                    // Regular Feed Mode
                    // Stories / Favorite Artists Row
                    if (stories.isNotEmpty()) {
                        item(key = "stories_row") {
                            SocialStoriesRow(
                                profiles = stories,
                                onProfileClick = onOpenProfile,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                    }

                    // Error Banner when posts are already cached
                    if (errorMessage != null && posts.isNotEmpty()) {
                        item(key = "feed_error_banner") {
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = 20.dp)
                                    .clip(RoundedCornerShape(14.dp))
                                    .background(MaterialTheme.colorScheme.surfaceVariant)
                                    .padding(horizontal = 14.dp, vertical = 10.dp),
                            ) {
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                ) {
                                    Row(
                                        modifier = Modifier
                                            .weight(1f)
                                            .clickable { viewModel.loadFeed() },
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                                    ) {
                                        Icon(
                                            imageVector = Icons.Rounded.Refresh,
                                            contentDescription = "Retry",
                                            tint = MaterialTheme.colorScheme.primary,
                                            modifier = Modifier.size(18.dp),
                                        )
                                        Text(
                                            text = errorMessage ?: "Couldn't load feed, tap to retry",
                                            style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold),
                                            color = MaterialTheme.colorScheme.onSurface,
                                            maxLines = 2,
                                            overflow = TextOverflow.Ellipsis,
                                        )
                                    }
                                    IconButton(
                                        onClick = { viewModel.clearErrorMessage() },
                                        modifier = Modifier.size(28.dp),
                                    ) {
                                        Icon(
                                            imageVector = Icons.Rounded.Close,
                                            contentDescription = "Dismiss",
                                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                            modifier = Modifier.size(16.dp),
                                        )
                                    }
                                }
                            }
                        }
                    }

                    // Loading State
                    if (isLoading && posts.isEmpty()) {
                        item(key = "loading_indicator") {
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .height(200.dp),
                                contentAlignment = Alignment.Center,
                            ) {
                                CircularProgressIndicator(
                                    color = MaterialTheme.colorScheme.primary,
                                    strokeWidth = 2.dp,
                                )
                            }
                        }
                    }

                    // Empty or Error State
                    if (!isLoading && posts.isEmpty()) {
                        item(key = "empty_feed") {
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(top = 60.dp, start = 32.dp, end = 32.dp),
                                contentAlignment = Alignment.Center,
                            ) {
                                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                    Icon(
                                        imageVector = Icons.Rounded.GraphicEq,
                                        contentDescription = null,
                                        tint = MaterialTheme.colorScheme.primary,
                                        modifier = Modifier.size(48.dp),
                                    )
                                    Spacer(Modifier.height(14.dp))
                                    Text(
                                        text = if (errorMessage != null) {
                                            errorMessage ?: "Couldn't load feed"
                                        } else if (feedTab == FeedTab.FRIENDS) {
                                            "No posts from friends yet"
                                        } else {
                                            "No posts in the community yet"
                                        },
                                        style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                                        color = MaterialTheme.colorScheme.onSurface,
                                    )
                                    Spacer(Modifier.height(6.dp))
                                    Text(
                                        text = if (errorMessage != null) {
                                            "Tap below to retry connecting to the feed"
                                        } else {
                                            "Be the first to share your music vibe or ask a question!"
                                        },
                                        style = MaterialTheme.typography.bodyMedium,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                    if (errorMessage != null) {
                                        Spacer(Modifier.height(14.dp))
                                        Box(
                                            modifier = Modifier
                                                .clip(RoundedCornerShape(20.dp))
                                                .background(MaterialTheme.colorScheme.primary)
                                                .clickable { viewModel.loadFeed() }
                                                .padding(horizontal = 20.dp, vertical = 10.dp),
                                            contentAlignment = Alignment.Center,
                                        ) {
                                            Text(
                                                text = "Tap to retry",
                                                style = MaterialTheme.typography.labelLarge.copy(fontWeight = FontWeight.Bold),
                                                color = MaterialTheme.colorScheme.onPrimary,
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Posts Feed
                    itemsIndexed(
                        items = posts.distinctBy { it.id },
                        key = { index, post -> "post_${post.id.ifBlank { index.toString() }}_$index" },
                    ) { _, post ->
                        val targetPost = post.repostOf?.takeIf { post.content.isBlank() } ?: post
                        SocialPostCard(
                            post = post,
                            onLikeClick = { viewModel.toggleLike(targetPost) },
                            onCommentClick = { viewModel.openComments(targetPost) },
                            onRepostClick = {
                                if (targetPost.isRepostedByMe) {
                                    viewModel.toggleRepost(targetPost)
                                } else {
                                    repostActionTarget = targetPost
                                }
                            },
                            onImageClick = { previewImageUrl = it },
                            onMediaClick = { list, idx -> activeMediaViewer = Pair(list, idx) },
                            onShareClick = {
                                val sendIntent = Intent(Intent.ACTION_SEND).apply {
                                    putExtra(
                                        Intent.EXTRA_TEXT,
                                        "Check out @${targetPost.authorHandle}'s music post on Vibra:\n\n${targetPost.content}",
                                    )
                                    type = "text/plain"
                                }
                                context.startActivity(Intent.createChooser(sendIntent, "Share Post"))
                            },
                            onPlayTrack = onPlayTrack,
                            onVotePoll = { optionIdx -> viewModel.votePoll(targetPost, optionIdx) },
                            onAuthorClick = {
                                onOpenProfile(
                                    post.author ?: SocialProfile(
                                        id = post.authorId,
                                        handle = post.authorHandle,
                                        displayName = post.authorName,
                                        avatarUrl = post.authorAvatar,
                                        verifiedBadge = post.authorVerified,
                                    ),
                                )
                            },
                            onOpenProfile = onOpenProfile,
                            onTaggedArtistClick = { artistName ->
                                coroutineScope.launch {
                                    val resolved = YtMusicRepository.resolveArtist(artistName)
                                    val browseId = resolved?.first ?: artistName
                                    val artwork = resolved?.second
                                    onOpenArtistDetail?.invoke(browseId, artistName, artwork)
                                }
                            },
                            onDeleteClick = null,
                            onQuoteClick = { quoted ->
                                inspectedQuotedPost = quoted
                            },
                            onMentionClick = { handle ->
                                viewModel.openUserProfileByHandle(handle)
                            },
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 16.dp),
                        )
                    }
                }
            }
        }

        // Floating Action Button to Create Post
        FloatingActionButton(
            onClick = { showCreatePostSheet = true },
            containerColor = MaterialTheme.colorScheme.primary,
            contentColor = MaterialTheme.colorScheme.onPrimary,
            shape = CircleShape,
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(end = 20.dp, bottom = (contentPadding.calculateBottomPadding() - 40.dp).coerceAtLeast(16.dp))
                .size(54.dp),
        ) {
            Icon(
                imageVector = Icons.Rounded.Add,
                contentDescription = "Create Post",
                modifier = Modifier.size(26.dp),
            )
        }
    }

    // Create / Quote Post Sheet
    if (showCreatePostSheet || quotingPost != null) {
        CreatePostSheet(
            currentlyPlayingSong = currentlyPlayingSong,
            quotedPost = quotingPost,
            isPosting = isPosting,
            onDismiss = {
                showCreatePostSheet = false
                viewModel.clearQuotePost()
            },
            onSubmitPost = { content, imageUrls, videoUrl, gifUrl, audioUrl, isReview, rating, taggedArtist, track, poll, quoteOfId ->
                viewModel.createPost(
                    content = content,
                    imageUrls = imageUrls,
                    videoUrl = videoUrl,
                    gifUrl = gifUrl,
                    audioUrl = audioUrl,
                    isReview = isReview,
                    rating = rating,
                    taggedArtist = taggedArtist,
                    musicAttachment = track,
                    poll = poll,
                    quoteOfId = quoteOfId,
                ) {
                    showCreatePostSheet = false
                    viewModel.clearQuotePost()
                }
            },
        )
    }

    // Dedicated Twitter (X) style Post Thread Screen (Hero post on top, comments below, quick reply docked at bottom)
    selectedPostForComments?.let { post ->
        PostThreadScreen(
            post = post,
            comments = comments,
            currentProfile = currentProfile,
            onBack = { viewModel.closeComments() },
            onLikePost = { viewModel.toggleLike(it) },
            onRepostPost = {
                if (it.isRepostedByMe) {
                    viewModel.toggleRepost(it)
                } else {
                    repostActionTarget = it
                }
            },
            onEditPost = { postId, newContent ->
                viewModel.editPost(postId, newContent)
            },
            onDeletePost = { postId ->
                viewModel.deletePost(postId)
                viewModel.closeComments()
            },
            onAddComment = { content, parentId, gifUrl ->
                viewModel.addComment(post.id, content, parentId, gifUrl)
            },
            onToggleLikeComment = { viewModel.toggleLikeComment(it) },
            onEditComment = { commentId, newContent ->
                viewModel.editComment(commentId, newContent)
            },
            onDeleteComment = { commentId, postId ->
                viewModel.deleteComment(commentId, postId)
            },
            onOpenProfile = { profile ->
                viewModel.closeComments()
                onOpenProfile(profile)
            },
            onPlayTrack = onPlayTrack,
            onMediaClick = { list, idx ->
                activeMediaViewer = Pair(list, idx)
            },
            onMentionClick = { handle ->
                viewModel.closeComments()
                viewModel.openUserProfileByHandle(handle)
            },
            onVotePoll = { optionIdx ->
                viewModel.votePoll(post, optionIdx)
            },
            onQuoteClick = { quoted ->
                viewModel.openComments(quoted)
            },
        )
    }

    // Repost / Quote Post Bottom Sheet
    repostActionTarget?.let { target ->
        RepostOptionsSheet(
            targetPost = target,
            onDismiss = { repostActionTarget = null },
            onRepost = {
                viewModel.repost(target)
                repostActionTarget = null
            },
            onQuote = {
                viewModel.openQuotePost(target)
                repostActionTarget = null
            },
        )
    }

    // Fullscreen Multi-Media Viewer Dialog (Swipeable Images & Videos)
    activeMediaViewer?.let { (mediaList, idx) ->
        FullScreenMediaViewerDialog(
            mediaList = mediaList,
            initialIndex = idx,
            onDismiss = { activeMediaViewer = null },
        )
    }

    previewImageUrl?.let { url ->
        FullScreenMediaViewerDialog(
            mediaList = listOf(PostMediaItem(url = url, type = PostMediaType.IMAGE)),
            initialIndex = 0,
            onDismiss = { previewImageUrl = null },
        )
    }

    // Delete Post Confirmation Dialog
    postToDelete?.let { target ->
        AlertDialog(
            onDismissRequest = { postToDelete = null },
            containerColor = MaterialTheme.colorScheme.surface,
            title = {
                Text(
                    text = "Delete post",
                    style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                    color = MaterialTheme.colorScheme.onSurface,
                )
            },
            text = {
                Text(
                    text = "Are you sure you want to delete this post? This action cannot be undone.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            },
            confirmButton = {
                ElevatedButton(
                    onClick = {
                        viewModel.deletePost(target)
                        postToDelete = null
                    },
                    colors = ButtonDefaults.elevatedButtonColors(
                        containerColor = MaterialTheme.colorScheme.error,
                        contentColor = MaterialTheme.colorScheme.onError,
                    ),
                    shape = RoundedCornerShape(12.dp),
                ) {
                    Text("Delete", fontWeight = FontWeight.Bold)
                }
            },
            dismissButton = {
                ElevatedButton(
                    onClick = { postToDelete = null },
                    colors = ButtonDefaults.elevatedButtonColors(
                        containerColor = MaterialTheme.colorScheme.surfaceVariant,
                        contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
                    ),
                    shape = RoundedCornerShape(12.dp),
                ) {
                    Text("Cancel")
                }
            },
        )
    }

    // Inspected Quoted Post Modal Dialog
    inspectedQuotedPost?.let { quoted ->
        Dialog(
            onDismissRequest = { inspectedQuotedPost = null },
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(MaterialTheme.colorScheme.surface)
                    .systemBarsPadding(),
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(horizontal = 16.dp, vertical = 12.dp),
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(bottom = 12.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            text = "Quoted Post",
                            style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                        IconButton(onClick = { inspectedQuotedPost = null }) {
                            Icon(
                                imageVector = Icons.Rounded.Close,
                                contentDescription = "Close",
                                tint = MaterialTheme.colorScheme.onSurface,
                            )
                        }
                    }

                    SocialPostCard(
                        post = quoted,
                        onLikeClick = { viewModel.toggleLike(quoted) },
                        onCommentClick = {
                            inspectedQuotedPost = null
                            viewModel.openComments(quoted)
                        },
                        onRepostClick = {
                            inspectedQuotedPost = null
                            repostActionTarget = quoted
                        },
                        onImageClick = { previewImageUrl = it },
                        onMediaClick = { list, idx -> activeMediaViewer = Pair(list, idx) },
                        onShareClick = {
                            val sendIntent = Intent(Intent.ACTION_SEND).apply {
                                putExtra(
                                    Intent.EXTRA_TEXT,
                                    "Check out @${quoted.authorHandle}'s post on Vibra:\n\n${quoted.content}",
                                )
                                type = "text/plain"
                            }
                            context.startActivity(Intent.createChooser(sendIntent, "Share Post"))
                        },
                        onPlayTrack = onPlayTrack,
                        onVotePoll = { viewModel.votePoll(quoted, it) },
                        onAuthorClick = {
                            inspectedQuotedPost = null
                            onOpenProfile(
                                quoted.author ?: SocialProfile(
                                    id = quoted.authorId,
                                    handle = quoted.authorHandle,
                                    displayName = quoted.authorName,
                                    avatarUrl = quoted.authorAvatar,
                                    verifiedBadge = quoted.authorVerified,
                                ),
                            )
                        },
                        onTaggedArtistClick = { artistName ->
                            inspectedQuotedPost = null
                            coroutineScope.launch {
                                val resolved = YtMusicRepository.resolveArtist(artistName)
                                val browseId = resolved?.first ?: artistName
                                val artwork = resolved?.second
                                onOpenArtistDetail?.invoke(browseId, artistName, artwork)
                            }
                        },
                        onMentionClick = { handle ->
                            inspectedQuotedPost = null
                            viewModel.openUserProfileByHandle(handle)
                        },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        }
    }
}

@Composable
private fun SearchUserChip(
    user: SocialProfile,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .clip(RoundedCornerShape(20.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 6.dp),
    ) {
        ArtistAvatar(
            name = user.displayName,
            artworkUrl = user.avatarUrl,
            size = 32.dp,
        )
        Spacer(Modifier.width(8.dp))
        Column {
            Text(
                text = user.displayName,
                style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
            )
            Text(
                text = formatHandle(user.handle),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
            )
        }
    }
}

@Composable
fun FeedTabSwitcher(
    selectedTab: FeedTab,
    onTabSelect: (FeedTab) -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(24.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .padding(4.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.Center,
        ) {
            FeedTabPill(
                label = "For You",
                selected = selectedTab == FeedTab.FOR_YOU,
                onClick = { onTabSelect(FeedTab.FOR_YOU) },
                modifier = Modifier.weight(1f),
            )
            FeedTabPill(
                label = "Friends",
                selected = selectedTab == FeedTab.FRIENDS,
                onClick = { onTabSelect(FeedTab.FRIENDS) },
                modifier = Modifier.weight(1f),
            )
        }
    }
}

@Composable
private fun FeedTabPill(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val bgColor by animateColorAsState(
        targetValue = if (selected) MaterialTheme.colorScheme.primary else Color.Transparent,
        label = "feedTabBg",
    )
    val textColor by animateColorAsState(
        targetValue = if (selected) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurfaceVariant,
        label = "feedTabText",
    )

    Box(
        modifier = modifier
            .clip(RoundedCornerShape(20.dp))
            .background(bgColor)
            .clickable(onClick = onClick)
            .padding(vertical = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelLarge.copy(fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium),
            color = textColor,
        )
    }
}

@Composable
fun SocialStoriesRow(
    profiles: List<SocialProfile>,
    onProfileClick: (SocialProfile) -> Unit,
    modifier: Modifier = Modifier,
) {
    LazyRow(
        modifier = modifier,
        contentPadding = PaddingValues(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        itemsIndexed(
            items = profiles.distinctBy { it.id },
            key = { index, user -> "story_${user.id.ifBlank { index.toString() }}_$index" },
        ) { _, user ->
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier
                    .clip(RoundedCornerShape(12.dp))
                    .clickable { onProfileClick(user) }
                    .padding(4.dp),
            ) {
                Box(
                    modifier = Modifier
                        .size(56.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.surfaceVariant),
                    contentAlignment = Alignment.Center,
                ) {
                    ArtistAvatar(
                        name = user.displayName,
                        artworkUrl = user.avatarUrl,
                        size = 52.dp,
                    )
                }

                Spacer(Modifier.height(6.dp))

                Text(
                    text = user.displayName,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.width(62.dp),
                )
            }
        }
    }
}

@Composable
fun SocialPostCard(
    post: SocialPost,
    onLikeClick: () -> Unit,
    onCommentClick: () -> Unit,
    onRepostClick: () -> Unit,
    onImageClick: (String) -> Unit = {},
    onMediaClick: ((List<PostMediaItem>, Int) -> Unit)? = null,
    onShareClick: () -> Unit,
    onPlayTrack: (MusicTrackAttachment) -> Unit,
    onVotePoll: (Int) -> Unit,
    onAuthorClick: () -> Unit,
    onTaggedArtistClick: ((String) -> Unit)? = null,
    onEditClick: (() -> Unit)? = null,
    onDeleteClick: (() -> Unit)? = null,
    onQuoteClick: ((SocialPost) -> Unit)? = null,
    onOpenProfile: ((SocialProfile) -> Unit)? = null,
    onMentionClick: ((String) -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val isPureRepost = (post.repostOf != null || post.repostOfId != null) && post.content.isBlank()
    val displayPost = post.repostOf ?: post

    val reposterProfile = post.author ?: SocialProfile(
        id = post.authorId,
        handle = post.authorHandle,
        displayName = post.authorName,
        avatarUrl = post.authorAvatar,
        verifiedBadge = post.authorVerified,
    )

    val displayAuthorProfile = displayPost.author ?: SocialProfile(
        id = displayPost.authorId,
        handle = displayPost.authorHandle,
        displayName = displayPost.authorName,
        avatarUrl = displayPost.authorAvatar,
        verifiedBadge = displayPost.authorVerified,
    )

    val onReposterHeaderClick: () -> Unit = {
        if (onOpenProfile != null) {
            onOpenProfile(reposterProfile)
        } else {
            onAuthorClick()
        }
    }

    val onDisplayAuthorClick: () -> Unit = {
        if (isPureRepost) {
            if (onOpenProfile != null) {
                onOpenProfile(displayAuthorProfile)
            } else if (onQuoteClick != null) {
                onQuoteClick(displayPost)
            } else {
                onAuthorClick()
            }
        } else {
            if (onOpenProfile != null) {
                onOpenProfile(displayAuthorProfile)
            } else {
                onAuthorClick()
            }
        }
    }

    Box(
        modifier = modifier
            .clip(RoundedCornerShape(20.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .clickable(onClick = onCommentClick)
            .padding(16.dp),
    ) {
        Column(modifier = Modifier.fillMaxWidth()) {
            // Repost Header indicator
            if (post.repostOfId != null || post.repostOf != null) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .clip(RoundedCornerShape(6.dp))
                        .clickable(onClick = onReposterHeaderClick)
                        .padding(bottom = 8.dp),
                ) {
                    Icon(
                        imageVector = Icons.Rounded.Repeat,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(14.dp),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(
                        text = "${post.authorName} reposted",
                        style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.SemiBold),
                        color = MaterialTheme.colorScheme.primary,
                    )
                }
            }

            if (isPureRepost && post.repostOf == null) {
                Text(
                    text = "This post is no longer available.",
                    style = MaterialTheme.typography.bodyMedium.copy(fontStyle = androidx.compose.ui.text.font.FontStyle.Italic),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(vertical = 12.dp),
                )
            } else {
                // Author Row
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(
                        modifier = Modifier
                            .size(42.dp)
                            .clip(CircleShape)
                            .clickable(onClick = onDisplayAuthorClick),
                        contentAlignment = Alignment.Center,
                    ) {
                        ArtistAvatar(
                            name = displayPost.authorName,
                            artworkUrl = displayPost.authorAvatar,
                            size = 42.dp,
                        )
                    }

                    Spacer(Modifier.width(12.dp))

                    Column(
                        modifier = Modifier
                            .weight(1f)
                            .clickable(onClick = onDisplayAuthorClick),
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                        ) {
                            Text(
                                text = displayPost.authorName,
                                style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Bold),
                                color = MaterialTheme.colorScheme.onSurface,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            if (displayPost.authorVerified) {
                                Icon(
                                    imageVector = Icons.Rounded.CheckCircle,
                                    contentDescription = "Verified",
                                    tint = MaterialTheme.colorScheme.primary,
                                    modifier = Modifier.size(14.dp),
                                )
                            }
                            displayPost.taggedArtist?.let { artist ->
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(4.dp))
                                        .clickable { onTaggedArtistClick?.invoke(artist) }
                                        .padding(horizontal = 2.dp, vertical = 1.dp),
                                ) {
                                    Icon(
                                        imageVector = Icons.Rounded.ChevronRight,
                                        contentDescription = null,
                                        tint = MaterialTheme.colorScheme.primary,
                                        modifier = Modifier.size(14.dp),
                                    )
                                    Spacer(Modifier.width(2.dp))
                                    Text(
                                        text = artist,
                                        style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Bold),
                                        color = MaterialTheme.colorScheme.primary,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                            }
                            val relativeTime = formatRelativeTime(displayPost.createdAt)
                            if (relativeTime.isNotBlank()) {
                                Text(
                                    text = " · $relativeTime",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }

                        Text(
                            text = formatHandle(displayPost.authorHandle),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }

                    if (onEditClick != null) {
                        IconButton(
                            onClick = onEditClick,
                            modifier = Modifier.size(32.dp),
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.Edit,
                                contentDescription = "Edit Post",
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(18.dp),
                            )
                        }
                    }

                    if (onDeleteClick != null) {
                        IconButton(
                            onClick = onDeleteClick,
                            modifier = Modifier.size(32.dp),
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.DeleteOutline,
                                contentDescription = "Delete Post",
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(18.dp),
                            )
                        }
                    }
                }

                // Review 5-Star Rating Bar
                if (displayPost.isReview && displayPost.rating > 0) {
                    Spacer(Modifier.height(8.dp))
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(3.dp),
                    ) {
                        (1..5).forEach { star ->
                            Icon(
                                imageVector = if (star <= displayPost.rating) Icons.Rounded.Star else Icons.Rounded.StarOutline,
                                contentDescription = null,
                                tint = if (star <= displayPost.rating) Color(0xFFFFB300) else MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(16.dp),
                            )
                        }
                    }
                }

                Spacer(Modifier.height(10.dp))

                // Text Content
                if (displayPost.content.isNotBlank()) {
                    val isLong = displayPost.content.length > 259
                    var isExpanded by remember(displayPost.id) { mutableStateOf(false) }

                    val displayText = if (isLong && !isExpanded) {
                        displayPost.content.take(259).trimEnd() + "..."
                    } else {
                        displayPost.content
                    }

                    Column {
                        ClickableMentionText(
                            content = displayText,
                            fontSize = 16.sp,
                            color = MaterialTheme.colorScheme.onSurface,
                            lineHeight = 22.sp,
                            onMentionClick = onMentionClick,
                        )
                        if (isLong) {
                            Spacer(Modifier.height(4.dp))
                            Text(
                                text = if (isExpanded) "Show less" else "Read more",
                                style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                                color = MaterialTheme.colorScheme.primary,
                                modifier = Modifier
                                    .clip(RoundedCornerShape(4.dp))
                                    .clickable { isExpanded = !isExpanded }
                                    .padding(vertical = 2.dp, horizontal = 2.dp),
                            )
                        }
                    }
                    Spacer(Modifier.height(12.dp))
                }

                // Attached Media Carousel (Swipeable HorizontalPager with indicator dots)
                val images = displayPost.effectiveImages
                if (images.isNotEmpty()) {
                    PostMediaCarousel(
                        images = images,
                        onImageClick = { clickedUrl ->
                            val idx = displayPost.allMediaItems.indexOfFirst { it.url == clickedUrl }.coerceAtLeast(0)
                            if (onMediaClick != null) {
                                onMediaClick(displayPost.allMediaItems, idx)
                            } else {
                                onImageClick(clickedUrl)
                            }
                        },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(12.dp))
                }

                // Attached GIF
                displayPost.gifUrl?.takeIf { it.isNotBlank() && it != "null" }?.let { gifUrl ->
                    if (!images.contains(gifUrl)) {
                        val gifIdx = displayPost.allMediaItems.indexOfFirst { it.url == gifUrl }.coerceAtLeast(0)
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(16.dp))
                                .background(MaterialTheme.colorScheme.surface)
                                .clickable {
                                    if (onMediaClick != null) {
                                        onMediaClick(displayPost.allMediaItems, gifIdx)
                                    } else {
                                        onImageClick(gifUrl)
                                    }
                                },
                        ) {
                            AsyncImage(
                                model = gifUrl,
                                contentDescription = "GIF",
                                contentScale = ContentScale.FillWidth,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                        Spacer(Modifier.height(12.dp))
                    }
                }

                // Attached Video Player
                displayPost.videoUrl?.takeIf { it.isNotBlank() && it != "null" }?.let { videoUrl ->
                    val videoIdx = displayPost.allMediaItems.indexOfFirst { it.url == videoUrl }.coerceAtLeast(0)
                    PostVideoPlayer(
                        videoUrl = videoUrl,
                        onFullScreenClick = {
                            if (onMediaClick != null) {
                                onMediaClick(displayPost.allMediaItems, videoIdx)
                            }
                        },
                        modifier = Modifier
                            .fillMaxWidth()
                            .aspectRatio(16f / 9f),
                    )
                    Spacer(Modifier.height(12.dp))
                }

                // Attached Voice Note Player
                displayPost.audioUrl?.takeIf { it.isNotBlank() && it != "null" }?.let { audioUrl ->
                    VoiceNotePlayerWidget(
                        audioUrl = audioUrl,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(12.dp))
                }

                // Attached Track Card
                displayPost.musicTrack?.let { track ->
                    PlayableTrackCard(
                        track = track,
                        onPlay = { onPlayTrack(track) },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(12.dp))
                }

                // Interactive Poll Card
                displayPost.poll?.let { poll ->
                    PollCard(
                        poll = poll,
                        onVote = onVotePoll,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(12.dp))
                }

                // Embedded Quoted Post
                if (displayPost.quoteOf != null || displayPost.quoteOfId != null) {
                    QuotedPostCard(
                        quotedPost = displayPost.quoteOf,
                        quotedId = displayPost.quoteOfId,
                        onPlayTrack = onPlayTrack,
                        onClick = {
                            displayPost.quoteOf?.let { onQuoteClick?.invoke(it) }
                        },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(12.dp))
                }

                // Actions Bar
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    // Like Button
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .clip(RoundedCornerShape(12.dp))
                            .clickable(onClick = onLikeClick)
                            .padding(horizontal = 8.dp, vertical = 6.dp),
                    ) {
                        Icon(
                            imageVector = if (displayPost.isLikedByMe) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder,
                            contentDescription = "Like",
                            tint = if (displayPost.isLikedByMe) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(19.dp),
                        )
                        if (displayPost.likesCount > 0) {
                            Spacer(Modifier.width(6.dp))
                            Text(
                                text = displayPost.likesCount.toString(),
                                style = MaterialTheme.typography.labelMedium,
                                color = if (displayPost.isLikedByMe) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }

                    // Comment Button
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .clip(RoundedCornerShape(12.dp))
                            .clickable(onClick = onCommentClick)
                            .padding(horizontal = 8.dp, vertical = 6.dp),
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.ChatBubbleOutline,
                            contentDescription = "Comment",
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(19.dp),
                        )
                        if (displayPost.commentsCount > 0) {
                            Spacer(Modifier.width(6.dp))
                            Text(
                                text = displayPost.commentsCount.toString(),
                                style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }

                    // Repost Button
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .clip(RoundedCornerShape(12.dp))
                            .clickable(onClick = onRepostClick)
                            .padding(horizontal = 8.dp, vertical = 6.dp),
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.Repeat,
                            contentDescription = "Repost",
                            tint = if (displayPost.isRepostedByMe) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(19.dp),
                        )
                        if (displayPost.repostsCount > 0) {
                            Spacer(Modifier.width(6.dp))
                            Text(
                                text = displayPost.repostsCount.toString(),
                                style = MaterialTheme.typography.labelMedium,
                                color = if (displayPost.isRepostedByMe) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }

                    // Share Button
                    IconButton(
                        onClick = onShareClick,
                        modifier = Modifier.size(34.dp),
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.Share,
                            contentDescription = "Share",
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                }
            }
        }
    }
}

@Composable
fun VoiceNotePlayerWidget(
    audioUrl: String,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val voiceRecorder = remember { VoiceRecorderManager(context) }
    val isPlaying by voiceRecorder.isPlaying.collectAsState()
    val progress by voiceRecorder.playbackProgress.collectAsState()
    val currentPositionMs by voiceRecorder.playbackPositionMs.collectAsState()
    val durationMs by voiceRecorder.playbackDurationMs.collectAsState()

    DisposableEffect(audioUrl) {
        onDispose {
            voiceRecorder.stopPlayback()
        }
    }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colorScheme.surface)
            .padding(horizontal = 14.dp, vertical = 10.dp),
    ) {
        IconButton(
            onClick = {
                if (isPlaying) voiceRecorder.pauseAudio()
                else voiceRecorder.playAudio(audioUrl)
            },
            modifier = Modifier
                .size(38.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.primary),
        ) {
            Icon(
                imageVector = if (isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow,
                contentDescription = "Play voice note",
                tint = MaterialTheme.colorScheme.onPrimary,
                modifier = Modifier.size(22.dp),
            )
        }

        Spacer(Modifier.width(12.dp))

        // Dynamic Waveform
        Row(
            modifier = Modifier.weight(1f),
            horizontalArrangement = Arrangement.spacedBy(3.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val barHeights = listOf(14, 24, 18, 30, 20, 16, 26, 22, 12, 28, 20, 15, 25, 18)
            barHeights.forEachIndexed { idx, h ->
                val barProgress = idx.toFloat() / barHeights.size
                val isPassed = barProgress <= progress
                Box(
                    modifier = Modifier
                        .width(3.dp)
                        .height(h.dp)
                        .clip(RoundedCornerShape(1.5.dp))
                        .background(
                            if (isPassed) MaterialTheme.colorScheme.primary
                            else MaterialTheme.colorScheme.onSurfaceVariant
                        ),
                )
            }
        }

        Spacer(Modifier.width(10.dp))

        val displaySeconds = if (isPlaying) currentPositionMs / 1000 else (if (durationMs > 0) durationMs / 1000 else 0)
        Text(
            text = String.format("%02d:%02d", displaySeconds / 60, displaySeconds % 60),
            style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.Bold),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
fun PostMediaCarousel(
    images: List<String>,
    onImageClick: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    if (images.isEmpty()) return

    if (images.size == 1) {
        Box(
            modifier = modifier
                .fillMaxWidth()
                .height(260.dp)
                .clip(RoundedCornerShape(16.dp))
                .background(MaterialTheme.colorScheme.surface)
                .clickable { onImageClick(images[0]) },
        ) {
            AsyncImage(
                model = images[0],
                contentDescription = "Post image",
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
        }
    } else {
        val pagerState = rememberPagerState(pageCount = { images.size })
        Column(modifier = modifier.fillMaxWidth()) {
            HorizontalPager(
                state = pagerState,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(280.dp)
                    .clip(RoundedCornerShape(16.dp))
                    .background(MaterialTheme.colorScheme.surface),
            ) { page ->
                val url = images[page]
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .clickable { onImageClick(url) },
                ) {
                    AsyncImage(
                        model = url,
                        contentDescription = "Media ${page + 1}",
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxSize(),
                    )
                }
            }

            Spacer(Modifier.height(8.dp))

            // Dynamic indicator dots: pill for active, small dot for inactive
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                repeat(images.size) { index ->
                    val isActive = pagerState.currentPage == index
                    Box(
                        modifier = Modifier
                            .padding(horizontal = 3.dp)
                            .height(6.dp)
                            .width(if (isActive) 18.dp else 6.dp)
                            .clip(RoundedCornerShape(3.dp))
                            .background(
                                if (isActive) MaterialTheme.colorScheme.primary
                                else MaterialTheme.colorScheme.onSurfaceVariant
                            ),
                    )
                }
            }
        }
    }
}

@Composable
fun PlayableTrackCard(
    track: MusicTrackAttachment,
    onPlay: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val effectiveCover = track.artworkUrl?.takeIf { it.isNotBlank() && it != "null" }
        ?: track.thumbnailUrl?.takeIf { it.isNotBlank() && it != "null" }
        ?: if (track.videoId.isNotBlank()) "https://i.ytimg.com/vi/${track.videoId}/hqdefault.jpg" else null

    Box(
        modifier = modifier
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colorScheme.surface)
            .clickable(onClick = onPlay)
            .padding(12.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Box(
                modifier = Modifier
                    .size(48.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(MaterialTheme.colorScheme.surfaceVariant),
            ) {
                if (effectiveCover != null) {
                    AsyncImage(
                        model = effectiveCover,
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxSize(),
                    )
                } else {
                    Icon(
                        imageVector = Icons.Rounded.MusicNote,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.align(Alignment.Center),
                    )
                }
            }

            Spacer(Modifier.width(12.dp))

            Column(Modifier.weight(1f)) {
                Text(
                    text = track.title,
                    style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Bold),
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = track.artist,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }

            Box(
                modifier = Modifier
                    .size(36.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.primary),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Rounded.PlayArrow,
                    contentDescription = "Play",
                    tint = MaterialTheme.colorScheme.onPrimary,
                    modifier = Modifier.size(20.dp),
                )
            }
        }
    }
}

@Composable
fun PollCard(
    poll: PollData,
    onVote: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colorScheme.surface)
            .padding(14.dp),
    ) {
        Text(
            text = poll.question,
            style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Bold),
            color = MaterialTheme.colorScheme.onSurface,
        )

        Spacer(Modifier.height(12.dp))

        val hasVoted = poll.userVotedIndex != null
        val totalVotes = poll.totalVotes.coerceAtLeast(1)

        poll.options.forEachIndexed { index, option ->
            val isMyVote = poll.userVotedIndex == index
            val percentage = (option.votes.toFloat() / totalVotes * 100).toInt()
            val animatedProgress by animateFloatAsState(
                targetValue = if (hasVoted) option.votes.toFloat() / totalVotes else 0f,
                label = "pollProgress",
            )

            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 4.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(MaterialTheme.colorScheme.surfaceVariant)
                    .clickable(enabled = !hasVoted) { onVote(index) }
                    .padding(vertical = 8.dp, horizontal = 10.dp),
            ) {
                if (hasVoted) {
                    val progressFillColor = if (isMyVote) {
                        MaterialTheme.colorScheme.primary.copy(alpha = 0.22f)
                    } else {
                        MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f)
                    }
                    Box(
                        modifier = Modifier
                            .matchParentSize()
                            .align(Alignment.CenterStart),
                    ) {
                        Box(
                            modifier = Modifier
                                .fillMaxHeight()
                                .fillMaxWidth(animatedProgress.coerceIn(0f, 1f))
                                .background(progressFillColor, RoundedCornerShape(12.dp)),
                        )
                    }
                }

                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 6.dp, vertical = 2.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.weight(1f),
                    ) {
                        val optionThumb = option.imageUrl ?: option.songAttachment?.artworkUrl ?: option.songAttachment?.thumbnailUrl
                        if (optionThumb != null) {
                            Box(
                                modifier = Modifier
                                    .size(36.dp)
                                    .clip(RoundedCornerShape(6.dp))
                                    .background(MaterialTheme.colorScheme.surface),
                            ) {
                                AsyncImage(
                                    model = optionThumb,
                                    contentDescription = null,
                                    contentScale = ContentScale.Crop,
                                    modifier = Modifier.fillMaxSize(),
                                )
                            }
                            Spacer(Modifier.width(10.dp))
                        }

                        Column {
                            Text(
                                text = option.text,
                                style = MaterialTheme.typography.bodyMedium.copy(
                                    fontWeight = if (isMyVote) FontWeight.Bold else FontWeight.Medium,
                                ),
                                color = MaterialTheme.colorScheme.onSurface,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            option.songAttachment?.let { song ->
                                Text(
                                    text = song.artist,
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                        }
                    }

                    if (hasVoted) {
                        Spacer(Modifier.width(8.dp))
                        Text(
                            text = "$percentage%",
                            style = MaterialTheme.typography.labelLarge.copy(fontWeight = FontWeight.Bold),
                            color = if (isMyVote) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                        )
                    }
                }
            }
        }

        Spacer(Modifier.height(8.dp))

        Text(
            text = if (hasVoted) "${poll.totalVotes} votes · Poll ended" else "${poll.totalVotes} votes · Tap to vote",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
fun QuotedPostCard(
    quotedPost: SocialPost?,
    quotedId: String?,
    onPlayTrack: (MusicTrackAttachment) -> Unit,
    onClick: () -> Unit = {},
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colorScheme.surface)
            .clickable(onClick = onClick)
            .padding(14.dp),
    ) {
        if (quotedPost == null) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(
                    imageVector = Icons.Rounded.Repeat,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(16.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    text = "View quoted post",
                    style = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.Medium),
                    color = MaterialTheme.colorScheme.primary,
                )
            }
        } else {
            Column(modifier = Modifier.fillMaxWidth()) {
                // Author row
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Box(
                        modifier = Modifier
                            .size(24.dp)
                            .clip(CircleShape),
                        contentAlignment = Alignment.Center,
                    ) {
                        ArtistAvatar(
                            name = quotedPost.authorName,
                            artworkUrl = quotedPost.authorAvatar,
                            size = 24.dp,
                        )
                    }

                    Spacer(Modifier.width(8.dp))

                    Text(
                        text = quotedPost.authorName,
                        style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )

                    quotedPost.taggedArtist?.let { artist ->
                        Spacer(Modifier.width(4.dp))
                        Icon(
                            imageVector = Icons.Rounded.ChevronRight,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(14.dp),
                        )
                        Spacer(Modifier.width(2.dp))
                        Text(
                            text = artist,
                            style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                            color = MaterialTheme.colorScheme.onSurface,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }

                    val relativeTime = formatRelativeTime(quotedPost.createdAt)
                    if (relativeTime.isNotBlank()) {
                        Spacer(Modifier.width(6.dp))
                        Text(
                            text = relativeTime,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }

                // Review rating stars if quoted post is review
                if (quotedPost.isReview && quotedPost.rating > 0) {
                    Spacer(Modifier.height(6.dp))
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(3.dp),
                    ) {
                        (1..5).forEach { star ->
                            Icon(
                                imageVector = if (star <= quotedPost.rating) Icons.Rounded.Star else Icons.Rounded.StarOutline,
                                contentDescription = null,
                                tint = if (star <= quotedPost.rating) Color(0xFFFFB300) else MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(14.dp),
                            )
                        }
                    }
                }

                // Quoted text
                if (quotedPost.content.isNotBlank()) {
                    Spacer(Modifier.height(8.dp))
                    Text(
                        text = quotedPost.content,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                        lineHeight = 18.sp,
                    )
                }

                // Quoted song track
                quotedPost.musicTrack?.let { track ->
                    Spacer(Modifier.height(8.dp))
                    PlayableTrackCard(
                        track = track,
                        onPlay = { onPlayTrack(track) },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RepostOptionsSheet(
    targetPost: SocialPost,
    onDismiss: () -> Unit,
    onRepost: () -> Unit,
    onQuote: () -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = MaterialTheme.colorScheme.surface,
        dragHandle = null,
        shape = RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 24.dp),
        ) {
            Text(
                text = "Share Post",
                style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                color = MaterialTheme.colorScheme.onSurface,
            )

            Spacer(Modifier.height(16.dp))

            // Instant Repost
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .clickable(onClick = onRepost)
                    .padding(vertical = 12.dp, horizontal = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    modifier = Modifier
                        .size(40.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.surfaceVariant),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = Icons.Rounded.Repeat,
                        contentDescription = "Repost",
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(20.dp),
                    )
                }

                Spacer(Modifier.width(14.dp))

                Column {
                    Text(
                        text = "Repost",
                        style = MaterialTheme.typography.bodyLarge.copy(fontWeight = FontWeight.SemiBold),
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Text(
                        text = "Instantly share this post with your followers",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            Spacer(Modifier.height(8.dp))

            // Quote Post
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .clickable(onClick = onQuote)
                    .padding(vertical = 12.dp, horizontal = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    modifier = Modifier
                        .size(40.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.surfaceVariant),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = Icons.Rounded.Edit,
                        contentDescription = "Quote Post",
                        tint = MaterialTheme.colorScheme.secondary,
                        modifier = Modifier.size(20.dp),
                    )
                }

                Spacer(Modifier.width(14.dp))

                Column {
                    Text(
                        text = "Quote Post",
                        style = MaterialTheme.typography.bodyLarge.copy(fontWeight = FontWeight.SemiBold),
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Text(
                        text = "Add your own commentary or music to this post",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            Spacer(Modifier.height(16.dp))
        }
    }
}

@Composable
fun FullscreenImageDialog(
    imageUrl: String,
    onDismiss: () -> Unit,
) {
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color.Black),
        ) {
            AsyncImage(
                model = imageUrl,
                contentDescription = null,
                contentScale = ContentScale.Fit,
                modifier = Modifier
                    .fillMaxSize()
                    .padding(16.dp)
                    .clickable(onClick = onDismiss),
            )

            IconButton(
                onClick = onDismiss,
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(24.dp)
                    .size(42.dp)
                    .clip(CircleShape)
                    .background(Color(0xFF222226)),
            ) {
                Icon(
                    imageVector = Icons.Rounded.Close,
                    contentDescription = "Close",
                    tint = Color.White,
                    modifier = Modifier.size(22.dp),
                )
            }
        }
    }
}

