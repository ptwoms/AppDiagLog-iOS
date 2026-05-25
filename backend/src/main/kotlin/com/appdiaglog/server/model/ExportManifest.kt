package com.appdiaglog.server.model

import com.fasterxml.jackson.annotation.JsonInclude
import com.fasterxml.jackson.annotation.JsonProperty

/**
 * Plaintext manifest written at the root of every export ZIP. Lists which
 * `sessions/x.enc` files are present and their plaintext metadata.
 *
 * Useful before decryption — you can triage by app version / device model
 * without touching key material.
 */
@JsonInclude(JsonInclude.Include.NON_NULL)
data class ExportManifest(
    val version: Int,
    @JsonProperty("sdk_version") val sdkVersion: String,
    @JsonProperty("exported_at") val exportedAt: String,
    val sessions: List<Session>,
) {
    @JsonInclude(JsonInclude.Include.NON_NULL)
    data class Session(
        val id: String,
        @JsonProperty("created_at") val createdAt: String,
        @JsonProperty("sealed_at") val sealedAt: String? = null,
        @JsonProperty("event_count") val eventCount: Int,
        @JsonProperty("session_tag") val sessionTag: String? = null,
        @JsonProperty("file_name") val fileName: String,
    )
}
