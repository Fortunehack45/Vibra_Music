package com.fortune.vibramusic.ui.onboarding

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.ExperimentalAnimationApi
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowForward
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.CameraAlt
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.GraphicEq
import androidx.compose.material.icons.rounded.Headphones
import androidx.compose.material.icons.rounded.LibraryMusic
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Stars
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.fortune.vibramusic.auth.AuthStore
import com.fortune.vibramusic.data.YtMusicRepository
import com.fortune.vibramusic.data.model.BrowseItem
import com.fortune.vibramusic.data.model.SearchFilter
import com.fortune.vibramusic.data.model.SearchResult
import com.fortune.vibramusic.data.settings.AppSettings
import com.fortune.vibramusic.data.quiz.QuizArtist
import com.fortune.vibramusic.data.supabase.SupabaseService
import com.fortune.vibramusic.data.supabase.UserCloudSyncManager
import com.fortune.vibramusic.ui.components.ArtistAvatar
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class GenreItem(
    val id: String,
    val name: String,
    val icon: ImageVector,
)

data class SelectedArtist(
    val id: String,
    val name: String,
    val imageUrl: String? = null,
)

@OptIn(ExperimentalAnimationApi::class, ExperimentalLayoutApi::class)
@Composable
fun VibraOnboardingFlow(
    onLaunchSignIn: () -> Unit,
    onComplete: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val authStore = remember { AuthStore(context) }

    var currentStep by remember { mutableIntStateOf(1) } // 1: Auth, 2: Genres, 3: Artists, 4: Identity
    var isSubmitting by remember { mutableStateOf(false) }

    // Detected session
    val activeSession = authStore.activeSession
    val activeProfile = activeSession?.profiles?.firstOrNull { it.profileId == activeSession.activeProfileId }
        ?: activeSession?.profiles?.firstOrNull()
    val isSignedIn = authStore.isSignedIn && activeSession != null

    // Preferences states
    val selectedGenres = remember { mutableStateListOf<String>() }
    val selectedArtists = remember { mutableStateListOf<SelectedArtist>() }

    // Identity states
    val defaultName = activeProfile?.name ?: activeSession?.name?.ifBlank { null } ?: "Music Listener"
    val defaultHandle = activeProfile?.handle?.ifBlank { null }
        ?: defaultName.lowercase().replace("[^a-z0-9_]".toRegex(), "").take(16)
        ?: "vibra_user"

    var displayName by remember { mutableStateOf(defaultName) }
    var handle by remember { mutableStateOf(defaultHandle) }
    var bio by remember { mutableStateOf("Music enthusiast exploring new vibes on Vibra.") }
    var selectedAvatarUri by remember { mutableStateOf<Uri?>(null) }
    var existingAvatarUrl by remember { mutableStateOf(activeProfile?.avatar) }

    val photoPickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickVisualMedia()
    ) { uri ->
        if (uri != null) {
            selectedAvatarUri = uri
        }
    }

    // Curated Genres list
    val curatedGenres = remember {
        listOf(
            GenreItem("hiphop", "Hip-Hop & Rap", Icons.Rounded.GraphicEq),
            GenreItem("afrobeats", "Afrobeats", Icons.Rounded.MusicNote),
            GenreItem("pop", "Pop & Dance", Icons.Rounded.Headphones),
            GenreItem("rnb", "R&B & Soul", Icons.Rounded.LibraryMusic),
            GenreItem("rock", "Rock & Alt", Icons.Rounded.PlayArrow),
            GenreItem("electronic", "EDM & Electronic", Icons.Rounded.GraphicEq),
            GenreItem("amapiano", "Amapiano", Icons.Rounded.MusicNote),
            GenreItem("reggae", "Reggae", Icons.Rounded.LibraryMusic),
            GenreItem("latin", "Latin", Icons.Rounded.Headphones),
            GenreItem("lofi", "Lo-Fi & Chill", Icons.Rounded.MusicNote),
            GenreItem("jazz", "Jazz & Blues", Icons.Rounded.GraphicEq),
            GenreItem("classical", "Classical", Icons.Rounded.LibraryMusic),
            GenreItem("indie", "Indie", Icons.Rounded.Headphones),
            GenreItem("metal", "Metal", Icons.Rounded.PlayArrow),
        )
    }

    // Curated Popular Artists
    val popularArtists = remember {
        listOf(
            SelectedArtist("UC0C-w0YjGpqDXGB8Tr0GGyA", "Drake"),
            SelectedArtist("UCqECaJ8Gagnn7YCbPEzWH6g", "Taylor Swift"),
            SelectedArtist("UCOmHUn--16B90oW2L6FRR3A", "Burna Boy"),
            SelectedArtist("UC0WP5P-ufpRfjbNrmOWwLBQ", "The Weeknd"),
            SelectedArtist("UCCgsKDzkjI6kHjG22r7Lq2w", "Kendrick Lamar"),
            SelectedArtist("UCiGm_E4DwYcU-gEyZv29eJA", "Billie Eilish"),
            SelectedArtist("UCZFMw83p7qJd6UqgIqA6V6w", "Wizkid"),
            SelectedArtist("UC2V6LwU_Z6jHqTfE6A_aB8A", "Asake"),
            SelectedArtist("UCtxD0x63328S6T29Wc9tHrw", "Travis Scott"),
            SelectedArtist("UCeLHszkByNZtPKcaVxoCOQQ", "SZA"),
            SelectedArtist("UC0C-w0YjGpqDXGB8Tr0G000", "Post Malone"),
            SelectedArtist("UC0C-w0YjGpqDXGB8Tr0G111", "Ariana Grande"),
        )
    }

    // Artist Search states
    var artistSearchQuery by remember { mutableStateOf("") }
    var artistSearchResults by remember { mutableStateOf<List<BrowseItem>>(emptyList()) }
    var isSearchingArtists by remember { mutableStateOf(false) }

    LaunchedEffect(artistSearchQuery) {
        val q = artistSearchQuery.trim()
        if (q.length >= 2) {
            isSearchingArtists = true
            scope.launch {
                val results = withContext(Dispatchers.IO) {
                    val searchItems = YtMusicRepository.search(q, SearchFilter.ARTISTS).getOrNull().orEmpty()
                    searchItems.mapNotNull { item ->
                        when (item) {
                            is SearchResult.Browse -> item.item
                            else -> null
                        }
                    }
                }
                artistSearchResults = results
                isSearchingArtists = false
            }
        } else {
            artistSearchResults = emptyList()
            isSearchingArtists = false
        }
    }

    Surface(
        modifier = modifier.fillMaxSize(),
        color = Color(0xFF0C0D10),
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .navigationBarsPadding(),
        ) {
            // Top Progress Indicator & Step Count
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 24.dp, vertical = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                // Step Dots
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (step in 1..4) {
                        val active = step <= currentStep
                        Box(
                            modifier = Modifier
                                .height(4.dp)
                                .width(if (step == currentStep) 32.dp else 16.dp)
                                .clip(RoundedCornerShape(2.dp))
                                .background(
                                    if (active) MaterialTheme.colorScheme.primary
                                    else Color.White.copy(alpha = 0.15f)
                                ),
                        )
                    }
                }

                Text(
                    text = "Step $currentStep of 4",
                    style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            // Wizard Animated Body
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth(),
            ) {
                AnimatedContent(
                    targetState = currentStep,
                    transitionSpec = {
                        if (targetState > initialState) {
                            (slideInHorizontally { width -> width } + fadeIn(tween(300)))
                                .togetherWith(slideOutHorizontally { width -> -width } + fadeOut(tween(300)))
                        } else {
                            (slideInHorizontally { width -> -width } + fadeIn(tween(300)))
                                .togetherWith(slideOutHorizontally { width -> width } + fadeOut(tween(300)))
                        }
                    },
                    label = "onboarding_steps",
                ) { step ->
                    when (step) {
                        1 -> StepAuthAndMigration(
                            isSignedIn = isSignedIn,
                            activeName = defaultName,
                            activeHandle = defaultHandle,
                            activeAvatar = existingAvatarUrl,
                            onContinueWithAccount = { currentStep = 2 },
                            onLaunchSignIn = onLaunchSignIn,
                            onContinueGuest = { currentStep = 2 },
                        )
                        2 -> StepGenresPicker(
                            curatedGenres = curatedGenres,
                            selectedGenres = selectedGenres,
                            onToggleGenre = { genre ->
                                if (selectedGenres.contains(genre)) selectedGenres.remove(genre)
                                else selectedGenres.add(genre)
                            },
                            onNext = { currentStep = 3 },
                            onBack = { currentStep = 1 },
                        )
                        3 -> StepArtistsPicker(
                            popularArtists = popularArtists,
                            selectedArtists = selectedArtists,
                            searchQuery = artistSearchQuery,
                            onQueryChange = { artistSearchQuery = it },
                            searchResults = artistSearchResults,
                            isSearching = isSearchingArtists,
                            onAddArtist = { artist ->
                                if (selectedArtists.none { it.name.equals(artist.name, ignoreCase = true) }) {
                                    selectedArtists.add(artist)
                                }
                            },
                            onRemoveArtist = { artist -> selectedArtists.remove(artist) },
                            onNext = { currentStep = 4 },
                            onBack = { currentStep = 2 },
                        )
                        4 -> StepIdentitySetup(
                            displayName = displayName,
                            onDisplayNameChange = { displayName = it },
                            handle = handle,
                            onHandleChange = { handle = it },
                            bio = bio,
                            onBioChange = { bio = it },
                            avatarUri = selectedAvatarUri,
                            existingAvatarUrl = existingAvatarUrl,
                            onPickAvatar = {
                                photoPickerLauncher.launch(
                                    PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
                                )
                            },
                            isSubmitting = isSubmitting,
                            onComplete = {
                                scope.launch {
                                    isSubmitting = true
                                    val userId = activeProfile?.profileId
                                        ?: activeSession?.accountId
                                        ?: AppSettings.deviceUserId

                                    // 1. Upload custom avatar if picked
                                    var finalAvatarUrl = existingAvatarUrl
                                    if (selectedAvatarUri != null) {
                                        val bytes = withContext(Dispatchers.IO) {
                                            context.contentResolver.openInputStream(selectedAvatarUri!!)?.use { it.readBytes() }
                                        }
                                        if (bytes != null) {
                                            val uploadResult = SupabaseService.uploadImage(bytes, "image/jpeg")
                                            uploadResult.getOrNull()?.let { finalAvatarUrl = it }
                                        }
                                    }

                                    // 2. Persist to AppSettings
                                    AppSettings.setOnboardingCompleted(true)
                                    AppSettings.setPreferredGenres(selectedGenres.toSet())

                                    // 3. Update Supabase profile (creates or merges profile row first)
                                    SupabaseService.updateUserProfile(
                                        userId = userId,
                                        displayName = displayName.trim(),
                                        handle = handle.trim().removePrefix("@"),
                                        bio = bio.trim(),
                                        avatarUrl = finalAvatarUrl,
                                    )

                                    // 4. Save Favorite Artists in Supabase
                                    selectedArtists.forEach { artist ->
                                        val thumb = artist.imageUrl ?: com.fortune.vibramusic.data.YtMusicRepository.getArtistThumbnail(artist.id, artist.name)
                                        SupabaseService.addFavoriteArtist(
                                            userId = userId,
                                            artist = QuizArtist(
                                                id = artist.id,
                                                name = artist.name,
                                                artworkUrl = thumb,
                                            ),
                                        )
                                    }

                                    // 5. Sync listening experience & trigger cloud backup
                                    SupabaseService.syncListeningExperience(
                                        userId = userId,
                                        spotifySpdcToken = AppSettings.spotifySpdcToken.value.takeIf { it.isNotBlank() },
                                        spotifyConnected = AppSettings.spotifySpdcToken.value.isNotBlank(),
                                        audioQuality = AppSettings.effectiveAudioQuality.name,
                                        equalizerEnabled = false,
                                        equalizerPreset = "FLAT",
                                        volumeNormalization = AppSettings.loudnessNormalization.value,
                                        bassBoostPercent = 0,
                                        virtualizerPercent = 0,
                                        pitchCents = 0,
                                        tempoMultiplier = 1.0f,
                                        autoSkipSilence = false,
                                        lyricsSource = "DEFAULT",
                                        canvasEnabled = AppSettings.animatedCanvas.value,
                                        preferredGenres = selectedGenres.toList(),
                                    )

                                    UserCloudSyncManager.backupAllUserData(userId)

                                    isSubmitting = false
                                    onComplete()
                                }
                            },
                            onBack = { currentStep = 3 },
                        )
                    }
                }
            }
        }
    }
}

