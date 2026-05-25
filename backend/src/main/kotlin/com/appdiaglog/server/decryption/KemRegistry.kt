package com.appdiaglog.server.decryption

import org.bouncycastle.crypto.engines.AESEngine
import org.bouncycastle.crypto.engines.RFC3394WrapEngine
import org.bouncycastle.crypto.params.KeyParameter
import org.bouncycastle.jcajce.SecretKeyWithEncapsulation
import org.bouncycastle.jcajce.spec.KEMExtractSpec
import org.bouncycastle.pqc.crypto.mlkem.MLKEMExtractor
import org.bouncycastle.pqc.crypto.mlkem.MLKEMParameters
import org.bouncycastle.pqc.crypto.mlkem.MLKEMPrivateKeyParameters
import org.bouncycastle.pqc.jcajce.provider.BouncyCastlePQCProvider
import java.security.KeyFactory
import java.security.PrivateKey
import java.security.spec.MGF1ParameterSpec
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource
import javax.crypto.spec.SecretKeySpec

/**
 * Recovers the per-session DEK from an envelope's encrypted-key fields. Each
 * algorithm has its own [KemUnwrapper] implementation; the dispatcher picks one
 * based on `encryption.kek_algorithm`.
 *
 * Adding a new algorithm: implement [KemUnwrapper], register it in
 * [KemRegistry.builtIn]. The wire-format string must match exactly what the SDK
 * emits.
 */
interface KemUnwrapper {
    val algorithmId: String
    /**
     * @param kemCiphertext value from `encryption.kem_ciphertext` (may be empty for RSA)
     * @param wrappedDek    value from `encryption.wrapped_dek`
     * @param privateKey    PKCS#8-encoded private key bytes from the vault
     * @return raw DEK bytes — caller MUST wipe after use
     */
    fun unwrapDek(kemCiphertext: ByteArray, wrappedDek: ByteArray, privateKey: ByteArray): ByteArray
}

object KemRegistry {
    private val table: Map<String, KemUnwrapper> = listOf(
        MlKemUnwrapper("ML-KEM-768"),
        MlKemUnwrapper("ML-KEM-512"),
        RsaOaepUnwrapper(),
        EcdhKemUnwrapper(),
    ).associateBy { it.algorithmId }

    fun lookup(algorithmId: String): KemUnwrapper = table[algorithmId]
        ?: error("Unsupported KEK algorithm in envelope: '$algorithmId'. " +
            "Supported: ${table.keys.sorted()}.")
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/**
 * Undoes the DEK wrapping regardless of which AES key-wrap scheme was used.
 *
 * Two wire formats exist:
 *
 *   iOS (AesKwp.swift): CCSymmetricKeyWrap uses RFC 3394 (IV = A6A6A6A6A6A6A6A6).
 *   The caller manually prepends [A6 59 59 A6 | len_4be] to the DEK before
 *   wrapping, so the decrypted plaintext blocks contain that header. The
 *   [RFC3394WrapEngine] validates the recovered IV — this is used as the detector.
 *
 *   True RFC 5649 (Android BouncyCastle AESWRAPPAD or any compliant SDK): the AIV
 *   [A6 59 59 A6 | MLI_4be] is used inside the KW loop. The wrapped blob is smaller
 *   (no manual header in plaintext). The [RFC3394WrapEngine] IV check fails → fall
 *   back to the JCE "AESWRAPPAD" cipher which handles it correctly.
 */
private fun aesKwpUnwrap(kek: ByteArray, wrapped: ByteArray): ByteArray {
    try {
        val engine = RFC3394WrapEngine(AESEngine.newInstance())
        engine.init(false, KeyParameter(kek))
        val padded = engine.unwrap(wrapped, 0, wrapped.size)
        return rfc5649Unpad(padded)
    } catch (ignored: Exception) { }
    val keySpec = SecretKeySpec(kek, "AES")
    val cipher = Cipher.getInstance("AESWRAPPAD")
    cipher.init(Cipher.UNWRAP_MODE, keySpec)
    try {
        return cipher.unwrap(wrapped, "AES", Cipher.SECRET_KEY).encoded
    } catch (e: Exception) {
        throw IllegalArgumentException(
            "Failed to unwrap DEK. The envelope was not produced with the public key " +
                "matching this vault private key, or wrapped_dek is corrupted " +
                "(kek=${kek.size}B, wrapped_dek=${wrapped.size}B).",
            e,
        )
    }
}

/**
 * Strips the RFC 5649 header that AesKwp.swift manually prepends to the
 * plaintext before RFC 3394 wrapping.
 * Header layout: [A6 59 59 A6 | original_length_4be].
 */
private fun rfc5649Unpad(data: ByteArray): ByteArray {
    require(data.size >= 8) {
        "Data too short (${data.size} B) for RFC 5649 header"
    }
    require(
        data[0] == 0xA6.toByte() && data[1] == 0x59.toByte() &&
        data[2] == 0x59.toByte() && data[3] == 0xA6.toByte()
    ) {
        "Invalid RFC 5649 marker: ${data.take(4).joinToString("") { "%02x".format(it) }}"
    }
    val length = ((data[4].toInt() and 0xFF) shl 24) or
                 ((data[5].toInt() and 0xFF) shl 16) or
                 ((data[6].toInt() and 0xFF) shl  8) or
                  (data[7].toInt() and 0xFF)
    require(length <= data.size - 8) {
        "RFC 5649 MLI $length exceeds available data (${data.size - 8} B)"
    }
    return data.copyOfRange(8, 8 + length)
}

// ---------------------------------------------------------------------------
// MARK: - implementations
// ---------------------------------------------------------------------------

/** ML-KEM (FIPS 203). BouncyCastle's `KYBER` provider name covers both 512 and 768. */
internal class MlKemUnwrapper(override val algorithmId: String) : KemUnwrapper {

