package com.fortune.vibramusic.desktop

import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import com.fortune.vibramusic.desktop.ui.DesktopApp

fun main() = application {
    val windowState = rememberWindowState(width = 460.dp, height = 900.dp)

    Window(
        onCloseRequest = ::exitApplication,
        state = windowState,
        title = "Vibra Music",
    ) {
        DesktopApp()
    }
}
