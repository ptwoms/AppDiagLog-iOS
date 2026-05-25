package com.appdiaglog.server.decryption

import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Dispatch table for symmetric-AEAD algorithms used in [SessionEnvelope].
 *
 * Adding a new algorithm: implement [SymmetricCipher] and register it in
 * [SymmetricRegistry.builtIn]. Backwards-compat is preserved as long as the
 * `algorithm` wire string keeps its meaning.
 */
interface SymmetricCipher {
    /** Wire-format identifier the SDK records in `encryption.algorithm`. */
    val algorithmId: String
    /** Decrypt the AEAD payload. Tag is appended to `ciphertextAndTag`. */
    fun decrypt(key: ByteArray, iv: ByteArray, ciphertextAndTag: ByteArray, aad: ByteArray): ByteArray
}

object SymmetricRegistry {
    private val table: Map<String, SymmetricCipher> = listOf(
        AesGcmServerCipher(keySize = 32),
        AesGcmServerCipher(keySize = 16),
        ChaCha20Poly1305ServerCipher(),
    ).associateBy { it.algorithmId }

    fun lookup(algorithmId: String): SymmetricCipher = table[algorithmId]
        ?: error("Unsupported symmetric algorithm in envelope: '$algorithmId'. " +
            "Supported: ${table.keys.sorted()}.")
}

internal class AesGcmServerCipher(private val keySize: Int) : SymmetricCipher {
    override val algorithmId: String = if (keySize == 32) "AES-256-GCM" else "AES-128-GCM"

    override fun decrypt(key: ByteArray, iv: ByteArray, ciphertextAndTag: ByteArray, aad: ByteArray): ByteArray {
        require(key.size == keySize) { "$algorithmId requires a $keySize-byte key (got ${key.size})." }
        require(iv.size == 12) { "GCM expects a 96-bit IV." }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
        cipher.updateAAD(aad)
        return cipher.doFinal(ciphertextAndTag)
    }
}

internal class ChaCha20Poly1305ServerCipher : SymmetricCipher {
    override val algorithmId: String = "ChaCha20-Poly1305"

    override fun decrypt(key: ByteArray, iv: ByteArray, ciphertextAndTag: ByteArray, aad: ByteArray): ByteArray {
        require(key.size == 32) { "ChaCha20-Poly1305 requires a 32-byte key." }
        require(iv.size == 12) { "ChaCha20-Poly1305 expects a 12-byte IV." }
        // JDK 11+ ships ChaCha20-Poly1305 natively. BC also provides it; we rely on
        // whatever the default JCE chain returns. The transform name is identical.
        val cipher = Cipher.getInstance("ChaCha20-Poly1305")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "ChaCha20"), IvParameterSpec(iv))
        cipher.updateAAD(aad)
        return cipher.doFinal(ciphertextAndTag)
    }
}
