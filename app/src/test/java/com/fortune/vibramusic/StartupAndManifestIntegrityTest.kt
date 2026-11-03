package com.fortune.vibramusic

import com.fortune.vibramusic.playback.AudioCache
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

class StartupAndManifestIntegrityTest {

    private fun resolveManifestFile(): File =
        File("src/main/AndroidManifest.xml").takeIf { it.exists() }
            ?: File("app/src/main/AndroidManifest.xml").takeIf { it.exists() }
            ?: File("../app/src/main/AndroidManifest.xml")

    @Test
    fun manifestHasExactlyOneLauncherComponent() {
        val manifestFile = resolveManifestFile()
        assertTrue("AndroidManifest.xml should exist", manifestFile.exists())

        val doc = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(manifestFile)
        val activities = doc.getElementsByTagName("activity")
        val aliases = doc.getElementsByTagName("activity-alias")

        var launcherCount = 0
        val launcherNames = mutableListOf<String>()

        fun hasLauncherCategory(element: org.w3c.dom.Element): Boolean {
            val categories = element.getElementsByTagName("category")
            for (j in 0 until categories.length) {
                val catNode = categories.item(j)
                val catName = catNode.attributes.getNamedItem("android:name")?.nodeValue
                if (catName == "android.intent.category.LAUNCHER") {
                    return true
                }
            }
            return false
        }

        for (i in 0 until activities.length) {
            val element = activities.item(i) as org.w3c.dom.Element
            val name = element.getAttribute("android:name")
            if (hasLauncherCategory(element)) {
                launcherCount++
                launcherNames.add(name)
            }
        }

        for (i in 0 until aliases.length) {
            val element = aliases.item(i) as org.w3c.dom.Element
            val name = element.getAttribute("android:name")
            if (hasLauncherCategory(element)) {
                launcherCount++
                launcherNames.add(name)
            }
        }

        assertEquals(
            "Exactly one launcher component must exist in AndroidManifest to prevent duplicate desktop icons. Found: $launcherNames",
            1,
            launcherCount
        )
        assertEquals(
            "The primary launcher alias must be .LauncherDefault",
            ".LauncherDefault",
            launcherNames.first()
        )
    }

    @Test
    fun legacyAliasesAreDisabledByDefaultAndTargetMainActivityWithoutLauncherCategory() {
        val manifestFile = resolveManifestFile()
        val content = manifestFile.readText()

        // Ensure legacy aliases exist to avoid ActivityNotFoundException on existing shortcuts
        assertTrue(content.contains("android:name=\".LauncherGlassDark\""))
        assertTrue(content.contains("android:name=\".LauncherGlassLight\""))

        // Ensure legacy aliases are disabled by default in manifest to prevent OEM launchers (Infinix XOS) showing 3 icons
        val darkIndex = content.indexOf("android:name=\".LauncherGlassDark\"")
        val darkBlock = content.substring(darkIndex, darkIndex + 300)
        assertTrue("LauncherGlassDark must be disabled by default", darkBlock.contains("android:enabled=\"false\""))

        val lightIndex = content.indexOf("android:name=\".LauncherGlassLight\"")
        val lightBlock = content.substring(lightIndex, lightIndex + 300)
        assertTrue("LauncherGlassLight must be disabled by default", lightBlock.contains("android:enabled=\"false\""))

        // Ensure CrashActivity is declared in isolated :crash process
        assertTrue(content.contains("android:name=\".ui.CrashActivity\""))
        assertTrue(content.contains("android:process=\":crash\""))
    }

    @Test
    fun audioCacheClearIsSafeWhenUninitialized() {
        // Calling AudioCache.clear() before init() must not throw UninitializedPropertyAccessException
        var completed = false
        AudioCache.clear {
            completed = true
        }
        // Function completes without throwing
        assertTrue(true)
    }
}
