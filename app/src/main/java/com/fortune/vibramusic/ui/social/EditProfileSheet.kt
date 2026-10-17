package com.fortune.vibramusic.ui.social

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
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
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Album
import androidx.compose.material.icons.rounded.CameraAlt
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Image
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.QueueMusic
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ElevatedButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
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
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import coil3.compose.AsyncImage
import com.fortune.vibramusic.data.YtMusicRepository
import com.fortune.vibramusic.data.model.BrowseItem
import com.fortune.vibramusic.data.model.SearchFilter
import com.fortune.vibramusic.data.model.SearchResult
import com.fortune.vibramusic.data.social.SocialProfile
import com.fortune.vibramusic.data.supabase.SupabaseService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Full-screen Profile Editor with playlist banner showcase picker.
 */
@Composable
fun EditProfileSheet(
    profile: SocialProfile,
    onDismiss: () -> Unit,
    onSaveProfile: (
        displayName: String,
        handle: String,
        bio: String,
        avatarUrl: String?,
        country: String,
        age: Int?,
        statusBubble: String,
        bannerPlaylists: List<String>,
    ) -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var displayName by remember { mutableStateOf(profile.displayName) }
    var handle by remember { mutableStateOf(profile.handle) }
    var bio by remember { mutableStateOf(profile.bio) }
    var country by remember { mutableStateOf(profile.country) }
    var ageText by remember { mutableStateOf(profile.age?.toString() ?: "") }
    var statusBubble by remember { mutableStateOf(profile.statusBubble) }
    var bannerPlaylists by remember { mutableStateOf(profile.bannerPlaylists.take(15)) }
    var selectedAvatarUri by remember { mutableStateOf<Uri?>(null) }
    var isSaving by remember { mutableStateOf(false) }

    // Playlist Search states for Banner
    var playlistQuery by remember { mutableStateOf("") }
    var playlistSearchResults by remember { mutableStateOf<List<BrowseItem>>(emptyList()) }
    var isSearchingPlaylists by remember { mutableStateOf(false) }

    val photoPickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickVisualMedia(),
    ) { uri ->
        if (uri != null) {
            selectedAvatarUri = uri
        }
    }

    val bannerImagePickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickVisualMedia(),
    ) { uri ->
        if (uri != null && bannerPlaylists.size < 15) {
            scope.launch {
                val bytes = withContext(Dispatchers.IO) {
                    context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                }
                if (bytes != null) {
                    SupabaseService.uploadImage(bytes = bytes, mimeType = "image/jpeg").onSuccess { uploadedUrl ->
                        bannerPlaylists = (bannerPlaylists + uploadedUrl).take(15)
                    }
                }
            }
        }
    }

    // Debounced search for playlists
    LaunchedEffect(playlistQuery) {
        val q = playlistQuery.trim()
        if (q.length >= 2) {
            isSearchingPlaylists = true
            scope.launch {
                val results = withContext(Dispatchers.IO) {
                    val searchItems = YtMusicRepository.search(q, SearchFilter.PLAYLISTS).getOrNull().orEmpty()
                    searchItems.mapNotNull { item ->
                        when (item) {
                            is SearchResult.Browse -> item.item
                            else -> null
                        }
                    }
                }
                playlistSearchResults = results
                isSearchingPlaylists = false
            }
        } else {
            playlistSearchResults = emptyList()
            isSearchingPlaylists = false
        }
    }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            decorFitsSystemWindows = false,
        ),
    ) {
        Surface(
            modifier = Modifier.fillMaxSize(),
            color = MaterialTheme.colorScheme.background,
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .statusBarsPadding()
                    .navigationBarsPadding(),
            ) {
                // Top App Bar
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 12.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconButton(
                        onClick = onDismiss,
                        modifier = Modifier
                            .size(38.dp)
                            .clip(CircleShape)
                            .background(MaterialTheme.colorScheme.surfaceVariant),
                    ) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Rounded.ArrowBack,
                            contentDescription = "Cancel",
                            tint = MaterialTheme.colorScheme.onSurface,
                            modifier = Modifier.size(20.dp),
                        )
                    }

                    Text(
                        text = "Edit Profile",
                        style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold),
                        color = MaterialTheme.colorScheme.onSurface,
                    )

                    ElevatedButton(
                        onClick = {
                            scope.launch {
                                isSaving = true
                                var finalAvatarUrl = profile.avatarUrl

                                if (selectedAvatarUri != null) {
                                    runCatching {
                                        val bytes = withContext(Dispatchers.IO) {
                                            context.contentResolver.openInputStream(selectedAvatarUri!!)?.use { it.readBytes() }
                                        }
                                        if (bytes != null) {
                                            val uploadRes = SupabaseService.uploadImage(
                                                bytes = bytes,
                                                mimeType = "image/jpeg",
                                            )
                                            uploadRes.getOrNull()?.let { finalAvatarUrl = it }
                                        }
                                    }
                                }

                                val parsedAge = ageText.trim().toIntOrNull()
                                onSaveProfile(
                                    displayName.trim(),
                                    handle.trim().removePrefix("@"),
                                    bio.trim(),
                                    finalAvatarUrl,
                                    country.trim(),
                                    parsedAge,
                                    statusBubble.trim(),
                                    bannerPlaylists,
                                )
                                isSaving = false
                                onDismiss()
                            }
                        },
                        enabled = !isSaving && displayName.isNotBlank() && handle.isNotBlank(),
                        shape = RoundedCornerShape(14.dp),
                        colors = ButtonDefaults.elevatedButtonColors(
                            containerColor = MaterialTheme.colorScheme.primary,
                            contentColor = MaterialTheme.colorScheme.onPrimary,
                        ),
                    ) {
                        if (isSaving) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(16.dp),
                                color = MaterialTheme.colorScheme.onPrimary,
                                strokeWidth = 2.dp,
                            )
                        } else {
                            Text("Save", fontWeight = FontWeight.Bold)
                        }
                    }
                }

                // Scrollable Form Body
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth()
                        .verticalScroll(rememberScrollState())
                        .padding(horizontal = 20.dp, vertical = 8.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    // Profile Avatar Section
                    Box(
                        modifier = Modifier.size(100.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Box(
                            modifier = Modifier
                                .matchParentSize()
                                .clip(CircleShape)
                                .clickable {
                                    photoPickerLauncher.launch(
                                        PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly),
                                    )
                                },
                            contentAlignment = Alignment.Center,
                        ) {
                            if (selectedAvatarUri != null) {
                                AsyncImage(
                                    model = selectedAvatarUri,
                                    contentDescription = "New Avatar",
                                    contentScale = ContentScale.Crop,
                                    modifier = Modifier.matchParentSize(),
                                )
                            } else if (!profile.avatarUrl.isNullOrBlank()) {
                                AsyncImage(
                                    model = profile.avatarUrl,
                                    contentDescription = "Current Avatar",
                                    contentScale = ContentScale.Crop,
                                    modifier = Modifier.matchParentSize(),
                                )
                            } else {
                                Box(
                                    modifier = Modifier
                                        .matchParentSize()
                                        .background(MaterialTheme.colorScheme.surfaceVariant),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    Icon(
                                        imageVector = Icons.Rounded.Person,
                                        contentDescription = null,
                                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                        modifier = Modifier.size(52.dp),
                                    )
                                }
                            }
                        }

                        // Camera change badge
                        Box(
                            modifier = Modifier
                                .size(34.dp)
                                .align(Alignment.BottomEnd)
                                .clip(CircleShape)
                                .background(MaterialTheme.colorScheme.primary)
                                .border(2.dp, MaterialTheme.colorScheme.background, CircleShape)
                                .clickable {
                                    photoPickerLauncher.launch(
                                        PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly),
                                    )
                                },
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.CameraAlt,
                                contentDescription = "Change photo",
                                tint = MaterialTheme.colorScheme.onPrimary,
                                modifier = Modifier.size(18.dp),
                            )
                        }
                    }

                    Spacer(Modifier.height(8.dp))
                    Text(
                        text = "Change Profile Photo",
                        style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.clickable {
                            photoPickerLauncher.launch(
                                PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly),
                            )
                        },
                    )

                    Spacer(Modifier.height(24.dp))

                    // Display Name Field
                    FormField(
                        label = "Display Name",
                        value = displayName,
                        onValueChange = { displayName = it },
                        placeholder = "Your name",
                    )

                    Spacer(Modifier.height(16.dp))

                    // Handle Field
                    FormField(
                        label = "Handle",
                        value = handle,
                        onValueChange = { handle = it },
                        placeholder = "username",
                        prefix = "@",
                    )

                    Spacer(Modifier.height(16.dp))

                    // Bio Field
                    Column(modifier = Modifier.fillMaxWidth()) {
                        Text(
                            text = "Bio",
                            style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Spacer(Modifier.height(6.dp))
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(80.dp)
                                .clip(RoundedCornerShape(14.dp))
                                .background(MaterialTheme.colorScheme.surfaceVariant)
                                .padding(horizontal = 14.dp, vertical = 12.dp),
                        ) {
                            if (bio.isEmpty()) {
                                Text(
                                    text = "Tell the community about your music taste...",
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                                )
                            }
                            BasicTextField(
                                value = bio,
                                onValueChange = { if (it.length <= 160) bio = it },
                                textStyle = TextStyle(
                                    color = MaterialTheme.colorScheme.onSurface,
                                    fontSize = 14.sp,
                                ),
                                cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                                modifier = Modifier.fillMaxSize(),
                            )
                        }
                        Spacer(Modifier.height(4.dp))
                        Text(
                            text = "${bio.length}/160",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.align(Alignment.End),
                        )
                    }

                    Spacer(Modifier.height(14.dp))

                    // Status Bubble (Thought Bubble) Field
                    FormField(
                        label = "Thought Status Bubble (shown above your avatar)",
                        value = statusBubble,
                        onValueChange = { if (it.length <= 40) statusBubble = it },
                        placeholder = "What is on your mind? e.g. Vibing to Drake",
                    )

                    Spacer(Modifier.height(16.dp))

                    // Country & Age Row
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Box(modifier = Modifier.weight(1.4f)) {
                            FormField(
                                label = "Country",
                                value = country,
                                onValueChange = { country = it },
                                placeholder = "e.g. United States",
                            )
                        }

                        Box(modifier = Modifier.weight(0.8f)) {
                            FormField(
                                label = "Age",
                                value = ageText,
                                onValueChange = {
                                    if (it.all { ch -> ch.isDigit() } && it.length <= 3) {
                                        ageText = it
                                    }
                                },
                                placeholder = "Age",
                            )
                        }
                    }

                    Spacer(Modifier.height(24.dp))

                    // Banner Playlist Showcase Section (Up to 15)
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(16.dp))
                            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f))
                            .border(1.dp, MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(16.dp))
                            .padding(16.dp),
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column {
                                Text(
                                    text = "Banner Playlists (${bannerPlaylists.size}/15)",
                                    style = MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.Bold),
                                    color = MaterialTheme.colorScheme.onSurface,
                                )
                                Text(
                                    text = "Add up to 15 playlist and album covers for users to tap and play.",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }

                        Spacer(Modifier.height(14.dp))

                        // Current Added Banner Playlists Row
                        if (bannerPlaylists.isNotEmpty()) {
                            LazyRow(
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                itemsIndexed(bannerPlaylists) { idx, entry ->
                                    val parts = entry.split("|")
                                    val coverUrl = if (parts.size >= 3) parts[2] else entry
                                    val title = if (parts.size >= 2) parts[1] else "Playlist"

                                    Box(
                                        modifier = Modifier
                                            .size(72.dp)
                                            .clip(RoundedCornerShape(12.dp))
                                            .background(MaterialTheme.colorScheme.surface),
                                    ) {
                                        AsyncImage(
                                            model = coverUrl,
                                            contentDescription = title,
                                            contentScale = ContentScale.Crop,
                                            modifier = Modifier.fillMaxSize(),
                                        )

                                        Box(
                                            modifier = Modifier
                                                .align(Alignment.TopEnd)
                                                .padding(3.dp)
                                                .size(20.dp)
                                                .clip(CircleShape)
                                                .background(Color.Black.copy(alpha = 0.75f))
                                                .clickable {
                                                    bannerPlaylists = bannerPlaylists.filterIndexed { i, _ -> i != idx }
                                                },
                                            contentAlignment = Alignment.Center,
                                        ) {
                                            Icon(
                                                imageVector = Icons.Rounded.Close,
                                                contentDescription = "Remove",
                                                tint = Color.White,
                                                modifier = Modifier.size(12.dp),
                                            )
                                        }
                                    }
                                }
                            }
                            Spacer(Modifier.height(14.dp))
                        }

                        // Playlist Search Bar
                        if (bannerPlaylists.size < 15) {
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(MaterialTheme.colorScheme.surface)
                                    .border(1.dp, MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(12.dp))
                                    .padding(horizontal = 12.dp, vertical = 10.dp),
                            ) {
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    modifier = Modifier.fillMaxWidth(),
                                ) {
                                    Icon(
                                        imageVector = Icons.Rounded.Search,
                                        contentDescription = null,
                                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                        modifier = Modifier.size(18.dp),
                                    )
                                    Spacer(Modifier.width(8.dp))
                                    BasicTextField(
                                        value = playlistQuery,
                                        onValueChange = { playlistQuery = it },
                                        textStyle = TextStyle(
                                            color = MaterialTheme.colorScheme.onSurface,
                                            fontSize = 13.sp,
                                        ),
                                        cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                                        modifier = Modifier.weight(1f),
                                        decorationBox = { inner ->
                                            if (playlistQuery.isEmpty()) {
                                                Text(
                                                    text = "Search playlists or albums on YouTube Music...",
                                                    style = MaterialTheme.typography.bodySmall,
                                                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                                                )
                                            }
                                            inner()
                                        },
                                    )
                                    if (isSearchingPlaylists) {
                                        CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                                    } else if (playlistQuery.isNotEmpty()) {
                                        IconButton(
                                            onClick = { playlistQuery = "" },
                                            modifier = Modifier.size(20.dp),
                                        ) {
                                            Icon(
                                                imageVector = Icons.Rounded.Close,
                                                contentDescription = "Clear",
                                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                                modifier = Modifier.size(14.dp),
                                            )
                                        }
                                    }
                                }
                            }

                            // Search Results Dropdown/Row
                            AnimatedVisibility(visible = playlistSearchResults.isNotEmpty()) {
                                Column(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(top = 8.dp),
                                    verticalArrangement = Arrangement.spacedBy(6.dp),
                                ) {
                                    playlistSearchResults.take(5).forEach { browse ->
                                        Row(
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .clip(RoundedCornerShape(10.dp))
                                                .background(MaterialTheme.colorScheme.surface)
                                                .clickable {
                                                    val serialized = "${browse.browseId}|${browse.title}|${browse.thumbnailUrl.orEmpty()}"
                                                    if (bannerPlaylists.none { it.startsWith("${browse.browseId}|") }) {
                                                        bannerPlaylists = (bannerPlaylists + serialized).take(15)
                                                    }
                                                    playlistQuery = ""
                                                    playlistSearchResults = emptyList()
                                                }
                                                .padding(8.dp),
                                            verticalAlignment = Alignment.CenterVertically,
                                        ) {
                                            Box(
                                                modifier = Modifier
                                                    .size(42.dp)
                                                    .clip(RoundedCornerShape(8.dp))
                                                    .background(MaterialTheme.colorScheme.surfaceVariant),
                                            ) {
                                                if (!browse.thumbnailUrl.isNullOrBlank()) {
                                                    AsyncImage(
                                                        model = browse.thumbnailUrl,
                                                        contentDescription = null,
                                                        contentScale = ContentScale.Crop,
                                                        modifier = Modifier.fillMaxSize(),
                                                    )
                                                } else {
                                                    Icon(
                                                        imageVector = Icons.Rounded.QueueMusic,
                                                        contentDescription = null,
                                                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                                        modifier = Modifier
                                                            .size(22.dp)
                                                            .align(Alignment.Center),
                                                    )
                                                }
                                            }

                                            Spacer(Modifier.width(10.dp))

                                            Column(modifier = Modifier.weight(1f)) {
                                                Text(
                                                    text = browse.title,
                                                    style = MaterialTheme.typography.bodySmall.copy(fontWeight = FontWeight.Bold),
                                                    color = MaterialTheme.colorScheme.onSurface,
                                                    maxLines = 1,
                                                    overflow = TextOverflow.Ellipsis,
                                                )
                                                Text(
                                                    text = browse.subtitle.ifBlank { "Playlist" },
                                                    style = MaterialTheme.typography.labelSmall,
                                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                                    maxLines = 1,
                                                )
                                            }

                                            Icon(
                                                imageVector = Icons.Rounded.Add,
                                                contentDescription = "Add",
                                                tint = MaterialTheme.colorScheme.primary,
                                                modifier = Modifier.size(18.dp),
                                            )
                                        }
                                    }
                                }
                            }

                            Spacer(Modifier.height(8.dp))

                            // Or custom upload button
                            OutlinedButton(
                                onClick = {
                                    bannerImagePickerLauncher.launch(
                                        PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly),
                                    )
                                },
                                shape = RoundedCornerShape(10.dp),
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                Icon(imageVector = Icons.Rounded.Image, contentDescription = null, modifier = Modifier.size(16.dp))
                                Spacer(Modifier.width(6.dp))
                                Text("Upload Custom Cover Image", fontSize = 12.sp)
                            }
                        }
                    }

                    Spacer(Modifier.height(30.dp))
                }
            }
        }
    }
}

@Composable
private fun FormField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    prefix: String? = null,
) {
    Column(modifier = Modifier.fillMaxWidth()) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(6.dp))
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(14.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant)
                .padding(horizontal = 14.dp, vertical = 12.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (prefix != null) {
                    Text(
                        text = prefix,
                        style = TextStyle(
                            color = MaterialTheme.colorScheme.primary,
                            fontSize = 15.sp,
                            fontWeight = FontWeight.Bold,
                        ),
                    )
                    Spacer(Modifier.width(2.dp))
                }
                Box(modifier = Modifier.weight(1f)) {
                    if (value.isEmpty()) {
                        Text(
                            text = placeholder,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                        )
                    }
                    BasicTextField(
                        value = value,
                        onValueChange = onValueChange,
                        textStyle = TextStyle(
                            color = MaterialTheme.colorScheme.onSurface,
                            fontSize = 15.sp,
                        ),
                        cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        }
    }
}
