package com.fortune.vibramusic.data.db

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MixTypeConvertersTest {

    private val converters = MixTypeConverters()

    @Test
    fun testFloatArrayRoundTrip() {
        assertNull(converters.fromFloatArray(null))
        assertArrayEquals(FloatArray(0), converters.toFloatArray(null), 0.0f)

        val original = floatArrayOf(0.0f, 120.5f, -14.2f, 3.14159f, Float.MAX_VALUE, Float.MIN_VALUE)
        val blob = converters.fromFloatArray(original)
        assert(blob != null)
        assertEquals(original.size * 4, blob!!.size)

        val restored = converters.toFloatArray(blob)
        assertArrayEquals(original, restored, 0.0001f)
    }

    @Test
    fun testLongArrayRoundTrip() {
        assertNull(converters.fromLongArray(null))
        assertArrayEquals(LongArray(0), converters.toLongArray(null))

        val original = longArrayOf(0L, 16000L, 140000L, Long.MAX_VALUE, Long.MIN_VALUE)
        val blob = converters.fromLongArray(original)
        assert(blob != null)
        assertEquals(original.size * 8, blob!!.size)

        val restored = converters.toLongArray(blob)
        assertArrayEquals(original, restored)
    }
}
