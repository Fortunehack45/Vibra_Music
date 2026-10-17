package com.fortune.vibramusic.ui.social

import androidx.compose.animation.AnimatedVisibility
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Send
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.SubdirectoryArrowRight
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.fortune.vibramusic.data.social.PostComment
import com.fortune.vibramusic.data.social.SocialPost

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PostCommentsSheet(
    post: SocialPost,
    comments: List<PostComment>,
    onDismiss: () -> Unit,
    onAddComment: (content: String, parentId: String?, gifUrl: String?) -> Unit,
    onToggleLikeComment: (PostComment) -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false)
    var commentText by remember { mutableStateOf("") }
    var replyingTo by remember { mutableStateOf<PostComment?>(null) }
    var selectedGifUrl by remember { mutableStateOf<String?>(null) }
    var showGifPicker by remember { mutableStateOf(false) }

    // Organize comments into root comments and replies grouped by parentId
    val repliesByParent = remember(comments) {
        comments.filter { it.parentId != null }.groupBy { it.parentId!! }
    }
    val rootComments = remember(comments) {
        comments.filter { it.parentId == null }
    }

    val surfaceColor = MaterialTheme.colorScheme.surface
    val onSurfaceColor = MaterialTheme.colorScheme.onSurface
    val onSurfaceVariantColor = MaterialTheme.colorScheme.onSurfaceVariant
    val primaryColor = MaterialTheme.colorScheme.primary
    val dividerColor = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.35f)
    val inputBgColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f)
    val inputBorderColor = Color.White.copy(alpha = 0.12f)
    val replyBannerBg = primaryColor.copy(alpha = 0.12f)

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = surfaceColor,
        shape = RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp),
        dragHandle = null,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .fillMaxHeight(0.85f),
        ) {
            // Header Bar
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 20.dp, vertical = 14.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column {
                    Text(
                        text = "Comments (${comments.size})",
                        style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                        color = onSurfaceColor,
                    )
                    Text(
                        text = "on ${post.authorHandle}'s post",
                        style = MaterialTheme.typography.labelSmall,
                        color = onSurfaceVariantColor,
                    )
                }

                IconButton(onClick = onDismiss) {
                    Icon(
                        imageVector = Icons.Rounded.Close,
                        contentDescription = "Close",
                        tint = onSurfaceVariantColor,
                    )
                }
            }

            HorizontalDivider(color = dividerColor, thickness = 1.dp)

            // Threaded Comments List
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth(),
            ) {
                if (comments.isEmpty()) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(top = 60.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text(
                                text = "No comments yet",
                                style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold),
                                color = onSurfaceColor,
                            )
                            Spacer(Modifier.height(4.dp))
                            Text(
                                text = "Be the first to start the conversation",
                                style = MaterialTheme.typography.bodySmall,
                                color = onSurfaceVariantColor,
                            )
                        }
                    }
                } else {
                    LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp, vertical = 12.dp),
                        verticalArrangement = Arrangement.spacedBy(16.dp),
                    ) {
                        items(rootComments, key = { it.id }) { rootComment ->
                            val childReplies = repliesByParent[rootComment.id].orEmpty()
                            ThreadedCommentItem(
                                comment = rootComment,
                                replies = childReplies,
                                allRepliesByParent = repliesByParent,
                                onReply = { replyingTo = it },
                                onToggleLike = onToggleLikeComment,
                            )
                        }
                    }
                }
            }

            // Reply Preview Banner
            AnimatedVisibility(visible = replyingTo != null) {
                replyingTo?.let { replyTarget ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(replyBannerBg)
                            .padding(horizontal = 18.dp, vertical = 9.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(
                                imageVector = Icons.Rounded.SubdirectoryArrowRight,
                                contentDescription = null,
                                tint = primaryColor,
                                modifier = Modifier.size(16.dp),
                            )
                            Spacer(Modifier.width(8.dp))
                            Text(
                                text = "Replying to ${replyTarget.authorHandle}",
                                style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                                color = primaryColor,
                            )
                        }

                        IconButton(
                            onClick = { replyingTo = null },
                            modifier = Modifier.size(24.dp),
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.Close,
                                contentDescription = "Cancel Reply",
                                tint = onSurfaceVariantColor,
                                modifier = Modifier.size(16.dp),
                            )
                        }
                    }
                }
            }

            // Attached GIF Preview Banner
            AnimatedVisibility(visible = selectedGifUrl != null) {
                selectedGifUrl?.let { gif ->
                    Box(
                        modifier = Modifier
                            .padding(horizontal = 16.dp, vertical = 6.dp)
                            .size(width = 110.dp, height = 80.dp)
                            .clip(RoundedCornerShape(12.dp)),
                    ) {
                        AsyncImage(
                            model = gif,
                            contentDescription = "Selected GIF",
                            contentScale = ContentScale.Crop,
                            modifier = Modifier.fillMaxSize(),
                        )
                        Box(
                            modifier = Modifier
                                .align(Alignment.TopEnd)
                                .padding(4.dp)
                                .size(20.dp)
                                .clip(CircleShape)
                                .background(Color.Black.copy(alpha = 0.65f))
                                .clickable { selectedGifUrl = null },
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.Close,
                                contentDescription = "Remove GIF",
                                tint = Color.White,
                                modifier = Modifier.size(12.dp),
                            )
                        }
                    }
                }
            }

            HorizontalDivider(color = dividerColor, thickness = 1.dp)

            // Input Field Bar with Keyboard Padding
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(surfaceColor)
                    .navigationBarsPadding()
                    .imePadding()
                    .padding(horizontal = 16.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(22.dp))
                        .background(inputBgColor)
                        .padding(horizontal = 16.dp, vertical = 11.dp),
                ) {
                    BasicTextField(
                        value = commentText,
                        onValueChange = { commentText = it },
                        textStyle = TextStyle(
                            color = onSurfaceColor,
                            fontSize = 14.sp,
                        ),
                        cursorBrush = SolidColor(primaryColor),
                        modifier = Modifier.fillMaxWidth(),
                        maxLines = 4,
                        decorationBox = { innerTextField ->
                            if (commentText.isEmpty() && selectedGifUrl == null) {
                                Text(
                                    text = if (replyingTo != null) "Reply to ${replyingTo?.authorHandle}..." else "Add a comment...",
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = onSurfaceVariantColor.copy(alpha = 0.65f),
                                )
                            }
                            innerTextField()
                        },
                    )
                }

                Spacer(Modifier.width(8.dp))

                // GIF Picker Button
                Box(
                    modifier = Modifier
                        .size(38.dp)
                        .clip(CircleShape)
                        .background(
                            if (selectedGifUrl != null) primaryColor.copy(alpha = 0.25f)
                            else inputBgColor
                        )
                        .clickable { showGifPicker = true },
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = "GIF",
                        style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.Bold),
                        color = if (selectedGifUrl != null) primaryColor else onSurfaceVariantColor,
                        fontSize = 11.sp,
                    )
                }

                Spacer(Modifier.width(8.dp))

                // Send Button
                val canSend = commentText.isNotBlank() || selectedGifUrl != null
                IconButton(
                    onClick = {
                        val trimmed = commentText.trim()
                        if (trimmed.isNotBlank() || selectedGifUrl != null) {
                            onAddComment(trimmed, replyingTo?.id, selectedGifUrl)
                            commentText = ""
                            selectedGifUrl = null
                            replyingTo = null
                        }
                    },
                    enabled = canSend,
                    modifier = Modifier
                        .size(40.dp)
                        .clip(CircleShape)
                        .background(
                            if (canSend) primaryColor
                            else primaryColor.copy(alpha = 0.25f),
                        ),
                ) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Rounded.Send,
                        contentDescription = "Send",
                        tint = if (canSend) MaterialTheme.colorScheme.onPrimary else onSurfaceVariantColor.copy(alpha = 0.5f),
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
        }
    }

    if (showGifPicker) {
        GifPickerSheet(
            onDismiss = { showGifPicker = false },
            onSelectGif = { gif ->
                selectedGifUrl = gif
                showGifPicker = false
            },
        )
    }
}

