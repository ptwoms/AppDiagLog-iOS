package com.appdiaglog.server.storage.adapter.sqlite

import com.fasterxml.jackson.core.type.TypeReference
import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import com.appdiaglog.server.storage.adapter.DecryptedEvent
import com.appdiaglog.server.storage.adapter.DecryptedSession
import com.appdiaglog.server.storage.adapter.EventFilter
import com.appdiaglog.server.storage.adapter.SessionFilter
import com.appdiaglog.server.storage.adapter.SessionStore
import org.slf4j.LoggerFactory
import org.springframework.data.domain.Page
import org.springframework.data.domain.PageImpl
import org.springframework.data.domain.Pageable
import java.security.SecureRandom
import java.sql.Connection
import java.sql.DriverManager
import java.util.Base64
import java.util.concurrent.locks.ReentrantLock
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlin.concurrent.withLock

/**
 * SQLite-backed [SessionStore] that encrypts sensitive columns at the application
 * layer with AES-256-GCM. Each ciphertext column carries its own IV; AAD binds
 * the ciphertext to its row identity so a row swap is detected at decrypt time.
 *
 * Schema:
 *   sessions(id PK, key_id, created_at, sealed_at, event_count, session_tag,
 *            metadata_ct, metadata_iv, os, app_version, model, locale, decrypted_at)
 *   events(session_id, seq, ts, level, event_name, screen, props_ct, props_iv,
 *          PRIMARY KEY(session_id, seq))
 *
 * The convenience columns (`os`, `app_version`, etc.) are stored plaintext to keep
 * them filterable; they're already lifted from `deviceMetadata` which the SDK
 * marks as plaintext-by-design (see CLAUDE.md). The full `deviceMetadata` map
 * goes into `metadata_ct` encrypted.
 *
 * Concurrency: SQLite serialises writers anyway. We share a single connection
 * behind a [ReentrantLock] for simplicity — the ingest path isn't a hot path,
 * and one process owns the DB file at a time.
 */
