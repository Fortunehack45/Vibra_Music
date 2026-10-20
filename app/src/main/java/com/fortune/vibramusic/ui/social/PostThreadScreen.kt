package com.fortune.vibramusic.ui.social

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.Send
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.DeleteOutline
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.Gif
import androidx.compose.material.icons.rounded.Image
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Repeat
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material.icons.rounded.SubdirectoryArrowRight
import androidx.compose.material.icons.rounded.Verified
import androidx.compose.material.icons.rounded.Videocam
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.fortune.vibramusic.data.social.MusicTrackAttachment
import com.fortune.vibramusic.data.social.PostComment
import com.fortune.vibramusic.data.social.PostMediaItem
import com.fortune.vibramusic.data.social.PostMediaType
import com.fortune.vibramusic.data.social.SocialPost
import com.fortune.vibramusic.data.social.SocialProfile
import com.fortune.vibramusic.data.social.formatHandle
import com.fortune.vibramusic.data.social.formatRelativeTime
import com.fortune.vibramusic.data.social.isWithinEditWindow
import com.fortune.vibramusic.data.supabase.SupabaseService
import com.fortune.vibramusic.ui.components.MentionSuggestionPopup
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
fun PostThreadScreen(
    post: SocialPost,
    comments: List<PostComment>,
    currentProfile: SocialProfile?,
    onBack: () -> Unit,
    onLikePost: (SocialPost) -> Unit,
    onRepostPost: (SocialPost) -> Unit,
    onAddComment: (content: String, parentId: String?, imageUrl: String?, videoUrl: String?, gifUrl: String?) -> Unit,
    onToggleLikeComment: (PostComment) -> Unit,
    onEditPost: ((postId: String, newContent: String) -> Unit)? = null,
    onDeletePost: ((SocialPost) -> Unit)? = null,
    onEditComment: ((commentId: String, newContent: String) -> Unit)? = null,
    onDeleteComment: ((commentId: String, postId: String) -> Unit)? = null,
    onPlayTrack: ((MusicTrackAttachment) -> Unit)? = null,
    onOpenProfile: (SocialProfile) -> Unit,
    onMediaClick: ((List<PostMediaItem>, Int) -> Unit)? = null,
    onMentionClick: ((String) -> Unit)? = null,
    onVotePoll: ((Int) -> Unit)? = null,
    onQuoteClick: ((SocialPost) -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var replyText by remember { mutableStateOf("") }
    var replyingTo by remember { mutableStateOf<PostComment?>(null) }
    var selectedImageUri by remember { mutableStateOf<Uri?>(null) }
    var selectedVideoUri by remember { mutableStateOf<Uri?>(null) }
    var selectedGifUrl by remember { mutableStateOf<String?>(null) }
    var isUploadingMedia by remember { mutableStateOf(false) }
    var showGifPicker by remember { mutableStateOf(false) }

    val photoPickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickVisualMedia(),
    ) { uri ->
        if (uri != null) {
            selectedImageUri = uri
            selectedVideoUri = null
            selectedGifUrl = null
        }
    }

    val videoPickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickVisualMedia(),
    ) { uri ->
        if (uri != null) {
            selectedVideoUri = uri
            selectedImageUri = null
            selectedGifUrl = null
        }
    }

    // Mention suggestions state
    var mentionQuery by remember { mutableStateOf<String?>(null) }
    var mentionSuggestions by remember { mutableStateOf<List<SocialProfile>>(emptyList()) }

    // Dialogs
    var showEditPostDialog by remember { mutableStateOf(false) }
    var editPostContent by remember { mutableStateOf(post.content) }

    var editingComment by remember { mutableStateOf<PostComment?>(null) }
    var editCommentContent by remember { mutableStateOf("") }

    var postToDelete by remember { mutableStateOf<SocialPost?>(null) }
    var commentToDelete by remember { mutableStateOf<PostComment?>(null) }

    val currentUserId = currentProfile?.id ?: ""
    val isPostAuthor = post.authorId == currentUserId
    val canEditPost = isPostAuthor && isWithinEditWindow(post.createdAt, 10L)

    // Detect mention typing in reply field
    LaunchedEffect(replyText) {
        val lastWord = replyText.substringAfterLast(" ", missingDelimiterValue = replyText).substringAfterLast("\n")
        if (lastWord.startsWith("@")) {
            val q = lastWord.removePrefix("@")
            mentionQuery = q
            scope.launch {
                SupabaseService.searchUsersForMention(q).onSuccess {
                    mentionSuggestions = it
                }
            }
        } else {
            mentionQuery = null
            mentionSuggestions = emptyList()
        }
    }

    // Twitter(X)-style comment thread drill-down state
    var focusedCommentStack by remember { mutableStateOf<List<PostComment>>(emptyList()) }
    val focusedCommentRaw = focusedCommentStack.lastOrNull()
    val focusedComment = focusedCommentRaw?.let { fc -> comments.find { it.id == fc.id } ?: fc }

    val ancestorChain = remember(focusedComment, comments) {
        if (focusedComment == null) emptyList<PostComment>()
        else {
            val list = mutableListOf<PostComment>()
            var currParentId = focusedComment.parentId
            while (currParentId != null) {
                val p = comments.find { it.id == currParentId }
                if (p != null) {
                    list.add(0, p)
                    currParentId = p.parentId
                } else {
                    break
                }
            }
            list
        }
    }

    BackHandler(enabled = replyingTo != null || focusedCommentStack.isNotEmpty()) {
        if (replyingTo != null) {
            replyingTo = null
        } else if (focusedCommentStack.isNotEmpty()) {
            focusedCommentStack = focusedCommentStack.dropLast(1)
        }
    }

    // Organize root comments and replies
    val rootComments = remember(comments) {
        comments.filter { it.parentId == null }
    }
    val repliesByParent = remember(comments) {
        comments.filter { it.parentId != null }.groupBy { it.parentId!! }
    }

    Surface(
        modifier = modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background),
        color = MaterialTheme.colorScheme.background,
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding(),
        ) {
            // Top Bar
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(
                    onClick = {
                        if (replyingTo != null) {
                            replyingTo = null
                        } else if (focusedCommentStack.isNotEmpty()) {
                            focusedCommentStack = focusedCommentStack.dropLast(1)
                        } else {
                            onBack()
                        }
                    },
                    modifier = Modifier
                        .size(38.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.surfaceVariant),
                ) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Rounded.ArrowBack,
                        contentDescription = "Back",
                        tint = MaterialTheme.colorScheme.onSurface,
                        modifier = Modifier.size(20.dp),
                    )
                }

                Spacer(Modifier.width(14.dp))

                Text(
                    text = if (focusedComment != null) "Thread" else "Post",
                    style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold),
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.weight(1f),
                )

                // More menu if post author and viewing root post
                if (focusedComment == null && isPostAuthor) {
                    var showPostMenu by remember { mutableStateOf(false) }
                    Box {
                        IconButton(onClick = { showPostMenu = true }) {
                            Icon(
                                imageVector = Icons.Rounded.MoreVert,
                                contentDescription = "More",
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        DropdownMenu(
                            expanded = showPostMenu,
                            onDismissRequest = { showPostMenu = false },
                            modifier = Modifier.background(MaterialTheme.colorScheme.surfaceVariant),
                        ) {
                            if (canEditPost) {
                                DropdownMenuItem(
                                    text = {
                                        Row(verticalAlignment = Alignment.CenterVertically) {
                                            Icon(
                                                imageVector = Icons.Rounded.Edit,
                                                contentDescription = null,
                                                tint = MaterialTheme.colorScheme.primary,
                                                modifier = Modifier.size(18.dp),
                                            )
                                            Spacer(Modifier.width(8.dp))
                                            Text("Edit Post", color = MaterialTheme.colorScheme.onSurface)
                                        }
                                    },
                                    onClick = {
                                        showPostMenu = false
                                        editPostContent = post.content
                                        showEditPostDialog = true
                                    },
                                )
                            }
                            DropdownMenuItem(
                                text = {
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Icon(
                                            imageVector = Icons.Rounded.DeleteOutline,
                                            contentDescription = null,
                                            tint = MaterialTheme.colorScheme.error,
                                            modifier = Modifier.size(18.dp),
                                        )
                                        Spacer(Modifier.width(8.dp))
                                        Text("Delete Post", color = MaterialTheme.colorScheme.error)
                                    }
                                },
                                onClick = {
                                    showPostMenu = false
                                    postToDelete = post
                                },
                            )
                        }
                    }
                }
            }

            HorizontalDivider(
                color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
                thickness = 0.5.dp,
            )

            // Thread Content
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth(),
            ) {
                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                ) {
                    if (focusedComment == null) {
                        // Hero Post
                        item(key = "hero_post") {
                            HeroPostItem(
                                post = post,
                                isAuthor = isPostAuthor,
                                onLikeClick = { onLikePost(post) },
                                onRepostClick = { onRepostPost(post) },
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
                                onOpenProfile = onOpenProfile,
                                onPlayTrack = onPlayTrack,
                                onMediaClick = onMediaClick,
                                onMentionClick = onMentionClick,
                                onVotePoll = onVotePoll,
                                onQuoteClick = onQuoteClick,
                            )
                        }

                        // Comments Section Header
                        item(key = "comments_header") {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = 16.dp, vertical = 10.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(
                                    text = "Replies (${comments.size})",
                                    style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Bold),
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }

                        // Empty Comments Message
                        if (rootComments.isEmpty()) {
                            item(key = "empty_comments") {
                                Box(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(vertical = 40.dp, horizontal = 24.dp),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    Text(
                                        text = "No replies yet. Be the first to share your thoughts!",
                                        style = MaterialTheme.typography.bodyMedium,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                                    )
                                }
                            }
                        }

                        // Root Comments with Threaded Replies
                        items(
                            items = rootComments,
                            key = { it.id },
                        ) { comment ->
                            val replies = repliesByParent[comment.id].orEmpty()
                            ThreadCommentItem(
                                comment = comment,
                                replies = replies,
                                currentUserId = currentUserId,
                                onReplyClick = { replyingTo = it },
                                onToggleLike = { onToggleLikeComment(it) },
                                onEditClick = {
                                    editingComment = it
                                    editCommentContent = it.content
                                },
                                onDeleteClick = { commentToDelete = it },
                                onOpenProfile = onOpenProfile,
                                onMentionClick = onMentionClick,
                                onMediaClick = onMediaClick,
                                onCommentClick = { focusedCommentStack = focusedCommentStack + it },
                                onReplyClickRow = { focusedCommentStack = focusedCommentStack + it },
                            )
                        }
                    } else {
                        // Ancestor Chain
                        item(key = "ancestor_post") {
                            ThreadAncestorPostItem(
                                post = post,
                                onOpenProfile = onOpenProfile,
                                onClick = { focusedCommentStack = emptyList() },
                            )
                        }

                        items(
                            items = ancestorChain,
                            key = { "ancestor_${it.id}" },
                        ) { ancestor ->
                            ThreadAncestorCommentItem(
                                comment = ancestor,
                                onOpenProfile = onOpenProfile,
                                onClick = {
                                    val idx = focusedCommentStack.indexOfFirst { fc -> fc.id == ancestor.id }
                                    if (idx >= 0) {
                                        focusedCommentStack = focusedCommentStack.take(idx + 1)
                                    }
                                },
                            )
                        }

                        val directReplies = repliesByParent[focusedComment.id].orEmpty()

                        // Hero Focused Comment
                        item(key = "hero_comment_${focusedComment.id}") {
                            val isAuthor = focusedComment.authorId == currentUserId
                            val canEdit = isAuthor && isWithinEditWindow(focusedComment.createdAt, 10L)
                            HeroCommentItem(
                                comment = focusedComment,
                                isAuthor = isAuthor,
                                canEdit = canEdit,
                                onReplyClick = { replyingTo = focusedComment },
                                onLikeClick = { onToggleLikeComment(focusedComment) },
                                onShareClick = {
                                    val sendIntent = Intent(Intent.ACTION_SEND).apply {
                                        putExtra(
                                            Intent.EXTRA_TEXT,
                                            "Reply by @${focusedComment.authorHandle} on Vibra:\n\n${focusedComment.content}",
                                        )
                                        type = "text/plain"
                                    }
                                    context.startActivity(Intent.createChooser(sendIntent, "Share Reply"))
                                },
                                onOpenProfile = onOpenProfile,
                                onMediaClick = onMediaClick,
                                onMentionClick = onMentionClick,
                                onEditClick = {
                                    editingComment = focusedComment
                                    editCommentContent = focusedComment.content
                                },
                                onDeleteClick = { commentToDelete = focusedComment },
                                repliesCount = directReplies.size,
                            )
                        }

                        // Direct Replies Header
                        item(key = "focused_replies_header") {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = 16.dp, vertical = 10.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(
                                    text = "Replies (${directReplies.size})",
                                    style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Bold),
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }

                        if (directReplies.isEmpty()) {
                            item(key = "empty_focused_replies") {
                                Box(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(vertical = 36.dp, horizontal = 24.dp),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    Text(
                                        text = "No replies yet. Be the first to reply!",
                                        style = MaterialTheme.typography.bodyMedium,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                                    )
                                }
                            }
                        } else {
                            items(
                                items = directReplies,
                                key = { it.id },
                            ) { reply ->
                                val childReplies = repliesByParent[reply.id].orEmpty()
                                ThreadCommentItem(
                                    comment = reply,
                                    replies = childReplies,
                                    currentUserId = currentUserId,
                                    onReplyClick = { replyingTo = it },
                                    onToggleLike = { onToggleLikeComment(it) },
                                    onEditClick = {
                                        editingComment = it
                                        editCommentContent = it.content
                                    },
                                    onDeleteClick = { commentToDelete = it },
                                    onOpenProfile = onOpenProfile,
                                    onMentionClick = onMentionClick,
                                    onMediaClick = onMediaClick,
                                    onCommentClick = { focusedCommentStack = focusedCommentStack + it },
                                    onReplyClickRow = { focusedCommentStack = focusedCommentStack + it },
                                )
                            }
                        }
                    }

                    // Bottom padding to clear docked reply bar
                    item(key = "bottom_space") {
                        Spacer(Modifier.height(100.dp))
                    }
                }

                // Autocomplete Mention Suggestions Popup
                androidx.compose.animation.AnimatedVisibility(
                    visible = mentionSuggestions.isNotEmpty(),
                    enter = fadeIn(),
                    exit = fadeOut(),
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .padding(bottom = 74.dp, start = 16.dp, end = 16.dp),
                ) {
                    MentionSuggestionPopup(
                        suggestions = mentionSuggestions,
                        onSelectUser = { user ->
                            val lastIdx = replyText.lastIndexOf("@")
                            if (lastIdx >= 0) {
                                val cleanHandle = user.handle.removePrefix("@")
                                replyText = replyText.substring(0, lastIdx) + "@$cleanHandle "
                            }
                            mentionSuggestions = emptyList()
                            mentionQuery = null
                        },
                    )
                }
            }

            // Docked Quick-Reply Bar
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.95f))
                    .navigationBarsPadding()
                    .imePadding(),
            ) {
                // Replying To indicator
                val effectiveReplyingTo = replyingTo ?: focusedComment
                effectiveReplyingTo?.let { target ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(MaterialTheme.colorScheme.surface)
                            .padding(horizontal = 16.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        Text(
                            text = "Replying to @${target.authorHandle.removePrefix("@")}",
                            style = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.Medium),
                            color = MaterialTheme.colorScheme.primary,
                        )
                        if (replyingTo != null && focusedComment != null) {
                            Icon(
                                imageVector = Icons.Rounded.Close,
                                contentDescription = "Clear specific reply target",
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier
                                    .size(16.dp)
                                    .clickable { replyingTo = null },
                            )
                        } else if (replyingTo != null) {
                            Icon(
                                imageVector = Icons.Rounded.Close,
                                contentDescription = "Cancel reply",
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier
                                    .size(16.dp)
                                    .clickable { replyingTo = null },
                            )
                        }
                    }
                }

                // Attachment Preview Strip
                if (selectedImageUri != null || selectedVideoUri != null || selectedGifUrl != null) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Box(
                            modifier = Modifier
                                .size(56.dp)
                                .clip(RoundedCornerShape(8.dp))
                                .background(MaterialTheme.colorScheme.surface),
                            contentAlignment = Alignment.Center,
                        ) {
                            if (selectedImageUri != null) {
                                AsyncImage(
                                    model = selectedImageUri,
                                    contentDescription = "Selected image",
                                    contentScale = ContentScale.Crop,
                                    modifier = Modifier.fillMaxSize(),
                                )
                            } else if (selectedVideoUri != null) {
                                Icon(
                                    imageVector = Icons.Rounded.Videocam,
                                    contentDescription = "Selected video",
                                    tint = MaterialTheme.colorScheme.primary,
                                    modifier = Modifier.size(28.dp),
                                )
                            } else if (selectedGifUrl != null) {
                                AsyncImage(
                                    model = selectedGifUrl,
                                    contentDescription = "Selected GIF",
                                    contentScale = ContentScale.Crop,
                                    modifier = Modifier.fillMaxSize(),
                                )
                            }

                            // Close / Remove icon overlay
                            Box(
                                modifier = Modifier
                                    .align(Alignment.TopEnd)
                                    .padding(2.dp)
                                    .size(18.dp)
                                    .clip(CircleShape)
                                    .background(Color.Black.copy(alpha = 0.7f))
                                    .clickable {
                                        selectedImageUri = null
                                        selectedVideoUri = null
                                        selectedGifUrl = null
                                    },
                                contentAlignment = Alignment.Center,
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.Close,
                                    contentDescription = "Remove attachment",
                                    tint = Color.White,
                                    modifier = Modifier.size(12.dp),
                                )
                            }
                        }
                    }
                }

                // Input Controls Row
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    // User Avatar
                    Box(
                        modifier = Modifier
                            .size(34.dp)
                            .clip(CircleShape)
                            .background(MaterialTheme.colorScheme.surface),
                        contentAlignment = Alignment.Center,
                    ) {
                        if (!currentProfile?.avatarUrl.isNullOrBlank()) {
                            AsyncImage(
                                model = currentProfile!!.avatarUrl,
                                contentDescription = null,
                                contentScale = ContentScale.Crop,
                                modifier = Modifier.fillMaxSize(),
                            )
                        } else {
                            Icon(
                                imageVector = Icons.Rounded.Person,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(18.dp),
                            )
                        }
                    }

                    Spacer(Modifier.width(8.dp))

                    // Text Input
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(20.dp))
                            .background(MaterialTheme.colorScheme.surface)
                            .padding(horizontal = 14.dp, vertical = 10.dp),
                    ) {
                        if (replyText.isBlank()) {
                            Text(
                                text = "Post your reply...",
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                            )
                        }
                        BasicTextField(
                            value = replyText,
                            onValueChange = { replyText = it },
                            textStyle = TextStyle(
                                color = MaterialTheme.colorScheme.onSurface,
                                fontSize = 14.sp,
                            ),
                            cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }

                    Spacer(Modifier.width(6.dp))

                    // Photo Picker Button
                    IconButton(
                        onClick = {
                            photoPickerLauncher.launch(
                                PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
                            )
                        },
                        modifier = Modifier.size(32.dp),
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.Image,
                            contentDescription = "Attach photo",
                            tint = if (selectedImageUri != null) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(20.dp),
                        )
                    }

                    // Video Picker Button
                    IconButton(
                        onClick = {
                            videoPickerLauncher.launch(
                                PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.VideoOnly)
                            )
                        },
                        modifier = Modifier.size(32.dp),
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.Videocam,
                            contentDescription = "Attach video",
                            tint = if (selectedVideoUri != null) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(20.dp),
                        )
                    }

                    // GIF Picker Button
                    Box(
                        modifier = Modifier
                            .size(30.dp)
                            .clip(CircleShape)
                            .background(
                                if (selectedGifUrl != null) MaterialTheme.colorScheme.primary
                                else MaterialTheme.colorScheme.surface
                            )
                            .clickable { showGifPicker = true },
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            text = "GIF",
                            style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.Bold),
                            color = if (selectedGifUrl != null) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurfaceVariant,
                            fontSize = 11.sp,
                        )
                    }

                    Spacer(Modifier.width(6.dp))

                    // Send Button
                    val canSend = (replyText.isNotBlank() || selectedImageUri != null || selectedVideoUri != null || selectedGifUrl != null) && !isUploadingMedia
                    IconButton(
                        onClick = {
                            if (!canSend) return@IconButton
                            val trimmed = replyText.trim()
                            val imageUri = selectedImageUri
                            val videoUri = selectedVideoUri
                            val gif = selectedGifUrl
                            val parent = replyingTo?.id ?: focusedComment?.id

                            replyText = ""
                            selectedImageUri = null
                            selectedVideoUri = null
                            selectedGifUrl = null
                            replyingTo = null

                            if (imageUri != null || videoUri != null) {
                                isUploadingMedia = true
                                scope.launch {
                                    var uploadedImg: String? = null
                                    var uploadedVid: String? = null
                                    if (imageUri != null) {
                                        runCatching {
                                            val bytes = withContext(Dispatchers.IO) {
                                                context.contentResolver.openInputStream(imageUri)?.use { it.readBytes() }
                                            }
                                            if (bytes != null) {
                                                uploadedImg = SupabaseService.uploadMedia(bytes, "image/jpeg").getOrNull()
                                            }
                                        }
                                    }
                                    if (videoUri != null) {
                                        runCatching {
                                            val bytes = withContext(Dispatchers.IO) {
                                                context.contentResolver.openInputStream(videoUri)?.use { it.readBytes() }
                                            }
                                            if (bytes != null) {
                                                uploadedVid = SupabaseService.uploadMedia(bytes, "video/mp4").getOrNull()
                                            }
                                        }
                                    }
                                    isUploadingMedia = false
                                    onAddComment(trimmed, parent, uploadedImg, uploadedVid, gif)
                                }
                            } else {
                                onAddComment(trimmed, parent, null, null, gif)
                            }
                        },
                        enabled = canSend,
                        modifier = Modifier
                            .size(38.dp)
                            .clip(CircleShape)
                            .background(
                                if (canSend) {
                                    MaterialTheme.colorScheme.primary
                                } else {
                                    MaterialTheme.colorScheme.surface
                                },
                            ),
                    ) {
                        if (isUploadingMedia) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(16.dp),
                                strokeWidth = 2.dp,
                                color = MaterialTheme.colorScheme.onPrimary,
                            )
                        } else {
                            Icon(
                                imageVector = Icons.AutoMirrored.Rounded.Send,
                                contentDescription = "Send",
                                tint = if (canSend) {
                                    MaterialTheme.colorScheme.onPrimary
                                } else {
                                    MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f)
                                },
                                modifier = Modifier.size(18.dp),
                            )
                        }
                    }
                }
            }
        }
    }

    // Edit Post Dialog
    if (showEditPostDialog) {
        AlertDialog(
            onDismissRequest = { showEditPostDialog = false },
            title = {
                Text(
                    text = "Edit Post",
                    style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                )
            },
            text = {
                OutlinedTextField(
                    value = editPostContent,
                    onValueChange = { editPostContent = it },
                    label = { Text("Content") },
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(12.dp),
                )
            },
            confirmButton = {
                Button(
                    onClick = {
                        val trimmed = editPostContent.trim()
                        if (trimmed.isNotBlank()) {
                            onEditPost?.invoke(post.id, trimmed)
                            showEditPostDialog = false
                        }
                    },
                ) {
                    Text("Save")
                }
            },
            dismissButton = {
                TextButton(onClick = { showEditPostDialog = false }) {
                    Text("Cancel")
                }
            },
        )
    }

    // Edit Comment Dialog
    editingComment?.let { targetComment ->
        AlertDialog(
            onDismissRequest = { editingComment = null },
            title = {
                Text(
                    text = "Edit Reply",
                    style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                )
            },
            text = {
                OutlinedTextField(
                    value = editCommentContent,
                    onValueChange = { editCommentContent = it },
                    label = { Text("Reply") },
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(12.dp),
                )
            },
            confirmButton = {
                Button(
                    onClick = {
                        val trimmed = editCommentContent.trim()
                        if (trimmed.isNotBlank()) {
                            onEditComment?.invoke(targetComment.id, trimmed)
                            editingComment = null
                        }
                    },
                ) {
                    Text("Save")
                }
            },
            dismissButton = {
                TextButton(onClick = { editingComment = null }) {
                    Text("Cancel")
                }
            },
        )
    }

    // Delete Post Confirmation Dialog
    postToDelete?.let { target ->
        AlertDialog(
            onDismissRequest = { postToDelete = null },
            title = { Text("Delete Post") },
            text = { Text("Are you sure you want to permanently delete this post?") },
            confirmButton = {
                Button(
                    onClick = {
                        onDeletePost?.invoke(target)
                        postToDelete = null
                        onBack()
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error),
                ) {
                    Text("Delete")
                }
            },
            dismissButton = {
                TextButton(onClick = { postToDelete = null }) {
                    Text("Cancel")
                }
            },
        )
    }

    // Delete Comment Confirmation Dialog
    commentToDelete?.let { target ->
        AlertDialog(
            onDismissRequest = { commentToDelete = null },
            title = { Text("Delete Reply") },
            text = { Text("Are you sure you want to permanently delete this reply?") },
            confirmButton = {
                Button(
                    onClick = {
                        onDeleteComment?.invoke(target.id, post.id)
                        commentToDelete = null
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error),
                ) {
                    Text("Delete")
                }
            },
            dismissButton = {
                TextButton(onClick = { commentToDelete = null }) {
                    Text("Cancel")
                }
            },
        )
    }

    if (showGifPicker) {
        GifPickerSheet(
            onDismiss = { showGifPicker = false },
            onSelectGif = { gif ->
                selectedGifUrl = gif
                selectedImageUri = null
                selectedVideoUri = null
                showGifPicker = false
            },
        )
    }
}