/**
 * Thread item containing a parent comment and its nested replies with connector lines.
 */
@Composable
private fun ThreadedCommentItem(
    comment: PostComment,
    replies: List<PostComment>,
    allRepliesByParent: Map<String, List<PostComment>>,
    onReply: (PostComment) -> Unit,
    onToggleLike: (PostComment) -> Unit,
    modifier: Modifier = Modifier,
) {
    val threadLineColor = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f)

    Column(modifier = modifier.fillMaxWidth()) {
        // Parent Comment Row
        SingleCommentRow(
            comment = comment,
            onReply = { onReply(comment) },
            onToggleLike = { onToggleLike(comment) },
        )

        // Indented Nested Replies
        if (replies.isNotEmpty()) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = 24.dp, top = 8.dp),
            ) {
                replies.forEach { reply ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(IntrinsicSize.Min),
                    ) {
                        // Vertical connector line
                        Box(
                            modifier = Modifier
                                .width(2.dp)
                                .fillMaxHeight()
                                .background(threadLineColor),
                        )

                        Spacer(Modifier.width(14.dp))

                        Column(
                            modifier = Modifier
                                .weight(1f)
                                .padding(vertical = 4.dp),
                        ) {
                            SingleCommentRow(
                                comment = reply,
                                isReply = true,
                                onReply = { onReply(reply) },
                                onToggleLike = { onToggleLike(reply) },
                            )

                            // Handle deeper nesting (replies to replies)
                            val subReplies = allRepliesByParent[reply.id].orEmpty()
                            if (subReplies.isNotEmpty()) {
                                Column(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(start = 18.dp, top = 6.dp),
                                ) {
                                    subReplies.forEach { subReply ->
                                        SingleCommentRow(
                                            comment = subReply,
                                            isReply = true,
                                            onReply = { onReply(subReply) },
                                            onToggleLike = { onToggleLike(subReply) },
                                        )
                                        Spacer(Modifier.height(6.dp))
                                    }
                                }
                            }
                        }
                    }
                    Spacer(Modifier.height(8.dp))
                }
            }
        }
    }
}

