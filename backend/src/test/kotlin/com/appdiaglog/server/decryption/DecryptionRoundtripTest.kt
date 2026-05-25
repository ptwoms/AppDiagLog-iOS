package com.appdiaglog.server.decryption

import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import com.appdiaglog.server.model.EventEnvelope
import com.appdiaglog.server.model.ExportManifest
import com.appdiaglog.server.model.SessionEnvelope
import com.appdiaglog.server.storage.adapter.EventFilter
import com.appdiaglog.server.storage.adapter.SessionStore
import com.appdiaglog.server.vault.InMemoryKeyVault
import org.bouncycastle.jcajce.SecretKeyWithEncapsulation
import org.bouncycastle.jcajce.spec.KEMGenerateSpec
import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.bouncycastle.pqc.jcajce.provider.BouncyCastlePQCProvider
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.test.annotation.DirtiesContext
import org.springframework.test.context.ActiveProfiles
import java.io.ByteArrayOutputStream
import java.security.KeyFactory
import java.security.PublicKey
import java.security.SecureRandom
import java.security.Security
import java.security.spec.X509EncodedKeySpec
import java.util.Base64
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * End-to-end test that mirrors what the on-device SDKs do:
 *
 *   1. Generate an ML-KEM-768 keypair (server side).
 *   2. Encrypt a known event list with AES-256-GCM, wrap the DEK with KEM
 *      shared secret + AES-KWP, build a wire-format SessionEnvelope.
 *   3. Bundle into a ZIP exactly like ExportManager does.
 *   4. Feed the ZIP through DecryptionService and assert sessions/events
 *      land in the repos with the right contents.
 *
 * If anything in the on-disk format drifts on either client or server side,
 * this test catches it before a real device export does.
 */
@SpringBootTest
@ActiveProfiles("dev")
@DirtiesContext
class DecryptionRoundtripTest {

    @Autowired lateinit var decryption: DecryptionService
    @Autowired lateinit var store: SessionStore
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

