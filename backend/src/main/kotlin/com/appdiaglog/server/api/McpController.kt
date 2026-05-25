package com.appdiaglog.server.api

import com.appdiaglog.server.decryption.DecryptionService
import com.appdiaglog.server.storage.adapter.EventFilter
import com.appdiaglog.server.storage.adapter.SessionFilter
import com.appdiaglog.server.storage.adapter.SessionStore
import com.fasterxml.jackson.annotation.JsonInclude
import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.databind.node.ArrayNode
import com.fasterxml.jackson.databind.node.ObjectNode
import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import org.slf4j.LoggerFactory
import org.springframework.data.domain.PageRequest
import org.springframework.http.HttpStatus
import org.springframework.http.MediaType
import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController
import java.io.ByteArrayInputStream
import java.util.Base64

/**
 * MCP (Model Context Protocol) endpoint for the AppDiagLog backend.
 *
 *   POST /api/v1/mcp
 *   Authorization: Bearer <token>
 *   Content-Type: application/json
 *   Body: JSON-RPC 2.0 request
 *
 * Implements the JSON-RPC 2.0 + MCP Streamable HTTP transport without SSE — each
 * POST returns a single JSON response. This is compatible with the SDK's MCP client
 * and with standard MCP tooling.
 *
 * Exposed tools:
 *   - `submit_diagnostics`  — base64 ZIP → DecryptionService (same pipeline as /upload)
 *   - `list_sessions`       — SessionStore.listSessions with optional filters
 *   - `query_events`        — SessionStore.listEvents for a session with optional filters
 *   - `get_session_events`  — alias for query_events
 *
 * Authentication is handled by [IngestTokenFilter], which is extended to gate this path.
 */
