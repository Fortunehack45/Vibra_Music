package com.fortune.vibramusic.ui.screens

import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Cached
import androidx.compose.material.icons.rounded.DeleteOutline
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.OfflinePin
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Shuffle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.media3.common.util.UnstableApi
import com.fortune.vibramusic.R
import com.fortune.vibramusic.data.cache.OfflineCacheManager
import com.fortune.vibramusic.data.model.Song
import com.fortune.vibramusic.ui.components.PAGE_GUTTER
import com.fortune.vibramusic.ui.components.SongRow
import com.fortune.vibramusic.ui.components.topBarContentPadding

@OptIn(ExperimentalMaterial3Api::class, UnstableApi::class)
@Composable
fun CachedMusicScreen(
    songs: List<Song>,
    currentSong: Song?,
    isPlaying: Boolean,
    onBack: () -> Unit,
    onSongClick: (List<Song>, Int) -> Unit,
    onSongLongPress: (Song) -> Unit,
    onClearCache: () -> Unit,
    onSaveAllToDownloads: () -> Unit,
    modifier: Modifier = Modifier,
    contentPadding: PaddingValues = PaddingValues(),
) {
    BackHandler(onBack = onBack)

    val context = LocalContext.current
    val listState = rememberLazyListState()
    val totalSize by OfflineCacheManager.totalCacheSizeFormatted.collectAsStateWithLifecycle()
    var showClearDialog by remember { mutableStateOf(false) }

    if (showClearDialog) {
        AlertDialog(
            onDismissRequest = { showClearDialog = false },
            title = {
                Text(
                    text = "Clear music cache?",
                    fontWeight = FontWeight.Bold,
                )
            },
            text = {
                Text("This will remove all temporarily saved offline tracks and free up storage on your device.")
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        showClearDialog = false
                        onClearCache()
                        Toast.makeText(context, "Cache cleared", Toast.LENGTH_SHORT).show()
                    },
                    colors = ButtonDefaults.textButtonColors(contentColor = Color(0xFFE50914)),
                ) {
                    Text("Clear", fontWeight = FontWeight.Bold)
                }
            },
            dismissButton = {
                TextButton(onClick = { showClearDialog = false }) {
                    Text(stringResource(R.string.cancel))
                }
            },
            shape = RoundedCornerShape(20.dp),
        )
    }

    Box(modifier = modifier.fillMaxSize()) {
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(
                top = topBarContentPadding(),
                bottom = contentPadding.calculateBottomPadding() + 40.dp,
            ),
        ) {
            // Header Stats Card
            item(key = "cache_header_card") {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = PAGE_GUTTER, vertical = 10.dp)
                        .clip(RoundedCornerShape(22.dp))
                        .background(
                            Brush.verticalGradient(
                                listOf(
                                    MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.65f),
                                    MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f),
                                )
                            )
                        )
                        .border(
                            1.dp,
                            MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f),
                            RoundedCornerShape(22.dp),
                        )
                        .padding(18.dp),
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Box(
                                modifier = Modifier
                                    .size(34.dp)
                                    .clip(CircleShape)
                                    .background(Color(0xFFE50914).copy(alpha = 0.15f)),
                                contentAlignment = Alignment.Center,
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.Cached,
                                    contentDescription = null,
                                    tint = Color(0xFFE50914),
                                    modifier = Modifier.size(20.dp),
                                )
                            }
                            Text(
                                text = "Temporary Offline Storage",
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.Bold,
                            )
                        }

                        // Storage Pill & Clear Action
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            Box(
                                modifier = Modifier
                                    .clip(RoundedCornerShape(10.dp))
                                    .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.8f))
                                    .padding(horizontal = 10.dp, vertical = 5.dp),
                            ) {
                                Text(
                                    text = totalSize,
                                    style = MaterialTheme.typography.labelMedium,
                                    fontWeight = FontWeight.Bold,
                                    color = MaterialTheme.colorScheme.primary,
                                )
                            }

                            if (songs.isNotEmpty()) {
                                IconButton(
                                    onClick = { showClearDialog = true },
                                    modifier = Modifier.size(32.dp),
                                ) {
                                    Icon(
                                        imageVector = Icons.Rounded.DeleteOutline,
                                        contentDescription = "Clear Cache",
                                        tint = MaterialTheme.colorScheme.error,
                                        modifier = Modifier.size(18.dp),
                                    )
                                }
                            }
                        }
                    }

                    Spacer(Modifier.height(10.dp))

                    Text(
                        text = "Songs streamed while connected are automatically cached here so you can seamlessly play them without an internet connection.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        lineHeight = 18.sp,
                    )

                    if (songs.isNotEmpty()) {
                        Spacer(Modifier.height(16.dp))

                        // Actions Row: Play All, Shuffle, Download All
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            Button(
                                onClick = { onSongClick(songs, 0) },
                                modifier = Modifier.weight(1f),
                                shape = RoundedCornerShape(14.dp),
                                colors = ButtonDefaults.buttonColors(
                                    containerColor = Color(0xFFE50914),
                                    contentColor = Color.White,
                                ),
                                contentPadding = PaddingValues(vertical = 11.dp),
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.PlayArrow,
                                    contentDescription = null,
                                    modifier = Modifier.size(18.dp),
                                )
                                Spacer(Modifier.width(6.dp))
                                Text(
                                    text = "Play All",
                                    fontWeight = FontWeight.Bold,
                                    fontSize = 13.sp,
                                )
                            }

                            FilledTonalButton(
                                onClick = {
                                    val shuffled = songs.shuffled()
                                    onSongClick(shuffled, 0)
                                },
                                modifier = Modifier.weight(1f),
                                shape = RoundedCornerShape(14.dp),
                                contentPadding = PaddingValues(vertical = 11.dp),
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.Shuffle,
                                    contentDescription = null,
                                    modifier = Modifier.size(18.dp),
                                )
                                Spacer(Modifier.width(6.dp))
                                Text(
                                    text = "Shuffle",
                                    fontWeight = FontWeight.Bold,
                                    fontSize = 13.sp,
                                )
                            }

                            IconButton(
                                onClick = onSaveAllToDownloads,
                                modifier = Modifier
                                    .clip(RoundedCornerShape(14.dp))
                                    .background(MaterialTheme.colorScheme.surface)
                                    .size(44.dp),
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.Download,
                                    contentDescription = "Save all to Downloads",
                                    tint = MaterialTheme.colorScheme.onSurface,
                                    modifier = Modifier.size(20.dp),
                                )
                            }
                        }
                    }
                }
            }

            if (songs.isEmpty()) {
                item(key = "empty_cache") {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = PAGE_GUTTER, vertical = 60.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Box(
                            modifier = Modifier
                                .size(72.dp)
                                .clip(CircleShape)
                                .background(MaterialTheme.colorScheme.surfaceVariant),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.OfflinePin,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                                modifier = Modifier.size(36.dp),
                            )
                        }
                        Spacer(Modifier.height(16.dp))
                        Text(
                            text = "No cached music yet",
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold,
                        )
                        Spacer(Modifier.height(6.dp))
                        Text(
                            text = "Play some songs online and they will appear here automatically for offline listening.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                            modifier = Modifier.padding(horizontal = 24.dp),
                        )
                    }
                }
            } else {
                item(key = "track_count_header") {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = PAGE_GUTTER, vertical = 8.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            text = "${songs.size} cached tracks",
                            style = MaterialTheme.typography.labelLarge,
                            fontWeight = FontWeight.SemiBold,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }

                itemsIndexed(
                    items = songs,
                    key = { _, song -> song.videoId },
                ) { index, song ->
                    val isCurrent = song.videoId == currentSong?.videoId
                    SongRow(
                        song = song,
                        onClick = { onSongClick(songs, index) },
                        onLongPress = { onSongLongPress(song) },
                        isCurrent = isCurrent,
                        isPlaying = isCurrent && isPlaying,
                        modifier = Modifier.padding(horizontal = PAGE_GUTTER),
                    )
                }
            }
        }
    }
}
