import Foundation
import CryptoKit
import Security

/// On-wire output of an asymmetric DEK wrapper.
struct WrappedDek: Sendable {
    let kemCiphertext: Data
    let wrappedDek: Data
    let kekAlgorithm: String
    let kekParams: [String: String]
}

protocol KemWrapper: Sendable {
    var algorithmId: String { get }
    func wrap(dek: Data, key: AsymmetricKey) throws -> WrappedDek
}

enum KemWrapperFactory {
    /// `pqcProvider` is consulted only when the configured key is an ML-KEM variant.
    /// Other algorithms (RSA-OAEP, ECDH-P256) rely on system primitives.
    static func make(for key: AsymmetricKey, pqcProvider: PQCProvider) -> KemWrapper {
        switch key {
        case .mlKem768, .mlKem512:
            return MLKEMWrapper(provider: pqcProvider, parameters: key)
        case .rsaOaep3072:
            return RSAOAEPWrapper()
        case .ecdhP256:
            return ECDHKEMWrapper()
        }
    }
}

// MARK: - ML-KEM (768 / 512)

struct MLKEMWrapper: KemWrapper {
    let provider: PQCProvider
    /// Carries which parameter set we report on the wire.
    let parameters: AsymmetricKey
    var algorithmId: String {
        switch parameters {
        case .mlKem768: return "ML-KEM-768"
        case .mlKem512: return "ML-KEM-512"
        default: return "ML-KEM-768"
        }
    }

    func wrap(dek: Data, key: AsymmetricKey) throws -> WrappedDek {
        let pubBytes: Data
        switch key {
        case .mlKem768(_, let bytes): pubBytes = bytes
        case .mlKem512(_, let bytes): pubBytes = bytes
        default: throw PQCUnavailableError()
        }
        let enc = try provider.encapsulate(publicKey: pubBytes)
        defer {
            var ss = enc.sharedSecret
            wipe(&ss)
        }
        let wrapped = try AesKwp.wrap(kek: enc.sharedSecret, key: dek)
        return WrappedDek(
            kemCiphertext: enc.kemCiphertext,
            wrappedDek: wrapped,
            kekAlgorithm: algorithmId,
            kekParams: [:]
        )
    }
}

// MARK: - RSA-OAEP-3072

struct RSAOAEPWrapper: KemWrapper {
    let algorithmId: String = "RSA-OAEP-3072"

    func wrap(dek: Data, key: AsymmetricKey) throws -> WrappedDek {
        guard case .rsaOaep3072(_, let pubBytes) = key else {
            throw NSError(domain: "RSAOAEPWrapper", code: 1, userInfo: [NSLocalizedDescriptionKey: "wrong key type"])
        }
        // Parse X.509 SubjectPublicKeyInfo via SecKey. We accept either raw RSA
        // public key bytes (PKCS#1) or the SPKI wrapping; SecKeyCreateWithData
        // wants the PKCS#1 form, so strip the SPKI prefix if present.
        let pkcs1 = stripSpkiPrefixIfPresent(pubBytes)
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 3072,
        ]
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, &error) else {
            throw error?.takeRetainedValue() ?? NSError(domain: "RSAOAEPWrapper", code: 2)
        }
        let algorithm: SecKeyAlgorithm = .rsaEncryptionOAEPSHA256
        guard SecKeyIsAlgorithmSupported(secKey, .encrypt, algorithm) else {
            throw NSError(domain: "RSAOAEPWrapper", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "RSA-OAEP-SHA256 not supported on this runtime"])
        }
        var encErr: Unmanaged<CFError>?
        guard let cipher = SecKeyCreateEncryptedData(secKey, algorithm, dek as CFData, &encErr) else {
            throw encErr?.takeRetainedValue() ?? NSError(domain: "RSAOAEPWrapper", code: 4)
        }
        return WrappedDek(
            kemCiphertext: Data(),
            wrappedDek: cipher as Data,
            kekAlgorithm: algorithmId,
            kekParams: ["hash": "SHA-256", "mgf": "MGF1-SHA-256"]
        )
    }

    /// SecKey RSA APIs accept PKCS#1 RSAPublicKey bytes — not the SPKI envelope. If the
    /// caller provided SPKI (the encoding everyone uses on the wire), strip the algorithm
    /// identifier prefix to get the inner PKCS#1 bytes. Best-effort: if the structure
    /// doesn't match, return as-is and let SecKey raise.
    private func stripSpkiPrefixIfPresent(_ data: Data) -> Data {
        // The standard SPKI for 3072-bit RSA starts with a DER SEQUENCE; the
        // inner BIT STRING contains the PKCS#1 RSAPublicKey. We do the minimum
        // ASN.1 walk needed to extract it.
        guard data.count > 32, data.first == 0x30 else { return data }
        var idx = 1
        // SEQUENCE length
        idx += derLengthSkip(data, at: idx)
        // AlgorithmIdentifier SEQUENCE
        guard idx < data.count, data[idx] == 0x30 else { return data }
        idx += 1
        let algIdLen = derLength(data, at: &idx)
        idx += algIdLen
        // BIT STRING
        guard idx < data.count, data[idx] == 0x03 else { return data }
        idx += 1
        _ = derLength(data, at: &idx)
        // skip unused-bits byte (always 0 for keys)
        guard idx < data.count else { return data }
        idx += 1
        return data.subdata(in: idx..<data.count)
    }

    private func derLengthSkip(_ data: Data, at index: Int) -> Int {
        let b = data[index]
        if b < 0x80 { return 1 }
        return Int(b & 0x7F) + 1
    }

    private func derLength(_ data: Data, at index: inout Int) -> Int {
        let b = data[index]
        index += 1
        if b < 0x80 { return Int(b) }
        let n = Int(b & 0x7F)
        var len = 0
        for _ in 0..<n {
            len = (len << 8) | Int(data[index])
            index += 1
        }
        return len
    }
}

