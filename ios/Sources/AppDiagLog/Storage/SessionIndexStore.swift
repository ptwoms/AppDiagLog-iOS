import Foundation

/// Reads / writes the session index with atomic replace.
actor SessionIndexStore {
    private let paths: AppDiagLogPaths
    private let maxSessions: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(paths: AppDiagLogPaths, maxSessions: Int) {
        self.paths = paths
        self.maxSessions = maxSessions
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
        self.decoder = JSONDecoder()
    }

    func load() -> SessionIndex {
        guard FileManager.default.fileExists(atPath: paths.indexFile.path) else {
            return SessionIndex(maxSessions: maxSessions)
        }
        do {
            let data = try Data(contentsOf: paths.indexFile)
            if data.isEmpty { return SessionIndex(maxSessions: maxSessions) }
            return try decoder.decode(SessionIndex.self, from: data)
        } catch {
            SdkLog.warn("session index corrupted — reinitializing", error: error)
            return SessionIndex(maxSessions: maxSessions)
        }
    }

    func persist(_ index: SessionIndex) {
        do {
            let data = try encoder.encode(index)
            let tmp = paths.indexFile.appendingPathExtension("tmp")
            try data.write(to: tmp, options: [.atomic])
            _ = try? FileManager.default.replaceItem(at: paths.indexFile, withItemAt: tmp, backupItemName: nil, options: [], resultingItemURL: nil)
        } catch {
            SdkLog.error("persist index failed", error: error)
        }
    }
}
