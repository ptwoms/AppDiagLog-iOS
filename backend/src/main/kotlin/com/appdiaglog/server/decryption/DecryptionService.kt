package com.appdiaglog.server.decryption

import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import com.appdiaglog.server.model.ExportManifest
import com.appdiaglog.server.model.SessionEnvelope
import org.slf4j.LoggerFactory
import org.springframework.stereotype.Service
import java.io.InputStream
import java.util.zip.ZipInputStream

/**
 * Owns the export-zip ingest pipeline. Workflow per upload:
 *
 *   read manifest.json        (plaintext metadata, used for triage)
 *   for each sessions/x.enc:
 *     parse JSON envelope
 *     hand off to SessionIngestor (single transaction per session) which:
 *       vault.lookup(key_id)    → fail if unknown
 *       decapsulate KEM         → shared secret
 *       unwrap DEK              → 32-byte AES key
 *       AES-GCM decrypt payload (AAD = "session_id|key_id")
 *       parse JSON event array
 *       UPSERT session row + delete-old-events + bulk insert new events
 *       wipe DEK
 *
 * One bad session does NOT fail the whole upload — it's recorded in the
 * [Result.failures] list so support can chase the missing key, while everything
 * else lands. This matches the SDK's "best-effort export" posture.
 *
 * Per-session persistence lives in [SessionIngestor] because Spring's
 * `@Transactional` only takes effect across bean boundaries (proxy interception).
 * Calling a `@Transactional` method from another method on the same bean
 * silently runs without a transaction.
 */
@Service
class DecryptionService(
    private val sessionIngestor: SessionIngestor,
) {
    private val log = LoggerFactory.getLogger(javaClass)
    private val mapper: ObjectMapper = jacksonObjectMapper()

    data class Result(
        val sessionsImported: Int,
        val eventsImported: Int,
        val imported: List<ImportedSession>,
        val failures: List<FailedSession>,
        val manifest: ExportManifest?,
    )

    data class ImportedSession(val id: String, val eventCount: Int, val keyId: String)
    data class FailedSession(val id: String?, val fileName: String, val reason: String)

    fun ingest(zipBytes: InputStream): Result {
        var manifest: ExportManifest? = null
        val envelopes = mutableMapOf<String, SessionEnvelope>() // fileName -> envelope

        // Pass 1: parse every entry. The SDK caps exports at ~10MB, so the
        // bounded read into memory is safe. We don't decrypt during parsing
        // to keep this function side-effect-free until validation passes.
        ZipInputStream(zipBytes).use { zin ->
            while (true) {
                val entry = zin.nextEntry ?: break
                val name = entry.name
                if (entry.isDirectory) continue
                val bytes = zin.readAllBytes()
                when {
                    name == "manifest.json" -> {
                        manifest = runCatching { mapper.readValue(bytes, ExportManifest::class.java) }
                            .getOrElse {
                                log.warn("Malformed manifest.json: ${it.message}")
                                null
                            }
                    }
                    name.startsWith("sessions/") && name.endsWith(".enc") -> {
                        val parsed = runCatching { mapper.readValue(bytes, SessionEnvelope::class.java) }
                            .getOrNull()
                        if (parsed != null) {
                            envelopes[name] = parsed
                        } else {
                            log.warn("Skipping malformed envelope: $name")
                        }
                    }
                    else -> log.debug("Ignoring zip entry: $name")
                }
            }
        }

        val imported = mutableListOf<ImportedSession>()
        val failures = mutableListOf<FailedSession>()

        for ((fileName, envelope) in envelopes) {
            try {
                val eventCount = sessionIngestor.persist(envelope)
                imported.add(ImportedSession(envelope.sessionId, eventCount, envelope.encryption.keyId))
            } catch (e: Exception) {
                log.error("Failed to ingest $fileName (session=${envelope.sessionId}): ${e.message}", e)
                failures.add(FailedSession(envelope.sessionId, fileName, e.message ?: e.javaClass.simpleName))
            }
        }

        val totalEvents = imported.sumOf { it.eventCount }
        log.info(
            "Ingest complete: {} sessions / {} events imported, {} failed.",
            imported.size, totalEvents, failures.size,
        )
        return Result(imported.size, totalEvents, imported, failures, manifest)
    }
}
