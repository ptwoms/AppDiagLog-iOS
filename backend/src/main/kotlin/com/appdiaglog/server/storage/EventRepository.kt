package com.appdiaglog.server.storage

import org.springframework.data.domain.Page
import org.springframework.data.domain.Pageable
import org.springframework.data.jpa.repository.JpaRepository
import org.springframework.data.jpa.repository.Modifying
import org.springframework.data.jpa.repository.Query
import org.springframework.data.repository.query.Param

interface EventRepository : JpaRepository<EventEntity, EventPk> {

    /**
     * Paged event stream for one session, with optional filters.
     *
     * `level` and `event` are exact matches (cheap with indexes). `screen`
     * supports prefix LIKE since clients sometimes log "Screen.Foo.Detail" and
     * want all "Screen.Foo*" matches.
     */
    @Query(
        """
        SELECT e FROM EventEntity e
        WHERE e.pk.sessionId = :sessionId
          AND (:level IS NULL OR e.level = :level)
          AND (:event IS NULL OR e.event = :event)
          AND (:screenPrefix IS NULL OR e.screen LIKE CONCAT(:screenPrefix, '%'))
          AND (:from IS NULL OR e.ts >= :from)
          AND (:to IS NULL OR e.ts <= :to)
        ORDER BY e.pk.seq ASC
        """
    )
    fun searchEvents(
        @Param("sessionId") sessionId: String,
        @Param("level") level: String?,
        @Param("event") event: String?,
        @Param("screenPrefix") screenPrefix: String?,
        @Param("from") from: String?,
        @Param("to") to: String?,
        pageable: Pageable,
    ): Page<EventEntity>

    fun countByPkSessionId(sessionId: String): Long

    /**
     * Bulk delete-by-session used during idempotent re-upload. Declared as a
     * JPQL @Modifying query so Hibernate issues a single DELETE instead of
     * the SELECT+DELETE pair that Spring Data's derived delete method would
     * generate.
     */
    @Modifying
    @Query("delete from EventEntity e where e.pk.sessionId = :sessionId")
    fun deleteByPkSessionId(@Param("sessionId") sessionId: String): Int
}
