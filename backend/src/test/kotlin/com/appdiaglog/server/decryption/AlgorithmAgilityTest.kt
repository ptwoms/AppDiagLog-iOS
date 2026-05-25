package com.appdiaglog.server.decryption

import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import com.appdiaglog.server.model.EventEnvelope
import com.appdiaglog.server.model.SessionEnvelope
import com.appdiaglog.server.storage.EventRepository
import com.appdiaglog.server.storage.SessionRepository
import com.appdiaglog.server.vault.InMemoryKeyVault
import org.bouncycastle.jcajce.SecretKeyWithEncapsulation
import org.bouncycastle.jcajce.spec.KEMGenerateSpec
import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.bouncycastle.pqc.jcajce.provider.BouncyCastlePQCProvider
import org.bouncycastle.pqc.jcajce.spec.KyberParameterSpec
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.DynamicTest
import org.junit.jupiter.api.TestFactory
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.test.annotation.DirtiesContext
import org.springframework.test.context.ActiveProfiles
import java.io.ByteArrayOutputStream
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.SecureRandom
import java.security.Security
import java.security.spec.ECGenParameterSpec
import java.security.spec.MGF1ParameterSpec
import java.security.spec.X509EncodedKeySpec
import java.util.Base64
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource
import javax.crypto.spec.SecretKeySpec

/**
 * Validates the full crypto agility matrix: every supported (symmetric × KEM)
 * pair must round-trip from an SDK-equivalent encrypt → backend decrypt path.
 *
 * Builds envelopes using raw JCE primitives (mirrors what the SDKs produce)
 * and feeds them through [DecryptionService] for the dispatcher to choose the
 * right unwrap/decrypt code path.
 */
@SpringBootTest
@ActiveProfiles("dev")
@DirtiesContext
class AlgorithmAgilityTest {

    @Autowired lateinit var decryption: DecryptionService
    @Autowired lateinit var sessions: SessionRepository
    @Autowired lateinit var events: EventRepository
    @Autowired lateinit var vault: InMemoryKeyVault

    private val mapper: ObjectMapper = jacksonObjectMapper()

    companion object {
        @JvmStatic
        @BeforeAll
        fun installProviders() {
            if (Security.getProvider(BouncyCastleProvider.PROVIDER_NAME) == null) {
                Security.addProvider(BouncyCastleProvider())
            }
            if (Security.getProvider(BouncyCastlePQCProvider.PROVIDER_NAME) == null) {
                Security.addProvider(BouncyCastlePQCProvider())
            }
        }
    }

    @TestFactory
    fun `every symmetric × kem pair round-trips through ingest`(): List<DynamicTest> {
        val pairs = mutableListOf<DynamicTest>()
        for (symmetric in listOf("AES-256-GCM", "AES-128-GCM", "ChaCha20-Poly1305")) {
            for (kem in listOf("ML-KEM-768", "ML-KEM-512", "RSA-OAEP-3072", "ECDH-P256+HKDF")) {
                pairs += DynamicTest.dynamicTest("$symmetric + $kem") {
                    runPair(symmetric, kem)
                }
            }
        }
        return pairs
    }

    private fun runPair(symmetricAlg: String, kemAlg: String) {
        val keyId = "test-${symmetricAlg}-${kemAlg}-${System.nanoTime()}"
        val keyMaterial = generateKeyPair(kemAlg)
        vault.register(keyId, keyMaterial.privatePkcs8)

        val sessionId = "rt-${System.nanoTime()}"
        val testEvents = (1..3).map { seq ->
            EventEnvelope(
                seq = seq.toLong(),
                ts = "2026-04-18T10:30:0$seq.000Z",
                sessionId = sessionId,
                screen = "screen-$seq",
                event = "tap",
                level = "info",
                props = mapOf("pair" to "$symmetricAlg+$kemAlg", "row" to "$seq"),
            )
        }
        val plaintext = mapper.writeValueAsBytes(testEvents)

        val envelope = buildEnvelope(
            sessionId = sessionId,
            keyId = keyId,
            plaintext = plaintext,
            symmetricAlg = symmetricAlg,
            kemAlg = kemAlg,
            publicKey = keyMaterial.publicX509OrPkcs1,
            eventCount = testEvents.size,
        )

        val zipBytes = packZip(envelope)
        val result = decryption.ingest(zipBytes.inputStream())
        assertTrue(result.failures.isEmpty(), "no failures: ${result.failures}")
        assertEquals(1, result.sessionsImported)
        assertEquals(testEvents.size, result.eventsImported)
    }

