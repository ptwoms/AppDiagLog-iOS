import XCTest
@testable import AppDiagLog

final class EvictionPolicyTests: XCTestCase {

    func testEvictsOldestSealedWhenOverCount() throws {
        let root = TestHelpers.tempDir("eviction-1")
        let paths = AppDiagLogPaths(rootDir: root)

        // Materialize 4 session files on disk.
        for i in 0..<4 {
            let url = paths.sessionFile("s\(i)")
            try Data("x".utf8).write(to: url)
        }

        var index = SessionIndex(maxSessions: 2)
        index.sessions = [
            .init(id: "s0", createdAt: "t0", sealedAt: nil, sealed: true, fileSizeBytes: 10, eventCount: 0, sessionTag: nil),
            .init(id: "s1", createdAt: "t1", sealedAt: nil, sealed: true, fileSizeBytes: 10, eventCount: 0, sessionTag: nil),
            .init(id: "s2", createdAt: "t2", sealedAt: nil, sealed: true, fileSizeBytes: 10, eventCount: 0, sessionTag: nil),
            .init(id: "s3", createdAt: "t3", sealedAt: nil, sealed: false, fileSizeBytes: 10, eventCount: 0, sessionTag: nil)
        ]

        let policy = EvictionPolicy(paths: paths, maxSessions: 2, maxDiskBytes: .max)
        policy.apply(&index)

        XCTAssertEqual(index.sessions.map(\.id), ["s2", "s3"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.sessionFile("s0").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.sessionFile("s1").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.sessionFile("s3").path),
                      "unsealed session must survive")
    }

    func testNeverEvictsUnsealedSessionEvenUnderTightDiskBudget() throws {
        let root = TestHelpers.tempDir("eviction-2")
        let paths = AppDiagLogPaths(rootDir: root)

        let currentURL = paths.sessionFile("current")
        try Data("big".utf8).write(to: currentURL)

        var index = SessionIndex(maxSessions: 5)
        index.sessions = [
            .init(id: "current", createdAt: "t", sealedAt: nil, sealed: false,
                  fileSizeBytes: 1_000_000, eventCount: 0, sessionTag: nil)
        ]

        let policy = EvictionPolicy(paths: paths, maxSessions: 5, maxDiskBytes: 1_000)
        policy.apply(&index)

        XCTAssertEqual(index.sessions.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentURL.path))
    }

    func testEvictsForDiskBudget() throws {
        let root = TestHelpers.tempDir("eviction-3")
        let paths = AppDiagLogPaths(rootDir: root)

        for i in 0..<3 {
            try Data("x".utf8).write(to: paths.sessionFile("s\(i)"))
        }

        var index = SessionIndex(maxSessions: 10)
        index.sessions = [
            .init(id: "s0", createdAt: "t0", sealedAt: nil, sealed: true, fileSizeBytes: 800, eventCount: 0, sessionTag: nil),
            .init(id: "s1", createdAt: "t1", sealedAt: nil, sealed: true, fileSizeBytes: 800, eventCount: 0, sessionTag: nil),
            .init(id: "s2", createdAt: "t2", sealedAt: nil, sealed: true, fileSizeBytes: 800, eventCount: 0, sessionTag: nil)
        ]

        // Budget = 2000 bytes total → must drop one (oldest) to fit.
        EvictionPolicy(paths: paths, maxSessions: 10, maxDiskBytes: 2_000).apply(&index)

        XCTAssertEqual(index.sessions.map(\.id), ["s1", "s2"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.sessionFile("s0").path))
    }
}
