package com.appdiaglog.server.storage.adapter

import org.springframework.data.domain.Page
import org.springframework.data.domain.Pageable

/**
 * Storage abstraction for decrypted sessions/events. Lets the backend swap its
 * persistence layer without touching the ingest or query pipeline.
 *
 * Implementations:
 *  - [com.appdiaglog.server.storage.adapter.jpa.JpaSessionStore] — PostgreSQL/H2 via Spring Data
 *  - [com.appdiaglog.server.storage.adapter.sqlite.SqliteEncryptedSessionStore] — per-row AES-GCM in SQLite
 *  - [com.appdiaglog.server.storage.adapter.csv.CsvSessionStore] — append-only CSV files
 *
 * The active implementation is picked at boot by [StorageAdapterConfig] based on
 * the `appdiaglog.storage.adapter` property.
 *
 * Contract notes:
 *  - [persistSession] is idempotent: a second call with the same `session.id`
 *    replaces both the session row and its event rows.
 *  - All read methods return defensive copies — callers can mutate freely.
 */
interface SessionStore {
    fun persistSession(session: DecryptedSession, events: List<DecryptedEvent>)
    fun findSession(id: String): DecryptedSession?
    fun existsSession(id: String): Boolean
    fun listSessions(filter: SessionFilter, page: Pageable): Page<DecryptedSession>
    fun listEvents(sessionId: String, filter: EventFilter, page: Pageable): Page<DecryptedEvent>
}

/**
 * Plain-Kotlin session row — no JPA annotations, decouples adapters from each
 * other. Fields mirror what the SDKs put in the envelope; convenience columns
 * are lifted from `deviceMetadata` for cheap filtering.
 */
data class DecryptedSession(
    val id: String,
    val keyId: String,
    val createdAt: String,
    val sealedAt: String?,
    val eventCount: Int,
    val sessionTag: String?,
    val deviceMetadata: Map<String, String>,
) {
    val os: String? get() = deviceMetadata["os"]
    val appVersion: String? get() = deviceMetadata["app_version"] ?: deviceMetadata["appVersion"]
    val model: String? get() = deviceMetadata["model"]
    val locale: String? get() = deviceMetadata["locale"]
}

data class DecryptedEvent(
    val sessionId: String,
    val seq: Long,
    val ts: String,
    val screen: String?,
    val event: String,
    val level: String,
    val props: Map<String, String>,
)

data class SessionFilter(
    val from: String? = null,
    val to: String? = null,
    val appVersion: String? = null,
    val os: String? = null,
)

data class EventFilter(
    val level: String? = null,
    val event: String? = null,
    val screenPrefix: String? = null,
    val from: String? = null,
    val to: String? = null,
)