/**
 * Step 1: YouTube Authentication & Existing User Session Migration
 */
@Composable
private fun StepAuthAndMigration(
    isSignedIn: Boolean,
    activeName: String,
    activeHandle: String,
    activeAvatar: String?,
    onContinueWithAccount: () -> Unit,
    onLaunchSignIn: () -> Unit,
    onContinueGuest: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        // App / Logo Header
        Box(
            modifier = Modifier
                .size(76.dp)
                .clip(CircleShape)
                .background(
                    Brush.radialGradient(
                        listOf(
                            MaterialTheme.colorScheme.primary.copy(alpha = 0.35f),
                            Color.Transparent,
                        )
                    )
                )
                .border(1.5.dp, MaterialTheme.colorScheme.primary.copy(alpha = 0.6f), CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = Icons.Rounded.MusicNote,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(38.dp),
            )
        }

        Spacer(Modifier.height(24.dp))

        if (isSignedIn) {
            Text(
                text = "Welcome to Vibra Music",
                style = MaterialTheme.typography.headlineMedium.copy(fontWeight = FontWeight.Bold),
                color = MaterialTheme.colorScheme.onSurface,
                textAlign = TextAlign.Center,
            )

            Spacer(Modifier.height(8.dp))

            Text(
                text = "We detected your active YouTube account. Your library, liked tracks, and listening experience are ready to sync.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
                lineHeight = 20.sp,
            )

            Spacer(Modifier.height(28.dp))

            // User Identity Card
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(16.dp))
                    .background(Color(0xFF16181E))
                    .border(1.dp, MaterialTheme.colorScheme.primary.copy(alpha = 0.3f), RoundedCornerShape(16.dp))
                    .padding(16.dp),
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Box(
                        modifier = Modifier
                            .size(52.dp)
                            .clip(CircleShape)
                            .background(MaterialTheme.colorScheme.surfaceVariant),
                        contentAlignment = Alignment.Center,
                    ) {
                        if (activeAvatar != null) {
                            AsyncImage(
                                model = activeAvatar,
                                contentDescription = null,
                                contentScale = ContentScale.Crop,
                                modifier = Modifier.fillMaxSize(),
                            )
                        } else {
                            Icon(
                                imageVector = Icons.Rounded.Person,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(28.dp),
                            )
                        }
                    }

                    Spacer(Modifier.width(14.dp))

                    Column(Modifier.weight(1f)) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            Text(
                                text = activeName,
                                style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                                color = MaterialTheme.colorScheme.onSurface,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            Icon(
                                imageVector = Icons.Rounded.CheckCircle,
                                contentDescription = "Connected",
                                tint = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.size(16.dp),
                            )
                        }
                        Text(
                            text = "@$activeHandle",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }

            Spacer(Modifier.height(32.dp))

            Button(
                onClick = onContinueWithAccount,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(52.dp),
                shape = RoundedCornerShape(14.dp),
                colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.primary),
            ) {
                Text(
                    text = "Continue as $activeName",
                    style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Bold),
                    color = MaterialTheme.colorScheme.onPrimary,
                )
            }

            Spacer(Modifier.height(12.dp))

            TextButton(
                onClick = onLaunchSignIn,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(
                    text = "Switch Google / YouTube Account",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.primary,
                )
            }
        } else {
            Text(
                text = "Connect Your Music",
                style = MaterialTheme.typography.headlineMedium.copy(fontWeight = FontWeight.Bold),
                color = MaterialTheme.colorScheme.onSurface,
                textAlign = TextAlign.Center,
            )

            Spacer(Modifier.height(8.dp))

            Text(
                text = "Connect your YouTube account to unlock your library, personalized playlists, and sync with the Vibra Social community.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
                lineHeight = 20.sp,
            )

            Spacer(Modifier.height(36.dp))

            Button(
                onClick = onLaunchSignIn,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(52.dp),
                shape = RoundedCornerShape(14.dp),
                colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.primary),
            ) {
                Icon(
                    imageVector = Icons.Rounded.PlayArrow,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onPrimary,
                    modifier = Modifier.size(20.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    text = "Connect with YouTube",
                    style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Bold),
                    color = MaterialTheme.colorScheme.onPrimary,
                )
            }

            Spacer(Modifier.height(14.dp))

            OutlinedButton(
                onClick = onContinueGuest,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(52.dp),
                shape = RoundedCornerShape(14.dp),
            ) {
                Text(
                    text = "Continue as Guest",
                    style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Medium),
                    color = MaterialTheme.colorScheme.onSurface,
                )
            }
        }
    }
}