class SqliteEncryptedSessionStore(
    private val jdbcUrl: String,
    masterKeyBase64: String,
) : SessionStore, AutoCloseable {

    private val log = LoggerFactory.getLogger(javaClass)
    private val mapper: ObjectMapper = jacksonObjectMapper()
    private val propsType = object : TypeReference<Map<String, String>>() {}
    private val metaType = object : TypeReference<Map<String, String>>() {}

    private val masterKey: ByteArray = Base64.getDecoder().decode(masterKeyBase64).also {
        require(it.size == 32) {
            "appdiaglog.storage.sqlite.master-key must base64-decode to 32 bytes (got ${it.size})."
        }
    }
    private val rng = SecureRandom()
    private val lock = ReentrantLock()

    @Volatile private var conn: Connection? = null

    private fun connection(): Connection {
        conn?.let { return it }
        return lock.withLock {
            conn ?: run {
                Class.forName("org.sqlite.JDBC")
                val c = DriverManager.getConnection(jdbcUrl)
                c.autoCommit = true
                migrate(c)
                conn = c
                c
            }
        }
    }

    private fun migrate(c: Connection) {
        c.createStatement().use { st ->
            st.execute("""
                CREATE TABLE IF NOT EXISTS sessions (
                    id TEXT PRIMARY KEY,
                    key_id TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    sealed_at TEXT,
                    event_count INTEGER NOT NULL,
                    session_tag TEXT,
                    metadata_ct BLOB NOT NULL,
                    metadata_iv BLOB NOT NULL,
                    os TEXT, app_version TEXT, model TEXT, locale TEXT,
                    decrypted_at INTEGER NOT NULL
                )
            """.trimIndent())
            st.execute("CREATE INDEX IF NOT EXISTS idx_sessions_created_at ON sessions(created_at)")
            st.execute("CREATE INDEX IF NOT EXISTS idx_sessions_app_version ON sessions(app_version)")
            st.execute("CREATE INDEX IF NOT EXISTS idx_sessions_os ON sessions(os)")
            st.execute("""
                CREATE TABLE IF NOT EXISTS events (
                    session_id TEXT NOT NULL,
                    seq INTEGER NOT NULL,
                    ts TEXT NOT NULL,
                    level TEXT NOT NULL,
                    event_name TEXT NOT NULL,
                    screen TEXT,
                    props_ct BLOB NOT NULL,
                    props_iv BLOB NOT NULL,
                    PRIMARY KEY (session_id, seq)
                )
            """.trimIndent())
            st.execute("CREATE INDEX IF NOT EXISTS idx_events_session ON events(session_id)")
            st.execute("CREATE INDEX IF NOT EXISTS idx_events_level ON events(level)")
            st.execute("CREATE INDEX IF NOT EXISTS idx_events_event_name ON events(event_name)")
            st.execute("CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts)")
        }
    }

    override fun persistSession(session: DecryptedSession, events: List<DecryptedEvent>) {
        lock.withLock {
            val c = connection()
            c.autoCommit = false
            try {
                val (metaCt, metaIv) = encryptColumn(
                    plaintext = mapper.writeValueAsBytes(session.deviceMetadata),
                    aad = "session-metadata|${session.id}".toByteArray(),
                )
                c.prepareStatement("DELETE FROM sessions WHERE id = ?").use {
                    it.setString(1, session.id); it.executeUpdate()
                }
                c.prepareStatement("""
                    INSERT INTO sessions (id, key_id, created_at, sealed_at, event_count, session_tag,
                        metadata_ct, metadata_iv, os, app_version, model, locale, decrypted_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """.trimIndent()).use { ps ->
                    ps.setString(1, session.id)
                    ps.setString(2, session.keyId)
                    ps.setString(3, session.createdAt)
                    ps.setString(4, session.sealedAt)
                    ps.setInt(5, session.eventCount)
                    ps.setString(6, session.sessionTag)
                    ps.setBytes(7, metaCt)
                    ps.setBytes(8, metaIv)
                    ps.setString(9, session.os)
                    ps.setString(10, session.appVersion)
                    ps.setString(11, session.model)
                    ps.setString(12, session.locale)
                    ps.setLong(13, System.currentTimeMillis())
                    ps.executeUpdate()
                }
                c.prepareStatement("DELETE FROM events WHERE session_id = ?").use {
                    it.setString(1, session.id); it.executeUpdate()
                }
                if (events.isNotEmpty()) {
                    c.prepareStatement("""
                        INSERT INTO events (session_id, seq, ts, level, event_name, screen, props_ct, props_iv)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """.trimIndent()).use { ps ->
                        for (ev in events) {
                            val (propsCt, propsIv) = encryptColumn(
                                plaintext = mapper.writeValueAsBytes(ev.props),
                                aad = "event-props|${ev.sessionId}|${ev.seq}".toByteArray(),
                            )
                            ps.setString(1, ev.sessionId)
                            ps.setLong(2, ev.seq)
                            ps.setString(3, ev.ts)
                            ps.setString(4, ev.level)
                            ps.setString(5, ev.event)
                            ps.setString(6, ev.screen)
                            ps.setBytes(7, propsCt)
                            ps.setBytes(8, propsIv)
                            ps.addBatch()
                        }
                        ps.executeBatch()
                    }
                }
                c.commit()
            } catch (t: Throwable) {
                c.rollback()
                throw t
            } finally {
                c.autoCommit = true
            }
        }
    }

    override fun findSession(id: String): DecryptedSession? = lock.withLock {
        val c = connection()
        c.prepareStatement("SELECT * FROM sessions WHERE id = ?").use { ps ->
            ps.setString(1, id)
            val rs = ps.executeQuery()
            if (rs.next()) readSession(rs) else null
        }
    }

    override fun existsSession(id: String): Boolean = lock.withLock {
        val c = connection()
        c.prepareStatement("SELECT 1 FROM sessions WHERE id = ? LIMIT 1").use { ps ->
            ps.setString(1, id)
            ps.executeQuery().next()
        }
    }

    override fun listSessions(filter: SessionFilter, page: Pageable): Page<DecryptedSession> = lock.withLock {
        val c = connection()
        val (where, params) = buildSessionWhere(filter)
        val countSql = "SELECT COUNT(*) FROM sessions $where"
        val total = c.prepareStatement(countSql).use { ps ->
            params.forEachIndexed { i, v -> ps.setString(i + 1, v) }
            ps.executeQuery().also { it.next() }.getLong(1)
        }
        val sql = "SELECT * FROM sessions $where ORDER BY created_at DESC LIMIT ? OFFSET ?"
        val rows = c.prepareStatement(sql).use { ps ->
            params.forEachIndexed { i, v -> ps.setString(i + 1, v) }
            ps.setInt(params.size + 1, page.pageSize)
            ps.setLong(params.size + 2, page.offset)
            val rs = ps.executeQuery()
            val out = mutableListOf<DecryptedSession>()
            while (rs.next()) out += readSession(rs)
            out
        }
        PageImpl(rows, page, total)
    }

    override fun listEvents(sessionId: String, filter: EventFilter, page: Pageable): Page<DecryptedEvent> = lock.withLock {
        val c = connection()
        val (where, params) = buildEventWhere(sessionId, filter)
        val countSql = "SELECT COUNT(*) FROM events $where"
        val total = c.prepareStatement(countSql).use { ps ->
            params.forEachIndexed { i, v -> ps.setString(i + 1, v) }
            ps.executeQuery().also { it.next() }.getLong(1)
        }
        val sql = "SELECT * FROM events $where ORDER BY seq ASC LIMIT ? OFFSET ?"
        val rows = c.prepareStatement(sql).use { ps ->
            params.forEachIndexed { i, v -> ps.setString(i + 1, v) }
            ps.setInt(params.size + 1, page.pageSize)
            ps.setLong(params.size + 2, page.offset)
            val rs = ps.executeQuery()
            val out = mutableListOf<DecryptedEvent>()
            while (rs.next()) {
                val props = decryptColumn(
                    rs.getBytes("props_ct"),
                    rs.getBytes("props_iv"),
                    aad = "event-props|$sessionId|${rs.getLong("seq")}".toByteArray(),
                )
                out += DecryptedEvent(
                    sessionId = sessionId,
                    seq = rs.getLong("seq"),
                    ts = rs.getString("ts"),
                    screen = rs.getString("screen"),
                    event = rs.getString("event_name"),
                    level = rs.getString("level"),
                    props = runCatching { mapper.readValue(props, propsType) }.getOrElse { emptyMap() },
                )
            }
            out
        }
        PageImpl(rows, page, total)
    }

    override fun close() {
        lock.withLock { conn?.close(); conn = null }
    }

    // -- internal helpers --------------------------------------------------

    private fun buildSessionWhere(filter: SessionFilter): Pair<String, List<String>> {
        val clauses = mutableListOf<String>()
        val params = mutableListOf<String>()
        filter.from?.let { clauses += "created_at >= ?"; params += it }
        filter.to?.let { clauses += "created_at <= ?"; params += it }
        filter.appVersion?.let { clauses += "app_version = ?"; params += it }
        filter.os?.let { clauses += "os = ?"; params += it }
        val where = if (clauses.isEmpty()) "" else "WHERE " + clauses.joinToString(" AND ")
        return where to params
    }

    private fun buildEventWhere(sessionId: String, filter: EventFilter): Pair<String, List<String>> {
        val clauses = mutableListOf("session_id = ?")
        val params = mutableListOf(sessionId)
        filter.level?.let { clauses += "level = ?"; params += it }
        filter.event?.let { clauses += "event_name = ?"; params += it }
        filter.screenPrefix?.let { clauses += "screen LIKE ?"; params += "$it%" }
        filter.from?.let { clauses += "ts >= ?"; params += it }
        filter.to?.let { clauses += "ts <= ?"; params += it }
        return "WHERE " + clauses.joinToString(" AND ") to params
    }

    private fun readSession(rs: java.sql.ResultSet): DecryptedSession {
        val id = rs.getString("id")
        val metaPlain = decryptColumn(
            ciphertext = rs.getBytes("metadata_ct"),
            iv = rs.getBytes("metadata_iv"),
            aad = "session-metadata|$id".toByteArray(),
        )
        val meta = runCatching { mapper.readValue(metaPlain, metaType) }.getOrElse { emptyMap() }
        return DecryptedSession(
            id = id,
            keyId = rs.getString("key_id"),
            createdAt = rs.getString("created_at"),
            sealedAt = rs.getString("sealed_at"),
            eventCount = rs.getInt("event_count"),
            sessionTag = rs.getString("session_tag"),
            deviceMetadata = meta,
        )
    }

    private fun encryptColumn(plaintext: ByteArray, aad: ByteArray): Pair<ByteArray, ByteArray> {
        val iv = ByteArray(12).also { rng.nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(masterKey, "AES"), GCMParameterSpec(128, iv))
        cipher.updateAAD(aad)
        return cipher.doFinal(plaintext) to iv
    }

    private fun decryptColumn(ciphertext: ByteArray, iv: ByteArray, aad: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(masterKey, "AES"), GCMParameterSpec(128, iv))
        cipher.updateAAD(aad)
        return cipher.doFinal(ciphertext)
    }
}
