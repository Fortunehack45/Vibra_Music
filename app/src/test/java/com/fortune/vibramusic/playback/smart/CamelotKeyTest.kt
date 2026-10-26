package com.fortune.vibramusic.playback.smart

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CamelotKeyTest {

    @Test
    fun parsesDirectCamelotNotation() {
        val key8A = CamelotKey.parse("8A")
        assertNotNull(key8A)
        assertEquals(8, key8A?.number)
        assertEquals(false, key8A?.isMajor)
        assertEquals("8A", key8A?.code)

        val key11B = CamelotKey.parse("11B")
        assertNotNull(key11B)
        assertEquals(11, key11B?.number)
        assertEquals(true, key11B?.isMajor)
        assertEquals("11B", key11B?.code)
    }

    @Test
    fun parsesStandardPitchNotation() {
        // C Major = 8B
        val cMaj = CamelotKey.parse("C Major")
        assertNotNull(cMaj)
        assertEquals(8, cMaj?.number)
        assertEquals(true, cMaj?.isMajor)

        // A Minor = 8A
        val aMin = CamelotKey.parse("Am")
        assertNotNull(aMin)
        assertEquals(8, aMin?.number)
        assertEquals(false, aMin?.isMajor)

        // F# Minor = 11A
        val fSharpMin = CamelotKey.parse("F#m")
        assertNotNull(fSharpMin)
        assertEquals(11, fSharpMin?.number)
        assertEquals(false, fSharpMin?.isMajor)

        // Unicode sharp/flat notation from C++ DSP analyzer
        val cSharpMinUnicode = CamelotKey.parse("C♯ minor")
        assertNotNull(cSharpMinUnicode)
        assertEquals("12A", cSharpMinUnicode?.code)

        val eFlatMajUnicode = CamelotKey.parse("E♭ major")
        assertNotNull(eFlatMajUnicode)
        assertEquals("5B", eFlatMajUnicode?.code)

        val fSharpMajUnicode = CamelotKey.parse("F♯ major")
        assertNotNull(fSharpMajUnicode)
        assertEquals("2B", fSharpMajUnicode?.code)

        val bFlatMajUnicode = CamelotKey.parse("B♭ major")
        assertNotNull(bFlatMajUnicode)
        assertEquals("6B", bFlatMajUnicode?.code)
    }

    @Test
    fun returnsNullForUnrecognizedKeys() {
        assertNull(CamelotKey.parse(null))
        assertNull(CamelotKey.parse(""))
        assertNull(CamelotKey.parse("   "))
        assertNull(CamelotKey.parse("InvalidKey123"))
        assertNull(CamelotKey.parse("13A"))
    }

    @Test
    fun calculatesHarmonicCompatibilityCorrectly() {
        val key8A = CamelotKey.parse("8A")!!
        val key8B = CamelotKey.parse("8B")!!
        val key7A = CamelotKey.parse("7A")!!
        val key9A = CamelotKey.parse("9A")!!
        val key1A = CamelotKey.parse("1A")!!
        val key12A = CamelotKey.parse("12A")!!

        // Identical key = 1.0
        assertEquals(1.0f, key8A.compatibilityScore(key8A), 0.0001f)

        // Adjacent key (+/- 1 fifth) = 0.90
        assertEquals(0.90f, key8A.compatibilityScore(key7A), 0.0001f)
        assertEquals(0.90f, key8A.compatibilityScore(key9A), 0.0001f)

        // Circular wrap on 12-hour wheel (1A to 12A is 1 step away) = 0.90
        assertEquals(0.90f, key1A.compatibilityScore(key12A), 0.0001f)

        // Relative major/minor (same number, mode flip) = 0.85
        assertEquals(0.85f, key8A.compatibilityScore(key8B), 0.0001f)

        // Incompatible / distant key (< 0.5)
        assertTrue(key8A.compatibilityScore(key1A) <= 0.40f)
    }
}
