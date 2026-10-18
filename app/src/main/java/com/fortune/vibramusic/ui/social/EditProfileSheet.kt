package com.fortune.vibramusic.ui.social

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.widget.Toast
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
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.CameraAlt
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.Image
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.Videocam
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
import androidx.compose.ui.graphics.asImageBitmap
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
import com.fortune.vibramusic.data.social.SocialProfile
import com.fortune.vibramusic.data.supabase.SupabaseService
import com.fortune.vibramusic.ui.components.MediaCropAdjustDialog
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.util.UUID

private enum class CropTarget {
    AVATAR,
    BANNER,
}

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
        bannerUrl: String?,
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
    var bannerUrl by remember { mutableStateOf(profile.bannerUrl) }
    var bannerPlaylists by remember { mutableStateOf(profile.bannerPlaylists) }

    // Staged cropped bitmaps
    var stagedAvatarBitmap by remember { mutableStateOf<Bitmap?>(null) }
    var stagedBannerBitmap by remember { mutableStateOf<Bitmap?>(null) }
    var stagedBannerVideoUri by remember { mutableStateOf<Uri?>(null) }

    // Crop dialog trigger
    var activeCropTarget by remember { mutableStateOf<Pair<Uri, CropTarget>?>(null) }

    // Unique handle checking
    var isCheckingHandle by remember { mutableStateOf(false) }
    var isHandleAvailable by remember { mutableStateOf<Boolean?>(true) }

    var isSaving by remember { mutableStateOf(false) }

    // Real-time unique handle check with debounce
    LaunchedEffect(handle) {
        val clean = handle.trim().lowercase().removePrefix("@")
        if (clean.isBlank()) {
            isHandleAvailable = false
            return@LaunchedEffect
        }
        if (clean == profile.handle.lowercase().removePrefix("@")) {
            isHandleAvailable = true
            isCheckingHandle = false
            return@LaunchedEffect
        }
        if (clean.length < 3) {
            isHandleAvailable = false
            isCheckingHandle = false
            return@LaunchedEffect
        }
        isCheckingHandle = true
        delay(400)
        SupabaseService.isHandleAvailable(clean, profile.id).onSuccess { available ->
            isHandleAvailable = available
            isCheckingHandle = false
        }.onFailure {
            isCheckingHandle = false
        }
    }

    // Launchers
    val avatarPickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickVisualMedia(),
    ) { uri ->
        if (uri != null) {
            activeCropTarget = Pair(uri, CropTarget.AVATAR)
        }
    }

    val bannerImagePickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickVisualMedia(),
    ) { uri ->
        if (uri != null) {
            activeCropTarget = Pair(uri, CropTarget.BANNER)
        }
    }

    val bannerVideoPickerLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickVisualMedia(),
    ) { uri ->
        if (uri != null) {
            scope.launch {
                val isValid = withContext(Dispatchers.IO) {
                    runCatching {
                        val retriever = MediaMetadataRetriever()
                        retriever.setDataSource(context, uri)
                        val durationStr = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                        val durationMs = durationStr?.toLongOrNull() ?: 0L
                        retriever.release()

                        val pfd = context.contentResolver.openFileDescriptor(uri, "r")
                        val fileSize = pfd?.statSize ?: 0L
                        pfd?.close()

                        durationMs <= 10_500L && fileSize <= 5L * 1024 * 1024
                    }.getOrDefault(false)
                }

                if (isValid) {
                    stagedBannerVideoUri = uri
                    stagedBannerBitmap = null
                } else {
                    Toast.makeText(
                        context,
                        "Banner video must be 10 seconds or less and under 5MB.",
                        Toast.LENGTH_LONG,
                    ).show()
                }
            }
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
                                var finalBannerUrl = bannerUrl

                                // Upload staged avatar bitmap
                                stagedAvatarBitmap?.let { bmp ->
                                    val stream = ByteArrayOutputStream()
                                    bmp.compress(Bitmap.CompressFormat.JPEG, 90, stream)
                                    val bytes = stream.toByteArray()
                                    SupabaseService.uploadImage(
                                        bytes = bytes,
                                        mimeType = "image/jpeg",
                                        fileName = "avatar_${profile.id}_${UUID.randomUUID()}.jpg",
                                    ).onSuccess { finalAvatarUrl = it }
                                }

                                // Upload staged banner bitmap
                                stagedBannerBitmap?.let { bmp ->
                                    val stream = ByteArrayOutputStream()
                                    bmp.compress(Bitmap.CompressFormat.JPEG, 88, stream)
                                    val bytes = stream.toByteArray()
                                    SupabaseService.uploadImage(
                                        bytes = bytes,
                                        mimeType = "image/jpeg",
                                        fileName = "banner_${profile.id}_${UUID.randomUUID()}.jpg",
                                    ).onSuccess { finalBannerUrl = it }
                                }

                                // Upload staged banner video
                                stagedBannerVideoUri?.let { uri ->
                                    val bytes = withContext(Dispatchers.IO) {
                                        context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                                    }
                                    if (bytes != null) {
                                        SupabaseService.uploadMedia(
                                            bytes = bytes,
                                            mimeType = "video/mp4",
                                            fileName = "banner_vid_${profile.id}_${UUID.randomUUID()}.mp4",
                                        ).onSuccess { finalBannerUrl = it }
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
                                    finalBannerUrl,
                                )
                                isSaving = false
                                onDismiss()
                            }
                        },
                        enabled = !isSaving && displayName.isNotBlank() && handle.isNotBlank() && isHandleAvailable == true,
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
                    // Profile Banner Editor
                    Column(modifier = Modifier.fillMaxWidth()) {
                        Text(
                            text = "Banner",
                            style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Spacer(Modifier.height(8.dp))
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(140.dp)
                                .clip(RoundedCornerShape(16.dp))
                                .background(MaterialTheme.colorScheme.surfaceVariant),
                            contentAlignment = Alignment.Center,
                        ) {
                            if (stagedBannerBitmap != null) {
                                androidx.compose.foundation.Image(
                                    bitmap = stagedBannerBitmap!!.asImageBitmap(),
                                    contentDescription = "New Banner",
                                    contentScale = ContentScale.Crop,
                                    modifier = Modifier.fillMaxSize(),
                                )
                            } else if (stagedBannerVideoUri != null) {
                                Box(
                                    modifier = Modifier
                                        .fillMaxSize()
                                        .background(Color.Black),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    Text(
                                        text = "Video Banner Selected (Looping <= 10s)",
                                        style = MaterialTheme.typography.bodySmall,
                                        color = Color.White,
                                    )
                                }
                            } else if (!bannerUrl.isNullOrBlank()) {
                                AsyncImage(
                                    model = bannerUrl,
                                    contentDescription = "Current Banner",
                                    contentScale = ContentScale.Crop,
                                    modifier = Modifier.fillMaxSize(),
                                )
                            } else {
                                Icon(
                                    imageVector = Icons.Rounded.Image,
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
                                    modifier = Modifier.size(48.dp),
                                )
                            }

                            // Banner Controls Row
                            Row(
                                modifier = Modifier
                                    .align(Alignment.BottomEnd)
                                    .padding(8.dp),
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                OutlinedButton(
                                    onClick = {
                                        bannerImagePickerLauncher.launch(
                                            PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly),
                                        )
                                    },
                                    shape = RoundedCornerShape(10.dp),
                                    colors = ButtonDefaults.outlinedButtonColors(
                                        containerColor = Color.Black.copy(alpha = 0.6f),
                                        contentColor = Color.White,
                                    ),
                                ) {
                                    Icon(Icons.Rounded.CameraAlt, contentDescription = null, modifier = Modifier.size(16.dp))
                                    Spacer(Modifier.width(4.dp))
                                    Text("Photo", fontSize = 12.sp)
                                }

                                OutlinedButton(
                                    onClick = {
                                        bannerVideoPickerLauncher.launch(
                                            PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.VideoOnly),
                                        )
                                    },
                                    shape = RoundedCornerShape(10.dp),
                                    colors = ButtonDefaults.outlinedButtonColors(
                                        containerColor = Color.Black.copy(alpha = 0.6f),
                                        contentColor = Color.White,
                                    ),
                                ) {
                                    Icon(Icons.Rounded.Videocam, contentDescription = null, modifier = Modifier.size(16.dp))
                                    Spacer(Modifier.width(4.dp))
                                    Text("Video", fontSize = 12.sp)
                                }

                                if (stagedBannerBitmap != null || stagedBannerVideoUri != null || !bannerUrl.isNullOrBlank()) {
                                    IconButton(
                                        onClick = {
                                            stagedBannerBitmap = null
                                            stagedBannerVideoUri = null
                                            bannerUrl = null
                                        },
                                        modifier = Modifier
                                            .size(36.dp)
                                            .clip(CircleShape)
                                            .background(Color.Black.copy(alpha = 0.6f)),
                                    ) {
                                        Icon(
                                            imageVector = Icons.Rounded.Close,
                                            contentDescription = "Remove banner",
                                            tint = Color.White,
                                            modifier = Modifier.size(16.dp),
                                        )
                                    }
                                }
                            }
                        }
                    }

                    Spacer(Modifier.height(20.dp))

                    // Profile Avatar Section
                    Box(
                        modifier = Modifier.size(96.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Box(
                            modifier = Modifier
                                .matchParentSize()
                                .clip(CircleShape)
                                .clickable {
                                    avatarPickerLauncher.launch(
                                        PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly),
                                    )
                                },
                            contentAlignment = Alignment.Center,
                        ) {
                            if (stagedAvatarBitmap != null) {
                                androidx.compose.foundation.Image(
                                    bitmap = stagedAvatarBitmap!!.asImageBitmap(),
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
                                        modifier = Modifier.size(48.dp),
                                    )
                                }
                            }
                        }

                        // Camera change badge
                        Box(
                            modifier = Modifier
                                .size(32.dp)
                                .align(Alignment.BottomEnd)
                                .clip(CircleShape)
                                .background(MaterialTheme.colorScheme.primary)
                                .border(2.dp, MaterialTheme.colorScheme.background, CircleShape)
                                .clickable {
                                    avatarPickerLauncher.launch(
                                        PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly),
                                    )
                                },
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.CameraAlt,
                                contentDescription = "Change photo",
                                tint = MaterialTheme.colorScheme.onPrimary,
                                modifier = Modifier.size(16.dp),
                            )
                        }
                    }

                    Spacer(Modifier.height(6.dp))
                    Text(
                        text = "Change Profile Photo",
                        style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.clickable {
                            avatarPickerLauncher.launch(
                                PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly),
                            )
                        },
                    )

                    Spacer(Modifier.height(20.dp))

                    // Display Name Field
                    FormField(
                        label = "Display Name",
                        value = displayName,
                        onValueChange = { displayName = it },
                        placeholder = "Your name",
                    )

                    Spacer(Modifier.height(16.dp))

                    // Handle Field with Uniqueness Check
                    Column(modifier = Modifier.fillMaxWidth()) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                text = "Handle",
                                style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold),
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            if (isCheckingHandle) {
                                CircularProgressIndicator(modifier = Modifier.size(14.dp), strokeWidth = 1.5.dp)
                            } else if (isHandleAvailable == true && handle.isNotBlank()) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Icon(
                                        imageVector = Icons.Rounded.Check,
                                        contentDescription = "Available",
                                        tint = Color(0xFF4CAF50),
                                        modifier = Modifier.size(14.dp),
                                    )
                                    Spacer(Modifier.width(4.dp))
                                    Text(
                                        text = "Available",
                                        style = MaterialTheme.typography.labelSmall,
                                        color = Color(0xFF4CAF50),
                                    )
                                }
                            } else if (isHandleAvailable == false) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Icon(
                                        imageVector = Icons.Rounded.ErrorOutline,
                                        contentDescription = "Taken",
                                        tint = MaterialTheme.colorScheme.error,
                                        modifier = Modifier.size(14.dp),
                                    )
                                    Spacer(Modifier.width(4.dp))
                                    Text(
                                        text = "Already taken",
                                        style = MaterialTheme.typography.labelSmall,
                                        color = MaterialTheme.colorScheme.error,
                                    )
                                }
                            }
                        }
                        Spacer(Modifier.height(6.dp))
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(14.dp))
                                .background(MaterialTheme.colorScheme.surfaceVariant)
                                .padding(horizontal = 14.dp, vertical = 12.dp),
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(
                                    text = "@",
                                    style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Bold),
                                    color = MaterialTheme.colorScheme.primary,
                                )
                                Spacer(Modifier.width(4.dp))
                                BasicTextField(
                                    value = handle.removePrefix("@"),
                                    onValueChange = { handle = it.trim().lowercase() },
                                    textStyle = TextStyle(
                                        color = MaterialTheme.colorScheme.onSurface,
                                        fontSize = 14.sp,
                                    ),
                                    cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                                    modifier = Modifier.fillMaxWidth(),
                                )
                            }
                        }
                    }

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

                    // Status Bubble Field
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
                                    if (it.isEmpty() || (it.all { c -> c.isDigit() } && it.length <= 3)) {
                                        ageText = it
                                    }
                                },
                                placeholder = "Age",
                            )
                        }
                    }

                    Spacer(Modifier.height(30.dp))
                }
            }
        }
    }

    // Interactive Crop & Adjust Dialog
    activeCropTarget?.let { (uri, target) ->
        val aspect = if (target == CropTarget.AVATAR) 1f else (16f / 9f)
        val title = if (target == CropTarget.AVATAR) "Adjust Profile Photo" else "Adjust Banner"
        MediaCropAdjustDialog(
            imageUri = uri,
            targetAspectRatio = aspect,
            title = title,
            onDismiss = { activeCropTarget = null },
            onConfirm = { croppedBmp ->
                if (target == CropTarget.AVATAR) {
                    stagedAvatarBitmap = croppedBmp
                } else {
                    stagedBannerBitmap = croppedBmp
                    stagedBannerVideoUri = null
                }
                activeCropTarget = null
            },
        )
    }
}

@Composable
private fun FormField(
    label: String,
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    prefix: String? = null,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier.fillMaxWidth()) {
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
                        style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Bold),
                        color = MaterialTheme.colorScheme.primary,
                    )
                    Spacer(Modifier.width(4.dp))
                }
                Box(modifier = Modifier.weight(1f)) {
                    if (value.isEmpty()) {
                        Text(
                            text = placeholder,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    BasicTextField(
                        value = value,
                        onValueChange = onValueChange,
                        textStyle = TextStyle(
                            color = MaterialTheme.colorScheme.onSurface,
                            fontSize = 14.sp,
                        ),
                        cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true,
                    )
                }
            }
        }
    }
}
