import Foundation

/// Applies session eviction at session-creation time.
struct EvictionPolicy: Sendable {
    let paths: AppDiagLogPaths
    let maxSessions: Int
    let maxDiskBytes: Int64

    func apply(_ index: inout SessionIndex) {
        // Guard 1: count
        while index.sessions.count > maxSessions {
            guard let oldest = index.firstSealed else { break }
            delete(id: oldest.id)
            index.sessions.removeAll { $0.id == oldest.id }
        }
        // Guard 2: disk usage
        while index.totalDiskBytes > maxDiskBytes {
            guard let oldest = index.firstSealed else { break }
            delete(id: oldest.id)
            index.sessions.removeAll { $0.id == oldest.id }
        }
    }

    private func delete(id: String) {
        try? FileManager.default.removeItem(at: paths.sessionFile(id))
    }
}
