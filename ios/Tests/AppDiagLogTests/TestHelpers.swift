import Foundation
@testable import AppDiagLog

enum TestHelpers {
    static func makeEnvelope(
        seq: Int64 = 1,
        event: String = "e",
        level: LogLevel = .info,
        props: [String: String] = [:]
    ) -> EventEnvelope {
        EventEnvelope(
            seq: seq,
            ts: "2026-04-18T00:00:00.000Z",
            sessionId: "s",
            screen: nil,
            event: event,
            level: level,
            props: props
        )
    }

    /// Provides a deterministic PQC stub for tests. Encapsulation returns a fixed
    /// shared secret derived from the public key. Decapsulation reproduces it.
    /// This is *not* secure — it just lets crypto roundtrip tests run without liboqs.
    struct StubPQCProvider: PQCProvider {
        var isAvailable: Bool { true }
        func encapsulate(publicKey: Data) throws -> (kemCiphertext: Data, sharedSecret: Data) {
            let kemCiphertext = Data(repeating: 0xCC, count: 1088) // ML-KEM-768 ct size
            // SHA-256(publicKey || "shared") = 32 bytes
            let secret = StubPQCProvider.derive(publicKey: publicKey)
            return (kemCiphertext, secret)
        }
        func decapsulate(privateKey: Data, kemCiphertext: Data) throws -> Data {
            // For test purposes, treat privateKey == publicKey to keep symmetry.
            return Self.derive(publicKey: privateKey)
        }

        private static func derive(publicKey: Data) -> Data {
            // Cheap deterministic 32-byte derivation. Don't use in prod.
            var s = Data(count: 32)
            for i in 0..<32 {
                s[i] = publicKey.isEmpty ? UInt8(i) : publicKey[i % publicKey.count] ^ UInt8(i)
            }
            return s
        }
    }

    static func tempDir(_ name: String = "appdiaglog-tests") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(name)
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
