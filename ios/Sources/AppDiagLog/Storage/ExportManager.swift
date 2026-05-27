import Foundation

/// Public result type returned by AppDiagLog.export().
public enum ExportResult: Sendable {
    case success(file: URL, sessionCount: Int, totalBytes: Int64)
    case failure(error: Error, message: String)
}

/// Builds the encrypted export ZIP.
///
///   manifest.json        – plaintext session inventory (safe to log on backend)
///   sessions/*.enc       – encrypted session envelopes (opaque to device)
///
/// All entries are STORED (no compression). Since `.enc` is ciphertext, DEFLATE wouldn't
/// reduce size — it would just burn CPU.
actor ExportManager {
    private let paths: AppDiagLogPaths
    private let indexStore: SessionIndexStore
    private let sdkVersion: String

    init(paths: AppDiagLogPaths, indexStore: SessionIndexStore, sdkVersion: String) {
        self.paths = paths
        self.indexStore = indexStore
        self.sdkVersion = sdkVersion
    }

    func export() async -> ExportResult {
        paths.cleanupTemp()
        let index = await indexStore.load()
        guard !index.sessions.isEmpty else {
            return .failure(error: ExportError.nothingToExport, message: "No recorded sessions are available.")
        }
        let out = paths.tempDir.appendingPathComponent(
            "appdiaglog_export_\(Int(Date().timeIntervalSince1970 * 1000)).zip"
        )

        do {
            let manifestEntries = index.sessions.map {
                ExportManifest.Session(
                    id: $0.id,
                    createdAt: $0.createdAt,
                    sealedAt: $0.sealedAt,
                    eventCount: $0.eventCount,
                    sessionTag: $0.sessionTag,
                    fileName: "session_\($0.id).enc"
                )
            }
            let manifest = ExportManifest(
                version: 1,
                sdkVersion: sdkVersion,
                exportedAt: self.nowIso,
                sessions: manifestEntries
            )
            let manifestData = try JSONEncoder().encode(manifest)

            let writer = try MinimalZipWriter(url: out)
            try writer.append(fileName: "manifest.json", data: manifestData)

            var sessionsWritten = 0
            for entry in index.sessions {
                let src = paths.sessionFile(entry.id)
                guard let payload = try? Data(contentsOf: src) else {
                    SdkLog.warn("export: missing file for session \(entry.id)")
                    continue
                }
                try writer.append(fileName: "sessions/session_\(entry.id).enc", data: payload)
                sessionsWritten += 1
            }
            try writer.close()

            guard sessionsWritten > 0 else {
                try? FileManager.default.removeItem(at: out)
                return .failure(error: ExportError.nothingToExport, message: "Session index existed but files were missing on disk.")
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int64) ?? 0
            return .success(file: out, sessionCount: sessionsWritten, totalBytes: size)
        } catch {
            try? FileManager.default.removeItem(at: out)
            SdkLog.error("export failed", error: error)
            return .failure(error: error, message: error.localizedDescription)
        }
    }

    enum ExportError: Error { case nothingToExport }

    private lazy var nowDateFormatter: ISO8601DateFormatter = {
        Date.isoDateFormatter
    }()

    private var nowIso: String {
        return nowDateFormatter.string(from: Date())
    }
}
