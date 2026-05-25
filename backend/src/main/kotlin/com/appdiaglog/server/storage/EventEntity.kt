package com.appdiaglog.server.storage

import jakarta.persistence.Column
import jakarta.persistence.Embeddable
import jakarta.persistence.EmbeddedId
import jakarta.persistence.Entity
import jakarta.persistence.Index
import jakarta.persistence.Lob
import jakarta.persistence.Table
import java.io.Serializable

/**
 * One decrypted event. Composite PK on (session_id, seq) so re-uploads of the
 * same session UPSERT-by-overwrite without producing duplicate rows. The seq
 * field is the SDK's monotonic per-session counter — guaranteed unique within
 * a session.
 *
 * `props` is stored as a JSON string in a CLOB column. We keep it as text
 * (rather than @ElementCollection on a side table) because:
 *   - props can carry up to ~16 keys per event; a side table = 16 inserts/event,
 *     and at 1000 events/session that's a 16,000-row burst per ingest.
 *   - the read path always returns props as-is via Jackson — no SQL filtering
 *     by individual prop key today.
 *
 * If we add prop-level search later, switch to PostgreSQL `jsonb` and a GIN
 * index — easy migration since the on-disk format is already JSON.
 */
@Entity
@Table(
    name = "diagnostic_event",
    indexes = [
        Index(name = "idx_event_session", columnList = "session_id"),
        Index(name = "idx_event_session_seq", columnList = "session_id,seq"),
        Index(name = "idx_event_level", columnList = "level"),
        Index(name = "idx_event_event_name", columnList = "eventName"),
    ],
)
class EventEntity(

    @EmbeddedId
    var pk: EventPk = EventPk(),

    @Column(length = 32, nullable = false)
    var ts: String = "",

    @Column(length = 256)
    var screen: String? = null,

    @Column(name = "eventName", length = 128, nullable = false)
    var event: String = "",

    @Column(length = 16, nullable = false)
    var level: String = "info",

    @Lob
    @Column(name = "props_json")
    var propsJson: String = "{}",
) {
    constructor() : this(pk = EventPk())
}

@Embeddable
data class EventPk(
    @Column(name = "session_id", length = 64)
    var sessionId: String = "",

    @Column(name = "seq")
    var seq: Long = 0L,
) : Serializable
