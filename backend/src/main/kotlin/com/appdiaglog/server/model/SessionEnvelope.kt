package com.appdiaglog.server.model

import com.fasterxml.jackson.annotation.JsonInclude
import com.fasterxml.jackson.annotation.JsonProperty

/**
 * Wire-compatible mirror of the SDK's `session_*.enc` envelope.
 *
 * Keys are snake_case to match what iOS (Codable with CodingKeys) write. Adding a field requires
 * updating all three layers in lockstep.
 *
 * `payload` and the inner crypto fields are base64. We keep them as strings here
 * so Jackson never has to decode binary while parsing — decoding happens in the
 * decryption pipeline where errors map cleanly to "bad ciphertext" responses.
 */
@JsonInclude(JsonInclude.Include.NON_NULL)
data class SessionEnvelope(
    val version: Int,
    @JsonProperty("session_id") val sessionId: String,
    @JsonProperty("created_at") val createdAt: String,
    @JsonProperty("sealed_at") val sealedAt: String? = null,
    @JsonProperty("event_count") val eventCount: Int,
    @JsonProperty("session_tag") val sessionTag: String? = null,
    @JsonProperty("device_metadata") val deviceMetadata: Map<String, String> = emptyMap(),
    val encryption: Encryption,
    val payload: String,
) {
    @JsonInclude(JsonInclude.Include.NON_NULL)
    data class Encryption(
        val algorithm: String,
        val nonce: String,
        @JsonProperty("kek_algorithm") val kekAlgorithm: String,
        @JsonProperty("key_id") val keyId: String,
        @JsonProperty("kem_ciphertext") val kemCiphertext: String,
        @JsonProperty("wrapped_dek") val wrappedDek: String,
        /** Optional algorithm-specific parameters. Pre-agility envelopes omit it. */
        @JsonProperty("kek_params") val kekParams: Map<String, String>? = null,
    )
}
