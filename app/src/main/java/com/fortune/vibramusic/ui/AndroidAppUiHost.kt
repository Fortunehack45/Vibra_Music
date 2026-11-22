package com.fortune.vibramusic.ui

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.fortune.vibramusic.data.settings.AppSettings
import com.fortune.vibramusic.data.settings.LibrarySort
import com.fortune.vibramusic.data.settings.LibraryViewType
import com.fortune.vibramusic.download.Downloads
import kotlinx.coroutines.flow.StateFlow

class AndroidAppUiHost(context: Context) : AppUiHost {
    override val swipeToPlayNext: StateFlow<Boolean> = AppSettings.swipeToPlayNext
    override val homeRecentsViewType: StateFlow<LibraryViewType> = AppSettings.homeRecentsViewType
    override fun setHomeRecentsViewType(value: LibraryViewType) {
        AppSettings.setHomeRecentsViewType(value)
    }
    override val pinnedPlaylists: StateFlow<List<String>> = AppSettings.pinnedPlaylists
    override val librarySort: StateFlow<LibrarySort> = AppSettings.librarySort

    @Composable
    override fun downloadedIds(): Set<String> {
        val saved by Downloads.saved.collectAsStateWithLifecycle()
        return saved.keys
    }
}
