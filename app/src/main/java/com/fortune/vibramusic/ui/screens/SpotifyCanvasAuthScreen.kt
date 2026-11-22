package com.fortune.vibramusic.ui.screens

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
import com.fortune.vibramusic.R
import androidx.compose.foundation.layout.size
import androidx.compose.ui.res.painterResource
import com.fortune.vibramusic.data.canvas.TokenProvider
import com.fortune.vibramusic.data.canvas.SpotifyToken
import com.fortune.vibramusic.data.settings.AppSettings

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SpotifyCanvasAuthScreen(
    onNavigateUp: () -> Unit,
    onOpenLogin: () -> Unit = {},
) {
    val currentToken by AppSettings.spotifySpdcToken.collectAsStateWithLifecycle()
    val disableSpotify by AppSettings.disableSpotifyCanvas.collectAsStateWithLifecycle()
    val autoHidePlayer by AppSettings.spotifyCanvasAutoHide.collectAsStateWithLifecycle()
    val prioritizeSpotify by AppSettings.prioritizeSpotifyCanvas.collectAsStateWithLifecycle()
    val canvasOverCellular by AppSettings.canvasOverCellular.collectAsStateWithLifecycle()
    val context = androidx.compose.ui.platform.LocalContext.current
    var tokenInput by remember(currentToken) { mutableStateOf(currentToken) }

    val builtIn = remember { TokenProvider.getSpdcToken() }
    val hasBuiltIn = !builtIn.isNullOrBlank()
    val hasUserToken = currentToken.isNotBlank() && (builtIn == null || currentToken.trim() != builtIn)

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
                    containerColor = when {
                        hasUserToken || hasBuiltIn -> MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.5f)
                        else -> MaterialTheme.colorScheme.errorContainer.copy(alpha = 0.4f)
                    }
                )
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(
                            imageVector = when {
                                hasUserToken || hasBuiltIn -> Icons.Rounded.CheckCircle
                                else -> Icons.Rounded.Key
                            },
                            contentDescription = null,
                            tint = when {
                                hasUserToken || hasBuiltIn -> MaterialTheme.colorScheme.primary
                                else -> MaterialTheme.colorScheme.error
                            },
                            modifier = Modifier.padding(end = 12.dp)
                        )
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = when {
                                    hasUserToken -> stringResource(R.string.spotify_canvas_cookie_active_title)
                                    hasBuiltIn -> stringResource(R.string.spotify_canvas_builtin_active)
                                    else -> stringResource(R.string.spotify_canvas_cookie_required_title)
                                },
                                style = MaterialTheme.typography.titleMedium,
                            )
                            Spacer(modifier = Modifier.height(4.dp))
                            Text(
                                text = when {
                                    hasUserToken -> stringResource(R.string.spotify_canvas_cookie_active_desc)
                                    hasBuiltIn -> stringResource(R.string.spotify_canvas_builtin_active_desc)
                                    else -> stringResource(R.string.spotify_canvas_cookie_required_desc)
                                },
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }

                    if (!hasUserToken) {
                        Spacer(modifier = Modifier.height(12.dp))
                        Button(
                            onClick = onOpenLogin,
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Icon(
                                painter = painterResource(R.drawable.ic_spotify),
                                contentDescription = null,
                                modifier = Modifier
                                    .padding(end = 8.dp)
                                    .size(20.dp),
                            )
                            Text(stringResource(R.string.spotify_canvas_login_button))
                        }
                    } else if (hasUserToken) {
                        Spacer(modifier = Modifier.height(12.dp))
                        OutlinedButton(
                            onClick = {
                                com.fortune.vibramusic.auth.clearSpotifyWebSession()
                                AppSettings.setSpotifySpdcToken("")
                                SpotifyToken.invalidate()
                                tokenInput = ""
                            },
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Icon(
                                Icons.Rounded.Close,
                                contentDescription = null,
                                modifier = Modifier
                                    .padding(end = 8.dp)
                                    .size(18.dp),
                            )
                            Text(stringResource(R.string.spotify_canvas_disconnect_button))
                        }
                    }
                }
            }

            // Toggles
            SpotifyCanvasSettingToggle(
                title = stringResource(R.string.disable_spotify_canvas),
                subtitle = stringResource(R.string.disable_spotify_canvas_subtitle),
                checked = disableSpotify,
                onCheckedChange = AppSettings::setDisableSpotifyCanvas,
            )

            SpotifyCanvasSettingToggle(
                title = stringResource(R.string.spotify_canvas_auto_hide),
                subtitle = stringResource(R.string.spotify_canvas_auto_hide_subtitle),
                checked = autoHidePlayer,
                onCheckedChange = AppSettings::setSpotifyCanvasAutoHide,
                enabled = !disableSpotify,
            )

            SpotifyCanvasSettingToggle(
                title = stringResource(R.string.prioritize_spotify_canvas),
                subtitle = stringResource(R.string.prioritize_spotify_canvas_subtitle),
                checked = prioritizeSpotify,
                onCheckedChange = AppSettings::setPrioritizeSpotifyCanvas,
                enabled = !disableSpotify,
            )

            SpotifyCanvasSettingToggle(
                title = stringResource(R.string.animated_cover_cellular),
                subtitle = null,
                checked = canvasOverCellular,
                onCheckedChange = AppSettings::setCanvasOverCellular,
                enabled = !disableSpotify,
            )

            Spacer(modifier = Modifier.height(16.dp))

            // Manual cookie entry
            Text(
                text = stringResource(R.string.spotify_canvas_manual_entry_title),
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
                    Spacer(Modifier.height(10.dp))
                    OutlinedButton(
                        onClick = {
                            runCatching {
                                val intent = android.content.Intent(
                                    android.content.Intent.ACTION_VIEW,
                                    android.net.Uri.parse("https://open.spotify.com")
                                )
                                context.startActivity(intent)
                            }
                        },
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text(stringResource(R.string.open_in_browser))
                    }
                }
            }

            OutlinedTextField(
                value = tokenInput,
                onValueChange = { tokenInput = it },
                label = { Text(stringResource(R.string.spdc_token)) },
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
                                contentDescription = stringResource(R.string.clear)
                            )
                        }
                    }
                }
            )

            if (currentToken.isNotBlank() && hasBuiltIn) {
                OutlinedButton(
                    onClick = {
                        com.fortune.vibramusic.auth.clearSpotifyWebSession()
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
    subtitle: String? = null,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    enabled: Boolean = true,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled) { onCheckedChange(!checked) }
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
                color = if (enabled) MaterialTheme.colorScheme.onBackground else MaterialTheme.colorScheme.onBackground.copy(alpha = 0.45f),
            )
            if (!subtitle.isNullOrBlank()) {
                Text(
                    text = subtitle,
                    style = MaterialTheme.typography.bodyMedium,
                    color = if (enabled) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.45f),
                )
            }
        }
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            enabled = enabled,
        )
    }
}
