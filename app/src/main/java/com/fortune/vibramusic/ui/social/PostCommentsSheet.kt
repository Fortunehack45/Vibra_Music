package com.fortune.vibramusic.ui.social

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
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

// Solid opaque color definitions to satisfy the strict non-transparent requirement
private val SolidSheetBackground = Color(0xFF141416)
private val SolidInputBackground = Color(0xFF1E1E22)
private val SolidInputBorder = Color(0xFF2E2E36)
private val SolidReplyBannerBg = Color(0xFF1B1B20)
private val SolidAvatarBackground = Color(0xFF282830)
private val SolidDividerColor = Color(0xFF222228)
private val SolidThreadLineColor = Color(0xFF2F2F38)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PostCommentsSheet(
    post: SocialPost,
    comments: List<PostComment>,
    onDismiss: () -> Unit,
    onAddComment: (content: String, parentId: String?) -> Unit,
    onToggleLikeComment: (PostComment) -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false)
    var commentText by remember { mutableStateOf("") }
    var replyingTo by remember { mutableStateOf<PostComment?>(null) }

    // Organize comments into root comments and replies grouped by parentId
    val repliesByParent = remember(comments) {
        comments.filter { it.parentId != null }.groupBy { it.parentId!! }
    }
    val rootComments = remember(comments) {
        comments.filter { it.parentId == null }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = SolidSheetBackground,
        shape = RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp),
        dragHandle = null,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .fillMaxHeight(0.85f)
                .background(SolidSheetBackground)
                .navigationBarsPadding(),
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
                        color = Color.White,
                    )
                    Text(
                        text = "on @${post.authorHandle}'s post",
                        style = MaterialTheme.typography.labelSmall,
                        color = Color(0xFF9E9EA8),
                    )
                }

                IconButton(onClick = onDismiss) {
                    Icon(
                        imageVector = Icons.Rounded.Close,
                        contentDescription = "Close",
                        tint = Color(0xFFB0B0BC),
                    )
                }
            }

            HorizontalDivider(color = SolidDividerColor, thickness = 1.dp)

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
                                color = Color.White,
                            )
                            Spacer(Modifier.height(4.dp))
                            Text(
                                text = "Be the first to share your thoughts or start a thread!",
                                style = MaterialTheme.typography.bodySmall,
                                color = Color(0xFF8E8E98),
                            )
                        }
                    }
                } else {
                    LazyColumn(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp),
                        verticalArrangement = Arrangement.spacedBy(16.dp),
                    ) {
                        item { Spacer(Modifier.height(8.dp)) }

                        items(rootComments, key = { it.id }) { rootComment ->
                            CommentThreadItem(
                                comment = rootComment,
                                replies = repliesByParent[rootComment.id].orEmpty(),
                                allRepliesByParent = repliesByParent,
                                onReply = { replyingTo = it },
                                onToggleLike = onToggleLikeComment,
                            )
                        }

                        item { Spacer(Modifier.height(16.dp)) }
                    }
                }
            }

            // Reply Preview Banner
            AnimatedVisibility(visible = replyingTo != null) {
                replyingTo?.let { replyTarget ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(SolidReplyBannerBg)
                            .padding(horizontal = 18.dp, vertical = 9.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(
                                imageVector = Icons.Rounded.SubdirectoryArrowRight,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.size(16.dp),
                            )
                            Spacer(Modifier.width(8.dp))
                            Text(
                                text = "Replying to @${replyTarget.authorHandle}",
                                style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                                color = MaterialTheme.colorScheme.primary,
                            )
                        }

                        IconButton(
                            onClick = { replyingTo = null },
                            modifier = Modifier.size(24.dp),
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.Close,
                                contentDescription = "Cancel Reply",
                                tint = Color(0xFFAAAAAF),
                                modifier = Modifier.size(16.dp),
                            )
                        }
                    }
                }
            }

            HorizontalDivider(color = SolidDividerColor, thickness = 1.dp)

            // Solid Input Field
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(SolidSheetBackground)
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(22.dp))
                        .background(SolidInputBackground)
                        .border(1.dp, SolidInputBorder, RoundedCornerShape(22.dp))
                        .padding(horizontal = 16.dp, vertical = 11.dp),
                ) {
                    if (commentText.isEmpty()) {
                        Text(
                            text = if (replyingTo != null) "Reply to @${replyingTo?.authorHandle}..." else "Add a comment...",
                            style = MaterialTheme.typography.bodyMedium,
                            color = Color(0xFF7A7A85),
                        )
                    }
                    BasicTextField(
                        value = commentText,
                        onValueChange = { commentText = it },
                        textStyle = TextStyle(
                            color = Color.White,
                            fontSize = 14.sp,
                        ),
                        cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }

                Spacer(Modifier.width(10.dp))

                IconButton(
                    onClick = {
                        val trimmed = commentText.trim()
                        if (trimmed.isNotBlank()) {
                            onAddComment(trimmed, replyingTo?.id)
                            commentText = ""
                            replyingTo = null
                        }
                    },
                    enabled = commentText.isNotBlank(),
                    modifier = Modifier
                        .size(42.dp)
                        .clip(CircleShape)
                        .background(
                            if (commentText.isNotBlank()) MaterialTheme.colorScheme.primary
                            else MaterialTheme.colorScheme.primary.copy(alpha = 0.25f),
                        ),
                ) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Rounded.Send,
                        contentDescription = "Send",
                        tint = if (commentText.isNotBlank()) MaterialTheme.colorScheme.onPrimary else Color(0xFF6B6B75),
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
        }
    }
}

