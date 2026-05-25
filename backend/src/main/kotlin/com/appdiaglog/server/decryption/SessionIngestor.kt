package com.appdiaglog.server.decryption

import com.fasterxml.jackson.core.type.TypeReference
import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import com.appdiaglog.server.model.EventEnvelope
import com.appdiaglog.server.model.SessionEnvelope
import com.appdiaglog.server.storage.adapter.DecryptedEvent
import com.appdiaglog.server.storage.adapter.DecryptedSession
import com.appdiaglog.server.storage.adapter.SessionStore
import com.appdiaglog.server.vault.KeyVaultService
import org.springframework.stereotype.Service
import java.util.Base64

/**
 * Single-session decrypt + persist. Lives in its own bean so the persistence
 * call goes through the storage adapter (JPA / SQLite / CSV) — chosen at boot.
 *
 * The decrypt path itself is storage-agnostic: it pulls algorithm strings from
 * the envelope, runs them through [SymmetricRegistry] / [KemRegistry], and
 * hands plain DTOs to the [SessionStore].
 */
@Service
class SessionIngestor(
    private val vault: KeyVaultService,
    private val store: SessionStore,
) {
    private val mapper: ObjectMapper = jacksonObjectMapper()

    /**
     * Decrypts the envelope, parses the event array, injects session boundary
     * events, and writes through the configured [SessionStore]. The persist call
     * is idempotent: re-ingesting the same session_id replaces the previous rows.
     *
     * Returns 0 and persists nothing when the session is cleanly sealed but has
     * zero events (app launched and closed before any flush — nothing useful to
     * record).
     *
     * Boundary events injected:
     * - `session_start` (seq=-1, first): device metadata in props.
     * - `session_end` (seq=-1, last): level=info when cleanly sealed;
     *   level=warning + props["sealed"]="false" for abnormal terminations
     *   (force-kill, OOM, watchdog, debugger-intercepted crash).
     *
     * @return number of events written (including synthetic boundary events).
     * @throws IllegalStateException if the key id is unknown to the vault
     * @throws IllegalArgumentException if the envelope uses an unsupported algorithm
     * @throws javax.crypto.AEADBadTagException if AEAD tag verification fails
     */
    fun persist(envelope: SessionEnvelope): Int {
        val enc = envelope.encryption
        val symmetric = SymmetricRegistry.lookup(enc.algorithm)
        val kem = KemRegistry.lookup(enc.kekAlgorithm)

        val privateKey = vault.lookupPrivateKey(enc.keyId)
            ?: throw IllegalStateException("No private key in vault for key_id='${enc.keyId}'")

        val kemCt = Base64.getDecoder().decode(enc.kemCiphertext)
        val wrapped = Base64.getDecoder().decode(enc.wrappedDek)
        val iv = Base64.getDecoder().decode(enc.nonce)
        val payload = Base64.getDecoder().decode(envelope.payload)

        val dek = kem.unwrapDek(kemCt, wrapped, privateKey)
        val plaintext = try {
            symmetric.decrypt(
                key = dek,
                iv = iv,
                ciphertextAndTag = payload,
                aad = CryptoOps.aad(envelope.sessionId, enc.keyId),
            )
        } finally {
            CryptoOps.wipe(dek)
            CryptoOps.wipe(privateKey)
        }

        val parsed: List<EventEnvelope> = mapper.readValue(
            plaintext,
            object : TypeReference<List<EventEnvelope>>() {},
        )

        val hasCleanSeal = envelope.sealedAt != null

        // Skip truly empty sessions that ended normally (app opened and closed
        // before the first flush — nothing useful to store).
        if (parsed.isEmpty() && hasCleanSeal) return 0

        val session = DecryptedSession(
            id = envelope.sessionId,
            keyId = enc.keyId,
            createdAt = envelope.createdAt,
            sealedAt = envelope.sealedAt,
            eventCount = envelope.eventCount,
            sessionTag = envelope.sessionTag,
            deviceMetadata = envelope.deviceMetadata.toMap(),
        )

        val rawEvents = parsed.map { ev ->
            DecryptedEvent(
                sessionId = envelope.sessionId,
                seq = ev.seq,
                ts = ev.ts,
                screen = ev.screen,
                event = ev.event,
                level = ev.level,
                props = ev.props,
            )
        }

        val events = withBoundaries(envelope, rawEvents)
        store.persistSession(session, events)
        return events.size
    }

    /**
     * Injects session_start and session_end boundary events.
     *
     * Boundary events use seq = -1 so they are identifiable programmatically.
     */
    private fun withBoundaries(
        envelope: SessionEnvelope,
        rawEvents: List<DecryptedEvent>,
    ): List<DecryptedEvent> {
        val hasCleanSeal = envelope.sealedAt != null

        val startProps = envelope.deviceMetadata.toMutableMap()
        envelope.sessionTag?.let { startProps["session_tag"] = it }

        val startEvent = DecryptedEvent(
            sessionId = envelope.sessionId,
            seq = -1L,
            ts = envelope.createdAt,
            screen = null,
            event = "session_start",
            level = "info",
            props = startProps,
        )

        val endTs = rawEvents.lastOrNull()?.ts
            ?: envelope.sealedAt
            ?: envelope.createdAt

        val endProps = mutableMapOf("event_count" to rawEvents.size.toString())
        val tail = mutableListOf<DecryptedEvent>()

        if (hasCleanSeal) {
            tail += DecryptedEvent(
                sessionId = envelope.sessionId,
                seq = -1L,
                ts = envelope.sealedAt!!,
                screen = null,
                event = "session_end",
                level = "info",
                props = endProps,
            )
        } else {
            endProps["sealed"] = "false"
            tail += DecryptedEvent(
                sessionId = envelope.sessionId,
                seq = -1L,
                ts = endTs,
                screen = null,
                event = "session_end",
                level = "warning",
                props = endProps,
            )
        }

        return buildList {
            add(startEvent)
            addAll(rawEvents)
            addAll(tail)
        }
    }

}
