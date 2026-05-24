import XCTest
@testable import AppDiagLog

final class SessionEnvelopeRoundtripTests: XCTestCase {

    func testEncryptedSessionFileCanBeDecryptedWithDek() async throws {
        let root = TestHelpers.tempDir("envelope-roundtrip")
        let paths = AppDiagLogPaths(rootDir: root)
        let writer = SessionFileWriter(paths: paths)

        let key = AsymmetricKey.mlKem768(keyId: "test-key", publicKey: Data(repeating: 0xAB, count: 1184))
        let crypto = try SessionCryptoMaterial.generate(
            key: key,
            symmetric: .aes256gcm,
            pqcProvider: TestHelpers.StubPQCProvider()
        )
        // Snapshot the DEK before write — production code wipes it on session seal.
        let dekCopy = crypto.dek

        let events: [EventEnvelope] = (1...5).map { TestHelpers.makeEnvelope(seq: Int64($0)) }
        let args = SessionFileWriter.Args(
            sessionId: "abc",
            createdAt: "2026-04-18T00:00:00.000Z",
            sealedAt: nil,
            sessionTag: "test",
            deviceMetadata: ["os": "iOS 18", "model": "iPhone15,2"],
            crypto: crypto,
            events: events
        )
        _ = try await writer.write(args)

        // Read the envelope back, decrypt with the snapshotted DEK, verify contents.
        let raw = try Data(contentsOf: paths.sessionFile("abc"))
        let envelope = try JSONDecoder().decode(SessionEnvelope.self, from: raw)

        XCTAssertEqual(envelope.sessionId, "abc")
        XCTAssertEqual(envelope.eventCount, 5)
        XCTAssertEqual(envelope.encryption.algorithm, "AES-256-GCM")
        XCTAssertEqual(envelope.encryption.kekAlgorithm, "ML-KEM-768")
        XCTAssertEqual(envelope.deviceMetadata["model"], "iPhone15,2")

        guard
            let iv = Data(base64Encoded: envelope.encryption.nonce),
            let ciphertext = Data(base64Encoded: envelope.payload)
        else {
            return XCTFail("Failed to decode base64 payload/nonce")
        }
        let aad = Data("abc|test-key".utf8)
        let plaintext = try AesGcmEncryptor.decrypt(
            key: dekCopy,
            iv: iv,
            ciphertextAndTag: ciphertext,
            aad: aad
        )

        let decoded = try JSONDecoder().decode([EventEnvelope].self, from: plaintext)
        XCTAssertEqual(decoded.map(\.seq), [1, 2, 3, 4, 5])
    }
}