        @JvmStatic
        @AfterAll
        fun teardown() {
            // Providers stay registered — Spring context lives across tests in
            // this JVM and removing them here would break any sibling test class.
        }
    }

    @Test
    fun `encrypted export from SDK round trips to decrypted rows`() {
        // 1. Server-side keypair, register the private half with the vault.
        val (publicKeyX509, privatePkcs8) = InMemoryKeyVault.generateKeyPair()
        val keyId = "test-key-${System.currentTimeMillis()}"
        vault.register(keyId, privatePkcs8)

        // 2. Build the envelope client-side (this is what iOS produce).
        val sessionId = "rt-${System.currentTimeMillis()}"
        val testEvents = (1..7).map { seq ->
            EventEnvelope(
                seq = seq.toLong(),
                ts = "2026-04-18T10:30:0$seq.000Z",
                sessionId = sessionId,
                screen = if (seq % 2 == 0) "HomeScreen" else "DetailScreen",
                event = "tap",
                level = if (seq == 7) "error" else "info",
                props = mapOf("button" to "save", "row" to "$seq"),
            )
        }
        val plaintext = mapper.writeValueAsBytes(testEvents)

        val envelope = buildEnvelope(
            sessionId = sessionId,
            keyId = keyId,
            publicKeyX509 = publicKeyX509,
            plaintext = plaintext,
            eventCount = testEvents.size,
            deviceMetadata = mapOf(
                "os" to "iOS 18",
                "app_version" to "1.0.0",
                "model" to "iPhone16,1",
                "locale" to "en-SG",
            ),
        )

        // 3. Pack into a ZIP just like ExportManager.
        val zipBytes = packZip(
            manifest = ExportManifest(
                version = 1,
                sdkVersion = "0.1.0-test",
                exportedAt = "2026-04-18T11:00:00.000Z",
                sessions = listOf(
                    ExportManifest.Session(
                        id = sessionId,
                        createdAt = envelope.createdAt,
                        sealedAt = envelope.sealedAt,
                        eventCount = envelope.eventCount,
                        sessionTag = envelope.sessionTag,
                        fileName = "session_$sessionId.enc",
                    )
                ),
            ),
            envelopes = mapOf("sessions/session_$sessionId.enc" to envelope),
        )

        // 4. Ingest and assert.
        val result = decryption.ingest(zipBytes.inputStream())
        assertEquals(1, result.sessionsImported, "exactly one session should import")
        assertEquals(testEvents.size, result.eventsImported, "all events should import")
        assertTrue(result.failures.isEmpty(), "no failures: ${result.failures}")

        val storedSession = store.findSession(sessionId)
            ?: error("expected session $sessionId to exist")
        assertEquals(testEvents.size, storedSession.eventCount)
        assertEquals(keyId, storedSession.keyId)
        assertEquals("iOS 18", storedSession.os)
        assertEquals("1.0.0", storedSession.appVersion)

        val storedEvents = store.listEvents(
            sessionId = sessionId,
            filter = EventFilter(),
            page = org.springframework.data.domain.PageRequest.of(0, 100),
        ).content
        assertEquals(testEvents.size, storedEvents.size)
        assertEquals(testEvents.map { it.seq }, storedEvents.map { it.seq })
        assertEquals("error", storedEvents.last().level)
    }

    @Test
    fun `bad key id is reported as a failure not a crash`() {
        // Build an envelope with a key the vault doesn't know about.
        val (publicKeyX509, _) = InMemoryKeyVault.generateKeyPair()
        val sessionId = "no-key-${System.currentTimeMillis()}"
        val envelope = buildEnvelope(
            sessionId = sessionId,
            keyId = "key-that-does-not-exist",
            publicKeyX509 = publicKeyX509,
            plaintext = mapper.writeValueAsBytes(emptyList<EventEnvelope>()),
            eventCount = 0,
            deviceMetadata = emptyMap(),
        )
        val zip = packZip(
            manifest = ExportManifest(1, "0.1.0", "2026-04-18T11:00:00Z", emptyList()),
            envelopes = mapOf("sessions/session_$sessionId.enc" to envelope),
        )

        val result = decryption.ingest(zip.inputStream())
        assertEquals(0, result.sessionsImported)
        assertEquals(1, result.failures.size)
        assertEquals(sessionId, result.failures.first().id)
        assertTrue(
            result.failures.first().reason.contains("key", ignoreCase = true),
            "reason should reference missing key, got: ${result.failures.first().reason}"
        )
    }

    // -- Helpers (mirror the SDK crypto path) ----------------------------

    /**
     * Build an envelope using the same primitives as [com.appdiaglog.sdk.crypto].
     * Validating against the BC version of the same ops we use server-side gives us
     * a tight round-trip that catches drift in either direction.
     */
    private fun buildEnvelope(
        sessionId: String,
        keyId: String,
        publicKeyX509: ByteArray,
        plaintext: ByteArray,
        eventCount: Int,
        deviceMetadata: Map<String, String>,
    ): SessionEnvelope {
        // KEM encapsulate against the public key.
        val pubKey: PublicKey = KeyFactory.getInstance("KYBER", BouncyCastlePQCProvider.PROVIDER_NAME)
            .generatePublic(X509EncodedKeySpec(publicKeyX509))
        val kemGen = KeyGenerator.getInstance("KYBER", BouncyCastlePQCProvider.PROVIDER_NAME)
        kemGen.init(KEMGenerateSpec(pubKey, "AES-KWP"), SecureRandom())
        val kem = kemGen.generateKey() as SecretKeyWithEncapsulation
        val sharedSecret = kem.encoded
        val kemCiphertext = kem.encapsulation

        // AES-KWP wrap the DEK using shared secret.
        val dek = ByteArray(32).also { SecureRandom().nextBytes(it) }
        val kwpCipher = Cipher.getInstance("AESWRAPPAD")
        kwpCipher.init(Cipher.WRAP_MODE, SecretKeySpec(sharedSecret, "AES"))
        val wrappedDek = kwpCipher.wrap(SecretKeySpec(dek, "AES"))

        // AES-256-GCM encrypt payload with the DEK and AAD = sessionId|keyId.
        val iv = ByteArray(12).also { SecureRandom().nextBytes(it) }
        val gcmCipher = Cipher.getInstance("AES/GCM/NoPadding")
        gcmCipher.init(
            Cipher.ENCRYPT_MODE,
            SecretKeySpec(dek, "AES"),
            GCMParameterSpec(128, iv),
        )
        gcmCipher.updateAAD(CryptoOps.aad(sessionId, keyId))
        val ciphertext = gcmCipher.doFinal(plaintext)

        return SessionEnvelope(
            version = 1,
            sessionId = sessionId,
            createdAt = "2026-04-18T10:30:00.000Z",
            sealedAt = "2026-04-18T10:35:00.000Z",
            eventCount = eventCount,
            sessionTag = null,
            deviceMetadata = deviceMetadata,
            encryption = SessionEnvelope.Encryption(
                algorithm = "AES-256-GCM",
                nonce = Base64.getEncoder().encodeToString(iv),
                kekAlgorithm = "ML-KEM-768",
                keyId = keyId,
                kemCiphertext = Base64.getEncoder().encodeToString(kemCiphertext),
                wrappedDek = Base64.getEncoder().encodeToString(wrappedDek),
            ),
            payload = Base64.getEncoder().encodeToString(ciphertext),
        )
    }

    private fun packZip(
        manifest: ExportManifest,
        envelopes: Map<String, SessionEnvelope>,
    ): ByteArray {
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { zos ->
            zos.putNextEntry(ZipEntry("manifest.json"))
            zos.write(mapper.writeValueAsBytes(manifest))
            zos.closeEntry()
            for ((name, env) in envelopes) {
                zos.putNextEntry(ZipEntry(name))
                zos.write(mapper.writeValueAsBytes(env))
                zos.closeEntry()
            }
        }
        return out.toByteArray()
    }
}
