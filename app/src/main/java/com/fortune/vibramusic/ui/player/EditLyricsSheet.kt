package com.fortune.vibramusic.ui.player

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ContentPaste
import androidx.compose.material.icons.rounded.FileOpen
import androidx.compose.material.icons.rounded.RestartAlt
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.fortune.vibramusic.R
import com.fortune.vibramusic.data.lyrics.LyricLine
import com.fortune.vibramusic.data.lyrics.toLrc
import com.fortune.vibramusic.ui.haptics.Haptic
import com.fortune.vibramusic.ui.haptics.rememberHaptics
import dev.chrisbanes.haze.HazeState

/**
 * Bottom drawer panel allowing users to edit existing lyrics text, paste from clipboard,
 * or import external .lrc / plain text files for the currently playing track.
 */
@Composable
internal fun EditLyricsSheet(
    hazeState: HazeState,
    initialLyrics: List<LyricLine>?,
    initialRawText: String?,
    isCustom: Boolean,
    onSave: (String) -> Unit,
    onReset: () -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val clipboardManager = LocalClipboardManager.current
    val haptics = rememberHaptics()

    val startingText = remember(initialLyrics, initialRawText) {
        initialRawText?.takeIf { it.isNotBlank() }
            ?: initialLyrics?.takeIf { it.isNotEmpty() }?.let { lines ->
                if (lines.any { it.timeMs > 0L }) lines.toLrc()
                else lines.joinToString("\n") { it.text }
            }
            ?: ""
    }

    var text by remember { mutableStateOf(startingText) }

    val filePicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.GetContent()
    ) { uri: Uri? ->
        if (uri != null) {
            runCatching {
                context.contentResolver.openInputStream(uri)?.use { stream ->
                    val content = stream.bufferedReader().readText()
                    if (content.isNotBlank()) {
                        text = content
                        haptics.play(Haptic.Select)
                    }
                }
            }
        }
    }

    PlayerDrawer(
        hazeState = hazeState,
        title = stringResource(R.string.edit_or_import_lyrics),
        onDismiss = onDismiss,
        modifier = modifier,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            // Quick action buttons: Import file, Paste, Reset
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                // Import file button
                EditActionChip(
                    icon = Icons.Rounded.FileOpen,
                    label = stringResource(R.string.import_lrc_file),
                    modifier = Modifier.weight(1f),
                    onClick = {
                        haptics.play(Haptic.Tap)
                        filePicker.launch("*/*")
                    },
                )

                // Paste button
                EditActionChip(
                    icon = Icons.Rounded.ContentPaste,
                    label = stringResource(R.string.paste_lyrics),
                    modifier = Modifier.weight(1f),
                    onClick = {
                        haptics.play(Haptic.Tap)
                        clipboardManager.getText()?.text?.let { clipboardText ->
                            if (clipboardText.isNotBlank()) {
                                text = clipboardText
                            }
                        }
                    },
                )

                // Reset button if custom
                if (isCustom) {
                    EditActionChip(
                        icon = Icons.Rounded.RestartAlt,
                        label = stringResource(R.string.reset_lyrics),
                        modifier = Modifier.weight(1f),
                        onClick = {
                            haptics.play(Haptic.Select)
                            onReset()
                            onDismiss()
                        },
                    )
                }
            }

            // Text input area
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                placeholder = {
                    Text(
                        text = stringResource(R.string.lyrics_editor_hint),
                        style = MaterialTheme.typography.bodyMedium,
                        color = Color.White.copy(alpha = 0.4f),
                    )
                },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(260.dp),
                shape = RoundedCornerShape(16.dp),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedTextColor = Color.White,
                    unfocusedTextColor = Color.White.copy(alpha = 0.9f),
                    focusedContainerColor = Color.White.copy(alpha = 0.08f),
                    unfocusedContainerColor = Color.White.copy(alpha = 0.05f),
                    focusedBorderColor = Color.White.copy(alpha = 0.25f),
                    unfocusedBorderColor = Color.White.copy(alpha = 0.12f),
                    cursorColor = Color.White,
                ),
                textStyle = MaterialTheme.typography.bodyMedium.copy(
                    fontSize = 14.sp,
                    lineHeight = 20.sp,
                ),
            )

            // Bottom Buttons
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TextButton(
                    onClick = onDismiss,
                    modifier = Modifier.weight(1f),
                ) {
                    Text(
                        text = stringResource(R.string.cancel),
                        color = Color.White.copy(alpha = 0.7f),
                    )
                }

                Button(
                    onClick = {
                        haptics.play(Haptic.Select)
                        onSave(text)
                        onDismiss()
                    },
                    modifier = Modifier.weight(1f),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Color.White,
                        contentColor = Color.Black,
                    ),
                    shape = RoundedCornerShape(20.dp),
                ) {
                    Text(
                        text = stringResource(R.string.save_lyrics),
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }
        }
    }
}

@Composable
private fun EditActionChip(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .clip(RoundedCornerShape(14.dp))
            .background(Color.White.copy(alpha = 0.08f))
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = Color.White.copy(alpha = 0.85f),
            modifier = Modifier.size(16.dp),
        )
        Spacer(Modifier.width(6.dp))
        Text(
            text = label,
            style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Medium),
            color = Color.White.copy(alpha = 0.9f),
            maxLines = 1,
        )
    }
}