// MARK: - ECDH-P256+HKDF

struct ECDHKEMWrapper: KemWrapper {
    let algorithmId: String = "ECDH-P256+HKDF"
    static let hkdfInfo = Data("AppDiagLog/ECDH-P256+HKDF".utf8)

    func wrap(dek: Data, key: AsymmetricKey) throws -> WrappedDek {
        guard case .ecdhP256(_, let pubBytes) = key else {
            throw NSError(domain: "ECDHKEMWrapper", code: 1, userInfo: [NSLocalizedDescriptionKey: "wrong key type"])
        }
        // Recipient static public key. The wire format is X.509 SubjectPublicKeyInfo
        // (DER) so every consumer — backend, Python, Go — parses the same
        // bytes. Fall back to x963 if a caller supplies the raw uncompressed point.
        let recipientPublicKey = try parseP256PublicKey(pubBytes)

        // Ephemeral keypair. The DER (SPKI) encoding is what we ship in
        // `kem_ciphertext` so every receiver parses it identically.
        let ephemeralPrivate = P256.KeyAgreement.PrivateKey()
        let ephemeralPubDer = ephemeralPrivate.publicKey.derRepresentation

        // ECDH → shared.
        let shared = try ephemeralPrivate.sharedSecretFromKeyAgreement(with: recipientPublicKey)

        // HKDF-SHA-256(shared, salt=ephemeralPub-DER, info, length=32). The salt
        // MUST be the same bytes the receiver sees in `kem_ciphertext`.
        let derived = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: ephemeralPubDer,
            sharedInfo: Self.hkdfInfo,
            outputByteCount: 32
        )
        let derivedData = derived.withUnsafeBytes { Data($0) }

        // AES-KWP-wrap DEK with the derived KEK.
        let wrapped = try AesKwp.wrap(kek: derivedData, key: dek)
        return WrappedDek(
            kemCiphertext: ephemeralPubDer,
            wrappedDek: wrapped,
            kekAlgorithm: algorithmId,
            kekParams: ["curve": "P-256", "kdf": "HKDF-SHA-256"]
        )
    }

    private func parseP256PublicKey(_ data: Data) throws -> P256.KeyAgreement.PublicKey {
        // Prefer DER (matches the wire format everyone else uses). Fall back to
        // x963 in case callers supplied the raw uncompressed point.
        if let key = try? P256.KeyAgreement.PublicKey(derRepresentation: data) {
            return key
        }
        return try P256.KeyAgreement.PublicKey(x963Representation: data)
    }
}

// MARK: - misc helpers

@inline(__always)
private func wipe(_ data: inout Data) {
    for i in 0..<data.count { data[i] = 0 }
}
