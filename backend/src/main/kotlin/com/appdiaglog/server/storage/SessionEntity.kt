package com.appdiaglog.server.storage

import jakarta.persistence.CollectionTable
import jakarta.persistence.Column
import jakarta.persistence.ElementCollection
import jakarta.persistence.Entity
import jakarta.persistence.FetchType
import jakarta.persistence.Id
import jakarta.persistence.Index
import jakarta.persistence.JoinColumn
import jakarta.persistence.MapKeyColumn
import jakarta.persistence.Table
import java.time.Instant

/**
 * One row per decrypted session. Keyed by the SDK-assigned session ID
 * (already a UUID, so we let the client own the primary key — this is also
 * what makes re-uploading the same export idempotent).
 *
 * `deviceMetadata` is mapped as a side-table because Hibernate's @ElementCollection
 * is the lightest way to persist a `Map<String,String>` without an extra entity.
 */
@Entity
@Table(
    name = "diagnostic_session",
    indexes = [
        Index(name = "idx_session_created_at", columnList = "createdAt"),
        Index(name = "idx_session_app_version", columnList = "appVersion"),
        Index(name = "idx_session_key_id", columnList = "keyId"),
    ],
)
class SessionEntity(

    @Id
    @Column(length = 64)
    var id: String = "",

    @Column(length = 64, nullable = false)
    var keyId: String = "",

    /** ISO-8601 string from the device. We keep the original string so we don't
     *  silently lose milliseconds on storage round-trips. */
    @Column(length = 32, nullable = false)
    var createdAt: String = "",

    @Column(length = 32)
    var sealedAt: String? = null,

    @Column(nullable = false)
    var eventCount: Int = 0,

    @Column(length = 256)
    var sessionTag: String? = null,

    /** Convenience columns lifted from device_metadata for cheap filtering. */
    @Column(length = 64)
    var os: String? = null,

    @Column(length = 64)
    var appVersion: String? = null,

    @Column(length = 64)
    var model: String? = null,

    @Column(length = 16)
    var locale: String? = null,

    @ElementCollection(fetch = FetchType.LAZY)
    @CollectionTable(
        name = "diagnostic_session_metadata",
        joinColumns = [JoinColumn(name = "session_id")],
    )
    @MapKeyColumn(name = "k", length = 128)
    @Column(name = "v", length = 1024)
    var deviceMetadata: MutableMap<String, String> = mutableMapOf(),

    @Column(nullable = false)
    var decryptedAt: Instant = Instant.now(),
) {
    /** No-arg constructor for Hibernate. */
    constructor() : this(id = "")
}
