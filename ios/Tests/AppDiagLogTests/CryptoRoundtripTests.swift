import XCTest
@testable import AppDiagLog

final class CryptoRoundtripTests: XCTestCase {

    func testAesGcmRoundTrip() throws {
        let key = AesGcmEncryptor.generateKey()
        let plaintext = Data("hello diagnostic log".utf8)
        let aad = Data("aad".utf8)

        let sealed = try AesGcmEncryptor.encrypt(key: key, plaintext: plaintext, aad: aad)
        let recovered = try AesGcmEncryptor.decrypt(
            key: key,
            iv: sealed.iv,
            ciphertextAndTag: sealed.ciphertext,
            aad: aad
        )

        XCTAssertEqual(recovered, plaintext)
    }

    func testAesGcmAadMismatchFailsAuth() throws {
        let key = AesGcmEncryptor.generateKey()
        let sealed = try AesGcmEncryptor.encrypt(
            key: key,
            plaintext: Data("p".utf8),
            aad: Data("right".utf8)
        )

        XCTAssertThrowsError(
            try AesGcmEncryptor.decrypt(
                key: key,
                iv: sealed.iv,
                ciphertextAndTag: sealed.ciphertext,
                aad: Data("wrong".utf8)
            )
        )
    }

    func testAesGcmFreshIvOnEveryEncrypt() throws {
        let key = AesGcmEncryptor.generateKey()
        let p = Data("same".utf8)
        let a = try AesGcmEncryptor.encrypt(key: key, plaintext: p)
        let b = try AesGcmEncryptor.encrypt(key: key, plaintext: p)
        XCTAssertNotEqual(a.iv, b.iv, "IV reuse would break GCM confidentiality")
        XCTAssertNotEqual(a.ciphertext, b.ciphertext)
    }

    func testAesKwpRoundTripExactBlockMultiple() throws {
        let kek = AesGcmEncryptor.generateKey()           // 32 bytes
        let dek = AesGcmEncryptor.generateKey()           // 32 bytes (multiple of 8)
        let wrapped = try AesKwp.wrap(kek: kek, key: dek)
        let unwrapped = try AesKwp.unwrap(kek: kek, wrapped: wrapped)
        XCTAssertEqual(unwrapped, dek)
    }

    func testWipeZeroesDek() {
        var key = AesGcmEncryptor.generateKey()
        XCTAssertFalse(key.allSatisfy { $0 == 0 }, "generated key should not be all zeros")
        AesGcmEncryptor.wipe(&key)
        XCTAssertTrue(key.allSatisfy { $0 == 0 }, "wipe should zero the buffer")
    }

    func testSessionCryptoMaterialWipesDekOnSeal() throws {
        let key = AsymmetricKey.mlKem768(keyId: "k1", publicKey: Data(repeating: 0xAB, count: 1184))
        let material = try SessionCryptoMaterial.generate(
            key: key,
            symmetric: .aes256gcm,
            pqcProvider: TestHelpers.StubPQCProvider()
        )
        XCTAssertEqual(material.dek.count, 32)
        material.wipe()
        XCTAssertTrue(material.dek.allSatisfy { $0 == 0 })
    }
}
