package com.fortune.vibramusic.data.settings

/**
 * Supporter links and donation endpoints for Vibra Music.
 * All contributions are strictly voluntary; Vibra Music remains 100% free and open-source
 * with zero feature paywalls, zero ads, and zero user data collection.
 */
object SupportConfig {
    // Supporter Web Platforms
    var buyMeACoffeeUrl: String = ""
    var kofiUrl: String = ""
    var patreonUrl: String = ""
    var githubSponsorsUrl: String = "https://github.com/sponsors/Fortunehack45"
    var paypalUrl: String = ""

    // Crypto Donation Addresses
    var usdtAddress: String = ""
    var btcAddress: String = ""
    var ethAddress: String = ""
    var solAddress: String = ""

    val hasAnyPlatform: Boolean
        get() = buyMeACoffeeUrl.isNotBlank() ||
            kofiUrl.isNotBlank() ||
            patreonUrl.isNotBlank() ||
            githubSponsorsUrl.isNotBlank() ||
            paypalUrl.isNotBlank()

    val hasAnyCrypto: Boolean
        get() = usdtAddress.isNotBlank() ||
            btcAddress.isNotBlank() ||
            ethAddress.isNotBlank() ||
            solAddress.isNotBlank()
}
