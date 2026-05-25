package com.appdiaglog.server.decryption

import org.bouncycastle.jcajce.SecretKeyWithEncapsulation
import org.bouncycastle.jcajce.spec.KEMExtractSpec
import org.bouncycastle.pqc.jcajce.provider.BouncyCastlePQCProvider
import java.security.KeyFactory
import java.security.PrivateKey
import java.security.spec.PKCS8EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Undo the operations the device did:
 *
 *   1. ML-KEM-768 decapsulate(kem_ciphertext, privateKey)  → sharedSecret
 *   2. AES-KWP unwrap(wrapped_dek, sharedSecret)           → DEK
 *   3. AES-GCM decrypt(payload, DEK, IV, AAD)              → plaintext events JSON
 *
 * AAD is `"<session_id>|<key_id>"` UTF-8 — must be identical to what the
 * client used or the GCM tag fails verification. This binds the envelope
 * metadata to the ciphertext, so tampering with either header field invalidates
 * the whole envelope.
 *
 * All `ByteArray` inputs that contain key material are wiped on exit — see
 * `wipe()`. We can't guarantee the JVM honors this (GC may have already
 * copied), but it shortens the window where a heap dump would expose secrets.
 */
object CryptoOps {

    private const val KEM_ALGORITHM = "KYBER" // BC's name for ML-KEM family
    private const val GCM_TRANSFORM = "AES/GCM/NoPadding"
    private const val KWP_TRANSFORM = "AESWRAPPAD"
    private const val GCM_TAG_BITS = 128
    private const val GCM_IV_BYTES = 12

    /**
     * Recover the per-session DEK from the envelope's KEM ciphertext + wrapped DEK.
     *
     * @param kemCiphertext output of ML-KEM encapsulation done on the device
     * @param wrappedDek    AES-KWP-wrapped DEK produced by the device
     * @param privateKey    server-side ML-KEM private key (PKCS#8 encoded)
     * @return raw 32-byte DEK. Caller MUST wipe after use.
     */
    fun unwrapDek(
        kemCiphertext: ByteArray,
        wrappedDek: ByteArray,
        privateKey: ByteArray,
    ): ByteArray {
        // Decapsulate KEM → shared secret (32 bytes for ML-KEM-768).
        val keyFactory = KeyFactory.getInstance(KEM_ALGORITHM, BouncyCastlePQCProvider.PROVIDER_NAME)
        val pkcs8 = PKCS8EncodedKeySpec(privateKey)
        val privKey: PrivateKey = keyFactory.generatePrivate(pkcs8)

        val extractor = KeyGenerator.getInstance(KEM_ALGORITHM, BouncyCastlePQCProvider.PROVIDER_NAME)
        extractor.init(KEMExtractSpec(privKey, kemCiphertext, "AES-KWP"))
        val shared = (extractor.generateKey() as SecretKeyWithEncapsulation).encoded

        return try {
            // Unwrap the DEK with the shared secret using AES-KWP (RFC 5649).
            val cipher = Cipher.getInstance(KWP_TRANSFORM)
            cipher.init(Cipher.UNWRAP_MODE, SecretKeySpec(shared, "AES"))
            val dekKey = cipher.unwrap(wrappedDek, "AES", Cipher.SECRET_KEY)
            dekKey.encoded
        } finally {
            wipe(shared)
        }
    }

    /**
     * Decrypt the AES-GCM payload using the recovered DEK.
     *
     * @param payload  ciphertext + 16-byte tag, exactly as produced by the SDKs
     *                 iOS emits `sealedBox.ciphertext + sealedBox.tag`.
     * @param iv       12-byte GCM IV (envelope.encryption.nonce)
     * @param dek      32-byte data encryption key
     * @param aad      `"<session_id>|<key_id>"` UTF-8 bytes
     */
    fun decryptPayload(
        payload: ByteArray,
        iv: ByteArray,
        dek: ByteArray,
        aad: ByteArray,
    ): ByteArray {
        require(iv.size == GCM_IV_BYTES) { "GCM expects a 96-bit IV (got ${iv.size} bytes)." }
        require(dek.size == 32) { "DEK must be 32 bytes (got ${dek.size})." }
        require(payload.size >= 16) { "Payload must include the 16-byte GCM tag." }

        val cipher = Cipher.getInstance(GCM_TRANSFORM)
        cipher.init(
            Cipher.DECRYPT_MODE,
            SecretKeySpec(dek, "AES"),
            GCMParameterSpec(GCM_TAG_BITS, iv),
        )
        cipher.updateAAD(aad)
        return cipher.doFinal(payload)
    }

    /** AAD format is "<session_id>|<key_id>" — same on every platform. */
    fun aad(sessionId: String, keyId: String): ByteArray =
        "$sessionId|$keyId".toByteArray(Charsets.UTF_8)

    /** Best-effort zero of in-memory key material. */
    fun wipe(bytes: ByteArray) {
        for (i in bytes.indices) bytes[i] = 0
    }
}
