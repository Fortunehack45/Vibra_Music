package com.fortune.vibramusic.playback.smart

import com.fortune.vibramusic.data.model.Song
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

class AcousticCatalogServiceTest {

    private fun song(title: String, artist: String, id: String = title) =
        Song(videoId = id, title = title, artist = artist, thumbnailUrl = null)

    @Before
    fun setUp() {
        AcousticCatalogService.clearCache()
    }

    @Test
    fun unanalyzedTracksReturnNullWithoutHardcoding() {
        // Zero hardcoding: Any track without prior dynamic analysis returns null
        // so UI renders genuine loading placeholders instead of static/fake data.
        val song1 = song("FRE\$H", "Victony", "fresh_id")
        val song2 = song("TWIN (feat. FOLA)", "Victony, FOLA", "twin_id")
        val song3 = song("Voodoo", "Chisway, JZyNo", "voodoo_id")
        val song4 = song("Unknown Track Title 123", "Unknown Artist 456", "unknown_id")

        assertNull(AcousticCatalogService.get(song1))
        assertNull(AcousticCatalogService.get(song2))
        assertNull(AcousticCatalogService.get(song3))
        assertNull(AcousticCatalogService.get(song4))
    }

    @Test
    fun dynamicallyAnalyzedTrackResolvesAccuratelyFromStore() {
        val testSong = song("FRE\$H", "Victony", "fresh_id")

        // Mock/subclass AnalysisStore returning dynamic analysis
        val mockStore = object : AnalysisStore() {
            private val map = mutableMapOf<String, TrackAnalysis>()

            override fun load(trackId: String): TrackAnalysis? = map[trackId]
            override fun save(trackId: String, analysis: TrackAnalysis) {
                map[trackId] = analysis
            }
        }

        // Initially unanalyzed
        assertNull(AcousticCatalogService.get(testSong, mockStore))

        // Store receives dynamic analysis from DSP
        val dynamicAnalysis = TrackAnalysis(
            status = TrackAnalysis.STATUS_READY,
            trackId = testSong.videoId,
            bpm = 120.0,
            key = "1A",
            beatInterval = 0.5,
            duration = 180.0,
        )
        mockStore.save(testSong.videoId, dynamicAnalysis)

        // Now AcousticCatalogService dynamically returns the DSP result
        val data = AcousticCatalogService.get(testSong, mockStore)
        assertNotNull(data)
        assertEquals(120.0, data!!.bpm, 0.01)
        assertEquals("1A", data.camelotKey)
    }

    @Test
    fun tempoNormalizationMaintainsStandardAutomixWindow() {
        assertEquals(120.0, AcousticCatalogService.normalizeTempo(120.0), 0.01)
        // Halves fast tempos (> 165 BPM) into natural beat range
        assertEquals(85.0, AcousticCatalogService.normalizeTempo(170.0), 0.01)
        // Doubles slow tempos (< 75 BPM) into natural beat range
        assertEquals(140.0, AcousticCatalogService.normalizeTempo(70.0), 0.01)
    }

    @Test
    fun spotifyKeyToCamelotMappingsAreAccurate() {
        // C Major (key 0, mode 1) -> 8B
        assertEquals("8B", AcousticCatalogService.spotifyKeyToCamelot(0, 1))
        // A Minor (key 9, mode 0) -> 8A
        assertEquals("8A", AcousticCatalogService.spotifyKeyToCamelot(9, 0))
        // F# / Gb Minor (key 6, mode 0) -> 11A
        assertEquals("11A", AcousticCatalogService.spotifyKeyToCamelot(6, 0))
        // B Minor (key 11, mode 0) -> 10A
        assertEquals("10A", AcousticCatalogService.spotifyKeyToCamelot(11, 0))
    }
}