    // -- Key generation per algorithm ------------------------------------

    private data class KeyMaterial(val publicX509OrPkcs1: ByteArray, val privatePkcs8: ByteArray)

    private fun generateKeyPair(kemAlg: String): KeyMaterial = when (kemAlg) {
        "ML-KEM-768" -> {
            val kpg = KeyPairGenerator.getInstance("KYBER", BouncyCastlePQCProvider.PROVIDER_NAME)
            kpg.initialize(KyberParameterSpec.kyber768, SecureRandom())
            val kp = kpg.generateKeyPair()
            KeyMaterial(kp.public.encoded, kp.private.encoded)
        }
        "ML-KEM-512" -> {
            val kpg = KeyPairGenerator.getInstance("KYBER", BouncyCastlePQCProvider.PROVIDER_NAME)
            kpg.initialize(KyberParameterSpec.kyber512, SecureRandom())
            val kp = kpg.generateKeyPair()
            KeyMaterial(kp.public.encoded, kp.private.encoded)
        }
        "RSA-OAEP-3072" -> {
            val kpg = KeyPairGenerator.getInstance("RSA")
            kpg.initialize(3072, SecureRandom())
            val kp = kpg.generateKeyPair()
            KeyMaterial(kp.public.encoded, kp.private.encoded)
        }
        "ECDH-P256+HKDF" -> {
            val kpg = KeyPairGenerator.getInstance("EC")
            kpg.initialize(ECGenParameterSpec("secp256r1"))
            val kp = kpg.generateKeyPair()
            KeyMaterial(kp.public.encoded, kp.private.encoded)
        }
        else -> error("Unknown KEM algorithm: $kemAlg")
    }

    // -- Envelope builder (mirrors SDK behaviour) ------------------------

    private fun buildEnvelope(
        sessionId: String,
        keyId: String,
        plaintext: ByteArray,
        symmetricAlg: String,
        kemAlg: String,
        publicKey: ByteArray,
        eventCount: Int,
    ): SessionEnvelope {
        // Step 1: pick a fresh DEK sized to the symmetric algorithm.
        val keySize = when (symmetricAlg) {
            "AES-256-GCM", "ChaCha20-Poly1305" -> 32
            "AES-128-GCM" -> 16
            else -> error("Unknown symmetric algorithm $symmetricAlg")
        }
        val dek = ByteArray(keySize).also { SecureRandom().nextBytes(it) }

        // Step 2: wrap the DEK with the configured KEM.
        val (kemCiphertext, wrappedDek) = wrapDek(kemAlg, dek, publicKey)

        // Step 3: AEAD-encrypt the payload with the DEK.
        val (iv, ciphertext) = symmetricEncrypt(symmetricAlg, dek, plaintext, sessionId, keyId)

        return SessionEnvelope(
            version = 1,
            sessionId = sessionId,
            createdAt = "2026-04-18T10:30:00.000Z",
            sealedAt = "2026-04-18T10:35:00.000Z",
            eventCount = eventCount,
            sessionTag = null,
            deviceMetadata = mapOf("os" to "test"),
            encryption = SessionEnvelope.Encryption(
                algorithm = symmetricAlg,
                nonce = Base64.getEncoder().encodeToString(iv),
                kekAlgorithm = kemAlg,
                keyId = keyId,
                kemCiphertext = Base64.getEncoder().encodeToString(kemCiphertext),
                wrappedDek = Base64.getEncoder().encodeToString(wrappedDek),
                kekParams = null,
            ),
            payload = Base64.getEncoder().encodeToString(ciphertext),
        )
    }

