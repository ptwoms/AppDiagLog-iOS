package com.appdiaglog.server.storage

import org.springframework.data.domain.Page
import org.springframework.data.domain.Pageable
import org.springframework.data.jpa.repository.JpaRepository
import org.springframework.data.jpa.repository.Query
import org.springframework.data.repository.query.Param

interface SessionRepository : JpaRepository<SessionEntity, String> {

    /**
     * Filtered listing. All filters optional; null = no filter for that field.
     * `from`/`to` are inclusive ISO-8601 strings — string comparison is correct
     * for ISO timestamps because the format is lexicographically sortable.
     */
    @Query(
        """
        SELECT s FROM SessionEntity s
        WHERE (:from IS NULL OR s.createdAt >= :from)
          AND (:to IS NULL OR s.createdAt <= :to)
          AND (:appVersion IS NULL OR s.appVersion = :appVersion)
          AND (:os IS NULL OR s.os = :os)
        ORDER BY s.createdAt DESC
        """
    )
    fun search(
        @Param("from") from: String?,
        @Param("to") to: String?,
        @Param("appVersion") appVersion: String?,
        @Param("os") os: String?,
        pageable: Pageable,
    ): Page<SessionEntity>
}
