package com.fortune.vibramusic.desktop.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.Groups
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.LibraryMusic
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.QueueMusic
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.fortune.vibramusic.desktop.data.DesktopMusicRepository
import com.fortune.vibramusic.desktop.glass.liquidGlass
import com.fortune.vibramusic.desktop.model.DesktopSong
import com.fortune.vibramusic.desktop.model.DesktopTab
import com.fortune.vibramusic.desktop.player.DesktopPlayerController
import com.fortune.vibramusic.desktop.update.DesktopAppUpdateChecker
import kotlinx.coroutines.launch

private val DarkColorScheme = darkColorScheme(
    primary = Color.White,
    onPrimary = Color.Black,
    background = Color.Black,
    onBackground = Color.White,
    surface = Color(0xFF0D0D0F),
    onSurface = Color.White,
    surfaceVariant = Color(0xFF1C1C1E),
    onSurfaceVariant = Color(0xFF8E8E93),
    outline = Color(0xFF2C2C2E),
)

@Composable
fun DesktopApp() {
    val uiState by DesktopPlayerController.uiState.collectAsState()
    val scope = rememberCoroutineScope()

    var searchQuery by remember { mutableStateOf("") }
    var showPartyDialog by remember { mutableStateOf(false) }
    var showSettingsDialog by remember { mutableStateOf(false) }
    var showUpdateDialog by remember { mutableStateOf(false) }
    val updateInfo by DesktopAppUpdateChecker.available.collectAsState()
    val downloadState by DesktopAppUpdateChecker.downloadState.collectAsState()
    val updateAvailable = updateInfo != null

    val homeShelves = remember { DesktopMusicRepository.getHomeShelves() }
    val featuredSongs = remember { DesktopMusicRepository.getFeaturedSongs() }
    val moodGenres = remember { DesktopMusicRepository.getMoodGenres() }

    // Check for updates on startup
    LaunchedEffect(Unit) {
        DesktopAppUpdateChecker.check()
    }

    MaterialTheme(colorScheme = DarkColorScheme) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color.Black),
        ) {
            Column(modifier = Modifier.fillMaxSize()) {
                // Top Frosted Bar
                DesktopTopBar(
                    updateAvailable = updateAvailable,
                    onOpenUpdate = { showUpdateDialog = true },
                    onOpenParty = { showPartyDialog = true },
                    onOpenSettings = { showSettingsDialog = true },
                )

                // Main Content Page
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth(),
                ) {
                    when (uiState.currentTab) {
                        DesktopTab.Home -> {
                            LazyColumn(
                                modifier = Modifier.fillMaxSize(),
                                contentPadding = PaddingValues(horizontal = 28.dp, vertical = 20.dp),
                            ) {
                                // Big Header
                                item {
                                    Column(modifier = Modifier.padding(bottom = 24.dp)) {
                                        Text(
                                            text = "Listen Now",
                                            color = Color.White,
                                            fontSize = 34.sp,
                                            fontWeight = FontWeight.ExtraBold,
                                            letterSpacing = (-0.8).sp,
                                        )
                                        Text(
                                            text = "Top picks and recent favorites",
                                            color = Color(0xFF8E8E93),
                                            fontSize = 15.sp,
                                        )
                                    }
                                }

                                // Quick Picks Section (4 tracks per column, horizontal scroll)
                                item {
                                    Text(
                                        text = "Quick Picks",
                                        color = Color.White,
                                        fontSize = 22.sp,
                                        fontWeight = FontWeight.Bold,
                                        modifier = Modifier.padding(bottom = 14.dp),
                                    )

                                    val chunked = featuredSongs.chunked(4)
                                    LazyRow(
                                        horizontalArrangement = Arrangement.spacedBy(16.dp),
                                        contentPadding = PaddingValues(bottom = 24.dp),
                                    ) {
                                        items(chunked) { columnSongs ->
                                            Column(
                                                modifier = Modifier.width(320.dp),
                                                verticalArrangement = Arrangement.spacedBy(6.dp),
                                            ) {
                                                columnSongs.forEach { song ->
                                                    val isCurrent = uiState.currentSong?.id == song.id
                                                    DesktopQuickPickItem(
                                                        song = song,
                                                        isPlaying = isCurrent && uiState.isPlaying,
                                                        onClick = {
                                                            DesktopPlayerController.playSong(song, featuredSongs)
                                                        },
                                                    )
                                                }
                                            }
                                        }
                                    }
                                }

                                // Shelves (Trending Now, New Releases, etc.)
                                items(homeShelves) { shelf ->
                                    Column(modifier = Modifier.padding(bottom = 28.dp)) {
                                        Text(
                                            text = shelf.title,
                                            color = Color.White,
                                            fontSize = 22.sp,
                                            fontWeight = FontWeight.Bold,
                                        )
                                        if (shelf.subtitle.isNotBlank()) {
                                            Text(
                                                text = shelf.subtitle,
                                                color = Color(0xFF8E8E93),
                                                fontSize = 13.sp,
                                                modifier = Modifier.padding(bottom = 12.dp),
                                            )
                                        } else {
                                            Spacer(modifier = Modifier.height(12.dp))
                                        }

                                        LazyRow(
                                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                                        ) {
                                            items(shelf.items) { itemSong ->
                                                DesktopShelfCard(
                                                    song = itemSong,
                                                    onClick = {
                                                        DesktopPlayerController.playSong(itemSong, shelf.items)
                                                    },
                                                )
                                            }
                                        }
                                    }
                                }

                                // Bottom spacer to clear the floating bottom bar
                                item {
                                    Spacer(modifier = Modifier.height(130.dp))
                                }
                            }
                        }

                        DesktopTab.Explore -> {
                            LazyColumn(
                                modifier = Modifier.fillMaxSize(),
                                contentPadding = PaddingValues(horizontal = 28.dp, vertical = 20.dp),
                            ) {
                                item {
                                    Column(modifier = Modifier.padding(bottom = 24.dp)) {
                                        Text(
                                            text = "Explore",
                                            color = Color.White,
                                            fontSize = 34.sp,
                                            fontWeight = FontWeight.ExtraBold,
                                            letterSpacing = (-0.8).sp,
                                        )
                                        Text(
                                            text = "New releases, charts and moods",
                                            color = Color(0xFF8E8E93),
                                            fontSize = 15.sp,
                                        )
                                    }
                                }

                                item {
                                    Text(
                                        text = "Moods & Genres",
                                        color = Color.White,
                                        fontSize = 22.sp,
                                        fontWeight = FontWeight.Bold,
                                        modifier = Modifier.padding(bottom = 16.dp),
                                    )
                                }

                                // 4-column Grid of Mood & Genre Cards
                                item {
                                    val rows = moodGenres.chunked(4)
                                    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                                        rows.forEach { rowMoods ->
                                            Row(
                                                modifier = Modifier.fillMaxWidth(),
                                                horizontalArrangement = Arrangement.spacedBy(14.dp),
                                            ) {
                                                rowMoods.forEach { mood ->
                                                    DesktopMoodGenreCard(
                                                        mood = mood,
                                                        onClick = {
                                                            searchQuery = mood.title
                                                            DesktopPlayerController.search(mood.title)
                                                            DesktopPlayerController.setTab(DesktopTab.Search)
                                                        },
                                                        modifier = Modifier.weight(1f),
                                                    )
                                                }
                                                // Fill empty slots if row has fewer than 4 items
                                                repeat(4 - rowMoods.size) {
                                                    Spacer(modifier = Modifier.weight(1f))
                                                }
                                            }
                                        }
                                    }
                                }

                                item {
                                    Spacer(modifier = Modifier.height(32.dp))
                                    Text(
                                        text = "Global Top Charts",
                                        color = Color.White,
                                        fontSize = 22.sp,
                                        fontWeight = FontWeight.Bold,
                                        modifier = Modifier.padding(bottom = 14.dp),
                                    )
                                }

                                itemsIndexed(featuredSongs) { index, song ->
                                    val isCurrent = uiState.currentSong?.id == song.id
                                    Row(
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .clip(RoundedCornerShape(10.dp))
                                            .clickable { DesktopPlayerController.playSong(song, featuredSongs) }
                                            .padding(vertical = 6.dp, horizontal = 8.dp),
                                        verticalAlignment = Alignment.CenterVertically,
                                    ) {
                                        Text(
                                            text = "${index + 1}",
                                            color = if (index < 3) Color(0xFFFA2D48) else Color(0xFF8E8E93),
                                            fontSize = 18.sp,
                                            fontWeight = FontWeight.Bold,
                                            modifier = Modifier.width(36.dp),
                                        )
                                        DesktopSongListItem(
                                            song = song,
                                            isPlaying = isCurrent && uiState.isPlaying,
                                            onClick = { DesktopPlayerController.playSong(song, featuredSongs) },
                                            modifier = Modifier.weight(1f),
                                        )
                                    }
                                }

                                item {
                                    Spacer(modifier = Modifier.height(130.dp))
                                }
                            }
                        }

                        DesktopTab.Library -> {
                            LazyColumn(
                                modifier = Modifier.fillMaxSize(),
                                contentPadding = PaddingValues(horizontal = 28.dp, vertical = 20.dp),
                            ) {
                                item {
                                    Column(modifier = Modifier.padding(bottom = 24.dp)) {
                                        Text(
                                            text = "Library",
                                            color = Color.White,
                                            fontSize = 34.sp,
                                            fontWeight = FontWeight.ExtraBold,
                                            letterSpacing = (-0.8).sp,
                                        )
                                        Text(
                                            text = "Liked songs, history and playlists",
                                            color = Color(0xFF8E8E93),
                                            fontSize = 15.sp,
                                        )
                                    }
                                }

                                // Quick Category Cards Row
                                item {
                                    Row(
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .padding(bottom = 28.dp),
                                        horizontalArrangement = Arrangement.spacedBy(16.dp),
                                    ) {
                                        val categories = listOf(
                                            Triple("Playlists", Icons.Rounded.QueueMusic, Color(0xFF3498DB)),
                                            Triple("Liked Songs", Icons.Rounded.Favorite, Color(0xFFFA2D48)),
                                            Triple("History", Icons.Rounded.History, Color(0xFF9B59B6)),
                                            Triple("Listen Together", Icons.Rounded.Groups, Color(0xFF2ECC71)),
                                        )
                                        categories.forEach { (catTitle, catIcon, catColor) ->
                                            Box(
                                                modifier = Modifier
                                                    .weight(1f)
                                                    .height(84.dp)
                                                    .clip(RoundedCornerShape(14.dp))
                                                    .background(Color(0xFF16181F))
                                                    .clickable {
                                                        if (catTitle == "Listen Together") showPartyDialog = true
                                                    }
                                                    .padding(14.dp),
                                                contentAlignment = Alignment.BottomStart,
                                            ) {
                                                Row(
                                                    verticalAlignment = Alignment.CenterVertically,
                                                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                                                ) {
                                                    Box(
                                                        modifier = Modifier
                                                            .size(36.dp)
                                                            .clip(CircleShape)
                                                            .background(catColor.copy(alpha = 0.2f)),
                                                        contentAlignment = Alignment.Center,
                                                    ) {
                                                        Icon(catIcon, contentDescription = null, tint = catColor, modifier = Modifier.size(20.dp))
                                                    }
                                                    Text(catTitle, color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.Bold)
                                                }
                                            }
                                        }
                                    }
                                }

                                // Liked Songs Section
                                val likedSongs = featuredSongs.filter { uiState.likedSongIds.contains(it.id) }
                                if (likedSongs.isNotEmpty()) {
                                    item {
                                        Text(
                                            text = "Liked Songs (${likedSongs.size})",
                                            color = Color.White,
                                            fontSize = 22.sp,
                                            fontWeight = FontWeight.Bold,
                                            modifier = Modifier.padding(bottom = 12.dp),
                                        )
                                    }
                                    items(likedSongs) { song ->
                                        val isCurrent = uiState.currentSong?.id == song.id
                                        DesktopSongListItem(
                                            song = song,
                                            isPlaying = isCurrent && uiState.isPlaying,
                                            onClick = { DesktopPlayerController.playSong(song, likedSongs) },
                                        )
                                    }
                                }

                                // History Section
                                if (uiState.history.isNotEmpty()) {
                                    item {
                                        Spacer(modifier = Modifier.height(20.dp))
                                        Text(
                                            text = "Recently Played",
                                            color = Color.White,
                                            fontSize = 22.sp,
                                            fontWeight = FontWeight.Bold,
                                            modifier = Modifier.padding(bottom = 12.dp),
                                        )
                                    }
                                    items(uiState.history) { song ->
                                        val isCurrent = uiState.currentSong?.id == song.id
                                        DesktopSongListItem(
                                            song = song,
                                            isPlaying = isCurrent && uiState.isPlaying,
                                            onClick = { DesktopPlayerController.playSong(song, uiState.history) },
                                        )
                                    }
                                } else if (likedSongs.isEmpty()) {
                                    item {
                                        Box(
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .height(200.dp),
                                            contentAlignment = Alignment.Center,
                                        ) {
                                            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                                Icon(
                                                    imageVector = Icons.Rounded.LibraryMusic,
                                                    contentDescription = null,
                                                    tint = Color.White.copy(alpha = 0.3f),
                                                    modifier = Modifier.size(48.dp),
                                                )
                                                Spacer(modifier = Modifier.height(12.dp))
                                                Text("Your library will appear here", color = Color.White.copy(alpha = 0.6f), fontSize = 16.sp)
                                                Text("Songs you play and like will be saved", color = Color(0xFF8E8E93), fontSize = 13.sp)
                                            }
                                        }
                                    }
                                }

                                item {
                                    Spacer(modifier = Modifier.height(130.dp))
                                }
                            }
                        }

                        DesktopTab.Search -> {
                            LazyColumn(
                                modifier = Modifier.fillMaxSize(),
                                contentPadding = PaddingValues(horizontal = 28.dp, vertical = 20.dp),
                            ) {
                                item {
                                    Column(modifier = Modifier.padding(bottom = 20.dp)) {
                                        Text(
                                            text = "Search",
                                            color = Color.White,
                                            fontSize = 34.sp,
                                            fontWeight = FontWeight.ExtraBold,
                                            letterSpacing = (-0.8).sp,
                                        )
                                        Spacer(modifier = Modifier.height(16.dp))

                                        // Capsule Liquid Glass Search Bar
                                        DesktopSearchBar(
                                            query = searchQuery,
                                            onQueryChange = {
                                                searchQuery = it
                                                DesktopPlayerController.search(it)
                                            },
                                            onClear = {
                                                searchQuery = ""
                                                DesktopPlayerController.search("")
                                            },
                                        )
                                    }
                                }

                                if (uiState.isSearching) {
                                    item {
                                        Box(
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .padding(top = 40.dp),
                                            contentAlignment = Alignment.Center,
                                        ) {
                                            CircularProgressIndicator(color = Color(0xFFFA2D48))
                                        }
                                    }
                                } else if (uiState.searchResults.isNotEmpty()) {
                                    item {
                                        Text(
                                            text = "Top Results",
                                            color = Color.White,
                                            fontSize = 20.sp,
                                            fontWeight = FontWeight.Bold,
                                            modifier = Modifier.padding(bottom = 12.dp),
                                        )
                                    }
                                    items(uiState.searchResults) { song ->
                                        val isCurrent = uiState.currentSong?.id == song.id
                                        DesktopSongListItem(
                                            song = song,
                                            isPlaying = isCurrent && uiState.isPlaying,
                                            onClick = {
                                                DesktopPlayerController.playSong(song, uiState.searchResults)
                                            },
                                        )
                                    }
                                } else if (searchQuery.isBlank()) {
                                    // Trending Search Chips
                                    item {
                                        Column {
                                            Text(
                                                text = "Trending Searches",
                                                color = Color.White,
                                                fontSize = 20.sp,
                                                fontWeight = FontWeight.Bold,
                                                modifier = Modifier.padding(bottom = 14.dp),
                                            )

                                            val trending = listOf("The Weeknd", "Taylor Swift", "Drake", "Billie Eilish", "Post Malone", "Ed Sheeran", "Dua Lipa", "Coldplay", "Bruno Mars")
                                            Row(
                                                modifier = Modifier.fillMaxWidth(),
                                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                                            ) {
                                                trending.take(5).forEach { tag ->
                                                    Box(
                                                        modifier = Modifier
                                                            .clip(RoundedCornerShape(20.dp))
                                                            .background(Color(0xFF1C1E24))
                                                            .clickable {
                                                                searchQuery = tag
                                                                DesktopPlayerController.search(tag)
                                                            }
                                                            .padding(horizontal = 16.dp, vertical = 8.dp),
                                                    ) {
                                                        Text(tag, color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }

                                item {
                                    Spacer(modifier = Modifier.height(130.dp))
                                }
                            }
                        }
                    }
                }
            }

            // Bottom Centered Floating Area: MiniPlayer + FloatingBottomBar
            Column(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .widthIn(max = 480.dp)
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 18.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                // Mini Player (Appears above the bottom bar when a song is playing)
                if (uiState.currentSong != null) {
                    DesktopMiniPlayer(
                        song = uiState.currentSong!!,
                        isPlaying = uiState.isPlaying,
                        isBuffering = uiState.isBuffering,
                        onPlayPause = { DesktopPlayerController.togglePlayPause() },
                        onNext = { DesktopPlayerController.next() },
                        onPrevious = { DesktopPlayerController.previous() },
                        onExpand = { DesktopPlayerController.setNowPlayingExpanded(true) },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(modifier = Modifier.height(10.dp))
                }

                // Floating Navigation Bar (Home, Explore, Library, Search)
                DesktopFloatingNavBar(
                    selectedTab = uiState.currentTab,
                    onTabSelected = { DesktopPlayerController.setTab(it) },
                )
            }

            // Fullscreen Now Playing Drawer (Landscape 2-Column Mode)
            AnimatedVisibility(
                visible = uiState.isNowPlayingExpanded && uiState.currentSong != null,
                enter = slideInVertically(initialOffsetY = { it }, animationSpec = tween(350)),
                exit = slideOutVertically(targetOffsetY = { it }, animationSpec = tween(300)),
            ) {
                uiState.currentSong?.let { current ->
                    DesktopNowPlayingScreen(
                        song = current,
                        isPlaying = uiState.isPlaying,
                        isBuffering = uiState.isBuffering,
                        currentPositionMs = uiState.currentPositionMs,
                        durationMs = uiState.durationMs,
                        volume = uiState.volume,
                        isLiked = uiState.likedSongIds.contains(current.id),
                        onToggleLike = { DesktopPlayerController.toggleLike(current) },
                        onClose = { DesktopPlayerController.setNowPlayingExpanded(false) },
                        onPlayPause = { DesktopPlayerController.togglePlayPause() },
                        onSeekTo = { DesktopPlayerController.seekTo(it) },
                        onSkipNext = { DesktopPlayerController.next() },
                        onSkipPrevious = { DesktopPlayerController.previous() },
                        onVolumeChange = { DesktopPlayerController.setVolume(it) },
                        queue = uiState.queue,
                        onSelectQueueItem = { DesktopPlayerController.playSong(it, uiState.queue) },
                    )
                }
            }

            // Listen Together Party Modal
            if (showPartyDialog) {
                var partyInputCode by remember { mutableStateOf("") }
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(Color.Black.copy(alpha = 0.65f))
                        .clickable { showPartyDialog = false },
                    contentAlignment = Alignment.Center,
                ) {
                    val cardShape = remember { RoundedCornerShape(24.dp) }
                    Box(
                        modifier = Modifier
                            .widthIn(max = 460.dp)
                            .fillMaxWidth(0.88f)
                            .liquidGlass(shape = cardShape, elevation = 20.dp)
                            .background(Color(0xFF16181F), cardShape)
                            .clickable(enabled = false) {}
                            .padding(32.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text("Listen Together", color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.Bold)
                            Spacer(modifier = Modifier.height(8.dp))
                            Text("Synchronized party music across Windows & Android", color = Color(0xFF8E8E93), fontSize = 13.sp)
                            Spacer(modifier = Modifier.height(24.dp))

                            OutlinedTextField(
                                value = partyInputCode,
                                onValueChange = { if (it.length <= 6) partyInputCode = it.uppercase() },
                                label = { Text("Enter 6-digit Party Code") },
                                colors = TextFieldDefaults.colors(
                                    focusedTextColor = Color.White,
                                    unfocusedTextColor = Color.White,
                                    focusedContainerColor = Color.Transparent,
                                    unfocusedContainerColor = Color.Transparent,
                                ),
                                singleLine = true,
                            )
                            Spacer(modifier = Modifier.height(20.dp))

                            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                Button(
                                    onClick = { showPartyDialog = false },
                                    colors = ButtonDefaults.buttonColors(containerColor = Color.White.copy(alpha = 0.15f)),
                                    shape = RoundedCornerShape(50),
                                ) {
                                    Text("Cancel", color = Color.White)
                                }
                                Button(
                                    onClick = {
                                        if (partyInputCode.isNotBlank()) {
                                            DesktopPlayerController.joinParty(partyInputCode)
                                            showPartyDialog = false
                                        }
                                    },
                                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFFA2D48)),
                                    shape = RoundedCornerShape(50),
                                ) {
                                    Text("Join Party", fontWeight = FontWeight.Bold)
                                }
                            }
                        }
                    }
                }
            }

            // Settings Modal
            if (showSettingsDialog) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(Color.Black.copy(alpha = 0.65f))
                        .clickable { showSettingsDialog = false },
                    contentAlignment = Alignment.Center,
                ) {
                    val cardShape = remember { RoundedCornerShape(24.dp) }
                    Box(
                        modifier = Modifier
                            .widthIn(max = 460.dp)
                            .fillMaxWidth(0.88f)
                            .liquidGlass(shape = cardShape, elevation = 20.dp)
                            .background(Color(0xFF16181F), cardShape)
                            .clickable(enabled = false) {}
                            .padding(28.dp),
                    ) {
                        Column {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text("Settings", color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)
                                IconButton(onClick = { showSettingsDialog = false }) {
                                    Icon(Icons.Rounded.Close, contentDescription = "Close", tint = Color.White)
                                }
                            }

                            Spacer(modifier = Modifier.height(18.dp))

                            Text("Vibra Music for Windows", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                            Text("Version 1.8.19 • Pure Compose Multiplatform Desktop", color = Color(0xFF8E8E93), fontSize = 13.sp)

                            Spacer(modifier = Modifier.height(16.dp))
                            Text("Audio Engine: VLCJ / LibVLC Native Streamer", color = Color(0xFF8E8E93), fontSize = 13.sp)
                            Text("Liquid Glass: Skia Hardware-Accelerated Refraction", color = Color(0xFF8E8E93), fontSize = 13.sp)

                            Spacer(modifier = Modifier.height(24.dp))

                            Button(
                                onClick = {
                                    showSettingsDialog = false
                                    scope.launch {
                                        val info = DesktopAppUpdateChecker.check()
                                        if (info != null) {
                                            showUpdateDialog = true
                                        }
                                    }
                                },
                                colors = ButtonDefaults.buttonColors(containerColor = Color.White.copy(alpha = 0.15f)),
                                shape = RoundedCornerShape(50),
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                Text("Check for Updates", color = Color.White, fontWeight = FontWeight.SemiBold)
                            }
                        }
                    }
                }
            }

            // Update Dialog
            if (showUpdateDialog && updateInfo != null) {
                DesktopUpdateDialog(
                    updateInfo = updateInfo!!,
                    downloadState = downloadState,
                    onDismiss = { showUpdateDialog = false },
                )
            }
        }
    }
}
