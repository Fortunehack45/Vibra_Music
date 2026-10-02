import org.jetbrains.compose.desktop.application.dsl.TargetFormat

plugins {
    kotlin("jvm")
    id("org.jetbrains.compose")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

kotlin {
    jvmToolchain(17)
}

compose.resources {
    packageOfResClass = "com.fortune.vibramusic.desktop.resources"
}

dependencies {
    implementation(compose.desktop.currentOs)
    implementation(compose.material3)
    implementation(compose.materialIconsExtended)
    implementation(compose.components.resources)
    
    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-swing:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")

    // Image loading - Coil 3
    implementation("io.coil-kt.coil3:coil-compose:3.0.4")
    implementation("io.coil-kt.coil3:coil-network-okhttp:3.0.4")

    // Frosted glass
    implementation("dev.chrisbanes.haze:haze:1.3.1")
    implementation("dev.chrisbanes.haze:haze-materials:1.3.1")

    // HTTP / Network
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("io.ktor:ktor-client-core:3.0.3")
    implementation("io.ktor:ktor-client-okhttp:3.0.3")
    implementation("io.ktor:ktor-client-content-negotiation:3.0.3")
    implementation("io.ktor:ktor-serialization-kotlinx-json:3.0.3")

    // Desktop Media Player (VLCJ / LibVLC)
    implementation("uk.co.caprica:vlcj:4.8.3")

    // JNA for Windows Native Integration (SMTC / System Media Transport Controls, Media Keys)
    implementation("net.java.dev.jna:jna:5.14.0")
    implementation("net.java.dev.jna:jna-platform:5.14.0")

    // QR Code for party sharing
    implementation("com.google.zxing:core:3.5.3")

    // YouTube Stream extraction (NewPipeExtractor)
    implementation("com.github.TeamNewPipe:NewPipeExtractor:v0.26.3")
}

compose.desktop {
    application {
        mainClass = "com.fortune.vibramusic.desktop.MainKt"

        nativeDistributions {
            targetFormats(TargetFormat.Msi, TargetFormat.Exe)
            packageName = "VibraMusic"
            packageVersion = "1.8.22"
            description = "Vibra Music for Windows"
            copyright = "© 2026 Vibra Music"
            vendor = "Vibra Music"

            windows {
                menuGroup = "Vibra Music"
                upgradeUuid = "d78d227b-2850-4b53-90d5-33798cf0df83"
                dirChooser = true
                perUserInstall = true
                shortcut = true
                iconFile.set(project.file("src/main/resources/icon.ico"))
            }
        }
    }
}
