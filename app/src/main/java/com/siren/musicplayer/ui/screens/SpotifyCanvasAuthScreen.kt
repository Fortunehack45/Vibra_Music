package com.siren.musicplayer.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Key
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.siren.musicplayer.R
import com.siren.musicplayer.data.canvas.SpotifyToken
import com.siren.musicplayer.data.settings.AppSettings

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SpotifyCanvasAuthScreen(
    onNavigateUp: () -> Unit
) {
    val currentToken by AppSettings.spotifySpdcToken.collectAsStateWithLifecycle()
    val autoHidePlayer by AppSettings.spotifyCanvasAutoHide.collectAsStateWithLifecycle()
    val prioritizeSpotify by AppSettings.prioritizeSpotifyCanvas.collectAsStateWithLifecycle()
    var tokenInput by remember(currentToken) { mutableStateOf(currentToken) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.spotify_canvas_setup)) },
                navigationIcon = {
                    IconButton(onClick = onNavigateUp) {
                        Icon(
                            Icons.AutoMirrored.Rounded.ArrowBack,
                            contentDescription = stringResource(R.string.back),
                        )
                    }
                }
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(16.dp)
                .verticalScroll(rememberScrollState())
        ) {
            // Active Status Banner
            Card(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(bottom = 16.dp),
                colors = CardDefaults.cardColors(
                    containerColor = if (currentToken.isBlank()) {
                        MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.5f)
                    } else {
                        MaterialTheme.colorScheme.secondaryContainer.copy(alpha = 0.5f)
                    }
                )
            ) {
                Row(
                    modifier = Modifier.padding(16.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(
                        imageVector = if (currentToken.isBlank()) Icons.Rounded.CheckCircle else Icons.Rounded.Key,
                        contentDescription = null,
                        tint = if (currentToken.isBlank()) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.secondary,
                        modifier = Modifier.padding(end = 12.dp)
                    )
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = if (currentToken.isBlank()) {
                                stringResource(R.string.spotify_canvas_builtin_active)
                            } else {
                                stringResource(R.string.spotify_canvas_custom_active)
                            },
                            style = MaterialTheme.typography.titleMedium,
                        )
                        Spacer(modifier = Modifier.height(4.dp))
                        Text(
                            text = if (currentToken.isBlank()) {
                                stringResource(R.string.spotify_canvas_builtin_active_desc)
                            } else {
                                stringResource(R.string.spotify_canvas_custom_active_desc)
                            },
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }

            // Toggles
            SpotifyCanvasSettingToggle(
                title = stringResource(R.string.spotify_canvas_auto_hide),
                subtitle = stringResource(R.string.spotify_canvas_auto_hide_subtitle),
                checked = autoHidePlayer,
                onCheckedChange = AppSettings::setSpotifyCanvasAutoHide,
            )

            SpotifyCanvasSettingToggle(
                title = stringResource(R.string.prioritize_spotify_canvas),
                subtitle = stringResource(R.string.prioritize_spotify_canvas_subtitle),
                checked = prioritizeSpotify,
                onCheckedChange = AppSettings::setPrioritizeSpotifyCanvas,
            )

            Spacer(modifier = Modifier.height(16.dp))

            // Bring-your-own section & guide
            Text(
                text = stringResource(R.string.spotify_canvas_bring_your_own_title),
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.padding(bottom = 6.dp)
            )

            Text(
                text = stringResource(R.string.spotify_canvas_bring_your_own_desc),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(bottom = 12.dp)
            )

            Card(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(bottom = 16.dp),
                colors = CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
                )
            ) {
                Column(modifier = Modifier.padding(14.dp)) {
                    Text(
                        text = stringResource(R.string.spotify_canvas_guide_header),
                        style = MaterialTheme.typography.titleSmall,
                        modifier = Modifier.padding(bottom = 6.dp)
                    )
                    Text(
                        text = stringResource(R.string.spotify_canvas_setup_steps),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        lineHeight = MaterialTheme.typography.bodySmall.lineHeight * 1.2f
                    )
                }
            }

            OutlinedTextField(
                value = tokenInput,
                onValueChange = { tokenInput = it },
                label = { Text(stringResource(R.string.spotify_canvas_custom_optional)) },
                placeholder = { Text(stringResource(R.string.spotify_canvas_placeholder)) },
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(bottom = 16.dp),
                singleLine = true,
                trailingIcon = {
                    if (tokenInput.isNotBlank()) {
                        IconButton(onClick = { tokenInput = "" }) {
                            Icon(
                                Icons.Rounded.Close,
                                contentDescription = stringResource(R.string.clear_queue)
                            )
                        }
                    }
                }
            )

            if (currentToken.isNotBlank()) {
                OutlinedButton(
                    onClick = {
                        AppSettings.setSpotifySpdcToken("")
                        SpotifyToken.invalidate()
                        tokenInput = ""
                    },
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(bottom = 12.dp)
                ) {
                    Text(stringResource(R.string.spotify_canvas_revert_builtin))
                }
            }

            Button(
                onClick = { 
                    AppSettings.setSpotifySpdcToken(tokenInput.trim())
                    SpotifyToken.invalidate()
                    onNavigateUp()
                },
                modifier = Modifier.fillMaxWidth()
            ) {
                Text(stringResource(R.string.save))
            }
        }
    }
}

@Composable
private fun SpotifyCanvasSettingToggle(
    title: String,
    subtitle: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onCheckedChange(!checked) }
            .padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(
            modifier = Modifier
                .weight(1f)
                .padding(end = 16.dp),
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.bodyLarge,
            )
            Text(
                text = subtitle,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
        )
    }
}
