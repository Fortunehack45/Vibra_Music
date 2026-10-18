package com.fortune.vibramusic.ui.social

import android.content.Intent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
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
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.Repeat
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material.icons.rounded.SubdirectoryArrowRight
import androidx.compose.material.icons.rounded.Verified
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
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
import kotlinx.coroutines.launch

@Composable
fun PostThreadScreen(
    post: SocialPost,
    comments: List<PostComment>,
    currentProfile: SocialProfile?,
    onBack: () -> Unit,
    onLikePost: (SocialPost) -> Unit,
    onRepostPost: (SocialPost) -> Unit,
    onAddComment: (content: String, parentId: String?, gifUrl: String?) -> Unit,
    onToggleLikeComment: (PostComment) -> Unit,
    onEditPost: ((postId: String, newContent: String) -> Unit)? = null,
    onDeletePost: ((SocialPost) -> Unit)? = null,
    onEditComment: ((commentId: String, newContent: String) -> Unit)? = null,
    onDeleteComment: ((commentId: String, postId: String) -> Unit)? = null,
    onPlayTrack: ((MusicTrackAttachment) -> Unit)? = null,
    onOpenProfile: (SocialProfile) -> Unit,
    onMediaClick: ((List<PostMediaItem>, Int) -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var replyText by remember { mutableStateOf("") }
    var replyingTo by remember { mutableStateOf<PostComment?>(null) }
    var selectedGifUrl by remember { mutableStateOf<String?>(null) }
    var showGifPicker by remember { mutableStateOf(false) }

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
        val lastWord = replyText.substringAfterLast(" ", missingDelimiterValue = replyText)
        if (lastWord.startsWith("@") && lastWord.length > 1) {
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
                    onClick = onBack,
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
                    text = "Post",
                    style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.Bold),
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.weight(1f),
                )

                // More menu if post author
                if (isPostAuthor) {
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
                        )
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
                                replyText = replyText.substring(0, lastIdx) + "@${user.handle} "
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
                replyingTo?.let { target ->
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

                    Spacer(Modifier.width(10.dp))

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

                    Spacer(Modifier.width(8.dp))

                    // Send Button
                    IconButton(
                        onClick = {
                            val trimmed = replyText.trim()
                            if (trimmed.isNotBlank() || selectedGifUrl != null) {
                                onAddComment(trimmed, replyingTo?.id, selectedGifUrl)
                                replyText = ""
                                replyingTo = null
                                selectedGifUrl = null
                            }
                        },
                        enabled = replyText.isNotBlank() || selectedGifUrl != null,
                        modifier = Modifier
                            .size(38.dp)
                            .clip(CircleShape)
                            .background(
                                if (replyText.isNotBlank() || selectedGifUrl != null) {
                                    MaterialTheme.colorScheme.primary
                                } else {
                                    MaterialTheme.colorScheme.surface
                                },
                            ),
                    ) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Rounded.Send,
                            contentDescription = "Send",
                            tint = if (replyText.isNotBlank() || selectedGifUrl != null) {
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

        // Post Text with clickable @mentions highlighted
        if (post.content.isNotBlank()) {
            ClickableMentionText(
                content = post.content,
                fontSize = 17.sp,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Spacer(Modifier.height(12.dp))
        }

        // Media (Images, Video, GIF)
        val allImages = post.imageUrls.ifEmpty { listOfNotNull(post.imageUrl) }
        if (allImages.isNotEmpty()) {
            val mediaItems = allImages.map { PostMediaItem(url = it, type = PostMediaType.IMAGE) }
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(260.dp)
                    .clip(RoundedCornerShape(16.dp))
                    .clickable {
                        onMediaClick?.invoke(mediaItems, 0)
                    },
            ) {
                AsyncImage(
                    model = allImages.first(),
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
            }
            Spacer(Modifier.height(12.dp))
        }

        // Attached Music Track
        post.musicTrack?.let { track ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(14.dp))
                    .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f))
                    .clickable { onPlayTrack?.invoke(track) }
                    .padding(10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                AsyncImage(
                    model = track.thumbnailUrl ?: track.artworkUrl,
                    contentDescription = track.title,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier
                        .size(46.dp)
                        .clip(RoundedCornerShape(8.dp)),
                )
                Spacer(Modifier.width(12.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = track.title,
                        style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.SemiBold),
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
            }
            Spacer(Modifier.height(12.dp))
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
private fun ThreadCommentItem(
    comment: PostComment,
    replies: List<PostComment>,
    currentUserId: String,
    onReplyClick: (PostComment) -> Unit,
    onToggleLike: (PostComment) -> Unit,
    onEditClick: (PostComment) -> Unit,
    onDeleteClick: (PostComment) -> Unit,
    onOpenProfile: (SocialProfile) -> Unit,
) {
    val isCommentAuthor = comment.authorId == currentUserId
    val canEdit = isCommentAuthor && isWithinEditWindow(comment.createdAt, 10L)

    Column(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
        ) {
            // Left Column: Avatar + Connector line if replies exist
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
                    if (!comment.authorAvatar.isNullOrBlank()) {
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

            // Right Column: Details & Body
            Column(modifier = Modifier.weight(1f)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = comment.authorName,
                        style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Bold),
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(
                        text = formatHandle(comment.authorHandle),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(
                        text = "· ${formatRelativeTime(comment.createdAt)}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    if (comment.isEdited) {
                        Text(
                            text = " (edited)",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                        )
                    }

                    Spacer(Modifier.weight(1f))

                    // Menu for comment author
                    if (isCommentAuthor) {
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

                ClickableMentionText(
                    content = comment.content,
                    fontSize = 15.sp,
                    color = MaterialTheme.colorScheme.onSurface,
                )

                // GIF
                if (!comment.gifUrl.isNullOrBlank()) {
                    Spacer(Modifier.height(6.dp))
                    AsyncImage(
                        model = comment.gifUrl,
                        contentDescription = "GIF",
                        contentScale = ContentScale.Crop,
                        modifier = Modifier
                            .fillMaxWidth(0.7f)
                            .height(140.dp)
                            .clip(RoundedCornerShape(12.dp)),
                    )
                }

                Spacer(Modifier.height(8.dp))

                // Actions: Reply & Like
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
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = 52.dp, end = 16.dp, top = 4.dp, bottom = 6.dp),
            ) {
                Box(
                    modifier = Modifier
                        .size(28.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.surfaceVariant)
                        .clickable { reply.author?.let { onOpenProfile(it) } },
                    contentAlignment = Alignment.Center,
                ) {
                    if (!reply.authorAvatar.isNullOrBlank()) {
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
                            text = reply.authorName,
                            style = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.Bold),
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                        Spacer(Modifier.width(4.dp))
                        Text(
                            text = "· ${formatRelativeTime(reply.createdAt)}",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        if (reply.isEdited) {
                            Text(
                                text = " (edited)",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                            )
                        }
                    }

                    Spacer(Modifier.height(2.dp))

                    ClickableMentionText(
                        content = reply.content,
                        fontSize = 14.sp,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
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
    modifier: Modifier = Modifier,
) {
    val primaryColor = MaterialTheme.colorScheme.primary
    val annotated = remember(content, primaryColor, color) {
        buildAnnotatedString {
            val mentionRegex = Regex("""(@[a-zA-Z0-9_]+)""")
            var lastIndex = 0
            mentionRegex.findAll(content).forEach { matchResult ->
                val start = matchResult.range.first
                val end = matchResult.range.last + 1
                if (start > lastIndex) {
                    withStyle(SpanStyle(color = color)) {
                        append(content.substring(lastIndex, start))
                    }
                }
                withStyle(SpanStyle(color = primaryColor, fontWeight = FontWeight.SemiBold)) {
                    append(matchResult.value)
                }
                lastIndex = end
            }
            if (lastIndex < content.length) {
                withStyle(SpanStyle(color = color)) {
                    append(content.substring(lastIndex))
                }
            }
        }
    }

    Text(
        text = annotated,
        style = MaterialTheme.typography.bodyMedium.copy(fontSize = fontSize, lineHeight = lineHeight),
        modifier = modifier,
    )
}
