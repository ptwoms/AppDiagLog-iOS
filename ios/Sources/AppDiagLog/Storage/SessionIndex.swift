import Foundation

/// The session_index.json schema.
struct SessionIndex: Codable, Sendable {
    var version: Int = 1
    var maxSessions: Int
    var sessions: [Entry] = []

    struct Entry: Codable, Sendable, Equatable {
        var id: String
        var createdAt: String
        var sealedAt: String?
        var sealed: Bool = false
        var fileSizeBytes: Int64 = 0
        var eventCount: Int = 0
        var sessionTag: String?

        enum CodingKeys: String, CodingKey {
            case id, sealed
            case createdAt = "created_at"
            case sealedAt = "sealed_at"
            case fileSizeBytes = "file_size_bytes"
            case eventCount = "event_count"
            case sessionTag = "session_tag"
        }
    }

    enum CodingKeys: String, CodingKey {
        case version, sessions
        case maxSessions = "max_sessions"
    }

    var totalDiskBytes: Int64 { sessions.reduce(0) { $0 + $1.fileSizeBytes } }
    var firstSealed: Entry? { sessions.first(where: \.sealed) }
    var unsealed: Entry? { sessions.first(where: { !$0.sealed }) }

    mutating func update(id: String, transform: (inout Entry) -> Void) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        transform(&sessions[idx])
    }
}