/**
 * Step 2: Preferred Music Genres Grid
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun StepGenresPicker(
    curatedGenres: List<GenreItem>,
    selectedGenres: List<String>,
    onToggleGenre: (String) -> Unit,
    onNext: () -> Unit,
    onBack: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 24.dp),
    ) {
        Text(
            text = "What do you love listening to?",
            style = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.Bold),
            color = MaterialTheme.colorScheme.onSurface,
        )

        Spacer(Modifier.height(6.dp))

        Text(
            text = "Select genres to tailor your daily discovery, social feed, and quiz matches.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Spacer(Modifier.height(20.dp))

        LazyColumn(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            items(curatedGenres.chunked(2)) { pair ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    pair.forEach { genre ->
                        val isSelected = selectedGenres.contains(genre.name)
                        val animBg by animateColorAsState(
                            targetValue = if (isSelected) MaterialTheme.colorScheme.primary.copy(alpha = 0.18f)
                            else Color(0xFF16181E),
                            label = "genre_bg",
                        )
                        val animBorder by animateColorAsState(
                            targetValue = if (isSelected) MaterialTheme.colorScheme.primary
                            else Color.White.copy(alpha = 0.08f),
                            label = "genre_border",
                        )

                        Box(
                            modifier = Modifier
                                .weight(1f)
                                .height(64.dp)
                                .clip(RoundedCornerShape(14.dp))
                                .background(animBg)
                                .border(1.2.dp, animBorder, RoundedCornerShape(14.dp))
                                .clickable { onToggleGenre(genre.name) }
                                .padding(horizontal = 14.dp),
                            contentAlignment = Alignment.CenterStart,
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.SpaceBetween,
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    modifier = Modifier.weight(1f),
                                ) {
                                    Icon(
                                        imageVector = genre.icon,
                                        contentDescription = null,
                                        tint = if (isSelected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                                        modifier = Modifier.size(20.dp),
                                    )
                                    Spacer(Modifier.width(10.dp))
                                    Text(
                                        text = genre.name,
                                        style = MaterialTheme.typography.bodyMedium.copy(
                                            fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Medium
                                        ),
                                        color = if (isSelected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }

                                if (isSelected) {
                                    Icon(
                                        imageVector = Icons.Rounded.Check,
                                        contentDescription = "Selected",
                                        tint = MaterialTheme.colorScheme.primary,
                                        modifier = Modifier.size(18.dp),
                                    )
                                }
                            }
                        }
                    }
                    if (pair.size == 1) {
                        Spacer(Modifier.weight(1f))
                    }
                }
            }
        }

        Spacer(Modifier.height(16.dp))

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OutlinedButton(
                onClick = onBack,
                modifier = Modifier
                    .weight(0.4f)
                    .height(50.dp),
                shape = RoundedCornerShape(14.dp),
            ) {
                Text("Back")
            }

            Button(
                onClick = onNext,
                modifier = Modifier
                    .weight(0.6f)
                    .height(50.dp),
                shape = RoundedCornerShape(14.dp),
                colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.primary),
            ) {
                Text(
                    text = if (selectedGenres.isEmpty()) "Skip for now" else "Continue (${selectedGenres.size})",
                    fontWeight = FontWeight.Bold,
                )
            }
        }

        Spacer(Modifier.height(16.dp))
    }
}

/**
 * Step 3: Favorite Artists Picker (Curated + Live YouTube Search)
 */
