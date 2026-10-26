package com.fortune.vibramusic.playback.voice

import android.provider.MediaStore
import com.fortune.vibramusic.data.LocalPlaylistsStore
import com.fortune.vibramusic.data.model.Song
import com.fortune.vibramusic.playback.LinkRequest
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class VoiceCommandResolverTest {

    private val createdPlaylistIds = mutableListOf<String>()

    @After
    fun tearDown() {
        for (id in createdPlaylistIds) {
            LocalPlaylistsStore.deletePlaylist(id)
        }
        createdPlaylistIds.clear()
    }

    @Test
    fun testResumeOnEmptyQueryAndExtras() = runBlocking {
        val res1 = VoiceCommandResolver.resolve(query = "")
        assertEquals(VoiceResolution.Resume, res1)

        val res2 = VoiceCommandResolver.resolve(
            voice = LinkRequest.Voice(
                rawQuery = "   ",
                mediaFocus = null,
                title = null,
                artist = null,
                album = null,
                playlist = null
            )
        )
        assertEquals(VoiceResolution.Resume, res2)
    }

    @Test
    fun testPlaylistFocusResolvesLocalPlaylist() = runBlocking {
        val testSong = Song(
            videoId = "test_vid_1",
            title = "Voice Test Song",
            artist = "Voice Test Artist",
            thumbnailUrl = "https://example.com/thumb.jpg"
        )
        val created = LocalPlaylistsStore.savePlaylist("Gym Workout", listOf(testSong))
        createdPlaylistIds.add(created.playlistId)

        val res = VoiceCommandResolver.resolve(
            query = "Gym Workout",
            mediaFocus = MediaStore.Audio.Playlists.ENTRY_CONTENT_TYPE,
            playlist = "Gym Workout"
        )

        assertTrue(res is VoiceResolution.PlaySongs)
        val playSongs = res as VoiceResolution.PlaySongs
        assertEquals("Gym Workout", playSongs.title)
        assertEquals(1, playSongs.songs.size)
        assertEquals("test_vid_1", playSongs.songs.first().videoId)
        assertTrue(playSongs.announcement.contains("Gym Workout"))
    }

    @Test
    fun testNaturalLanguageMyPlaylistResolvesLocalPlaylist() = runBlocking {
        val testSong = Song(
            videoId = "test_vid_2",
            title = "Chill Track",
            artist = "Chill Artist",
            thumbnailUrl = null
        )
        val created = LocalPlaylistsStore.savePlaylist("Evening Chill", listOf(testSong))
        createdPlaylistIds.add(created.playlistId)

        val res = VoiceCommandResolver.resolve(
            query = "play my playlist Evening Chill"
        )

        assertTrue(res is VoiceResolution.PlaySongs)
        val playSongs = res as VoiceResolution.PlaySongs
        assertEquals("Evening Chill", playSongs.title)
        assertEquals("test_vid_2", playSongs.songs.first().videoId)
    }

    @Test
    fun testLinkRequestVoiceCarriesExtras() = runBlocking {
        val testSong = Song(
            videoId = "test_vid_3",
            title = "Road Song",
            artist = "Road Artist",
            thumbnailUrl = null
        )
        val created = LocalPlaylistsStore.savePlaylist("Road Trip 2026", listOf(testSong))
        createdPlaylistIds.add(created.playlistId)

        val voice = LinkRequest.Voice(
            rawQuery = "Road Trip 2026",
            mediaFocus = MediaStore.Audio.Playlists.ENTRY_CONTENT_TYPE,
            playlist = "Road Trip 2026"
        )

        val res = VoiceCommandResolver.resolve(voice = voice)
        assertTrue(res is VoiceResolution.PlaySongs)
        val playSongs = res as VoiceResolution.PlaySongs
        assertEquals("Road Trip 2026", playSongs.title)
        assertEquals(1, playSongs.songs.size)
    }

    @Test
    fun testLocalPlaylistExactMatchTakesPrecedenceOverOnline() = runBlocking {
        val testSong = Song(
            videoId = "test_vid_local",
            title = "Local Exclusive",
            artist = "Local Artist",
            thumbnailUrl = null
        )
        val created = LocalPlaylistsStore.savePlaylist("Top Hits Offline", listOf(testSong))
        createdPlaylistIds.add(created.playlistId)

        val res = VoiceCommandResolver.resolve(query = "Top Hits Offline")
        assertTrue(res is VoiceResolution.PlaySongs)
        val playSongs = res as VoiceResolution.PlaySongs
        assertEquals("Top Hits Offline", playSongs.title)
        assertEquals("test_vid_local", playSongs.songs.first().videoId)
    }

    @Test
    fun testCleanSpokenQueryConversationalPhrases() {
        assertEquals("Asake", VoiceCommandResolver.cleanSpokenQuery("And play one Asake song"))
        assertEquals("Asake", VoiceCommandResolver.cleanSpokenQuery("Just help me to play one Asake song"))
        assertEquals("Asake", VoiceCommandResolver.cleanSpokenQuery("Play Asake on Vibra Music"))
        assertEquals("Asake", VoiceCommandResolver.cleanSpokenQuery("Play Asake on Vibra"))
        assertEquals("Asake", VoiceCommandResolver.cleanSpokenQuery("Play one Asake song"))
        assertEquals("Asake", VoiceCommandResolver.cleanSpokenQuery("Play songs by Asake"))
        assertEquals("Asake", VoiceCommandResolver.cleanSpokenQuery("music by Asake"))
        assertEquals("Burna Boy", VoiceCommandResolver.cleanSpokenQuery("Play some Burna Boy music"))
        assertEquals("Evening Chill", VoiceCommandResolver.cleanSpokenQuery("Play my playlist Evening Chill"))
        assertEquals("Starboy by The Weeknd", VoiceCommandResolver.cleanSpokenQuery("Play Starboy by The Weeknd"))
    }

    @Test
    fun testGenericPlayMusicCommandsResolveToResume() = runBlocking {
        assertEquals(VoiceResolution.Resume, VoiceCommandResolver.resolve(query = "Play music on Vibra Music"))
        assertEquals(VoiceResolution.Resume, VoiceCommandResolver.resolve(query = "Play some music"))
        assertEquals(VoiceResolution.Resume, VoiceCommandResolver.resolve(query = "Start playing music"))
        assertEquals(VoiceResolution.Resume, VoiceCommandResolver.resolve(query = "Put on some music"))
        assertEquals(VoiceResolution.Resume, VoiceCommandResolver.resolve(query = "Play music"))
        assertEquals(VoiceResolution.Resume, VoiceCommandResolver.resolve(query = "music"))
    }
}