/**
 * Individual comment or reply bubble with adaptive styling, GIF rendering, and like/reply actions.
 */
@Composable
private fun SingleCommentRow(
    comment: PostComment,
    onReply: () -> Unit,
    onToggleLike: () -> Unit,
    isReply: Boolean = false,
    modifier: Modifier = Modifier,
) {
    val onSurfaceColor = MaterialTheme.colorScheme.onSurface
    val onSurfaceVariantColor = MaterialTheme.colorScheme.onSurfaceVariant
    val primaryColor = MaterialTheme.colorScheme.primary
    val avatarBg = MaterialTheme.colorScheme.surfaceVariant

    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.Top,
    ) {
        // Avatar
        Box(
            modifier = Modifier
                .size(if (isReply) 28.dp else 36.dp)
                .clip(CircleShape)
                .background(avatarBg),
            contentAlignment = Alignment.Center,
        ) {
            if (comment.authorAvatar != null) {
                AsyncImage(
                    model = comment.authorAvatar,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
            } else {
                Icon(
                    imageVector = Icons.Rounded.Person,
                    contentDescription = null,
                    tint = onSurfaceVariantColor,
                    modifier = Modifier.size(if (isReply) 16.dp else 20.dp),
                )
            }
        }

        Spacer(Modifier.width(10.dp))

        // Comment Body
        Column(Modifier.weight(1f)) {
            // Author info
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text(
                    text = comment.authorName,
                    style = (if (isReply) MaterialTheme.typography.bodySmall else MaterialTheme.typography.labelMedium)
                        .copy(fontWeight = FontWeight.Bold),
                    color = onSurfaceColor,
                )
                Text(
                    text = comment.authorHandle,
                    style = MaterialTheme.typography.labelSmall,
                    color = onSurfaceVariantColor,
                )
            }

            Spacer(Modifier.height(3.dp))

            // Text
            if (comment.content.isNotBlank()) {
                Text(
                    text = comment.content,
                    style = MaterialTheme.typography.bodyMedium,
                    color = onSurfaceColor.copy(alpha = 0.92f),
                    lineHeight = 20.sp,
                )
            }

            // GIF attachment if present
            if (!comment.gifUrl.isNullOrBlank()) {
                Spacer(Modifier.height(6.dp))
                AsyncImage(
                    model = comment.gifUrl,
                    contentDescription = "Comment GIF",
                    contentScale = ContentScale.Crop,
                    modifier = Modifier
                        .fillMaxWidth(0.85f)
                        .height(160.dp)
                        .clip(RoundedCornerShape(12.dp)),
                )
            }

            Spacer(Modifier.height(6.dp))

            // Action row: Reply + Like button
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                // Reply Button
                Text(
                    text = "Reply",
                    style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.SemiBold),
                    color = primaryColor,
                    modifier = Modifier
                        .clip(RoundedCornerShape(4.dp))
                        .clickable(onClick = onReply)
                        .padding(vertical = 2.dp, horizontal = 2.dp),
                )

                // Like Button
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .clip(RoundedCornerShape(4.dp))
                        .clickable(onClick = onToggleLike)
                        .padding(vertical = 2.dp, horizontal = 2.dp),
                ) {
                    Icon(
                        imageVector = if (comment.isLikedByMe) Icons.Rounded.Favorite else Icons.Rounded.FavoriteBorder,
                        contentDescription = "Like Comment",
                        tint = if (comment.isLikedByMe) Color(0xFFE53935) else onSurfaceVariantColor,
                        modifier = Modifier.size(14.dp),
                    )
                    if (comment.likesCount > 0) {
                        Spacer(Modifier.width(4.dp))
                        Text(
                            text = comment.likesCount.toString(),
                            style = MaterialTheme.typography.labelSmall,
                            color = if (comment.isLikedByMe) Color(0xFFE53935) else onSurfaceVariantColor,
                        )
                    }
                }
            }
        }
    }
}
