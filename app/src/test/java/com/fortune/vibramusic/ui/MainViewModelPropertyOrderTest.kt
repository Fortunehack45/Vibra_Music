package com.fortune.vibramusic.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class MainViewModelPropertyOrderTest {

    private fun resolveSourceFile(relativePath: String): File {
        val candidates = listOf(
            File(relativePath),
            File("app", relativePath),
            File("..", relativePath),
            File("../app", relativePath),
        )
        return candidates.firstOrNull { it.exists() }
            ?: throw IllegalStateException("Could not find source file: $relativePath")
    }

    @Test
    fun noMainViewModelPropertyDeclaredAfterInit() {
        val file = resolveSourceFile("src/main/java/com/fortune/vibramusic/ui/MainViewModel.kt")
        assertTrue("MainViewModel.kt should exist", file.exists())

        val lines = file.readLines()
        var inClass = false
        var initLineIndex = -1
        val deferredProperties = mutableListOf<String>()

        val propertyKeywords = listOf(
            "val ", "var ",
            "private val ", "private var ",
            "internal val ", "internal var ",
            "public val ", "public var ",
        )

        for ((idx, rawLine) in lines.withIndex()) {
            val trimmed = rawLine.trim()
            if (trimmed.startsWith("class MainViewModel") && !inClass) {
                inClass = true
                continue
            }
            if (inClass && trimmed.startsWith("companion object")) {
                // Companion object is at the bottom, class instance scope ends here
                break
            }
            if (!inClass) continue

            if (trimmed.startsWith("init {") && initLineIndex == -1) {
                initLineIndex = idx
                continue
            }

            // Member properties have 4 spaces indent in class body
            if (rawLine.startsWith("    ") && !rawLine.startsWith("     ")) {
                if (propertyKeywords.any { trimmed.startsWith(it) }) {
                    if (initLineIndex != -1 && idx > initLineIndex) {
                        deferredProperties.add("Line ${idx + 1}: $trimmed")
                    }
                }
            }
        }

        assertTrue("init block in MainViewModel should be found", initLineIndex > 0)
        assertEquals(
            "All properties in MainViewModel must be declared BEFORE init to prevent null-initialization hazards. Found: $deferredProperties",
            emptyList<String>(),
            deferredProperties
        )
    }

    @Test
    fun topPicksFileConstantIsAccessibleInCompanionObject() {
        val field = MainViewModel::class.java.declaredFields.firstOrNull { it.name == "TOP_PICKS_FILE" }
        assertNotNull("TOP_PICKS_FILE constant should be declared on MainViewModel", field)
        field?.isAccessible = true
        val value = field?.get(null)
        assertEquals("top_picks_v4.json", value)
    }

    @Test
    fun noMusicVideoEnginePropertyDeclaredAfterInit() {
        val file = resolveSourceFile("src/main/java/com/fortune/vibramusic/ui/player/MusicVideoPlayer.kt")
        assertTrue("MusicVideoPlayer.kt should exist", file.exists())

        val lines = file.readLines()
        var inEngine = false
        var initLineIndex = -1
        val deferredProperties = mutableListOf<String>()

        val propertyKeywords = listOf(
            "val ", "var ",
            "private val ", "private var ",
            "internal val ", "internal var ",
            "public val ", "public var ",
        )

        for ((idx, rawLine) in lines.withIndex()) {
            val trimmed = rawLine.trim()
            if (trimmed.contains("object MusicVideoEngine") && !inEngine) {
                inEngine = true
                continue
            }
            if (inEngine && rawLine.startsWith("}")) {
                break
            }
            if (!inEngine) continue

            if (trimmed.startsWith("init {") && initLineIndex == -1) {
                initLineIndex = idx
                continue
            }

            if (rawLine.startsWith("    ") && !rawLine.startsWith("     ")) {
                if (propertyKeywords.any { trimmed.startsWith(it) }) {
                    if (initLineIndex != -1 && idx > initLineIndex) {
                        deferredProperties.add("Line ${idx + 1}: $trimmed")
                    }
                }
            }
        }

        assertTrue("init block in MusicVideoEngine should be found", initLineIndex > 0)
        assertEquals(
            "All properties in MusicVideoEngine must be declared BEFORE init to prevent startup race hazards. Found: $deferredProperties",
            emptyList<String>(),
            deferredProperties
        )
    }
}
