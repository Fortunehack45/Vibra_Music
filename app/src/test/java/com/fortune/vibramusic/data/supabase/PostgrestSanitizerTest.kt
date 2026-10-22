package com.fortune.vibramusic.data.supabase

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PostgrestSanitizerTest {

    @Test
    fun testEscapeIlikePattern_stripsDelimiters() {
        val malicious = "malicious),id.neq.0,or(handle.ilike.*"
        val escaped = PostgrestSanitizer.escapeIlikePattern(malicious)
        assertFalse("Should not contain comma", escaped.contains(","))
        assertFalse("Should not contain opening paren", escaped.contains("("))
        assertFalse("Should not contain closing paren", escaped.contains(")"))
        assertFalse("Should not contain quotes", escaped.contains("\""))
    }

    @Test
    fun testEscapeIlikePattern_escapesSqlWildcards() {
        val wildcards = "test%search_query"
        val escaped = PostgrestSanitizer.escapeIlikePattern(wildcards)
        assertEquals("test\\%search\\_query", escaped)
    }

    @Test
    fun testSanitizeIdentifier_validIdsAllowed() {
        assertEquals("guest_c921f9b680e7", PostgrestSanitizer.sanitizeIdentifier("guest_c921f9b680e7"))
        assertEquals("UC123-abc.xyz:789", PostgrestSanitizer.sanitizeIdentifier("UC123-abc.xyz:789"))
    }

    @Test
    fun testSanitizeIdentifier_stripsMaliciousCharacters() {
        val injected = "user_id' OR 1=1; DROP TABLE profiles;--"
        val sanitized = PostgrestSanitizer.sanitizeIdentifier(injected)
        assertFalse("Should not contain single quote", sanitized.contains("'"))
        assertFalse("Should not contain space", sanitized.contains(" "))
        assertFalse("Should not contain semicolon", sanitized.contains(";"))
        assertFalse("Should not contain dashes that form comments", sanitized.contains("--"))
    }

    @Test
    fun testBuildSafeInFilter_sanitizesIds() {
        val ids = listOf("valid_1", "valid_2),status.eq.ALL,(id.in.(hack", "valid_3")
        val filter = PostgrestSanitizer.buildSafeInFilter(ids)
        assertTrue(filter.startsWith("in.("))
        assertTrue(filter.endsWith(")"))
        assertFalse("Should not contain unescaped injected delimiters", filter.contains("hack)"))
    }

    @Test
    fun testSafeJsonString_escapesQuotesAndControlChars() {
        val injection = "hello\"},\"is_admin\":true,\"x\":\""
        val safeJson = PostgrestSanitizer.safeJsonString(injection)
        assertTrue(safeJson.startsWith("\""))
        assertTrue(safeJson.endsWith("\""))
        assertTrue(safeJson.contains("\\\"is_admin\\\":true"))
    }
}