    private fun wrapDek(kemAlg: String, dek: ByteArray, publicKey: ByteArray): Pair<ByteArray, ByteArray> {
        return when (kemAlg) {
            "ML-KEM-768", "ML-KEM-512" -> {
                val pub = KeyFactory.getInstance("KYBER", BouncyCastlePQCProvider.PROVIDER_NAME)
                    .generatePublic(X509EncodedKeySpec(publicKey))
                val kemGen = KeyGenerator.getInstance("KYBER", BouncyCastlePQCProvider.PROVIDER_NAME)
                kemGen.init(KEMGenerateSpec(pub, "AES-KWP"), SecureRandom())
                val kem = kemGen.generateKey() as SecretKeyWithEncapsulation
                val shared = kem.encoded
                val cipher = Cipher.getInstance("AESWRAPPAD")
                cipher.init(Cipher.WRAP_MODE, SecretKeySpec(shared, "AES"))
                kem.encapsulation to cipher.wrap(SecretKeySpec(dek, "AES"))
            }
            "RSA-OAEP-3072" -> {
                val pub = KeyFactory.getInstance("RSA").generatePublic(X509EncodedKeySpec(publicKey))
                val cipher = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding")
                cipher.init(
                    Cipher.ENCRYPT_MODE,
                    pub,
                    OAEPParameterSpec("SHA-256", "MGF1", MGF1ParameterSpec.SHA256, PSource.PSpecified.DEFAULT),
                )
                ByteArray(0) to cipher.doFinal(dek)
            }
            "ECDH-P256+HKDF" -> {
                val recipientPub = KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(publicKey))
                val kpg = KeyPairGenerator.getInstance("EC")
                kpg.initialize(ECGenParameterSpec("secp256r1"))
                val ephemeral = kpg.generateKeyPair()
                val ka = KeyAgreement.getInstance("ECDH")
                ka.init(ephemeral.private)
                ka.doPhase(recipientPub, true)
                val shared = ka.generateSecret()
                val ephemeralPubBytes = ephemeral.public.encoded
                val kek = hkdfSha256(shared, ephemeralPubBytes, "AppDiagLog/ECDH-P256+HKDF".toByteArray(), 32)
                val cipher = Cipher.getInstance("AESWRAPPAD")
                cipher.init(Cipher.WRAP_MODE, SecretKeySpec(kek, "AES"))
                ephemeralPubBytes to cipher.wrap(SecretKeySpec(dek, "AES"))
            }
            else -> error("Unknown KEM: $kemAlg")
        }
    }

    private fun symmetricEncrypt(
        algorithm: String,
        dek: ByteArray,
        plaintext: ByteArray,
        sessionId: String,
        keyId: String,
    ): Pair<ByteArray, ByteArray> {
        val aad = CryptoOps.aad(sessionId, keyId)
        val iv = ByteArray(12).also { SecureRandom().nextBytes(it) }
        return when (algorithm) {
            "AES-256-GCM", "AES-128-GCM" -> {
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(dek, "AES"), GCMParameterSpec(128, iv))
                cipher.updateAAD(aad)
                iv to cipher.doFinal(plaintext)
            }
            "ChaCha20-Poly1305" -> {
                val cipher = Cipher.getInstance("ChaCha20-Poly1305")
                cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(dek, "ChaCha20"), IvParameterSpec(iv))
                cipher.updateAAD(aad)
                iv to cipher.doFinal(plaintext)
            }
            else -> error("Unknown symmetric: $algorithm")
        }
    }

    private fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(if (salt.isEmpty()) ByteArray(32) else salt, "HmacSHA256"))
        val prk = mac.doFinal(ikm)
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        mac.update(info)
        mac.update(0x01.toByte())
        return mac.doFinal().copyOf(length)
    }

    private fun packZip(envelope: SessionEnvelope): ByteArray {
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { zos ->
            zos.putNextEntry(ZipEntry("manifest.json"))
            zos.write(mapper.writeValueAsBytes(mapOf("version" to 1, "sdkVersion" to "test")))
            zos.closeEntry()
            zos.putNextEntry(ZipEntry("sessions/session_${envelope.sessionId}.enc"))
            zos.write(mapper.writeValueAsBytes(envelope))
            zos.closeEntry()
        }
        return out.toByteArray()
    }
}
