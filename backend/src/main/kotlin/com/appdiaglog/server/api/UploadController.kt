package com.appdiaglog.server.api

import com.appdiaglog.server.decryption.DecryptionService
import org.slf4j.LoggerFactory
import org.springframework.http.HttpStatus
import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RequestParam
import org.springframework.web.bind.annotation.RestController
import org.springframework.web.multipart.MultipartFile

/**
 * Ingest endpoint:
 *
 *   POST /api/v1/diagnostics/upload
 *   Authorization: Bearer <token>
 *   Content-Type: multipart/form-data
 *   form field: `file` = the .zip exported by the SDK
 *
 * Response shape (success):
 *   {
 *     "sessionsImported": 3,
 *     "eventsImported": 1284,
 *     "imported": [{"id":"…","eventCount":428,"keyId":"key-2026-04"}, …],
 *     "failures": []
 *   }
 *
 * Returns 200 even when individual sessions fail — this lets the SDK upload
 * without retry-storming on a single corrupt session. The `failures` list
 * lets ops chase missing keys.
 */
@RestController
@RequestMapping("/api/v1/diagnostics")
class UploadController(
    private val decryption: DecryptionService,
) {
    private val log = LoggerFactory.getLogger(javaClass)

    @PostMapping("/upload")
    fun upload(@RequestParam("file") file: MultipartFile): ResponseEntity<UploadResponse> {
        if (file.isEmpty) {
            return ResponseEntity.status(HttpStatus.BAD_REQUEST)
                .body(UploadResponse.error("uploaded file is empty"))
        }
        log.info("Receiving upload: name={} size={}B", file.originalFilename, file.size)
        val result = file.inputStream.use { decryption.ingest(it) }

        return ResponseEntity.ok(
            UploadResponse(
                sessionsImported = result.sessionsImported,
                eventsImported = result.eventsImported,
                imported = result.imported.map {
                    UploadResponse.Imported(it.id, it.eventCount, it.keyId)
                },
                failures = result.failures.map {
                    UploadResponse.Failure(it.id, it.fileName, it.reason)
                },
                manifestVersion = result.manifest?.version,
                sdkVersion = result.manifest?.sdkVersion,
                error = null,
            )
        )
    }

    data class UploadResponse(
        val sessionsImported: Int = 0,
        val eventsImported: Int = 0,
        val imported: List<Imported> = emptyList(),
        val failures: List<Failure> = emptyList(),
        val manifestVersion: Int? = null,
        val sdkVersion: String? = null,
        val error: String? = null,
    ) {
        data class Imported(val id: String, val eventCount: Int, val keyId: String)
        data class Failure(val id: String?, val fileName: String, val reason: String)

        companion object {
            fun error(msg: String) = UploadResponse(error = msg)
        }
    }
}
