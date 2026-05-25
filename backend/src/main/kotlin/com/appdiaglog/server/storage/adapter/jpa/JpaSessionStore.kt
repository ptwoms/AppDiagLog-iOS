package com.appdiaglog.server.storage.adapter.jpa

import com.fasterxml.jackson.core.type.TypeReference
import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import com.appdiaglog.server.storage.EventEntity
import com.appdiaglog.server.storage.EventPk
import com.appdiaglog.server.storage.EventRepository
import com.appdiaglog.server.storage.SessionEntity
import com.appdiaglog.server.storage.SessionRepository
import com.appdiaglog.server.storage.adapter.DecryptedEvent
import com.appdiaglog.server.storage.adapter.DecryptedSession
import com.appdiaglog.server.storage.adapter.EventFilter
import com.appdiaglog.server.storage.adapter.SessionFilter
import com.appdiaglog.server.storage.adapter.SessionStore
import org.springframework.data.domain.Page
import org.springframework.data.domain.PageImpl
import org.springframework.data.domain.Pageable
import org.springframework.transaction.annotation.Transactional
import java.time.Instant

/**
 * JPA-backed [SessionStore]. The default adapter — wraps the existing
 * Hibernate repositories so we don't break deployments that have been running
 * the Postgres path. Hands DTOs in/out so other adapters can be swapped in
 * without touching the ingest/query controllers.
 */
open class JpaSessionStore(
    private val sessions: SessionRepository,
    private val events: EventRepository,
) : SessionStore {

    private val mapper: ObjectMapper = jacksonObjectMapper()
    private val propsType = object : TypeReference<Map<String, String>>() {}

    @Transactional
    open override fun persistSession(session: DecryptedSession, events: List<DecryptedEvent>) {
        val entity = SessionEntity(
            id = session.id,
            keyId = session.keyId,
            createdAt = session.createdAt,
            sealedAt = session.sealedAt,
            eventCount = session.eventCount,
            sessionTag = session.sessionTag,
            os = session.os,
            appVersion = session.appVersion,
            model = session.model,
            locale = session.locale,
            deviceMetadata = session.deviceMetadata.toMutableMap(),
            decryptedAt = Instant.now(),
        )
        sessions.save(entity)
        this.events.deleteByPkSessionId(session.id)
        this.events.saveAll(
            events.map { ev ->
                EventEntity(
                    pk = EventPk(sessionId = ev.sessionId, seq = ev.seq),
                    ts = ev.ts,
                    screen = ev.screen,
                    event = ev.event,
                    level = ev.level,
                    propsJson = mapper.writeValueAsString(ev.props),
                )
            }
        )
    }

    @Transactional(readOnly = true)
    override fun findSession(id: String): DecryptedSession? =
        sessions.findById(id).map { it.toDto() }.orElse(null)

    override fun existsSession(id: String): Boolean = sessions.existsById(id)

    @Transactional(readOnly = true)
    override fun listSessions(filter: SessionFilter, page: Pageable): Page<DecryptedSession> {
        val results = sessions.search(filter.from, filter.to, filter.appVersion, filter.os, page)
        return PageImpl(results.content.map { it.toDto() }, page, results.totalElements)
    }

    @Transactional(readOnly = true)
    override fun listEvents(sessionId: String, filter: EventFilter, page: Pageable): Page<DecryptedEvent> {
        val results = events.searchEvents(
            sessionId = sessionId,
            level = filter.level,
            event = filter.event,
            screenPrefix = filter.screenPrefix,
            from = filter.from,
            to = filter.to,
            pageable = page,
        )
        return PageImpl(results.content.map { it.toDto() }, page, results.totalElements)
    }

    private fun SessionEntity.toDto() = DecryptedSession(
        id = id,
        keyId = keyId,
        createdAt = createdAt,
        sealedAt = sealedAt,
        eventCount = eventCount,
        sessionTag = sessionTag,
        deviceMetadata = deviceMetadata.toMap(),
    )

    private fun EventEntity.toDto(): DecryptedEvent {
        val props: Map<String, String> = runCatching {
            mapper.readValue(propsJson, propsType)
        }.getOrElse { emptyMap() }
        return DecryptedEvent(
            sessionId = pk.sessionId,
            seq = pk.seq,
            ts = ts,
            screen = screen,
            event = event,
            level = level,
            props = props,
        )
    }
}
