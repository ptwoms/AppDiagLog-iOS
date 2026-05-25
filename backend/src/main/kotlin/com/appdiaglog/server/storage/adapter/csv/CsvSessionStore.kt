package com.appdiaglog.server.storage.adapter.csv

import com.fasterxml.jackson.core.type.TypeReference
import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import com.appdiaglog.server.storage.adapter.DecryptedEvent
import com.appdiaglog.server.storage.adapter.DecryptedSession
import com.appdiaglog.server.storage.adapter.EventFilter
import com.appdiaglog.server.storage.adapter.SessionFilter
import com.appdiaglog.server.storage.adapter.SessionStore
import org.apache.commons.csv.CSVFormat
import org.apache.commons.csv.CSVPrinter
import org.apache.commons.csv.CSVRecord
import org.slf4j.LoggerFactory
import org.springframework.data.domain.Page
import org.springframework.data.domain.PageImpl
import org.springframework.data.domain.Pageable
import java.io.BufferedReader
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import kotlin.io.path.exists
import kotlin.io.path.outputStream
import kotlin.io.path.readText

/**
 * Append-only CSV-backed [SessionStore]. Intended for offline analysis flows
 * where engineers want flat files instead of a database. Two files under
 * `appdiaglog.storage.csv.dir`:
 *
 *   sessions.csv  — one row per session (props as JSON in the metadata column)
 *   events.csv    — one row per event (props as JSON in a single column)
 *
 * Queries are linear scans with in-memory filtering. That's intentional: this
 * adapter exists for export/inspection use cases that aren't latency-sensitive.
 * For high-throughput querying use the JPA or SQLite adapter.
 *
 * Idempotent re-ingest is implemented by rewriting the affected file: read all
 * rows, drop the session being replaced, append the new rows, then atomic-rename
 * onto the target path. Acceptable while CSV files stay in the tens-of-MB range.
 */
class CsvSessionStore(private val directory: Path) : SessionStore {

    private val log = LoggerFactory.getLogger(javaClass)
    private val mapper: ObjectMapper = jacksonObjectMapper()
    private val propsType = object : TypeReference<Map<String, String>>() {}
    private val lock = ReentrantLock()

    init {
        Files.createDirectories(directory)
    }

    private val sessionsPath: Path get() = directory.resolve("sessions.csv")
    private val eventsPath: Path get() = directory.resolve("events.csv")

    override fun persistSession(session: DecryptedSession, events: List<DecryptedEvent>) {
        lock.withLock {
            rewriteSessions { existing ->
                existing.filterNot { it.id == session.id } + session
            }
            rewriteEvents { existing ->
                existing.filterNot { it.sessionId == session.id } + events
            }
        }
    }

    override fun findSession(id: String): DecryptedSession? = lock.withLock {
        readSessions().firstOrNull { it.id == id }
    }

    override fun existsSession(id: String): Boolean = lock.withLock {
        readSessions().any { it.id == id }
    }

    override fun listSessions(filter: SessionFilter, page: Pageable): Page<DecryptedSession> = lock.withLock {
        val matched = readSessions()
            .filter { matches(it, filter) }
            .sortedByDescending { it.createdAt }
        paginate(matched, page)
    }

    override fun listEvents(sessionId: String, filter: EventFilter, page: Pageable): Page<DecryptedEvent> = lock.withLock {
        val matched = readEvents()
            .filter { it.sessionId == sessionId && matches(it, filter) }
            .sortedBy { it.seq }
        paginate(matched, page)
    }

    // ---- read / write helpers ---------------------------------------------

    private val sessionHeaders = arrayOf(
        "id", "key_id", "created_at", "sealed_at", "event_count", "session_tag",
        "os", "app_version", "model", "locale", "device_metadata",
    )
    private val eventHeaders = arrayOf(
        "session_id", "seq", "ts", "level", "event_name", "screen", "props",
    )

    private fun readSessions(): List<DecryptedSession> {
        if (!sessionsPath.exists()) return emptyList()
        return Files.newBufferedReader(sessionsPath, StandardCharsets.UTF_8).use { reader ->
            csvFormat(sessionHeaders).parse(reader).records.map { toSession(it) }
        }
    }

