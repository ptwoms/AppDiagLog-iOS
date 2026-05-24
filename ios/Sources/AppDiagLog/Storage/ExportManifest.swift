import Foundation

/// Plaintext manifest bundled into the export zip.
struct ExportManifest: Codable, Sendable {
    let version: Int
    let sdkVersion: String
    let exportedAt: String
    let sessions: [Session]

    struct Session: Codable, Sendable {
        let id: String
        let createdAt: String
        let sealedAt: String?
        let eventCount: Int
        let sessionTag: String?
        let fileName: String

        enum CodingKeys: String, CodingKey {
            case id
            case createdAt = "created_at"
            case sealedAt = "sealed_at"
            case eventCount = "event_count"
            case sessionTag = "session_tag"
            case fileName = "file_name"
        }
    }

    enum CodingKeys: String, CodingKey {
        case version, sessions
        case sdkVersion = "sdk_version"
        case exportedAt = "exported_at"
    }
}