@Composable
private fun StepArtistsPicker(
    popularArtists: List<SelectedArtist>,
    selectedArtists: List<SelectedArtist>,
    searchQuery: String,
    onQueryChange: (String) -> Unit,
    searchResults: List<BrowseItem>,
    isSearching: Boolean,
    onAddArtist: (SelectedArtist) -> Unit,
    onRemoveArtist: (SelectedArtist) -> Unit,
    onNext: () -> Unit,
    onBack: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 24.dp),
    ) {
        Text(
            text = "Pick your favorite artists",
            style = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.Bold),
            color = MaterialTheme.colorScheme.onSurface,
        )

        Spacer(Modifier.height(6.dp))

        Text(
            text = "Follow artists to build your personalized vibe and unlock customized music quizzes.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Spacer(Modifier.height(16.dp))

        // Selected Artists Chips Row
        if (selectedArtists.isNotEmpty()) {
            LazyRow(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                contentPadding = PaddingValues(vertical = 4.dp),
            ) {
                items(selectedArtists, key = { it.name }) { artist ->
                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(20.dp))
                            .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.2f))
                            .border(1.dp, MaterialTheme.colorScheme.primary.copy(alpha = 0.5f), RoundedCornerShape(20.dp))
                            .clickable { onRemoveArtist(artist) }
                            .padding(horizontal = 12.dp, vertical = 6.dp),
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            Text(
                                text = artist.name,
                                style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                                color = MaterialTheme.colorScheme.primary,
                            )
                            Icon(
                                imageVector = Icons.Rounded.Close,
                                contentDescription = "Remove",
                                tint = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.size(14.dp),
                            )
                        }
                    }
                }
            }
            Spacer(Modifier.height(12.dp))
        }

        // Live Search Input Box
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(14.dp))
                .background(Color(0xFF16181E))
                .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(14.dp))
                .padding(horizontal = 14.dp, vertical = 12.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(
                    imageVector = Icons.Rounded.Search,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(20.dp),
                )
                Spacer(Modifier.width(10.dp))
                BasicTextField(
                    value = searchQuery,
                    onValueChange = onQueryChange,
                    textStyle = TextStyle(
                        color = MaterialTheme.colorScheme.onSurface,
                        fontSize = 15.sp,
                    ),
                    cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                    modifier = Modifier.weight(1f),
                    decorationBox = { inner ->
                        if (searchQuery.isEmpty()) {
                            Text(
                                text = "Search any artist on YouTube Music...",
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                            )
                        }
                        inner()
                    },
                )
                if (isSearching) {
                    CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                } else if (searchQuery.isNotEmpty()) {
                    IconButton(
                        onClick = { onQueryChange("") },
                        modifier = Modifier.size(20.dp),
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

        Spacer(Modifier.height(14.dp))

        // Search Results or Curated Popular Artists
        LazyColumn(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (searchQuery.isNotBlank() && searchResults.isNotEmpty()) {
                item {
                    Text(
                        text = "Search Results",
                        style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.padding(vertical = 4.dp),
                    )
                }
                items(searchResults) { browse ->
                    val isAdded = selectedArtists.any { it.name.equals(browse.title, ignoreCase = true) }
                    ArtistPickerRow(
                        name = browse.title,
                        subtitle = browse.subtitle,
                        avatarUrl = browse.thumbnailUrl,
                        isAdded = isAdded,
                        onToggle = {
                            if (isAdded) {
                                selectedArtists.firstOrNull { it.name.equals(browse.title, ignoreCase = true) }
                                    ?.let(onRemoveArtist)
                            } else {
                                onAddArtist(SelectedArtist(browse.browseId, browse.title, browse.thumbnailUrl))
                            }
                        },
                    )
                }
            } else {
                item {
                    Text(
                        text = "Popular Artists",
                        style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(vertical = 4.dp),
                    )
                }
                items(popularArtists) { artist ->
                    val isAdded = selectedArtists.any { it.name.equals(artist.name, ignoreCase = true) }
                    ArtistPickerRow(
                        name = artist.name,
                        subtitle = "Artist",
                        avatarUrl = null,
                        isAdded = isAdded,
                        onToggle = {
                            if (isAdded) onRemoveArtist(artist)
                            else onAddArtist(artist)
                        },
                    )
                }
            }
        }

        Spacer(Modifier.height(16.dp))

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OutlinedButton(
                onClick = onBack,
                modifier = Modifier
                    .weight(0.4f)
                    .height(50.dp),
                shape = RoundedCornerShape(14.dp),
            ) {
                Text("Back")
            }

            Button(
                onClick = onNext,
                modifier = Modifier
                    .weight(0.6f)
                    .height(50.dp),
                shape = RoundedCornerShape(14.dp),
                colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.primary),
            ) {
                Text(
                    text = if (selectedArtists.isEmpty()) "Skip for now" else "Continue (${selectedArtists.size})",
                    fontWeight = FontWeight.Bold,
                )
            }
        }

        Spacer(Modifier.height(16.dp))
    }
}