@Composable
private fun HeroPostItem(
    post: SocialPost,
    isAuthor: Boolean,
    onLikeClick: () -> Unit,
    onRepostClick: () -> Unit,
    onShareClick: () -> Unit,
    onOpenProfile: (SocialProfile) -> Unit,
    onPlayTrack: ((MusicTrackAttachment) -> Unit)?,
    onMediaClick: ((List<PostMediaItem>, Int) -> Unit)?,
    onMentionClick: ((String) -> Unit)? = null,
    onVotePoll: ((Int) -> Unit)? = null,
    onQuoteClick: ((SocialPost) -> Unit)? = null,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        // Author Header
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(48.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.surfaceVariant)
                    .clickable {
                        post.author?.let { onOpenProfile(it) }
                    },
                contentAlignment = Alignment.Center,
            ) {
                if (!post.authorAvatar.isNullOrBlank()) {
                    AsyncImage(
                        model = post.authorAvatar,
                        contentDescription = post.authorName,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxSize(),
                    )
                } else {
                    Icon(
                        imageVector = Icons.Rounded.Person,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(26.dp),
                    )
                }
            }

            Spacer(Modifier.width(12.dp))

            Column(
                modifier = Modifier
                    .weight(1f)
                    .clickable { post.author?.let { onOpenProfile(it) } },
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = post.authorName,
                        style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (post.authorVerified) {
                        Spacer(Modifier.width(4.dp))
                        Icon(
                            imageVector = Icons.Rounded.Verified,
                            contentDescription = "Verified",
                            tint = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.size(16.dp),
                        )
                    }
                }
                Text(
                    text = formatHandle(post.authorHandle),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }

        Spacer(Modifier.height(14.dp))

        val isDeleted = post.isDeleted || post.content.trim() == "[This post was deleted by the author]"

        if (isDeleted) {
            Text(
                text = "[This post was deleted by the author]",
                style = MaterialTheme.typography.bodyLarge.copy(fontStyle = FontStyle.Italic),
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
            )
            Spacer(Modifier.height(12.dp))
        } else {
            // Post Text with clickable @mentions highlighted
            if (post.content.isNotBlank()) {
                ClickableMentionText(
                    content = post.content,
                    fontSize = 17.sp,
                    color = MaterialTheme.colorScheme.onSurface,
                    onMentionClick = onMentionClick,
                )
                Spacer(Modifier.height(12.dp))
            }

            // Attached Media Carousel (Swipeable HorizontalPager with indicator dots)
            val images = post.effectiveImages
            if (images.isNotEmpty()) {
                PostMediaCarousel(
                    images = images,
                    onImageClick = { clickedUrl ->
                        val idx = post.allMediaItems.indexOfFirst { it.url == clickedUrl }.coerceAtLeast(0)
                        if (onMediaClick != null) {
                            onMediaClick(post.allMediaItems, idx)
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(12.dp))
            }

            // Attached GIF
            post.gifUrl?.takeIf { it.isNotBlank() && it != "null" }?.let { gifUrl ->
                if (!images.contains(gifUrl)) {
                    val gifIdx = post.allMediaItems.indexOfFirst { it.url == gifUrl }.coerceAtLeast(0)
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(16.dp))
                            .background(MaterialTheme.colorScheme.surface)
                            .clickable {
                                if (onMediaClick != null) {
                                    onMediaClick(post.allMediaItems, gifIdx)
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
            post.videoUrl?.takeIf { it.isNotBlank() && it != "null" }?.let { videoUrl ->
                val videoIdx = post.allMediaItems.indexOfFirst { it.url == videoUrl }.coerceAtLeast(0)
                PostVideoPlayer(
                    videoUrl = videoUrl,
                    onFullScreenClick = {
                        if (onMediaClick != null) {
                            onMediaClick(post.allMediaItems, videoIdx)
                        }
                    },
                    modifier = Modifier
                        .fillMaxWidth()
                        .aspectRatio(16f / 9f),
                )
                Spacer(Modifier.height(12.dp))
            }

            // Attached Voice Note Player
            post.audioUrl?.takeIf { it.isNotBlank() && it != "null" }?.let { audioUrl ->
                VoiceNotePlayerWidget(
                    audioUrl = audioUrl,
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(12.dp))
            }

            // Attached Track Card
            post.musicTrack?.let { track ->
                PlayableTrackCard(
                    track = track,
                    onPlay = { onPlayTrack?.invoke(track) },
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(12.dp))
            }

            // Interactive Poll Card
            post.poll?.let { poll ->
                PollCard(
                    poll = poll,
                    onVote = { onVotePoll?.invoke(it) },
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(12.dp))
            }

            // Embedded Quoted Post
            if (post.quoteOf != null || post.quoteOfId != null) {
                QuotedPostCard(
                    quotedPost = post.quoteOf,
                    quotedId = post.quoteOfId,
                    onPlayTrack = { track -> onPlayTrack?.invoke(track) },
                    onClick = {
                        post.quoteOf?.let { onQuoteClick?.invoke(it) }
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(12.dp))
            }
        }

        // Timestamp & (edited) indicator
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = formatRelativeTime(post.createdAt),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (post.isEdited) {
                Text(
                    text = " (edited)",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                )
            }
        }

        Spacer(Modifier.height(10.dp))

        HorizontalDivider(
            color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
            thickness = 0.5.dp,
        )

        // Metrics Line
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                text = "${post.likesCount} Likes",
                style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold),
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = "${post.repostsCount} Reposts",
                style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold),
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = "${post.commentsCount} Replies",
                style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold),
                color = MaterialTheme.colorScheme.onSurface,
            )
        }

        HorizontalDivider(
            color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
            thickness = 0.5.dp,
        )

        // Action Buttons
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 6.dp),
            horizontalArrangement = Arrangement.SpaceAround,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // Like
            IconButton(onClick = onLikeClick) {
                Icon(
                    imageVector = if (post.isLikedByMe) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder,
                    contentDescription = "Like",
                    tint = if (post.isLikedByMe) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            // Repost
            IconButton(onClick = onRepostClick) {
                Icon(
                    imageVector = Icons.Rounded.Repeat,
                    contentDescription = "Repost",
                    tint = if (post.isRepostedByMe) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            // Share
            IconButton(onClick = onShareClick) {
                Icon(
                    imageVector = Icons.Rounded.Share,
                    contentDescription = "Share",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        HorizontalDivider(
            color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
            thickness = 0.5.dp,
        )
    }
}

@Composable
private fun ThreadAncestorPostItem(
    post: SocialPost,
    onOpenProfile: (SocialProfile) -> Unit,
    onClick: () -> Unit,
) {
    val isDeleted = post.isDeleted || post.content.trim() == "[This post was deleted by the author]" || post.content.trim() == "This post was deleted by the author."
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.width(40.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(38.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.surfaceVariant)
                    .clickable { post.author?.let { onOpenProfile(it) } },
                contentAlignment = Alignment.Center,
            ) {
                if (!post.authorAvatar.isNullOrBlank() && !isDeleted) {
                    AsyncImage(
                        model = post.authorAvatar,
                        contentDescription = post.authorName,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxSize(),
                    )
                } else {
                    Icon(
                        imageVector = Icons.Rounded.Person,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(20.dp),
                    )
                }
            }

            Spacer(Modifier.height(4.dp))
            Box(
                modifier = Modifier
                    .width(2.dp)
                    .weight(1f, fill = false)
                    .heightIn(min = 24.dp)
                    .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.7f)),
            )
        }

        Spacer(Modifier.width(12.dp))

        Column(modifier = Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = if (isDeleted) "User" else post.authorName,
                    style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Bold),
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Spacer(Modifier.width(6.dp))
                if (!isDeleted) {
                    Text(
                        text = formatHandle(post.authorHandle),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.width(6.dp))
                }
                Text(
                    text = "· ${formatRelativeTime(post.createdAt)}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            Spacer(Modifier.height(4.dp))

            if (isDeleted) {
                Text(
                    text = "[This post was deleted by the author]",
                    style = MaterialTheme.typography.bodyMedium.copy(fontStyle = FontStyle.Italic),
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                )
            } else {
                if (post.content.isNotBlank()) {
                    Text(
                        text = post.content,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                    )
                }

                val images = post.imageUrls
                if (images.size == 1) {
                    Spacer(Modifier.height(6.dp))
                    AsyncImage(
                        model = images.first(),
                        contentDescription = "Post image",
                        contentScale = ContentScale.Crop,
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(max = 180.dp)
                            .clip(RoundedCornerShape(12.dp)),
                    )
                } else if (images.size > 1) {
                    Spacer(Modifier.height(6.dp))
                    PostMediaCarousel(
                        images = images,
                        onImageClick = {},
                        modifier = Modifier.fillMaxWidth(),
                    )
                } else if (!post.gifUrl.isNullOrBlank()) {
                    Spacer(Modifier.height(6.dp))
                    AsyncImage(
                        model = post.gifUrl,
                        contentDescription = "GIF",
                        contentScale = ContentScale.Crop,
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(max = 160.dp)
                            .clip(RoundedCornerShape(12.dp)),
                    )
                }

                if (!post.videoUrl.isNullOrBlank()) {
                    Spacer(Modifier.height(6.dp))
                    PostVideoPlayer(
                        videoUrl = post.videoUrl,
                        onFullScreenClick = {},
                        modifier = Modifier
                            .fillMaxWidth()
                            .aspectRatio(16f / 9f)
                            .clip(RoundedCornerShape(12.dp)),
                    )
                }

                post.poll?.let { poll ->
                    Spacer(Modifier.height(6.dp))
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(10.dp))
                            .background(MaterialTheme.colorScheme.surfaceVariant)
                            .padding(8.dp),
                    ) {
                        Text(
                            text = "Poll: ${poll.question}",
                            style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                            color = MaterialTheme.colorScheme.onSurface,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Spacer(Modifier.height(2.dp))
                        poll.options.take(2).forEach { opt ->
                            Text(
                                text = "• ${opt.text}",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                }

                post.musicTrack?.let { track ->
                    Spacer(Modifier.height(6.dp))
                    PlayableTrackCard(
                        track = track,
                        onPlay = {},
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        }
    }
}

@Composable
private fun ThreadAncestorCommentItem(
    comment: PostComment,
    onOpenProfile: (SocialProfile) -> Unit,
    onClick: () -> Unit,
) {
    val isDeleted = comment.isDeleted || comment.content.trim() == "[This comment was deleted by the user]"
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.width(40.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(38.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.surfaceVariant)
                    .clickable { comment.author?.let { onOpenProfile(it) } },
                contentAlignment = Alignment.Center,
            ) {
                if (!comment.authorAvatar.isNullOrBlank() && !isDeleted) {
                    AsyncImage(
                        model = comment.authorAvatar,
                        contentDescription = comment.authorName,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxSize(),
                    )
                } else {
                    Icon(
                        imageVector = Icons.Rounded.Person,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(20.dp),
                    )
                }
            }

            Spacer(Modifier.height(4.dp))
            Box(
                modifier = Modifier
                    .width(2.dp)
                    .weight(1f, fill = false)
                    .heightIn(min = 24.dp)
                    .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.7f)),
            )
        }

        Spacer(Modifier.width(12.dp))

        Column(modifier = Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = if (isDeleted) "User" else comment.authorName,
                    style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Bold),
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Spacer(Modifier.width(6.dp))
                if (!isDeleted) {
                    Text(
                        text = formatHandle(comment.authorHandle),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.width(6.dp))
                }
                Text(
                    text = "· ${formatRelativeTime(comment.createdAt)}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            Spacer(Modifier.height(4.dp))

            if (isDeleted) {
                Text(
                    text = "[This comment was deleted by the user]",
                    style = MaterialTheme.typography.bodyMedium.copy(fontStyle = FontStyle.Italic),
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                )
            } else {
                if (comment.content.isNotBlank()) {
                    Text(
                        text = comment.content,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                    )
                }

                val commentImg = comment.imageUrl
                if (!commentImg.isNullOrBlank()) {
                    Spacer(Modifier.height(6.dp))
                    AsyncImage(
                        model = commentImg,
                        contentDescription = "Comment image",
                        contentScale = ContentScale.Crop,
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(max = 160.dp)
                            .clip(RoundedCornerShape(12.dp)),
                    )
                } else if (!comment.gifUrl.isNullOrBlank()) {
                    Spacer(Modifier.height(6.dp))
                    AsyncImage(
                        model = comment.gifUrl,
                        contentDescription = "GIF",
                        contentScale = ContentScale.Crop,
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(max = 140.dp)
                            .clip(RoundedCornerShape(12.dp)),
                    )
                }

                if (!comment.videoUrl.isNullOrBlank()) {
                    Spacer(Modifier.height(6.dp))
                    PostVideoPlayer(
                        videoUrl = comment.videoUrl,
                        onFullScreenClick = {},
                        modifier = Modifier
                            .fillMaxWidth()
                            .aspectRatio(16f / 9f)
                            .clip(RoundedCornerShape(12.dp)),
                    )
                }
            }
        }
    }
}

@Composable
private fun HeroCommentItem(
    comment: PostComment,
    isAuthor: Boolean,
    canEdit: Boolean,
    onReplyClick: () -> Unit,
    onLikeClick: () -> Unit,
    onShareClick: () -> Unit,
    onOpenProfile: (SocialProfile) -> Unit,
    onMediaClick: ((List<PostMediaItem>, Int) -> Unit)? = null,
    onMentionClick: ((String) -> Unit)? = null,
    onEditClick: (() -> Unit)? = null,
    onDeleteClick: (() -> Unit)? = null,
    repliesCount: Int = 0,
) {
    val isDeleted = comment.isDeleted || comment.content.trim() == "[This comment was deleted by the user]"
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(48.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.surfaceVariant)
                    .clickable {
                        if (!isDeleted) comment.author?.let { onOpenProfile(it) }
                    },
                contentAlignment = Alignment.Center,
            ) {
                if (!comment.authorAvatar.isNullOrBlank() && !isDeleted) {
                    AsyncImage(
                        model = comment.authorAvatar,
                        contentDescription = comment.authorName,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxSize(),
                    )
                } else {
                    Icon(
                        imageVector = Icons.Rounded.Person,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(26.dp),
                    )
                }
            }

            Spacer(Modifier.width(12.dp))

            Column(
                modifier = Modifier
                    .weight(1f)
                    .clickable { if (!isDeleted) comment.author?.let { onOpenProfile(it) } },
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = if (isDeleted) "User" else comment.authorName,
                        style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    if (!isDeleted && comment.author?.verifiedBadge == true) {
                        Spacer(Modifier.width(4.dp))
                        Icon(
                            imageVector = Icons.Rounded.Verified,
                            contentDescription = "Verified",
                            tint = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.size(16.dp),
                        )
                    }
                }
                if (!isDeleted) {
                    Text(
                        text = formatHandle(comment.authorHandle),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            if (isAuthor && !isDeleted) {
                var showMenu by remember { mutableStateOf(false) }
                Box {
                    IconButton(onClick = { showMenu = true }) {
                        Icon(
                            imageVector = Icons.Rounded.MoreVert,
                            contentDescription = "More",
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    DropdownMenu(
                        expanded = showMenu,
                        onDismissRequest = { showMenu = false },
                        modifier = Modifier.background(MaterialTheme.colorScheme.surfaceVariant),
                    ) {
                        if (canEdit) {
                            DropdownMenuItem(
                                text = {
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Icon(
                                            imageVector = Icons.Rounded.Edit,
                                            contentDescription = null,
                                            tint = MaterialTheme.colorScheme.primary,
                                            modifier = Modifier.size(18.dp),
                                        )
                                        Spacer(Modifier.width(8.dp))
                                        Text("Edit Reply", color = MaterialTheme.colorScheme.onSurface)
                                    }
                                },
                                onClick = {
                                    showMenu = false
                                    onEditClick?.invoke()
                                },
                            )
                        }
                        DropdownMenuItem(
                            text = {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Icon(
                                        imageVector = Icons.Rounded.DeleteOutline,
                                        contentDescription = null,
                                        tint = MaterialTheme.colorScheme.error,
                                        modifier = Modifier.size(18.dp),
                                    )
                                    Spacer(Modifier.width(8.dp))
                                    Text("Delete Reply", color = MaterialTheme.colorScheme.error)
                                }
                            },
                            onClick = {
                                showMenu = false
                                onDeleteClick?.invoke()
                            },
                        )
                    }
                }
            }
        }

        Spacer(Modifier.height(14.dp))

        if (isDeleted) {
            Text(
                text = "[This comment was deleted by the user]",
                style = MaterialTheme.typography.bodyLarge.copy(fontStyle = FontStyle.Italic),
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
            )
        } else {
            ClickableMentionText(
                content = comment.content,
                fontSize = 18.sp,
                lineHeight = 26.sp,
                color = MaterialTheme.colorScheme.onSurface,
                onMentionClick = onMentionClick,
            )

            if (!comment.imageUrl.isNullOrBlank()) {
                Spacer(Modifier.height(12.dp))
                AsyncImage(
                    model = comment.imageUrl,
                    contentDescription = "Comment image",
                    contentScale = ContentScale.Crop,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(240.dp)
                        .clip(RoundedCornerShape(14.dp))
                        .clickable {
                            onMediaClick?.invoke(
                                listOf(PostMediaItem(url = comment.imageUrl, type = PostMediaType.IMAGE)),
                                0,
                            )
                        },
                )
            }

            if (!comment.videoUrl.isNullOrBlank()) {
                Spacer(Modifier.height(12.dp))
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(240.dp)
                        .clip(RoundedCornerShape(14.dp)),
                ) {
                    PostVideoPlayer(
                        videoUrl = comment.videoUrl,
                        onFullScreenClick = {
                            onMediaClick?.invoke(
                                listOf(PostMediaItem(url = comment.videoUrl, type = PostMediaType.VIDEO)),
                                0,
                            )
                        },
                    )
                }
            }

            if (!comment.gifUrl.isNullOrBlank()) {
                Spacer(Modifier.height(12.dp))
                AsyncImage(
                    model = comment.gifUrl,
                    contentDescription = "GIF",
                    contentScale = ContentScale.Crop,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(200.dp)
                        .clip(RoundedCornerShape(14.dp))
                        .clickable {
                            onMediaClick?.invoke(
                                listOf(PostMediaItem(url = comment.gifUrl, type = PostMediaType.IMAGE)),
                                0,
                            )
                        },
                )
            }
        }

        Spacer(Modifier.height(12.dp))

        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = formatRelativeTime(comment.createdAt),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (comment.isEdited && !isDeleted) {
                Text(
                    text = " (edited)",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                )
            }
        }

        Spacer(Modifier.height(10.dp))

        HorizontalDivider(
            color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
            thickness = 0.5.dp,
        )

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(
                text = "${comment.likesCount} Likes",
                style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold),
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = "$repliesCount Replies",
                style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold),
                color = MaterialTheme.colorScheme.onSurface,
            )
        }

        HorizontalDivider(
            color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
            thickness = 0.5.dp,
        )

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 6.dp),
            horizontalArrangement = Arrangement.SpaceAround,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onReplyClick) {
                Icon(
                    imageVector = Icons.Rounded.SubdirectoryArrowRight,
                    contentDescription = "Reply",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            IconButton(onClick = onLikeClick) {
                Icon(
                    imageVector = if (comment.isLikedByMe) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder,
                    contentDescription = "Like",
                    tint = if (comment.isLikedByMe) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            IconButton(onClick = onShareClick) {
                Icon(
                    imageVector = Icons.Rounded.Share,
                    contentDescription = "Share",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        HorizontalDivider(
            color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
            thickness = 0.5.dp,
        )
    }
}

@Composable
private fun ThreadCommentItem(
    comment: PostComment,
    replies: List<PostComment>,
    currentUserId: String,
    onReplyClick: (PostComment) -> Unit,
    onToggleLike: (PostComment) -> Unit,
    onEditClick: (PostComment) -> Unit,
    onDeleteClick: (PostComment) -> Unit,
    onOpenProfile: (SocialProfile) -> Unit,
    onMentionClick: ((String) -> Unit)? = null,
    onMediaClick: ((List<PostMediaItem>, Int) -> Unit)? = null,
    onCommentClick: ((PostComment) -> Unit)? = null,
    onReplyClickRow: ((PostComment) -> Unit)? = null,
) {
    val isCommentAuthor = comment.authorId == currentUserId
    val canEdit = isCommentAuthor && isWithinEditWindow(comment.createdAt, 10L)
    val isDeleted = comment.isDeleted || comment.content.trim() == "[This comment was deleted by the user]"

    Column(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable { onCommentClick?.invoke(comment) }
                .padding(horizontal = 16.dp, vertical = 8.dp),
        ) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier.width(40.dp),
            ) {
                Box(
                    modifier = Modifier
                        .size(38.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.surfaceVariant)
                        .clickable {
                            if (!isDeleted) comment.author?.let { onOpenProfile(it) }
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    if (!comment.authorAvatar.isNullOrBlank() && !isDeleted) {
                        AsyncImage(
                            model = comment.authorAvatar,
                            contentDescription = comment.authorName,
                            contentScale = ContentScale.Crop,
                            modifier = Modifier.fillMaxSize(),
                        )
                    } else {
                        Icon(
                            imageVector = Icons.Rounded.Person,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(20.dp),
                        )
                    }
                }

                if (replies.isNotEmpty()) {
                    Spacer(Modifier.height(4.dp))
                    Box(
                        modifier = Modifier
                            .width(2.dp)
                            .weight(1f)
                            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.7f)),
                    )
                }
            }

            Spacer(Modifier.width(12.dp))

            Column(modifier = Modifier.weight(1f)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = if (isDeleted) "User" else comment.authorName,
                        style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Bold),
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Spacer(Modifier.width(6.dp))
                    if (!isDeleted) {
                        Text(
                            text = formatHandle(comment.authorHandle),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Spacer(Modifier.width(6.dp))
                    }
                    Text(
                        text = "· ${formatRelativeTime(comment.createdAt)}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    if (comment.isEdited && !isDeleted) {
                        Text(
                            text = " (edited)",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                        )
                    }

                    Spacer(Modifier.weight(1f))

                    if (isCommentAuthor && !isDeleted) {
                        var showMenu by remember { mutableStateOf(false) }
                        Box {
                            Icon(
                                imageVector = Icons.Rounded.MoreVert,
                                contentDescription = "Actions",
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier
                                    .size(18.dp)
                                    .clickable { showMenu = true },
                            )
                            DropdownMenu(
                                expanded = showMenu,
                                onDismissRequest = { showMenu = false },
                                modifier = Modifier.background(MaterialTheme.colorScheme.surfaceVariant),
                            ) {
                                if (canEdit) {
                                    DropdownMenuItem(
                                        text = { Text("Edit", color = MaterialTheme.colorScheme.onSurface) },
                                        onClick = {
                                            showMenu = false
                                            onEditClick(comment)
                                        },
                                    )
                                }
                                DropdownMenuItem(
                                    text = { Text("Delete", color = MaterialTheme.colorScheme.error) },
                                    onClick = {
                                        showMenu = false
                                        onDeleteClick(comment)
                                    },
                                )
                            }
                        }
                    }
                }

                Spacer(Modifier.height(4.dp))

                if (isDeleted) {
                    Text(
                        text = "[This comment was deleted by the user]",
                        style = MaterialTheme.typography.bodyMedium.copy(fontStyle = FontStyle.Italic),
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                    )
                } else {
                    ClickableMentionText(
                        content = comment.content,
                        fontSize = 15.sp,
                        color = MaterialTheme.colorScheme.onSurface,
                        onMentionClick = onMentionClick,
                    )

                    if (!comment.imageUrl.isNullOrBlank()) {
                        Spacer(Modifier.height(6.dp))
                        AsyncImage(
                            model = comment.imageUrl,
                            contentDescription = "Comment image",
                            contentScale = ContentScale.Crop,
                            modifier = Modifier
                                .fillMaxWidth(0.85f)
                                .height(180.dp)
                                .clip(RoundedCornerShape(12.dp))
                                .clickable {
                                    onMediaClick?.invoke(
                                        listOf(PostMediaItem(url = comment.imageUrl, type = PostMediaType.IMAGE)),
                                        0,
                                    )
                                },
                        )
                    }

                    if (!comment.videoUrl.isNullOrBlank()) {
                        Spacer(Modifier.height(6.dp))
                        Box(
                            modifier = Modifier
                                .fillMaxWidth(0.85f)
                                .height(180.dp)
                                .clip(RoundedCornerShape(12.dp)),
                        ) {
                            PostVideoPlayer(
                                videoUrl = comment.videoUrl,
                                onFullScreenClick = {
                                    onMediaClick?.invoke(
                                        listOf(PostMediaItem(url = comment.videoUrl, type = PostMediaType.VIDEO)),
                                        0,
                                    )
                                },
                            )
                        }
                    }

                    if (!comment.gifUrl.isNullOrBlank()) {
                        Spacer(Modifier.height(6.dp))
                        AsyncImage(
                            model = comment.gifUrl,
                            contentDescription = "GIF",
                            contentScale = ContentScale.Crop,
                            modifier = Modifier
                                .fillMaxWidth(0.7f)
                                .height(140.dp)
                                .clip(RoundedCornerShape(12.dp))
                                .clickable {
                                    onMediaClick?.invoke(
                                        listOf(PostMediaItem(url = comment.gifUrl, type = PostMediaType.IMAGE)),
                                        0,
                                    )
                                },
                        )
                    }
                }

                Spacer(Modifier.height(8.dp))

                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.clickable { onReplyClick(comment) },
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.SubdirectoryArrowRight,
                            contentDescription = "Reply",
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(16.dp),
                        )
                        Spacer(Modifier.width(4.dp))
                        Text(
                            text = "Reply",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }

                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.clickable { onToggleLike(comment) },
                    ) {
                        Icon(
                            imageVector = if (comment.isLikedByMe) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder,
                            contentDescription = "Like",
                            tint = if (comment.isLikedByMe) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(16.dp),
                        )
                        if (comment.likesCount > 0) {
                            Spacer(Modifier.width(4.dp))
                            Text(
                                text = "${comment.likesCount}",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
            }
        }

        // Nested Replies
        replies.forEach { reply ->
            val isReplyDeleted = reply.isDeleted || reply.content.trim() == "[This comment was deleted by the user]"
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { onReplyClickRow?.invoke(reply) }
                    .padding(start = 52.dp, end = 16.dp, top = 4.dp, bottom = 6.dp),
            ) {
                Box(
                    modifier = Modifier
                        .size(28.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.surfaceVariant)
                        .clickable {
                            if (!isReplyDeleted) reply.author?.let { onOpenProfile(it) }
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    if (!reply.authorAvatar.isNullOrBlank() && !isReplyDeleted) {
                        AsyncImage(
                            model = reply.authorAvatar,
                            contentDescription = reply.authorName,
                            contentScale = ContentScale.Crop,
                            modifier = Modifier.fillMaxSize(),
                        )
                    } else {
                        Icon(
                            imageVector = Icons.Rounded.Person,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(16.dp),
                        )
                    }
                }

                Spacer(Modifier.width(10.dp))

                Column(modifier = Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = if (isReplyDeleted) "User" else reply.authorName,
                            style = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.Bold),
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                        Spacer(Modifier.width(4.dp))
                        if (!isReplyDeleted) {
                            Text(
                                text = formatHandle(reply.authorHandle),
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            Spacer(Modifier.width(4.dp))
                        }
                        Text(
                            text = "· ${formatRelativeTime(reply.createdAt)}",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        if (reply.isEdited && !isReplyDeleted) {
                            Text(
                                text = " (edited)",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                            )
                        }
                    }

                    Spacer(Modifier.height(2.dp))

                    if (isReplyDeleted) {
                        Text(
                            text = "[This comment was deleted by the user]",
                            style = MaterialTheme.typography.bodySmall.copy(fontStyle = FontStyle.Italic),
                            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                        )
                    } else {
                        ClickableMentionText(
                            content = reply.content,
                            fontSize = 14.sp,
                            color = MaterialTheme.colorScheme.onSurface,
                            onMentionClick = onMentionClick,
                        )

                        if (!reply.imageUrl.isNullOrBlank()) {
                            Spacer(Modifier.height(4.dp))
                            AsyncImage(
                                model = reply.imageUrl,
                                contentDescription = "Reply image",
                                contentScale = ContentScale.Crop,
                                modifier = Modifier
                                    .fillMaxWidth(0.85f)
                                    .height(140.dp)
                                    .clip(RoundedCornerShape(10.dp))
                                    .clickable {
                                        onMediaClick?.invoke(
                                            listOf(PostMediaItem(url = reply.imageUrl, type = PostMediaType.IMAGE)),
                                            0,
                                        )
                                    },
                            )
                        }

                        if (!reply.videoUrl.isNullOrBlank()) {
                            Spacer(Modifier.height(4.dp))
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth(0.85f)
                                    .height(140.dp)
                                    .clip(RoundedCornerShape(10.dp)),
                            ) {
                                PostVideoPlayer(
                                    videoUrl = reply.videoUrl,
                                    onFullScreenClick = {
                                        onMediaClick?.invoke(
                                            listOf(PostMediaItem(url = reply.videoUrl, type = PostMediaType.VIDEO)),
                                            0,
                                        )
                                    },
                                )
                            }
                        }

                        if (!reply.gifUrl.isNullOrBlank()) {
                            Spacer(Modifier.height(4.dp))
                            AsyncImage(
                                model = reply.gifUrl,
                                contentDescription = "GIF",
                                contentScale = ContentScale.Crop,
                                modifier = Modifier
                                    .fillMaxWidth(0.7f)
                                    .height(120.dp)
                                    .clip(RoundedCornerShape(10.dp))
                                    .clickable {
                                        onMediaClick?.invoke(
                                            listOf(PostMediaItem(url = reply.gifUrl, type = PostMediaType.IMAGE)),
                                            0,
                                        )
                                    },
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun ClickableMentionText(
    content: String,
    fontSize: androidx.compose.ui.unit.TextUnit = 15.sp,
    color: Color = MaterialTheme.colorScheme.onSurface,
    lineHeight: androidx.compose.ui.unit.TextUnit = 22.sp,
    onMentionClick: ((String) -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val primaryColor = MaterialTheme.colorScheme.primary
    val annotated = remember(content, primaryColor, color) {
        buildAnnotatedString {
            val mentionRegex = Regex("""(@[a-zA-Z0-9_.-]+)""")
            var lastIndex = 0
            mentionRegex.findAll(content).forEach { matchResult ->
                val start = matchResult.range.first
                val end = matchResult.range.last + 1
                if (start > lastIndex) {
                    withStyle(SpanStyle(color = color)) {
                        append(content.substring(lastIndex, start))
                    }
                }
                val handle = matchResult.value.removePrefix("@")
                pushStringAnnotation(tag = "MENTION", annotation = handle)
                withStyle(SpanStyle(color = primaryColor, fontWeight = FontWeight.SemiBold)) {
                    append(matchResult.value)
                }
                pop()
                lastIndex = end
            }
            if (lastIndex < content.length) {
                withStyle(SpanStyle(color = color)) {
                    append(content.substring(lastIndex))
                }
            }
        }
    }

    if (onMentionClick != null) {
        androidx.compose.foundation.text.ClickableText(
            text = annotated,
            style = MaterialTheme.typography.bodyMedium.copy(fontSize = fontSize, lineHeight = lineHeight),
            onClick = { offset ->
                annotated.getStringAnnotations(tag = "MENTION", start = offset, end = offset)
                    .firstOrNull()?.let { annotation ->
                        onMentionClick(annotation.item)
                    }
            },
            modifier = modifier,
        )
    } else {
        Text(
            text = annotated,
            style = MaterialTheme.typography.bodyMedium.copy(fontSize = fontSize, lineHeight = lineHeight),
            modifier = modifier,
        )
    }
}
