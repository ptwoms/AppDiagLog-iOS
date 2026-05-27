import Foundation

/// Filesystem layout under the app sandbox.
struct AppDiagLogPaths: Sendable {
    let root: URL
    let sessionsDir: URL
    let indexFile: URL
    let tempDir: URL
    let crashMarkerFile: URL

    init(rootDir: URL) {
        self.root = rootDir.appendingPathComponent("appdiaglog", isDirectory: true)
        self.sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        self.indexFile = root.appendingPathComponent("session_index.json")
        self.tempDir = root.appendingPathComponent("tmp", isDirectory: true)
        self.crashMarkerFile = root.appendingPathComponent("pending_crash_marker.json")
        createDirectories()
    }

    func sessionFile(_ sessionId: String) -> URL {
        sessionsDir.appendingPathComponent("session_\(sessionId).enc")
    }

    func cleanupTemp() {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) else { return }
        for url in entries { try? FileManager.default.removeItem(at: url) }
    }

    private func createDirectories() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Exclude from iCloud backup — diagnostic data is local-only.
        var opts = URLResourceValues()
        opts.isExcludedFromBackup = true
        var rootMutable = root
        try? rootMutable.setResourceValues(opts)
    }
}
