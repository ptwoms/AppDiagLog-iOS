import Foundation
import CryptoKit

/// AEAD interface for the per-flush payload cipher. One concrete type per
/// algorithm; the active one is picked by `AppDiagLogConfig.symmetric`.
public enum SymmetricAlgorithm: String, Sendable {
    case aes256gcm = "AES-256-GCM"
    case aes128gcm = "AES-128-GCM"
    case chacha20Poly1305 = "ChaCha20-Poly1305"
}

protocol SymmetricCipher: Sendable {
    var algorithmId: String { get }
    var keySize: Int { get }
    var ivSize: Int { get }

    func generateKey() throws -> Data
    func encrypt(key: Data, plaintext: Data, aad: Data?) throws -> SymmetricSealed
    func decrypt(key: Data, iv: Data, ciphertextAndTag: Data, aad: Data?) throws -> Data
}

struct SymmetricSealed: Sendable {
    let ciphertext: Data
    let iv: Data
}

enum SymmetricCipherFactory {
    static func make(_ algorithm: SymmetricAlgorithm) -> SymmetricCipher {
        switch algorithm {
        case .aes256gcm: return AesGcmCipher(keySize: 32)
        case .aes128gcm: return AesGcmCipher(keySize: 16)
        case .chacha20Poly1305: return ChaCha20Poly1305Cipher()
        }
    }
}

// MARK: - AES-GCM

struct AesGcmCipher: SymmetricCipher {
    let keySize: Int
    let ivSize: Int = 12
    var algorithmId: String { keySize == 32 ? "AES-256-GCM" : "AES-128-GCM" }

    func generateKey() throws -> Data { try Data.randomBytes(keySize) }

    func encrypt(key: Data, plaintext: Data, aad: Data?) throws -> SymmetricSealed {
        try DLCondition(key.count == keySize, SymCipherError.invalidKeyLength)
        let nonce = try AES.GCM.Nonce(data: Data.randomBytes(ivSize))
        let symKey = SymmetricKey(data: key)
        let sealed: AES.GCM.SealedBox
        if let aad {
            sealed = try AES.GCM.seal(plaintext, using: symKey, nonce: nonce, authenticating: aad)
        } else {
            sealed = try AES.GCM.seal(plaintext, using: symKey, nonce: nonce)
        }
        return SymmetricSealed(ciphertext: sealed.ciphertext + sealed.tag, iv: Data(nonce))
    }

    func decrypt(key: Data, iv: Data, ciphertextAndTag: Data, aad: Data?) throws -> Data {
        try DLCondition(key.count == keySize, SymCipherError.invalidKeyLength)
        try DLCondition(iv.count == ivSize, SymCipherError.invalidIvLength)
        try DLCondition(ciphertextAndTag.count >= 16, SymCipherError.invalidCiphertextAndTag)
        let bytes = Data(ciphertextAndTag)
        let tagStart = bytes.count - 16
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: iv),
            ciphertext: bytes.subdata(in: 0..<tagStart),
            tag: bytes.subdata(in: tagStart..<bytes.count)
        )
        if let aad {
            return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
        } else {
            return try AES.GCM.open(box, using: SymmetricKey(data: key))
        }
    }
}

// MARK: - ChaCha20-Poly1305

struct ChaCha20Poly1305Cipher: SymmetricCipher {
    let algorithmId: String = "ChaCha20-Poly1305"
    let keySize: Int = 32
    let ivSize: Int = 12

    func generateKey() throws -> Data { try Data.randomBytes(keySize) }

    func encrypt(key: Data, plaintext: Data, aad: Data?) throws -> SymmetricSealed {
        try DLCondition(key.count == keySize, SymCipherError.invalidKeyLength)
        let nonce = try ChaChaPoly.Nonce(data: Data.randomBytes(ivSize))
        let symKey = SymmetricKey(data: key)
        let sealed: ChaChaPoly.SealedBox
        if let aad {
            sealed = try ChaChaPoly.seal(plaintext, using: symKey, nonce: nonce, authenticating: aad)
        } else {
            sealed = try ChaChaPoly.seal(plaintext, using: symKey, nonce: nonce)
        }
        return SymmetricSealed(ciphertext: sealed.ciphertext + sealed.tag, iv: Data(nonce))
    }

    func decrypt(key: Data, iv: Data, ciphertextAndTag: Data, aad: Data?) throws -> Data {
        try DLCondition(key.count == keySize, SymCipherError.invalidKeyLength)
        try DLCondition(iv.count == ivSize, SymCipherError.invalidIvLength)
        let bytes = Data(ciphertextAndTag)
        let tagStart = bytes.count - 16
        let box = try ChaChaPoly.SealedBox(
            nonce: ChaChaPoly.Nonce(data: iv),
            ciphertext: bytes.subdata(in: 0..<tagStart),
            tag: bytes.subdata(in: tagStart..<bytes.count)
        )
        if let aad {
            return try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: aad)
        } else {
            return try ChaChaPoly.open(box, using: SymmetricKey(data: key))
        }
    }
}

