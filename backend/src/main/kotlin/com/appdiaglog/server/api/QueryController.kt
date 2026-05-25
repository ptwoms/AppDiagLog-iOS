package com.appdiaglog.server.api

import com.appdiaglog.server.storage.adapter.DecryptedEvent
import com.appdiaglog.server.storage.adapter.DecryptedSession
import com.appdiaglog.server.storage.adapter.EventFilter
import com.appdiaglog.server.storage.adapter.SessionFilter
import com.appdiaglog.server.storage.adapter.SessionStore
import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import org.apache.commons.csv.CSVFormat
import org.apache.commons.csv.CSVPrinter
import org.apache.poi.hssf.usermodel.HSSFWorkbook
import org.apache.poi.ss.usermodel.CellStyle
import org.apache.poi.ss.usermodel.Row
import org.springframework.data.domain.PageRequest
import org.springframework.http.HttpHeaders
import org.springframework.http.HttpStatus
import org.springframework.http.MediaType
import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RequestParam
import org.springframework.web.bind.annotation.RestController
import org.springframework.web.server.ResponseStatusException
import org.springframework.web.servlet.mvc.method.annotation.StreamingResponseBody
import java.io.OutputStreamWriter
import java.nio.charset.StandardCharsets

/**
 * Read-side API for support tooling / dashboards. All endpoints are paginated;
 * none of them load the full event stream into memory.
 *
 * Endpoints:
 *   GET /api/v1/diagnostics/sessions
 *       ?from=&to=&app_version=&os=&page=0&size=50
 *   GET /api/v1/diagnostics/sessions/{id}
 *   GET /api/v1/diagnostics/sessions/{id}/events
 *       ?level=&event=&screen=&from=&to=&page=0&size=200
 *   GET /api/v1/diagnostics/sessions/{id}/events.csv
 *       — streaming CSV download of all events for the session
 *   GET /api/v1/diagnostics/events.xls
 *       — Excel workbook with all sessions and all events
 *
 * Reads go through [SessionStore] so the same controller works against the JPA,
 * SQLite, or CSV adapter.
 */
