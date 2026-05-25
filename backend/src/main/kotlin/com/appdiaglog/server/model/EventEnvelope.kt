package com.appdiaglog.server.model

import com.fasterxml.jackson.annotation.JsonProperty

/**
 * One decrypted event. The SDKs serialize an array of these as the AES-GCM
 * plaintext, so this is the one type that is *never* persisted by the SDK in
 * cleartext — it only exists between AES-GCM.open() and JPA insert.
 *
 * `props` is always String->String. The schema deliberately disallows nested
 * objects — keeps redaction simple and indexes predictable.
 */
data class EventEnvelope(
    val seq: Long,
    val ts: String,
    @JsonProperty("session_id") val sessionId: String,
    val screen: String? = null,
    val event: String,
    val level: String,
    val props: Map<String, String> = emptyMap(),
)
