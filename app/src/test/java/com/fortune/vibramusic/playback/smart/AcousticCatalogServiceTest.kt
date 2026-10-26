package com.fortune.vibramusic.playback.smart

import com.fortune.vibramusic.data.model.Song
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class AcousticCatalogServiceTest {

    private fun song(title: String, artist: String, id: String = title) =
        Song(videoId = id, title = title, artist = artist, thumbnailUrl = null)

    @Test
    fun resolvesAllPlaylistTracksAccurately() {
        val fresh = song("FRE\$H", "Victony")
        val freshData = AcousticCatalogService.get(fresh)
        assertNotNull(freshData)
        assertEquals(120.0, freshData!!.bpm, 0.01)
        assertEquals("1A", freshData.camelotKey)

        val twin = song("TWIN (feat. FOLA)", "Victony, FOLA")
        val twinData = AcousticCatalogService.get(twin)
        assertNotNull(twinData)
        assertEquals(116.0, twinData!!.bpm, 0.01)
        assertEquals("7B", twinData.camelotKey)

        val motionSickness = song("MOTION SICKNESS (feat. Zlatan)", "ODUMODUBLVCK, Zlatan")
        val msData = AcousticCatalogService.get(motionSickness)
        assertNotNull(msData)
        assertEquals(116.0, msData!!.bpm, 0.01)
        assertEquals("4A", msData.camelotKey)

        val lala = song("La La (feat. Ckay)", "Davido, CKay")
        val lalaData = AcousticCatalogService.get(lala)
        assertNotNull(lalaData)
        assertEquals(114.0, lalaData!!.bpm, 0.01)
        assertEquals("12B", lalaData.camelotKey)

        val cfmf = song("CFMF", "Davido")
        val cfmfData = AcousticCatalogService.get(cfmf)
        assertNotNull(cfmfData)
        assertEquals(112.0, cfmfData!!.bpm, 0.01)
        assertEquals("2B", cfmfData.camelotKey)

        val allMyMoney = song("All My Money", "Kashcoming")
        val ammData = AcousticCatalogService.get(allMyMoney)
        assertNotNull(ammData)
        assertEquals(112.0, ammData!!.bpm, 0.01)
        assertEquals("8A", ammData.camelotKey)

        val malacosta = song("Malacosta (feat. Vulela)", "Mluusician, Ricky Lenyora")
        val malacostaData = AcousticCatalogService.get(malacosta)
        assertNotNull(malacostaData)
        assertEquals(113.0, malacostaData!!.bpm, 0.01)
        assertEquals("1A", malacostaData.camelotKey)

        val elumelu = song("Elumelu", "Young Jonn")
        val elumeluData = AcousticCatalogService.get(elumelu)
        assertNotNull(elumeluData)
        assertEquals(120.0, elumeluData!!.bpm, 0.01)
        assertEquals("1A", elumeluData.camelotKey)

        val cestLaVie = song("C'EST LA VIE", "Fireboy DML")
        val clvData = AcousticCatalogService.get(cestLaVie)
        assertNotNull(clvData)
        assertEquals(122.0, clvData!!.bpm, 0.01)
        assertEquals("3B", clvData.camelotKey)
    }
}