    private fun readEvents(): List<DecryptedEvent> {
        if (!eventsPath.exists()) return emptyList()
        return Files.newBufferedReader(eventsPath, StandardCharsets.UTF_8).use { reader ->
            csvFormat(eventHeaders).parse(reader).records.map { toEvent(it) }
        }
    }

    private fun rewriteSessions(transform: (List<DecryptedSession>) -> List<DecryptedSession>) {
        val updated = transform(readSessions())
        atomicWrite(sessionsPath) { printer ->
            printer.printRecord(*sessionHeaders)
            for (s in updated) {
                printer.printRecord(
                    s.id,
                    s.keyId,
                    s.createdAt,
                    s.sealedAt ?: "",
                    s.eventCount,
                    s.sessionTag ?: "",
                    s.os ?: "",
                    s.appVersion ?: "",
                    s.model ?: "",
                    s.locale ?: "",
                    mapper.writeValueAsString(s.deviceMetadata),
                )
            }
        }
    }

    private fun rewriteEvents(transform: (List<DecryptedEvent>) -> List<DecryptedEvent>) {
        val updated = transform(readEvents())
        atomicWrite(eventsPath) { printer ->
            printer.printRecord(*eventHeaders)
            for (e in updated) {
                printer.printRecord(
                    e.sessionId,
                    e.seq,
                    e.ts,
                    e.level,
                    e.event,
                    e.screen ?: "",
                    mapper.writeValueAsString(e.props),
                )
            }
        }
    }

    private fun atomicWrite(target: Path, body: (CSVPrinter) -> Unit) {
        val tmp = target.resolveSibling(target.fileName.toString() + ".tmp")
        tmp.outputStream().bufferedWriter(StandardCharsets.UTF_8).use { w ->
            CSVPrinter(w, CSVFormat.DEFAULT).use(body)
        }
        Files.move(tmp, target, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
    }

    private fun csvFormat(headers: Array<String>): CSVFormat = CSVFormat.DEFAULT.builder()
        .setHeader(*headers)
        .setSkipHeaderRecord(true)
        .build()

    private fun toSession(rec: CSVRecord): DecryptedSession {
        val meta = runCatching {
            mapper.readValue(rec.get("device_metadata").ifEmpty { "{}" }, propsType)
        }.getOrElse { emptyMap() }
        return DecryptedSession(
            id = rec.get("id"),
            keyId = rec.get("key_id"),
            createdAt = rec.get("created_at"),
            sealedAt = rec.get("sealed_at").ifEmpty { null },
            eventCount = rec.get("event_count").toIntOrNull() ?: 0,
            sessionTag = rec.get("session_tag").ifEmpty { null },
            deviceMetadata = meta,
        )
    }

    private fun toEvent(rec: CSVRecord): DecryptedEvent {
        val props = runCatching {
            mapper.readValue(rec.get("props").ifEmpty { "{}" }, propsType)
        }.getOrElse { emptyMap() }
        return DecryptedEvent(
            sessionId = rec.get("session_id"),
            seq = rec.get("seq").toLongOrNull() ?: 0,
            ts = rec.get("ts"),
            screen = rec.get("screen").ifEmpty { null },
            event = rec.get("event_name"),
            level = rec.get("level"),
            props = props,
        )
    }

    private fun matches(s: DecryptedSession, f: SessionFilter): Boolean {
        if (f.from != null && s.createdAt < f.from) return false
        if (f.to != null && s.createdAt > f.to) return false
        if (f.appVersion != null && s.appVersion != f.appVersion) return false
        if (f.os != null && s.os != f.os) return false
        return true
    }

    private fun matches(e: DecryptedEvent, f: EventFilter): Boolean {
        if (f.level != null && e.level != f.level) return false
        if (f.event != null && e.event != f.event) return false
        if (f.screenPrefix != null && (e.screen == null || !e.screen!!.startsWith(f.screenPrefix))) return false
        if (f.from != null && e.ts < f.from) return false
        if (f.to != null && e.ts > f.to) return false
        return true
    }

    private fun <T> paginate(items: List<T>, page: Pageable): Page<T> {
        if (page.isUnpaged) return PageImpl(items, page, items.size.toLong())
        val from = page.offset.toInt().coerceAtMost(items.size)
        val to = (from + page.pageSize).coerceAtMost(items.size)
        return PageImpl(items.subList(from, to), page, items.size.toLong())
    }
}
