import Foundation

/// On-disk session envelope format
struct SessionEnvelope: Codable, Sendable {
    let version: Int
    let sessionId: String
    let createdAt: String
    let sealedAt: String?
    let eventCount: Int
    let sessionTag: String?
    let deviceMetadata: [String: String]
    let encryption: Encryption
    let payload: String

    struct Encryption: Codable, Sendable {
        let algorithm: String      // "AES-256-GCM" | "AES-128-GCM" | "ChaCha20-Poly1305"
        let nonce: String
        let kekAlgorithm: String   // "ML-KEM-768" | "ML-KEM-512" | "RSA-OAEP-3072" | "ECDH-P256+HKDF"
        let keyId: String
        let kemCiphertext: String  // base64 (empty string for RSA-OAEP)
        let wrappedDek: String     // base64
        /// Algorithm-specific extras. Encoded only when non-empty.
        let kekParams: [String: String]?

        enum CodingKeys: String, CodingKey {
            case algorithm, nonce
            case kekAlgorithm = "kek_algorithm"
            case keyId = "key_id"
            case kemCiphertext = "kem_ciphertext"
            case wrappedDek = "wrapped_dek"
            case kekParams = "kek_params"
        }
    }

    enum CodingKeys: String, CodingKey {
        case version, encryption, payload
        case sessionId = "session_id"
        case createdAt = "created_at"
        case sealedAt = "sealed_at"
        case eventCount = "event_count"
        case sessionTag = "session_tag"
        case deviceMetadata = "device_metadata"
    }
}
