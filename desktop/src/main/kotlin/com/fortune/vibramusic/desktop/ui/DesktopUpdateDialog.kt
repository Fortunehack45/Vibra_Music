package com.fortune.vibramusic.desktop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.fortune.vibramusic.desktop.glass.liquidGlass
import com.fortune.vibramusic.desktop.update.DesktopAppUpdateChecker
import kotlinx.coroutines.launch

@Composable
fun DesktopUpdateDialog(
    updateInfo: DesktopAppUpdateChecker.DesktopUpdateInfo,
    downloadState: DesktopAppUpdateChecker.DownloadState,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val cardShape = remember { RoundedCornerShape(24.dp) }
    val scope = rememberCoroutineScope()

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.65f)),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .width(420.dp)
                .liquidGlass(shape = cardShape, elevation = 20.dp)
                .padding(28.dp),
        ) {
            Column(horizontalAlignment = Alignment.Start) {
                Text(
                    text = "Update Available",
                    color = Color.White,
                    fontSize = 20.sp,
                    fontWeight = FontWeight.Bold,
                )
                Spacer(modifier = Modifier.height(4.dp))
                Text(
                    text = "Version ${updateInfo.version} is now available (Current: ${DesktopAppUpdateChecker.CURRENT_VERSION})",
                    color = Color.White.copy(alpha = 0.7f),
                    fontSize = 13.sp,
                )

                if (!updateInfo.notes.isNullOrBlank()) {
                    Spacer(modifier = Modifier.height(14.dp))
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(140.dp)
                            .background(Color.Black.copy(alpha = 0.25f), RoundedCornerShape(12.dp))
                            .padding(12.dp)
                            .verticalScroll(rememberScrollState()),
                    ) {
                        Text(
                            text = updateInfo.notes,
                            color = Color.White.copy(alpha = 0.85f),
                            fontSize = 12.sp,
                            lineHeight = 16.sp,
                        )
                    }
                }

                Spacer(modifier = Modifier.height(20.dp))

                // Download Progress
                when (downloadState) {
                    is DesktopAppUpdateChecker.DownloadState.Downloading -> {
                        val pct = (downloadState.fraction * 100).toInt()
                        Text("Downloading update... $pct%", color = Color.White.copy(alpha = 0.8f), fontSize = 12.sp)
                        Spacer(modifier = Modifier.height(6.dp))
                        LinearProgressIndicator(
                            progress = { downloadState.fraction },
                            color = Color(0xFFFA2D48),
                            trackColor = Color.White.copy(alpha = 0.15f),
                            modifier = Modifier.fillMaxWidth().height(6.dp),
                        )
                    }
                    is DesktopAppUpdateChecker.DownloadState.Ready -> {
                        Text("Update ready to install!", color = Color(0xFF4CAF50), fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                    }
                    is DesktopAppUpdateChecker.DownloadState.Failed -> {
                        Text(downloadState.message, color = Color(0xFFFF5252), fontSize = 12.sp)
                    }
                    else -> {}
                }

                Spacer(modifier = Modifier.height(20.dp))

                // Actions
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.End,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    TextButton(onClick = onDismiss) {
                        Text("Later", color = Color.White.copy(alpha = 0.7f))
                    }
                    Spacer(modifier = Modifier.width(12.dp))

                    when (downloadState) {
                        is DesktopAppUpdateChecker.DownloadState.Ready -> {
                            Button(
                                onClick = { DesktopAppUpdateChecker.installAndRestart(downloadState.file) },
                                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF4CAF50)),
                                shape = RoundedCornerShape(50),
                            ) {
                                Text("Install & Restart", fontWeight = FontWeight.Bold)
                            }
                        }
                        is DesktopAppUpdateChecker.DownloadState.Downloading -> {
                            Button(
                                onClick = {},
                                enabled = false,
                                colors = ButtonDefaults.buttonColors(containerColor = Color.White.copy(alpha = 0.2f)),
                                shape = RoundedCornerShape(50),
                            ) {
                                Text("Downloading...")
                            }
                        }
                        else -> {
                            Button(
                                onClick = {
                                    scope.launch { DesktopAppUpdateChecker.downloadUpdate() }
                                },
                                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFFA2D48)),
                                shape = RoundedCornerShape(50),
                            ) {
                                Text("Download & Update", fontWeight = FontWeight.Bold)
                            }
                        }
                    }
                }
            }
        }
    }
}