@Composable
private fun ArtistPickerRow(
    name: String,
    subtitle: String,
    avatarUrl: String?,
    isAdded: Boolean,
    onToggle: () -> Unit,
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(Color(0xFF16181E))
            .border(1.dp, Color.White.copy(alpha = 0.06f), RoundedCornerShape(12.dp))
            .clickable(onClick = onToggle)
            .padding(12.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth(),
        ) {
            ArtistAvatar(
                artistName = name,
                artworkUrl = avatarUrl,
                size = 44.dp,
            )

            Spacer(Modifier.width(14.dp))

            Column(Modifier.weight(1f)) {
                Text(
                    text = name,
                    style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Bold),
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }

            Box(
                modifier = Modifier
                    .size(34.dp)
                    .clip(CircleShape)
                    .background(
                        if (isAdded) MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f)
                    ),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = if (isAdded) Icons.Rounded.Check else Icons.Rounded.Add,
                    contentDescription = null,
                    tint = if (isAdded) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
    }
}

/**
 * Step 4: Social Identity, Profile Details & 5 Quiz Lives Grant
 */
@Composable
private fun StepIdentitySetup(
    displayName: String,
    onDisplayNameChange: (String) -> Unit,
    handle: String,
    onHandleChange: (String) -> Unit,
    bio: String,
    onBioChange: (String) -> Unit,
    avatarUri: Uri?,
    existingAvatarUrl: String?,
    onPickAvatar: () -> Unit,
    isSubmitting: Boolean,
    onComplete: () -> Unit,
    onBack: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 24.dp),
    ) {
        Text(
            text = "Set up your social identity",
            style = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.Bold),
            color = MaterialTheme.colorScheme.onSurface,
        )

        Spacer(Modifier.height(6.dp))

        Text(
            text = "Your profile in the Vibra Social sphere: share music, participate in threads, and challenge friends.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Spacer(Modifier.height(20.dp))

        LazyColumn(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            // Avatar picker
            item {
                Box(
                    modifier = Modifier.fillMaxWidth(),
                    contentAlignment = Alignment.Center,
                ) {
                    Box(
                        modifier = Modifier
                            .size(92.dp)
                            .clip(CircleShape)
                            .background(MaterialTheme.colorScheme.surfaceVariant)
                            .border(2.dp, MaterialTheme.colorScheme.primary, CircleShape)
                            .clickable(onClick = onPickAvatar),
                        contentAlignment = Alignment.Center,
                    ) {
                        if (avatarUri != null) {
                            AsyncImage(
                                model = avatarUri,
                                contentDescription = null,
                                contentScale = ContentScale.Crop,
                                modifier = Modifier.fillMaxSize(),
                            )
                        } else if (existingAvatarUrl != null) {
                            AsyncImage(
                                model = existingAvatarUrl,
                                contentDescription = null,
                                contentScale = ContentScale.Crop,
                                modifier = Modifier.fillMaxSize(),
                            )
                        } else {
                            Icon(
                                imageVector = Icons.Rounded.Person,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(44.dp),
                            )
                        }

                        // Camera overlay badge
                        Box(
                            modifier = Modifier
                                .align(Alignment.BottomEnd)
                                .size(28.dp)
                                .clip(CircleShape)
                                .background(MaterialTheme.colorScheme.primary),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.CameraAlt,
                                contentDescription = "Change Avatar",
                                tint = MaterialTheme.colorScheme.onPrimary,
                                modifier = Modifier.size(16.dp),
                            )
                        }
                    }
                }
            }

            // Display Name
            item {
                OutlinedTextField(
                    value = displayName,
                    onValueChange = onDisplayNameChange,
                    label = { Text("Display Name") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(14.dp),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = MaterialTheme.colorScheme.primary,
                        unfocusedBorderColor = Color.White.copy(alpha = 0.12f),
                    ),
                )
            }

            // Handle
            item {
                OutlinedTextField(
                    value = handle,
                    onValueChange = onHandleChange,
                    label = { Text("Username / Handle") },
                    prefix = { Text("@") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(14.dp),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = MaterialTheme.colorScheme.primary,
                        unfocusedBorderColor = Color.White.copy(alpha = 0.12f),
                    ),
                )
            }

            // Bio
            item {
                OutlinedTextField(
                    value = bio,
                    onValueChange = onBioChange,
                    label = { Text("Bio") },
                    maxLines = 3,
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(14.dp),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = MaterialTheme.colorScheme.primary,
                        unfocusedBorderColor = Color.White.copy(alpha = 0.12f),
                    ),
                )
            }

            // Bonus Gift Card: +5 Quiz Lives
            item {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(16.dp))
                        .background(
                            Brush.linearGradient(
                                listOf(
                                    MaterialTheme.colorScheme.primary.copy(alpha = 0.2f),
                                    MaterialTheme.colorScheme.secondary.copy(alpha = 0.12f),
                                )
                            )
                        )
                        .border(1.dp, MaterialTheme.colorScheme.primary.copy(alpha = 0.4f), RoundedCornerShape(16.dp))
                        .padding(16.dp),
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Box(
                            modifier = Modifier
                                .size(46.dp)
                                .clip(CircleShape)
                                .background(MaterialTheme.colorScheme.primary),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.Stars,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onPrimary,
                                modifier = Modifier.size(26.dp),
                            )
                        }

                        Spacer(Modifier.width(14.dp))

                        Column(Modifier.weight(1f)) {
                            Text(
                                text = "Welcome Bonus: +5 Quiz Lives",
                                style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Bold),
                                color = MaterialTheme.colorScheme.onSurface,
                            )
                            Spacer(Modifier.height(2.dp))
                            Text(
                                text = "Use your bonus lives in the Vibra Music Quiz to test your track knowledge and climb global rankings.",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
            }
        }

        Spacer(Modifier.height(16.dp))

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OutlinedButton(
                onClick = onBack,
                enabled = !isSubmitting,
                modifier = Modifier
                    .weight(0.35f)
                    .height(52.dp),
                shape = RoundedCornerShape(14.dp),
            ) {
                Text("Back")
            }

            Button(
                onClick = onComplete,
                enabled = !isSubmitting && displayName.isNotBlank() && handle.isNotBlank(),
                modifier = Modifier
                    .weight(0.65f)
                    .height(52.dp),
                shape = RoundedCornerShape(14.dp),
                colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.primary),
            ) {
                if (isSubmitting) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(22.dp),
                        strokeWidth = 2.dp,
                        color = MaterialTheme.colorScheme.onPrimary,
                    )
                } else {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Text(
                            text = "Enter Vibra Music",
                            style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Bold),
                            color = MaterialTheme.colorScheme.onPrimary,
                        )
                        Icon(
                            imageVector = Icons.AutoMirrored.Rounded.ArrowForward,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.onPrimary,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                }
            }
        }

        Spacer(Modifier.height(16.dp))
    }
}
