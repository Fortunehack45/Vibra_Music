package com.fortune.vibramusic.ui.social

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
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
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material3.ExperimentalMaterial3Api
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
    onAddComment: (content: String, parentId: String?) -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false)
    var commentText by remember { mutableStateOf("") }
    var replyingTo by remember { mutableStateOf<PostComment?>(null) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = MaterialTheme.colorScheme.surface.copy(alpha = 0.95f),
        shape = RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp),
        dragHandle = null,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .fillMaxHeight(0.75f)
                .navigationBarsPadding(),
        ) {
            // Header
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 20.dp, vertical = 14.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "Comments (${comments.size})",
                    style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                    color = MaterialTheme.colorScheme.onSurface,
                )

                IconButton(onClick = onDismiss) {
                    Icon(
                        imageVector = Icons.Rounded.Close,
                        contentDescription = "Close",
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            // Comments List
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth(),
            ) {
                if (comments.isEmpty()) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(top = 40.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            text = "No comments yet. Start the conversation!",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                        )
                    }
                } else {
                    LazyColumn(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 20.dp),
                        verticalArrangement = Arrangement.spacedBy(14.dp),
                    ) {
                        items(comments, key = { it.id }) { item ->
                            CommentRow(
                                comment = item,
                                onReply = { replyingTo = item },
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
                            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f))
                            .padding(horizontal = 20.dp, vertical = 8.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            text = "Replying to @${replyTarget.authorHandle}",
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.primary,
                        )
                        IconButton(
                            onClick = { replyingTo = null },
                            modifier = Modifier.size(24.dp),
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.Close,
                                contentDescription = "Cancel Reply",
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(16.dp),
                            )
                        }
                    }
                }
            }

            // Comment Input Field (Liquid Glass)
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(24.dp))
                        .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f))
                        .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(24.dp))
                        .padding(horizontal = 16.dp, vertical = 10.dp),
                ) {
                    if (commentText.isEmpty()) {
                        Text(
                            text = if (replyingTo != null) "Write a reply..." else "Add a comment...",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                        )
                    }
                    BasicTextField(
                        value = commentText,
                        onValueChange = { commentText = it },
                        textStyle = TextStyle(
                            color = MaterialTheme.colorScheme.onSurface,
                            fontSize = 14.sp,
                        ),
                        cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }

                Spacer(Modifier.width(8.dp))

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
                            else MaterialTheme.colorScheme.primary.copy(alpha = 0.3f),
                        ),
                ) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Rounded.Send,
                        contentDescription = "Send",
                        tint = MaterialTheme.colorScheme.onPrimary,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun CommentRow(
    comment: PostComment,
    onReply: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.Top,
    ) {
        Box(
            modifier = Modifier
                .size(34.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.surfaceVariant),
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
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(20.dp),
                )
            }
        }

        Spacer(Modifier.width(10.dp))

        Column(Modifier.weight(1f)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text(
                    text = comment.authorName,
                    style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Text(
                    text = "@${comment.authorHandle}",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                )
            }

            Spacer(Modifier.height(3.dp))

            Text(
                text = comment.content,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface,
            )

            Spacer(Modifier.height(4.dp))

            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .clip(RoundedCornerShape(6.dp))
                    .clickable(onClick = onReply)
                    .padding(vertical = 2.dp, horizontal = 4.dp),
            ) {
                Text(
                    text = "Reply",
                    style = MaterialTheme.typography.labelSmall.copy(fontWeight = FontWeight.SemiBold),
                    color = MaterialTheme.colorScheme.primary,
                )
            }
        }
    }
}
