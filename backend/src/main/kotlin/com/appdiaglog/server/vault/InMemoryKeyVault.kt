package com.appdiaglog.server.vault

import org.bouncycastle.pqc.jcajce.provider.BouncyCastlePQCProvider
import org.bouncycastle.pqc.jcajce.spec.KyberParameterSpec
import org.slf4j.LoggerFactory
import org.springframework.beans.factory.annotation.Value
import org.springframework.boot.context.event.ApplicationReadyEvent
import org.springframework.context.event.EventListener
import org.springframework.stereotype.Service
import java.security.KeyPairGenerator
import java.security.SecureRandom
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap

/**
 * In-memory vault for development and integration tests. Loads keys two ways:
 *
 *  1. From the `appdiaglog.vault.inline-keys` config property (semicolon-
 *     separated `keyId=base64PrivateKey` entries).
 *  2. Programmatically via [register] — used by tests that need to bootstrap a
 *     fresh keypair against the real BC provider.
 *
 * Never use in production. Private keys live in the JVM heap as plain
 * `byte[]`; a heap dump exposes them. Real deployments must back this with
 * an HSM or KMS.
 */
@Service
class InMemoryKeyVault(
    @Value("\${appdiaglog.vault.inline-keys:}") private val inlineKeys: String,
) : KeyVaultService {

    private val log = LoggerFactory.getLogger(javaClass)
    private val store = ConcurrentHashMap<String, ByteArray>()

    @EventListener(ApplicationReadyEvent::class)
    fun loadInlineKeys() {
        if (inlineKeys.isBlank()) {
            log.warn("InMemoryKeyVault has no keys loaded. Set appdiaglog.vault.inline-keys " +
                "(format: keyId=base64;keyId2=base64) or call register() at runtime.")
            return
        }
        var loaded = 0
        for (chunk in inlineKeys.split(';')) {
            val trimmed = chunk.trim()
            if (trimmed.isEmpty()) continue
            val eq = trimmed.indexOf('=')
            if (eq <= 0) {
                log.error("Skipping malformed inline-keys entry: '${trimmed.take(20)}…'")
                continue
            }
            val keyId = trimmed.substring(0, eq).trim()
            val b64 = trimmed.substring(eq + 1).trim()
            try {
                val pkcs8 = Base64.getDecoder().decode(b64)
                store[keyId] = pkcs8
                loaded++
            } catch (e: Exception) {
                // Don't log the base64 — even partial leak of private-key material is unsafe.
                log.error("Failed to decode inline key '$keyId': ${e.javaClass.simpleName}")
            }
        }
        log.info("InMemoryKeyVault loaded $loaded key(s): {}", store.keys.toSortedSet())
    }

    override fun lookupPrivateKey(keyId: String): ByteArray? {
        val key = store[keyId]
        if (key == null) {
            log.warn("Vault miss for key_id='{}' — known: {}", keyId, store.keys)
        } else {
            log.debug("Vault hit for key_id='{}'", keyId)
        }
        // Defensive copy so a caller that wipes can't corrupt our canonical store.
        return key?.copyOf()
    }

    override fun knownKeyIds(): Set<String> = store.keys.toSet()

    /** Programmatic registration. Used by tests and by ops bootstrap scripts. */
    fun register(keyId: String, pkcs8PrivateKey: ByteArray) {
        store[keyId] = pkcs8PrivateKey.copyOf()
        log.info("Registered key '{}' ({} bytes)", keyId, pkcs8PrivateKey.size)
    }

    companion object {
        /**
         * Generate a fresh ML-KEM-768 keypair. Returns (publicX509, privatePkcs8)
         * suitable for either embedding in an SDK config (public) or registering
         * with the vault (private). Test-fixture grade — production keys come
         * from KMS.
         */
        fun generateKeyPair(): Pair<ByteArray, ByteArray> {
            val kpg = KeyPairGenerator.getInstance("KYBER", BouncyCastlePQCProvider.PROVIDER_NAME)
            kpg.initialize(KyberParameterSpec.kyber768, SecureRandom())
            val kp = kpg.generateKeyPair()
            return kp.public.encoded to kp.private.encoded
        }
    }
}
