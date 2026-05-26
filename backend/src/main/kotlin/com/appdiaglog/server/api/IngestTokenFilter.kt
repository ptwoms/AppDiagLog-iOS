package com.appdiaglog.server.api

import jakarta.servlet.FilterChain
import jakarta.servlet.http.HttpServletRequest
import jakarta.servlet.http.HttpServletResponse
import org.slf4j.LoggerFactory
import org.springframework.beans.factory.annotation.Value
import org.springframework.http.HttpStatus
import org.springframework.stereotype.Component
import org.springframework.web.filter.OncePerRequestFilter

/**
 * Trivial bearer-token gate for the upload endpoint. Production deployments
 * should swap this for mTLS, signed-URL upload, or a proper auth-server
 * setup — this is intentionally minimal so the SDK has *something* to point
 * at for dev/CI without dragging in Spring Security.
 *
 * Constant-time comparison avoids leaking the token byte-by-byte through
 * timing variation — overkill for a dev token, but cheap and correct.
 */
@Component
class IngestTokenFilter(
    @Value("\${appdiaglog.ingest-token}") private val expectedToken: String,
) : OncePerRequestFilter() {

    private val log = LoggerFactory.getLogger(javaClass)
    private val expectedBytes = expectedToken.toByteArray(Charsets.UTF_8)

    override fun shouldNotFilter(request: HttpServletRequest): Boolean {
        // Gate the upload endpoint and the MCP endpoint. Other read paths rely on
        // whatever network-level controls the operator configures (VPN, IP allowlist).
        // Note: Spring's embedded Tomcat normalises URI path segments (including /../
        // traversals) before the request reaches this filter, so prefix matching on
        // the resolved URI is safe.
        val uri = request.requestURI
        return !uri.startsWith("/api/v1/diagnostics/upload") && !uri.startsWith("/api/v1/mcp")
    }

    override fun doFilterInternal(
        request: HttpServletRequest,
        response: HttpServletResponse,
        filterChain: FilterChain,
    ) {
        applyCorsHeaders(request, response)

        if (request.method.equals("OPTIONS", ignoreCase = true)) {
            response.status = HttpServletResponse.SC_NO_CONTENT
            return
        }

        val auth = request.getHeader("Authorization")
        val provided = auth?.removePrefix("Bearer ")?.trim().orEmpty()
        if (!constantTimeEquals(provided.toByteArray(Charsets.UTF_8), expectedBytes)) {
            log.warn("Unauthorized upload attempt from {}", request.remoteAddr)
            response.status = HttpStatus.UNAUTHORIZED.value()
            response.contentType = "application/json"
            response.writer.write("""{"error":"unauthorized"}""")
            return
        }
        filterChain.doFilter(request, response)
    }

    private fun applyCorsHeaders(request: HttpServletRequest, response: HttpServletResponse) {
        val origin = request.getHeader("Origin") ?: return
        response.setHeader("Access-Control-Allow-Origin", origin)
        response.setHeader("Vary", "Origin")
        response.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS")
        response.setHeader(
            "Access-Control-Allow-Headers",
            request.getHeader("Access-Control-Request-Headers")
                ?: "Content-Type, Authorization, MCP-Protocol-Version, MCP-Session-Id",
        )
        response.setHeader("Access-Control-Expose-Headers", "MCP-Protocol-Version, MCP-Session-Id")
        response.setHeader("Access-Control-Max-Age", "600")
    }

    private fun constantTimeEquals(a: ByteArray, b: ByteArray): Boolean {
        if (a.size != b.size) return false
        var diff = 0
        for (i in a.indices) diff = diff or (a[i].toInt() xor b[i].toInt())
        return diff == 0
    }
}
