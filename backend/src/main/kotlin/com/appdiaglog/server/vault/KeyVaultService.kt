package com.appdiaglog.server.vault

/**
 * Interface for resolving a `key_id` (carried in the session envelope) to a
 * PKCS#8-encoded ML-KEM-768 private key.
 *
 * Production implementations should defer to AWS KMS / GCP KMS / HashiCorp
 * Vault. The bundled [InMemoryKeyVault] is for dev/CI only — it loads keys
 * from config and never persists them anywhere.
 *
 * Implementations MUST:
 *  - never log the raw private key
 *  - log every successful and failed lookup (for audit)
 *  - return `null` for unknown keys; throwing reveals timing information
 */
interface KeyVaultService {
    /**
     * @return PKCS#8-encoded ML-KEM-768 private key, or null if not found.
     *         Returned bytes belong to the caller — they SHOULD wipe after use,
     *         though the in-memory vault keeps its own canonical copy.
     */
    fun lookupPrivateKey(keyId: String): ByteArray?

    /** Sanity check used by health endpoints / startup probes. */
    fun knownKeyIds(): Set<String>
}
