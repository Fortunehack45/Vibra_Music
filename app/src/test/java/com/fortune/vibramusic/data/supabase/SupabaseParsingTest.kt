package com.fortune.vibramusic.data.supabase

import com.fortune.vibramusic.data.model.UserListeningExperience
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SupabaseParsingTest {

    @Test
    fun testUserListeningExperienceCreation() {
        val experience = UserListeningExperience(
            userId = "test-user-123",
            audioQuality = "HIGH",
            equalizerEnabled = true,
            listeningStatsJson = "{\"played_ms\": 120000}",
        )
        assertEquals("test-user-123", experience.userId)
        assertEquals("HIGH", experience.audioQuality)
        assertTrue(experience.equalizerEnabled)
        assertNotNull(experience.listeningStatsJson)
    }

    @Test
    fun testPostgrestSanitizerWildcardHandling() {
        val sanitized = PostgrestSanitizer.escapeIlikePattern("artist%name_test")
        assertEquals("artist\\%name\\_test", sanitized)
    }
}
