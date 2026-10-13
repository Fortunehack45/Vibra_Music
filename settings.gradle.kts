pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // NewPipeExtractor is published via JitPack.
        maven("https://jitpack.io")
    }
}

rootProject.name = "vibramusic"
val iosOnly = providers.gradleProperty("iosOnly").orNull == "true" ||
    providers.gradleProperty("vibramusic.iosOnly").orNull == "true"
include(":shared")
include(":sharedUi")
if (!iosOnly) {
    include(":desktopApp")
    include(":app")
}
 