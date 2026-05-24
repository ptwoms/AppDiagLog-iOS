import Foundation
import CryptoKit

/// AES-256-GCM helpers. Use a new IV for every encryption — key+IV reuse destroys GCM's
/// confidentiality guarantees. We generate the IV fresh inside `encrypt`.
enum AesGcmEncryptor {
    static let keySize = 32   // 256-bit
    static let ivSize = 12    // 96-bit recommended for GCM

    struct Sealed {
        let ciphertext: Data
        let iv: Data
    }

    static func generateKey() -> Data { randomBytes(keySize) }

    static func encrypt(key: Data, plaintext: Data, aad: Data? = nil) throws -> Sealed {
        precondition(key.count == keySize, "AES-256 requires a 32-byte key.")
        let nonce = try AES.GCM.Nonce(data: randomBytes(ivSize))
        let sealed: AES.GCM.SealedBox
        if let aad {
            sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: nonce, authenticating: aad)
        } else {
            sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: nonce)
        }
        // CryptoKit's combined form = nonce + ciphertext + tag. We persist nonce separately
        // in the envelope, so we return ciphertext+tag only.
        return Sealed(ciphertext: sealed.ciphertext + sealed.tag, iv: Data(nonce))
    }

    static func decrypt(key: Data, iv: Data, ciphertextAndTag: Data, aad: Data? = nil) throws -> Data {
        precondition(key.count == keySize, "AES-256 requires a 32-byte key.")
        precondition(iv.count == ivSize, "GCM expects a 96-bit IV.")
        precondition(ciphertextAndTag.count >= 16, "ciphertextAndTag must include the 16-byte GCM tag")
        // Re-wrap in a fresh Data to normalize indices — `Data` slicing preserves the
        // original startIndex, which trips both `subdata(in:)` and CryptoKit's
        // ContiguousBytes consumers when the input came from a SubSequence.
        let bytes = Data(ciphertextAndTag)
        let total = bytes.count
        let tagStart = total - 16
        let ciphertext = bytes.subdata(in: 0..<tagStart)
        let tag = bytes.subdata(in: tagStart..<total)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: ciphertext, tag: tag)
        if let aad {
            return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
        } else {
            return try AES.GCM.open(box, using: SymmetricKey(data: key))
        }
    }

    static func wipe(_ data: inout Data) {
        // Swift Data isn't guaranteed to be in-place wipable, but this is best-effort.
        for i in 0..<data.count { data[i] = 0 }
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = Data(count: count)
        let result = bytes.withUnsafeMutableBytes { ptr -> Int32 in
            SecRandomCopyBytes(kSecRandomDefault, count, ptr.baseAddress!)
        }
        precondition(result == errSecSuccess, "SecRandomCopyBytes failed")
        return bytes
    }
}