/**
 * Thread item containing a parent comment and its nested replies with connector lines.
 */
@Composable
private fun CommentThreadItem(
    comment: PostComment,
    replies: List<PostComment>,
    allRepliesByParent: Map<String, List<PostComment>>,
    onReply: (PostComment) -> Unit,
    onToggleLike: (PostComment) -> Unit,
    modifier: Modifier = Modifier,
) {
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
                                .background(SolidThreadLineColor),
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
 * Individual comment or reply bubble with solid high-contrast styling and like/reply actions.
 */
@Composable
private fun SingleCommentRow(
    comment: PostComment,
    onReply: () -> Unit,
    onToggleLike: () -> Unit,
    isReply: Boolean = false,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.Top,
    ) {
        // Avatar
        Box(
            modifier = Modifier
                .size(if (isReply) 28.dp else 36.dp)
                .clip(CircleShape)
                .background(SolidAvatarBackground)
                .border(1.dp, SolidInputBorder, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            if (comment.authorAvatar != null) {
                AsyncImage(
                    model = comment.authorAvatar,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxWidth(),
                )
            } else {
                Icon(
                    imageVector = Icons.Rounded.Person,
                    contentDescription = null,
                    tint = Color(0xFFA0A0AA),
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
                    color = Color.White,
                )
                Text(
                    text = "@${comment.authorHandle}",
                    style = MaterialTheme.typography.labelSmall,
                    color = Color(0xFF8E8E98),
                )
            }

            Spacer(Modifier.height(3.dp))

            // Text
            Text(
                text = comment.content,
                style = MaterialTheme.typography.bodyMedium,
                color = Color(0xFFEDEDF0),
                lineHeight = 20.sp,
            )

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
                    color = MaterialTheme.colorScheme.primary,
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
                        tint = if (comment.isLikedByMe) Color(0xFFE53935) else Color(0xFF8E8E98),
                        modifier = Modifier.size(14.dp),
                    )
                    if (comment.likesCount > 0) {
                        Spacer(Modifier.width(4.dp))
                        Text(
                            text = comment.likesCount.toString(),
                            style = MaterialTheme.typography.labelSmall,
                            color = if (comment.isLikedByMe) Color(0xFFE53935) else Color(0xFF8E8E98),
                        )
                    }
                }
            }
        }
    }
}
