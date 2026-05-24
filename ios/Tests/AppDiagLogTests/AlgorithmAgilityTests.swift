import XCTest
import CryptoKit
import Security
@testable import AppDiagLog

/// Validates each (symmetric × asymmetric) pair round-trips end to end through
/// the device-side wrappers and a local "backend" decrypt that uses the same
/// platform primitives.
///
/// ML-KEM is exercised via the deterministic [TestHelpers.StubPQCProvider], so
/// these tests run on every iOS version. Apps targeting production must inject
/// a real PQCProvider (CryptoKit on iOS 18+, or liboqs).
final class AlgorithmAgilityTests: XCTestCase {

    private let plaintext = Data((0..<512).map { UInt8($0 & 0xFF) })
    private let aad = Data("session|key".utf8)

    func testEverySymmetricByAsymmetricPair() throws {
        let cases: [(label: String, asym: AsymKey)] = [
            ("ML-KEM-768", try mlKem(parameters: .mlKem768)),
            ("ML-KEM-512", try mlKem(parameters: .mlKem512)),
            ("RSA-OAEP-3072", try rsaOaep()),
            ("ECDH-P256+HKDF", try ecdh()),
        ]
        for symmetric in [SymmetricAlgorithm.aes256gcm, .aes128gcm, .chacha20Poly1305] {
            for c in cases {
                try runRoundTrip(
                    label: "\(symmetric.rawValue) + \(c.label)",
                    asymmetric: c.asym,
                    symmetric: symmetric
                )
            }
        }
    }

    // MARK: - core round-trip

    private struct AsymKey {
        let publicKeyEntry: AsymmetricKey
        let provider: PQCProvider
        let unwrap: (WrappedDek) throws -> Data
    }

    private func runRoundTrip(
        label: String,
        asymmetric: AsymKey,
        symmetric: SymmetricAlgorithm
    ) throws {
        let material = try SessionCryptoMaterial.generate(
            key: asymmetric.publicKeyEntry,
            symmetric: symmetric,
            pqcProvider: asymmetric.provider
        )
        let sealed = try material.cipher.encrypt(key: material.dek, plaintext: plaintext, aad: aad)
        let recoveredDek = try asymmetric.unwrap(material.wrapped)
        let recoveredPlain = try material.cipher.decrypt(
            key: recoveredDek,
            iv: sealed.iv,
            ciphertextAndTag: sealed.ciphertext,
            aad: aad
        )
        XCTAssertEqual(recoveredPlain, plaintext, "round-trip failed for \(label)")
        material.wipe()
    }

    // MARK: - case factories

    private enum MlKemParameters { case mlKem768, mlKem512 }

    private func mlKem(parameters: MlKemParameters) throws -> AsymKey {
        // ML-KEM relies on the injected provider — use the deterministic stub
        // so we can derive the shared secret on the decrypt side without
        // shipping liboqs to the test target.
        let stub = TestHelpers.StubPQCProvider()
        let fakePubKey = Data(repeating: 0xAB, count: parameters == .mlKem768 ? 1184 : 800)
        let key: AsymmetricKey = parameters == .mlKem768
            ? .mlKem768(keyId: "test", publicKey: fakePubKey)
            : .mlKem512(keyId: "test", publicKey: fakePubKey)
        return AsymKey(
            publicKeyEntry: key,
            provider: stub,
            unwrap: { wrapped in
                // Symmetric stub: encapsulate→derive(pub), decapsulate→derive(priv).
                // We use the same byte string for both halves to keep symmetry.
                let shared = try stub.decapsulate(privateKey: fakePubKey, kemCiphertext: wrapped.kemCiphertext)
                return try AesKwp.unwrap(kek: shared, wrapped: wrapped.wrappedDek)
            }
        )
    }

    private func rsaOaep() throws -> AsymKey {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 3072,
        ]
        var error: Unmanaged<CFError>?
        guard let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
            throw error?.takeRetainedValue() ?? NSError(domain: "test", code: 1)
        }
        let pub = SecKeyCopyPublicKey(priv)!
        let pubData = SecKeyCopyExternalRepresentation(pub, &error)! as Data
        let key: AsymmetricKey = .rsaOaep3072(keyId: "test", publicKey: pubData)
        return AsymKey(
            publicKeyEntry: key,
            provider: TestHelpers.StubPQCProvider(),
            unwrap: { wrapped in
                var err: Unmanaged<CFError>?
                guard let cleartext = SecKeyCreateDecryptedData(
                    priv,
                    .rsaEncryptionOAEPSHA256,
                    wrapped.wrappedDek as CFData,
                    &err
                ) else {
                    throw err?.takeRetainedValue() ?? NSError(domain: "test", code: 2)
                }
                return cleartext as Data
            }
        )
    }

    private func ecdh() throws -> AsymKey {
        let priv = P256.KeyAgreement.PrivateKey()
        let pub = priv.publicKey.derRepresentation
        let key: AsymmetricKey = .ecdhP256(keyId: "test", publicKey: pub)
        return AsymKey(
            publicKeyEntry: key,
            provider: TestHelpers.StubPQCProvider(),
            unwrap: { wrapped in
                let ephemeral = try P256.KeyAgreement.PublicKey(derRepresentation: wrapped.kemCiphertext)
                let shared = try priv.sharedSecretFromKeyAgreement(with: ephemeral)
                let derived = shared.hkdfDerivedSymmetricKey(
                    using: SHA256.self,
                    salt: wrapped.kemCiphertext,
                    sharedInfo: ECDHKEMWrapper.hkdfInfo,
                    outputByteCount: 32
                )
                let kek = derived.withUnsafeBytes { Data($0) }
                return try AesKwp.unwrap(kek: kek, wrapped: wrapped.wrappedDek)
            }
        )
    }
}
