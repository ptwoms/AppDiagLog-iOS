package com.appdiaglog.server.storage.adapter

import com.appdiaglog.server.storage.adapter.csv.CsvSessionStore
import com.appdiaglog.server.storage.adapter.sqlite.SqliteEncryptedSessionStore
import org.junit.jupiter.api.AfterEach
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import org.springframework.data.domain.PageRequest
import java.nio.file.Path
import java.util.Base64
import kotlin.io.path.deleteIfExists

/**
 * Verifies the SQLite and CSV [SessionStore] adapters honour the shared contract:
 * upsert by session_id (idempotent), filter+paginate sessions, filter+paginate
 * events. The JPA path is covered by the Spring Boot integration tests.
 */
class StorageAdapterTest {

    @TempDir lateinit var tempDir: Path

    private lateinit var sqlitePath: Path
    private lateinit var sqlite: SqliteEncryptedSessionStore
    private lateinit var csv: CsvSessionStore

    @AfterEach
    fun tearDown() {
        runCatching { sqlite.close() }
        runCatching { sqlitePath.deleteIfExists() }
    }

    private fun makeSqlite(): SqliteEncryptedSessionStore {
        sqlitePath = tempDir.resolve("test.db")
        val masterKey = Base64.getEncoder().encodeToString(ByteArray(32) { it.toByte() })
        return SqliteEncryptedSessionStore(
            jdbcUrl = "jdbc:sqlite:${sqlitePath.toAbsolutePath()}",
            masterKeyBase64 = masterKey,
        ).also { sqlite = it }
    }

    private fun makeCsv(): CsvSessionStore = CsvSessionStore(tempDir.resolve("csv")).also { csv = it }

    private val sampleSession = DecryptedSession(
        id = "session-1",
        keyId = "k1",
        createdAt = "2026-04-18T10:00:00Z",
        sealedAt = "2026-04-18T10:05:00Z",
        eventCount = 2,
        sessionTag = "checkout-crash",
        deviceMetadata = mapOf("os" to "iOS 18", "app_version" to "1.0.0", "model" to "iPhone15,2"),
    )
    private val sampleEvents = listOf(
        DecryptedEvent("session-1", 1, "2026-04-18T10:00:01Z", "Home", "screen_view", "info", mapOf("a" to "1")),
        DecryptedEvent("session-1", 2, "2026-04-18T10:00:02Z", "Home", "tap", "error", mapOf("button" to "pay")),
    )

    @Test fun `sqlite roundtrips a session and its events`() = runAdapterContract(makeSqlite())
    @Test fun `csv roundtrips a session and its events`() = runAdapterContract(makeCsv())

    @Test fun `sqlite is idempotent on re-persist`() = runIdempotencyContract(makeSqlite())
    @Test fun `csv is idempotent on re-persist`() = runIdempotencyContract(makeCsv())

    private fun runAdapterContract(store: SessionStore) {
        store.persistSession(sampleSession, sampleEvents)

        // findSession + existsSession
        assertNotNull(store.findSession("session-1"))
        assertTrue(store.existsSession("session-1"))
        assertNull(store.findSession("missing-id"))

        // listSessions with a filter
        val all = store.listSessions(SessionFilter(), PageRequest.of(0, 10))
        assertEquals(1, all.totalElements)
        assertEquals("iOS 18", all.content.first().os)

        val osFiltered = store.listSessions(SessionFilter(os = "iOS 18"), PageRequest.of(0, 10))
        assertEquals(1, osFiltered.totalElements)

        // listEvents with level filter
        val allEvents = store.listEvents("session-1", EventFilter(), PageRequest.of(0, 10))
        assertEquals(2, allEvents.totalElements)
        val errors = store.listEvents("session-1", EventFilter(level = "error"), PageRequest.of(0, 10))
        assertEquals(1, errors.totalElements)
        assertEquals("tap", errors.content.first().event)
        assertEquals("pay", errors.content.first().props["button"])
    }

    private fun runIdempotencyContract(store: SessionStore) {
        store.persistSession(sampleSession, sampleEvents)
        // Re-persist with a different event set — must replace, not append.
        val newer = listOf(
            DecryptedEvent("session-1", 1, "2026-04-18T10:00:01Z", "Home", "screen_view", "info", emptyMap()),
            DecryptedEvent("session-1", 2, "2026-04-18T10:00:02Z", "Home", "tap", "info", emptyMap()),
            DecryptedEvent("session-1", 3, "2026-04-18T10:00:03Z", "Home", "scroll", "info", emptyMap()),
        )
        store.persistSession(sampleSession.copy(eventCount = 3), newer)

        val events = store.listEvents("session-1", EventFilter(), PageRequest.of(0, 10))
        assertEquals(3, events.totalElements)
    }
}