@RestController
@RequestMapping("/api/v1/diagnostics")
class QueryController(
    private val store: SessionStore,
) {
    private val mapper = jacksonObjectMapper()

    @GetMapping("/sessions")
    fun listSessions(
        @RequestParam(required = false) from: String?,
        @RequestParam(name = "to", required = false) to: String?,
        @RequestParam(name = "app_version", required = false) appVersion: String?,
        @RequestParam(required = false) os: String?,
        @RequestParam(defaultValue = "0") page: Int,
        @RequestParam(defaultValue = "50") size: Int,
    ): SessionPage {
        val capped = size.coerceIn(1, 200)
        val results = store.listSessions(
            SessionFilter(from = from, to = to, appVersion = appVersion, os = os),
            PageRequest.of(page, capped),
        )
        return SessionPage(
            page = results.number,
            size = results.size,
            total = results.totalElements,
            sessions = results.content.map { it.toDto() },
        )
    }

    @GetMapping("/sessions/{id}")
    fun getSession(@PathVariable id: String): SessionDto =
        store.findSession(id)?.toDto()
            ?: throw ResponseStatusException(HttpStatus.NOT_FOUND, "session $id not found")

    @GetMapping("/sessions/{id}/events")
    fun listEvents(
        @PathVariable id: String,
        @RequestParam(required = false) level: String?,
        @RequestParam(required = false) event: String?,
        @RequestParam(required = false) screen: String?,
        @RequestParam(required = false) from: String?,
        @RequestParam(name = "to", required = false) to: String?,
        @RequestParam(defaultValue = "0") page: Int,
        @RequestParam(defaultValue = "200") size: Int,
    ): EventPage {
        if (!store.existsSession(id)) {
            throw ResponseStatusException(HttpStatus.NOT_FOUND, "session $id not found")
        }
        val capped = size.coerceIn(1, 1000)
        val results = store.listEvents(
            sessionId = id,
            filter = EventFilter(
                level = level, event = event, screenPrefix = screen, from = from, to = to,
            ),
            page = PageRequest.of(page, capped),
        )
        return EventPage(
            page = results.number,
            size = results.size,
            total = results.totalElements,
            events = results.content.map { it.toDto() },
        )
    }

    /**
     * Stream a session's events as CSV. Useful for ad-hoc analysis in
     * spreadsheets or `cut`/`awk` pipelines.
     */
    @GetMapping("/sessions/{id}/events.csv")
    fun streamEventsCsv(@PathVariable id: String): ResponseEntity<StreamingResponseBody> {
        if (!store.existsSession(id)) {
            throw ResponseStatusException(HttpStatus.NOT_FOUND, "session $id not found")
        }
        val body = StreamingResponseBody { os ->
            OutputStreamWriter(os, StandardCharsets.UTF_8).use { writer ->
                CSVPrinter(writer, CSVFormat.DEFAULT).use { printer ->
                    printer.printRecord("seq", "ts", "level", "event", "screen", "props")
                    var pageIndex = 0
                    val pageSize = 1000
                    while (true) {
                        val page = store.listEvents(
                            sessionId = id,
                            filter = EventFilter(),
                            page = PageRequest.of(pageIndex, pageSize),
                        )
                        for (e in page.content) {
                            printer.printRecord(
                                e.seq,
                                e.ts,
                                e.level,
                                e.event,
                                e.screen ?: "",
                                mapper.writeValueAsString(e.props),
                            )
                        }
                        if (!page.hasNext()) break
                        pageIndex++
                    }
                }
            }
        }
        return ResponseEntity.ok()
            .contentType(MediaType.parseMediaType("text/csv"))
            .header(HttpHeaders.CONTENT_DISPOSITION, "attachment; filename=session-$id-events.csv")
            .body(body)
    }

    @GetMapping("/sessions/events.xls")
    fun streamAllEventsXls(): ResponseEntity<StreamingResponseBody> {
        val body = StreamingResponseBody { os ->
            HSSFWorkbook().use { workbook ->
                val headerStyle = workbook.createCellStyle().apply {
                    val font = workbook.createFont()
                    font.bold = true
                    setFont(font)
                }

                val sessionsSheet = workbook.createSheet("Sessions")
                writeRow(
                    sessionsSheet.createRow(0),
                    listOf(
                        "session_id", "key_id", "created_at", "sealed_at", "event_count",
                        "session_tag", "os", "app_version", "model", "locale", "device_metadata",
                    ),
                    headerStyle,
                )

                var sessionRowIndex = 1
                var eventSheetIndex = 1
                var eventsSheet = workbook.createSheet("Events $eventSheetIndex")
                writeEventHeader(eventsSheet.createRow(0), headerStyle)
                var eventRowIndex = 1

                forEachSession { session ->
                    writeRow(
                        sessionsSheet.createRow(sessionRowIndex++),
                        listOf(
                            session.id,
                            session.keyId,
                            session.createdAt,
                            session.sealedAt ?: "",
                            session.eventCount.toString(),
                            session.sessionTag ?: "",
                            session.os ?: "",
                            session.appVersion ?: "",
                            session.model ?: "",
                            session.locale ?: "",
                            mapper.writeValueAsString(session.deviceMetadata),
                        ),
                    )

                    var eventPageIndex = 0
                    while (true) {
                        val page = store.listEvents(
                            sessionId = session.id,
                            filter = EventFilter(),
                            page = PageRequest.of(eventPageIndex, EVENTS_PAGE_SIZE),
                        )
                        for (event in page.content) {
                            if (eventRowIndex >= XLS_MAX_ROWS) {
                                eventSheetIndex++
                                eventsSheet = workbook.createSheet("Events $eventSheetIndex")
                                writeEventHeader(eventsSheet.createRow(0), headerStyle)
                                eventRowIndex = 1
                            }
                            writeRow(
                                eventsSheet.createRow(eventRowIndex++),
                                listOf(
                                    event.sessionId,
                                    event.seq.toString(),
                                    event.ts,
                                    event.level,
                                    event.event,
                                    event.screen ?: "",
                                    mapper.writeValueAsString(event.props),
                                ),
                            )
                        }
                        if (!page.hasNext()) break
                        eventPageIndex++
                    }
                }

                workbook.write(os)
            }
        }

        return ResponseEntity.ok()
            .contentType(MediaType.parseMediaType("application/vnd.ms-excel"))
            .header(HttpHeaders.CONTENT_DISPOSITION, "attachment; filename=events.xls")
            .body(body)
    }

    private fun forEachSession(body: (DecryptedSession) -> Unit) {
        var pageIndex = 0
        while (true) {
            val page = store.listSessions(SessionFilter(), PageRequest.of(pageIndex, SESSIONS_PAGE_SIZE))
            page.content.forEach(body)
            if (!page.hasNext()) break
            pageIndex++
        }
    }

    private fun writeEventHeader(row: Row, headerStyle: CellStyle) {
        writeRow(
            row,
            listOf("session_id", "seq", "ts", "level", "event", "screen", "props"),
            headerStyle,
        )
    }

    private fun writeRow(row: Row, values: List<String>, style: CellStyle? = null) {
        values.forEachIndexed { index, value ->
            val cell = row.createCell(index)
            cell.setCellValue(value)
            if (style != null) cell.cellStyle = style
        }
    }

    // ---- DTOs ----------------------------------------------------------

    private fun DecryptedSession.toDto() = SessionDto(
        id = id,
        keyId = keyId,
        createdAt = createdAt,
        sealedAt = sealedAt,
        eventCount = eventCount,
        sessionTag = sessionTag,
        os = os,
        appVersion = appVersion,
        model = model,
        locale = locale,
        deviceMetadata = deviceMetadata,
    )

    private fun DecryptedEvent.toDto() = EventDto(
        seq = seq,
        ts = ts,
        screen = screen,
        event = event,
        level = level,
        props = props,
    )

    data class SessionPage(
        val page: Int,
        val size: Int,
        val total: Long,
        val sessions: List<SessionDto>,
    )

    data class SessionDto(
        val id: String,
        val keyId: String,
        val createdAt: String,
        val sealedAt: String?,
        val eventCount: Int,
        val sessionTag: String?,
        val os: String?,
        val appVersion: String?,
        val model: String?,
        val locale: String?,
        val deviceMetadata: Map<String, String>,
    )

    data class EventPage(
        val page: Int,
        val size: Int,
        val total: Long,
        val events: List<EventDto>,
    )

    data class EventDto(
        val seq: Long,
        val ts: String,
        val screen: String?,
        val event: String,
        val level: String,
        val props: Map<String, String>,
    )

    companion object {
        private const val SESSIONS_PAGE_SIZE = 200
        private const val EVENTS_PAGE_SIZE = 1000
        private const val XLS_MAX_ROWS = 65_536
    }
}
