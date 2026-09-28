package com.fortune.vibramusic.data.canvas

import android.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Provides the built-in encrypted Spotify sp_dc service token for Canvas fetching.
 *
 * The token is encrypted using AES-128-CBC with PKCS5 padding, and the key and IV
 * are split into XOR-masked byte arrays so the plaintext token never appears in
 * source code literals, resources, or the compiled DEX string pool.
 */
internal object SpotifyTokenSecret {

    private val KM = byteArrayOf(-96, -126, -58, 72, -19, 33, -33, 122, -82, -66, 47, 46, 75, -85, -114, 110)
    private val KD = byteArrayOf(-67, 57, -85, -25, 67, 126, -121, -80, -77, -54, -71, 31, -86, 46, -37, 65)

    private val IM = byteArrayOf(107, -10, 30, -118, -82, 111, 92, 66, -20, -51, 118, 1, 10, -51, -75, 127)
    private val ID = byteArrayOf(-61, 39, 117, 56, 26, 103, 9, -10, -21, 66, 103, 11, 86, 36, 114, 46)

    private const val CT = "hzgBnXFT+2mf1gsDsgzVaIcYVwlGCvIatt76OTNDq0HgO5gg5fTuZZTqAae4w0wRO+25Rn1YD2YJ9FwbEH1I0DRaM5EcgW7CV74zqekUufvtrAbJAkYiA1UXpNwivuKNzeOA4vfzhQT5JNK8ma18Z0kS3B7w3X8JTVMkBRvFM18G9owuzuquxlgO5mHBb+72iLyqVmpSIF6XTuYeDbeTA7uCQL/CncRjQ2HglcuyhY1+MSvCaTBEhXTgzviXS+3Snum5WHZd2SMQ8Vka0YlR3SdDEIS2Eowha4gseNpOloJpcTgGXmWgASvNlGG+7huRdSOCCGClVkSobdj6VFhePUo7VvccByFEiwyrMGQnQ3Q="

    @Volatile
    private var cachedToken: String? = null

    /**
     * Decrypts and returns the built-in Spotify sp_dc token in memory.
     * Returns null if decryption fails for any unexpected reason.
     */
    fun getBuiltInSpdc(): String? {
        cachedToken?.let { return it }
        return runCatching {
            val key = ByteArray(16) { i -> (KM[i].toInt() xor KD[i].toInt()).toByte() }
            val iv = ByteArray(16) { i -> (IM[i].toInt() xor ID[i].toInt()).toByte() }
            val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(iv))
            val cipherBytes = Base64.decode(CT, Base64.DEFAULT)
            val decrypted = cipher.doFinal(cipherBytes)
            val token = String(decrypted, Charsets.UTF_8)
            cachedToken = token
            token
        }.getOrNull()
    }
}
