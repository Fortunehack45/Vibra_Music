package com.fortune.vibramusic.ui.theme

import androidx.compose.runtime.Composable

private object NoOrientation : ScreenOrientation {
    override fun landscape() = Unit
    override fun portrait() = Unit
}

@Composable
actual fun rememberScreenOrientation(): ScreenOrientation = NoOrientation