    override fun unwrapDek(kemCiphertext: ByteArray, wrappedDek: ByteArray, privateKey: ByteArray): ByteArray {
        val shared = decapsulate(privateKey, kemCiphertext)
        return try {
            aesKwpUnwrap(shared, wrappedDek)
        } finally {
            CryptoOps.wipe(shared)
        }
    }

    /**
     * Accepts two private-key wire formats:
     *
     *  1. **PKCS#8 DER** — produced by [InMemoryKeyVault.generateKeyPair] (BouncyCastle).
     *
     *  2. **Raw OQS/liboqs expanded key** — produced by `keygen.py` via pyoqs.
     *     FIPS 203 §6.4 layout: s || t || rho || H(ek) || z
     *     ML-KEM-768: 2400 bytes  (s=1152, t=1152, rho=32, H=32, z=32)
     *     ML-KEM-512: 1632 bytes  (s=768,  t=768,  rho=32, H=32, z=32)
     */
    private fun decapsulate(privateKey: ByteArray, kemCiphertext: ByteArray): ByteArray {
        // PKCS#8 path: BouncyCastle-generated keys.
        try {
            val kf = KeyFactory.getInstance("KYBER", BouncyCastlePQCProvider.PROVIDER_NAME)
            val priv: PrivateKey = kf.generatePrivate(PKCS8EncodedKeySpec(privateKey))
            val extractor = KeyGenerator.getInstance("KYBER", BouncyCastlePQCProvider.PROVIDER_NAME)
            extractor.init(KEMExtractSpec(priv, kemCiphertext, "AES"))
            return (extractor.generateKey() as SecretKeyWithEncapsulation).encoded
        } catch (_: Exception) { }

        // Raw OQS/liboqs expanded-key path: keygen.py output.
        // Layout (FIPS 203 dk): s || ek(t||rho) || H(ek) || z
        val (mlKemParams, sLen) = when (algorithmId) {
            "ML-KEM-768" -> MLKEMParameters.ml_kem_768 to 1152
            "ML-KEM-512" -> MLKEMParameters.ml_kem_512 to 768
            else -> error("No raw-key decoder for algorithm: $algorithmId")
        }
        val expectedSize = sLen * 2 + 96  // s + t + rho(32) + H(ek)(32) + z(32)
        require(privateKey.size == expectedSize) {
            "Expected $expectedSize-byte raw OQS key for $algorithmId, got ${privateKey.size} bytes. " +
            "Key must be PKCS#8 DER or the raw liboqs secret key."
        }
        val s     = privateKey.copyOfRange(0,              sLen)
        val t     = privateKey.copyOfRange(sLen,           sLen * 2)
        val rho   = privateKey.copyOfRange(sLen * 2,       sLen * 2 + 32)
        val hpk   = privateKey.copyOfRange(sLen * 2 + 32,  sLen * 2 + 64)
        val nonce = privateKey.copyOfRange(sLen * 2 + 64,  sLen * 2 + 96)
        val privParams = MLKEMPrivateKeyParameters(mlKemParams, s, hpk, nonce, t, rho)
        return MLKEMExtractor(privParams).extractSecret(kemCiphertext)
    }
}

/** RSA-OAEP with SHA-256, MGF1-SHA-256. */
internal class RsaOaepUnwrapper : KemUnwrapper {
    override val algorithmId: String = "RSA-OAEP-3072"

    override fun unwrapDek(kemCiphertext: ByteArray, wrappedDek: ByteArray, privateKey: ByteArray): ByteArray {
        val priv = KeyFactory.getInstance("RSA").generatePrivate(PKCS8EncodedKeySpec(privateKey))
        val cipher = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            priv,
            OAEPParameterSpec("SHA-256", "MGF1", MGF1ParameterSpec.SHA256, PSource.PSpecified.DEFAULT),
        )
        return cipher.doFinal(wrappedDek)
    }
}

/** ECDH-P256 ephemeral-static + HKDF-SHA-256 + AES-KWP. */
internal class EcdhKemUnwrapper : KemUnwrapper {
    override val algorithmId: String = "ECDH-P256+HKDF"

    override fun unwrapDek(kemCiphertext: ByteArray, wrappedDek: ByteArray, privateKey: ByteArray): ByteArray {
        val priv = KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(privateKey))
        val ephemeral = KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(kemCiphertext))
        val ka = KeyAgreement.getInstance("ECDH")
        ka.init(priv)
        ka.doPhase(ephemeral, true)
        val shared = ka.generateSecret()
        return try {
            val kek = hkdfSha256(
                ikm = shared,
                salt = kemCiphertext,
                info = HKDF_INFO,
                length = 32,
            )
            try {
                aesKwpUnwrap(kek, wrappedDek)
            } finally {
                CryptoOps.wipe(kek)
            }
        } finally {
            CryptoOps.wipe(shared)
        }
    }

    companion object {
        private val HKDF_INFO = "AppDiagLog/ECDH-P256+HKDF".toByteArray(Charsets.UTF_8)

        private fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
            require(length <= 32) { "Single-block HKDF only here." }
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(if (salt.isEmpty()) ByteArray(32) else salt, "HmacSHA256"))
            val prk = mac.doFinal(ikm)
            mac.init(SecretKeySpec(prk, "HmacSHA256"))
            mac.update(info)
            mac.update(0x01.toByte())
            return mac.doFinal().copyOf(length)
        }
    }
}