@RestController
@RequestMapping("/api/v1/mcp")
class McpController(
    private val decryption: DecryptionService,
    private val store: SessionStore,
) {
    private val log = LoggerFactory.getLogger(javaClass)
    private val mapper: ObjectMapper = jacksonObjectMapper()
        .setSerializationInclusion(JsonInclude.Include.NON_NULL)

    // ─── Entry point ─────────────────────────────────────────────────────────

    @PostMapping(
        consumes = [MediaType.APPLICATION_JSON_VALUE],
        produces = [MediaType.APPLICATION_JSON_VALUE],
    )
    fun handle(@RequestBody body: String): ResponseEntity<String> {
        val request: JsonNode = try {
            mapper.readTree(body)
        } catch (e: Exception) {
            log.warn("MCP: malformed JSON body: ${e.message}")
            return jsonRpcError(null, McpError.PARSE_ERROR, "Invalid JSON", HttpStatus.BAD_REQUEST)
        }

        val idNode = if (request.has("id")) request.get("id") else null
        val id: Int? = when {
            idNode == null || idNode.isNull -> null
            idNode.isInt -> idNode.intValue()
            else -> null // Non-integer ids are not supported; treat as notification.
        }
        val method = request.path("method").asText(null)
            ?: return jsonRpcError(id, McpError.INVALID_REQUEST, "Missing method", HttpStatus.BAD_REQUEST)

        val params = if (request.has("params")) request.get("params") else mapper.createObjectNode()

        return when (method) {
            "initialize" -> handleInitialize(id, params)
            "notifications/initialized" -> ResponseEntity.noContent().build() // notification, no response
            "tools/list" -> handleToolsList(id)
            "tools/call" -> handleToolsCall(id, params)
            else -> jsonRpcError(id, McpError.METHOD_NOT_FOUND, "Unknown method: $method", HttpStatus.OK)
        }
    }

    // ─── MCP handlers ────────────────────────────────────────────────────────

    private fun handleInitialize(id: Int?, params: JsonNode): ResponseEntity<String> {
        val result = mapper.createObjectNode().apply {
            put("protocolVersion", MCP_PROTOCOL_VERSION)
            set<ObjectNode>("capabilities", mapper.createObjectNode().apply {
                set<ObjectNode>("tools", mapper.createObjectNode())
            })
            set<ObjectNode>("serverInfo", mapper.createObjectNode().apply {
                put("name", "AppDiagLogServer")
                put("version", SERVER_VERSION)
            })
        }
        log.debug("MCP: initialize from client at protocol {}", params.path("protocolVersion").asText("unknown"))
        return jsonRpcResult(id, result)
    }

    private fun handleToolsList(id: Int?): ResponseEntity<String> {
        val tools = mapper.createArrayNode().apply {
            add(tool("submit_diagnostics", "Ingest an encrypted session export ZIP (base64-encoded) into the backend.",
                inputSchema(
                    properties = mapOf(
                        "data" to prop("string", "Base64-encoded ZIP produced by the AppDiagLog SDK export."),
                        "filename" to prop("string", "Optional original filename for logging."),
                    ),
                    required = listOf("data"),
                )))
            add(tool("list_sessions", "List imported session metadata with optional filters.",
                inputSchema(
                    properties = mapOf(
                        "from" to prop("string", "ISO-8601 lower bound for createdAt."),
                        "to" to prop("string", "ISO-8601 upper bound for createdAt."),
                        "app_version" to prop("string", "Filter by exact app version string."),
                        "os" to prop("string", "Filter by OS string prefix (e.g. 'iOS 26')."),
                        "page" to prop("integer", "0-based page index (default 0)."),
                        "size" to prop("integer", "Page size (default $SESSION_PAGE_DEFAULT, max $SESSION_PAGE_MAX)."),
                    ),
                )))
            add(tool("query_events", "List events for a specific session with optional filters.",
                inputSchema(
                    properties = mapOf(
                        "session_id" to prop("string", "Session ID to query."),
                        "level" to prop("string", "Filter by log level (debug|info|warning|error)."),
                        "event" to prop("string", "Filter by event name."),
                        "screen" to prop("string", "Filter by screen name prefix."),
                        "from" to prop("string", "ISO-8601 lower bound for event timestamp."),
                        "to" to prop("string", "ISO-8601 upper bound for event timestamp."),
                        "page" to prop("integer", "0-based page index (default 0)."),
                        "size" to prop("integer", "Page size (default $EVENT_PAGE_DEFAULT, max $EVENT_PAGE_MAX)."),
                    ),
                    required = listOf("session_id"),
                )))
            add(tool("get_session_events", "Alias for query_events.",
                inputSchema(
                    properties = mapOf(
                        "session_id" to prop("string", "Session ID to query."),
                        "level" to prop("string", "Filter by log level."),
                        "event" to prop("string", "Filter by event name."),
                        "page" to prop("integer", "0-based page index."),
                        "size" to prop("integer", "Page size (max 1000)."),
                    ),
                    required = listOf("session_id"),
                )))
        }
        return jsonRpcResult(id, mapper.createObjectNode().set("tools", tools))
    }

    private fun handleToolsCall(id: Int?, params: JsonNode): ResponseEntity<String> {
        val toolName = params.path("name").asText(null)
            ?: return jsonRpcError(id, McpError.INVALID_PARAMS, "Missing tool name", HttpStatus.OK)
        val args = params.path("arguments")

        return when (toolName) {
            "submit_diagnostics" -> toolSubmitDiagnostics(id, args)
            "list_sessions" -> toolListSessions(id, args)
            "query_events", "get_session_events" -> toolQueryEvents(id, args)
            else -> jsonRpcResult(id, toolResult("""{"error":"Unknown tool: $toolName"}""", isError = true))
        }
    }

    // ─── Tool implementations ─────────────────────────────────────────────────

    private fun toolSubmitDiagnostics(id: Int?, args: JsonNode): ResponseEntity<String> {
        val dataB64 = args.path("data").asText(null)
            ?: return jsonRpcResult(id, toolResult("""{"error":"Missing required argument: data"}""", isError = true))

        val zipBytes = try {
            Base64.getDecoder().decode(dataB64)
        } catch (e: IllegalArgumentException) {
            log.warn("MCP submit_diagnostics: invalid base64 — ${e.message}")
            return jsonRpcResult(id, toolResult("""{"error":"data is not valid base64"}""", isError = true))
        }

        val filename = args.path("filename").asText("mcp-upload.zip")
        log.info("MCP submit_diagnostics: name={} size={}B", filename, zipBytes.size)

        val result = ByteArrayInputStream(zipBytes).use { decryption.ingest(it) }

        val summary = mapper.writeValueAsString(
            mapOf(
                "sessions_imported" to result.sessionsImported,
                "events_imported" to result.eventsImported,
                "imported" to result.imported.map {
                    mapOf("id" to it.id, "event_count" to it.eventCount, "key_id" to it.keyId)
                },
                "failures" to result.failures.map {
                    mapOf("id" to it.id, "file" to it.fileName, "reason" to it.reason)
                },
            ),
        )
        return jsonRpcResult(id, toolResult(summary))
    }

    private fun toolListSessions(id: Int?, args: JsonNode): ResponseEntity<String> {
        val page = args.path("page").asInt(0)
        val size = args.path("size").asInt(SESSION_PAGE_DEFAULT).coerceIn(1, SESSION_PAGE_MAX)

        val sessions = store.listSessions(
            SessionFilter(
                from = args.path("from").asText(null)?.takeIf { it.isNotBlank() },
                to = args.path("to").asText(null)?.takeIf { it.isNotBlank() },
                appVersion = args.path("app_version").asText(null)?.takeIf { it.isNotBlank() },
                os = args.path("os").asText(null)?.takeIf { it.isNotBlank() },
            ),
            PageRequest.of(page, size),
        )

        val summary = mapper.writeValueAsString(
            mapOf(
                "page" to sessions.number,
                "size" to sessions.size,
                "total" to sessions.totalElements,
                "sessions" to sessions.content.map {
                    mapOf(
                        "id" to it.id,
                        "created_at" to it.createdAt,
                        "sealed_at" to it.sealedAt,
                        "event_count" to it.eventCount,
                        "key_id" to it.keyId,
                        "session_tag" to it.sessionTag,
                        "os" to it.os,
                        "app_version" to it.appVersion,
                        "model" to it.model,
                    )
                },
            ),
        )
        return jsonRpcResult(id, toolResult(summary))
    }

    private fun toolQueryEvents(id: Int?, args: JsonNode): ResponseEntity<String> {
        val sessionId = args.path("session_id").asText(null)
            ?: return jsonRpcResult(id, toolResult("""{"error":"Missing required argument: session_id"}""", isError = true))

        if (!store.existsSession(sessionId)) {
            return jsonRpcResult(id, toolResult("""{"error":"Session not found: $sessionId"}""", isError = true))
        }

        val page = args.path("page").asInt(0)
        val size = args.path("size").asInt(EVENT_PAGE_DEFAULT).coerceIn(1, EVENT_PAGE_MAX)

        val events = store.listEvents(
            sessionId = sessionId,
            filter = EventFilter(
                level = args.path("level").asText(null)?.takeIf { it.isNotBlank() },
                event = args.path("event").asText(null)?.takeIf { it.isNotBlank() },
                screenPrefix = args.path("screen").asText(null)?.takeIf { it.isNotBlank() },
                from = args.path("from").asText(null)?.takeIf { it.isNotBlank() },
                to = args.path("to").asText(null)?.takeIf { it.isNotBlank() },
            ),
            page = PageRequest.of(page, size),
        )

        val summary = mapper.writeValueAsString(
            mapOf(
                "session_id" to sessionId,
                "page" to events.number,
                "size" to events.size,
                "total" to events.totalElements,
                "events" to events.content.map {
                    mapOf(
                        "seq" to it.seq,
                        "ts" to it.ts,
                        "level" to it.level,
                        "event" to it.event,
                        "screen" to it.screen,
                        "props" to it.props,
                    )
                },
            ),
        )
        return jsonRpcResult(id, toolResult(summary))
    }

    // ─── DSL helpers ─────────────────────────────────────────────────────────

    private fun toolResult(text: String, isError: Boolean = false): ObjectNode =
        mapper.createObjectNode().apply {
            set<ArrayNode>("content", mapper.createArrayNode().apply {
                add(mapper.createObjectNode().apply {
                    put("type", "text")
                    put("text", text)
                })
            })
            put("isError", isError)
        }

    private fun tool(name: String, description: String, schema: ObjectNode): ObjectNode =
        mapper.createObjectNode().apply {
            put("name", name)
            put("description", description)
            set<ObjectNode>("inputSchema", schema)
        }

    private fun inputSchema(
        properties: Map<String, ObjectNode>,
        required: List<String> = emptyList(),
    ): ObjectNode = mapper.createObjectNode().apply {
        put("type", "object")
        set<ObjectNode>("properties", mapper.createObjectNode().apply {
            properties.forEach { (k, v) -> set<ObjectNode>(k, v) }
        })
        if (required.isNotEmpty()) {
            set<ArrayNode>("required", mapper.createArrayNode().apply { required.forEach { add(it) } })
        }
    }

    private fun prop(type: String, description: String): ObjectNode =
        mapper.createObjectNode().apply {
            put("type", type)
            put("description", description)
        }

    // ─── JSON-RPC response builders ───────────────────────────────────────────

    private fun jsonRpcResult(id: Int?, result: JsonNode): ResponseEntity<String> {
        val node = mapper.createObjectNode().apply {
            put("jsonrpc", JSONRPC_VERSION)
            if (id != null) put("id", id)
            set<JsonNode>("result", result)
        }
        return ResponseEntity.ok(mapper.writeValueAsString(node))
    }

    private fun jsonRpcError(
        id: Int?,
        code: Int,
        message: String,
        status: HttpStatus,
    ): ResponseEntity<String> {
        val node = mapper.createObjectNode().apply {
            put("jsonrpc", JSONRPC_VERSION)
            if (id != null) put("id", id)
            set<ObjectNode>("error", mapper.createObjectNode().apply {
                put("code", code)
                put("message", message)
            })
        }
        return ResponseEntity.status(status).body(mapper.writeValueAsString(node))
    }

    // ─── Constants ────────────────────────────────────────────────────────────

    companion object {
        private const val JSONRPC_VERSION = "2.0"
        private const val MCP_PROTOCOL_VERSION = "2024-11-05"
        private const val SERVER_VERSION = "1.0.0"
        private const val SESSION_PAGE_DEFAULT = 50
        private const val SESSION_PAGE_MAX = 200
        private const val EVENT_PAGE_DEFAULT = 200
        private const val EVENT_PAGE_MAX = 1000
    }

    // ─── Error codes ─────────────────────────────────────────────────────────

    private object McpError {
        const val PARSE_ERROR = -32700
        const val INVALID_REQUEST = -32600
        const val METHOD_NOT_FOUND = -32601
        const val INVALID_PARAMS = -32602
    }
}
