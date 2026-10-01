package com.fortune.vibramusic.desktop.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.fortune.vibramusic.desktop.data.DesktopMusicRepository
import com.fortune.vibramusic.desktop.glass.liquidGlass
import com.fortune.vibramusic.desktop.model.DesktopTab
import com.fortune.vibramusic.desktop.player.DesktopPlayerController

@Composable
fun DesktopApp() {
    val uiState by DesktopPlayerController.uiState.collectAsState()
    var searchQuery by remember { mutableStateOf("") }
    val featuredSongs = remember { DesktopMusicRepository.getFeaturedSongs() }

    MaterialTheme(
        colorScheme = darkColorScheme(
            background = Color(0xFF0A0A0C),
            surface = Color(0xFF141416),
            primary = Color(0xFFFA2D48),
            onPrimary = Color.White,
            onBackground = Color.White,
            onSurface = Color.White,
        )
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color(0xFF0A0A0C))
        ) {
            // Background Mesh Gradient (soft atmosphere)
            DesktopMeshGradient()

            Column(modifier = Modifier.fillMaxSize()) {
                // Top Glass Header with search
                DesktopTopBar(
                    searchQuery = searchQuery,
                    onSearchChange = { q ->
                        searchQuery = q
                        DesktopPlayerController.search(q)
                    }
                )

                // Main Content View based on active Tab or active Search
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth()
                        .padding(bottom = 90.dp) // space for floating bottom bar
                ) {
                    if (searchQuery.isNotEmpty()) {
                        // Search Results Screen
                        if (uiState.isSearching) {
                            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                                CircularProgressIndicator(color = Color(0xFFFA2D48))
                            }
                        } else if (uiState.searchResults.isEmpty()) {
                            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                                Text("No results found for \"$searchQuery\"", color = Color.White.copy(alpha = 0.6f))
                            }
                        } else {
                            LazyColumn(modifier = Modifier.fillMaxSize()) {
                                items(uiState.searchResults) { song ->
                                    val isCurrent = uiState.currentSong?.id == song.id
                                    SongListItem(
                                        song = song,
                                        isPlaying = isCurrent && uiState.isPlaying,
                                        onClick = {
                                            DesktopPlayerController.playSong(song, uiState.searchResults)
                                        }
                                    )
                                }
                            }
                        }
                    } else {
                        // Tab Contents
                        when (uiState.currentTab) {
                            DesktopTab.Home -> {
                                LazyColumn(
                                    modifier = Modifier
                                        .fillMaxSize()
                                        .padding(horizontal = 20.dp)
                                ) {
                                    item {
                                        Text(
                                            text = "Quick Picks",
                                            color = Color.White,
                                            fontSize = 22.sp,
                                            fontWeight = FontWeight.Bold,
                                            modifier = Modifier.padding(vertical = 16.dp),
                                        )
                                    }
                                    items(featuredSongs) { song ->
                                        val isCurrent = uiState.currentSong?.id == song.id
                                        SongListItem(
                                            song = song,
                                            isPlaying = isCurrent && uiState.isPlaying,
                                            onClick = {
                                                DesktopPlayerController.playSong(song, featuredSongs)
                                            }
                                        )
                                    }
                                }
                            }

                            DesktopTab.Explore -> {
                                LazyColumn(
                                    modifier = Modifier
                                        .fillMaxSize()
                                        .padding(horizontal = 20.dp)
                                ) {
                                    item {
                                        Text(
                                            text = "Trending Now",
                                            color = Color.White,
                                            fontSize = 22.sp,
                                            fontWeight = FontWeight.Bold,
                                            modifier = Modifier.padding(vertical = 16.dp),
                                        )
                                    }
                                    items(featuredSongs.reversed()) { song ->
                                        val isCurrent = uiState.currentSong?.id == song.id
                                        SongListItem(
                                            song = song,
                                            isPlaying = isCurrent && uiState.isPlaying,
                                            onClick = {
                                                DesktopPlayerController.playSong(song, featuredSongs.reversed())
                                            }
                                        )
                                    }
                                }
                            }

                            DesktopTab.Library -> {
                                Box(
                                    modifier = Modifier
                                        .fillMaxSize()
                                        .padding(24.dp),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                        Text("Your Library", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                                        Spacer(modifier = Modifier.height(8.dp))
                                        Text("Local audio scanner & saved playlists are ready", color = Color.White.copy(alpha = 0.6f))
                                    }
                                }
                            }

                            DesktopTab.Party -> {
                                // Listen Together Party Screen
                                var partyInputCode by remember { mutableStateOf("") }
                                Box(
                                    modifier = Modifier
                                        .fillMaxSize()
                                        .padding(24.dp),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    val cardShape = remember { RoundedCornerShape(24.dp) }
                                    Box(
                                        modifier = Modifier
                                            .fillMaxWidth(0.85f)
                                            .liquidGlass(shape = cardShape, elevation = 16.dp)
                                            .padding(32.dp),
                                        contentAlignment = Alignment.Center,
                                    ) {
                                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                            Text("Listen Together", color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.Bold)
                                            Spacer(modifier = Modifier.height(8.dp))
                                            Text("Party Server: https://party.vibramusic.store", color = Color.White.copy(alpha = 0.6f), fontSize = 12.sp)
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
                                            Spacer(modifier = Modifier.height(16.dp))

                                            Button(
                                                onClick = {
                                                    if (partyInputCode.isNotBlank()) {
                                                        DesktopPlayerController.joinParty(partyInputCode)
                                                    }
                                                },
                                                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFFA2D48)),
                                                shape = RoundedCornerShape(50),
                                            ) {
                                                Text("Join Party", fontWeight = FontWeight.Bold)
                                            }

                                            if (uiState.partyCode.isNotEmpty()) {
                                                Spacer(modifier = Modifier.height(16.dp))
                                                Text(uiState.partyStatus, color = Color(0xFF4CAF50), fontSize = 14.sp)
                                            }
                                        }
                                    }
                                }
                            }

                            DesktopTab.Settings -> {
                                Box(
                                    modifier = Modifier
                                        .fillMaxSize()
                                        .padding(24.dp),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                        Text("Vibra Music Settings", color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)
                                        Spacer(modifier = Modifier.height(16.dp))
                                        Text("Liquid Glass: Hardware GPU (SkSL / DirectX 12) Enabled", color = Color.White.copy(alpha = 0.8f))
                                        Text("Audio Backend: VLCJ LibVLC Native Engine Active", color = Color.White.copy(alpha = 0.8f))
                                        Text("App Version: v1.8.17 (Windows Desktop Edition)", color = Color.White.copy(alpha = 0.6f))
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Floating Liquid Glass Navigation Bar (pinned at bottom)
            DesktopFloatingNavBar(
                selectedTab = uiState.currentTab,
                onTabSelected = { tab ->
                    searchQuery = ""
                    DesktopPlayerController.setTab(tab)
                },
                currentSong = uiState.currentSong,
                isPlaying = uiState.isPlaying,
                isBuffering = uiState.isBuffering,
                onPlayPause = { DesktopPlayerController.togglePlayPause() },
                onExpandNowPlaying = { DesktopPlayerController.setNowPlayingExpanded(true) },
                modifier = Modifier.align(Alignment.BottomCenter),
            )

            // Animated Fullscreen Now Playing Drawer
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
                        onClose = { DesktopPlayerController.setNowPlayingExpanded(false) },
                        onPlayPause = { DesktopPlayerController.togglePlayPause() },
                        onNext = { DesktopPlayerController.next() },
                        onPrevious = { DesktopPlayerController.previous() },
                        onSeek = { ms -> DesktopPlayerController.seekTo(ms) },
                        onVolumeChange = { vol -> DesktopPlayerController.setVolume(vol) },
                    )
                }
            }
        }
    }
}
