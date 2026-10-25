package com.fortune.vibramusic.data.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class TransitionStoreTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    private lateinit var store: TransitionStore

    @Before
    fun setUp() {
        store = TransitionStore(tempFolder.root)
    }

    @Test
    fun savesAndLoadsTransitionConfigSuccessfully() {
        val config = TransitionConfig(
            playlistId = "pl_dance",
            fromItemId = "item_1",
            toItemId = "item_2",
            preset = "rise",
            durationMs = 6000L,
            outgoingGainCurve = listOf(PointDto(0f, 1f), PointDto(1f, 0f)),
            incomingGainCurve = listOf(PointDto(0f, 0f), PointDto(1f, 1f)),
        )

        store.save(config)

        val loaded = store.load(fromItemId = "item_1", toItemId = "item_2", playlistId = "pl_dance")
        assertNotNull(loaded)
        assertEquals("item_1", loaded?.fromItemId)
        assertEquals("item_2", loaded?.toItemId)
        assertEquals("rise", loaded?.preset)
        assertEquals(6000L, loaded?.durationMs)
    }

    @Test
    fun returnsNullForNonExistentConfig() {
        val loaded = store.load(fromItemId = "missing_1", toItemId = "missing_2")
        assertNull(loaded)
    }

    @Test
    fun deletesTransitionConfigProperly() {
        val config = TransitionConfig(
            fromItemId = "del_1",
            toItemId = "del_2",
            preset = "fade",
        )
        store.save(config)
        assertNotNull(store.load("del_1", "del_2"))

        store.delete("del_1", "del_2")
        assertNull(store.load("del_1", "del_2"))
    }
}
